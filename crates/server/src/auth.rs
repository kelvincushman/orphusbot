//! Sign-in: passkeys and sessions (DESIGN §12, PRD B-CLI-06).
//!
//! While no passkey exists, the setup token signs you in for an hour so you
//! can add one. After that, passkeys are the only way in. Removing every
//! passkey turns the setup token back on, which is the recovery path.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Context;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::{Extension, Form, Json};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use sqlx::types::Json as Jsonb;
use tracing::warn;
use webauthn_rs::prelude::*;

use crate::{ApiError, Shared, internal, lock, tokens_match};

const COOKIE: &str = "orphusbot_session";
/// A setup session only has to last long enough to add a passkey.
const SETUP_SESSION: Duration = Duration::from_secs(60 * 60);
pub(crate) const SESSION: Duration = Duration::from_secs(30 * 24 * 60 * 60);
/// How long the browser has to finish a passkey prompt.
const CEREMONY: Duration = Duration::from_secs(5 * 60);
const MAX_NAME_CHARS: usize = 60;
/// OrphusBot has one owner; this is their WebAuthn user handle.
const OWNER: Uuid = Uuid::from_u128(0x6f72_7068_7573_626f_742d_6f77_6e65_7201);

enum Ceremony {
    Register(PasskeyRegistration),
    Login(PasskeyAuthentication),
}

pub struct Auth {
    webauthn: Webauthn,
    setup_token: String,
    /// Mark cookies `Secure` when served over HTTPS.
    secure: bool,
    // ponytail: prompts in progress live in memory, so a server restart mid-sign-in means trying again.
    ceremonies: Mutex<HashMap<String, (Instant, Ceremony)>>,
}

impl Auth {
    /// `origin` is the address browsers use, such as `https://bots.example.com`.
    /// Passkeys are bound to its host name, so it can't be an IP address.
    pub fn new(origin: &str, setup_token: String) -> anyhow::Result<Self> {
        let url = Url::parse(origin).context("ORPHUSBOT_ORIGIN is not a URL")?;
        let rp_id = url
            .domain()
            .context("ORPHUSBOT_ORIGIN needs a host name such as localhost, not an IP address")?
            .to_owned();
        let webauthn = WebauthnBuilder::new(&rp_id, &url)?
            .rp_name("OrphusBot")
            .build()?;
        Ok(Self {
            webauthn,
            setup_token,
            secure: url.scheme() == "https",
            ceremonies: Mutex::default(),
        })
    }

    fn begin(&self, ceremony: Ceremony) -> anyhow::Result<String> {
        let id = random_token()?;
        let mut all = lock(&self.ceremonies);
        all.retain(|_, (at, _)| at.elapsed() < CEREMONY);
        all.insert(id.clone(), (Instant::now(), ceremony));
        Ok(id)
    }

    fn finish(&self, id: &str) -> Option<Ceremony> {
        lock(&self.ceremonies)
            .remove(id)
            .filter(|(at, _)| at.elapsed() < CEREMONY)
            .map(|(_, c)| c)
    }

    pub(crate) fn cookie(&self, token: &str, ttl: Duration) -> String {
        let secure = if self.secure { "; Secure" } else { "" };
        format!(
            "{COOKIE}={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={}{secure}",
            ttl.as_secs()
        )
    }
}

/// A signed-in browser, put in request extensions by [`require_session`].
#[derive(Clone)]
pub struct Session {
    hash: Vec<u8>,
    /// `None` for a setup session.
    pub(crate) passkey: Option<i64>,
}

pub(crate) fn random_token() -> anyhow::Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| anyhow::anyhow!("no OS randomness: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub(crate) fn digest(token: &str) -> Vec<u8> {
    Sha256::digest(token.as_bytes()).to_vec()
}

fn cookie_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|kv| kv.trim().split_once('='))
        .find(|(k, _)| *k == COOKIE)
        .map(|(_, v)| v)
}

async fn current(db: &PgPool, headers: &HeaderMap) -> sqlx::Result<Option<Session>> {
    let Some(token) = cookie_token(headers) else {
        return Ok(None);
    };
    let hash = digest(token);
    let passkey = sqlx::query_scalar!(
        "select passkey_id from session where token_hash = $1 and expires_at > now()",
        hash
    )
    .fetch_optional(db)
    .await?;
    Ok(passkey.map(|passkey| Session { hash, passkey }))
}

pub(crate) async fn create_session(
    db: &PgPool,
    passkey: Option<i64>,
    ttl: Duration,
) -> anyhow::Result<String> {
    let token = random_token()?;
    sqlx::query!("delete from session where expires_at <= now()")
        .execute(db)
        .await?;
    sqlx::query!(
        "insert into session (token_hash, passkey_id, expires_at)
         values ($1, $2, now() + make_interval(secs => $3))",
        digest(&token),
        passkey,
        ttl.as_secs_f64()
    )
    .execute(db)
    .await?;
    Ok(token)
}

async fn passkeys(db: &PgPool) -> sqlx::Result<Vec<(i64, Passkey)>> {
    let rows = sqlx::query!(
        r#"select id, credential as "credential: Jsonb<Passkey>" from passkey order by id"#
    )
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.credential.0)).collect())
}

async fn passkey_count(db: &PgPool) -> Result<i64, ApiError> {
    sqlx::query_scalar!(r#"select count(*) as "n!" from passkey"#)
        .fetch_one(db)
        .await
        .map_err(|e| internal("counting passkeys", e))
}

/// Guards `/api`: anything without a live session gets 401.
pub async fn require_session(State(app): State<Shared>, mut req: Request, next: Next) -> Response {
    match current(&app.db, req.headers()).await {
        Ok(Some(session)) => {
            req.extensions_mut().insert(session);
            next.run(req).await
        }
        Ok(None) => (StatusCode::UNAUTHORIZED, "Sign in first").into_response(),
        Err(e) => internal("checking the session", e).into_response(),
    }
}

/// What the sign-in screen should show.
pub async fn state(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let session = current(&app.db, &headers)
        .await
        .map_err(|e| internal("checking the session", e))?;
    let setup_open = passkey_count(&app.db).await? == 0;
    Ok(Json(json!({
        "signed_in": session.is_some(),
        "needs_passkey": session.is_some_and(|s| s.passkey.is_none()),
        "setup_open": setup_open,
    })))
}

#[derive(Deserialize)]
pub struct SetupForm {
    token: String,
}

/// Signs in with the setup token, only while no passkey exists.
pub async fn setup(
    State(app): State<Shared>,
    Form(form): Form<SetupForm>,
) -> Result<Response, ApiError> {
    if !tokens_match(&form.token, &app.auth.setup_token) {
        return Err((StatusCode::UNAUTHORIZED, "Wrong setup token"));
    }
    if passkey_count(&app.db).await? > 0 {
        return Err((
            StatusCode::FORBIDDEN,
            "A passkey is set up, so sign in with that",
        ));
    }
    let token = create_session(&app.db, None, SETUP_SESSION)
        .await
        .map_err(|e| internal("starting a session", e))?;
    let cookie = app.auth.cookie(&token, SETUP_SESSION);
    Ok((
        StatusCode::SEE_OTHER,
        [(header::SET_COOKIE, cookie), (header::LOCATION, "/".into())],
    )
        .into_response())
}

/// First half of adding a passkey: the options for `navigator.credentials.create`.
pub async fn register_start(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let existing = passkeys(&app.db)
        .await
        .map_err(|e| internal("reading passkeys", e))?;
    // Stops the same authenticator registering twice.
    let exclude = existing.iter().map(|(_, p)| p.cred_id().clone()).collect();
    let (options, reg) = app
        .auth
        .webauthn
        .start_passkey_registration(OWNER, "owner", "OrphusBot owner", Some(exclude))
        .map_err(|e| internal("starting passkey registration", e))?;
    let id = app
        .auth
        .begin(Ceremony::Register(reg))
        .map_err(|e| internal("starting passkey registration", e))?;
    Ok(Json(json!({ "id": id, "options": options })))
}

#[derive(Deserialize)]
pub struct RegisterFinish {
    id: String,
    name: String,
    credential: RegisterPublicKeyCredential,
}

/// Second half: verify and store the new passkey.
pub async fn register_finish(
    State(app): State<Shared>,
    Extension(session): Extension<Session>,
    headers: HeaderMap,
    Json(body): Json<RegisterFinish>,
) -> Result<Response, ApiError> {
    let name = body.name.trim();
    if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Name the passkey in 1 to 60 characters",
        ));
    }
    let Some(Ceremony::Register(reg)) = app.auth.finish(&body.id) else {
        return Err((StatusCode::GONE, "That passkey prompt expired; try again"));
    };
    let passkey = app
        .auth
        .webauthn
        .finish_passkey_registration(&body.credential, &reg)
        .map_err(|e| {
            warn!("passkey registration failed: {e}");
            (StatusCode::BAD_REQUEST, "The passkey could not be verified")
        })?;
    let id = sqlx::query_scalar!(
        "insert into passkey (name, credential) values ($1, $2) returning id",
        name,
        Jsonb(&passkey) as _
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("storing the passkey", e))?;

    if session.passkey.is_some() {
        return Ok(StatusCode::CREATED.into_response());
    }
    // A setup session becomes a normal one, so adding the first passkey doesn't sign
    // you out an hour later, and no other setup session outlives the setup token.
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("upgrading the session", e))?;
    sqlx::query!(
        "update session set passkey_id = $2, expires_at = now() + make_interval(secs => $3)
         where token_hash = $1",
        session.hash,
        id,
        SESSION.as_secs_f64()
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("upgrading the session", e))?;
    sqlx::query!("delete from session where passkey_id is null")
        .execute(&mut *tx)
        .await
        .map_err(|e| internal("upgrading the session", e))?;
    tx.commit()
        .await
        .map_err(|e| internal("upgrading the session", e))?;
    let token = cookie_token(&headers).unwrap_or_default();
    let cookie = app.auth.cookie(token, SESSION);
    Ok((StatusCode::CREATED, [(header::SET_COOKIE, cookie)]).into_response())
}

/// First half of signing in: the options for `navigator.credentials.get`.
pub async fn login_start(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let creds: Vec<Passkey> = passkeys(&app.db)
        .await
        .map_err(|e| internal("reading passkeys", e))?
        .into_iter()
        .map(|(_, p)| p)
        .collect();
    if creds.is_empty() {
        return Err((
            StatusCode::CONFLICT,
            "No passkey yet; sign in with the setup token",
        ));
    }
    let (options, auth) = app
        .auth
        .webauthn
        .start_passkey_authentication(&creds)
        .map_err(|e| internal("starting passkey sign-in", e))?;
    let id = app
        .auth
        .begin(Ceremony::Login(auth))
        .map_err(|e| internal("starting passkey sign-in", e))?;
    Ok(Json(json!({ "id": id, "options": options })))
}

#[derive(Deserialize)]
pub struct LoginFinish {
    id: String,
    credential: PublicKeyCredential,
}

/// Second half: check the signature and start a session.
pub async fn login_finish(
    State(app): State<Shared>,
    Json(body): Json<LoginFinish>,
) -> Result<Response, ApiError> {
    let Some(Ceremony::Login(state)) = app.auth.finish(&body.id) else {
        return Err((StatusCode::GONE, "That sign-in prompt expired; try again"));
    };
    let rejected = (
        StatusCode::UNAUTHORIZED,
        "That passkey isn't one of OrphusBot's",
    );
    let result = app
        .auth
        .webauthn
        .finish_passkey_authentication(&body.credential, &state)
        .map_err(|e| {
            warn!("passkey sign-in failed: {e}");
            rejected
        })?;
    let found = passkeys(&app.db)
        .await
        .map_err(|e| internal("reading passkeys", e))?
        .into_iter()
        .find(|(_, p)| p.cred_id() == result.cred_id());
    // It was removed while the prompt was open.
    let Some((id, mut passkey)) = found else {
        return Err(rejected);
    };
    passkey.update_credential(&result);
    sqlx::query!(
        "update passkey set credential = $2, last_used_at = now() where id = $1",
        id,
        Jsonb(&passkey) as _
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("updating the passkey", e))?;
    let token = create_session(&app.db, Some(id), SESSION)
        .await
        .map_err(|e| internal("starting a session", e))?;
    let cookie = app.auth.cookie(&token, SESSION);
    Ok((StatusCode::NO_CONTENT, [(header::SET_COOKIE, cookie)]).into_response())
}

pub async fn logout(
    State(app): State<Shared>,
    Extension(session): Extension<Session>,
) -> Result<Response, ApiError> {
    sqlx::query!("delete from session where token_hash = $1", session.hash)
        .execute(&app.db)
        .await
        .map_err(|e| internal("signing out", e))?;
    let cookie = app.auth.cookie("", Duration::ZERO);
    Ok((StatusCode::NO_CONTENT, [(header::SET_COOKIE, cookie)]).into_response())
}

/// The owner's passkeys, for revoking a lost device.
pub async fn list_passkeys(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select id, name, created_at::text as "created_at!", last_used_at::text as last_used_at
           from passkey order by id"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing passkeys", e))?;
    let list: Vec<Value> = rows
        .into_iter()
        .map(|r| json!({ "id": r.id, "name": r.name, "created_at": r.created_at, "last_used_at": r.last_used_at }))
        .collect();
    Ok(Json(json!(list)))
}

#[derive(Deserialize)]
pub struct RemovePasskey {
    id: i64,
}

/// Removes a passkey and signs out every session it started.
pub async fn remove_passkey(
    State(app): State<Shared>,
    Json(body): Json<RemovePasskey>,
) -> Result<StatusCode, ApiError> {
    let removed = sqlx::query!("delete from passkey where id = $1", body.id)
        .execute(&app.db)
        .await
        .map_err(|e| internal("removing the passkey", e))?
        .rows_affected();
    if removed == 0 {
        return Err((StatusCode::NOT_FOUND, "No such passkey"));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use axum::body::{Body, to_bytes};
    use axum::http::Request as HttpRequest;
    use tower::ServiceExt;
    use webauthn_authenticator_rs::WebauthnAuthenticator;
    use webauthn_authenticator_rs::softpasskey::SoftPasskey;

    const ORIGIN: &str = "http://localhost:7480";
    const SETUP: &str = "setup-token-for-tests";

    pub(crate) fn app(db: PgPool) -> Shared {
        std::sync::Arc::new(crate::App {
            db,
            live: tokio::sync::broadcast::channel(16).0,
            rt: Mutex::default(),
            auth: Auth::new(ORIGIN, SETUP.into()).unwrap(),
            ui_dir: String::new(),
        })
    }

    /// Sends one request; returns the status, the session cookie it set (if any) and the body.
    pub(crate) async fn call(
        app: &Shared,
        path: &str,
        cookie: &str,
        body: Option<Value>,
    ) -> (StatusCode, Option<String>, Value) {
        let req = HttpRequest::builder()
            .method(if body.is_some() { "POST" } else { "GET" })
            .uri(path)
            .header(header::COOKIE, format!("{COOKIE}={cookie}"))
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.map(|b| b.to_string()).unwrap_or_default()))
            .unwrap();
        let res = crate::router(app.clone()).oneshot(req).await.unwrap();
        let status = res.status();
        let set = res
            .headers()
            .get(header::SET_COOKIE)
            .map(|v| v.to_str().unwrap().to_owned());
        let token = set.and_then(|c| {
            let v = c.split(';').next()?.split_once('=')?.1.to_owned();
            Some(v)
        });
        let bytes = to_bytes(res.into_body(), 1 << 20).await.unwrap();
        (
            status,
            token,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn setup(app: &Shared, token: &str) -> (StatusCode, Option<String>) {
        let req = HttpRequest::builder()
            .method("POST")
            .uri("/auth/setup")
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(Body::from(format!("token={token}")))
            .unwrap();
        let res = crate::router(app.clone()).oneshot(req).await.unwrap();
        let cookie = res.headers().get(header::SET_COOKIE).map(|v| {
            let v = v.to_str().unwrap();
            v[COOKIE.len() + 1..v.find(';').unwrap()].to_owned()
        });
        (res.status(), cookie)
    }

    #[sqlx::test]
    async fn setup_token_then_passkey_then_revoke(db: PgPool) {
        let app = app(db);
        let origin = Url::parse(ORIGIN).unwrap();
        let mut device = WebauthnAuthenticator::new(SoftPasskey::new(true));

        // Nothing under /api without a session.
        assert_eq!(
            call(&app, "/api/passkeys", "", None).await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            setup(&app, "wrong-token-xxxxxxxx").await.0,
            StatusCode::UNAUTHORIZED
        );
        let (status, setup_cookie) = setup(&app, SETUP).await;
        assert_eq!(status, StatusCode::SEE_OTHER);
        let setup_cookie = setup_cookie.unwrap();

        // Add a passkey from the setup session; the session is kept and upgraded.
        let (_, _, start) = call(&app, "/api/passkeys/start", &setup_cookie, Some(json!({}))).await;
        let options = serde_json::from_value(start["options"].clone()).unwrap();
        let credential = device.do_registration(origin.clone(), options).unwrap();
        let finish = json!({ "id": start["id"], "name": "laptop", "credential": credential });
        let (status, cookie, _) =
            call(&app, "/api/passkeys/finish", &setup_cookie, Some(finish)).await;
        assert_eq!(status, StatusCode::CREATED);
        assert_eq!(cookie.as_deref(), Some(setup_cookie.as_str()));
        let (_, _, state) = call(&app, "/auth/state", &setup_cookie, None).await;
        assert_eq!(
            state,
            json!({ "signed_in": true, "needs_passkey": false, "setup_open": false })
        );

        // The setup token is closed now.
        assert_eq!(setup(&app, SETUP).await.0, StatusCode::FORBIDDEN);

        // Sign in with the passkey.
        let (_, _, start) = call(&app, "/auth/login/start", "", Some(json!({}))).await;
        let options = serde_json::from_value(start["options"].clone()).unwrap();
        let credential = device.do_authentication(origin, options).unwrap();
        let finish = json!({ "id": start["id"], "credential": credential });
        let (status, cookie, _) = call(&app, "/auth/login/finish", "", Some(finish.clone())).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let cookie = cookie.unwrap();
        let (status, _, list) = call(&app, "/api/passkeys", &cookie, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(list[0]["name"], "laptop");

        // A prompt can't be answered twice.
        assert_eq!(
            call(&app, "/auth/login/finish", "", Some(finish)).await.0,
            StatusCode::GONE
        );

        // Removing the passkey signs out its sessions and reopens setup.
        let remove = json!({ "id": list[0]["id"] });
        assert_eq!(
            call(&app, "/api/passkeys/remove", &cookie, Some(remove))
                .await
                .0,
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            call(&app, "/api/passkeys", &cookie, None).await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            call(&app, "/api/passkeys", &setup_cookie, None).await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(setup(&app, SETUP).await.0, StatusCode::SEE_OTHER);
    }

    #[sqlx::test]
    async fn logout_ends_the_session(db: PgPool) {
        let app = app(db);
        let cookie = setup(&app, SETUP).await.1.unwrap();
        assert_eq!(
            call(&app, "/api/passkeys", &cookie, None).await.0,
            StatusCode::OK
        );
        assert_eq!(
            call(&app, "/api/logout", &cookie, Some(json!({}))).await.0,
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            call(&app, "/api/passkeys", &cookie, None).await.0,
            StatusCode::UNAUTHORIZED
        );
    }
}
