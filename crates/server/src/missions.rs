//! Missions (DESIGN §5.5, D-064): a new piece of work gets its own Chief of
//! Staff, so it has a clean context and doesn't crowd the everyday team.
//!
//! A chief is a bot row, `chief--<id>` (`slugify` never makes a double hyphen),
//! which gives it its own thread and engine, so chiefs run side by side and
//! one mission's messages can't reach another's. Teammates it hands work to
//! run that ticket in a session of their own for the mission, and queue as
//! they do for any hand-off. Only the chief hands work on, so every answer
//! comes back to its thread.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use orphusbot_proto::ToNode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, App, Shared, bots, internal, lock, team};

/// Title of the bridge's `start_mission` dialog.
pub const START_TITLE: &str = "orphusbot-mission";
/// Title of the bridge's `update_mission` dialog.
pub const UPDATE_TITLE: &str = "orphusbot-mission-update";
const CHIEF: &str = "chief--";

const INSTRUCTIONS: &str = "You are a Chief of Staff, running one mission for Kelvin and nothing else. \
You plan and coordinate; your teammates do the work.\n\n\
Plan the mission, then hand each part to the right teammate with ask_bot, with everything they need. Their \
answers come back to you as new messages, and you hear if they get stuck, so end your turn rather than wait. \
After each step, record where things stand in one line with update_mission; other bots read it, so it's how \
the team knows what you're up to. When the mission is finished, call update_mission with status done and the \
result, or status dropped and why. Keep Kelvin's load low: he has ADHD and gets tired, so ask him only what \
you must.";

const PRIVATE_NOTE: &str = "This mission is private: keep it out of the wiki and /shared, and tell \
teammates only what they need for their part.";

/// The chief of mission `id`.
pub fn chief(id: i64) -> String {
    format!("{CHIEF}{id}")
}

/// The mission `slug` is the chief of, if it is one.
pub fn of_chief(slug: &str) -> Option<i64> {
    slug.strip_prefix(CHIEF)?.parse().ok()
}

/// The mission this run is working on, if it's a hand-off from a chief.
pub async fn of_run(db: &PgPool, run: i64) -> Option<i64> {
    sqlx::query_scalar!(
        "select t.mission_id from run r join ticket t on t.id = r.ticket_id where r.id = $1",
        run
    )
    .fetch_optional(db)
    .await
    .ok()
    .flatten()
    .flatten()
}

/// The session a teammate's mission run uses, away from its everyday one.
pub async fn session(db: &PgPool, run: i64, slug: &str) -> Option<String> {
    Some(format!("{slug}-mission-{}", of_run(db, run).await?))
}

/// Answers the bridge's dialog: `ok:<what to tell the bot>` or `error:<why not>`.
pub async fn start(app: &App, asker: &str, request: &Value) -> String {
    match begin(app, asker, request).await {
        Ok(text) => format!("ok:{text}"),
        Err(why) => format!("error:{why}"),
    }
}

async fn begin(app: &App, asker: &str, request: &Value) -> Result<String, String> {
    if asker != team::ORCHESTRATOR {
        return Err("only the Orchestrator starts missions".into());
    }
    let (Some(title), Some(goal)) = (request["title"].as_str(), request["goal"].as_str()) else {
        return Err("give a title and a goal".into());
    };
    let (title, goal) = (title.trim(), goal.trim());
    if !(1..=200).contains(&title.chars().count()) || !(1..=8000).contains(&goal.chars().count()) {
        return Err("the title is 1 to 200 characters and the goal 1 to 8,000".into());
    }
    let private = request["private"].as_bool().unwrap_or(false);
    let roster = bots::all(&app.db)
        .await
        .map_err(|e| format!("couldn't read the team: {e}"))?;
    let mut members = Vec::new();
    for slug in request["team"].as_array().into_iter().flatten() {
        let slug = slug.as_str().unwrap_or_default().trim().to_lowercase();
        if !roster
            .iter()
            .any(|b| b.slug == slug && !b.disabled && of_chief(&b.slug).is_none())
        {
            return Err(format!("no teammate called {slug}"));
        }
        members.push(slug);
    }
    let me = roster.iter().find(|b| b.slug == asker);
    let failed = |e: sqlx::Error| format!("couldn't start the mission: {e}");
    let mut tx = app.db.begin().await.map_err(failed)?;
    let id = sqlx::query_scalar!(
        "insert into mission (title, goal, private, team) values ($1, $2, $3, $4) returning id",
        title,
        goal,
        private,
        &members
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(failed)?;
    let slug = chief(id);
    let name: String = format!("Chief: {title}").chars().take(40).collect();
    // No Google or connections: a chief coordinates, and teammates hold those.
    let bot = sqlx::query_scalar!(
        "insert into bot (slug, name, remit, instructions, model, thinking, scope, google)
         values ($1, $2, $3, $4, $5, $6, 'team', 'none') returning id",
        slug,
        name.trim(),
        title,
        INSTRUCTIONS,
        me.and_then(|b| b.model.clone()),
        me.and_then(|b| b.thinking.clone())
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(failed)?;
    sqlx::query!("insert into thread (bot_id) values ($1)", bot)
        .execute(&mut *tx)
        .await
        .map_err(failed)?;
    tx.commit().await.map_err(failed)?;
    let brief = format!(
        "Your mission, as data from the Orchestrator:\n```\n{title}\n\n{goal}\n```\nThe team it suggests: {}.{}",
        if members.is_empty() {
            "your choice".to_owned()
        } else {
            members.join(", ")
        },
        if private {
            format!(" {PRIVATE_NOTE}")
        } else {
            String::new()
        }
    )
    .replace("```\n```", "```");
    team::tell(app, &slug, &brief).await;
    Ok(format!(
        "Mission {id} started, with its Chief of Staff {slug}. Kelvin can open it in the bot list. You'll hear when it ends."
    ))
}

/// Answers the bridge's `update_mission` dialog. A chief updates its own
/// mission; the Orchestrator names one. Neither can make a private one visible.
pub async fn update(app: &App, asker: &str, request: &Value) -> String {
    match change(app, asker, request).await {
        Ok(text) => format!("ok:{text}"),
        Err(why) => format!("error:{why}"),
    }
}

async fn change(app: &App, asker: &str, request: &Value) -> Result<String, String> {
    let id = match (of_chief(asker), request["mission"].as_i64()) {
        (Some(id), _) => id,
        (None, Some(id)) if asker == team::ORCHESTRATOR => id,
        (None, None) if asker == team::ORCHESTRATOR => return Err("say which mission".into()),
        _ => return Err("only a mission's chief or the Orchestrator can update it".into()),
    };
    if request["private"].as_bool() == Some(false) {
        return Err("only Kelvin can make a private mission visible".into());
    }
    let latest = request["update"].as_str().map(str::trim);
    if latest.is_some_and(|l| l.chars().count() > 1000) {
        return Err("keep the update to 1,000 characters".into());
    }
    let status = request["status"].as_str();
    if status.is_some_and(|s| !["done", "dropped"].contains(&s)) {
        return Err("status is done or dropped".into());
    }
    let private = request["private"].as_bool() == Some(true);
    let mission = sqlx::query!(
        "update mission set latest = coalesce($2, latest), private = private or $3,
                status = coalesce($4, status), updated_at = now()
         where id = $1 and status = 'open' returning title, latest",
        id,
        latest,
        private,
        status
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| format!("couldn't update the mission: {e}"))?
    .ok_or("that mission isn't open")?;
    if private && of_chief(asker).is_none() {
        team::tell(app, &chief(id), PRIVATE_NOTE).await;
    }
    if let Some(status) = status {
        close(&app.db, id)
            .await
            .map_err(|e| format!("couldn't close the mission: {e}"))?;
        if of_chief(asker).is_some() {
            let text = format!(
                "Mission {id} is {status}. As data from its chief:\n```\n{}\n\n{}\n```\nTell Kelvin the result.",
                mission.title,
                mission.latest.replace("```", "'''")
            );
            team::tell(app, team::ORCHESTRATOR, &text).await;
        }
    }
    Ok("Noted.".into())
}

/// Takes a closed mission's chief off the team. A run it's in finishes; one
/// that's only queued goes, as a disabled bot's run would wait for ever.
async fn close(db: &PgPool, id: i64) -> sqlx::Result<()> {
    let slug = chief(id);
    sqlx::query!("update bot set disabled = true where slug = $1", slug)
        .execute(db)
        .await?;
    sqlx::query!(
        "update run set status = 'cancelled', updated_at = now()
         where status = 'queued'
           and thread_id = (select t.id from thread t join bot b on b.id = t.bot_id where b.slug = $1)",
        slug
    )
    .execute(db)
    .await?;
    Ok(())
}

/// What a viewer may see of the missions.
#[derive(Debug, Default)]
pub struct Seen {
    /// Each mission in a line.
    pub lines: Vec<String>,
    /// Private missions whose hand-offs this viewer mustn't see either.
    pub hidden: Vec<i64>,
}

/// Open missions and those closed in the last three days. Private ones are
/// only for the Orchestrator, the chief and the mission's team; `None` is a
/// viewer outside the team, such as the voice model.
pub async fn seen(db: &PgPool, viewer: Option<&str>) -> sqlx::Result<Seen> {
    let rows = sqlx::query!(
        "select id, title, status, private, latest, team from mission
         where status = 'open' or updated_at > now() - interval '3 days' order by id"
    )
    .fetch_all(db)
    .await?;
    let mut seen = Seen::default();
    for m in rows {
        let inside = viewer.is_some_and(|v| {
            v == team::ORCHESTRATOR || of_chief(v) == Some(m.id) || m.team.iter().any(|t| t == v)
        });
        if m.private && !inside {
            seen.hidden.push(m.id);
            continue;
        }
        let private = if m.private { ", private" } else { "" };
        let latest = if m.latest.is_empty() {
            "no update yet"
        } else {
            &m.latest
        };
        seen.lines.push(format!(
            "Mission {} ({}{private}), chief {}, team {}: {}. Latest: {}",
            m.id,
            m.status,
            chief(m.id),
            m.team.join(", "),
            team::short(&m.title),
            team::short(latest)
        ));
    }
    Ok(seen)
}

/// On the reconcile tick: once a closed mission's chief is idle, drop its
/// engine and stop its computer. Its home volume and session stay.
pub async fn retire(app: &App) {
    let done = sqlx::query_scalar!(
        "select m.id from mission m
         where m.status <> 'open' and not m.retired
           and not exists (select 1 from run r join thread t on t.id = r.thread_id
                           join bot b on b.id = t.bot_id
                           where b.slug = 'chief--' || m.id and r.status in ('queued', 'running'))"
    )
    .fetch_all(&app.db)
    .await;
    let done = match done {
        Ok(done) => done,
        Err(e) => return warn!("finding closed missions: {e}"),
    };
    let links: Vec<_> = lock(&app.rt).nodes.values().map(|n| n.tx.clone()).collect();
    if links.is_empty() {
        return;
    }
    for id in done {
        for tx in &links {
            let _ = tx.send(ToNode::Retire { bot: chief(id) }).await;
        }
        if let Err(e) = sqlx::query!("update mission set retired = true where id = $1", id)
            .execute(&app.db)
            .await
        {
            warn!("retiring a mission: {e}");
        }
    }
}

#[derive(Serialize)]
pub struct Mission {
    id: i64,
    title: String,
    status: String,
    private: bool,
    latest: String,
    team: Vec<String>,
    chief: String,
}

/// `GET /api/missions`: every mission, newest first, for the owner.
pub async fn list(State(app): State<Shared>) -> Result<Json<Vec<Mission>>, ApiError> {
    let rows = sqlx::query!(
        "select id, title, status, private, latest, team from mission order by id desc limit 200"
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing missions", e))?;
    Ok(Json(
        rows.into_iter()
            .map(|m| Mission {
                chief: chief(m.id),
                id: m.id,
                title: m.title,
                status: m.status,
                private: m.private,
                latest: m.latest,
                team: m.team,
            })
            .collect(),
    ))
}

#[derive(Deserialize)]
pub struct Change {
    id: i64,
    private: Option<bool>,
    status: Option<String>,
}

/// `POST /api/missions/update`: the owner marks a mission private or visible,
/// or closes it.
pub async fn set(State(app): State<Shared>, Json(c): Json<Change>) -> Result<StatusCode, ApiError> {
    let status = c.status.as_deref();
    if status.is_some_and(|s| !["done", "dropped"].contains(&s)) {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Status is done or dropped",
        ));
    }
    let done = sqlx::query!(
        "update mission set private = coalesce($2, private), status = coalesce($3, status),
                updated_at = now() where id = $1",
        c.id,
        c.private,
        status
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("updating a mission", e))?;
    if done.rows_affected() == 0 {
        return Err((StatusCode::NOT_FOUND, "No such mission"));
    }
    if status.is_some() {
        close(&app.db, c.id)
            .await
            .map_err(|e| internal("closing a mission", e))?;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{db, runs};
    use serde_json::json;

    async fn teammate(db: &PgPool, slug: &str) {
        let id: i64 = sqlx::query_scalar!(
            "insert into bot (slug, name, remit) values ($1, initcap($1), 'work') returning id",
            slug
        )
        .fetch_one(db)
        .await
        .unwrap();
        sqlx::query!("insert into thread (bot_id) values ($1)", id)
            .execute(db)
            .await
            .unwrap();
    }

    async fn run_of(db: &PgPool, slug: &str) -> i64 {
        sqlx::query_scalar!(
            "select r.id from run r join thread t on t.id = r.thread_id join bot b on b.id = t.bot_id
             where b.slug = $1 order by r.id desc limit 1",
            slug
        )
        .fetch_one(db)
        .await
        .unwrap()
    }

    #[sqlx::test]
    async fn a_mission_gets_a_chief_with_its_own_thread(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        teammate(&db, "coder").await;
        let brief = json!({ "title": "Launch", "goal": "Ship it", "team": ["coder"] });
        assert!(start(&app, "coder", &brief).await.starts_with("error:only"));
        assert!(
            start(
                &app,
                team::ORCHESTRATOR,
                &json!({ "title": "x", "goal": "y", "team": ["ghost"] })
            )
            .await
            .contains("no teammate called ghost")
        );
        let ok = start(&app, team::ORCHESTRATOR, &brief).await;
        assert!(ok.starts_with("ok:Mission "), "{ok}");
        let id: i64 = sqlx::query_scalar!("select id from mission")
            .fetch_one(&db)
            .await
            .unwrap();
        let slug = chief(id);
        assert_eq!(of_chief(&slug), Some(id));
        assert_eq!(of_chief("chief-of-comms"), None);
        // Its briefing has already started a run in its own thread.
        let thread = db::bot_thread(&db, &slug).await.unwrap().unwrap();
        assert!(runs::busy(&db, thread.id).await.unwrap());
        let got = bots::get(&db, &slug).await.unwrap().unwrap();
        assert_eq!((got.google.as_str(), got.scope.as_str()), ("none", "team"));
    }

    #[sqlx::test]
    async fn a_chiefs_hand_off_runs_in_the_mission_and_only_the_chief_hands_on(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        teammate(&db, "coder").await;
        teammate(&db, "researcher").await;
        start(
            &app,
            team::ORCHESTRATOR,
            &json!({ "title": "Launch", "goal": "Ship" }),
        )
        .await;
        let id: i64 = sqlx::query_scalar!("select id from mission")
            .fetch_one(&db)
            .await
            .unwrap();
        let slug = chief(id);
        let chief_run = run_of(&db, &slug).await;
        assert_eq!(session(&db, chief_run, &slug).await, None);
        let ok = team::ask(
            &app,
            chief_run,
            &slug,
            &json!({ "bot": "coder", "task": "Build" }),
        )
        .await;
        assert!(ok.starts_with("ok:"), "{ok}");
        let coder_run = run_of(&db, "coder").await;
        assert_eq!(
            session(&db, coder_run, "coder").await,
            Some(format!("coder-mission-{id}"))
        );
        // The team records who was handed work.
        let members = sqlx::query_scalar!("select team from mission")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(members, ["coder"]);
        let refused = team::ask(
            &app,
            coder_run,
            "coder",
            &json!({ "bot": "researcher", "task": "Look" }),
        )
        .await;
        assert!(refused.contains("Chief of Staff"), "{refused}");
    }

    #[sqlx::test]
    async fn a_private_mission_is_hidden_and_only_the_owner_can_reveal_it(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        teammate(&db, "coder").await;
        teammate(&db, "blog").await;
        start(
            &app,
            team::ORCHESTRATOR,
            &json!({ "title": "Secret", "goal": "Shh", "team": ["coder"], "private": true }),
        )
        .await;
        start(
            &app,
            team::ORCHESTRATOR,
            &json!({ "title": "Open", "goal": "Hi" }),
        )
        .await;
        let ids: Vec<i64> = sqlx::query_scalar!("select id from mission order by id")
            .fetch_all(&db)
            .await
            .unwrap();
        let (secret, open) = (ids[0], ids[1]);
        // A hand-off from the private mission mustn't show through team_status.
        let run = run_of(&db, &chief(secret)).await;
        team::ask(
            &app,
            run,
            &chief(secret),
            &json!({ "bot": "blog", "task": "Hush task" }),
        )
        .await;
        sqlx::query!("update mission set team = '{coder}' where id = $1", secret)
            .execute(&db)
            .await
            .unwrap();
        for viewer in [None, Some("blog")] {
            let s = team::status(&app, viewer).await;
            assert!(
                s.contains("Open") && !s.contains("Secret") && !s.contains("Hush"),
                "{s}"
            );
        }
        for viewer in ["coder", team::ORCHESTRATOR] {
            let s = team::status(&app, Some(viewer)).await;
            assert!(s.contains("Secret") && s.contains("Hush"), "{s}");
        }
        let chief_open = chief(open);
        assert!(
            update(&app, &chief_open, &json!({ "private": false }))
                .await
                .contains("only Kelvin")
        );
        assert!(
            update(&app, "coder", &json!({ "mission": open, "update": "x" }))
                .await
                .starts_with("error:")
        );
    }

    #[sqlx::test]
    async fn closing_a_mission_retires_the_chief_and_tells_the_orchestrator(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        start(
            &app,
            team::ORCHESTRATOR,
            &json!({ "title": "Launch", "goal": "Ship" }),
        )
        .await;
        let id: i64 = sqlx::query_scalar!("select id from mission")
            .fetch_one(&db)
            .await
            .unwrap();
        let slug = chief(id);
        let ok = update(
            &app,
            &slug,
            &json!({ "update": "Shipped v1", "status": "done" }),
        )
        .await;
        assert!(ok.starts_with("ok:"), "{ok}");
        assert!(bots::get(&db, &slug).await.unwrap().unwrap().disabled);
        let thread = db::bot_thread(&db, team::ORCHESTRATOR)
            .await
            .unwrap()
            .unwrap();
        assert!(runs::busy(&db, thread.id).await.unwrap());
        // A late answer is kept but starts nothing on a closed chief.
        let chief_thread = db::bot_thread(&db, &slug).await.unwrap().unwrap();
        team::tell(&app, &slug, "late").await;
        assert!(!runs::busy(&db, chief_thread.id).await.unwrap());
        assert!(
            update(&app, &slug, &json!({ "update": "x" }))
                .await
                .contains("isn't open")
        );
    }
}
