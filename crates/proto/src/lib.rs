//! Wire types shared by the OrphusBot server, its nodes and its clients.
//!
//! Every type here is plain data with no I/O, so the crate also compiles for
//! the browser when the Leptos UI arrives (DESIGN §2).

use serde::{Deserialize, Serialize};

/// Identifies one attempt at a run. A node tags everything it reports with
/// this; the server ignores reports whose fence is no longer current
/// (DESIGN §3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Attempt {
    pub run: i64,
    pub fence: i64,
}

/// Server → node, over the node link (DESIGN §4.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToNode {
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
}

/// Node → server, over the node link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FromNode {
    /// First frame after connecting.
    Hello { node: String, version: String },
    /// A chunk of assistant text while it streams.
    Delta { attempt: Attempt, text: String },
    /// One complete assistant message. A run that uses tools can produce several.
    Reply { attempt: Attempt, text: String },
    /// The attempt is over; `error` says why if it failed.
    TurnEnded {
        attempt: Attempt,
        error: Option<String>,
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
        matches!(self, Self::Message { .. } | Self::RunEnded { .. })
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
