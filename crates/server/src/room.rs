//! The Ideas Room (DESIGN §12.5): the owner talks with the Orchestrator by
//! voice. The app records a turn and sends it here to be written down by the
//! box's own speech recognition (qwen-stt, `ORPHUSBOT_STT_URL` with its token
//! `ORPHUSBOT_STT_TOKEN`); the reply is spoken by ElevenLabs
//! (`ORPHUSBOT_ELEVENLABS_KEY`, voice `ORPHUSBOT_ELEVENLABS_VOICE`). Both keys
//! stay on the server; the app only sends audio and gets audio back.

use axum::Json;
use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::Response;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{ApiError, Shared};

/// One client for both services; reqwest pools connections.
static HTTP: std::sync::LazyLock<reqwest::Client> = std::sync::LazyLock::new(reqwest::Client::new);

/// About two minutes of 16 kHz mono 16-bit audio.
const MAX_AUDIO_BYTES: usize = 4 * 1024 * 1024;
/// ElevenLabs takes up to 5,000 characters a request; replies are short anyway.
const MAX_SPEAK_CHARS: usize = 4_000;
/// A clear, warm British voice ("George") unless the owner picks another.
const DEFAULT_VOICE: &str = "JBFqnCBsd6RMkjVDRZzb";

/// Added to the Orchestrator's prompt for a message said in the room. Kept out
/// of the recorded message, so the chat shows only what the owner said.
pub const ROOM_NOTE: &str = "\n\n(You're in the Ideas Room: Kelvin is talking to you by voice and \
hears your reply read aloud. Speak naturally in short sentences, two to five of them; no \
Markdown, tables, lists, links or code, since they're read out. We're brainstorming: help him \
get the idea clear, go wide before narrowing, ask one question at a time, and build on what he \
says. When facts or examples from the web would help, hand Researcher the search with ask_bot \
and carry on talking; tell him when results come in. When he says he's done, or asks for it, \
write an idea brief (the idea, who it's for, what's known, open questions, next steps) into the \
team wiki under wiki/ideas/ and offer tickets for the next steps.)";

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

/// `POST /api/room/transcribe`, a WAV (16 kHz mono) as the body: `{"text": …}`.
pub async fn transcribe(State(_app): State<Shared>, body: Bytes) -> Result<Json<Value>, ApiError> {
    if body.is_empty() || body.len() > MAX_AUDIO_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            "Speak for at most two minutes at a time",
        ));
    }
    let url = env("ORPHUSBOT_STT_URL").unwrap_or_else(|| "http://127.0.0.1:6006/transcribe".into());
    let mut req = HTTP
        .post(url)
        .body(body)
        .timeout(std::time::Duration::from_secs(60));
    if let Some(token) = env("ORPHUSBOT_STT_TOKEN") {
        req = req.bearer_auth(token);
    }
    let res = req.send().await.map_err(|e| {
        tracing::warn!("speech recognition unreachable: {e}");
        (
            StatusCode::BAD_GATEWAY,
            "Speech recognition isn't answering",
        )
    })?;
    if !res.status().is_success() {
        tracing::warn!("speech recognition answered {}", res.status());
        return Err((
            StatusCode::BAD_GATEWAY,
            "Speech recognition couldn't read that",
        ));
    }
    let got: Value = res.json().await.map_err(|_| {
        (
            StatusCode::BAD_GATEWAY,
            "Speech recognition sent something odd",
        )
    })?;
    let text = got["text"].as_str().unwrap_or_default().trim().to_owned();
    Ok(Json(json!({ "text": text })))
}

#[derive(Deserialize)]
pub struct Speak {
    text: String,
}

/// `POST /api/room/speak {text}`: the reply read aloud, as MP3.
pub async fn speak(State(_app): State<Shared>, Json(s): Json<Speak>) -> Result<Response, ApiError> {
    let text = speakable(&s.text);
    if text.is_empty() {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, "Nothing to say"));
    }
    let key = env("ORPHUSBOT_ELEVENLABS_KEY").ok_or((
        StatusCode::SERVICE_UNAVAILABLE,
        "The voice isn't set up: add ORPHUSBOT_ELEVENLABS_KEY",
    ))?;
    let voice = env("ORPHUSBOT_ELEVENLABS_VOICE").unwrap_or_else(|| DEFAULT_VOICE.into());
    let res = HTTP
        .post(format!(
            "https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128"
        ))
        .header("xi-api-key", key)
        .json(&json!({ "text": text, "model_id": "eleven_flash_v2_5" }))
        .timeout(std::time::Duration::from_secs(60))
        .send()
        .await
        .map_err(|e| {
            tracing::warn!("ElevenLabs unreachable: {e}");
            (StatusCode::BAD_GATEWAY, "The voice service isn't answering")
        })?;
    if !res.status().is_success() {
        tracing::warn!("ElevenLabs answered {}", res.status());
        return Err((StatusCode::BAD_GATEWAY, "The voice service refused that"));
    }
    let audio = res
        .bytes()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "The voice was cut off"))?;
    Response::builder()
        .header(header::CONTENT_TYPE, "audio/mpeg")
        .body(Body::from(audio))
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Couldn't send the voice"))
}

/// A reply as it should be read aloud: code, links and Markdown marks dropped.
pub fn speakable(text: &str) -> String {
    let mut out = String::new();
    let mut in_code = false;
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code || t.starts_with('|') || t.chars().all(|c| "-=*_ ".contains(c)) && !t.is_empty()
        {
            continue;
        }
        // Headings, bullets and quotes keep their words.
        let t = t.trim_start_matches(['#', '>', '-', '*', '+', ' ']);
        out.push_str(t);
        out.push(' ');
    }
    // [words](link) reads as the words; bare links aren't read.
    let mut text = String::new();
    let mut rest = out.as_str();
    while let Some(i) = rest.find('[') {
        text.push_str(&rest[..i]);
        rest = &rest[i + 1..];
        match (rest.find("]("), rest.find(']')) {
            (Some(j), Some(k)) if j == k => {
                text.push_str(&rest[..j]);
                rest = rest[j + 2..].split_once(')').map_or("", |(_, r)| r);
            }
            _ => text.push('['),
        }
    }
    text.push_str(rest);
    let words: Vec<&str> = text
        .split_whitespace()
        .filter(|w| !w.starts_with("http://") && !w.starts_with("https://"))
        .collect();
    let text = words.join(" ").replace(['*', '`', '_'], "");
    text.chars().take(MAX_SPEAK_CHARS).collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replies_are_read_without_markdown_code_or_links() {
        let reply = "## Plan\n\nThat's a **good** idea.\n\n- First, ask [Researcher](https://x.io/a).\n\
                     ```rust\nfn main() {}\n```\n| a | b |\n|---|---|\nSee https://example.com for more.";
        assert_eq!(
            speakable(reply),
            "Plan That's a good idea. First, ask Researcher. See for more."
        );
        assert_eq!(speakable("```\nonly code\n```"), "");
        assert!(speakable(&"word ".repeat(2000)).chars().count() <= MAX_SPEAK_CHARS);
    }
}
