//! Fleets the owner sets up (DESIGN §11.2): Orphus fleet blueprints kept here
//! and sent with every run, so `/fleet <name> <task>` finds them on any node.
//!
//! The server only checks the name and size and that the file names itself;
//! Orphus validates the rest when it reads it (`/fleet validate <name>`).

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use orphusbot_proto::{FleetFile, is_fleet_name};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, Shared, internal};

const MAX_YAML: usize = 64 * 1024;

/// The value of a top-level `key:` line, unquoted, for the list's summary.
fn top_level<'a>(yaml: &'a str, key: &str) -> Option<&'a str> {
    yaml.lines().find_map(|l| {
        let v = l.strip_prefix(key)?.strip_prefix(':')?.trim();
        Some(v.trim_matches(|c| c == '"' || c == '\''))
    })
}

/// Why this blueprint can't be saved under `name`, if it can't.
fn problem(name: &str, yaml: &str) -> Option<&'static str> {
    if !is_fleet_name(name) {
        Some("A fleet name is lower-case letters, digits, - and _, starting with a letter or digit")
    } else if yaml.trim().is_empty() || yaml.len() > MAX_YAML {
        Some("A fleet file is between 1 byte and 64 KB")
    } else if top_level(yaml, "name") != Some(name) {
        Some("The file's own `name:` line must match the fleet's name")
    } else {
        None
    }
}

/// Every fleet, for a run.
pub async fn all(db: &PgPool) -> Vec<FleetFile> {
    sqlx::query_as!(FleetFile, "select name, yaml from fleet order by name")
        .fetch_all(db)
        .await
        .unwrap_or_else(|e| {
            warn!("listing fleets for a run: {e}");
            Vec::new()
        })
}

pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!("select name, yaml, updated_at from fleet order by name")
        .fetch_all(&app.db)
        .await
        .map_err(|e| internal("listing fleets", e))?;
    Ok(Json(json!(
        rows.into_iter()
            .map(|r| json!({ "name": r.name, "description": top_level(&r.yaml, "description").unwrap_or(""),
                             "yaml": r.yaml, "updated_at": r.updated_at.to_rfc3339() }))
            .collect::<Vec<_>>()
    )))
}

#[derive(Deserialize)]
pub struct Save {
    name: String,
    yaml: String,
}

pub async fn save(State(app): State<Shared>, Json(f): Json<Save>) -> Result<StatusCode, ApiError> {
    if let Some(why) = problem(&f.name, &f.yaml) {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, why));
    }
    sqlx::query!(
        "insert into fleet (name, yaml) values ($1, $2)
         on conflict (name) do update set yaml = excluded.yaml, updated_at = now()",
        f.name,
        f.yaml
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("saving a fleet", e))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct ByName {
    name: String,
}

pub async fn delete(
    State(app): State<Shared>,
    Json(by): Json<ByName>,
) -> Result<StatusCode, ApiError> {
    let done = sqlx::query!("delete from fleet where name = $1", by.name)
        .execute(&app.db)
        .await
        .map_err(|e| internal("deleting a fleet", e))?;
    if done.rows_affected() == 0 {
        return Err((StatusCode::NOT_FOUND, "No such fleet"));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_name_size_and_self_name() {
        let ok = "# A council\nname: council\ndescription: \"Four argue\"\nteams: {}\n";
        assert_eq!(problem("council", ok), None);
        assert_eq!(top_level(ok, "description"), Some("Four argue"));
        assert!(problem("Council", ok).is_some());
        assert!(
            problem("other", ok).is_some(),
            "file names a different fleet"
        );
        assert!(problem("council", "teams: {}\n").is_some(), "no name line");
        assert!(
            problem("council", "  name: council\n").is_some(),
            "only top level counts"
        );
        assert!(
            problem(
                "council",
                &format!("name: council\n{}", "#".repeat(MAX_YAML))
            )
            .is_some()
        );
    }
}
