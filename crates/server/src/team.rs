//! Bots working as a team (DESIGN §5.3). A bot hands a teammate a task with the
//! bridge's `ask_bot` tool: the server makes it a ticket for that bot and starts
//! it, and when that run ends the answer goes back to the asker as a new message,
//! so it carries on. Every action either bot takes still goes through the gate.
//! Hand-offs stop three deep, a bot can't ask itself, and a job a teammate
//! asked for can't be handed back to them.
//!
//! A run that's blocked doesn't end, so the checker ([check], on the server's
//! reconcile tick) speaks up for it: a card left unanswered reaches the asker
//! and the Orchestrator, and a hand-off left on the board starts once its bot
//! is free. No model runs for this unless there's news.

use std::collections::HashMap;

use axum::Json;
use axum::extract::State;
use orphusbot_proto::{Role, RunOutcome, ThreadEvent};
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::{
    ApiError, App, Shared, db, dialog_closed, gate, internal, lock, missions, record, respond,
    runs, submit, ui_response,
};

/// Title of the bridge's `ask_bot` dialog.
pub const ASK_TITLE: &str = "orphusbot-ask";
/// Title of the bridge's `team_status` dialog.
pub const STATUS_TITLE: &str = "orphusbot-team";
const MAX_DEPTH: i32 = 3;
/// Title of the bridge's `accept_card` dialog.
pub const ACCEPT_TITLE: &str = "orphusbot-accept";
/// The owner's main bot, told about every stuck hand-off (D-037).
pub(crate) const ORCHESTRATOR: &str = "orchestrator";

/// A hand-off that isn't finished, with the card its run is blocked on, if any.
#[derive(Debug)]
pub struct Open {
    pub id: i64,
    pub title: String,
    pub status: String,
    pub bot: String,
    pub worker: String,
    pub asker: String,
    mission: Option<i64>,
    told: Option<String>,
    card: Option<String>,
    pub card_text: Option<String>,
    card_stale: bool,
}

/// Every unfinished hand-off from the last three days, oldest first.
pub async fn open(db: &PgPool) -> sqlx::Result<Vec<Open>> {
    sqlx::query_as!(
        Open,
        r#"select t.id, t.title, t.status::text as "status!", w.slug as bot, w.name as worker,
                  a.slug as asker, t.mission_id as mission, t.asker_told as told, c.id as "card?", c.text as "card_text?",
                  coalesce(c.stale, false) as "card_stale!"
           from ticket t join bot w on w.id = t.bot_id join bot a on a.id = t.asked_by
           left join lateral (
               select e.body -> 'dialog' ->> 'id' as id,
                      coalesce(e.body -> 'dialog' -> 'kind' ->> 'message',
                               e.body -> 'dialog' -> 'kind' ->> 'title',
                               e.body -> 'dialog' -> 'kind' ->> 'reason',
                               'permission to use ' || (e.body -> 'dialog' -> 'kind' ->> 'tool')) as text,
                      e.created_at < now() - interval '2 minutes' as stale
               from run r join event e on e.thread_id = r.thread_id
               where r.ticket_id = t.id and r.status = 'running'
                 and e.body ->> 'type' = 'dialog_opened'
                 and (e.body -> 'dialog' ->> 'run')::bigint = r.id
                 and not exists (select 1 from event x
                                 where x.thread_id = e.thread_id and x.seq > e.seq
                                   and x.body ->> 'type' = 'dialog_closed'
                                   and x.body ->> 'id' = e.body -> 'dialog' ->> 'id')
               order by e.seq limit 1
           ) c on true
           where t.status in ('todo', 'doing') and t.created_at > now() - interval '3 days'
           order by t.id"#
    )
    .fetch_all(db)
    .await
}

/// `GET /api/team/open`: who each bot is waiting on, for the faces.
pub async fn open_list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let open = open(&app.db)
        .await
        .map_err(|e| internal("listing hand-offs", e))?;
    let list: Vec<Value> = open
        .iter()
        .map(|t| json!({ "id": t.id, "bot": t.bot, "asked_by": t.asker, "blocked": t.card.is_some() }))
        .collect();
    Ok(Json(json!({ "open": list })))
}

/// May the Orchestrator accept this open card?
fn safe(app: &App, card: &str) -> bool {
    lock(&app.rt).dialogs.get(card).is_some_and(|p| p.safe)
}

/// The Orchestrator accepts a teammate's safe card (D-062). The server decides
/// what's safe, so nothing a bot reads can widen this.
pub async fn accept(app: &App, asker: &str, request: &Value) -> String {
    if asker != ORCHESTRATOR {
        return "error:only the Orchestrator can accept a card".into();
    }
    let Some(id) = request["card"].as_str() else {
        return "error:give the card's id, from team_status".into();
    };
    let pending = {
        let mut rt = lock(&app.rt);
        match rt.dialogs.get(id) {
            None => return "error:that card is no longer open".into(),
            Some(p) if p.thread.bot == asker => {
                return "error:you can't accept your own card".into();
            }
            Some(p) if !p.safe || p.tool_call_id.is_none() => {
                return "error:that card is Kelvin's to answer; tell him what's needed".into();
            }
            Some(_) => rt.dialogs.remove(id),
        }
    };
    let Some(pending) = pending else {
        return "error:that card is no longer open".into();
    };
    let call = pending.tool_call_id.clone().unwrap_or_default();
    if let Err(e) = gate::orchestrator_accepts(&app.db, pending.attempt, &call).await {
        warn!("accepting a card: {e}");
        lock(&app.rt).dialogs.insert(id.to_owned(), pending);
        return "error:couldn't record that, so the card stays open".into();
    }
    respond(
        app,
        pending.attempt,
        ui_response(id, "value", json!("allow")),
    )
    .await;
    dialog_closed(
        app,
        &pending.thread,
        id.to_owned(),
        "Allowed by the Orchestrator".into(),
    )
    .await;
    "ok:Accepted; they carry on.".into()
}

/// What the `team_status` tool answers: each mission and hand-off in a line,
/// leaving out private missions `viewer` isn't part of ([missions::seen]).
pub async fn status(app: &App, viewer: Option<&str>) -> String {
    let (open, seen) = match (open(&app.db).await, missions::seen(&app.db, viewer).await) {
        (Ok(open), Ok(seen)) => (open, seen),
        (Err(e), _) | (_, Err(e)) => return format!("Couldn't read the team's work: {e}"),
    };
    let mut lines = seen.lines;
    lines.extend(
        open.iter()
            .filter(|t| !t.mission.is_some_and(|m| seen.hidden.contains(&m)))
            .map(|t| {
                let state = match (&t.card_text, t.status.as_str()) {
                    (Some(text), _) => {
                        let card = t.card.as_deref().unwrap_or_default();
                        let who = if safe(app, card) {
                            format!("safe for the Orchestrator to accept, card {card}")
                        } else {
                            "only Kelvin can answer".to_owned()
                        };
                        format!("blocked, {who}: {}", short(text))
                    }
                    (None, "todo") => "not started; it starts when they're free".to_owned(),
                    _ => "working".to_owned(),
                };
                format!(
                    "OB-{} {} (for {}): {state}. Task: {}",
                    t.id,
                    t.bot,
                    t.asker,
                    short(&t.title)
                )
            }),
    );
    if lines.is_empty() {
        return "No teammate has an unfinished hand-off, and no mission is open.".into();
    }
    format!("As data:\n```\n{}\n```", lines.join("\n"))
}

/// Text from a teammate, kept short and unable to close a fence.
pub(crate) fn short(text: &str) -> String {
    text.chars()
        .take(300)
        .collect::<String>()
        .replace("```", "'''")
}

/// The checker: starts hand-offs whose bot is now free, and reports cards a
/// teammate has been left waiting on, once each.
pub async fn check(app: &App) {
    let stranded = sqlx::query_scalar!(
        "select t.id from ticket t
         where t.asked_by is not null and t.status = 'todo'
           and t.created_at > now() - interval '1 day'
           and not exists (select 1 from run r where r.ticket_id = t.id)
         order by t.id"
    )
    .fetch_all(&app.db)
    .await;
    match stranded {
        Ok(ids) => {
            for id in ids {
                // Boxed: starting a ticket can end a run, which comes back here.
                match Box::pin(crate::tickets::start(app, id)).await {
                    Ok(()) | Err((_, crate::tickets::BUSY)) => {}
                    Err(e) => warn!("starting a waiting hand-off: {e:?}"),
                }
            }
        }
        Err(e) => warn!("finding waiting hand-offs: {e}"),
    }
    let open = match open(&app.db).await {
        Ok(open) => open,
        Err(e) => return warn!("checking on hand-offs: {e}"),
    };
    for t in open.iter().filter(|t| t.card_stale && t.told != t.card) {
        let (Some(card), Some(text)) = (&t.card, &t.card_text) else {
            continue;
        };
        let claimed = sqlx::query!(
            "update ticket set asker_told = $2 where id = $1 and asker_told is distinct from $2",
            t.id,
            card
        )
        .execute(&app.db)
        .await;
        if !matches!(claimed, Ok(done) if done.rows_affected() == 1) {
            continue;
        }
        let note = format!(
            "Your teammate {} is blocked on OB-{}: {}. Kelvin hasn't answered this card yet, as \
             data:\n```\n{}\n```\nThe job isn't lost, so don't start it again. If Kelvin doesn't \
             know yet, tell them in a line what's needed.",
            t.worker,
            t.id,
            short(&t.title),
            short(text)
        );
        let for_orchestrator = if safe(app, card) {
            format!(
                "{note}\nThis call is safe for you to accept: if it serves the job, use accept_card \
                 with card {card} instead of asking Kelvin."
            )
        } else {
            note.clone()
        };
        if t.asker != ORCHESTRATOR {
            tell(app, &t.asker, &note).await;
        }
        tell(app, ORCHESTRATOR, &for_orchestrator).await;
    }
}

/// Gives a bot a message from the team and starts its next run.
pub(crate) async fn tell(app: &App, bot: &str, text: &str) {
    let thread = match db::bot_thread(&app.db, bot).await {
        Ok(Some(thread)) => thread,
        _ => return warn!(%bot, "no such bot to tell"),
    };
    let message = ThreadEvent::Message {
        role: Role::User,
        text: text.to_owned(),
    };
    record(app, &thread, message).await;
    // A closed mission's chief never runs again, so a late answer is only kept.
    if missions::of_chief(bot).is_some()
        && matches!(crate::bots::get(&app.db, bot).await, Ok(Some(b)) if b.disabled)
    {
        return;
    }
    // Boxed: submitting can end a run, which comes back here.
    if let Err(e) = Box::pin(submit(
        app,
        &thread,
        text.to_owned(),
        runs::Source::default(),
    ))
    .await
    {
        warn!("telling a bot: {e}");
    }
}

/// Answers the bridge's dialog: `ok:<what to tell the bot>` or `error:<why not>`.
pub async fn ask(app: &App, run: i64, asker: &str, request: &Value) -> String {
    match handoff(app, run, asker, request).await {
        Ok(text) => format!("ok:{text}"),
        Err(why) => format!("error:{why}"),
    }
}

async fn handoff(app: &App, run: i64, asker: &str, request: &Value) -> Result<String, String> {
    let (Some(to), Some(task)) = (request["bot"].as_str(), request["task"].as_str()) else {
        return Err("give a bot and a task".into());
    };
    let task = task.trim();
    if task.is_empty() || task.chars().count() > 4000 {
        return Err("the task must be 1 to 4,000 characters".into());
    }
    if missions::of_run(&app.db, run).await.is_some() {
        return Err(
            "you're on a mission, so finish your turn and say what you need; your Chief of Staff \
             will hand it on"
                .into(),
        );
    }
    let to = to.trim().to_lowercase();
    if to == asker {
        return Err("you can't ask yourself; do it, or ask a teammate".into());
    }
    let roster = crate::bots::all(&app.db)
        .await
        .map_err(|e| format!("couldn't read the team: {e}"))?;
    let Some(bot) = roster.iter().find(|b| b.slug == to && !b.disabled) else {
        let names: Vec<&str> = roster
            .iter()
            .filter(|b| !b.disabled && b.slug != asker && missions::of_chief(&b.slug).is_none())
            .map(|b| b.slug.as_str())
            .collect();
        return Err(format!(
            "no teammate called {to}; ask one of: {}",
            names.join(", ")
        ));
    };
    let depth = sqlx::query_scalar!(
        r#"select coalesce(t.ask_depth, 0) as "depth!" from run r left join ticket t on t.id = r.ticket_id where r.id = $1"#,
        run
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| format!("couldn't read this run: {e}"))?;
    if depth >= MAX_DEPTH {
        return Err("this is already three hand-offs deep; finish it yourself".into());
    }
    // A job a teammate asked for doesn't go back to them: that's how two bots
    // each thinking the other owned a job passed it to and fro (D-049).
    let asked_by = sqlx::query_scalar!(
        r#"select b.slug from run r join ticket t on t.id = r.ticket_id join bot b on b.id = t.asked_by where r.id = $1"#,
        run
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| format!("couldn't read this run: {e}"))?;
    if asked_by.as_deref() == Some(to.as_str()) {
        return Err(format!(
            "{to} asked you for this, so don't hand it back. Finish your turn with your answer, \
             or say plainly that you can't do it and why (for example, a tool you don't have); \
             that goes back to {to} by itself"
        ));
    }
    let title: String = task
        .lines()
        .next()
        .unwrap_or(task)
        .chars()
        .take(200)
        .collect();
    let mission = missions::of_chief(asker);
    let id = sqlx::query_scalar!(
        "insert into ticket (title, body, urgency, bot_id, asked_by, ask_depth, mission_id)
         values ($1, $2, 'hour', (select id from bot where slug = $3), (select id from bot where slug = $4), $5, $6)
         returning id",
        title,
        task,
        to,
        asker,
        depth + 1,
        mission
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| format!("couldn't make the ticket: {e}"))?;
    if mission.is_some() {
        sqlx::query!(
            "update mission set team = array_append(team, $2), updated_at = now()
             where id = $1 and not ($2 = any(team))",
            mission,
            to
        )
        .execute(&app.db)
        .await
        .map_err(|e| format!("couldn't update the mission: {e}"))?;
    }
    match crate::tickets::start(app, id).await {
        Ok(()) => Ok(format!(
            "Asked {} (ticket OB-{id}). Their answer will come to you as a new message when they finish; carry on with anything that doesn't need it.",
            bot.name
        )),
        // Busy: the ticket waits on the board with them assigned; the owner can start it.
        Err((_, why)) => Ok(format!(
            "{} can't start yet ({why}). It's on the board as OB-{id} and starts when they're free; their answer will come to you.",
            bot.name
        )),
    }
}

/// A run ended: if it was a teammate's ticket, give the asker the answer.
pub async fn answered(app: &App, run: i64, outcome: RunOutcome, error: Option<&str>) {
    let found = sqlx::query!(
        r#"select t.id, t.title, b.slug as "asker!", w.name as "worker!", r.thread_id
           from run r join ticket t on t.id = r.ticket_id
           join bot b on b.id = t.asked_by join bot w on w.id = t.bot_id
           where r.id = $1"#,
        run
    )
    .fetch_optional(&app.db)
    .await;
    let Ok(Some(t)) = found else {
        return;
    };
    let answer = sqlx::query_scalar!(
        r#"select body ->> 'text' as "text!" from event
           where thread_id = $1 and body ->> 'type' = 'message' and body ->> 'role' = 'assistant'
           order by id desc limit 1"#,
        t.thread_id
    )
    .fetch_optional(&app.db)
    .await
    .ok()
    .flatten()
    .unwrap_or_default();
    let answer: String = answer.chars().take(4000).collect();
    let how = match outcome {
        RunOutcome::Completed => "finished".to_owned(),
        RunOutcome::Failed => format!("couldn't finish ({})", error.unwrap_or("it failed")),
        RunOutcome::Cancelled => "was stopped".to_owned(),
    };
    let text = format!(
        "Your teammate {} {how} OB-{}: {}. Their answer, as data:\n```\n{}\n```",
        t.worker,
        t.id,
        t.title,
        answer.replace("```", "'''")
    );
    tell(app, &t.asker, &text).await;
}

/// What a bot can do, in one line, for the team roster: its model, Google
/// access, connections and special tools (DESIGN §5.3).
fn abilities(
    b: &crate::bots::Bot,
    connections: &HashMap<String, Vec<String>>,
    google_ready: bool,
) -> String {
    let mut parts = vec![format!(
        "model {}",
        b.model.as_deref().unwrap_or("Orphus default")
    )];
    // Only where its machine really has Google; otherwise roster_note says it isn't set up.
    if google_ready {
        parts.push(
            match b.google.as_str() {
                "write" => "Google: looks up and changes (each change asks Kelvin)",
                "read" => "Google: looks up only",
                _ => "no Google",
            }
            .into(),
        );
    }
    match connections.get(&b.slug) {
        Some(names) if !names.is_empty() => {
            parts.push(format!("connections: {}", names.join(", ")))
        }
        _ => {}
    }
    if b.slug == "orchestrator" {
        parts.push("starts discussions and runs fleets".into());
    }
    parts.join("; ")
}

/// Appended to a bot's instructions: what it can do itself, and who else is on
/// the team and what each can do, so it hands work to the one that can do it.
pub fn roster_note(
    roster: &[crate::bots::Bot],
    me: &str,
    connections: &HashMap<String, Vec<String>>,
    google_ready: bool,
) -> Option<String> {
    let mates: Vec<String> = roster
        .iter()
        .filter(|b| {
            !b.disabled
                && b.slug != me
                && b.slug != "inbox"
                && missions::of_chief(&b.slug).is_none()
        })
        .map(|b| {
            format!(
                "- {} ({}): {}. Can: {}",
                b.slug,
                b.name,
                b.remit,
                abilities(b, connections, google_ready)
            )
        })
        .collect();
    let mine = roster
        .iter()
        .find(|b| b.slug == me)
        .map(|b| abilities(b, connections, google_ready));
    (!mates.is_empty()).then(|| {
        format!(
            "\n\nYou: {}. If a job needs something you can't do (say, changing something in Google), hand it to the \
             teammate who can with the ask_bot tool; their answer comes back to you as a message, and you hear if they get stuck. \
             Before you say anything is pending, look with the team_status tool. Files you both \
             need can go in /shared.\n\nYour teammates and what each can do:\n{}",
            mine.unwrap_or_default(),
            mates.join("\n")
        ) + if me == ORCHESTRATOR {
            "\n\nYou may accept a teammate's safe card with accept_card; team_status shows which. \
             Send, pay, delete, merge and publish stay Kelvin's.\n\nA big new piece of work, as opposed to \
             everyday jobs like blog posts and social media, gets its own Chief of Staff: start it with \
             start_mission and suggest its team. Missions are visible to the team unless Kelvin says private. \
             update_mission marks one private or closes it."
        } else {
            ""
        } + if google_ready {
            ""
        } else {
            "\n\nGoogle (Gmail, Calendar, Tasks, Drive) isn't set up yet, so no bot can use it. If a task needs it, \
             tell Kelvin plainly rather than handing it to a teammate."
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use orphusbot_proto::{Dialog, DialogKind};
    use runs::Submitted;

    async fn bot(db: &PgPool, slug: &str, remit: &str) {
        let id: i64 = sqlx::query_scalar!(
            "insert into bot (slug, name, remit) values ($1, initcap($1), $2) returning id",
            slug,
            remit
        )
        .fetch_one(db)
        .await
        .unwrap();
        sqlx::query!("insert into thread (bot_id) values ($1)", id)
            .execute(db)
            .await
            .unwrap();
    }

    #[sqlx::test]
    async fn the_checker_reports_a_stuck_teammate_once_per_card(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        for slug in ["researcher", "coder"] {
            bot(&db, slug, "x").await;
        }
        let researcher = db::bot_thread(&db, "researcher").await.unwrap().unwrap();
        let Submitted::Queued(run) =
            runs::submit(&db, researcher.id, "compare", runs::Source::default())
                .await
                .unwrap()
        else {
            panic!("expected a run")
        };
        let asked = ask(
            &app,
            run,
            "researcher",
            &json!({ "bot": "coder", "task": "benchmark" }),
        )
        .await;
        assert!(asked.starts_with("ok:Asked Coder"), "{asked}");
        let coder_run: i64 = sqlx::query_scalar!(
            r#"select r.id as "id!" from run r join ticket t on t.id = r.ticket_id"#
        )
        .fetch_one(&db)
        .await
        .unwrap();
        sqlx::query!(
            "update run set status = 'running', node = 'n', lease_expires_at = now() + interval '1 hour'
             where id = $1",
            coder_run
        )
        .execute(&db)
        .await
        .unwrap();
        let coder = db::bot_thread(&db, "coder").await.unwrap().unwrap();
        let dialog = Dialog {
            id: "card-1".into(),
            run: coder_run,
            kind: DialogKind::Approval {
                tool: "mcp:github_search_code".into(),
                input: json!({}),
                uncertain: false,
            },
        };
        db::append(&db, coder.id, &ThreadEvent::DialogOpened { dialog })
            .await
            .unwrap();
        let told = |bot: i64| {
            let db = db.clone();
            async move {
                sqlx::query_scalar!(
                    r#"select count(*) as "n!" from event
                       where thread_id = $1 and body ->> 'text' like 'Your teammate Coder is blocked%'"#,
                    bot
                )
                .fetch_one(&db)
                .await
                .unwrap()
            }
        };
        let orchestrator = db::bot_thread(&db, "orchestrator").await.unwrap().unwrap();

        // A fresh card is left alone: the owner may be about to tap it.
        check(&app).await;
        assert_eq!(told(researcher.id).await, 0);
        assert!(
            status(&app, Some("orchestrator"))
                .await
                .contains("permission to use mcp:github_search_code")
        );

        sqlx::query!(
            "update event set created_at = now() - interval '3 minutes' where thread_id = $1",
            coder.id
        )
        .execute(&db)
        .await
        .unwrap();
        check(&app).await;
        check(&app).await;
        assert_eq!(
            (told(researcher.id).await, told(orchestrator.id).await),
            (1, 1)
        );

        // An answered card is no longer blocking.
        db::append(
            &db,
            coder.id,
            &ThreadEvent::DialogClosed {
                id: "card-1".into(),
                outcome: "allow".into(),
            },
        )
        .await
        .unwrap();
        assert!(open(&db).await.unwrap()[0].card.is_none());
    }

    #[sqlx::test]
    async fn the_orchestrator_accepts_only_a_teammates_safe_card(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        bot(&db, "coder", "x").await;
        let coder = db::bot_thread(&db, "coder").await.unwrap().unwrap();
        let mine = db::bot_thread(&db, ORCHESTRATOR).await.unwrap().unwrap();
        let Submitted::Queued(run) = runs::submit(&db, coder.id, "go", runs::Source::default())
            .await
            .unwrap()
        else {
            panic!("expected a run")
        };
        sqlx::query!(
            "insert into effect (run_id, fence, tool_call_id, tool, input, state)
             values ($1, 0, 'call', 'mcp:github_search_code', '{}', 'pending')",
            run
        )
        .execute(&db)
        .await
        .unwrap();
        let attempt = orphusbot_proto::Attempt { run, fence: 0 };
        let card = |thread: &db::Thread, safe: bool| crate::Pending {
            attempt,
            thread: thread.clone(),
            tool_call_id: Some("call".into()),
            takeover: false,
            safe,
        };
        let put = |id: &str, pending| {
            lock(&app.rt).dialogs.insert(id.to_owned(), pending);
        };
        put("safe", card(&coder, true));
        put("kelvins", card(&coder, false));
        put("own", card(&mine, true));

        let accept = |bot: &'static str, id: &'static str| {
            let app = &app;
            async move { accept(app, bot, &json!({ "card": id })).await }
        };
        assert!(
            accept("coder", "safe")
                .await
                .starts_with("error:only the Orchestrator")
        );
        assert!(
            accept(ORCHESTRATOR, "kelvins")
                .await
                .contains("Kelvin's to answer")
        );
        assert!(accept(ORCHESTRATOR, "own").await.contains("your own card"));
        assert!(
            accept(ORCHESTRATOR, "gone")
                .await
                .contains("no longer open")
        );
        assert!(accept(ORCHESTRATOR, "safe").await.starts_with("ok:"));

        let who = sqlx::query_scalar!("select decided_by from effect")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(
            who.as_deref(),
            Some("orchestrator"),
            "it never counts as the owner"
        );
        let rules: i64 = sqlx::query_scalar!(r#"select count(*) as "n!" from approval_rule"#)
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rules, 0, "accepting adds no rule");
        assert!(!lock(&app.rt).dialogs.contains_key("safe"));
    }

    #[sqlx::test]
    async fn a_hand_off_to_a_busy_bot_starts_when_it_is_free(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        bot(&db, "researcher", "x").await;
        bot(&db, "coder", "x").await;
        let researcher = db::bot_thread(&db, "researcher").await.unwrap().unwrap();
        let coder = db::bot_thread(&db, "coder").await.unwrap().unwrap();
        let Submitted::Queued(run) =
            runs::submit(&db, researcher.id, "compare", runs::Source::default())
                .await
                .unwrap()
        else {
            panic!("expected a run")
        };
        let Submitted::Queued(busy) = runs::submit(&db, coder.id, "busy", runs::Source::default())
            .await
            .unwrap()
        else {
            panic!("expected a run")
        };
        let asked = ask(
            &app,
            run,
            "researcher",
            &json!({ "bot": "coder", "task": "benchmark" }),
        )
        .await;
        assert!(asked.contains("starts when they're free"), "{asked}");
        let state = || {
            let db = db.clone();
            async move {
                sqlx::query_scalar!(r#"select status::text as "s!" from ticket"#)
                    .fetch_one(&db)
                    .await
                    .unwrap()
            }
        };
        check(&app).await;
        assert_eq!(state().await, "todo");
        sqlx::query!("update run set status = 'cancelled' where id = $1", busy)
            .execute(&db)
            .await
            .unwrap();
        check(&app).await;
        assert_eq!(state().await, "doing");
    }

    #[sqlx::test]
    async fn hand_offs_make_tickets_and_answers_come_back(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        bot(&db, "researcher", "looks things up").await;
        bot(&db, "coder", "writes code").await;
        let researcher = db::bot_thread(&db, "researcher").await.unwrap().unwrap();
        let runs::Submitted::Queued(run) = runs::submit(
            &db,
            researcher.id,
            "compare libraries",
            runs::Source::default(),
        )
        .await
        .unwrap() else {
            panic!("expected a run")
        };

        assert!(
            ask(
                &app,
                run,
                "researcher",
                &json!({ "bot": "researcher", "task": "x" })
            )
            .await
            .starts_with("error:you can't ask yourself")
        );
        let unknown = ask(
            &app,
            run,
            "researcher",
            &json!({ "bot": "designer", "task": "x" }),
        )
        .await;
        assert!(
            unknown.contains("ask one of: ") && unknown.contains("coder"),
            "{unknown}"
        );

        let ok = ask(
            &app,
            run,
            "researcher",
            &json!({ "bot": "coder", "task": "Write a benchmark\nfor both libraries" }),
        )
        .await;
        assert!(ok.starts_with("ok:Asked Coder (ticket OB-"), "{ok}");
        let t =
            sqlx::query!(r#"select id, title, status::text as "status!", ask_depth from ticket"#)
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(
            (t.title.as_str(), t.status.as_str(), t.ask_depth),
            ("Write a benchmark", "doing", 1)
        );

        // The coder answers and its run ends: the researcher gets the answer and a new run.
        let coder_run: i64 =
            sqlx::query_scalar!(r#"select id as "id!" from run where ticket_id = $1"#, t.id)
                .fetch_one(&db)
                .await
                .unwrap();
        let coder = db::bot_thread(&db, "coder").await.unwrap().unwrap();
        db::append(
            &db,
            coder.id,
            &ThreadEvent::Message {
                role: Role::Assistant,
                text: "benchmark.rs is in /shared".into(),
            },
        )
        .await
        .unwrap();
        answered(&app, coder_run, RunOutcome::Completed, None).await;
        let back: String = sqlx::query_scalar!(
            r#"select body ->> 'text' as "t!" from event where thread_id = $1 and body ->> 'role' = 'user' order by id desc limit 1"#,
            researcher.id
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert!(
            back.starts_with(&format!("Your teammate Coder finished OB-{}", t.id))
                && back.contains("benchmark.rs is in /shared"),
            "{back}"
        );

        // Three deep is the limit.
        sqlx::query!("update ticket set ask_depth = 3 where id = $1", t.id)
            .execute(&db)
            .await
            .unwrap();
        let deep = ask(
            &app,
            coder_run,
            "coder",
            &json!({ "bot": "researcher", "task": "x" }),
        )
        .await;
        assert!(
            deep.starts_with("error:this is already three hand-offs deep"),
            "{deep}"
        );

        // Not deep, but the researcher asked for this: the coder can't hand it back.
        sqlx::query!("update ticket set ask_depth = 1 where id = $1", t.id)
            .execute(&db)
            .await
            .unwrap();
        let bounce = ask(
            &app,
            coder_run,
            "coder",
            &json!({ "bot": "researcher", "task": "Can you do it instead?" }),
        )
        .await;
        assert!(
            bounce.starts_with("error:researcher asked you for this"),
            "{bounce}"
        );
    }

    #[test]
    fn the_roster_lists_teammates_not_yourself_or_the_inbox() {
        let b = |slug: &str, disabled| crate::bots::Bot {
            slug: slug.into(),
            name: slug.to_uppercase(),
            remit: format!("{slug} work"),
            instructions: String::new(),
            model: None,
            thinking: None,
            exclude_tools: vec![],
            scope: "team".into(),
            disabled,
            computer: "node".into(),
            google: "read".into(),
            face: None,
            desktop: "debian".into(),
            phone: "none".into(),
            media: false,
            session_gen: 0,
        };
        let roster = [
            b("inbox", false),
            b("coder", false),
            b("checker", false),
            b("old", true),
        ];
        let mut grants = HashMap::new();
        grants.insert("checker".to_string(), vec!["github".to_string()]);
        let note = roster_note(&roster, "coder", &grants, true).unwrap();
        assert!(note.contains("- checker (CHECKER): checker work. Can: model Orphus default; Google: looks up only; connections: github"));
        assert!(note.starts_with("\n\nYou: model Orphus default; Google: looks up only."));
        assert!(!note.contains("- coder") && !note.contains("inbox") && !note.contains("old"));
        assert!(roster_note(&[b("coder", false)], "coder", &grants, true).is_none());
        // Without Google set up, no bot is told it has Google, and all are told why.
        let none = roster_note(&roster, "coder", &grants, false).unwrap();
        assert!(!none.contains("Google: looks up"));
        assert!(none.contains("isn't set up yet"));
    }
}
