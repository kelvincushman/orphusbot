//! Bots working as a team (DESIGN §5.3). A bot hands a teammate a task with the
//! bridge's `ask_bot` tool: the server makes it a ticket for that bot and starts
//! it, and when that run ends the answer goes back to the asker as a new message,
//! so it carries on. Every action either bot takes still goes through the gate.
//! Hand-offs stop three deep, and a bot can't ask itself.

use orphusbot_proto::{Role, RunOutcome, ThreadEvent};
use serde_json::Value;
use tracing::warn;

use crate::{App, db, record, runs, submit};

/// Title of the bridge's `ask_bot` dialog.
pub const ASK_TITLE: &str = "orphusbot-ask";
const MAX_DEPTH: i32 = 3;

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
            .filter(|b| !b.disabled && b.slug != asker)
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
    let title: String = task
        .lines()
        .next()
        .unwrap_or(task)
        .chars()
        .take(200)
        .collect();
    let id = sqlx::query_scalar!(
        "insert into ticket (title, body, urgency, bot_id, asked_by, ask_depth)
         values ($1, $2, 'hour', (select id from bot where slug = $3), (select id from bot where slug = $4), $5)
         returning id",
        title,
        task,
        to,
        asker,
        depth + 1
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| format!("couldn't make the ticket: {e}"))?;
    match crate::tickets::start(app, id).await {
        Ok(()) => Ok(format!(
            "Asked {} (ticket OB-{id}). Their answer will come to you as a new message when they finish; carry on with anything that doesn't need it.",
            bot.name
        )),
        // Busy: the ticket waits on the board with them assigned; the owner can start it.
        Err((_, why)) => Ok(format!(
            "{} can't start yet ({why}). It's on the board as OB-{id}; their answer will come to you when it runs.",
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
    let thread = match db::bot_thread(&app.db, &t.asker).await {
        Ok(Some(thread)) => thread,
        _ => return warn!(asker = %t.asker, "the bot that asked is gone"),
    };
    let message = ThreadEvent::Message {
        role: Role::User,
        text: text.clone(),
    };
    record(app, &thread, message).await;
    // Boxed: submitting can end a run, which comes back here.
    if let Err(e) = Box::pin(submit(app, &thread, text, runs::Source::default())).await {
        warn!("handing an answer back: {e}");
    }
}

/// Appended to a bot's instructions: who else is on the team, so it can ask them.
pub fn roster_note(roster: &[crate::bots::Bot], me: &str) -> Option<String> {
    let mates: Vec<String> = roster
        .iter()
        .filter(|b| !b.disabled && b.slug != me && b.slug != "inbox")
        .map(|b| format!("- {} ({}): {}", b.slug, b.name, b.remit))
        .collect();
    (!mates.is_empty()).then(|| {
        format!(
            "\n\nYour teammates. Hand one a task with the ask_bot tool when it suits them better; their answer comes back to you as a message. Files you both need can go in /shared.\n{}",
            mates.join("\n")
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sqlx::PgPool;

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
        };
        let roster = [
            b("inbox", false),
            b("coder", false),
            b("checker", false),
            b("old", true),
        ];
        let note = roster_note(&roster, "coder").unwrap();
        assert!(note.contains("- checker (CHECKER): checker work"));
        assert!(!note.contains("- coder") && !note.contains("inbox") && !note.contains("old"));
        assert!(roster_note(&[b("coder", false)], "coder").is_none());
    }
}
