//! The thread reducer: folds [`ThreadEvent`]s into what a client shows
//! (DESIGN §12). Every client uses this one function, so the web, desktop
//! and Android apps can't disagree about what happened.

use crate::{Dialog, NodeView, Role, RunOutcome, StepKind, ThreadEvent};

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
    /// A file the owner sent.
    Attached {
        id: i64,
        name: String,
        size: u64,
        image: bool,
    },
    /// A file the bot shared.
    Artifact {
        id: i64,
        name: String,
        version: i32,
        size: u64,
    },
    /// Tool calls in a row, shown as one line (DESIGN §12.6). `open` until
    /// another item or the run's end follows; `from` and `to` are its first
    /// step's start and the latest thing known about it, in milliseconds.
    Steps {
        steps: Vec<Step>,
        open: bool,
        from: i64,
        to: i64,
    },
    /// One bot handed another a job (DESIGN §12.7); `from` and `to` are slugs.
    /// `answered` is how it ended, `None` while the answer hasn't come.
    Asked {
        from: String,
        to: String,
        ticket: i64,
        answered: Option<bool>,
    },
    /// The answer went back from the teammate (`from`) to the asker (`to`).
    Answered {
        from: String,
        to: String,
        ticket: i64,
        ok: bool,
    },
}

/// The line for an `Asked` item, given the bots' names:
/// "Researcher asked Coder · OB-142", and "· waiting" until the answer comes.
pub fn asked_line(from: &str, to: &str, ticket: i64, answered: Option<bool>) -> String {
    let waiting = if answered.is_none() {
        " · waiting"
    } else {
        ""
    };
    format!("{from} asked {to} · OB-{ticket}{waiting}")
}

/// The line for an `Answered` item, given the bots' names.
pub fn answered_line(from: &str, to: &str, ticket: i64, ok: bool) -> String {
    let how = if ok {
        "answered"
    } else {
        "couldn't finish for"
    };
    format!("{from} {how} {to} · OB-{ticket}")
}

/// One tool call. `id` is only unique within `run`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub run: i64,
    pub id: String,
    pub label: String,
    pub kind: StepKind,
    /// How it ended; `None` while it runs, or if its end was never reported.
    pub done: Option<bool>,
}

/// The line for a `Steps` item: what it's doing while open, then
/// "Worked for 2m 10s · 7 steps".
pub fn steps_line(steps: &[Step], open: bool, from: i64, to: i64) -> String {
    let count = match steps.len() {
        1 => "1 step".to_owned(),
        n => format!("{n} steps"),
    };
    if open {
        let now = steps.iter().rev().find(|s| s.done.is_none());
        let label = now.or(steps.last()).map_or("Working", |s| &s.label);
        return format!("{label} · {count}");
    }
    let secs = (to - from).max(0) / 1000;
    let took = match secs {
        0..60 => format!("{secs}s"),
        60..3600 => format!("{}m {}s", secs / 60, secs % 60),
        _ => format!("{}h {}m", secs / 3600, secs % 3600 / 60),
    };
    format!("Worked for {took} · {count}")
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
    /// The label of the newest unfinished step, for the status line.
    pub doing: Option<String>,
    /// The routine run whose two lines (its notice and prompt) start at this
    /// item, until it ends; a `Quiet` takes them out again.
    pub routine: Option<(i64, usize)>,
}

impl ThreadView {
    /// [`Self::apply_at`] for a caller that shows no times.
    pub fn apply(&mut self, event: ThreadEvent) {
        self.apply_at(event, 0);
    }

    /// Folds in an event that happened at `at` (milliseconds, `Envelope::at`).
    pub fn apply_at(&mut self, event: ThreadEvent, at: i64) {
        let before = self.items.len();
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
                self.doing = None;
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
                self.doing = None;
                // A run that ends with nothing more to say still ends its steps.
                // Only steps still open: an earlier run's are already timed.
                if let Some(Item::Steps { open, to, .. }) = self.items.last_mut()
                    && *open
                {
                    *open = false;
                    *to = at.max(*to);
                }
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
            ThreadEvent::Notice { text } => self.items.push(Item::Notice { text, error: false }),
            ThreadEvent::Routed { name, sure, .. } => self.items.push(Item::Notice {
                text: format!("Sent to {name} (System 1 was {sure}% sure)"),
                error: false,
            }),
            ThreadEvent::Attached {
                id,
                name,
                size,
                image,
            } => self.items.push(Item::Attached {
                id,
                name,
                size,
                image,
            }),
            ThreadEvent::Artifact {
                id,
                name,
                version,
                size,
            } => self.items.push(Item::Artifact {
                id,
                name,
                version,
                size,
            }),
            // The node list is for every thread; clients keep it beside their thread views.
            // A push is shown by the desktop app as a notification, not in the thread.
            ThreadEvent::Nodes { .. } | ThreadEvent::Push { .. } => {}
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
            ThreadEvent::StepStarted {
                run,
                id,
                label,
                kind,
            } => {
                self.doing = Some(label.clone());
                let step = Step {
                    run,
                    id,
                    label,
                    kind,
                    done: None,
                };
                match self.items.last_mut() {
                    Some(Item::Steps {
                        steps,
                        open: true,
                        to,
                        ..
                    }) => {
                        steps.push(step);
                        *to = at.max(*to);
                    }
                    _ => self.items.push(Item::Steps {
                        steps: vec![step],
                        open: true,
                        from: at,
                        to: at,
                    }),
                }
            }
            ThreadEvent::StepEnded { run, id, ok } => {
                // Not only the last fold-up: an approval card may sit between
                // a step's start and its end.
                let mut found = false;
                for item in self.items.iter_mut().rev() {
                    if let Item::Steps { steps, to, .. } = item
                        && let Some(step) = steps.iter_mut().find(|s| s.run == run && s.id == id)
                    {
                        step.done = Some(ok);
                        *to = at.max(*to);
                        found = true;
                        break;
                    }
                }
                // An end that matches no step changes nothing.
                if !found {
                    return;
                }
                // ponytail: a step whose end never arrives (a helper's call,
                // DESIGN §12.6) can come back here until the next step or the
                // run's end; end such steps on the server if that shows.
                self.doing = self.items.iter().rev().find_map(|item| match item {
                    Item::Steps { steps, .. } => steps
                        .iter()
                        .rev()
                        .find(|s| s.run == run && s.done.is_none())
                        .map(|s| s.label.clone()),
                    _ => None,
                });
            }
            ThreadEvent::Asked { from, to, ticket } => self.items.push(Item::Asked {
                from,
                to,
                ticket,
                answered: None,
            }),
            ThreadEvent::Answered {
                from,
                to,
                ticket,
                ok,
            } => {
                // The answer settles the ask it belongs to; one with no ask in
                // this thread still shows.
                for item in &mut self.items {
                    if let Item::Asked {
                        ticket: t,
                        answered,
                        ..
                    } = item
                        && *t == ticket
                    {
                        *answered = Some(ok);
                    }
                }
                self.items.push(Item::Answered {
                    from,
                    to,
                    ticket,
                    ok,
                });
            }
            ThreadEvent::RoutineFired { run, notice, text } => {
                self.routine = Some((run, self.items.len()));
                self.items.push(Item::Notice {
                    text: notice,
                    error: false,
                });
                self.items.push(Item::Message {
                    role: Role::User,
                    text,
                });
            }
            ThreadEvent::Quiet { run } => {
                // Its reply never arrives as a message; drop what streamed.
                self.streaming = None;
                if let Some((r, start)) = self.routine.take()
                    && r == run
                    && matches!(self.items.get(start), Some(Item::Notice { .. }))
                    && matches!(
                        self.items.get(start + 1),
                        Some(Item::Message {
                            role: Role::User,
                            ..
                        })
                    )
                {
                    self.items.drain(start..start + 2);
                }
                for item in &mut self.items {
                    if let Item::Steps { steps, .. } = item {
                        steps.retain(|s| s.run != run);
                    }
                }
                self.items
                    .retain(|i| !matches!(i, Item::Steps { steps, .. } if steps.is_empty()));
                return;
            }
        }
        // Whatever comes after a fold-up closes it to new steps.
        if self.items.len() > before
            && let Some(Item::Steps { open, to, .. }) =
                before.checked_sub(1).and_then(|i| self.items.get_mut(i))
            && *open
        {
            *open = false;
            *to = at.max(*to);
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
    pub fn status(&self, nodes: &[NodeView]) -> String {
        let nodes = if nodes.is_empty() {
            "No node connected".to_owned()
        } else {
            let list: Vec<String> = nodes
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
            (RunState::Running { resumed: false }, _) => match &self.doing {
                Some(doing) => format!(" · {doing}{on}…"),
                None => format!(" · working{on}…"),
            },
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

    fn start(run: i64, id: &str, label: &str) -> ThreadEvent {
        ThreadEvent::StepStarted {
            run,
            id: id.into(),
            label: label.into(),
            kind: StepKind::Other,
        }
    }

    fn end(run: i64, id: &str, ok: bool) -> ThreadEvent {
        ThreadEvent::StepEnded {
            run,
            id: id.into(),
            ok,
        }
    }

    /// Each event one second after the last, starting at 1 s.
    fn timed(events: Vec<ThreadEvent>) -> ThreadView {
        let mut view = ThreadView::default();
        for (i, e) in events.into_iter().enumerate() {
            view.apply_at(e, (i as i64 + 1) * 1000);
        }
        view
    }

    /// The fold-ups in a view: (labels with how each ended, open, line).
    type Fold = (Vec<(String, Option<bool>)>, bool, String);
    fn folds(view: &ThreadView) -> Vec<Fold> {
        view.items
            .iter()
            .filter_map(|i| match i {
                Item::Steps {
                    steps,
                    open,
                    from,
                    to,
                } => Some((
                    steps.iter().map(|s| (s.label.clone(), s.done)).collect(),
                    *open,
                    steps_line(steps, *open, *from, *to),
                )),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn steps_in_a_row_fold_into_one_line() {
        let mut view = timed(vec![
            start(1, "a", "Reading a file"),
            end(1, "a", true),
            start(1, "b", "Running a command"),
        ]);
        assert_eq!(view.items.len(), 1);
        assert_eq!(view.doing.as_deref(), Some("Running a command"));
        assert_eq!(folds(&view)[0].2, "Running a command · 2 steps");
        view.run = RunState::Running { resumed: false };
        assert_eq!(view.status(&[]), "No node connected · Running a command…");
        view.apply_at(end(1, "b", false), 4000);
        assert_eq!(view.doing, None);
        assert_eq!(
            folds(&view),
            vec![(
                vec![
                    ("Reading a file".into(), Some(true)),
                    ("Running a command".into(), Some(false))
                ],
                true,
                "Running a command · 2 steps".into()
            )]
        );
    }

    #[test]
    fn another_item_closes_the_fold_up_and_the_next_step_starts_a_new_one() {
        let view = timed(vec![
            start(1, "a", "Reading a file"),
            end(1, "a", true),
            ThreadEvent::Message {
                role: Role::Assistant,
                text: "Found it.".into(),
            },
            start(1, "b", "Writing a file"),
        ]);
        assert_eq!(view.items.len(), 3);
        let folds = folds(&view);
        // From the step's start at 1 s to the message at 3 s.
        assert_eq!(folds[0].2, "Worked for 2s · 1 step");
        assert!(!folds[0].1);
        assert_eq!(folds[1].2, "Writing a file · 1 step");
    }

    #[test]
    fn a_step_that_needed_approval_ends_behind_its_card_and_its_time_counts() {
        let card = ThreadEvent::DialogOpened {
            dialog: Dialog {
                id: "d".into(),
                run: 1,
                kind: DialogKind::Approval {
                    tool: "bash".into(),
                    input: serde_json::json!({}),
                    uncertain: false,
                },
            },
        };
        let mut view = timed(vec![start(1, "a", "Running a command"), card]);
        assert_eq!(view.doing.as_deref(), Some("Running a command"));
        // The same call id in another run is another step.
        view.apply_at(end(2, "a", true), 3000);
        assert_eq!(folds(&view)[0].0[0].1, None);
        view.apply_at(end(1, "a", true), 131_000);
        assert_eq!(view.doing, None);
        assert_eq!(
            folds(&view),
            vec![(
                vec![("Running a command".into(), Some(true))],
                false,
                "Worked for 2m 10s · 1 step".into()
            )]
        );
    }

    #[test]
    fn a_denied_call_is_a_failed_step_and_the_one_before_it_shows_again() {
        let view = timed(vec![
            start(1, "a", "Reading a file"),
            start(1, "b", "Running a command"),
            end(1, "b", false),
        ]);
        assert_eq!(view.doing.as_deref(), Some("Reading a file"));
        assert_eq!(
            folds(&view)[0].0[1],
            ("Running a command".into(), Some(false))
        );
    }

    #[test]
    fn a_run_that_ends_mid_step_closes_the_fold_up_and_clears_the_line() {
        let mut view = timed(vec![
            start(1, "a", "Running a command"),
            ThreadEvent::RunEnded {
                run: 1,
                outcome: RunOutcome::Completed,
                error: None,
            },
        ]);
        assert_eq!(view.doing, None);
        assert_eq!(
            folds(&view),
            vec![(
                vec![("Running a command".into(), None)],
                false,
                "Worked for 1s · 1 step".into()
            )]
        );
        // A later run that ends without adding anything doesn't stretch it.
        view.apply_at(
            ThreadEvent::RunEnded {
                run: 2,
                outcome: RunOutcome::Cancelled,
                error: None,
            },
            62_000,
        );
        assert_eq!(folds(&view)[0].2, "Worked for 1s · 1 step");
        view.items.pop(); // the "Stopped." notice
        // The next run's steps don't join it.
        view.apply_at(start(3, "a", "Reading a file"), 70_000);
        assert_eq!(view.items.len(), 2);
    }

    #[test]
    fn an_end_that_matches_no_step_leaves_the_line_alone() {
        let view = timed(vec![start(1, "a", "Reading a file"), end(2, "a", true)]);
        assert_eq!(view.doing.as_deref(), Some("Reading a file"));
    }

    fn asked(ticket: i64) -> ThreadEvent {
        ThreadEvent::Asked {
            from: "researcher".into(),
            to: "coder".into(),
            ticket,
        }
    }

    fn answered(ticket: i64, ok: bool) -> ThreadEvent {
        ThreadEvent::Answered {
            from: "coder".into(),
            to: "researcher".into(),
            ticket,
            ok,
        }
    }

    /// The hand-off lines in a view, with the slugs standing in for names.
    fn handoffs(view: &ThreadView) -> Vec<String> {
        view.items
            .iter()
            .filter_map(|i| match i {
                Item::Asked {
                    from,
                    to,
                    ticket,
                    answered,
                } => Some(asked_line(from, to, *ticket, *answered)),
                Item::Answered {
                    from,
                    to,
                    ticket,
                    ok,
                } => Some(answered_line(from, to, *ticket, *ok)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn an_answer_settles_the_ask_with_its_ticket_and_no_other() {
        let view = fold(vec![asked(142), asked(143), answered(143, true)]);
        assert_eq!(
            handoffs(&view),
            [
                "researcher asked coder · OB-142 · waiting",
                "researcher asked coder · OB-143",
                "coder answered researcher · OB-143",
            ]
        );
    }

    #[test]
    fn an_answer_that_never_comes_leaves_the_ask_waiting() {
        let view = fold(vec![
            asked(142),
            ThreadEvent::RunEnded {
                run: 1,
                outcome: RunOutcome::Completed,
                error: None,
            },
        ]);
        assert_eq!(
            handoffs(&view),
            ["researcher asked coder · OB-142 · waiting"]
        );
    }

    #[test]
    fn a_teammate_that_failed_answers_with_not_ok_and_a_lone_answer_still_shows() {
        let view = fold(vec![asked(142), answered(142, false), answered(7, true)]);
        assert_eq!(
            handoffs(&view),
            [
                "researcher asked coder · OB-142",
                "coder couldn't finish for researcher · OB-142",
                "coder answered researcher · OB-7",
            ]
        );
    }

    #[test]
    fn a_denied_ask_is_a_failed_step_and_no_hand_off() {
        // The server refused ask_bot, so it made no ticket and sent no `Asked`.
        let view = timed(vec![
            start(1, "a", "Checking with Coder"),
            end(1, "a", false),
        ]);
        assert!(handoffs(&view).is_empty());
        assert_eq!(
            folds(&view)[0].0,
            [("Checking with Coder".into(), Some(false))]
        );
    }

    #[test]
    fn a_hand_off_closes_the_fold_up_and_its_step_still_ends() {
        let view = timed(vec![
            start(1, "a", "Checking with Coder"),
            asked(142),
            end(1, "a", true),
        ]);
        assert_eq!(view.items.len(), 2);
        assert_eq!(view.doing, None);
        assert_eq!(
            folds(&view)[0].0,
            [("Checking with Coder".into(), Some(true))]
        );
    }

    #[test]
    fn long_work_is_told_in_hours() {
        let step = Step {
            run: 1,
            id: "a".into(),
            label: "Working".into(),
            kind: StepKind::Other,
            done: Some(true),
        };
        let line = steps_line(&[step], false, 0, 3_725_000);
        assert_eq!(line, "Worked for 1h 2m · 1 step");
    }

    #[test]
    fn streamed_text_is_replaced_by_the_final_message() {
        let laptop = [node("laptop", true, None)];
        let view = fold(vec![
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
        assert_eq!(view.status(&laptop), "laptop online · working on laptop…");

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
        assert_eq!(view.status(&laptop), "laptop online");
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
        assert_eq!(view.status(&[]), "No node connected");
        let nodes = [
            node("gpu-box", true, None),
            node("laptop", false, Some("on battery")),
        ];
        view.apply(ThreadEvent::RunQueued {
            run: 2,
            waiting: Some("gpu-box is busy".into()),
        });
        assert_eq!(
            view.status(&nodes),
            "gpu-box, laptop (on battery) online · waiting: gpu-box is busy"
        );
    }

    #[test]
    fn a_quiet_routine_run_leaves_nothing_behind() {
        let fired = |run: i64| ThreadEvent::RoutineFired {
            run,
            notice: "Routine \"Mail\" (schedule)".into(),
            text: "Check the mail.".into(),
        };
        let step = |run: i64, id: &str| ThreadEvent::StepStarted {
            run,
            id: id.into(),
            label: "Checking mail".into(),
            kind: StepKind::Google,
        };
        let ended = |run: i64| ThreadEvent::RunEnded {
            run,
            outcome: RunOutcome::Completed,
            error: None,
        };
        let mut view = fold(vec![
            ThreadEvent::Message {
                role: Role::User,
                text: "hello".into(),
            },
            fired(7),
            step(7, "a"),
            ThreadEvent::StepEnded {
                run: 7,
                id: "a".into(),
                ok: true,
            },
            ThreadEvent::Delta {
                run: 7,
                text: crate::QUIET_REPLY.into(),
            },
            ThreadEvent::Quiet { run: 7 },
            ended(7),
        ]);
        assert_eq!(view.items, vec![msg(Role::User, "hello")]);
        assert_eq!(view.streaming, None);

        // One with something to say stays, prompt and all.
        for e in [
            fired(8),
            step(8, "b"),
            ThreadEvent::Message {
                role: Role::Assistant,
                text: "Two new emails.".into(),
            },
            ended(8),
            // A quiet for another run takes nothing.
            ThreadEvent::Quiet { run: 9 },
        ] {
            view.apply(e);
        }
        assert_eq!(view.items.len(), 5);
        assert!(matches!(&view.items[1], Item::Notice { text, .. } if text.starts_with("Routine")));
        assert_eq!(view.items[2], msg(Role::User, "Check the mail."));
        assert!(matches!(&view.items[3], Item::Steps { steps, .. } if steps.len() == 1));
        assert_eq!(view.items[4], msg(Role::Assistant, "Two new emails."));
    }
}
