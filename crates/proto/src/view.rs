//! The thread reducer: folds [`ThreadEvent`]s into what a client shows
//! (DESIGN §12). Every client uses this one function, so the web, desktop
//! and Android apps can't disagree about what happened.

use crate::{Dialog, NodeView, Role, RunOutcome, ThreadEvent};

/// One entry in the conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Item {
    Message {
        role: Role,
        text: String,
    },
    /// An approval or question. `outcome` is set once it's answered or expired.
    Card {
        dialog: Dialog,
        outcome: Option<String>,
    },
    /// A line from OrphusBot itself, such as "Stopped." `error` marks failures.
    Notice {
        text: String,
        error: bool,
    },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RunState {
    #[default]
    Idle,
    /// Waiting for a node.
    Queued,
    /// `resumed`: picking up after an interrupted attempt.
    Running { resumed: bool },
}

/// Where the run is, or why it waits, for the status line.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RunWhere {
    pub node: Option<String>,
    /// The placement rule that chose the node, or why the run is waiting.
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ThreadView {
    pub items: Vec<Item>,
    /// Assistant text still streaming in, shown after `items`.
    pub streaming: Option<String>,
    pub run: RunState,
    pub run_where: RunWhere,
    /// The connected nodes.
    pub nodes: Vec<NodeView>,
}

impl ThreadView {
    pub fn apply(&mut self, event: ThreadEvent) {
        match event {
            ThreadEvent::Message { role, text } => {
                if role == Role::Assistant {
                    // The final text replaces what streamed in.
                    self.streaming = None;
                }
                self.items.push(Item::Message { role, text });
            }
            ThreadEvent::Delta { text, .. } => {
                self.streaming.get_or_insert_default().push_str(&text);
            }
            ThreadEvent::RunQueued { waiting, .. } => {
                self.run = RunState::Queued;
                self.run_where = RunWhere {
                    node: None,
                    note: waiting,
                };
                self.streaming = None;
            }
            ThreadEvent::RunStarted {
                resumed, node, why, ..
            } => {
                self.run = RunState::Running { resumed };
                self.run_where = RunWhere { node, note: why };
            }
            ThreadEvent::RunEnded { outcome, error, .. } => {
                self.run = RunState::Idle;
                self.run_where = RunWhere::default();
                // Keep what streamed before a stop or failure; it isn't replayed.
                if let Some(text) = self.streaming.take().filter(|t| !t.is_empty()) {
                    self.items.push(Item::Message {
                        role: Role::Assistant,
                        text,
                    });
                }
                let notice = match outcome {
                    RunOutcome::Completed => None,
                    RunOutcome::Cancelled => Some("Stopped.".to_owned()),
                    RunOutcome::Failed => Some(format!(
                        "The run failed: {}",
                        error.as_deref().unwrap_or("unknown error")
                    )),
                };
                if let Some(text) = notice {
                    let error = outcome == RunOutcome::Failed;
                    self.items.push(Item::Notice { text, error });
                }
            }
            ThreadEvent::Nodes { nodes } => self.nodes = nodes,
            ThreadEvent::DialogOpened { dialog } => self.items.push(Item::Card {
                dialog,
                outcome: None,
            }),
            ThreadEvent::DialogClosed { id, outcome } => {
                for item in &mut self.items {
                    if let Item::Card { dialog, outcome: o } = item
                        && dialog.id == id
                    {
                        *o = Some(outcome.clone());
                    }
                }
            }
        }
    }

    /// Cards still waiting for the owner.
    pub fn waiting(&self) -> usize {
        self.items
            .iter()
            .filter(|i| matches!(i, Item::Card { outcome: None, .. }))
            .count()
    }

    /// One line for the header, such as "laptop online · working on laptop…".
    pub fn status(&self) -> String {
        let nodes = if self.nodes.is_empty() {
            "No node connected".to_owned()
        } else {
            let list: Vec<String> = self
                .nodes
                .iter()
                .map(|n| match (&n.note, n.ready) {
                    (Some(note), false) => format!("{} ({note})", n.name),
                    _ => n.name.clone(),
                })
                .collect();
            format!("{} online", list.join(", "))
        };
        let on = self
            .run_where
            .node
            .as_ref()
            .map(|n| format!(" on {n}"))
            .unwrap_or_default();
        let run = match (self.run, &self.run_where.note) {
            (RunState::Idle, _) => String::new(),
            (RunState::Queued, Some(why)) => format!(" · waiting: {why}"),
            (RunState::Queued, None) => " · waiting for a node".to_owned(),
            (RunState::Running { resumed: true }, _) => {
                format!(" · resuming{on} after an interruption…")
            }
            (RunState::Running { resumed: false }, _) => format!(" · working{on}…"),
        };
        format!("{nodes}{run}")
    }

    /// The latest message, for the sidebar preview.
    pub fn last_message(&self) -> Option<&str> {
        self.items.iter().rev().find_map(|i| match i {
            Item::Message { text, .. } => Some(text.as_str()),
            _ => None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DialogKind;

    fn node(name: &str, ready: bool, note: Option<&str>) -> NodeView {
        NodeView {
            name: name.into(),
            ready,
            note: note.map(Into::into),
        }
    }

    fn fold(events: Vec<ThreadEvent>) -> ThreadView {
        let mut view = ThreadView::default();
        events.into_iter().for_each(|e| view.apply(e));
        view
    }

    fn msg(role: Role, text: &str) -> Item {
        Item::Message {
            role,
            text: text.into(),
        }
    }

    #[test]
    fn streamed_text_is_replaced_by_the_final_message() {
        let view = fold(vec![
            ThreadEvent::Nodes {
                nodes: vec![node("laptop", true, None)],
            },
            ThreadEvent::Message {
                role: Role::User,
                text: "hi".into(),
            },
            ThreadEvent::RunQueued {
                run: 1,
                waiting: None,
            },
            ThreadEvent::RunStarted {
                run: 1,
                resumed: false,
                node: Some("laptop".into()),
                why: Some("least busy machine".into()),
            },
            ThreadEvent::Delta {
                run: 1,
                text: "Hel".into(),
            },
            ThreadEvent::Delta {
                run: 1,
                text: "lo".into(),
            },
        ]);
        assert_eq!(view.streaming.as_deref(), Some("Hello"));
        assert_eq!(view.status(), "laptop online · working on laptop…");

        let mut view = view;
        view.apply(ThreadEvent::Message {
            role: Role::Assistant,
            text: "Hello!".into(),
        });
        view.apply(ThreadEvent::RunEnded {
            run: 1,
            outcome: RunOutcome::Completed,
            error: None,
        });
        assert_eq!(view.streaming, None);
        assert_eq!(
            view.items,
            vec![msg(Role::User, "hi"), msg(Role::Assistant, "Hello!")]
        );
        assert_eq!(view.status(), "laptop online");
        assert_eq!(view.last_message(), Some("Hello!"));
    }

    #[test]
    fn a_stopped_run_keeps_its_partial_text_and_says_so() {
        let view = fold(vec![
            ThreadEvent::RunStarted {
                run: 1,
                resumed: true,
                node: None,
                why: None,
            },
            ThreadEvent::Delta {
                run: 1,
                text: "half".into(),
            },
            ThreadEvent::RunEnded {
                run: 1,
                outcome: RunOutcome::Cancelled,
                error: None,
            },
            ThreadEvent::RunEnded {
                run: 2,
                outcome: RunOutcome::Failed,
                error: Some("node lost".into()),
            },
        ]);
        assert_eq!(
            view.items,
            vec![
                msg(Role::Assistant, "half"),
                Item::Notice {
                    text: "Stopped.".into(),
                    error: false
                },
                Item::Notice {
                    text: "The run failed: node lost".into(),
                    error: true
                },
            ]
        );
        assert_eq!(view.run, RunState::Idle);
    }

    #[test]
    fn cards_close_by_id_and_count_while_open() {
        let card = |id: &str| ThreadEvent::DialogOpened {
            dialog: Dialog {
                id: id.into(),
                run: 1,
                kind: DialogKind::Approval {
                    tool: "write".into(),
                    input: serde_json::json!({}),
                    uncertain: false,
                },
            },
        };
        let mut view = fold(vec![card("a"), card("b")]);
        assert_eq!(view.waiting(), 2);
        view.apply(ThreadEvent::DialogClosed {
            id: "a".into(),
            outcome: "Allowed once".into(),
        });
        assert_eq!(view.waiting(), 1);
        assert!(
            matches!(&view.items[0], Item::Card { outcome: Some(o), .. } if o == "Allowed once")
        );
        view.apply(ThreadEvent::Nodes { nodes: vec![] });
        assert_eq!(view.status(), "No node connected");
        view.apply(ThreadEvent::Nodes {
            nodes: vec![
                node("gpu-box", true, None),
                node("laptop", false, Some("on battery")),
            ],
        });
        view.apply(ThreadEvent::RunQueued {
            run: 2,
            waiting: Some("gpu-box is busy".into()),
        });
        assert_eq!(
            view.status(),
            "gpu-box, laptop (on battery) online · waiting: gpu-box is busy"
        );
    }
}
