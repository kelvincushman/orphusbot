//! The thread reducer: folds [`ThreadEvent`]s into what a client shows
//! (DESIGN §12). Every client uses this one function, so the web, desktop
//! and Android apps can't disagree about what happened.

use crate::{Dialog, Role, RunOutcome, ThreadEvent};

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

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ThreadView {
    pub items: Vec<Item>,
    /// Assistant text still streaming in, shown after `items`.
    pub streaming: Option<String>,
    pub run: RunState,
    /// The connected node's name, if one is online.
    pub node: Option<String>,
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
            ThreadEvent::RunQueued { .. } => {
                self.run = RunState::Queued;
                self.streaming = None;
            }
            ThreadEvent::RunStarted { resumed, .. } => self.run = RunState::Running { resumed },
            ThreadEvent::RunEnded { outcome, error, .. } => {
                self.run = RunState::Idle;
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
            ThreadEvent::NodeStatus { online, node } => {
                self.node = node.filter(|_| online);
            }
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

    /// One line for the header, such as "laptop online · working…".
    pub fn status(&self) -> String {
        let node = match &self.node {
            Some(name) => format!("{name} online"),
            None => "No node connected".to_owned(),
        };
        let run = match self.run {
            RunState::Idle => "",
            RunState::Queued => " · waiting for a node",
            RunState::Running { resumed: true } => " · resuming after an interruption…",
            RunState::Running { resumed: false } => " · working…",
        };
        format!("{node}{run}")
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
            ThreadEvent::NodeStatus {
                online: true,
                node: Some("laptop".into()),
            },
            ThreadEvent::Message {
                role: Role::User,
                text: "hi".into(),
            },
            ThreadEvent::RunQueued { run: 1 },
            ThreadEvent::RunStarted {
                run: 1,
                resumed: false,
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
        assert_eq!(view.status(), "laptop online · working…");

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
        view.apply(ThreadEvent::NodeStatus {
            online: false,
            node: None,
        });
        assert_eq!(view.status(), "No node connected");
    }
}
