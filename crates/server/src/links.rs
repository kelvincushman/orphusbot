//! Linking a device that can't use passkeys, such as the Linux desktop app
//! (WebKitGTK has no WebAuthn) or an old browser. DESIGN §12, DECISIONS D-019.
//!
//! The device starts a link and shows a short code. The owner, signed in with
//! a passkey somewhere else, approves that code. The device's next poll gets
//! a session of its own, tied to the approving passkey, so removing that
//! passkey signs the device out too.

use std::time::Duration;

use axum::Json;
use axum::extract::{Extension, Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::{SESSION, Session, create_session, digest, random_token};
use crate::{ApiError, Shared, internal};

const LINK_LIFETIME: Duration = Duration::from_secs(10 * 60);
/// 32 letters and digits with the easily confused ones (0, O, 1, I) left out.
const ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MAX_LABEL_CHARS: usize = 120;

fn user_code() -> anyhow::Result<String> {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).map_err(|e| anyhow::anyhow!("no OS randomness: {e}"))?;
    let c: String = bytes
        .iter()
        .map(|b| char::from(ALPHABET[usize::from(b % 32)]))
        .collect();
    Ok(format!("{}-{}", &c[..4], &c[4..]))
}

/// Accepts "abcd efgh", "ABCDEFGH" or "ABCD-EFGH".
fn normalise(code: &str) -> String {
    let c: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    match (c.get(..4), c.get(4..)) {
        (Some(a), Some(b)) if c.len() == 8 => format!("{a}-{b}"),
        _ => c,
    }
}

/// A device without passkeys asks to be linked.
pub async fn start(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let label: String = headers
        .get(header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .filter(|ua| !ua.trim().is_empty())
        .unwrap_or("Unknown device")
        .chars()
        .take(MAX_LABEL_CHARS)
        .collect();
    let (device_code, user_code) = random_token()
        .and_then(|d| Ok((d, user_code()?)))
        .map_err(|e| internal("starting a device link", e))?;
    let stored = async {
        sqlx::query!("delete from device_link where expires_at <= now()")
            .execute(&app.db)
            .await?;
        sqlx::query!(
            "insert into device_link (device_hash, user_code, label, expires_at)
             values ($1, $2, $3, now() + make_interval(secs => $4))",
            digest(&device_code),
            user_code,
            label,
            LINK_LIFETIME.as_secs_f64()
        )
        .execute(&app.db)
        .await
    };
    stored
        .await
        .map_err(|e| internal("starting a device link", e))?;
    Ok(Json(json!({
        "device_code": device_code,
        "user_code": user_code,
        "expires_in_secs": LINK_LIFETIME.as_secs(),
    })))
}

#[derive(Deserialize)]
pub struct Poll {
    device_code: String,
}

/// The device checks whether its link was approved. 202 while waiting; once
/// approved, 200 with a session cookie, and the link is used up.
pub async fn poll(State(app): State<Shared>, Json(body): Json<Poll>) -> Result<Response, ApiError> {
    let hash = digest(&body.device_code);
    let approved = sqlx::query_scalar!(
        r#"delete from device_link
           where device_hash = $1 and expires_at > now() and passkey_id is not null
           returning passkey_id as "passkey_id!""#,
        hash
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("checking a device link", e))?;
    if let Some(passkey) = approved {
        let token = create_session(&app.db, Some(passkey), SESSION)
            .await
            .map_err(|e| internal("starting a session", e))?;
        let cookie = app.auth.cookie(&token, SESSION);
        return Ok((
            StatusCode::OK,
            [(header::SET_COOKIE, cookie)],
            Json(json!({ "linked": true })),
        )
            .into_response());
    }
    let waiting = sqlx::query_scalar!(
        r#"select true as "waiting!" from device_link where device_hash = $1 and expires_at > now()"#,
        hash
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("checking a device link", e))?;
    match waiting {
        Some(_) => Ok((StatusCode::ACCEPTED, Json(json!({ "linked": false }))).into_response()),
        None => Err((StatusCode::GONE, "This link expired; start again")),
    }
}

/// What's waiting behind a code, so the owner can check before approving.
pub async fn lookup(
    State(app): State<Shared>,
    Path(code): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let code = normalise(&code);
    let label = sqlx::query_scalar!(
        "select label from device_link
         where user_code = $1 and expires_at > now() and passkey_id is null",
        code
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("looking up a device link", e))?
    .ok_or((StatusCode::NOT_FOUND, "No device is waiting with that code"))?;
    Ok(Json(json!({ "user_code": code, "label": label })))
}

#[derive(Deserialize)]
pub struct Approve {
    user_code: String,
}

/// The owner approves a waiting device from a passkey session.
pub async fn approve(
    State(app): State<Shared>,
    Extension(session): Extension<Session>,
    Json(body): Json<Approve>,
) -> Result<StatusCode, ApiError> {
    let Some(passkey) = session.passkey else {
        return Err((
            StatusCode::FORBIDDEN,
            "Add a passkey first; a setup session can't link devices",
        ));
    };
    let approved = sqlx::query!(
        "update device_link set passkey_id = $2
         where user_code = $1 and expires_at > now() and passkey_id is null",
        normalise(&body.user_code),
        passkey
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("approving a device link", e))?
    .rows_affected();
    if approved == 0 {
        return Err((StatusCode::NOT_FOUND, "No device is waiting with that code"));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::tests::{app, call};
    use sqlx::PgPool;

    /// A session signed in with a (stand-in) passkey, as the owner's browser would have.
    async fn owner_cookie(db: &PgPool) -> String {
        let passkey = sqlx::query_scalar!(
            "insert into passkey (name, credential) values ('phone', '{}') returning id"
        )
        .fetch_one(db)
        .await
        .unwrap();
        create_session(db, Some(passkey), SESSION).await.unwrap()
    }

    #[sqlx::test]
    async fn approved_device_gets_its_own_session_once(db: PgPool) {
        let owner = owner_cookie(&db).await;
        let app = app(db);

        let (status, _, link) = call(&app, "/auth/link/start", "", Some(json!({}))).await;
        assert_eq!(status, StatusCode::OK);
        let device_code = link["device_code"].as_str().unwrap().to_owned();
        let user_code = link["user_code"].as_str().unwrap().to_owned();
        let poll = json!({ "device_code": device_code });
        assert_eq!(
            call(&app, "/auth/link/poll", "", Some(poll.clone()))
                .await
                .0,
            StatusCode::ACCEPTED
        );

        // The owner checks the code (typed loosely) and approves it.
        let typed = user_code.to_lowercase().replace('-', " ");
        let (status, _, found) = call(
            &app,
            &format!("/api/links/{}", typed.replace(' ', "%20")),
            &owner,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(found["label"], "Unknown device");
        let approve = json!({ "user_code": typed });
        assert_eq!(
            call(&app, "/api/links/approve", &owner, Some(approve.clone()))
                .await
                .0,
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            call(&app, "/api/links/approve", &owner, Some(approve))
                .await
                .0,
            StatusCode::NOT_FOUND
        );

        let (status, cookie, _) = call(&app, "/auth/link/poll", "", Some(poll.clone())).await;
        assert_eq!(status, StatusCode::OK);
        let cookie = cookie.unwrap();
        assert_ne!(cookie, owner);
        assert_eq!(
            call(&app, "/api/passkeys", &cookie, None).await.0,
            StatusCode::OK
        );
        // Used up.
        assert_eq!(
            call(&app, "/auth/link/poll", "", Some(poll)).await.0,
            StatusCode::GONE
        );
    }

    #[sqlx::test]
    async fn only_passkey_sessions_approve_and_codes_expire(db: PgPool) {
        let app = app(db.clone());
        let setup = create_session(&db, None, SESSION).await.unwrap();
        let (_, _, link) = call(&app, "/auth/link/start", "", Some(json!({}))).await;
        let approve = json!({ "user_code": link["user_code"] });
        assert_eq!(
            call(&app, "/api/links/approve", &setup, Some(approve.clone()))
                .await
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            call(&app, "/api/links/approve", "", Some(approve)).await.0,
            StatusCode::UNAUTHORIZED
        );

        sqlx::query!("update device_link set expires_at = now() - interval '1 second'")
            .execute(&db)
            .await
            .unwrap();
        let poll = json!({ "device_code": link["device_code"] });
        assert_eq!(
            call(&app, "/auth/link/poll", "", Some(poll)).await.0,
            StatusCode::GONE
        );
    }

    #[test]
    fn codes_look_right_and_normalise() {
        let code = user_code().unwrap();
        assert_eq!(code.len(), 9);
        assert!(
            code.chars()
                .all(|c| c == '-' || ALPHABET.contains(&(c as u8)))
        );
        assert_eq!(normalise(" abcd efgh "), "ABCD-EFGH");
        assert_eq!(normalise("ABCDEFGH"), "ABCD-EFGH");
        assert_eq!(normalise("abc"), "ABC");
    }
}
