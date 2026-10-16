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
        r#"select c.id, c.name, c.url, c.command, c.args, c.token_env, c.secret_id is not null as "has_token!",
                  c.oauth is not null and c.secret_id is not null as "signed_in!",
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
        .map(|r| {
            // What it is, in one line: the address, or the command it runs.
            let target = match (&r.url, &r.command) {
                (Some(url), _) => url.clone(),
                (None, Some(cmd)) => std::iter::once(cmd.clone()).chain(r.args.iter().cloned()).collect::<Vec<_>>().join(" "),
                (None, None) => String::new(),
            };
            json!({ "id": r.id, "name": r.name, "url": r.url, "command": r.command, "target": target,
                    "token_env": r.token_env, "has_token": r.has_token, "signed_in": r.signed_in, "bots": r.bots })
        })
        .collect();
    Ok(Json(
        json!({ "connections": list, "secrets": app.secrets.enabled() }),
    ))
}

#[derive(Deserialize)]
pub struct New {
    name: String,
    /// An http(s) address, or a command line the node runs (`npx -y some-mcp-server`).
    url: String,
    #[serde(default)]
    token: String,
    /// For a command: the environment variable it reads the token from.
    #[serde(default)]
    token_env: String,
}

/// A command line, split on spaces (no quoting): the program and its arguments.
// ponytail: no shell quoting, so an argument can't contain a space; add it if a server needs one.
fn command_line(text: &str) -> Result<(String, Vec<String>), &'static str> {
    let mut words = text.split_whitespace().map(str::to_owned);
    let program = words
        .next()
        .ok_or("Give the server's address or the command that runs it")?;
    let args: Vec<String> = words.collect();
    let program_ok = program.len() <= 100
        && program
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c));
    match () {
        _ if !program_ok => Err("The program name can only have letters, digits and . _ / -"),
        _ if args.len() > 20 || args.iter().any(|a| a.len() > 300) => {
            Err("That command has too many or too long arguments")
        }
        _ => Ok((program, args)),
    }
}

pub async fn create(
    State(app): State<Shared>,
    Json(new): Json<New>,
) -> Result<StatusCode, ApiError> {
    let name = new.name.trim().to_lowercase();
    let (url, token, token_env) = (new.url.trim(), new.token.trim(), new.token_env.trim());
    let is_url = url.starts_with("https://") || url.starts_with("http://");
    let command = match is_url {
        true => None,
        false => Some(command_line(url).map_err(|why| (StatusCode::UNPROCESSABLE_ENTITY, why))?),
    };
    let env_ok = token_env.is_empty()
        || (token_env.len() <= 64
            && token_env.starts_with(|c: char| c.is_ascii_uppercase() || c == '_')
            && token_env
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'));
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
        _ if url.len() > 500 => {
            return Err((StatusCode::UNPROCESSABLE_ENTITY, "That address is too long"));
        }
        _ if !env_ok => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "The token variable is capitals, digits and _, like GITHUB_TOKEN",
            ));
        }
        _ if command.is_some() && !token.is_empty() && token_env.is_empty() => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "Say which variable the command reads its token from",
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
    let (program, args) = command.unzip();
    sqlx::query!(
        "insert into connection (name, url, command, args, token_env, secret_id) values ($1, $2, $3, $4, $5, $6)",
        name,
        is_url.then_some(url),
        program,
        &args.unwrap_or_default(),
        (!token_env.is_empty()).then_some(token_env),
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
        "select c.id, c.name, c.url, c.command, c.args, c.token_env, c.secret_id from connection c
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
        // A signed-in server's access token may need refreshing first.
        crate::oauth::fresh(app, r.id).await;
        let secret_id = sqlx::query_scalar!("select secret_id from connection where id = $1", r.id)
            .fetch_one(&app.db)
            .await
            .unwrap_or(r.secret_id);
        let token = match secret_id {
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
            url: r.url.unwrap_or_default(),
            command: r.command,
            args: r.args,
            token_env: r.token_env,
            token,
        });
    }
    servers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_lines() {
        assert_eq!(
            command_line("  npx -y @modelcontextprotocol/server-github ").unwrap(),
            (
                "npx".to_owned(),
                vec![
                    "-y".to_owned(),
                    "@modelcontextprotocol/server-github".to_owned()
                ]
            )
        );
        assert!(command_line("").is_err());
        assert!(
            command_line("rm;reboot now").is_err(),
            "the program is a plain name"
        );
        assert!(command_line(&format!("npx {}", "a ".repeat(21))).is_err());
    }
}
