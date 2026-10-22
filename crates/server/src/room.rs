//! The Ideas Room (DESIGN §12.5, D-052): a live conversation with Grok's
//! realtime voice, speaking for the Orchestrator. The server mints Grok's
//! short-lived token and session (the xAI key stays here); Grok's lookups
//! reach the Orchestrator as room messages, answered on a quick model.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::{ApiError, Shared};

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
When he says he's done or asks you to save it, call save_idea with a short title and a brief: the idea, who it's for, what's known, open questions and next steps.";

/// `POST /api/room/voice`: a five-minute token for Grok's realtime voice and
/// the session the app should open with. The xAI key stays here.
pub async fn voice(State(_app): State<Shared>) -> Result<Json<Value>, ApiError> {
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
    Ok(Json(json!({
        "token": token,
        "url": "wss://api.x.ai/v1/realtime?model=grok-voice-latest",
        "session": {
            "voice": env("ORPHUSBOT_XAI_VOICE").unwrap_or_else(|| "eve".into()),
            "instructions": VOICE_INSTRUCTIONS,
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
