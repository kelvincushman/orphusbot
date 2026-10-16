//! System 1: fast typed decisions from Laya (DESIGN §7), each one receipted.
//!
//! The server asks laya-serve's `/v1/systemone` (the TypeSafe Jev wire
//! protocol) a question and acts only when the answer is confident enough.
//! When Laya isn't configured, is slow or fails, System 1 abstains and the
//! safe default applies: the message stays in the inbox, the tool call asks.
//!
//! System 1 never approves an irreversible action (AGENTS.md rule 5); the gate
//! only asks it about calls that are reversible by construction (`gate.rs`).

use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::State;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tracing::warn;

use crate::bots::Bot;
use crate::{ApiError, Shared, internal};

/// Strict defaults until thresholds are fitted to the owner's labels (DESIGN §7.5).
const ROUTE_THRESHOLD: f64 = 0.85;
const GATE_THRESHOLD: f64 = 0.95;
/// However it's tuned, letting a tool call through takes at least this.
const GATE_FLOOR: f64 = 0.9;
/// Laya's state limit is generous; receipts and requests don't need more than this.
const MAX_STATE_CHARS: usize = 4_000;

pub struct System1 {
    http: reqwest::Client,
    /// laya-serve's base URL, such as `http://127.0.0.1:7600`; `None` = always abstain.
    url: Option<String>,
    timeout: Duration,
    route_threshold: f64,
    gate_threshold: f64,
}

/// One answer, or an abstention, with what a receipt needs.
struct Asked {
    answers: Option<Value>,
    model: Option<String>,
    latency_ms: i32,
}

/// What a receipt records.
pub struct Receipt<'a> {
    pub catalogue: &'static str,
    pub state: &'a str,
    pub threshold: f64,
    pub confidence: Option<f64>,
    pub outcome: String,
    pub run: Option<i64>,
    pub tool_call_id: Option<&'a str>,
}

impl System1 {
    /// `ORPHUSBOT_LAYA_URL` turns it on; `ORPHUSBOT_LAYA_TIMEOUT_MS` (default 1500) bounds each ask.
    pub fn from_env() -> Self {
        let timeout = std::env::var("ORPHUSBOT_LAYA_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1500);
        let threshold = |name: &str, default: f64| {
            std::env::var(name)
                .ok()
                .and_then(|v| v.parse::<f64>().ok())
                .filter(|t| (0.0..=1.0).contains(t))
                .unwrap_or(default)
        };
        Self {
            http: reqwest::Client::new(),
            url: std::env::var("ORPHUSBOT_LAYA_URL")
                .ok()
                .map(|u| u.trim_end_matches('/').to_owned())
                .filter(|u| !u.is_empty()),
            timeout: Duration::from_millis(timeout),
            route_threshold: threshold("ORPHUSBOT_ROUTE_THRESHOLD", ROUTE_THRESHOLD),
            gate_threshold: threshold("ORPHUSBOT_GATE_THRESHOLD", GATE_THRESHOLD).max(GATE_FLOOR),
        }
    }

    /// Always abstains.
    #[cfg(test)]
    pub fn off() -> Self {
        Self {
            http: reqwest::Client::new(),
            url: None,
            timeout: Duration::from_millis(1),
            route_threshold: ROUTE_THRESHOLD,
            gate_threshold: GATE_THRESHOLD,
        }
    }

    pub fn enabled(&self) -> bool {
        self.url.is_some()
    }

    async fn ask(&self, state: &str, questions: Value) -> Asked {
        let started = Instant::now();
        let answers = match &self.url {
            None => None,
            Some(url) => {
                let body = json!({ "state": state, "questions": questions });
                let call = self
                    .http
                    .post(format!("{url}/v1/systemone"))
                    .json(&body)
                    .timeout(self.timeout)
                    .send();
                match call.await.and_then(reqwest::Response::error_for_status) {
                    Ok(res) => res
                        .json::<Value>()
                        .await
                        .map_err(|e| warn!("reading Laya's answer: {e}"))
                        .ok(),
                    Err(e) => {
                        warn!("asking Laya: {e}");
                        None
                    }
                }
            }
        };
        let latency_ms = i32::try_from(started.elapsed().as_millis()).unwrap_or(i32::MAX);
        Asked {
            model: answers
                .as_ref()
                .and_then(|a| a["model"].as_str().map(str::to_owned)),
            answers: answers
                .map(|a| a["answers"].clone())
                .filter(|a| a.is_object()),
            latency_ms,
        }
    }

    /// Which bot should take a message sent to the inbox (DESIGN §7.2 `triage.bot`)?
    /// `Some` only when System 1 is confident it's another bot's; otherwise the inbox keeps it.
    pub async fn route(&self, db: &PgPool, text: &str, roster: &[Bot]) -> Option<(Bot, f64)> {
        let enabled: Vec<&Bot> = roster.iter().filter(|b| !b.disabled).collect();
        if !self.enabled() || !enabled.iter().any(|b| b.slug != "inbox") {
            return None;
        }
        let criteria: serde_json::Map<String, Value> = enabled
            .iter()
            .map(|b| {
                let remit = if b.remit.is_empty() {
                    b.name.clone()
                } else {
                    b.remit.clone()
                };
                (b.slug.clone(), json!(remit))
            })
            .collect();
        let state: String = text.chars().take(MAX_STATE_CHARS).collect();
        let questions = json!({ "bot": {
            "type": "choice",
            "instructions": "Which bot should handle this message?",
            "criteria": criteria,
        }});
        let asked = self.ask(&state, questions).await;
        let answer = asked.answers.as_ref().map(|a| &a["bot"]);
        let choice = answer.and_then(|a| a["choice"].as_str());
        let confidence = answer.and_then(confidence);
        let chosen = choice
            .filter(|c| *c != "inbox")
            .filter(|_| confidence.is_some_and(|c| c >= self.route_threshold))
            .and_then(|c| enabled.iter().find(|b| b.slug == c));
        let outcome = match (chosen, &asked.answers, choice) {
            (Some(bot), _, _) => format!("Sent to {}", bot.name),
            (None, None, _) => "Abstained; kept in the inbox".to_owned(),
            (None, Some(_), Some("inbox")) => "Kept in the inbox (System 1 chose it)".to_owned(),
            (None, Some(_), _) => "Not sure enough; kept in the inbox".to_owned(),
        };
        let receipt = Receipt {
            catalogue: "triage",
            state: &state,
            threshold: self.route_threshold,
            confidence,
            outcome,
            run: None,
            tool_call_id: None,
        };
        record(db, &receipt, &asked).await;
        chosen.map(|b| ((*b).clone(), confidence.unwrap_or_default()))
    }

    /// May a reversible tool call run without asking (DESIGN §7.4 `gate.verdict`)?
    /// Only ever called for calls that are reversible by construction.
    pub async fn pass(&self, db: &PgPool, state: &str, run: i64, tool_call_id: &str) -> bool {
        if !self.enabled() {
            return false;
        }
        let state: String = state.chars().take(MAX_STATE_CHARS).collect();
        let questions = json!({ "verdict": {
            "type": "choice",
            "instructions": "Can this tool call go ahead without asking the owner? Pick ask unless it is plainly part of the task and harmless.",
            "criteria": {
                "pass": "clearly part of the task, harmless and easy to undo",
                "ask": "anything unusual, unclear, risky or outside the task",
            },
        }});
        let asked = self.ask(&state, questions).await;
        let answer = asked.answers.as_ref().map(|a| &a["verdict"]);
        let confidence = answer.and_then(confidence);
        let passed = answer.and_then(|a| a["choice"].as_str()) == Some("pass")
            && confidence.is_some_and(|c| c >= self.gate_threshold);
        let outcome = match (passed, &asked.answers) {
            (true, _) => "Allowed by System 1".to_owned(),
            (false, None) => "Abstained; asked the owner".to_owned(),
            (false, Some(_)) => "Asked the owner".to_owned(),
        };
        let receipt = Receipt {
            catalogue: "gate",
            state: &state,
            threshold: self.gate_threshold,
            confidence,
            outcome,
            run: Some(run),
            tool_call_id: Some(tool_call_id),
        };
        record(db, &receipt, &asked).await;
        passed
    }
}

/// Laya's calibrated confidence in the chosen answer.
fn confidence(answer: &Value) -> Option<f64> {
    answer["answer_confidence"].as_f64()
}

async fn record(db: &PgPool, r: &Receipt<'_>, asked: &Asked) {
    let hash = Sha256::digest(r.state.as_bytes()).to_vec();
    let stored = sqlx::query!(
        "insert into decision (catalogue, state_hash, state, answers, abstained, threshold,
                               confidence, model, latency_ms, outcome, run_id, tool_call_id)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        r.catalogue,
        hash,
        r.state,
        asked.answers,
        asked.answers.is_none(),
        r.threshold as f32,
        r.confidence.map(|c| c as f32),
        asked.model,
        asked.latency_ms,
        r.outcome,
        r.run,
        r.tool_call_id
    )
    .execute(db)
    .await;
    // ponytail: the 30-day trim rides on new receipts; a scheduled job when jobs arrive (DESIGN §3.5).
    let trimmed = sqlx::query!(
        "update decision set state = null where state is not null and created_at < now() - interval '30 days'"
    )
    .execute(db)
    .await;
    if let Err(e) = stored.and(trimmed) {
        warn!("storing a decision receipt: {e}");
    }
}

/// Recent receipts, newest first, for the Decisions view.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select id, catalogue, state, abstained, threshold, confidence, model, latency_ms, outcome,
                  created_at::text as "created_at!"
           from decision order by id desc limit 100"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing decisions", e))?;
    let list: Vec<Value> = rows
        .into_iter()
        .map(|r| {
            json!({
                "id": r.id, "catalogue": r.catalogue, "state": r.state, "abstained": r.abstained,
                "threshold": r.threshold, "confidence": r.confidence, "model": r.model,
                "latency_ms": r.latency_ms, "outcome": r.outcome, "created_at": r.created_at,
            })
        })
        .collect();
    Ok(Json(json!(list)))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A laya-serve stand-in that gives every question the same answer.
    pub(crate) async fn fake_laya(
        question: &'static str,
        choice: &'static str,
        confidence: f64,
    ) -> System1 {
        let answer = json!({ "model": "fake-laya", "answers": { question: {
            "type": "choice", "choice": choice, "answer_confidence": confidence,
        }}});
        let app = axum::Router::new().route(
            "/v1/systemone",
            axum::routing::post(move || {
                let answer = answer.clone();
                async move { Json(answer) }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        System1 {
            http: reqwest::Client::new(),
            url: Some(url),
            timeout: Duration::from_secs(5),
            route_threshold: ROUTE_THRESHOLD,
            gate_threshold: GATE_THRESHOLD,
        }
    }

    fn bot(slug: &str, disabled: bool) -> Bot {
        Bot {
            slug: slug.into(),
            name: slug.to_uppercase(),
            remit: format!("{slug} work"),
            instructions: String::new(),
            model: None,
            thinking: None,
            exclude_tools: vec![],
            scope: "private".into(),
            disabled,
        }
    }

    #[sqlx::test]
    async fn routes_only_when_sure_and_never_to_the_inbox(db: PgPool) {
        let roster = [
            bot("inbox", false),
            bot("researcher", false),
            bot("coder", true),
        ];
        let sure = fake_laya("bot", "researcher", 0.92).await;
        let (to, how_sure) = sure.route(&db, "look this up", &roster).await.unwrap();
        assert_eq!((to.slug.as_str(), how_sure), ("researcher", 0.92));

        assert!(
            fake_laya("bot", "researcher", 0.6)
                .await
                .route(&db, "hm", &roster)
                .await
                .is_none()
        );
        assert!(
            fake_laya("bot", "inbox", 0.99)
                .await
                .route(&db, "hi", &roster)
                .await
                .is_none()
        );
        // A disabled bot is never offered, so an answer naming it can't route there.
        assert!(
            fake_laya("bot", "coder", 0.99)
                .await
                .route(&db, "fix", &roster)
                .await
                .is_none()
        );
        // Off: abstains without asking, and without a receipt.
        assert!(
            System1::off()
                .route(&db, "look this up", &roster)
                .await
                .is_none()
        );

        let outcomes: Vec<String> = sqlx::query_scalar!("select outcome from decision order by id")
            .fetch_all(&db)
            .await
            .unwrap();
        assert_eq!(
            outcomes,
            [
                "Sent to RESEARCHER",
                "Not sure enough; kept in the inbox",
                "Kept in the inbox (System 1 chose it)",
                "Not sure enough; kept in the inbox",
            ]
        );
    }

    #[sqlx::test]
    async fn an_unreachable_laya_abstains(db: PgPool) {
        let gone = System1 {
            http: reqwest::Client::new(),
            url: Some("http://127.0.0.1:9".into()),
            timeout: Duration::from_millis(300),
            route_threshold: ROUTE_THRESHOLD,
            gate_threshold: GATE_THRESHOLD,
        };
        let roster = [bot("inbox", false), bot("researcher", false)];
        assert!(gone.route(&db, "look this up", &roster).await.is_none());
        let abstained: bool = sqlx::query_scalar!("select abstained from decision")
            .fetch_one(&db)
            .await
            .unwrap();
        assert!(abstained);
    }
}
