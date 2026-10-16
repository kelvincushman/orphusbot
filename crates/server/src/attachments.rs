//! Pictures and files the owner sends a bot (DESIGN §12.1). The app uploads
//! each one first (`POST /api/attachments?bot=…&name=…`, the bytes as the body),
//! then sends the message with their ids. The run carries them to its node,
//! which saves them in the bot's computer under `inbox/` and hands pictures
//! to the model as images.

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::IntoResponse;
use orphusbot_proto::SentFile;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;

use crate::{ApiError, Shared, artifacts, internal};

/// Per file, and for everything sent with one message: it all travels to the
/// node in one frame.
pub const MAX_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_FILES: usize = 10;

#[derive(Deserialize)]
pub struct Upload {
    bot: String,
    name: String,
}

pub async fn upload(
    State(app): State<Shared>,
    Query(u): Query<Upload>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<axum::Json<Value>, ApiError> {
    if body.is_empty() || body.len() > MAX_BYTES {
        return Err((StatusCode::PAYLOAD_TOO_LARGE, "A file can be up to 10 MB"));
    }
    let name = artifacts::plain_name(&u.name);
    let mime = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .filter(|m| !m.is_empty() && *m != "application/octet-stream")
        .map_or_else(|| guess_mime(&name).to_owned(), str::to_owned);
    let id = sqlx::query_scalar!(
        "insert into attachment (bot_id, name, mime, content)
         select id, $2, $3, $4 from bot where slug = $1 returning id",
        u.bot,
        name,
        mime,
        body.as_ref()
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("keeping an upload", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such bot"))?;
    Ok(axum::Json(
        json!({ "id": id, "name": name, "size": body.len(), "mime": mime }),
    ))
}

fn guess_mime(name: &str) -> &'static str {
    let ext = name
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "txt" | "md" | "csv" | "json" => "text/plain",
        _ => "application/octet-stream",
    }
}

/// The attachments for `bot` with these ids, checked: they must be its own,
/// at most ten, and together at most 10 MB.
pub async fn check(
    db: &PgPool,
    bot: &str,
    ids: &[i64],
) -> Result<Vec<(i64, String, u64, bool)>, ApiError> {
    if ids.len() > MAX_FILES {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send at most ten files at once",
        ));
    }
    let rows = sqlx::query!(
        r#"select a.id, a.name, a.mime, octet_length(a.content)::bigint as "size!" from attachment a
           join bot b on b.id = a.bot_id where b.slug = $1 and a.id = any($2) order by a.id"#,
        bot,
        ids
    )
    .fetch_all(db)
    .await
    .map_err(|e| internal("reading attachments", e))?;
    if rows.len() != ids.len() {
        return Err((
            StatusCode::NOT_FOUND,
            "An attachment is missing; upload it again",
        ));
    }
    let total: i64 = rows.iter().map(|r| r.size).sum();
    if total as usize > MAX_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            "Files sent together can be up to 10 MB",
        ));
    }
    Ok(rows
        .into_iter()
        .map(|r| {
            let image = matches!(
                r.mime.as_str(),
                "image/png" | "image/jpeg" | "image/gif" | "image/webp"
            );
            (r.id, r.name, r.size as u64, image)
        })
        .collect())
}

/// The files a run carries, ready for the node.
pub async fn for_run(db: &PgPool, run: i64) -> Vec<SentFile> {
    let ids = sqlx::query_scalar!("select attachments from run where id = $1", run)
        .fetch_optional(db)
        .await
        .ok()
        .flatten()
        .unwrap_or_default();
    by_ids(db, &ids).await
}

/// These attachments, ready for the node.
pub async fn by_ids(db: &PgPool, ids: &[i64]) -> Vec<SentFile> {
    if ids.is_empty() {
        return Vec::new();
    }
    let rows = sqlx::query!(
        "select name, mime, content from attachment where id = any($1) order by id",
        ids
    )
    .fetch_all(db)
    .await
    .unwrap_or_default();
    rows.into_iter()
        .map(|r| SentFile {
            name: r.name,
            mime: r.mime,
            data: openssl::base64::encode_block(&r.content),
        })
        .collect()
}

/// Downloads one, always as an attachment (see `artifacts::download`).
pub async fn download(
    State(app): State<Shared>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    let a = sqlx::query!("select name, content from attachment where id = $1", id)
        .fetch_optional(&app.db)
        .await
        .map_err(|e| internal("reading an attachment", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such file"))?;
    Ok(artifacts::as_download(&a.name, a.content))
}
