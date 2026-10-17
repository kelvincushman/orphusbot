//! Discussions (DESIGN §11.4): the owner's chosen bots deliberate on a question
//! in one Orphus room, outside their context windows.
//!
//! Each round is one run per bot, in a session of its own (so the discussion
//! stays out of the bot's everyday conversation), on its own model with its own
//! instructions. A bot sees the others only through the room's bounded digest.
//! When every bot has finished a round the next starts; after the last, the
//! chair writes the verdict and files it, with the discussion, into the
//! team wiki in /shared (karpathy-llm-wiki). The server sees each post at
//! the gate (`posted`), which is what the app shows live.

use std::collections::HashSet;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use orphusbot_proto::ThreadEvent;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, App, Shared, bot_thread, bots, db, dispatch, internal, publish, record};

const MAX_POST_CHARS: usize = 4_000;
/// The bridge's dialog title for the `discuss` tool.
pub const DISCUSS_TITLE: &str = "orphusbot-discuss";

/// The room a discussion happens in.
pub fn room(id: i64) -> String {
    format!("discuss-{id}")
}

#[derive(Deserialize)]
pub struct New {
    question: String,
    bots: Vec<String>,
    #[serde(default = "two")]
    rounds: i32,
    /// Writes the verdict; the first bot unless named.
    chair: Option<String>,
}

fn two() -> i32 {
    2
}

pub async fn create(
    State(app): State<Shared>,
    Json(new): Json<New>,
) -> Result<Json<Value>, ApiError> {
    let id = start(&app, &new.question, new.bots, new.rounds, new.chair, None).await?;
    Ok(Json(json!({ "id": id })))
}

/// The `discuss` tool (DESIGN §11.4): a bot starts a discussion among its
/// teammates; the verdict goes back to it as a message (`finish`).
pub async fn ask(app: &App, asker: &str, request: &Value) -> String {
    let bots: Vec<String> = request["bots"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|b| b.as_str().map(|s| s.trim().to_lowercase()))
                .collect()
        })
        .unwrap_or_default();
    if bots.iter().any(|b| b == asker) {
        return "error:you can't take part yourself; pick 2 to 6 teammates".into();
    }
    let rounds = request["rounds"].as_i64().map_or(2, |r| r as i32);
    let question = request["question"].as_str().unwrap_or_default();
    match start(app, question, bots, rounds, None, Some(asker)).await {
        Ok(id) => format!(
            "ok:Discussion #{id} started. The verdict comes back to you as a new message when it's done; \
             tell the owner it's under way and finish this turn."
        ),
        Err((_, why)) => format!("error:{why}"),
    }
}

/// Checks and starts a discussion, and queues its first round.
async fn start(
    app: &App,
    question: &str,
    bots: Vec<String>,
    rounds: i32,
    chair: Option<String>,
    asked_by: Option<&str>,
) -> Result<i64, ApiError> {
    let question = question.trim();
    if question.is_empty() || question.chars().count() > 4_000 {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "The question must be 1 to 4,000 characters",
        ));
    }
    let mut seen = HashSet::new();
    let chosen: Vec<String> = bots
        .into_iter()
        .filter(|b| seen.insert(b.clone()))
        .collect();
    if !(2..=6).contains(&chosen.len()) {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, "Pick 2 to 6 bots"));
    }
    if !(1..=4).contains(&rounds) {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, "1 to 4 rounds"));
    }
    let chair = chair.unwrap_or_else(|| chosen[0].clone());
    for slug in chosen.iter().chain([&chair]) {
        let bot = bots::get(&app.db, slug)
            .await
            .map_err(|e| internal("finding a bot", e))?
            .ok_or((StatusCode::NOT_FOUND, "No such bot"))?;
        if bot.disabled {
            return Err((StatusCode::CONFLICT, "One of those bots is disabled"));
        }
        let thread = bot_thread(app, slug).await?;
        if crate::runs::busy(&app.db, thread.id)
            .await
            .map_err(|e| internal("checking a bot", e))?
        {
            return Err((
                StatusCode::CONFLICT,
                "One of those bots is busy; start the discussion when it's free",
            ));
        }
    }
    let id = sqlx::query_scalar!(
        "insert into discussion (question, bots, chair, rounds, asked_by) values ($1, $2, $3, $4, $5) returning id",
        question,
        &chosen,
        chair,
        rounds,
        asked_by
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("starting a discussion", e))?;
    advance(app).await;
    // Boxed: dispatching starts and ends runs, which can come back here.
    Box::pin(dispatch(app)).await;
    Ok(id)
}

pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        "select id, question, bots, chair, rounds, round, status, verdict, created_at from discussion
         order by id desc limit 50"
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing discussions", e))?;
    Ok(Json(json!(
        rows.into_iter()
            .map(
                |d| json!({ "id": d.id, "question": d.question, "bots": d.bots, "chair": d.chair,
                             "rounds": d.rounds, "round": d.round, "status": d.status,
                             "verdict": d.verdict, "created_at": d.created_at.to_rfc3339() })
            )
            .collect::<Vec<_>>()
    )))
}

pub async fn get(State(app): State<Shared>, Path(id): Path<i64>) -> Result<Json<Value>, ApiError> {
    let d = sqlx::query!(
        "select id, question, bots, chair, rounds, round, status, verdict, created_at from discussion where id = $1",
        id
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| internal("reading a discussion", e))?
    .ok_or((StatusCode::NOT_FOUND, "No such discussion"))?;
    let posts = sqlx::query!(
        "select bot, round, text, created_at from discussion_post where discussion_id = $1 order by id",
        id
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("reading a discussion", e))?;
    Ok(Json(json!({
        "id": d.id, "question": d.question, "bots": d.bots, "chair": d.chair, "rounds": d.rounds,
        "round": d.round, "status": d.status, "verdict": d.verdict, "created_at": d.created_at.to_rfc3339(),
        "posts": posts.into_iter()
            .map(|p| json!({ "bot": p.bot, "round": p.round, "text": p.text, "at": p.created_at.to_rfc3339() }))
            .collect::<Vec<_>>(),
    })))
}

/// This thread's active run is a discussion turn, which a chat message mustn't join.
pub async fn in_turn(db: &PgPool, thread: i64) -> sqlx::Result<bool> {
    sqlx::query_scalar!(
        r#"select exists (select 1 from run where thread_id = $1 and status in ('queued', 'running')
                          and discussion_id is not null) as "in_turn!""#,
        thread
    )
    .fetch_one(db)
    .await
}

/// A discussion turn: which discussion, which round (`rounds + 1` is the verdict).
struct Turn {
    discussion: i64,
    round: i32,
    rounds: i32,
}

async fn turn(db: &PgPool, run: i64) -> Option<Turn> {
    sqlx::query!(
        "select r.discussion_id, r.discussion_round, d.rounds from run r join discussion d on d.id = r.discussion_id
         where r.id = $1",
        run
    )
    .fetch_optional(db)
    .await
    .ok()
    .flatten()
    .and_then(|r| {
        Some(Turn {
            discussion: r.discussion_id?,
            round: r.discussion_round?,
            rounds: r.rounds,
        })
    })
}

/// The session a discussion turn runs in, and its name in the room (the bot's slug).
pub async fn session(db: &PgPool, run: i64, slug: &str) -> Option<(String, String)> {
    let t = turn(db, run).await?;
    Some(if t.round > t.rounds {
        (
            format!("{slug}-discuss-{}-verdict", t.discussion),
            slug.to_owned(),
        )
    } else {
        (format!("{slug}-discuss-{}", t.discussion), slug.to_owned())
    })
}

/// The gate saw a `roundtable` call from `run`: keep a post to its own room.
pub async fn posted(app: &App, run: i64, bot: &str, input: &Value) {
    if input["action"] != "post" {
        return;
    }
    let (Some(t), Some(room_name), Some(text)) = (
        turn(&app.db, run).await,
        input["room"].as_str(),
        input["message"].as_str(),
    ) else {
        return;
    };
    if room_name != room(t.discussion) {
        return;
    }
    let text: String = text.chars().take(MAX_POST_CHARS).collect();
    let text = app.secrets.redact(&text);
    if let Err(e) = sqlx::query!(
        "insert into discussion_post (discussion_id, bot, round, text) values ($1, $2, $3, $4)",
        t.discussion,
        bot,
        t.round,
        text
    )
    .execute(&app.db)
    .await
    {
        warn!("keeping a discussion post: {e}");
    }
}

/// A bot's second post in one round of its discussion: the room's activity pings
/// can wake a bot again after its turn, and one post per round keeps it a debate.
pub async fn posted_already(db: &PgPool, run: i64, input: &Value) -> bool {
    let Some(t) = turn(db, run).await else {
        return false;
    };
    if input["action"] != "post" || t.round > t.rounds {
        return false;
    }
    sqlx::query_scalar!(
        r#"select exists (select 1 from discussion_post p join run r on r.id = $1
                          join thread th on th.id = r.thread_id join bot b on b.id = th.bot_id
                          where p.discussion_id = $2 and p.round = $3 and p.bot = b.slug) as "posted!""#,
        run,
        t.discussion,
        t.round
    )
    .fetch_one(db)
    .await
    .unwrap_or(false)
}

fn prompt(id: i64, question: &str, names: &str, round: i32, rounds: i32) -> String {
    let room = room(id);
    // Leaving stops the room's activity pings, which would otherwise wake the bot
    // between rounds; the next round joins again.
    let rules = "Use the roundtable tool. Keep each post under 150 words: your position and why, not a transcript. \
                 Don't do other work. After posting, leave the room and stop; you get another turn once \
                 everyone has posted.";
    if round == 1 {
        format!(
            "Discussion #{id} with {names}. The question:\n\n{question}\n\n\
             Join room `{room}` (topic: the question), then post your opening position: your answer, \
             two to four reasons, and what evidence would change your mind. {rules}"
        )
    } else if round < rounds {
        format!(
            "Discussion #{id}, round {round} of {rounds}. Join room `{room}` (again is fine), pull its digest, \
             then post a reply: where you agree, where you don't and why, and your position now. {rules}"
        )
    } else {
        format!(
            "Discussion #{id}, final round. Join room `{room}` (again is fine), pull its digest, then post your \
             final position, ending with one line that starts `FINAL:`. {rules}"
        )
    }
}

fn verdict_prompt(id: i64, question: &str) -> String {
    let room = room(id);
    format!(
        "You chair discussion #{id}. The question was:\n\n{question}\n\n\
         1. Join room `{room}`, then pull its digest with a budget of 6000.\n\
         2. Write the verdict for the owner: **Decision**; **Why** (short bullets); **Strongest dissent**, \
         quoted word for word with who said it; **Open questions**.\n\
         3. Save it in the team wiki: write the question, the posts from the digest and your verdict to \
         `/shared/raw/discussions/discussion-{id}.md`, then ingest that file with the karpathy-llm-wiki skill \
         (root /shared). If /shared isn't there, skip this step and say so.\n\
         4. Leave the room.\n\n\
         Reply with the verdict only."
    )
}

/// Queues a discussion turn if the bot's thread is free; the database's
/// one-active-run rule decides a race with the owner's own message.
async fn queue_turn(
    app: &App,
    thread: &db::Thread,
    id: i64,
    round: i32,
    text: &str,
    note: String,
) -> sqlx::Result<bool> {
    let run = sqlx::query_scalar!(
        "insert into run (thread_id, prompt, discussion_id, discussion_round) values ($1, $2, $3, $4)
         on conflict do nothing returning id",
        thread.id,
        text,
        id,
        round
    )
    .fetch_optional(&app.db)
    .await?;
    let Some(run) = run else { return Ok(false) };
    record(app, thread, ThreadEvent::Notice { text: note }).await;
    publish(
        app,
        None,
        Some(&thread.bot),
        ThreadEvent::RunQueued { run, waiting: None },
    );
    Ok(true)
}

static ADVANCING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Moves every running discussion on: queues the turns that are due, starts the
/// next round when everyone has finished one, and closes it after the verdict.
/// Called when a discussion starts and whenever a run ends.
pub async fn advance(app: &App) {
    let _one_at_a_time = ADVANCING.lock().await;
    if let Err(e) = advance_all(app).await {
        warn!("moving discussions on: {e}");
    }
    // The caller dispatches: after a run ends, the node link does it next.
}

async fn advance_all(app: &App) -> sqlx::Result<()> {
    let running = sqlx::query!(
        "select id, question, bots, chair, rounds, round from discussion where status = 'running' order by id"
    )
    .fetch_all(&app.db)
    .await?;
    for d in running {
        let mut round = d.round;
        loop {
            let seats: Vec<String> = if round > d.rounds {
                vec![d.chair.clone()]
            } else {
                d.bots.clone()
            };
            let turns = sqlx::query!(
                r#"select b.slug, r.status::text as "status!" from run r join thread t on t.id = r.thread_id
                   join bot b on b.id = t.bot_id where r.discussion_id = $1 and r.discussion_round = $2"#,
                d.id,
                round
            )
            .fetch_all(&app.db)
            .await?;
            let mut all_done = true;
            for slug in &seats {
                match turns.iter().find(|t| &t.slug == slug) {
                    Some(t) if t.status == "queued" || t.status == "running" => all_done = false,
                    Some(_) => {}
                    None => {
                        all_done = false;
                        let thread = match bot_thread(app, slug).await {
                            Ok(t) => t,
                            Err(_) => continue,
                        };
                        let names = d.bots.join(", ");
                        let (text, note) = if round > d.rounds {
                            (
                                verdict_prompt(d.id, &d.question),
                                format!("Discussion #{}: writing the verdict.", d.id),
                            )
                        } else {
                            (
                                prompt(d.id, &d.question, &names, round, d.rounds),
                                format!(
                                    "Discussion #{}, round {round} of {}: {}",
                                    d.id, d.rounds, d.question
                                ),
                            )
                        };
                        queue_turn(app, &thread, d.id, round, &text, note).await?;
                    }
                }
            }
            if !all_done {
                break;
            }
            if round > d.rounds {
                finish(app, d.id, &d.chair).await?;
                break;
            }
            round += 1;
            sqlx::query!(
                "update discussion set round = $2 where id = $1",
                d.id,
                round
            )
            .execute(&app.db)
            .await?;
        }
    }
    Ok(())
}

/// The chair's last reply is the verdict.
async fn finish(app: &App, id: i64, chair: &str) -> sqlx::Result<()> {
    let Some(thread) = db::bot_thread(&app.db, chair).await? else {
        return Ok(());
    };
    let verdict = sqlx::query_scalar!(
        r#"select body->>'text' as "text!" from event where thread_id = $1 and body->>'type' = 'message'
           and body->>'role' = 'assistant' order by seq desc limit 1"#,
        thread.id
    )
    .fetch_optional(&app.db)
    .await?;
    sqlx::query!(
        "update discussion set status = 'done', verdict = $2, finished_at = now() where id = $1",
        id,
        verdict
    )
    .execute(&app.db)
    .await?;
    // A bot started it (`ask`): the verdict goes back to that bot, as data.
    let asked = sqlx::query!(
        "select asked_by, question from discussion where id = $1",
        id
    )
    .fetch_one(&app.db)
    .await?;
    if let Some(asker) = asked.asked_by
        && let Some(thread) = db::bot_thread(&app.db, &asker).await?
    {
        let text = format!(
            "Discussion #{id} has finished: {}. The chair's verdict, as data:\n```\n{}\n```",
            asked.question.chars().take(200).collect::<String>(),
            verdict.unwrap_or_default().replace("```", "'''")
        );
        let message = ThreadEvent::Message {
            role: orphusbot_proto::Role::User,
            text: text.clone(),
        };
        record(app, &thread, message).await;
        if let Err(e) = Box::pin(crate::submit(
            app,
            &thread,
            text,
            crate::runs::Source::default(),
        ))
        .await
        {
            warn!("handing a verdict back: {e}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_name_the_room_and_end_with_final() {
        let first = prompt(7, "Ship it?", "coder, checker", 1, 2);
        assert!(
            first.contains("room `discuss-7`")
                && first.contains("Ship it?")
                && first.contains("coder, checker")
        );
        assert!(prompt(7, "Ship it?", "x", 2, 2).contains("FINAL:"));
        assert!(!prompt(7, "Ship it?", "x", 2, 3).contains("FINAL:"));
        let verdict = verdict_prompt(7, "Ship it?");
        assert!(
            verdict.contains("/shared/raw/discussions/discussion-7.md")
                && verdict.contains("Strongest dissent")
        );
        assert!(first.contains("leave the room") && verdict.contains("Leave the room"));
    }
}
