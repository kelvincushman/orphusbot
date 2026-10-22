//! The shared vault (DESIGN §11.8, D-054): one folder of Markdown that Kelvin
//! edits in Obsidian and the bots read and write as their team folder. The
//! server serves it over WebDAV at `/vault/`, so Obsidian on the laptop and the
//! phone syncs it (the Remotely Save plugin) through the public address, with
//! no NetBird. Its own password (`ORPHUSBOT_VAULT_PASSWORD`, Basic auth over
//! HTTPS) keeps it separate from app sessions, which Obsidian can't use.

use std::sync::LazyLock;

use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use dav_server::{DavConfig, DavHandler, fakels::FakeLs, localfs::LocalFs};
use subtle::ConstantTimeEq;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

/// The vault: the team folder on this machine (`ORPHUSBOT_VAULT_DIR`).
static DAV: LazyLock<Option<DavHandler>> = LazyLock::new(|| {
    env("ORPHUSBOT_VAULT_DIR").map(|dir| {
        DavConfig::new()
            .filesystem(LocalFs::new(dir, false, false, false))
            // Obsidian's sync plugins and Windows clients ask for locks.
            .locksystem(FakeLs::new())
            .strip_prefix("/vault")
            .build_handler()
    })
});

/// Whether the request carries the vault's password (any user name).
pub fn authorized(headers: &HeaderMap, password: &str) -> bool {
    let Some(given) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Basic "))
        .and_then(|b| openssl::base64::decode_block(b.trim()).ok())
    else {
        return false;
    };
    let Some(pass) = given
        .iter()
        .position(|&b| b == b':')
        .map(|i| &given[i + 1..])
    else {
        return false;
    };
    !password.is_empty() && bool::from(pass.ct_eq(password.as_bytes()))
}

/// Sends anything under `/vault` to the vault, whatever its method.
pub async fn first(req: Request, next: axum::middleware::Next) -> Response {
    let path = req.uri().path();
    if path == "/vault" || path.starts_with("/vault/") {
        serve(req).await
    } else {
        next.run(req).await
    }
}

/// Every WebDAV method under `/vault`.
pub async fn serve(req: Request) -> Response {
    let (Some(dav), Some(password)) = (DAV.as_ref(), env("ORPHUSBOT_VAULT_PASSWORD")) else {
        return (StatusCode::NOT_FOUND, "The vault isn't set up").into_response();
    };
    if !authorized(req.headers(), &password) {
        return (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Basic realm=\"OrphusBot vault\"")],
        )
            .into_response();
    }
    dav.handle(req).await.map(Body::new)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn basic(user_pass: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        let value = format!(
            "Basic {}",
            openssl::base64::encode_block(user_pass.as_bytes())
        );
        h.insert(header::AUTHORIZATION, value.parse().unwrap());
        h
    }

    #[test]
    fn only_the_vault_password_opens_it() {
        assert!(authorized(&basic("kelvin:s3cret-pass"), "s3cret-pass"));
        assert!(authorized(&basic(":s3cret-pass"), "s3cret-pass"));
        assert!(!authorized(&basic("kelvin:wrong"), "s3cret-pass"));
        assert!(!authorized(&basic("kelvin:"), ""));
        assert!(!authorized(&HeaderMap::new(), "s3cret-pass"));
        let mut bearer = HeaderMap::new();
        bearer.insert(header::AUTHORIZATION, "Bearer s3cret-pass".parse().unwrap());
        assert!(!authorized(&bearer, "s3cret-pass"));
    }
}
