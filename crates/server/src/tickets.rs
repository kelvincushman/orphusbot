//! Tickets (PRD B-TKT-01..03): a board of work, OB-1, OB-2, …
//!
//! Assigning a ticket to a bot starts the bot on it: the ticket goes to the
//! bot's thread as labelled data and moves to "doing". When that run ends the
//! ticket moves on by itself: completed → review, failed → blocked,
//! cancelled → todo. New tickets are triaged by System 1 in the background,
//! which fills in the bot and urgency when it's sure and starts the work only
//! when it's very sure that's safe; the owner can change anything after.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use orphusbot_proto::{Role, RunOutcome, ThreadEvent};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, App, Shared, bots, db, internal, record, runs, submit};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ticket {
    #[serde(default)]
    pub id: i64,
    pub title: String,
    #[serde(default)]
    pub body: String,
    /// `todo`, `doing`, `review`, `blocked` or `done`.
    #[serde(default = "todo")]
    pub status: String,
    /// `whenever`, `today`, `hour` or `now`.
    #[serde(default = "today")]
    pub urgency: String,
    /// The assigned bot's slug.
    pub bot: Option<String>,
    #[serde(default)]
    pub act_now: bool,
}

fn todo() -> String {
    "todo".into()
}

fn today() -> String {
    "today".into()
}

impl Ticket {
    fn check(mut self) -> Result<Self, &'static str> {
        self.title = self.title.trim().to_owned();
        self.body = self.body.trim().to_owned();
        let statuses = ["todo", "doing", "review", "blocked", "done"];
        match () {
            _ if !(1..=200).contains(&self.title.chars().count()) => {
                Err("Give the ticket a title of 1 to 200 characters")
            }
            _ if self.body.chars().count() > 8000 => {
                Err("The details are limited to 8,000 characters")
            }
            _ if !statuses.contains(&self.status.as_str()) => Err("Unknown status"),
            _ if !["whenever", "today", "hour", "now"].contains(&self.urgency.as_str()) => {
                Err("Unknown urgency")
            }
            _ => Ok(self),
        }
    }

    /// How a bot sees the ticket: labelled, so it reads as the task's data (B-TKT-03).
    pub fn as_data(&self) -> String {
        let mut text = format!(
            "Ticket OB-{} [{}, urgency {}]: {}",
            self.id, self.status, self.urgency, self.title
        );
        if !self.body.is_empty() {
            text.push_str("\n\n");
            text.push_str(&self.body);
        }
        text
    }
}

pub(crate) async fn get(db: &PgPool, id: i64) -> sqlx::Result<Option<Ticket>> {
    sqlx::query_as!(
        Ticket,
        r#"select t.id, t.title, t.body, t.status::text as "status!", t.urgency, b.slug as "bot?", t.act_now
           from ticket t left join bot b on b.id = t.bot_id where t.id = $1"#,
        id
    )
    .fetch_optional(db)
    .await
}

pub async fn list(State(app): State<Shared>) -> Result<Json<Vec<Ticket>>, ApiError> {
    sqlx::query_as!(
        Ticket,
        r#"select t.id, t.title, t.body, t.status::text as "status!", t.urgency, b.slug as "bot?", t.act_now
           from ticket t left join bot b on b.id = t.bot_id
           order by t.status = 'done', array_position(array['now', 'hour', 'today', 'whenever'], t.urgency), t.id desc"#
    )
    .fetch_all(&app.db)
    .await
    .map(Json)
    .map_err(|e| internal("listing tickets", e))
}

/// A new ticket. System 1 triages it in the background when it's on.
pub async fn create(
    State(app): State<Shared>,
    Json(ticket): Json<Ticket>,
) -> Result<Json<Ticket>, ApiError> {
    let t = ticket
        .check()
        .map_err(|why| (StatusCode::UNPROCESSABLE_ENTITY, why))?;
    let id = sqlx::query_scalar!(
        "insert into ticket (title, body, urgency) values ($1, $2, $3) returning id",
        t.title,
        t.body,
        t.urgency
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("creating a ticket", e))?;
    let ticket = Ticket { id, ..t };
    if app.system1.enabled() {
        tokio::spawn(triage(app.clone(), ticket.clone()));
    }
    Ok(Json(ticket))
}

async fn triage(app: Shared, ticket: Ticket) {
    let roster = bots::all(&app.db).await.unwrap_or_default();
    let text = format!("{}\n\n{}", ticket.title, ticket.body);
    let Some(t) = app
        .system1
        .triage_ticket(&app.db, &text, &roster, Some(ticket.id))
        .await
    else {
        return;
    };
    let saved = sqlx::query!(
        "update ticket set bot_id = coalesce((select id from bot where slug = $2), bot_id),
                urgency = coalesce($3, urgency), act_now = $4, updated_at = now()
         where id = $1 and bot_id is null",
        ticket.id,
        t.bot.as_ref().map(|b| b.slug.clone()),
        t.urgency,
        t.act_now
    )
    .execute(&app.db)
    .await;
    if let Err(e) = saved {
        return warn!("saving a ticket's triage: {e}");
    }
    if t.act_now
        && t.bot.is_some()
        && let Err(e) = start(&app, ticket.id).await
    {
        warn!("starting a triaged ticket: {e:?}");
    }
}

/// Saves the owner's changes. Assigning a bot that wasn't assigned before starts it.
pub async fn update(
    State(app): State<Shared>,
    Json(ticket): Json<Ticket>,
) -> Result<Json<Ticket>, ApiError> {
    let t = ticket
        .check()
        .map_err(|why| (StatusCode::UNPROCESSABLE_ENTITY, why))?;
    let before = get(&app.db, t.id)
        .await
        .map_err(|e| internal("reading a ticket", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such ticket"))?;
    sqlx::query!(
        "update ticket set title = $2, body = $3, status = $4::text::ticket_status, urgency = $5,
                bot_id = (select id from bot where slug = $6), updated_at = now()
         where id = $1",
        t.id,
        t.title,
        t.body,
        t.status,
        t.urgency,
        t.bot
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("saving a ticket", e))?;
    if t.bot != before.bot {
        crate::system1::label_ticket_bot(&app.db, t.id, t.bot.as_deref()).await;
    } else if t.status == "done" && before.status != "done" {
        crate::system1::label_ticket_kept(&app.db, t.id, "finished the ticket with its bot").await;
    }
    if t.urgency != before.urgency {
        crate::system1::label_ticket_urgency(&app.db, t.id, &t.urgency).await;
    }
    let newly_assigned = t.bot.is_some() && t.bot != before.bot && t.status == "todo";
    if newly_assigned {
        start(&app, t.id).await?;
    }
    Ok(Json(t))
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

pub async fn start_now(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<StatusCode, ApiError> {
    start(&app, by.id).await?;
    crate::system1::label_ticket_kept(&app.db, by.id, "started the ticket with its bot").await;
    Ok(StatusCode::ACCEPTED)
}

/// Why [start] refused: the bot already has a run.
pub(crate) const BUSY: &str = "That bot is busy; start the ticket when it's free";

/// Hands the ticket to its bot (B-TKT-01).
pub(crate) async fn start(app: &App, id: i64) -> Result<(), ApiError> {
    let ticket = get(&app.db, id)
        .await
        .map_err(|e| internal("reading a ticket", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such ticket"))?;
    let slug = ticket
        .bot
        .clone()
        .ok_or((StatusCode::CONFLICT, "Assign the ticket to a bot first"))?;
    let thread = db::bot_thread(&app.db, &slug)
        .await
        .map_err(|e| internal("finding the bot's thread", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such bot"))?;
    if runs::busy(&app.db, thread.id)
        .await
        .map_err(|e| internal("checking the bot", e))?
    {
        return Err((StatusCode::CONFLICT, BUSY));
    }
    let doing = Ticket {
        status: "doing".into(),
        ..ticket
    };
    sqlx::query!(
        "update ticket set status = 'doing', updated_at = now() where id = $1",
        id
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("starting a ticket", e))?;
    let notice = ThreadEvent::Notice {
        text: format!("Ticket OB-{id}: {}", doing.title),
    };
    record(app, &thread, notice).await;
    let text = format!(
        "Work on this ticket. It's labelled data from the ticket board.\n```\n{}\n```",
        doing.as_data().replace("```", "'''")
    );
    let message = ThreadEvent::Message {
        role: Role::User,
        text: text.clone(),
    };
    record(app, &thread, message).await;
    let device = sqlx::query_scalar!("select device_id from ticket where id = $1", id)
        .fetch_one(&app.db)
        .await
        .map_err(|e| internal("reading a ticket", e))?;
    let source = runs::Source {
        ticket: Some(id),
        device,
        ..Default::default()
    };
    submit(app, &thread, text, source)
        .await
        .map_err(|e| internal("queueing the ticket's run", e))?;
    Ok(())
}

/// A run ended: move its ticket along.
pub async fn run_ended(db: &PgPool, run: i64, outcome: RunOutcome) {
    let status = match outcome {
        RunOutcome::Completed => "review",
        RunOutcome::Failed => "blocked",
        RunOutcome::Cancelled => "todo",
    };
    let moved = sqlx::query!(
        "update ticket set status = $2::text::ticket_status, updated_at = now()
         where id = (select ticket_id from run where id = $1) and status = 'doing'",
        run,
        status
    )
    .execute(db)
    .await;
    if let Err(e) = moved {
        warn!("moving a ticket on: {e}");
    }
}

/// `OB-12` in a message: the tickets it names, as data for the run (B-TKT-03).
pub async fn referenced(db: &PgPool, text: &str) -> String {
    let ids: Vec<i64> = text
        .split(|c: char| !c.is_ascii_alphanumeric() && c != '-')
        .filter_map(|w| w.strip_prefix("OB-")?.parse().ok())
        .take(3)
        .collect();
    let mut out = String::new();
    for id in ids {
        if let Ok(Some(t)) = get(db, id).await {
            out.push_str(&format!(
                "\n\nReferenced ticket (data):\n```\n{}\n```",
                t.as_data().replace("```", "'''")
            ));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn ticket(db: &PgPool, title: &str) -> i64 {
        sqlx::query_scalar!(
            "insert into ticket (title, body) values ($1, 'details') returning id",
            title
        )
        .fetch_one(db)
        .await
        .unwrap()
    }

    #[sqlx::test]
    async fn references_become_labelled_data(db: PgPool) {
        let id = ticket(&db, "Reply to the supplier").await;
        let data = referenced(&db, &format!("see OB-{id}, and OB-999 which doesn't exist")).await;
        assert!(data.contains(&format!(
            "Ticket OB-{id} [todo, urgency today]: Reply to the supplier"
        )));
        assert!(data.contains("details"));
        assert_eq!(data.matches("Referenced ticket").count(), 1);
        assert!(
            referenced(&db, "no tickets here, not even OB- or XOB-1")
                .await
                .is_empty()
        );
    }

    #[sqlx::test]
    async fn a_finished_run_moves_its_ticket(db: PgPool) {
        let id = ticket(&db, "Draft a reply").await;
        let runs::Submitted::Queued(run) = runs::submit(&db, 1, "work", runs::Source::default())
            .await
            .unwrap()
        else {
            panic!("expected a run")
        };
        sqlx::query!("update run set ticket_id = $2 where id = $1", run, id)
            .execute(&db)
            .await
            .unwrap();
        sqlx::query!("update ticket set status = 'doing' where id = $1", id)
            .execute(&db)
            .await
            .unwrap();
        run_ended(&db, run, RunOutcome::Completed).await;
        assert_eq!(get(&db, id).await.unwrap().unwrap().status, "review");
        // Only a ticket that's being worked on moves.
        run_ended(&db, run, RunOutcome::Failed).await;
        assert_eq!(get(&db, id).await.unwrap().unwrap().status, "review");
    }
}
