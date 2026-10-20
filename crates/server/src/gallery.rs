//! The Gallery (DESIGN §12.2): files the owner keeps for the bots, such as
//! reference images, brand material, documents and video. Uploads stream to
//! disk (`ORPHUSBOT_GALLERY_DIR`), named by SHA-256 so a file is kept once;
//! the details are in `gallery_item`. Media is served inline (with ranges, so
//! video can seek); anything else only as a download, so an uploaded page
//! can't run in the app. The app sends a gallery item in a chat by fetching it
//! and attaching it like any file (up to 10 MB), so pictures reach the model.

use std::path::PathBuf;

use axum::Json;
use axum::body::Body;
use axum::extract::{Path, Query, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tower::ServiceExt;
use tower_http::services::ServeFile;

use crate::{ApiError, Shared, artifacts, internal};

/// Per file: room for video, without letting one upload fill the disk.
pub const MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Where the files are kept.
pub fn dir() -> PathBuf {
    std::env::var_os("ORPHUSBOT_GALLERY_DIR").map_or_else(
        || {
            let home = std::env::var_os("HOME").unwrap_or_else(|| ".".into());
            PathBuf::from(home).join(".local/share/orphusbot/gallery")
        },
        PathBuf::from,
    )
}

/// Shown inline in the app: pictures, video and audio. Everything else downloads.
fn inline(mime: &str) -> bool {
    ["image/", "video/", "audio/"]
        .iter()
        .any(|p| mime.starts_with(p))
        && mime != "image/svg+xml"
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
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "ogg" => "audio/ogg",
        "pdf" => "application/pdf",
        "txt" | "md" | "csv" | "json" => "text/plain",
        _ => "application/octet-stream",
    }
}

/// Tags as the owner typed them, tidied: lower case, no blanks or repeats, at most 20.
fn tidy_tags(tags: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for t in tags {
        let t = t.trim().to_lowercase();
        if !t.is_empty() && t.chars().count() <= 40 && !out.contains(&t) {
            out.push(t);
        }
    }
    out.truncate(20);
    out
}

fn item_json(r: &Item) -> Value {
    json!({ "id": r.id, "name": r.name, "mime": r.mime, "size": r.size, "tags": r.tags,
            "description": r.description, "pinned_for": r.pinned_for, "source": r.source,
            "created_at": r.created_at.to_rfc3339() })
}

struct Item {
    id: i64,
    name: String,
    mime: String,
    size: i64,
    sha256: String,
    tags: Vec<String>,
    description: String,
    pinned_for: Vec<String>,
    source: String,
    created_at: chrono::DateTime<chrono::Utc>,
}

async fn get_item(db: &sqlx::PgPool, id: i64) -> Result<Item, ApiError> {
    sqlx::query_as!(
        Item,
        "select id, name, mime, size, sha256, tags, description, pinned_for, source, created_at
         from gallery_item where id = $1",
        id
    )
    .fetch_optional(db)
    .await
    .map_err(|e| internal("reading the gallery", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such gallery item"))
}

#[derive(Deserialize)]
pub struct Search {
    #[serde(default)]
    q: String,
}

/// Newest first; `q` matches the name, description or a tag.
pub async fn list(
    State(app): State<Shared>,
    Query(s): Query<Search>,
) -> Result<Json<Value>, ApiError> {
    let q = s.q.trim().to_lowercase();
    let rows = sqlx::query_as!(
        Item,
        "select id, name, mime, size, sha256, tags, description, pinned_for, source, created_at
         from gallery_item
         where $1 = '' or lower(name) like '%' || $1 || '%' or lower(description) like '%' || $1 || '%'
               or $1 = any(tags)
         order by created_at desc limit 500",
        q
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing the gallery", e))?;
    Ok(Json(json!(rows.iter().map(item_json).collect::<Vec<_>>())))
}

#[derive(Deserialize)]
pub struct Upload {
    name: String,
}

/// `POST /api/gallery?name=…`, the file as the body: streamed to disk, hashed on the way.
pub async fn upload(
    State(app): State<Shared>,
    Query(u): Query<Upload>,
    headers: HeaderMap,
    request: Request,
) -> Result<Json<Value>, ApiError> {
    let name = artifacts::plain_name(&u.name);
    let mime = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .filter(|m| !m.is_empty() && *m != "application/octet-stream")
        .map_or_else(|| guess_mime(&name).to_owned(), str::to_owned);
    let dir = dir();
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| internal("making the gallery folder", e))?;
    let token = crate::auth::random_token().map_err(|e| internal("naming an upload", e))?;
    let part = dir.join(format!(".upload-{token}"));
    let written = save(request.into_body(), &part).await;
    let (size, sha) = match written {
        Ok(done) => done,
        Err(e) => {
            tokio::fs::remove_file(&part).await.ok();
            return Err(e);
        }
    };
    // The same bytes are kept once.
    tokio::fs::rename(&part, dir.join(&sha))
        .await
        .map_err(|e| internal("keeping a gallery file", e))?;
    let item = sqlx::query_as!(
        Item,
        "insert into gallery_item (name, mime, size, sha256) values ($1, $2, $3, $4)
         returning id, name, mime, size, sha256, tags, description, pinned_for, source, created_at",
        name,
        mime,
        size as i64,
        sha
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("keeping a gallery file", e))?;
    Ok(Json(item_json(&item)))
}

/// Writes the body to `path`, refusing more than `MAX_BYTES`; returns its size and SHA-256.
async fn save(body: Body, path: &std::path::Path) -> Result<(u64, String), ApiError> {
    let mut file = tokio::fs::File::create(path)
        .await
        .map_err(|e| internal("writing a gallery file", e))?;
    let mut hash = Sha256::new();
    let mut size = 0u64;
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| (StatusCode::BAD_REQUEST, "The upload was cut off"))?;
        size += chunk.len() as u64;
        if size > MAX_BYTES {
            return Err((
                StatusCode::PAYLOAD_TOO_LARGE,
                "A gallery file can be up to 2 GB",
            ));
        }
        hash.update(&chunk);
        file.write_all(&chunk)
            .await
            .map_err(|e| internal("writing a gallery file", e))?;
    }
    file.flush()
        .await
        .map_err(|e| internal("writing a gallery file", e))?;
    if size == 0 {
        return Err((StatusCode::BAD_REQUEST, "The file is empty"));
    }
    Ok((size, hex(&hash.finalize())))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `GET /api/gallery/{id}/file`: media inline with ranges; anything else as a download.
pub async fn file(
    State(app): State<Shared>,
    Path(id): Path<i64>,
    request: Request,
) -> Result<Response, ApiError> {
    let item = get_item(&app.db, id).await?;
    let served = ServeFile::new(dir().join(&item.sha256))
        .oneshot(request)
        .await
        .map_err(|e| internal("reading a gallery file", e))?;
    let mut response = served.into_response();
    let h = response.headers_mut();
    if let Ok(v) = HeaderValue::from_str(&item.mime) {
        h.insert(header::CONTENT_TYPE, v);
    }
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    h.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static("sandbox; default-src 'none'"),
    );
    if !inline(&item.mime) {
        let ascii: String = item
            .name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || ".-_ ".contains(c) {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        if let Ok(v) = HeaderValue::from_str(&format!("attachment; filename=\"{ascii}\"")) {
            h.insert(header::CONTENT_DISPOSITION, v);
        }
    }
    Ok(response)
}

#[derive(Deserialize)]
pub struct Edit {
    id: i64,
    name: String,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    description: String,
    #[serde(default)]
    pinned_for: Vec<String>,
}

pub async fn update(
    State(app): State<Shared>,
    Json(e): Json<Edit>,
) -> Result<Json<Value>, ApiError> {
    let name = artifacts::plain_name(&e.name);
    if e.description.chars().count() > 2000 {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "A description can be up to 2,000 characters",
        ));
    }
    let pinned: Vec<String> = e
        .pinned_for
        .iter()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    let item = sqlx::query_as!(
        Item,
        "update gallery_item set name = $2, tags = $3, description = $4, pinned_for = $5 where id = $1
         returning id, name, mime, size, sha256, tags, description, pinned_for, source, created_at",
        e.id,
        name,
        &tidy_tags(&e.tags),
        e.description.trim(),
        &pinned
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("updating the gallery", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such gallery item"))?;
    Ok(Json(item_json(&item)))
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

/// Removes the item, and its file when no other item has the same bytes.
pub async fn delete(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<StatusCode, ApiError> {
    let sha = sqlx::query_scalar!(
        "delete from gallery_item where id = $1 returning sha256",
        by.id
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("deleting from the gallery", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such gallery item"))?;
    let still = sqlx::query_scalar!(
        r#"select exists (select 1 from gallery_item where sha256 = $1) as "still!""#,
        sha
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("deleting from the gallery", e))?;
    if !still {
        tokio::fs::remove_file(dir().join(&sha)).await.ok();
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct FromArtifact {
    artifact: i64,
}

/// "Save to gallery" on a file a bot shared.
pub async fn from_artifact(
    State(app): State<Shared>,
    Json(f): Json<FromArtifact>,
) -> Result<Json<Value>, ApiError> {
    let a = sqlx::query!(
        "select a.name, a.content, b.slug from artifact a join bot b on b.id = a.bot_id where a.id = $1",
        f.artifact
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("reading an artifact", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such file"))?;
    let sha = hex(&Sha256::digest(&a.content));
    let dir = dir();
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| internal("making the gallery folder", e))?;
    tokio::fs::write(dir.join(&sha), &a.content)
        .await
        .map_err(|e| internal("keeping a gallery file", e))?;
    let item = sqlx::query_as!(
        Item,
        "insert into gallery_item (name, mime, size, sha256, source) values ($1, $2, $3, $4, $5)
         returning id, name, mime, size, sha256, tags, description, pinned_for, source, created_at",
        a.name,
        guess_mime(&a.name),
        a.content.len() as i64,
        sha,
        format!("bot:{}", a.slug)
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("keeping a gallery file", e))?;
    Ok(Json(item_json(&item)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_shows_inline_and_the_rest_downloads() {
        assert!(inline("image/png") && inline("video/mp4") && inline("audio/mpeg"));
        assert!(!inline("text/html") && !inline("image/svg+xml") && !inline("application/pdf"));
        assert_eq!(guess_mime("Brand Clip.MP4"), "video/mp4");
    }

    #[test]
    fn tags_are_tidied() {
        let raw = ["Brand ", "brand", "", "logo", &"x".repeat(41)].map(String::from);
        assert_eq!(tidy_tags(&raw), ["brand", "logo"]);
    }
}
