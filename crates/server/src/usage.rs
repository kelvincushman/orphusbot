//! The quota tracker (PRD M4): what each bot's model calls used, by provider and
//! model, today and this week, and an optional daily token budget. Crossing the
//! budget plays `budget_warn` on every wrist and pushes to the phone, once a day.

use axum::Json;
use axum::extract::State;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, App, Shared, internal};

/// `ORPHUSBOT_DAILY_TOKEN_BUDGET`: input + output tokens a day before warning.
fn budget() -> Option<i64> {
    std::env::var("ORPHUSBOT_DAILY_TOKEN_BUDGET")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|b| *b > 0)
}

/// One assistant message's usage, from its node.
#[allow(clippy::too_many_arguments)]
pub async fn record(
    app: &App,
    run: i64,
    bot: &str,
    provider: &str,
    model: &str,
    tokens: [u64; 4],
    cost_micros: u64,
) {
    let [input, output, cache_read, cache_write] =
        tokens.map(|t| i64::try_from(t).unwrap_or(i64::MAX));
    let saved = sqlx::query!(
        "insert into usage (run_id, bot, provider, model, input, output, cache_read, cache_write, cost_micros)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        run,
        bot,
        provider,
        model,
        input,
        output,
        cache_read,
        cache_write,
        i64::try_from(cost_micros).unwrap_or(i64::MAX)
    )
    .execute(&app.db)
    .await;
    if let Err(e) = saved {
        return warn!("storing usage: {e}");
    }
    let Some(budget) = budget() else {
        return;
    };
    let today = today_tokens(&app.db).await;
    if crossed(today, input + output, budget) {
        crate::device::warn_all(app, "budget_warn", "budget").await;
        app.notifier.send(crate::notify::Push {
            title: "Today's model budget is used up".into(),
            body: format!("Bots have used {today} tokens today (budget {budget})."),
            priority: 3,
            tags: "money_with_wings",
            bot: None,
        });
    }
}

/// Only the message that takes today's total over the budget warns, so it happens once a day.
fn crossed(today: i64, this_message: i64, budget: i64) -> bool {
    today >= budget && today - this_message < budget
}

async fn today_tokens(db: &PgPool) -> i64 {
    sqlx::query_scalar!(
        r#"select coalesce(sum(input + output), 0)::bigint as "n!" from usage where created_at >= date_trunc('day', now())"#
    )
    .fetch_one(db)
    .await
    .unwrap_or(0)
}

/// Today and the last 7 days, by provider and model, and today by bot.
pub async fn summary(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let by_model = |rows: Vec<(String, String, i64, i64, i64, i64)>| -> Vec<Value> {
        rows.into_iter()
            .map(|(provider, model, turns, input, output, cost)| {
                json!({ "provider": provider, "model": model, "turns": turns, "input": input, "output": output,
                        "cost": cost as f64 / 1_000_000.0 })
            })
            .collect()
    };
    let period = |days: f64| {
        let db = app.db.clone();
        async move {
            sqlx::query!(
                r#"select provider, model, count(*) as "turns!", sum(input)::bigint as "input!",
                          sum(output)::bigint as "output!", sum(cost_micros)::bigint as "cost!"
                   from usage where created_at >= date_trunc('day', now()) - make_interval(days => $1::float8::int)
                   group by provider, model order by sum(input + output) desc"#,
                days
            )
            .fetch_all(&db)
            .await
            .map(|rows| {
                rows.into_iter()
                    .map(|r| (r.provider, r.model, r.turns, r.input, r.output, r.cost))
                    .collect::<Vec<_>>()
            })
        }
    };
    let today = period(0.0)
        .await
        .map_err(|e| internal("summing usage", e))?;
    let week = period(6.0)
        .await
        .map_err(|e| internal("summing usage", e))?;
    let bots = sqlx::query!(
        r#"select bot, count(*) as "turns!", sum(input + output)::bigint as "tokens!"
           from usage where created_at >= date_trunc('day', now()) group by bot order by 3 desc"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("summing usage", e))?;
    Ok(Json(json!({
        "today": by_model(today),
        "week": by_model(week),
        "bots_today": bots.into_iter().map(|b| json!({ "bot": b.bot, "turns": b.turns, "tokens": b.tokens })).collect::<Vec<_>>(),
        "today_tokens": today_tokens(&app.db).await,
        "budget": budget(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warns_once_when_the_budget_is_crossed() {
        assert!(!crossed(900, 100, 1000), "still under");
        assert!(crossed(1000, 100, 1000), "this message reached it");
        assert!(crossed(1200, 300, 1000), "this message went over it");
        assert!(
            !crossed(1300, 100, 1000),
            "already over before this message"
        );
    }
}
