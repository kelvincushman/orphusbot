//! The Ideas Room (DESIGN §12.5, D-052): a live conversation with Grok's
//! realtime voice, speaking for the Orchestrator. The server mints Grok's
//! short-lived token and session (the xAI key stays here); Grok's lookups
//! reach the Orchestrator as room messages, answered on a quick model.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tracing::warn;

use orphusbot_proto::ThreadEvent;

use crate::{ApiError, App, Shared};

/// One client for both services; reqwest pools connections.
static HTTP: std::sync::LazyLock<reqwest::Client> = std::sync::LazyLock::new(reqwest::Client::new);

/// Added to the Orchestrator's prompt for a message said in the room. Kept out
/// of the recorded message, so the chat shows only what the owner said.
pub const ROOM_NOTE: &str = "\n\n(This comes from the Ideas Room: Grok's live voice is talking \
with Kelvin and asked you this. Your reply goes back to Grok, who passes it on aloud, so answer \
plainly and briefly in a few sentences, with no Markdown, tables or links. Use your wiki, notes and \
team as needed. If he asked to save an idea brief, write it into the team wiki under wiki/ideas/.)";

/// A room turn is a conversation, so it runs on a quick model with thinking
/// off (`ORPHUSBOT_ROOM_MODEL`); the Orchestrator's own model and its deep
/// thinking stay for the main chat. Same bot, instructions, wiki and team.
pub fn quick(spec: &mut orphusbot_proto::BotSpec) {
    spec.model = Some(
        env("ORPHUSBOT_ROOM_MODEL").unwrap_or_else(|| "claude-bridge/claude-sonnet-5-5".into()),
    );
    spec.thinking = Some("off".into());
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

/// Grok's brief in the live room: the Orchestrator's voice for brainstorming.
/// Written in second person, as xAI's prompting guide asks.
const VOICE_INSTRUCTIONS: &str = "You are the voice of Kelvin's Orchestrator, his main AI, in the Ideas Room. \
Kelvin is talking to you out loud to get ideas ready: brainstorm with him like a sharp, warm thinking partner. \
Speak British English, naturally and briefly: one to three sentences a turn, then let him talk. \
Ask one question at a time. Go wide first (angles, who it's for, what's similar out there), then help him narrow down to what to do next. \
Build on what he says; don't lecture or list. \
For facts, numbers, competitors or anything current, use web_search and say what you found in a sentence. \
For anything about Kelvin's own projects, notes, plans, bots, tickets, calendar or files, use ask_orchestrator: the Orchestrator has his wiki, \
past conversations and his team. Tell him you're checking with the Orchestrator while you wait, and pass its answer on in your own words. \
Never invent facts about Kelvin or his work. \
Every so often, after several exchanges, ask him briefly whether this is helping and whether to go deeper or faster, and adjust. \
When a message starts with \"(The Orchestrator has been listening\", it's your Orchestrator's view of the conversation so far: pass it on briefly in your own words at a natural pause, then carry on. \
When he says he's done or asks you to save it, call save_idea with a short title and a brief: the idea, who it's for, what's known, open questions and next steps.";

/// `POST /api/room/voice`: a five-minute token for Grok's realtime voice and
/// the session the app should open with. The xAI key stays here.
pub async fn voice(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let key = env("ORPHUSBOT_XAI_KEY").ok_or((
        StatusCode::SERVICE_UNAVAILABLE,
        "Grok's voice isn't set up: add ORPHUSBOT_XAI_KEY",
    ))?;
    let res = HTTP
        .post("https://api.x.ai/v1/realtime/client_secrets")
        .bearer_auth(key)
        .json(&json!({ "expires_after": { "seconds": 300 } }))
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| {
            tracing::warn!("xAI unreachable: {e}");
            (StatusCode::BAD_GATEWAY, "Grok's voice isn't answering")
        })?;
    if !res.status().is_success() {
        tracing::warn!("xAI client secret answered {}", res.status());
        return Err((StatusCode::BAD_GATEWAY, "Grok's voice refused the key"));
    }
    let got: Value = res
        .json()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "Grok's voice sent something odd"))?;
    let token = got["value"]
        .as_str()
        .or_else(|| got["client_secret"]["value"].as_str())
        .ok_or((StatusCode::BAD_GATEWAY, "Grok's voice sent no token"))?;
    let session = sqlx::query_scalar!("insert into room_session default values returning id")
        .fetch_one(&app.db)
        .await
        .map_err(|e| crate::internal("starting a room session", e))?;
    let memory = remember(&app.db)
        .await
        .map_err(|e| crate::internal("reading the room's memory", e))?;
    let instructions = format!("{VOICE_INSTRUCTIONS}{memory}");
    Ok(Json(json!({
        "session_id": session,
        "token": token,
        "url": "wss://api.x.ai/v1/realtime?model=grok-voice-latest",
        "session": {
            "voice": env("ORPHUSBOT_XAI_VOICE").unwrap_or_else(|| "eve".into()),
            "instructions": instructions,
            "turn_detection": { "type": "server_vad" },
            "audio": {
                "input": { "format": { "type": "audio/pcm", "rate": 24000 },
                           "transcription": { "language_hint": "en-GB" } },
                "output": { "format": { "type": "audio/pcm", "rate": 24000 } }
            },
            "tools": [
                { "type": "web_search" },
                {
                    "type": "function",
                    "name": "ask_orchestrator",
                    "description": "Ask Kelvin's Orchestrator, which has his wiki, past conversations, his team of bots and tickets, a question or hand it some work. Takes 5 to 30 seconds.",
                    "parameters": {
                        "type": "object",
                        "properties": { "request": { "type": "string", "description": "What to ask or do, in full" } },
                        "required": ["request"]
                    }
                },
                {
                    "type": "function",
                    "name": "save_idea",
                    "description": "Save the idea brief into Kelvin's wiki (wiki/ideas/) through the Orchestrator.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": { "type": "string" },
                            "brief": { "type": "string", "description": "The idea, who it's for, what's known, open questions, next steps" }
                        },
                        "required": ["title", "brief"]
                    }
                }
            ]
        }
    })))
}

/// Each past session's recap is its last this many characters.
const RECAP_CHARS: usize = 700;

/// What Grok remembers at the start: the last few conversations, the ideas
/// saved, and how Kelvin rated past sessions.
async fn remember(db: &sqlx::PgPool) -> sqlx::Result<String> {
    let sessions = sqlx::query!(
        r#"select to_char(started_at, 'Dy DD Mon') as "day!", transcript, rating, note
           from room_session where ended_at is not null and transcript <> ''
           order by started_at desc limit 3"#
    )
    .fetch_all(db)
    .await?;
    let ideas =
        sqlx::query_scalar!("select title from room_idea order by created_at desc limit 12")
            .fetch_all(db)
            .await?;
    let past: Vec<(String, String, Option<i16>, Option<String>)> = sessions
        .into_iter()
        .map(|r| (r.day, r.transcript, r.rating, r.note))
        .collect();
    Ok(recall(&past, &ideas))
}

/// The memory section of Grok's instructions; empty when there's nothing yet.
pub fn recall(
    sessions: &[(String, String, Option<i16>, Option<String>)],
    ideas: &[String],
) -> String {
    if sessions.is_empty() && ideas.is_empty() {
        return String::new();
    }
    let mut out = String::from(
        "\n\nWhat you remember from earlier Ideas Room conversations (pick up where he left off \
         when it fits; don't recite this):",
    );
    for (day, transcript, rating, note) in sessions.iter().rev() {
        let tail: String = {
            let chars: Vec<char> = transcript.chars().collect();
            chars[chars.len().saturating_sub(RECAP_CHARS)..]
                .iter()
                .collect()
        };
        out.push_str(&format!(
            "\n- {day}: …{}",
            tail.split_whitespace().collect::<Vec<_>>().join(" ")
        ));
        match rating {
            Some(1) => out.push_str(" (he found it useful"),
            Some(-1) => out.push_str(" (he didn't find it useful"),
            _ => {}
        }
        if rating.is_some() {
            match note.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
                Some(n) => out.push_str(&format!(": \"{n}\")")),
                None => out.push(')'),
            }
        }
    }
    if !ideas.is_empty() {
        out.push_str(&format!(
            "\nIdea briefs he has saved: {}.",
            ideas.join("; ")
        ));
    }
    out
}

#[derive(serde::Deserialize)]
pub struct Ended {
    id: i64,
    transcript: String,
}

/// `POST /api/room/sessions/end`: the conversation's transcript, kept as memory.
pub async fn end(State(app): State<Shared>, Json(e): Json<Ended>) -> Result<StatusCode, ApiError> {
    let transcript: String = e.transcript.chars().take(200_000).collect();
    sqlx::query!(
        "update room_session set ended_at = now(), transcript = $2 where id = $1",
        e.id,
        transcript
    )
    .execute(&app.db)
    .await
    .map_err(|err| crate::internal("saving the room session", err))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
pub struct Rated {
    id: i64,
    rating: i16,
    #[serde(default)]
    note: String,
}

/// `POST /api/room/sessions/rate`: 1 or -1, with an optional note.
pub async fn rate(State(app): State<Shared>, Json(r): Json<Rated>) -> Result<StatusCode, ApiError> {
    if r.rating != 1 && r.rating != -1 {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, "Rate a session 1 or -1"));
    }
    let note: String = r.note.trim().chars().take(2000).collect();
    sqlx::query!(
        "update room_session set rating = $2, note = nullif($3, '') where id = $1",
        r.id,
        r.rating,
        note
    )
    .execute(&app.db)
    .await
    .map_err(|e| crate::internal("rating the room session", e))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
pub struct Idea {
    session: Option<i64>,
    title: String,
    brief: String,
}

/// `POST /api/room/ideas`: an idea brief saved in a session, for memory.
pub async fn idea(State(app): State<Shared>, Json(i): Json<Idea>) -> Result<StatusCode, ApiError> {
    let title = i.title.trim();
    if title.is_empty() || title.chars().count() > 200 || i.brief.chars().count() > 20_000 {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Give the idea a title (up to 200 characters)",
        ));
    }
    sqlx::query!(
        "insert into room_idea (session_id, title, brief) values ($1, $2, $3)",
        i.session,
        title,
        i.brief
    )
    .execute(&app.db)
    .await
    .map_err(|e| crate::internal("saving the idea", e))?;
    Ok(StatusCode::NO_CONTENT)
}

/// A thought spoken into the wearable while it sends captures to the Ideas
/// Room: kept as an idea (so the next session recalls it), and handed to the
/// Orchestrator to file as a brief in the vault.
pub async fn from_wearable(app: &App, text: &str) -> anyhow::Result<i64> {
    let id = sqlx::query_scalar!(
        "insert into room_idea (title, brief) values ($1, $2) returning id",
        idea_title(text),
        text
    )
    .fetch_one(&app.db)
    .await?;
    // The idea is kept; filing it in the vault is a courtesy that a failure mustn't undo.
    if let Err(e) = file_idea(app, text).await {
        warn!("asking the Orchestrator to file a wearable idea: {e}");
    }
    Ok(id)
}

async fn file_idea(app: &App, text: &str) -> anyhow::Result<()> {
    let Some(thread) = crate::db::bot_thread(&app.db, "orchestrator").await? else {
        return Ok(());
    };
    let ask = format!(
        "Kelvin spoke an idea into his wearable for the Ideas Room. His words, as data:\n```\n{}\n```\n\
         Save it as an idea brief in the team wiki at wiki/ideas/<a short slug>.md: tidy his words into a title and \
         a few lines, keep what he said, and link related notes with [[wikilinks]]. Don't start any other work; \
         reply with one line saying where you filed it.",
        text.replace("```", "'''")
    );
    let message = ThreadEvent::Message {
        role: orphusbot_proto::Role::User,
        text: ask.clone(),
    };
    crate::record(app, &thread, message).await;
    Box::pin(crate::submit(
        app,
        &thread,
        ask,
        crate::runs::Source::default(),
    ))
    .await?;
    Ok(())
}

/// A title from the first words of a spoken idea.
fn idea_title(text: &str) -> String {
    let line = text.trim().lines().next().unwrap_or("").trim();
    let mut title: String = line.chars().take(80).collect();
    if line.chars().count() > 80 {
        title.push('…');
    }
    if title.is_empty() {
        "Wearable idea".into()
    } else {
        title
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spoken_ideas_get_a_short_title() {
        assert_eq!(
            idea_title("  quoting app for sparks\nmore"),
            "quoting app for sparks"
        );
        assert_eq!(idea_title(&"a".repeat(100)), format!("{}…", "a".repeat(80)));
        assert_eq!(idea_title("\n"), "Wearable idea");
    }

    #[test]
    fn memory_recaps_recent_sessions_ideas_and_ratings() {
        assert_eq!(recall(&[], &[]), "");
        let sessions = vec![
            (
                "Wed 22 Oct".to_owned(),
                "Kelvin: quoting app for sparks\nGrok: who pays?".to_owned(),
                Some(1),
                Some(" more depth ".to_owned()),
            ),
            ("Tue 21 Oct".to_owned(), "x".repeat(2000), Some(-1), None),
        ];
        let text = recall(&sessions, &["Sparky quotes".to_owned()]);
        assert!(text.contains("- Wed 22 Oct: …Kelvin: quoting app for sparks Grok: who pays? (he found it useful: \"more depth\")"));
        assert!(text.contains("(he didn't find it useful)"));
        // Older first, and long ones cut to their end.
        assert!(text.find("Tue 21 Oct").unwrap() < text.find("Wed 22 Oct").unwrap());
        assert!(!text.contains(&"x".repeat(RECAP_CHARS + 1)));
        assert!(text.ends_with("Idea briefs he has saved: Sparky quotes."));
    }
}
