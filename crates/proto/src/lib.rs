//! Wire types shared by the OrphusBot server, its nodes and its clients.
//!
//! Every type here is plain data with no I/O, so the crate also compiles for
//! the browser when the Leptos UI arrives (DESIGN §2).

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub mod view;

/// Identifies one attempt at a run. A node tags everything it reports with
/// this; the server ignores reports whose fence is no longer current
/// (DESIGN §3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Attempt {
    pub run: i64,
    pub fence: i64,
}

/// What a node signs with its Ed25519 key to prove who it is: its name and
/// the server's one-time nonce (DESIGN §4.1).
pub fn link_proof(node: &str, nonce: &str) -> String {
    format!("orphusbot-node-link-v1\n{node}\n{nonce}")
}

/// A screen's bytes on the node link travel as binary WebSocket frames: an
/// 8-byte big-endian stream number, then the VNC data (DESIGN §4.4).
pub fn screen_frame(stream: u64, data: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(8 + data.len());
    frame.extend_from_slice(&stream.to_be_bytes());
    frame.extend_from_slice(data);
    frame
}

/// Splits a binary frame back into its stream number and data.
pub fn split_screen_frame(frame: &[u8]) -> Option<(u64, &[u8])> {
    let (head, data) = frame.split_first_chunk::<8>()?;
    Some((u64::from_be_bytes(*head), data))
}

/// How to run one bot's engine: its Orphus settings (DESIGN §4.2, PRD B-BOT-01).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotSpec {
    /// Names the engine session, the computer and its home volume.
    pub slug: String,
    /// Appended to Orphus's system prompt.
    pub instructions: String,
    /// Orphus `--model`; `None` uses Orphus's default.
    pub model: Option<String>,
    /// Orphus `--thinking`.
    pub thinking: Option<String>,
    /// Orphus `--exclude-tools`.
    pub exclude_tools: Vec<String>,
    /// A team bot's computer also mounts the shared team folder at `/shared`.
    #[serde(default)]
    pub team: bool,
    /// The MCP servers the owner granted this bot (DESIGN §11).
    #[serde(default)]
    pub mcp: Vec<McpServer>,
    /// The bot's computer is this E2B sandbox, not a container on the node (DESIGN §6.2).
    #[serde(default)]
    pub e2b: Option<E2bComputer>,
}

/// One E2B sandbox's envd: where it answers and its access token. Scoped to
/// that sandbox; never the E2B API key, never a model token.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct E2bComputer {
    pub sandbox: String,
    pub url: String,
    pub token: Option<String>,
}

/// Keeps the token out of logs.
impl std::fmt::Debug for E2bComputer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("E2bComputer")
            .field("sandbox", &self.sandbox)
            .field("url", &self.url)
            .field("token", &self.token.as_ref().map(|_| "[secret]"))
            .finish()
    }
}

/// An MCP server a bot may use. Its token is the owner's secret for that
/// server, never a model subscription token (AGENTS.md rule 4).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpServer {
    /// Prefixes the server's tools, as in `pa_mail_list`.
    pub name: String,
    /// An MCP server over HTTP; empty for a command.
    #[serde(default)]
    pub url: String,
    /// Or a program the node runs (stdio), if it's on the node's allow-list.
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    /// For a command, the environment variable that carries the token.
    #[serde(default)]
    pub token_env: Option<String>,
    /// Sent as `Authorization: Bearer …`, or in `token_env` for a command.
    pub token: Option<String>,
}

/// Keeps the token out of logs.
impl std::fmt::Debug for McpServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpServer")
            .field("name", &self.name)
            .field("url", &self.url)
            .field("command", &self.command)
            .field("args", &self.args)
            .field("token", &self.token.as_ref().map(|_| "[secret]"))
            .finish()
    }
}

/// Server → node, over the node link (DESIGN §4.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToNode {
    /// First frame on every connection: sign this to say hello.
    Challenge { nonce: String },
    /// Answer to [`FromNode::Enrol`]; the server closes the link after it.
    Enrolled { error: Option<String> },
    /// Extract proposals from a capture window (DESIGN §10.2): one call with no
    /// tools, no extensions and no session; answer with `FromNode::Extracted`.
    Extract {
        id: i64,
        system: String,
        text: String,
    },
    /// Connect a viewer to a bot computer's screen; its bytes follow as binary frames.
    ScreenOpen { stream: u64, bot: String },
    /// The viewer went away.
    ScreenClose { stream: u64 },
    /// Work on this run. `resumed` means an earlier attempt was interrupted.
    StartTurn {
        attempt: Attempt,
        text: String,
        resumed: bool,
        bot: Box<BotSpec>,
    },
    /// Extra instructions for the run in progress.
    Steer { attempt: Attempt, text: String },
    /// Stop the run if it is still going.
    Abort { attempt: Attempt },
    /// Answer to a dialog the engine opened: a complete Orphus
    /// `extension_ui_response` object, written to the engine as is.
    DialogResponse { attempt: Attempt, response: Value },
}

/// Node → server, over the node link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FromNode {
    /// Reply to the challenge on a normal connection. `signature` is the
    /// hex Ed25519 signature of [`link_proof`] with the node's enrolled key.
    Hello {
        node: String,
        version: String,
        signature: String,
    },
    /// Reply to the challenge from `orphusbot-node enrol`: registers
    /// `public_key` (hex, 32 bytes) under `node` using a one-time code.
    Enrol {
        code: String,
        node: String,
        public_key: String,
    },
    /// A chunk of assistant text while it streams.
    Delta { attempt: Attempt, text: String },
    /// Every 10 s: what placement needs to know (DESIGN §4.1, §6.3).
    Heartbeat {
        /// One-minute load average as a percentage of the CPUs (can exceed 100).
        load: u32,
        /// Running on battery (a laptop off its charger).
        on_battery: bool,
        /// Inside the node's quiet hours.
        quiet: bool,
    },
    /// The extractor's reply for capture window `id`, or why it failed.
    Extracted {
        id: i64,
        text: Option<String>,
        error: Option<String>,
    },
    /// The models this node's Orphus can use, as `provider/model` (from `orphus --list-models`).
    Models { models: Vec<String> },
    /// The screen stream ended, or couldn't start (`error` says why).
    ScreenClosed { stream: u64, error: Option<String> },
    /// What one assistant message used, as the model's provider reported it
    /// (PRD M4 quota tracker). `cost_micros` is US dollars × 1,000,000.
    Usage {
        attempt: Attempt,
        provider: String,
        model: String,
        input: u64,
        output: u64,
        cache_read: u64,
        cache_write: u64,
        cost_micros: u64,
    },
    /// One complete assistant message. A run that uses tools can produce several.
    Reply { attempt: Attempt, text: String },
    /// The attempt is over; `error` says why if it failed.
    TurnEnded {
        attempt: Attempt,
        error: Option<String>,
    },
    /// The engine opened a dialog (`extension_ui_request` with method
    /// `select`, `confirm`, `input` or `editor`) and is waiting for an answer.
    Dialog { attempt: Attempt, request: Value },
    /// The bot shared a file with `share_file`; `data` is its bytes in base64.
    Artifact {
        attempt: Attempt,
        name: String,
        data: String,
    },
    /// A tool call finished. `result` is its text, truncated.
    ToolDone {
        attempt: Attempt,
        tool_call_id: String,
        ok: bool,
        result: String,
    },
}

/// Something the bot is waiting on the owner for (B-RUN-05, DESIGN §3.4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dialog {
    pub id: String,
    pub run: i64,
    pub kind: DialogKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DialogKind {
    /// May the bot run this tool call? `uncertain` means an interrupted
    /// attempt may already have run it.
    Approval {
        tool: String,
        input: Value,
        uncertain: bool,
    },
    /// The bot needs the owner on its screen, for example to log in.
    Takeover { reason: String },
    /// The bot asked a question. `method` is `select`, `confirm`, `input` or `editor`.
    Question {
        method: String,
        title: String,
        message: Option<String>,
        options: Vec<String>,
    },
}

/// Who wrote a message in a thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    User,
    Assistant,
}

/// What clients see on a thread's event stream.
///
/// `Message` and `RunEnded` are stored in Postgres with a per-thread sequence
/// number and replayed on reconnect. The rest are live only; a client that
/// reconnects gets the current run state again on connect.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ThreadEvent {
    Message {
        role: Role,
        text: String,
    },
    RunEnded {
        run: i64,
        outcome: RunOutcome,
        error: Option<String>,
    },
    /// The run is waiting for a node; `waiting` says why, when there are nodes.
    RunQueued {
        run: i64,
        #[serde(default)]
        waiting: Option<String>,
    },
    /// A node is working on the run. `resumed` means an earlier attempt was
    /// interrupted. `node` and `why` say where it runs and which placement rule chose it.
    RunStarted {
        run: i64,
        resumed: bool,
        #[serde(default)]
        node: Option<String>,
        #[serde(default)]
        why: Option<String>,
    },
    Delta {
        run: i64,
        text: String,
    },
    /// The connected nodes, sent whenever one connects, leaves or changes state.
    Nodes {
        nodes: Vec<NodeView>,
    },
    DialogOpened {
        dialog: Dialog,
    },
    /// A line from OrphusBot in the thread, such as a routine firing or being skipped.
    Notice {
        text: String,
    },
    /// System 1 sent an inbox message to another bot (`to` is its slug, `name` its
    /// name, `sure` the confidence in percent).
    Routed {
        to: String,
        name: String,
        sure: u8,
    },
    /// The dialog was answered, or expired because its run ended or moved on.
    DialogClosed {
        id: String,
        outcome: String,
    },
    /// The bot shared a file; it downloads from `/api/artifacts/<id>`.
    Artifact {
        id: i64,
        name: String,
        version: i32,
        size: u64,
    },
}

/// A connected node, as clients see it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeView {
    pub name: String,
    /// Placement may give it work.
    pub ready: bool,
    /// Why it isn't ready, such as "on battery".
    pub note: Option<String>,
}

/// What clients receive on the event stream: an event, and the bot whose
/// thread it belongs to (`None` for events about the whole system, such as `Nodes`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bot: Option<String>,
    #[serde(flatten)]
    pub event: ThreadEvent,
}

/// How a run ended, as clients see it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunOutcome {
    Completed,
    Failed,
    Cancelled,
}

impl ThreadEvent {
    /// Whether this event is stored and replayed, rather than live only.
    pub fn is_persisted(&self) -> bool {
        matches!(
            self,
            Self::Message { .. }
                | Self::RunEnded { .. }
                | Self::DialogOpened { .. }
                | Self::DialogClosed { .. }
                | Self::Routed { .. }
                | Self::Notice { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screen_frames_round_trip() {
        let frame = screen_frame(7, b"RFB 003.008");
        assert_eq!(split_screen_frame(&frame), Some((7, &b"RFB 003.008"[..])));
        assert_eq!(split_screen_frame(&[1, 2, 3]), None);
    }

    #[test]
    fn wire_format_is_tagged_snake_case() {
        let json = r#"{"type":"start_turn","attempt":{"run":3,"fence":2},"text":"hi","resumed":false,
            "bot":{"slug":"inbox","instructions":"","model":null,"thinking":null,"exclude_tools":[]}}"#;
        let parsed: ToNode = serde_json::from_str(json).unwrap();
        assert!(
            matches!(parsed, ToNode::StartTurn { attempt: Attempt { run: 3, fence: 2 }, ref bot, .. } if bot.slug == "inbox")
        );
        let env = Envelope {
            bot: Some("inbox".into()),
            event: ThreadEvent::RunQueued {
                run: 1,
                waiting: None,
            },
        };
        assert_eq!(
            serde_json::to_string(&env).unwrap(),
            r#"{"bot":"inbox","type":"run_queued","run":1,"waiting":null}"#
        );
        let ev = ThreadEvent::RunEnded {
            run: 3,
            outcome: RunOutcome::Cancelled,
            error: None,
        };
        assert_eq!(
            serde_json::to_string(&ev).unwrap(),
            r#"{"type":"run_ended","run":3,"outcome":"cancelled","error":null}"#
        );
        assert!(ev.is_persisted());
        assert!(
            !ThreadEvent::RunQueued {
                run: 1,
                waiting: None
            }
            .is_persisted()
        );
    }
}
