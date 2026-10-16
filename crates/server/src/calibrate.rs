//! Calibration (DESIGN §7.5, M5.2): fit System 1's thresholds to the owner's
//! labels, check them on the newest labels held out, then apply or roll back.
//!
//! The cut is Laya's own (`laya.calibrate`'s conservative abstention threshold),
//! fitted on the confidences the receipts already hold. Refitting Laya's
//! temperatures needs its raw logits, which receipts don't keep, so that stays
//! with Laya's tools on the GPU box (D-027).

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sqlx::PgPool;

use crate::system1::{Fitted, GATE_FLOOR};
use crate::{ApiError, App, Shared, internal};

/// A question that can be fitted: its key, receipt catalogue, label key,
/// the error it may make among the answers it acts on, and its lowest threshold.
struct Question {
    key: &'static str,
    catalogue: &'static str,
    label: &'static str,
    target_error: f64,
    floor: f64,
}

const QUESTIONS: [Question; 2] = [
    Question {
        key: "triage.bot",
        catalogue: "triage",
        label: "bot",
        target_error: 0.10,
        floor: 0.5,
    },
    // Only "pass" answers act, so only they are fitted (see `pairs`).
    Question {
        key: "gate.verdict",
        catalogue: "gate",
        label: "verdict",
        target_error: 0.05,
        floor: GATE_FLOOR,
    },
];

/// Fewer labels than this and a question keeps its threshold.
const MIN_LABELS: usize = 30;

/// Laya's selective cut, conservative: the lowest confidence whose accepted
/// answers (confidence at or above it) keep `(errors + 1) / (accepted + 1)`
/// within `target`. 1.0 when no cut does.
fn cut(pairs: &[(f64, bool)], target: f64) -> f64 {
    let mut levels: Vec<f64> = pairs.iter().map(|p| p.0).collect();
    levels.sort_by(|a, b| b.total_cmp(a));
    levels.dedup();
    let mut best = None;
    for tau in levels {
        let accepted: Vec<bool> = pairs.iter().filter(|p| p.0 >= tau).map(|p| p.1).collect();
        let errors = accepted.iter().filter(|ok| !**ok).count();
        if (errors as f64 + 1.0) / (accepted.len() as f64 + 1.0) <= target {
            best = Some(tau);
        }
    }
    best.unwrap_or(1.0).clamp(0.0, 1.0)
}

/// How a threshold does on some labelled answers.
fn score(pairs: &[(f64, bool)], threshold: f64) -> Value {
    let accepted: Vec<bool> = pairs
        .iter()
        .filter(|p| p.0 >= threshold)
        .map(|p| p.1)
        .collect();
    let errors = accepted.iter().filter(|ok| !**ok).count();
    json!({ "threshold": threshold, "accepted": accepted.len(), "errors": errors })
}

/// `(confidence, right)` for each labelled answer System 1 gave, oldest first.
async fn pairs(db: &PgPool, q: &Question) -> sqlx::Result<Vec<(f64, bool)>> {
    let rows = sqlx::query!(
        r#"select d.confidence::float8 as "confidence!", l.agrees
           from decision d
           join lateral (select agrees from decision_label
                         where decision_id = d.id and label ? $2 order by id desc limit 1) l on true
           where d.catalogue = $1 and not d.abstained and d.confidence is not null
             and ($2 <> 'verdict' or d.answers -> 'verdict' ->> 'choice' = 'pass')
           order by d.created_at, d.id"#,
        q.catalogue,
        q.label
    )
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(|r| (r.confidence, r.agrees)).collect())
}

/// Fits every question with enough labels and saves the result, not yet applied.
pub async fn fit(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let mut thresholds = Map::new();
    let mut report = Map::new();
    for q in &QUESTIONS {
        let pairs = pairs(&app.db, q)
            .await
            .map_err(|e| internal("reading labels", e))?;
        let now = match q.key {
            "gate.verdict" => app.system1.gate_threshold(),
            _ => app.system1.bot_threshold(),
        };
        if pairs.len() < MIN_LABELS {
            report.insert(
                q.key.into(),
                json!({ "labels": pairs.len(), "needs": MIN_LABELS }),
            );
            continue;
        }
        // The newest fifth checks the fit; the rest makes it.
        let held = pairs.len() / 5;
        let (train, test) = pairs.split_at(pairs.len() - held);
        let fitted = cut(train, q.target_error).max(q.floor);
        thresholds.insert(q.key.into(), json!(fitted));
        report.insert(
            q.key.into(),
            json!({
                "labels": pairs.len(), "held_out": held, "target_error": q.target_error,
                "before": score(test, now), "after": score(test, fitted),
            }),
        );
    }
    if thresholds.is_empty() {
        return Ok(Json(json!({ "model": null, "report": report })));
    }
    let id = sqlx::query_scalar!(
        "insert into decision_model (thresholds, report) values ($1, $2) returning id",
        Value::Object(thresholds),
        Value::Object(report.clone())
    )
    .fetch_one(&app.db)
    .await
    .map_err(|e| internal("saving a calibration", e))?;
    Ok(Json(json!({ "model": id, "report": report })))
}

/// Calibrations, newest first.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select id, thresholds, report, fitted_at::text as "fitted_at!", applied_at::text, active
           from decision_model order by id desc limit 20"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing calibrations", e))?;
    let list: Vec<Value> = rows
        .into_iter()
        .map(|r| {
            json!({
                "id": r.id, "thresholds": r.thresholds, "report": r.report,
                "fitted_at": r.fitted_at, "applied_at": r.applied_at, "active": r.active,
            })
        })
        .collect();
    Ok(Json(json!(list)))
}

#[derive(Deserialize)]
pub struct ById {
    id: i64,
}

/// Makes a calibration the one System 1 uses.
pub async fn apply(
    State(app): State<Shared>,
    Json(by): Json<ById>,
) -> Result<StatusCode, ApiError> {
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("applying a calibration", e))?;
    sqlx::query!("update decision_model set active = false where active")
        .execute(&mut *tx)
        .await
        .map_err(|e| internal("applying a calibration", e))?;
    let found = sqlx::query!(
        "update decision_model set active = true, applied_at = now() where id = $1",
        by.id
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("applying a calibration", e))?;
    if found.rows_affected() == 0 {
        return Err((StatusCode::NOT_FOUND, "No such calibration"));
    }
    tx.commit()
        .await
        .map_err(|e| internal("applying a calibration", e))?;
    load(&app).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Goes back to the calibration applied before the active one, or to the defaults.
pub async fn rollback(State(app): State<Shared>) -> Result<StatusCode, ApiError> {
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("rolling back", e))?;
    let active =
        sqlx::query_scalar!("update decision_model set active = false where active returning id")
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| internal("rolling back", e))?
            .ok_or((
                StatusCode::CONFLICT,
                "Nothing is applied; System 1 is on its defaults",
            ))?;
    sqlx::query!(
        "update decision_model set active = true
         where id = (select id from decision_model
                     where applied_at < (select applied_at from decision_model where id = $1)
                     order by applied_at desc limit 1)",
        active
    )
    .execute(&mut *tx)
    .await
    .map_err(|e| internal("rolling back", e))?;
    tx.commit().await.map_err(|e| internal("rolling back", e))?;
    load(&app).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Hands the active calibration (or none) to System 1. Called at start and on every change.
pub async fn load(app: &App) {
    let active = sqlx::query_scalar!("select thresholds from decision_model where active")
        .fetch_optional(&app.db)
        .await;
    let thresholds = match active {
        Ok(t) => t.unwrap_or_default(),
        Err(e) => return tracing::warn!("reading the active calibration: {e}"),
    };
    app.system1.apply(Fitted {
        bot: thresholds["triage.bot"].as_f64(),
        gate: thresholds["gate.verdict"].as_f64(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cut_keeps_the_error_within_target() {
        // 40 right answers at 0.95+, then mistakes creep in below 0.8.
        let mut pairs: Vec<(f64, bool)> = (0..40)
            .map(|i| (0.95 + f64::from(i) / 1000.0, true))
            .collect();
        pairs.extend([
            (0.85, true),
            (0.8, false),
            (0.7, false),
            (0.6, true),
            (0.5, false),
        ]);
        assert_eq!(cut(&pairs, 0.05), 0.8);
        // Looser: one more mistake in ten is fine, so it acts on everything here.
        assert_eq!(cut(&pairs, 0.10), 0.5);
        // Strict enough that even the best answers can't show it: never act.
        assert_eq!(cut(&pairs[..3], 0.05), 1.0);
        assert_eq!(cut(&[], 0.1), 1.0);
        let s = score(&pairs, 0.8);
        assert_eq!(
            (s["accepted"].as_u64(), s["errors"].as_u64()),
            (Some(42), Some(1))
        );
    }

    #[sqlx::test]
    async fn fit_apply_and_roll_back(db: PgPool) {
        let app = crate::auth::tests::app(db.clone());
        // 40 gate answers of "pass" the owner then allowed, all 0.97 sure.
        for i in 0..40u8 {
            let id: i64 = sqlx::query_scalar!(
                r#"insert into decision (catalogue, state_hash, answers, abstained, threshold, confidence, latency_ms, outcome)
                   values ('gate', $1, '{"verdict": {"choice": "pass"}}', false, 0.95, 0.97, 5, 'x') returning id"#,
                vec![i; 32]
            )
            .fetch_one(&db)
            .await
            .unwrap();
            sqlx::query!(
                r#"insert into decision_label (decision_id, label, agrees, source)
                   values ($1, '{"verdict": "pass"}', true, 'approved the card')"#,
                id
            )
            .execute(&db)
            .await
            .unwrap();
        }
        let Json(fitted) = fit(State(app.clone())).await.unwrap();
        // Too few bot labels: routing keeps its threshold. The gate is fitted.
        assert_eq!(fitted["report"]["triage.bot"]["labels"], 0);
        assert_eq!(fitted["report"]["gate.verdict"]["held_out"], 8);
        let first = fitted["model"].as_i64().unwrap();
        // Saved, not applied.
        assert_eq!(app.system1.gate_threshold(), 0.95);

        apply(State(app.clone()), Json(ById { id: first }))
            .await
            .unwrap();
        assert!((app.system1.gate_threshold() - 0.97).abs() < 1e-6);
        let Json(again) = fit(State(app.clone())).await.unwrap();
        let second = again["model"].as_i64().unwrap();
        sqlx::query!(
            r#"update decision_model set thresholds = '{"gate.verdict": 0.99}' where id = $1"#,
            second
        )
        .execute(&db)
        .await
        .unwrap();
        apply(State(app.clone()), Json(ById { id: second }))
            .await
            .unwrap();
        assert_eq!(app.system1.gate_threshold(), 0.99);

        rollback(State(app.clone())).await.unwrap();
        assert!((app.system1.gate_threshold() - 0.97).abs() < 1e-6);
        rollback(State(app.clone())).await.unwrap();
        assert_eq!(app.system1.gate_threshold(), 0.95);
        assert_eq!(
            rollback(State(app.clone())).await.unwrap_err().0,
            StatusCode::CONFLICT
        );
        // The database refuses a gate threshold under the floor.
        let low = sqlx::query!(
            r#"insert into decision_model (thresholds, report) values ('{"gate.verdict": 0.5}', '{}')"#
        )
        .execute(&db)
        .await;
        assert!(low.is_err());
    }
}
