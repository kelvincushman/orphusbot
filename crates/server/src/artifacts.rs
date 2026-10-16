//! Artifacts (DESIGN §11.1): files a bot shares with `share_file`. The node
//! sends the bytes; they are kept with a version per name and bot, and the
//! thread shows a download link.

use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::IntoResponse;
use orphusbot_proto::ThreadEvent;
use tracing::warn;

use crate::{ApiError, App, Shared, db, internal, record};

/// The same limit the bridge enforces.
const MAX_BYTES: usize = 10 * 1024 * 1024;

/// Keeps a shared file and puts it in the bot's thread.
pub async fn shared(app: &App, thread: &db::Thread, run: i64, name: &str, data: &str) {
    let bytes = match openssl::base64::decode_block(data) {
        Ok(b) if b.len() <= MAX_BYTES => b,
        Ok(_) => return warn!(run, "a shared file was over 10 MB"),
        Err(e) => return warn!(run, "a shared file wasn't base64: {e}"),
    };
    // A plain file name: no folders, no control characters.
    let name: String = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or_default()
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect();
    let name = if name.trim().is_empty() {
        "file".to_owned()
    } else {
        name
    };
    let saved = sqlx::query!(
        r#"insert into artifact (bot_id, run_id, name, version, content)
           select t.bot_id, $2, $3,
                  coalesce((select max(version) from artifact a where a.bot_id = t.bot_id and a.name = $3), 0) + 1, $4
           from thread t where t.id = $1
           returning id, version"#,
        thread.id,
        run,
        name,
        bytes
    )
    .fetch_one(&app.db)
    .await;
    match saved {
        Ok(a) => {
            let event = ThreadEvent::Artifact {
                id: a.id,
                name,
                version: a.version,
                size: bytes.len() as u64,
            };
            record(app, thread, event).await;
        }
        Err(e) => warn!("keeping a shared file: {e}"),
    }
}

/// Downloads an artifact. Always as an attachment, never shown inline, so a
/// shared HTML file can't run in OrphusBot's origin.
pub async fn download(
    State(app): State<Shared>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    let a = sqlx::query!("select name, content from artifact where id = $1", id)
        .fetch_optional(&app.db)
        .await
        .map_err(|e| internal("reading an artifact", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such file"))?;
    let ascii: String = a
        .name
        .chars()
        .map(|c| {
            if c.is_ascii_graphic() && c != '"' || c == ' ' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let encoded: String = a
        .name
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect();
    let disposition = format!("attachment; filename=\"{ascii}\"; filename*=UTF-8''{encoded}");
    Ok((
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_owned()),
            (header::CONTENT_DISPOSITION, disposition),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".to_owned()),
        ],
        a.content,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::PgPool;

    #[sqlx::test]
    async fn shared_files_are_versioned_and_download_as_attachments(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        let thread = db::bot_thread(&db, "inbox").await.unwrap().unwrap();
        let run: i64 = sqlx::query_scalar!(
            "insert into run (thread_id, prompt) values ($1, 'x') returning id",
            thread.id
        )
        .fetch_one(&db)
        .await
        .unwrap();
        shared(&app, &thread, run, "../../etc/report.html", "PGI+aGk8L2I+").await;
        shared(&app, &thread, run, "report.html", "PGI+aGk8L2I+").await;
        shared(&app, &thread, run, "bad.txt", "not base64!").await;
        let rows: Vec<(String, i32)> =
            sqlx::query!("select name, version from artifact order by id")
                .fetch_all(&db)
                .await
                .unwrap()
                .into_iter()
                .map(|r| (r.name, r.version))
                .collect();
        assert_eq!(rows, [("report.html".into(), 1), ("report.html".into(), 2)]);

        let id: i64 = sqlx::query_scalar!("select max(id) as \"id!\" from artifact")
            .fetch_one(&db)
            .await
            .unwrap();
        let res = download(State(app), Path(id))
            .await
            .unwrap()
            .into_response();
        let h = res.headers();
        assert_eq!(h[header::CONTENT_TYPE], "application/octet-stream");
        assert!(
            h[header::CONTENT_DISPOSITION]
                .to_str()
                .unwrap()
                .starts_with("attachment; filename=\"report.html\"")
        );
        assert_eq!(h[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
    }
}
