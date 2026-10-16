//! Capture profiles (DESIGN §10.5, PRD B-CAP-04): presets over what capture
//! keeps and how it comes back to the owner. **Focus support** (the default)
//! keeps every kind, sends three digests and an end-of-day review, files ideas
//! and things to remember by itself (undo for 24 h), brings a dismissed
//! commitment back once after three days, and nudges before appointments.
//! **Standard** keeps commitments and appointments and sends one digest.
//! Wording never guilts: open things are "still open", never "overdue".

use std::str::FromStr;
use std::time::Duration;

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use chrono::{DateTime, NaiveTime, TimeZone, Utc};
use chrono_tz::Tz;
use orphusbot_proto::ThreadEvent;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, App, Shared, db, internal, record};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Profile {
    pub focus: bool,
    pub tz: Tz,
}

impl Profile {
    /// Kinds the extractor's output is filtered to.
    pub fn keeps(&self, kind: &str) -> bool {
        self.focus || matches!(kind, "commitment" | "appointment")
    }

    /// Filed without a click (undo for 24 h).
    pub fn auto_files(&self, kind: &str) -> bool {
        self.focus && matches!(kind, "idea" | "remember")
    }

    /// Local digest times; the last one in Focus support is the end-of-day review.
    fn digests(&self) -> &'static [(u32, u32)] {
        if self.focus {
            &[(10, 0), (14, 0), (18, 0), (21, 0)]
        } else {
            &[(18, 0)]
        }
    }

    /// The latest digest time at or before `now`, if one has come today.
    fn digest_due(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let local = now.with_timezone(&self.tz);
        self.digests()
            .iter()
            .filter_map(|&(h, m)| {
                let at = local
                    .date_naive()
                    .and_time(NaiveTime::from_hms_opt(h, m, 0)?);
                self.tz.from_local_datetime(&at).earliest()
            })
            .map(|t| t.with_timezone(&Utc))
            .filter(|t| *t <= now)
            .max()
    }
}

pub async fn current(db: &PgPool) -> Profile {
    let row = sqlx::query!("select profile, timezone from capture_settings where id = 1")
        .fetch_optional(db)
        .await;
    match row {
        Ok(Some(r)) => Profile {
            focus: r.profile == "focus",
            tz: Tz::from_str(&r.timezone).unwrap_or(Tz::Europe__London),
        },
        _ => Profile {
            focus: true,
            tz: Tz::Europe__London,
        },
    }
}

pub async fn get(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let r = sqlx::query!("select profile, timezone from capture_settings where id = 1")
        .fetch_one(&app.db)
        .await
        .map_err(|e| internal("reading the capture profile", e))?;
    Ok(Json(
        json!({ "profile": r.profile, "timezone": r.timezone }),
    ))
}

#[derive(Deserialize)]
pub struct Settings {
    profile: String,
    timezone: String,
}

pub async fn set(
    State(app): State<Shared>,
    Json(s): Json<Settings>,
) -> Result<StatusCode, ApiError> {
    if !["focus", "standard"].contains(&s.profile.as_str()) {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "The profile is focus or standard",
        ));
    }
    if Tz::from_str(s.timezone.trim()).is_err() {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Unknown time zone, such as Europe/London",
        ));
    }
    sqlx::query!(
        "update capture_settings set profile = $1, timezone = $2 where id = 1",
        s.profile,
        s.timezone.trim()
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("saving the capture profile", e))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

/// Takes back something filed by itself, within 24 hours: its ticket goes too,
/// unless work on it has started.
pub async fn undo(State(app): State<Shared>, Json(by): Json<ById>) -> Result<StatusCode, ApiError> {
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("undoing a filed note", e))?;
    let ticket = sqlx::query_scalar!(
        "update proposal set state = 'dismissed', decided_at = now(), auto_filed = false
         where id = $1 and auto_filed and decided_at > now() - interval '24 hours'
         returning ticket_id",
        by.id
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| internal("undoing a filed note", e))?
    .ok_or((StatusCode::GONE, "That can't be undone any more"))?;
    sqlx::query!(
        "delete from ticket where id = $1 and status = 'todo' and bot_id is null",
        ticket
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("undoing a filed note", e))?;
    tx.commit()
        .await
        .map_err(|e| internal("undoing a filed note", e))?;
    Ok(StatusCode::NO_CONTENT)
}

/// Digests, re-surfacing and nudges, once a minute.
pub async fn tend_forever(app: Shared) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    loop {
        tick.tick().await;
        if let Err(e) = tend(&app, Utc::now()).await {
            warn!("capture profile: {e}");
        }
    }
}

async fn tend(app: &App, now: DateTime<Utc>) -> sqlx::Result<()> {
    let profile = current(&app.db).await;
    digest(app, &profile, now).await?;
    if profile.focus {
        sqlx::query!(
            "update proposal set state = 'proposed', resurfaced = true, decided_at = null
             where state = 'dismissed' and kind in ('commitment', 'task') and not resurfaced
               and not auto_filed and decided_at < $1::timestamptz - interval '3 days'",
            now
        )
        .execute(&app.db)
        .await?;
        nudges(app, now).await?;
    }
    Ok(())
}

async fn digest(app: &App, profile: &Profile, now: DateTime<Utc>) -> sqlx::Result<()> {
    let Some(due) = profile.digest_due(now) else {
        return Ok(());
    };
    let last = sqlx::query_scalar!("select last_digest_at from capture_settings where id = 1")
        .fetch_one(&app.db)
        .await?;
    if last.is_some_and(|l| l >= due) {
        return Ok(());
    }
    sqlx::query!(
        "update capture_settings set last_digest_at = $1 where id = 1",
        now
    )
    .execute(&app.db)
    .await?;
    let waiting = sqlx::query_scalar!(
        "select title from proposal where state = 'proposed' order by resurfaced desc, id limit 5"
    )
    .fetch_all(&app.db)
    .await?;
    let open = sqlx::query_scalar!(
        "select t.title from proposal p join ticket t on t.id = p.ticket_id
         where p.state = 'accepted' and p.kind in ('commitment', 'task') and t.status <> 'done'
         order by p.id limit 5"
    )
    .fetch_all(&app.db)
    .await?;
    let Some(text) = digest_text(&waiting, &open) else {
        return Ok(());
    };
    app.notifier.send(crate::notify::Push {
        title: "From your conversations".into(),
        body: text.clone(),
        priority: 2,
        tags: "memo",
        bot: None,
    });
    if let Ok(Some(inbox)) = db::bot_thread(&app.db, "inbox").await {
        record(app, &inbox, ThreadEvent::Notice { text }).await;
    }
    Ok(())
}

/// Short, concrete, no guilt: "still open", never "overdue". `None` when there's nothing.
fn digest_text(waiting: &[String], open: &[String]) -> Option<String> {
    let mut parts = Vec::new();
    if !waiting.is_empty() {
        parts.push(format!(
            "{} to look at: {}",
            waiting.len(),
            waiting.join("; ")
        ));
    }
    if !open.is_empty() {
        parts.push(format!("Still open: {}", open.join("; ")));
    }
    (!parts.is_empty()).then(|| parts.join("\n"))
}

/// "Starts in 30 min / 10 min / now" for accepted appointments with a time.
async fn nudges(app: &App, now: DateTime<Utc>) -> sqlx::Result<()> {
    let soon = sqlx::query!(
        r#"select id, title, due_at as "due_at!" from proposal
           where state = 'accepted' and kind = 'appointment' and due_at between $1::timestamptz - interval '5 minutes' and $1::timestamptz + interval '31 minutes'"#,
        now
    )
    .fetch_all(&app.db)
    .await?;
    for p in soon {
        let left = (p.due_at - now).num_minutes();
        let Some(minutes) = [0i32, 10, 30].into_iter().find(|m| left <= i64::from(*m)) else {
            continue;
        };
        let fresh = sqlx::query!(
            "insert into nudge (proposal_id, minutes) values ($1, $2) on conflict do nothing",
            p.id,
            minutes
        )
        .execute(&app.db)
        .await?
        .rows_affected()
            == 1;
        if !fresh {
            continue;
        }
        let when = if minutes == 0 {
            "Starting now".to_owned()
        } else {
            format!("Starts in {minutes} min")
        };
        app.notifier.send(crate::notify::Push {
            title: format!("{when}: {}", p.title),
            body: String::new(),
            priority: 4,
            tags: "alarm_clock",
            bot: None,
        });
        crate::device::warn_all(app, "nudge", &format!("nudge {} {minutes}", p.id)).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digests_come_at_the_profiles_times_in_its_zone() {
        let focus = Profile {
            focus: true,
            tz: Tz::Europe__London,
        };
        let at = |s: &str| DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc);
        // 15:30 in London in summer (BST, UTC+1): the 14:00 digest was the last one.
        assert_eq!(
            focus.digest_due(at("2026-07-01T14:30:00Z")),
            Some(at("2026-07-01T13:00:00Z"))
        );
        // Before 10:00 nothing has come yet today.
        assert_eq!(focus.digest_due(at("2026-07-01T08:00:00Z")), None);
        let standard = Profile {
            focus: false,
            ..focus
        };
        assert_eq!(standard.digest_due(at("2026-07-01T14:30:00Z")), None);
        assert!(standard.keeps("appointment") && !standard.keeps("idea"));
        assert!(focus.auto_files("idea") && !standard.auto_files("idea"));
        assert_eq!(
            digest_text(&["Call Sam".into()], &["Send the drawings".into()]).unwrap(),
            "1 to look at: Call Sam\nStill open: Send the drawings"
        );
        assert_eq!(digest_text(&[], &[]), None);
    }

    #[sqlx::test]
    async fn resurfaces_once_and_nudges_once(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        let now = Utc::now();
        sqlx::query!(
            "insert into proposal (kind, title, state, decided_at) values ('commitment', 'Send the drawings', 'dismissed', $1)",
            now - chrono::Duration::days(4)
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query!(
            "insert into proposal (kind, title, state, due_at) values ('appointment', 'Dentist', 'accepted', $1)",
            now + chrono::Duration::minutes(9)
        )
        .execute(&db)
        .await
        .unwrap();
        tend(&app, now).await.unwrap();
        tend(&app, now).await.unwrap();
        let back: Vec<(String, bool)> =
            sqlx::query!("select state, resurfaced from proposal where kind = 'commitment'")
                .fetch_all(&db)
                .await
                .unwrap()
                .into_iter()
                .map(|r| (r.state, r.resurfaced))
                .collect();
        assert_eq!(back, [("proposed".to_owned(), true)]);
        let nudged: Vec<i32> = sqlx::query_scalar!("select minutes from nudge")
            .fetch_all(&db)
            .await
            .unwrap();
        assert_eq!(nudged, [10], "the 10-minute nudge, once");
        // Dismissed again: it doesn't come back a second time.
        sqlx::query!(
            "update proposal set state = 'dismissed', decided_at = $1 where kind = 'commitment'",
            now - chrono::Duration::days(5)
        )
        .execute(&db)
        .await
        .unwrap();
        tend(&app, now).await.unwrap();
        let state: String =
            sqlx::query_scalar!("select state from proposal where kind = 'commitment'")
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(state, "dismissed");
    }
}
