//! Node enrolment and the signed hello (DESIGN §4.1).
//!
//! The owner creates a one-time code while signed in. `orphusbot-node enrol
//! <code>` makes an Ed25519 key and sends the public half with the code. On
//! every later connection the server sends a fresh nonce and the node signs it.

use std::time::Duration;

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use openssl::pkey::{Id, PKey};
use openssl::sign::Verifier;
use orphusbot_proto::link_proof;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::auth::{digest, random_token};
use crate::{ApiError, Shared, internal, lock};

const CODE_LIFETIME: Duration = Duration::from_secs(10 * 60);

/// Same rule as the `node.name` check in migration 0005, for a friendlier error.
fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    name.len() <= 63
        && chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// Registers a node's public key with a one-time code. Re-enrolling a name
/// (a reinstalled machine) replaces its key. The error is shown to the node.
pub async fn enrol(db: &PgPool, code: &str, name: &str, public_key: &str) -> Result<(), String> {
    if !valid_name(name) {
        return Err("Node names are 1 to 63 letters, digits, '.', '_' or '-', starting with a letter or digit".into());
    }
    let key = hex::decode(public_key)
        .ok()
        .filter(|k| k.len() == 32)
        .ok_or("The public key isn't 32 bytes of hex")?;
    let server_error = |e: sqlx::Error| {
        warn!("enrolling a node: {e}");
        "The server couldn't enrol this node; see its log".to_owned()
    };
    let mut tx = db.begin().await.map_err(server_error)?;
    let used = sqlx::query!(
        "delete from enrolment_code where code_hash = $1 and expires_at > now()",
        digest(code)
    )
    .execute(&mut *tx)
    .await
    .map_err(server_error)?
    .rows_affected();
    if used == 0 {
        return Err("That enrolment code is wrong, used or expired; create a new one".into());
    }
    sqlx::query!(
        "insert into node (name, public_key) values ($1, $2)
         on conflict (name) do update set public_key = excluded.public_key, last_seen_at = null",
        name,
        key
    )
    .execute(&mut *tx)
    .await
    .map_err(server_error)?;
    tx.commit().await.map_err(server_error)
}

/// Checks a hello: `signature` must be `name`'s key signing [`link_proof`].
pub async fn verify(db: &PgPool, name: &str, nonce: &str, signature: &str) -> sqlx::Result<bool> {
    let key = sqlx::query_scalar!("select public_key from node where name = $1", name)
        .fetch_optional(db)
        .await?;
    let (Some(key), Ok(signature)) = (key, hex::decode(signature)) else {
        return Ok(false);
    };
    let proof = link_proof(name, nonce);
    let ok = PKey::public_key_from_raw_bytes(&key, Id::ED25519)
        .and_then(|key| {
            Verifier::new_without_digest(&key)?.verify_oneshot(&signature, proof.as_bytes())
        })
        .unwrap_or(false);
    if ok {
        sqlx::query!("update node set last_seen_at = now() where name = $1", name)
            .execute(db)
            .await?;
    }
    Ok(ok)
}

/// A one-time enrolment code for `orphusbot-node enrol`.
pub async fn create_code(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let code = random_token().map_err(|e| internal("creating an enrolment code", e))?;
    let stored = async {
        sqlx::query!("delete from enrolment_code where expires_at <= now()")
            .execute(&app.db)
            .await?;
        sqlx::query!(
            "insert into enrolment_code (code_hash, expires_at)
             values ($1, now() + make_interval(secs => $2))",
            digest(&code),
            CODE_LIFETIME.as_secs_f64()
        )
        .execute(&app.db)
        .await
    };
    stored
        .await
        .map_err(|e| internal("storing an enrolment code", e))?;
    Ok(Json(
        json!({ "code": code, "expires_in_secs": CODE_LIFETIME.as_secs() }),
    ))
}

/// Enrolled nodes, for removing a lost or retired machine.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select id, name, created_at::text as "created_at!", last_seen_at::text as last_seen_at
           from node order by name"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing nodes", e))?;
    let list: Vec<Value> = rows
        .into_iter()
        .map(|r| json!({ "id": r.id, "name": r.name, "created_at": r.created_at, "last_seen_at": r.last_seen_at }))
        .collect();
    Ok(Json(json!(list)))
}

#[derive(Deserialize)]
pub struct RemoveNode {
    id: i64,
}

/// Removes a node's key and drops its link if it's connected.
pub async fn remove(
    State(app): State<Shared>,
    Json(body): Json<RemoveNode>,
) -> Result<StatusCode, ApiError> {
    let name = sqlx::query_scalar!("delete from node where id = $1 returning name", body.id)
        .fetch_optional(&app.db)
        .await
        .map_err(|e| internal("removing the node", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such node"))?;
    if let Some(link) = lock(&app.rt).node.as_ref().filter(|n| n.name == name) {
        link.kick.notify_one();
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use openssl::pkey::Private;
    use openssl::sign::Signer;

    fn keypair() -> (PKey<Private>, String) {
        let key = PKey::generate_ed25519().unwrap();
        let public = hex::encode(key.raw_public_key().unwrap());
        (key, public)
    }

    fn sign(key: &PKey<Private>, name: &str, nonce: &str) -> String {
        let proof = link_proof(name, nonce);
        let mut signer = Signer::new_without_digest(key).unwrap();
        hex::encode(signer.sign_oneshot_to_vec(proof.as_bytes()).unwrap())
    }

    async fn code(db: &PgPool, lifetime_secs: f64) -> String {
        let code = random_token().unwrap();
        sqlx::query!(
            "insert into enrolment_code (code_hash, expires_at) values ($1, now() + make_interval(secs => $2))",
            digest(&code),
            lifetime_secs
        )
        .execute(db)
        .await
        .unwrap();
        code
    }

    #[sqlx::test]
    async fn enrolled_key_passes_the_challenge_and_others_fail(db: PgPool) {
        let (key, public) = keypair();
        let c = code(&db, 600.0).await;
        enrol(&db, &c, "laptop", &public).await.unwrap();

        let sig = sign(&key, "laptop", "nonce-1");
        assert!(verify(&db, "laptop", "nonce-1", &sig).await.unwrap());
        // A signature is only good for its own nonce and name.
        assert!(!verify(&db, "laptop", "nonce-2", &sig).await.unwrap());
        assert!(!verify(&db, "gpu-box", "nonce-1", &sig).await.unwrap());
        // Another key can't pose as the laptop.
        let (other, _) = keypair();
        assert!(
            !verify(&db, "laptop", "nonce-3", &sign(&other, "laptop", "nonce-3"))
                .await
                .unwrap()
        );
        assert!(!verify(&db, "laptop", "nonce-4", "not hex").await.unwrap());
    }

    #[sqlx::test]
    async fn codes_work_once_and_expire(db: PgPool) {
        let (_, public) = keypair();
        let c = code(&db, 600.0).await;
        enrol(&db, &c, "laptop", &public).await.unwrap();
        assert!(
            enrol(&db, &c, "laptop", &public).await.is_err(),
            "used twice"
        );

        let old = code(&db, -1.0).await;
        assert!(
            enrol(&db, &old, "gpu-box", &keypair().1).await.is_err(),
            "expired"
        );
        assert!(
            enrol(&db, "made-up", "gpu-box", &keypair().1)
                .await
                .is_err(),
            "unknown"
        );

        let c = code(&db, 600.0).await;
        assert!(enrol(&db, &c, "-bad name", &keypair().1).await.is_err());
        assert!(
            enrol(&db, &c, "gpu-box", "abcd").await.is_err(),
            "short key"
        );
    }

    #[sqlx::test]
    async fn re_enrolling_a_name_replaces_its_key(db: PgPool) {
        let (old, old_public) = keypair();
        enrol(&db, &code(&db, 600.0).await, "laptop", &old_public)
            .await
            .unwrap();
        let (new, new_public) = keypair();
        enrol(&db, &code(&db, 600.0).await, "laptop", &new_public)
            .await
            .unwrap();
        assert!(
            !verify(&db, "laptop", "n", &sign(&old, "laptop", "n"))
                .await
                .unwrap()
        );
        assert!(
            verify(&db, "laptop", "n", &sign(&new, "laptop", "n"))
                .await
                .unwrap()
        );
    }

    #[test]
    fn names() {
        assert!(valid_name("gpu-box.home_1"));
        assert!(!valid_name(""));
        assert!(!valid_name(".hidden"));
        assert!(!valid_name("has space"));
        assert!(!valid_name(&"a".repeat(64)));
    }
}
