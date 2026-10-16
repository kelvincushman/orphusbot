//! Connections (DESIGN §11, PRD B-INT-01): MCP servers the owner adds and
//! grants to bots. A granted server reaches the bot's engine through its
//! `BotSpec`; Orphus's MCP adapter loads its tools lazily behind one `mcp` tool.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use orphusbot_proto::McpServer;
use serde::Deserialize;
use serde_json::{Value, json};
use tracing::warn;

use crate::{ApiError, App, Shared, internal, secrets};

pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select c.id, c.name, c.url, c.secret_id is not null as "has_token!",
                  coalesce(array_agg(b.slug order by b.slug) filter (where b.slug is not null), '{}') as "bots!"
           from connection c left join bot_connection g on g.connection_id = c.id
           left join bot b on b.id = g.bot_id
           group by c.id order by c.name"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing connections", e))?;
    let list: Vec<Value> = rows
        .into_iter()
        .map(|r| json!({ "id": r.id, "name": r.name, "url": r.url, "has_token": r.has_token, "bots": r.bots }))
        .collect();
    Ok(Json(
        json!({ "connections": list, "secrets": app.secrets.enabled() }),
    ))
}

#[derive(Deserialize)]
pub struct New {
    name: String,
    url: String,
    #[serde(default)]
    token: String,
}

pub async fn create(
    State(app): State<Shared>,
    Json(new): Json<New>,
) -> Result<StatusCode, ApiError> {
    let name = new.name.trim().to_lowercase();
    let (url, token) = (new.url.trim(), new.token.trim());
    let name_ok = (1..=24).contains(&name.len())
        && name.starts_with(|c: char| c.is_ascii_lowercase())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    match () {
        _ if !name_ok => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "Name it with lowercase letters, digits and _, starting with a letter (up to 24)",
            ));
        }
        _ if name.starts_with("mcp") => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "Pick a name that doesn't start with mcp",
            ));
        }
        _ if !(url.starts_with("https://") || url.starts_with("http://")) || url.len() > 500 => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "Give the server's http:// or https:// address",
            ));
        }
        _ if !token.is_empty() && token.len() < secrets::MIN_LEN => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "That token is too short to be a real one",
            ));
        }
        _ => {}
    }
    let taken = sqlx::query_scalar!(
        "select exists(select 1 from connection where name = $1) as \"taken!\"",
        name
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("adding a connection", e))?;
    if taken {
        return Err((
            StatusCode::CONFLICT,
            "There's already a connection with that name",
        ));
    }
    let secret = match token {
        "" => None,
        token => Some(
            app.secrets
                .store(&app.db, token)
                .await
                .map_err(|e| internal("storing a token", e))?
                .ok_or((
                    StatusCode::CONFLICT,
                    "Set ORPHUSBOT_SECRET_KEY_FILE on the server to store tokens",
                ))?,
        ),
    };
    sqlx::query!(
        "insert into connection (name, url, secret_id) values ($1, $2, $3)",
        name,
        url,
        secret
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("adding a connection", e))?;
    Ok(StatusCode::CREATED)
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

pub async fn delete(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<StatusCode, ApiError> {
    let secret = sqlx::query_scalar!(
        "delete from connection where id = $1 returning secret_id",
        by.id
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("removing a connection", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such connection"))?;
    if let Some(secret) = secret {
        sqlx::query!("delete from secret where id = $1", secret)
            .execute(&app.db)
            .await
            .map_err(|e| internal("removing a token", e))?;
        // ponytail: a removed token stops being redacted; keep it if old output must stay hidden.
        app.secrets
            .load(&app.db)
            .await
            .map_err(|e| internal("reloading secrets", e))?;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct Grant {
    id: i64,
    bot: String,
    granted: bool,
}

/// Lets a bot use a connection, or stops it. Takes effect on its next run.
pub async fn grant(
    State(app): State<Shared>,
    Json(g): Json<Grant>,
) -> Result<StatusCode, ApiError> {
    let changed = if g.granted {
        sqlx::query!(
            "insert into bot_connection (bot_id, connection_id)
             select b.id, c.id from bot b, connection c where b.slug = $1 and c.id = $2
             on conflict do nothing",
            g.bot,
            g.id
        )
        .execute(&app.db)
        .await
    } else {
        sqlx::query!(
            "delete from bot_connection where connection_id = $2 and bot_id = (select id from bot where slug = $1)",
            g.bot,
            g.id
        )
        .execute(&app.db)
        .await
    };
    changed.map_err(|e| internal("changing a grant", e))?;
    Ok(StatusCode::NO_CONTENT)
}

/// The servers a bot may use, with their tokens, for its engine.
pub async fn for_bot(app: &App, slug: &str) -> Vec<McpServer> {
    let rows = sqlx::query!(
        "select c.name, c.url, c.secret_id from connection c
         join bot_connection g on g.connection_id = c.id join bot b on b.id = g.bot_id
         where b.slug = $1 order by c.name",
        slug
    )
    .fetch_all(&app.db)
    .await;
    let rows = match rows {
        Ok(rows) => rows,
        Err(e) => {
            warn!("reading a bot's connections: {e}");
            return Vec::new();
        }
    };
    let mut servers = Vec::new();
    for r in rows {
        let token = match r.secret_id {
            None => None,
            Some(id) => match app.secrets.reveal(&app.db, id).await {
                Ok(token) => Some(token),
                Err(e) => {
                    warn!(connection = %r.name, "leaving out a connection whose token can't be read: {e:#}");
                    continue;
                }
            },
        };
        servers.push(McpServer {
            name: r.name,
            url: r.url,
            token,
        });
    }
    servers
}
