//! Ambient capture (DESIGN §10, PRD B-CAP-01..07): what was said in hands-free
//! mode, mined into proposals the owner accepts or dismisses.
//!
//! The rules, all enforced here:
//! - **Off unless chosen.** Text is captured only while the device's hands-free
//!   is on *and* the server allows it (`ORPHUSBOT_HANDS_FREE_ALLOWED`, a kill
//!   switch). Otherwise overheard text is dropped, unread.
//! - **Ambient text never makes a bot reply or act.** It goes to windows, then to
//!   a one-shot extraction on a node with **no tools, no extensions and no
//!   session** (`ToNode::Extract`).
//! - **Proposals need a click.** Accepting one makes an unassigned ticket; nothing
//!   starts by itself.
//! - **Other people's speech is context only**: the extractor is told to file
//!   only the owner's own commitments, things asked of the owner and follow-ups
//!   owed to the owner.
//! - **No audio is stored**, and window text is deleted after the retention
//!   period (`ORPHUSBOT_CAPTURE_RETENTION_DAYS`, default 7). A proposal keeps
//!   only its fields and a quote of at most 200 characters.

use std::time::Duration;

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use orphusbot_proto::ToNode;
use serde::Deserialize;
use serde_json::{Value, json};
use tracing::{info, warn};

use crate::{ApiError, App, Shared, internal, lock};

const KINDS: [&str; 6] = [
    "commitment",
    "task",
    "appointment",
    "follow-up",
    "idea",
    "remember",
];

/// The extractor's whole brief. It has no tools; it can only answer with JSON.
pub const EXTRACT_PROMPT: &str = "You are OrphusBot's capture extractor. You read a transcript of a \
conversation the owner had while hands-free listening was on, and you list the things worth keeping. \
You never act, reply to anyone or use tools: you only output JSON.\n\
Each line is `speaker: words`. The owner is the speaker named `owner` or `me`, or the one the others \
talk to. Other people's words are context only: file something from them only when it is something \
asked of the owner, or a follow-up they owe the owner (\"Sam said they'd send the quote by Friday\").\n\
Output a JSON array and nothing else. Each item: {\"kind\": one of commitment | task | appointment | \
follow-up | idea | remember, \"title\": a short, concrete action (max 80 characters, no guilt wording), \
\"detail\": one sentence, \"who\": the other person if any, \"due\": the time it's due as said (\"Thursday\", \
\"tomorrow 3pm\") or \"\", \"quote\": the exact words it came from (max 200 characters)}. If there is \
nothing worth keeping, output [].";

fn allowed() -> bool {
    std::env::var("ORPHUSBOT_HANDS_FREE_ALLOWED").map_or(true, |v| v != "false" && v != "0")
}

fn retention_days() -> f64 {
    std::env::var("ORPHUSBOT_CAPTURE_RETENTION_DAYS")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|d| *d > 0.0)
        .unwrap_or(7.0)
}

/// Overheard text from a device. Returns whether it was captured.
pub async fn overheard(app: &App, device: &str, speaker: &str, text: &str) -> sqlx::Result<bool> {
    let hands_free = sqlx::query_scalar!("select hands_free from device where id = $1", device)
        .fetch_one(&app.db)
        .await?;
    if !(hands_free && allowed()) {
        return Ok(false);
    }
    let speaker: String = speaker.trim().chars().take(40).collect();
    let line = format!(
        "{}: {}",
        if speaker.is_empty() {
            "someone"
        } else {
            &speaker
        },
        text
    );
    let appended = sqlx::query!(
        "update capture_window set text = text || E'\\n' || $2, last_at = now()
         where device_id = $1 and state = 'open' and opened_at > now() - interval '10 minutes'",
        device,
        line
    )
    .execute(&app.db)
    .await?
    .rows_affected();
    if appended == 0 {
        sqlx::query!(
            "insert into capture_window (device_id, text) values ($1, $2)",
            device,
            line
        )
        .execute(&app.db)
        .await?;
    }
    Ok(true)
}

/// Closes quiet or long windows, sends closed ones for extraction, and deletes
/// window text past retention. Forever.
pub async fn mine_forever(app: Shared) {
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    loop {
        tick.tick().await;
        if let Err(e) = mine_due(&app).await {
            warn!("mining captures: {e}");
        }
    }
}

async fn mine_due(app: &App) -> sqlx::Result<()> {
    // DESIGN §10.2: closed by 20 s of silence or a 10-minute cap.
    sqlx::query!(
        "update capture_window set state = 'closed', closed_at = now()
         where state = 'open' and (last_at < now() - interval '20 seconds' or opened_at < now() - interval '10 minutes')"
    )
    .execute(&app.db)
    .await?;
    sqlx::query!(
        "update capture_window set text = null
         where text is not null and closed_at < now() - make_interval(secs => $1::float8 * 86400)",
        retention_days()
    )
    .execute(&app.db)
    .await?;
    let closed = sqlx::query!(
        "select id, text as \"text!\" from capture_window where state = 'closed' and text is not null order by id limit 3"
    )
    .fetch_all(&app.db)
    .await?;
    for w in closed {
        // One extraction in flight per window.
        if !lock(&app.rt).extracting.insert(w.id) {
            continue;
        }
        if !app.system1.worth_extracting(&app.db, &w.text).await {
            lock(&app.rt).extracting.remove(&w.id);
            sqlx::query!(
                "update capture_window set state = 'mined' where id = $1",
                w.id
            )
            .execute(&app.db)
            .await?;
            continue;
        }
        let node = {
            let rt = lock(&app.rt);
            let candidates: Vec<_> = rt.nodes.values().map(crate::NodeLink::candidate).collect();
            match crate::placement::choose(&candidates, None) {
                crate::placement::Placement::Run { node, .. } => {
                    rt.nodes.get(&node).map(|n| n.tx.clone())
                }
                crate::placement::Placement::Wait { .. } => None,
            }
        };
        let sent = match node {
            Some(tx) => tx
                .send(ToNode::Extract {
                    id: w.id,
                    system: EXTRACT_PROMPT.to_owned(),
                    text: w.text,
                })
                .await
                .is_ok(),
            None => false,
        };
        if !sent {
            // No node can take it now; try again next tick.
            lock(&app.rt).extracting.remove(&w.id);
        }
    }
    Ok(())
}

/// The node's answer for window `id`: a JSON array of proposals, or an error.
pub async fn extracted(app: &App, id: i64, text: Option<String>, error: Option<String>) {
    lock(&app.rt).extracting.remove(&id);
    let Some(text) = text else {
        warn!(
            window = id,
            "extraction failed: {}",
            error.unwrap_or_default()
        );
        let _ = sqlx::query!(
            "update capture_window set state = 'failed' where id = $1",
            id
        )
        .execute(&app.db)
        .await;
        return;
    };
    let items = parse(&text);
    let mut filed = 0;
    for p in &items {
        let saved = sqlx::query!(
            "insert into proposal (window_id, kind, title, detail, who, due, quote)
             values ($1, $2, $3, $4, $5, $6, $7)",
            id,
            p.kind,
            p.title,
            p.detail,
            p.who,
            p.due,
            p.quote
        )
        .execute(&app.db)
        .await;
        match saved {
            Ok(_) => filed += 1,
            Err(e) => warn!("storing a proposal: {e}"),
        }
    }
    let _ = sqlx::query!(
        "update capture_window set state = 'mined' where id = $1",
        id
    )
    .execute(&app.db)
    .await;
    info!(window = id, filed, "capture mined");
    if filed > 0 {
        app.notifier.send(crate::notify::Push {
            title: format!(
                "{filed} thing{} from your conversation",
                if filed == 1 { "" } else { "s" }
            ),
            body: items
                .iter()
                .map(|p| p.title.clone())
                .collect::<Vec<_>>()
                .join("\n"),
            priority: 3,
            tags: "memo",
            bot: None,
        });
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Proposed {
    kind: String,
    title: String,
    detail: String,
    who: String,
    due: String,
    quote: String,
}

/// The extractor's JSON array, checked and trimmed; anything malformed is skipped.
fn parse(text: &str) -> Vec<Proposed> {
    let (Some(start), Some(end)) = (text.find('['), text.rfind(']')) else {
        return Vec::new();
    };
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(&text[start..=end.max(start)])
    else {
        return Vec::new();
    };
    let field = |v: &Value, k: &str, max: usize| -> String {
        v[k].as_str()
            .unwrap_or("")
            .trim()
            .chars()
            .take(max)
            .collect()
    };
    items
        .iter()
        .filter_map(|v| {
            let kind = field(v, "kind", 20).to_lowercase();
            let title = field(v, "title", 200);
            (KINDS.contains(&kind.as_str()) && !title.is_empty()).then(|| Proposed {
                kind,
                title,
                detail: field(v, "detail", 1000),
                who: field(v, "who", 100),
                due: field(v, "due", 100),
                quote: field(v, "quote", 200),
            })
        })
        .take(10)
        .collect()
}

/// Proposals waiting for the owner and the latest decided ones, plus hands-free state.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let proposals = sqlx::query!(
        r#"select id, kind, title, detail, who, due, quote, state, ticket_id, created_at::text as "at!"
           from proposal order by state <> 'proposed', id desc limit 50"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing proposals", e))?;
    let listening = sqlx::query!("select id, label from device where hands_free order by id")
        .fetch_all(&app.db)
        .await
        .map_err(|e| internal("reading hands-free", e))?;
    Ok(Json(json!({
        "allowed": allowed(),
        "listening": listening.into_iter().map(|d| json!({ "id": d.id, "label": d.label })).collect::<Vec<_>>(),
        "proposals": proposals.into_iter().map(|p| json!({
            "id": p.id, "kind": p.kind, "title": p.title, "detail": p.detail, "who": p.who, "due": p.due,
            "quote": p.quote, "state": p.state, "ticket": p.ticket_id, "at": p.at,
        })).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

/// Accepting makes an unassigned ticket (DESIGN §10.4); nothing starts by itself.
pub async fn accept(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<StatusCode, ApiError> {
    let p = sqlx::query!(
        "select kind, title, detail, who, due, quote from proposal where id = $1 and state = 'proposed'",
        by.id
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("reading a proposal", e))?
    .ok_or((StatusCode::GONE, "That proposal was already handled"))?;
    let title: String = match p.kind.as_str() {
        "follow-up" => format!("Follow up: {}", p.title),
        "appointment" => format!("Appointment: {}", p.title),
        "idea" | "remember" => format!("Note: {}", p.title),
        _ => p.title.clone(),
    }
    .chars()
    .take(200)
    .collect();
    let mut body = p.detail.clone();
    for (label, value) in [("Who", &p.who), ("Due", &p.due), ("Said", &p.quote)] {
        if !value.is_empty() {
            body.push_str(&format!("\n{label}: {value}"));
        }
    }
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("accepting a proposal", e))?;
    let ticket = sqlx::query_scalar!(
        "insert into ticket (title, body) values ($1, $2) returning id",
        title,
        body.trim()
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| internal("accepting a proposal", e))?;
    sqlx::query!(
        "update proposal set state = 'accepted', ticket_id = $2, decided_at = now() where id = $1",
        by.id,
        ticket
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("accepting a proposal", e))?;
    tx.commit()
        .await
        .map_err(|e| internal("accepting a proposal", e))?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn dismiss(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<StatusCode, ApiError> {
    sqlx::query!(
        "update proposal set state = 'dismissed', decided_at = now() where id = $1 and state = 'proposed'",
        by.id
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("dismissing a proposal", e))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct HandsFree {
    id: String,
    on: bool,
}

/// Pause or resume a device's hands-free listening from OrphusBot (B-CAP-07).
pub async fn set_hands_free(
    State(app): State<Shared>,
    Json(h): Json<HandsFree>,
) -> Result<StatusCode, ApiError> {
    let done = sqlx::query!(
        "update device set hands_free = $2 where id = $1",
        h.id,
        h.on
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("setting hands-free", e))?;
    if done.rows_affected() == 0 {
        return Err((StatusCode::NOT_FOUND, "No such device"));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_only_well_formed_proposals() {
        let reply = r#"Here you go:
[{"kind":"commitment","title":"Send the drawings","detail":"Owner promised the drawings.","who":"supplier","due":"Thursday","quote":"I'll send the drawings by Thursday"},
 {"kind":"Follow-Up","title":"Supplier to confirm delivery date","quote":"we'll confirm the delivery date tomorrow"},
 {"kind":"gossip","title":"not a kind"},
 {"kind":"task","title":""}]"#;
        let got = parse(reply);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].title, "Send the drawings");
        assert_eq!(got[0].due, "Thursday");
        assert_eq!(got[1].kind, "follow-up");
        assert!(parse("nothing worth keeping").is_empty());
        assert!(parse("[]").is_empty());
        let long = format!(
            r#"[{{"kind":"idea","title":"x","quote":"{}"}}]"#,
            "q".repeat(500)
        );
        assert_eq!(parse(&long)[0].quote.len(), 200, "quotes are capped");
    }
}
