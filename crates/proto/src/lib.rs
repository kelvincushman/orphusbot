//! Wire types shared by the OrphusBot server, its nodes and its clients.
//!
//! Every type here is plain data with no I/O, so the crate also compiles for
//! the browser when the Leptos UI arrives (DESIGN §2).

use serde::{Deserialize, Serialize};

/// Server → node, over the node link (DESIGN §4.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToNode {
    /// Run one agent turn for this prompt. `turn` correlates everything that follows.
    StartTurn { turn: i64, text: String },
    /// Stop the turn if it is still running.
    Abort { turn: i64 },
}

/// Node → server, over the node link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FromNode {
    /// First frame after connecting.
    Hello { node: String, version: String },
    /// A chunk of assistant text while it streams.
    Delta { turn: i64, text: String },
    /// One complete assistant message. A turn that uses tools can produce several.
    Reply { turn: i64, text: String },
    /// The turn is over; `error` says why if it failed.
    TurnEnded { turn: i64, error: Option<String> },
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
/// `Message` and `TurnEnded` are stored in Postgres with a per-thread sequence
/// number and replayed on reconnect. The rest are live only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ThreadEvent {
    Message { role: Role, text: String },
    TurnEnded { turn: i64, error: Option<String> },
    TurnStarted { turn: i64 },
    Delta { turn: i64, text: String },
    NodeStatus { online: bool, node: Option<String> },
}

impl ThreadEvent {
    /// Whether this event is stored and replayed, rather than live only.
    pub fn is_persisted(&self) -> bool {
        matches!(self, Self::Message { .. } | Self::TurnEnded { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_format_is_tagged_snake_case() {
        let json = r#"{"type":"start_turn","turn":3,"text":"hi"}"#;
        let parsed: ToNode = serde_json::from_str(json).unwrap();
        assert_eq!(
            parsed,
            ToNode::StartTurn {
                turn: 3,
                text: "hi".into()
            }
        );
        let ev = ThreadEvent::Message {
            role: Role::Assistant,
            text: "ok".into(),
        };
        assert_eq!(
            serde_json::to_string(&ev).unwrap(),
            r#"{"type":"message","role":"assistant","text":"ok"}"#
        );
        assert!(ev.is_persisted());
        assert!(!ThreadEvent::TurnStarted { turn: 1 }.is_persisted());
    }
}
