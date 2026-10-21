//! System 1: fast typed decisions from Laya (DESIGN §7), each one receipted.
//!
//! The server asks laya-serve's `/v1/systemone` (the TypeSafe Jev wire
//! protocol) a question and acts only when the answer is confident enough.
//! When Laya isn't configured, is slow or fails, System 1 abstains and the
//! safe default applies: the message stays in the inbox, the tool call asks.
//!
//! System 1 never approves an irreversible action (AGENTS.md rule 5); the gate
//! only asks it about calls that are reversible by construction (`gate.rs`).

use std::sync::RwLock;
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
pub const GATE_FLOOR: f64 = 0.9;
/// Laya's state limit is generous; receipts and requests don't need more than this.
const MAX_STATE_CHARS: usize = 4_000;

pub struct System1 {
    http: reqwest::Client,
    /// laya-serve's base URL, such as `http://127.0.0.1:7600`; `None` = always abstain.
    url: Option<String>,
    timeout: Duration,
    route_threshold: f64,
    gate_threshold: f64,
    /// Thresholds fitted to the owner's labels and applied (M5.2, `calibrate.rs`).
    fitted: RwLock<Fitted>,
}

/// An applied calibration: `None` keeps that question's default.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Fitted {
    /// `triage.bot`: which bot takes an inbox message or a ticket.
    pub bot: Option<f64>,
    /// `gate.verdict`: never below [`GATE_FLOOR`], however it was fitted.
    pub gate: Option<f64>,
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
    pub ticket: Option<i64>,
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
            fitted: RwLock::default(),
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
            fitted: RwLock::default(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.url.is_some()
    }

    /// The confidence a bot pick needs: fitted when applied, else the default.
    pub fn bot_threshold(&self) -> f64 {
        let fitted = self.fitted.read().ok().and_then(|f| f.bot);
        fitted.unwrap_or(self.route_threshold)
    }

    /// The confidence letting a reversible call through needs; never below the floor.
    pub fn gate_threshold(&self) -> f64 {
        let fitted = self.fitted.read().ok().and_then(|f| f.gate);
        fitted.unwrap_or(self.gate_threshold).max(GATE_FLOOR)
    }

    pub fn apply(&self, fitted: Fitted) {
        if let Ok(mut f) = self.fitted.write() {
            *f = fitted;
        }
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
            .filter(|_| confidence.is_some_and(|c| c >= self.bot_threshold()))
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
            threshold: self.bot_threshold(),
            confidence,
            outcome,
            run: None,
            tool_call_id: None,
            ticket: None,
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
            && confidence.is_some_and(|c| c >= self.gate_threshold());
        let outcome = match (passed, &asked.answers) {
            (true, _) => "Allowed by System 1".to_owned(),
            (false, None) => "Abstained; asked the owner".to_owned(),
            (false, Some(_)) => "Asked the owner".to_owned(),
        };
        let receipt = Receipt {
            catalogue: "gate",
            state: &state,
            threshold: self.gate_threshold(),
            confidence,
            outcome,
            run: Some(run),
            tool_call_id: Some(tool_call_id),
            ticket: None,
        };
        record(db, &receipt, &asked).await;
        passed
    }
}

impl System1 {
    /// Pre-flight (DESIGN §7.2 `preflight.worth_running`): is a routine worth running now?
    /// Skips only when System 1 is sure there's nothing to do; abstaining fires it.
    pub async fn worth_running(&self, db: &PgPool, state: &str) -> bool {
        if !self.enabled() {
            return true;
        }
        let state: String = state.chars().take(MAX_STATE_CHARS).collect();
        let questions = json!({ "worth_running": {
            "type": "noul",
            "instructions": "Is there likely something new for this routine to do now, given what it is for and what it found last time?",
        }});
        let asked = self.ask(&state, questions).await;
        let yes = asked
            .answers
            .as_ref()
            .and_then(|a| a["worth_running"]["noul"].as_f64());
        // Sure it's a no-op: the probability of "yes" is at most 1 - threshold.
        let skip = yes.is_some_and(|p| p <= 1.0 - self.route_threshold);
        let receipt = Receipt {
            catalogue: "preflight",
            state: &state,
            threshold: self.route_threshold,
            confidence: yes.map(|p| 1.0 - p),
            outcome: if skip {
                "Skipped: nothing new"
            } else {
                "Fired"
            }
            .to_owned(),
            run: None,
            tool_call_id: None,
            ticket: None,
        };
        record(db, &receipt, &asked).await;
        !skip
    }
}

/// What System 1 suggests for a new ticket; each part only when it's sure enough.
#[derive(Debug, Default, PartialEq)]
pub struct TicketTriage {
    pub bot: Option<Bot>,
    /// One of `whenever`, `today`, `hour`, `now`.
    pub urgency: Option<&'static str>,
    /// Start without asking: only at the act-now threshold (DESIGN §7.5).
    pub act_now: bool,
}

const URGENCY: [&str; 4] = ["whenever", "today", "hour", "now"];
/// DESIGN §7.5: acting without asking needs this much, whatever else is tuned.
const ACT_NOW_THRESHOLD: f64 = 0.95;

impl System1 {
    /// Triage for a new ticket (DESIGN §7.2 `triage`: bot, urgency, act now). `None` when off.
    pub async fn triage_ticket(
        &self,
        db: &PgPool,
        text: &str,
        roster: &[Bot],
        ticket: Option<i64>,
    ) -> Option<TicketTriage> {
        let enabled: Vec<&Bot> = roster.iter().filter(|b| !b.disabled).collect();
        if !self.enabled() || enabled.is_empty() {
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
        let questions = json!({
            "bot": { "type": "choice", "instructions": "Which bot should handle this ticket?", "criteria": criteria },
            "urgency": { "type": "score", "instructions": "How urgent is this ticket?",
                         "criteria": ["whenever", "today", "within the hour", "now"] },
            "act_now": { "type": "noul",
                         "instructions": "Can a bot start on this straight away without checking with the owner? Yes only for work that is easy to undo, like research or drafting." },
        });
        let asked = self.ask(&state, questions).await;
        let a = asked.answers.clone().unwrap_or_default();
        let bot_conf = confidence(&a["bot"]);
        let bot = a["bot"]["choice"]
            .as_str()
            .filter(|_| bot_conf.is_some_and(|c| c >= self.bot_threshold()))
            .and_then(|c| enabled.iter().find(|b| b.slug == c))
            .map(|b| (*b).clone());
        let urgency = most_likely(&a["urgency"])
            .filter(|(_, p)| *p >= self.route_threshold)
            .and_then(|(level, _)| URGENCY.get(level).copied());
        let act_now = a["act_now"]["noul"]
            .as_f64()
            .is_some_and(|p| p >= ACT_NOW_THRESHOLD);
        let triage = TicketTriage {
            bot,
            urgency,
            act_now,
        };
        let outcome = match (&asked.answers, &triage.bot) {
            (None, _) => "Abstained; left for the owner".to_owned(),
            (Some(_), None) => "Not sure which bot; left for the owner".to_owned(),
            (Some(_), Some(bot)) => format!(
                "Assigned to {}{}{}",
                bot.name,
                triage
                    .urgency
                    .map(|u| format!(" · urgency {u}"))
                    .unwrap_or_default(),
                if triage.act_now {
                    " · started"
                } else {
                    " · waiting for the owner to start"
                }
            ),
        };
        let receipt = Receipt {
            catalogue: "triage",
            state: &state,
            threshold: self.bot_threshold(),
            confidence: bot_conf,
            outcome,
            run: None,
            tool_call_id: None,
            ticket,
        };
        record(db, &receipt, &asked).await;
        Some(triage)
    }
}

/// A score answer's most likely level and its probability.
fn most_likely(answer: &Value) -> Option<(usize, f64)> {
    answer["probabilities"]
        .as_object()?
        .iter()
        .filter_map(|(k, v)| Some((k.parse::<usize>().ok()?, v.as_f64()?)))
        .max_by(|a, b| a.1.total_cmp(&b.1))
}

impl System1 {
    /// Capture (DESIGN §10.2): does a hands-free window hold anything worth keeping?
    /// Only a confident no skips extraction; abstaining extracts.
    pub async fn worth_extracting(&self, db: &PgPool, window: &str) -> bool {
        if !self.enabled() {
            return true;
        }
        let state: String = window.chars().take(MAX_STATE_CHARS).collect();
        let questions = json!({ "worth_keeping": {
            "type": "noul",
            "instructions": "Does this conversation contain something the owner should keep: a commitment they made, a task or appointment, something someone owes them, an idea or a thing to remember?",
        }});
        let asked = self.ask(&state, questions).await;
        let yes = asked
            .answers
            .as_ref()
            .and_then(|a| a["worth_keeping"]["noul"].as_f64());
        let skip = yes.is_some_and(|p| p <= 1.0 - self.route_threshold);
        let receipt = Receipt {
            catalogue: "capture",
            state: &state,
            threshold: self.route_threshold,
            confidence: yes.map(|p| 1.0 - p),
            outcome: if skip {
                "Nothing worth keeping"
            } else {
                "Sent for extraction"
            }
            .to_owned(),
            run: None,
            tool_call_id: None,
            ticket: None,
        };
        record(db, &receipt, &asked).await;
        !skip
    }
}

/// The probability of the chosen answer: Laya's `answer_confidence`, or for
/// kev (D-042) the chosen option's entry in `probabilities`. kev's own
/// `confidence` is chance-corrected (2p − 1 for two options), not a
/// probability, so the thresholds can't use it.
fn confidence(answer: &Value) -> Option<f64> {
    answer["answer_confidence"].as_f64().or_else(|| {
        let choice = answer["choice"].as_str()?;
        answer["probabilities"][choice].as_f64()
    })
}

async fn record(db: &PgPool, r: &Receipt<'_>, asked: &Asked) {
    let hash = Sha256::digest(r.state.as_bytes()).to_vec();
    let stored = sqlx::query!(
        "insert into decision (catalogue, state_hash, state, answers, abstained, threshold,
                               confidence, model, latency_ms, outcome, run_id, tool_call_id, ticket_id)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)",
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
        r.tool_call_id,
        r.ticket
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

/// Records what the owner's action says System 1 should have answered (DESIGN §7.5).
async fn label(db: &PgPool, decision: i64, label: Value, agrees: bool, source: &str) {
    let saved = sqlx::query!(
        "insert into decision_label (decision_id, label, agrees, source) values ($1, $2, $3, $4)",
        decision,
        label,
        agrees,
        source
    )
    .execute(db)
    .await;
    if let Err(e) = saved {
        warn!("storing a decision label: {e}");
    }
}

/// The owner answered an approval card System 1 was asked about: allow means
/// it could have passed, deny means it was right to ask.
pub async fn label_gate(db: &PgPool, tool_call_id: &str, allowed: bool) {
    let asked = sqlx::query!(
        r#"select id, answers -> 'verdict' ->> 'choice' as choice from decision
           where catalogue = 'gate' and tool_call_id = $1 order by id desc limit 1"#,
        tool_call_id
    )
    .fetch_optional(db)
    .await;
    if let Ok(Some(d)) = asked {
        let verdict = if allowed { "pass" } else { "ask" };
        let agrees = d.choice.as_deref() == Some(verdict);
        let source = if allowed {
            "approved the card"
        } else {
            "denied the card"
        };
        label(db, d.id, json!({ "verdict": verdict }), agrees, source).await;
    }
}

/// The owner changed the bot on a ticket System 1 triaged: that's the bot it should have picked.
pub async fn label_ticket_bot(db: &PgPool, ticket: i64, bot: Option<&str>) {
    let asked = sqlx::query!(
        r#"select id, answers -> 'bot' ->> 'choice' as choice from decision
           where catalogue = 'triage' and ticket_id = $1 order by id desc limit 1"#,
        ticket
    )
    .fetch_optional(db)
    .await;
    if let Ok(Some(d)) = asked {
        let agrees = d.choice.as_deref() == bot;
        label(
            db,
            d.id,
            json!({ "bot": bot }),
            agrees,
            "changed the ticket's bot",
        )
        .await;
    }
}

/// The owner kept the bot System 1 picked for a ticket (started or finished it
/// with that bot): that's a label saying it was right. Only the first such action counts.
pub async fn label_ticket_kept(db: &PgPool, ticket: i64, source: &str) {
    let asked = sqlx::query!(
        r#"select d.id, d.answers -> 'bot' ->> 'choice' as choice, b.slug as "slug?"
           from decision d join ticket t on t.id = d.ticket_id left join bot b on b.id = t.bot_id
           where d.catalogue = 'triage' and d.ticket_id = $1
             and not exists (select 1 from decision_label l where l.decision_id = d.id and l.label ? 'bot')
           order by d.id desc limit 1"#,
        ticket
    )
    .fetch_optional(db)
    .await;
    if let Ok(Some(d)) = asked
        && d.slug.is_some()
        && d.choice == d.slug
    {
        label(db, d.id, json!({ "bot": d.slug }), true, source).await;
    }
}

/// The owner changed a triaged ticket's urgency: that's the level it should have picked.
pub async fn label_ticket_urgency(db: &PgPool, ticket: i64, urgency: &str) {
    let asked = sqlx::query!(
        r#"select id, answers -> 'urgency' as urgency from decision
           where catalogue = 'triage' and ticket_id = $1 order by id desc limit 1"#,
        ticket
    )
    .fetch_optional(db)
    .await;
    if let Ok(Some(d)) = asked {
        let picked = d
            .urgency
            .as_ref()
            .and_then(most_likely)
            .and_then(|(level, _)| URGENCY.get(level).copied());
        let agrees = picked == Some(urgency);
        label(
            db,
            d.id,
            json!({ "urgency": urgency }),
            agrees,
            "changed the ticket's urgency",
        )
        .await;
    }
}

/// Per catalogue: how often System 1 was asked, abstained, was labelled and agreed.
pub async fn health(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select d.catalogue, count(*) as "asked!", count(*) filter (where d.abstained) as "abstained!",
                  count(l.id) as "labelled!", count(l.id) filter (where l.agrees) as "agreed!",
                  avg(d.latency_ms)::float8 as latency
           from decision d left join decision_label l on l.decision_id = d.id
           group by d.catalogue order by d.catalogue"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("summarising decisions", e))?;
    let list: Vec<Value> = rows
        .into_iter()
        .map(|r| {
            json!({
                "catalogue": r.catalogue, "asked": r.asked, "abstained": r.abstained,
                "labelled": r.labelled, "agreed": r.agreed, "latency_ms": r.latency,
            })
        })
        .collect();
    Ok(Json(json!(list)))
}

/// Recent receipts, newest first, for the Decisions view.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        r#"select d.id, d.catalogue, d.state, d.abstained, d.threshold, d.confidence, d.model, d.latency_ms,
                  d.outcome, d.created_at::text as "created_at!",
                  l.label as "label?", l.agrees as "agrees?", l.source as "label_source?"
           from decision d left join lateral (select label, agrees, source from decision_label
                                              where decision_id = d.id order by id desc limit 1) l on true
           order by d.id desc limit 100"#
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
                "label": r.label, "agrees": r.agrees, "label_source": r.label_source,
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
            fitted: RwLock::default(),
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
            computer: "node".into(),
            google: "read".into(),
            face: None,
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
    async fn ticket_triage_assigns_but_starts_only_when_told_its_safe(db: PgPool) {
        let roster = [bot("inbox", false), bot("researcher", false)];
        let laya = fake_laya("bot", "researcher", 0.9).await;
        let t = laya
            .triage_ticket(&db, "compare e-bike batteries", &roster, None)
            .await
            .unwrap();
        assert_eq!(t.bot.map(|b| b.slug), Some("researcher".to_owned()));
        // This fake gives no urgency or act-now answer: those stay unset, and nothing starts.
        assert_eq!((t.urgency, t.act_now), (None, false));
        assert!(
            System1::off()
                .triage_ticket(&db, "x", &roster, None)
                .await
                .is_none()
        );
        assert_eq!(
            most_likely(&json!({ "probabilities": { "0": 0.1, "1": 0.7, "2": 0.2 } })),
            Some((1, 0.7))
        );
    }

    #[sqlx::test]
    async fn owner_actions_label_decisions(db: PgPool) {
        let decision = |catalogue: &str,
                        answers: Value,
                        tool: Option<&str>,
                        ticket: Option<i64>| {
            let (catalogue, tool) = (catalogue.to_owned(), tool.map(str::to_owned));
            let db = db.clone();
            async move {
                sqlx::query!(
                    "insert into decision (catalogue, state_hash, answers, abstained, threshold, latency_ms, outcome,
                                           tool_call_id, ticket_id)
                     values ($1, $2, $3, false, 0.9, 5, 'x', $4, $5)",
                    catalogue, vec![0u8; 32], answers, tool, ticket
                )
                .execute(&db)
                .await
                .unwrap();
            }
        };
        let ticket: i64 =
            sqlx::query_scalar!("insert into ticket (title) values ('t') returning id")
                .fetch_one(&db)
                .await
                .unwrap();
        decision(
            "gate",
            json!({ "verdict": { "choice": "ask" } }),
            Some("c1"),
            None,
        )
        .await;
        decision(
            "triage",
            json!({ "bot": { "choice": "researcher" } }),
            None,
            Some(ticket),
        )
        .await;

        // System 1 said ask; the owner allowed it: it could have passed.
        label_gate(&db, "c1", true).await;
        // System 1 picked researcher; the owner kept that bot after editing it away and back.
        label_ticket_bot(&db, ticket, Some("researcher")).await;
        label_gate(&db, "no-such-call", false).await;

        let labels: Vec<(Value, bool, String)> =
            sqlx::query!("select label, agrees, source from decision_label order by id")
                .fetch_all(&db)
                .await
                .unwrap()
                .into_iter()
                .map(|r| (r.label, r.agrees, r.source))
                .collect();
        assert_eq!(
            labels,
            [
                (
                    json!({ "verdict": "pass" }),
                    false,
                    "approved the card".to_owned()
                ),
                (
                    json!({ "bot": "researcher" }),
                    true,
                    "changed the ticket's bot".to_owned()
                ),
            ]
        );
    }

    #[sqlx::test]
    async fn keeping_the_bot_and_changing_urgency_label_triage(db: PgPool) {
        let ticket: i64 = sqlx::query_scalar!(
            "insert into ticket (title, bot_id) values ('t', (select id from bot where slug = 'inbox')) returning id"
        )
        .fetch_one(&db)
        .await
        .unwrap();
        let answers = json!({
            "bot": { "choice": "inbox" },
            "urgency": { "probabilities": { "0": 0.1, "1": 0.8, "2": 0.1 } },
        });
        sqlx::query!(
            "insert into decision (catalogue, state_hash, answers, abstained, threshold, latency_ms, outcome, ticket_id)
             values ('triage', $1, $2, false, 0.85, 5, 'x', $3)",
            vec![0u8; 32],
            answers,
            ticket
        )
        .execute(&db)
        .await
        .unwrap();

        label_ticket_kept(&db, ticket, "started the ticket with its bot").await;
        // Only the first keep counts.
        label_ticket_kept(&db, ticket, "finished the ticket with its bot").await;
        label_ticket_urgency(&db, ticket, "now").await;
        label_ticket_urgency(&db, ticket, "today").await;

        let labels: Vec<(Value, bool)> =
            sqlx::query!("select label, agrees from decision_label order by id")
                .fetch_all(&db)
                .await
                .unwrap()
                .into_iter()
                .map(|r| (r.label, r.agrees))
                .collect();
        assert_eq!(
            labels,
            [
                (json!({ "bot": "inbox" }), true),
                (json!({ "urgency": "now" }), false),
                (json!({ "urgency": "today" }), true),
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
            fitted: RwLock::default(),
        };
        let roster = [bot("inbox", false), bot("researcher", false)];
        assert!(gone.route(&db, "look this up", &roster).await.is_none());
        let abstained: bool = sqlx::query_scalar!("select abstained from decision")
            .fetch_one(&db)
            .await
            .unwrap();
        assert!(abstained);
    }

    #[test]
    fn confidence_reads_laya_and_kev() {
        let laya = json!({ "choice": "pass", "answer_confidence": 0.97 });
        assert_eq!(confidence(&laya), Some(0.97));
        // kev: chance-corrected `confidence` is ignored for the option's probability.
        let kev = json!({ "type": "choice", "choice": "pass", "confidence": 0.94,
                          "probabilities": { "pass": 0.97, "ask": 0.03 } });
        assert_eq!(confidence(&kev), Some(0.97));
        assert_eq!(confidence(&json!({ "choice": "pass" })), None);
    }
}
