//! Signing in to an MCP server with OAuth (DESIGN §11, the MCP authorization
//! spec): the server finds the provider through the resource's metadata,
//! registers itself as a public client, and sends the owner to sign in with
//! PKCE. The provider sends them back to `/oauth/callback`; the server swaps
//! the code for tokens and keeps them as secrets. Before a run it refreshes an
//! access token that is about to expire. Nodes only ever see the access token.

use anyhow::{Context, bail};
use axum::Json;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Redirect};
use chrono::{Duration, Utc};
use reqwest::Url;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tracing::warn;

use crate::auth::random_token;
use crate::{ApiError, App, Shared, internal};

/// Where the provider's endpoints are.
#[derive(Debug, PartialEq)]
struct Provider {
    authorize: String,
    token: String,
    register: Option<String>,
}

fn http() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .unwrap_or_default()
}

async fn get_json(url: &str) -> Option<Value> {
    let res = http().get(url).send().await.ok()?;
    if !res.status().is_success() {
        return None;
    }
    res.json().await.ok()
}

/// RFC 9728 resource metadata names the authorization server; RFC 8414 metadata
/// names its endpoints. Each falls back as the MCP spec says.
async fn discover(mcp_url: &str) -> anyhow::Result<Provider> {
    let url = Url::parse(mcp_url).context("the connection's address isn't a URL")?;
    let origin = url.origin().ascii_serialization();
    let path = url.path().trim_end_matches('/');
    let mut server = origin.clone();
    for prm in [
        format!("{origin}/.well-known/oauth-protected-resource{path}"),
        format!("{origin}/.well-known/oauth-protected-resource"),
    ] {
        if let Some(found) = get_json(&prm).await
            && let Some(first) = found["authorization_servers"][0].as_str()
        {
            server = first.trim_end_matches('/').to_owned();
            break;
        }
    }
    let as_url = Url::parse(&server).context("the authorization server isn't a URL")?;
    let as_origin = as_url.origin().ascii_serialization();
    let as_path = as_url.path().trim_end_matches('/');
    for meta in [
        format!("{as_origin}/.well-known/oauth-authorization-server{as_path}"),
        format!("{as_origin}/.well-known/openid-configuration{as_path}"),
        format!("{server}/.well-known/openid-configuration"),
    ] {
        if let Some(m) = get_json(&meta).await
            && let (Some(authorize), Some(token)) = (
                m["authorization_endpoint"].as_str(),
                m["token_endpoint"].as_str(),
            )
        {
            return Ok(Provider {
                authorize: authorize.to_owned(),
                token: token.to_owned(),
                register: m["registration_endpoint"].as_str().map(str::to_owned),
            });
        }
    }
    Ok(Provider {
        authorize: format!("{server}/authorize"),
        token: format!("{server}/token"),
        register: Some(format!("{server}/register")),
    })
}

/// `application/x-www-form-urlencoded`, as token endpoints want.
fn form(pairs: &[(&str, &str)]) -> String {
    reqwest::Url::parse_with_params("http://form.invalid/", pairs)
        .ok()
        .and_then(|u| u.query().map(str::to_owned))
        .unwrap_or_default()
}

/// RFC 7636 S256: base64url(sha256(verifier)) without padding.
fn challenge(verifier: &str) -> String {
    openssl::base64::encode_block(&Sha256::digest(verifier.as_bytes()))
        .replace('+', "-")
        .replace('/', "_")
        .trim_end_matches('=')
        .to_owned()
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

/// Starts a sign-in: returns the provider's page to send the owner to.
pub async fn start(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<Json<Value>, ApiError> {
    if !app.secrets.enabled() {
        return Err((
            StatusCode::CONFLICT,
            "Set ORPHUSBOT_SECRET_KEY_FILE on the server to keep sign-ins",
        ));
    }
    let url = sqlx::query_scalar!("select url from connection where id = $1", by.id)
        .fetch_optional(&app.db)
        .await
        .map_err(|e| internal("reading a connection", e))?
        .flatten()
        .ok_or((
            StatusCode::NOT_FOUND,
            "Only a connection with an address can sign in",
        ))?;
    let redirect = format!("{}/oauth/callback", app.auth.origin);
    let begun = async {
        let provider = discover(&url).await?;
        let register = provider
            .register
            .as_deref()
            .context("the provider doesn't let new apps register")?;
        let registered: Value = http()
            .post(register)
            .json(&json!({
                "client_name": "OrphusBot",
                "redirect_uris": [redirect],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let client_id = registered["client_id"]
            .as_str()
            .context("the provider didn't give a client_id")?
            .to_owned();
        let (state, verifier) = (random_token()?, random_token()?);
        let mut page = Url::parse(&provider.authorize)?;
        page.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", &client_id)
            .append_pair("redirect_uri", &redirect)
            .append_pair("code_challenge", &challenge(&verifier))
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &state)
            .append_pair("resource", &url);
        anyhow::Ok((provider, client_id, state, verifier, page))
    };
    let (provider, client_id, state, verifier, page) = begun.await.map_err(|e| {
        warn!("starting a sign-in: {e:#}");
        (
            StatusCode::BAD_GATEWAY,
            "Couldn't start signing in to that server; see the server log",
        )
    })?;
    let oauth = json!({ "client_id": client_id, "token_endpoint": provider.token });
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("starting a sign-in", e))?;
    sqlx::query!("delete from oauth_flow where created_at < now() - interval '10 minutes'")
        .execute(&mut *tx)
        .await
        .map_err(|e| internal("starting a sign-in", e))?;
    sqlx::query!(
        "update connection set oauth = $2 where id = $1",
        by.id,
        oauth
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("starting a sign-in", e))?;
    sqlx::query!(
        "insert into oauth_flow (state, connection_id, verifier) values ($1, $2, $3)",
        state,
        by.id,
        verifier
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("starting a sign-in", e))?;
    tx.commit()
        .await
        .map_err(|e| internal("starting a sign-in", e))?;
    Ok(Json(json!({ "url": page.as_str() })))
}

#[derive(Deserialize)]
pub struct Back {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// The provider sends the owner back here. Public: a browser coming back from
/// another site doesn't send the `SameSite=Strict` session cookie, so the
/// single-use, ten-minute `state` is what proves the sign-in was started here.
pub async fn callback(State(app): State<Shared>, Query(back): Query<Back>) -> impl IntoResponse {
    let done = async {
        if let Some(error) = back.error {
            bail!("the provider said {error}");
        }
        let (code, state) = (
            back.code.context("no code")?,
            back.state.context("no state")?,
        );
        let flow = sqlx::query!(
            "delete from oauth_flow where state = $1 and created_at > now() - interval '10 minutes'
             returning connection_id, verifier",
            state
        )
        .fetch_optional(&app.db)
        .await?
        .context("that sign-in expired or was already used")?;
        let c = sqlx::query!(
            r#"select name, url as "url!", oauth as "oauth!" from connection where id = $1"#,
            flow.connection_id
        )
        .fetch_one(&app.db)
        .await?;
        let redirect = format!("{}/oauth/callback", app.auth.origin);
        let body = form(&[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("redirect_uri", &redirect),
            (
                "client_id",
                c.oauth["client_id"].as_str().unwrap_or_default(),
            ),
            ("code_verifier", &flow.verifier),
            ("resource", &c.url),
        ]);
        let tokens = exchange(c.oauth["token_endpoint"].as_str().unwrap_or_default(), body).await?;
        keep(&app, flow.connection_id, &tokens).await?;
        anyhow::Ok(c.name)
    };
    match done.await {
        Ok(name) => Redirect::to(&format!("/?connected={name}")),
        Err(e) => {
            warn!("finishing a sign-in: {e:#}");
            Redirect::to("/?connect_error=1")
        }
    }
}

async fn exchange(token_endpoint: &str, body: String) -> anyhow::Result<Value> {
    let res = http()
        .post(token_endpoint)
        .header("content-type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await?;
    let status = res.status();
    let tokens: Value = res.json().await.unwrap_or_default();
    if !status.is_success() || tokens["access_token"].as_str().is_none() {
        bail!("the token endpoint answered {status}: {}", tokens["error"]);
    }
    Ok(tokens)
}

/// Stores new tokens in place of the old ones.
async fn keep(app: &App, connection: i64, tokens: &Value) -> anyhow::Result<()> {
    let access = tokens["access_token"].as_str().context("no access token")?;
    let access_id = app
        .secrets
        .store(&app.db, access)
        .await?
        .context("no master key")?;
    let refresh_id = match tokens["refresh_token"].as_str() {
        Some(r) => Some(
            app.secrets
                .store(&app.db, r)
                .await?
                .context("no master key")?,
        ),
        None => None,
    };
    let expires = tokens["expires_in"]
        .as_i64()
        .map(|s| Utc::now() + Duration::seconds(s));
    let old = sqlx::query!(
        "update connection c set secret_id = $2, refresh_secret_id = coalesce($3, c.refresh_secret_id),
                token_expires_at = $4
         from connection before where c.id = $1 and before.id = c.id
         returning before.secret_id as old_access, before.refresh_secret_id as old_refresh",
        connection,
        access_id,
        refresh_id,
        expires
    )
    .fetch_one(&app.db)
    .await?;
    let stale = [
        old.old_access,
        old.old_refresh.filter(|_| refresh_id.is_some()),
    ];
    for id in stale.into_iter().flatten() {
        sqlx::query!("delete from secret where id = $1", id)
            .execute(&app.db)
            .await?;
    }
    app.secrets.load(&app.db).await?;
    Ok(())
}

/// Refreshes the access token if it expires within a minute. Errors are logged;
/// the run goes ahead with what there is.
pub async fn fresh(app: &App, connection: i64) {
    let due = sqlx::query!(
        r#"select oauth as "oauth!", refresh_secret_id as "refresh!", url as "url!" from connection
           where id = $1 and oauth is not null and refresh_secret_id is not null
             and token_expires_at < now() + interval '1 minute'"#,
        connection
    )
    .fetch_optional(&app.db)
    .await;
    let Ok(Some(c)) = due else {
        return;
    };
    let refreshed = async {
        let refresh = app.secrets.reveal(&app.db, c.refresh).await?;
        let body = form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh),
            (
                "client_id",
                c.oauth["client_id"].as_str().unwrap_or_default(),
            ),
            ("resource", &c.url),
        ]);
        let tokens = exchange(c.oauth["token_endpoint"].as_str().unwrap_or_default(), body).await?;
        keep(app, connection, &tokens).await
    };
    if let Err(e) = refreshed.await {
        warn!(connection, "refreshing a sign-in: {e:#}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_and_forms() {
        // RFC 7636 appendix B.
        assert_eq!(
            challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert_eq!(form(&[("a", "x y"), ("b", "1&2")]), "a=x+y&b=1%262");
    }
}
