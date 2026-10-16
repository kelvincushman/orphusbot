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

/// Server → node, over the node link (DESIGN §4.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToNode {
    /// First frame on every connection: sign this to say hello.
    Challenge { nonce: String },
    /// Answer to [`FromNode::Enrol`]; the server closes the link after it.
    Enrolled { error: Option<String> },
    /// Work on this run. `resumed` means an earlier attempt was interrupted.
    StartTurn {
        attempt: Attempt,
        text: String,
        resumed: bool,
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
    /// The run is waiting for a node.
    RunQueued {
        run: i64,
    },
    /// A node is working on the run. `resumed` means an earlier attempt was interrupted.
    RunStarted {
        run: i64,
        resumed: bool,
    },
    Delta {
        run: i64,
        text: String,
    },
    NodeStatus {
        online: bool,
        node: Option<String>,
    },
    DialogOpened {
        dialog: Dialog,
    },
    /// The dialog was answered, or expired because its run ended or moved on.
    DialogClosed {
        id: String,
        outcome: String,
    },
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
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_format_is_tagged_snake_case() {
        let json =
            r#"{"type":"start_turn","attempt":{"run":3,"fence":2},"text":"hi","resumed":false}"#;
        let parsed: ToNode = serde_json::from_str(json).unwrap();
        assert_eq!(
            parsed,
            ToNode::StartTurn {
                attempt: Attempt { run: 3, fence: 2 },
                text: "hi".into(),
                resumed: false,
            }
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
        assert!(!ThreadEvent::RunQueued { run: 1 }.is_persisted());
    }
}
