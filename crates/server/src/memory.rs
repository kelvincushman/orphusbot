//! What OrphusBot learns about the owner from what he says (DESIGN §11.9, D-066).
//!
//! Every message the owner sends a bot is noted (`heard`). A background loop
//! reads what is new, asks a local model for the facts in it, and files each
//! as one sentence with the messages it came from. The embedding model only
//! finds facts that might be the same; the model decides whether a new one
//! repeats an old one, replaces it, or is new, because embeddings score
//! opposites ("after 11" and "before 11") as near-identical.
//!
//! Off unless `ORPHUSBOT_MEMORY_LLM_URL` and `ORPHUSBOT_MEMORY_EMBED_URL` are set.

use std::collections::HashMap;
use std::time::Duration;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::warn;

use crate::{ApiError, App, Shared, internal};

/// Messages read in one go, from one thread.
const BATCH: i64 = 20;
/// A thread is read once the owner has been quiet in it this long, so one
/// exchange is learned together.
const SETTLE_SECS: f64 = 60.0;
/// After this many failed reads a message is skipped, so one bad message
/// can't hold up everything behind it.
const MAX_ATTEMPTS: i16 = 5;
/// How alike two facts' embeddings must be before the model is asked whether
/// they are the same. Measured on EmbeddingGemma: rewordings score about 0.90,
/// unrelated facts about 0.75.
const ALIKE: f32 = 0.85;
/// The nearest existing facts shown to the model for each new one.
const NEIGHBOURS: usize = 4;
const FACT_CHARS: usize = 400;
/// The bot's previous reply, given as context for answers like "yes, the first one".
const CONTEXT_CHARS: usize = 600;

/// The model answered, but with something that can't be used for these
/// messages. Only this counts against them: a server or database that is down
/// says nothing about the messages, which then simply wait.
#[derive(Debug)]
struct Unusable(String);

impl std::fmt::Display for Unusable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the model's reply can't be used: {}", self.0)
    }
}

impl std::error::Error for Unusable {}

pub struct Memory {
    http: reqwest::Client,
    /// An OpenAI-compatible server, up to and including `/v1`.
    llm_url: Option<String>,
    llm_model: String,
    embed_url: Option<String>,
    embed_model: String,
    /// The model name for embedding a search, where the server has one.
    query_model: String,
    /// What facts call the owner.
    owner: String,
}

impl Memory {
    /// `ORPHUSBOT_MEMORY_LLM_URL` and `ORPHUSBOT_MEMORY_EMBED_URL` turn it on.
    /// Optional: `ORPHUSBOT_MEMORY_LLM_MODEL`, `ORPHUSBOT_MEMORY_EMBED_MODEL`,
    /// `ORPHUSBOT_MEMORY_EMBED_QUERY_MODEL`, `ORPHUSBOT_OWNER_NAME`.
    pub fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        let url = |name: &str| var(name).map(|u| u.trim_end_matches('/').to_owned());
        let embed_model = var("ORPHUSBOT_MEMORY_EMBED_MODEL").unwrap_or_else(|| "default".into());
        Self {
            http: reqwest::Client::new(),
            llm_url: url("ORPHUSBOT_MEMORY_LLM_URL"),
            llm_model: var("ORPHUSBOT_MEMORY_LLM_MODEL").unwrap_or_else(|| "default".into()),
            embed_url: url("ORPHUSBOT_MEMORY_EMBED_URL"),
            query_model: var("ORPHUSBOT_MEMORY_EMBED_QUERY_MODEL")
                .unwrap_or_else(|| embed_model.clone()),
            embed_model,
            owner: var("ORPHUSBOT_OWNER_NAME").unwrap_or_else(|| "Kelvin".into()),
        }
    }

    #[cfg(test)]
    pub fn off() -> Self {
        Self {
            http: reqwest::Client::new(),
            llm_url: None,
            llm_model: "test".into(),
            embed_url: None,
            embed_model: "test".into(),
            query_model: "test".into(),
            owner: "Sam".into(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.llm_url.is_some() && self.embed_url.is_some()
    }

    /// One call to the model that must answer with JSON matching `schema`.
    async fn ask(
        &self,
        system: &str,
        user: &str,
        name: &str,
        schema: Value,
    ) -> anyhow::Result<Value> {
        let url = self.llm_url.as_deref().unwrap_or_default();
        let res = self
            .http
            .post(format!("{url}/chat/completions"))
            .json(&json!({
                "model": self.llm_model,
                "temperature": 0,
                "max_tokens": 2000,
                // Qwen spends the whole reply thinking otherwise; other servers ignore it.
                "chat_template_kwargs": { "enable_thinking": false },
                "messages": [
                    { "role": "system", "content": system },
                    { "role": "user", "content": user },
                ],
                "response_format": {
                    "type": "json_schema",
                    "json_schema": { "name": name, "strict": true, "schema": schema },
                },
            }))
            .timeout(Duration::from_secs(180))
            .send()
            .await?;
        // A refusal of this request (too long, say) won't change on a retry;
        // a busy or broken server will.
        let status = res.status();
        if status.is_client_error() && status.as_u16() != 408 && status.as_u16() != 429 {
            return Err(Unusable(format!("the model server answered {status}")).into());
        }
        let body: Value = res.error_for_status()?.json().await?;
        let content = body["choices"][0]["message"]["content"]
            .as_str()
            .ok_or_else(|| Unusable("no text in it".into()))?;
        serde_json::from_str(content).map_err(|e| Unusable(e.to_string()).into())
    }

    async fn embed(&self, texts: &[String], query: bool) -> anyhow::Result<Vec<Vec<f32>>> {
        let url = self.embed_url.as_deref().unwrap_or_default();
        let model = if query {
            &self.query_model
        } else {
            &self.embed_model
        };
        let res = self
            .http
            .post(format!("{url}/embeddings"))
            .json(&json!({ "model": model, "input": texts }))
            .timeout(Duration::from_secs(60))
            .send()
            .await?
            .error_for_status()?;
        #[derive(Deserialize)]
        struct Out {
            data: Vec<One>,
        }
        #[derive(Deserialize)]
        struct One {
            embedding: Vec<f32>,
        }
        let out: Out = res.json().await?;
        anyhow::ensure!(
            out.data.len() == texts.len() && out.data.iter().all(|d| !d.embedding.is_empty()),
            "the embedding server sent {} vectors for {} texts",
            out.data.len(),
            texts.len()
        );
        Ok(out.data.into_iter().map(|d| d.embedding).collect())
    }
}

/// The owner said `text` to the bot in `thread`. Cheap: the reading happens later.
pub async fn heard(app: &App, thread: i64, text: &str) {
    let text: String = text.trim().chars().take(8000).collect();
    if !app.memory.enabled() || text.is_empty() {
        return;
    }
    if let Err(e) = sqlx::query!(
        "insert into memory_heard (thread_id, text) values ($1, $2)",
        thread,
        text
    )
    .execute(&app.db)
    .await
    {
        warn!("noting a message for memory: {e}");
    }
}

pub async fn learn_forever(app: Shared) {
    if !app.memory.enabled() {
        return;
    }
    loop {
        match learn_due(&app.memory, &app.db).await {
            // More may be waiting: go straight round.
            Ok(true) => continue,
            Ok(false) => {}
            Err(e) => warn!("learning from messages: {e:#}"),
        }
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}

struct Heard {
    id: i64,
    text: String,
    heard_at: DateTime<Utc>,
}

/// A fact the model found, with the messages it rests on.
struct Found {
    text: String,
    sources: Vec<i64>,
}

/// Reads one thread's waiting messages. True if it read any.
async fn learn_due(memory: &Memory, db: &PgPool) -> anyhow::Result<bool> {
    let Some(thread) = sqlx::query_scalar!(
        r#"select thread_id from memory_heard where learned_at is null
           group by thread_id
           having max(heard_at) < now() - make_interval(secs => $1) or count(*) >= $2
           order by min(id) limit 1"#,
        SETTLE_SECS,
        BATCH
    )
    .fetch_optional(db)
    .await?
    else {
        return Ok(false);
    };
    let batch = sqlx::query_as!(
        Heard,
        "select id, text, heard_at from memory_heard
         where thread_id = $1 and learned_at is null order by id limit $2",
        thread,
        BATCH
    )
    .fetch_all(db)
    .await?;
    let ids: Vec<i64> = batch.iter().map(|h| h.id).collect();

    // Every model call first, then one transaction: a batch is filed whole or
    // not at all, so a retry can't count anything twice.
    let plan = match plan(memory, db, thread, &batch).await {
        Ok(plan) => plan,
        Err(e) => {
            // A server or database that is down or slow says nothing about
            // these messages: they wait, however long. Only a reply that
            // can't be used counts against them.
            if e.chain().any(|c| c.is::<Unusable>()) {
                sqlx::query!(
                    "update memory_heard set attempts = attempts + 1,
                            learned_at = case when attempts + 1 >= $2 then now() end
                     where id = any($1)",
                    &ids,
                    i32::from(MAX_ATTEMPTS)
                )
                .execute(db)
                .await?;
            }
            return Err(e);
        }
    };
    file(db, plan, &ids).await?;
    Ok(true)
}

/// Writes a batch's facts and marks its messages read, in one transaction.
async fn file(
    db: &PgPool,
    plan: Vec<(Found, Vec<f32>, Verdict)>,
    heard: &[i64],
) -> sqlx::Result<()> {
    let mut tx = db.begin().await?;
    for (fact, vector, verdict) in plan {
        // The model was asked outside this transaction. If the fact it
        // compared with was forgotten (or replaced) meanwhile, this one is
        // dropped: filing it would bring a forgotten fact back with no new
        // message from the owner.
        if let Verdict::Same(target) | Verdict::Replaces(target) = verdict {
            let still = sqlx::query_scalar!(
                "select id from memory_fact where id = $1 and replaced_by is null for update",
                target
            )
            .fetch_optional(&mut *tx)
            .await?;
            if still.is_none() {
                continue;
            }
        }
        let id = match verdict {
            Verdict::Same(id) => {
                sqlx::query!(
                    "update memory_fact set times_seen = times_seen + 1, last_seen_at = now() where id = $1",
                    id
                )
                .execute(&mut *tx)
                .await?;
                id
            }
            Verdict::New | Verdict::Replaces(_) => {
                let id = sqlx::query_scalar!(
                    "insert into memory_fact (text, embedding) values ($1, $2) returning id",
                    fact.text,
                    &vector
                )
                .fetch_one(&mut *tx)
                .await?;
                if let Verdict::Replaces(old) = verdict {
                    sqlx::query!(
                        "update memory_fact set replaced_by = $1 where id = $2",
                        id,
                        old
                    )
                    .execute(&mut *tx)
                    .await?;
                }
                id
            }
        };
        sqlx::query!(
            "insert into memory_fact_source (fact_id, heard_id)
             select $1, unnest($2::bigint[]) on conflict do nothing",
            id,
            &fact.sources
        )
        .execute(&mut *tx)
        .await?;
    }
    sqlx::query!(
        "update memory_heard set learned_at = now() where id = any($1)",
        heard
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await
}

/// Works out what a batch adds to memory, without writing anything.
async fn plan(
    memory: &Memory,
    db: &PgPool,
    thread: i64,
    batch: &[Heard],
) -> anyhow::Result<Vec<(Found, Vec<f32>, Verdict)>> {
    let tz = crate::profiles::current(db).await.tz;
    // Numbered lines for the model; `owner_line[n]` is the message line n came from.
    let mut lines = String::new();
    let mut owner_line: HashMap<i64, i64> = HashMap::new();
    let mut n = 0;
    for h in batch {
        let before = sqlx::query_scalar!(
            // Only replies from since the bot became a team bot: one that was
            // private keeps its thread, and those replies stay out.
            r#"select e.body->>'text' from event e
               join thread t on t.id = e.thread_id join bot b on b.id = t.bot_id
               where e.thread_id = $1 and e.created_at < $2 and e.created_at > b.team_since
                 and e.body->>'type' = 'message' and e.body->>'role' = 'assistant'
               order by e.seq desc limit 1"#,
            thread,
            h.heard_at
        )
        .fetch_optional(db)
        .await?
        .flatten();
        if let Some(reply) = before {
            n += 1;
            let reply: String = reply.chars().take(CONTEXT_CHARS).collect();
            lines.push_str(&format!("[{n}] the bot (context only): {reply}\n"));
        }
        n += 1;
        owner_line.insert(n, h.id);
        let when = h.heard_at.with_timezone(&tz).format("%A %-d %B %Y, %H:%M");
        lines.push_str(&format!("[{n}] {} ({when}): {}\n", memory.owner, h.text));
    }

    let found = extract(memory, &lines, &owner_line).await?;
    if found.is_empty() {
        return Ok(Vec::new());
    }
    let texts: Vec<String> = found.iter().map(|f| f.text.clone()).collect();
    let vectors = memory.embed(&texts, false).await?;

    // Only facts from before this batch: what was said together is one picture,
    // and its facts neither repeat nor replace each other.
    // ponytail: every current fact is loaded and compared here; fine to tens of
    // thousands of facts, then pgvector with an index.
    let known: Vec<(i64, String, Vec<f32>)> =
        sqlx::query!("select id, text, embedding from memory_fact where replaced_by is null")
            .fetch_all(db)
            .await?
            .into_iter()
            .map(|r| (r.id, r.text, r.embedding))
            .collect();

    let mut plan = Vec::new();
    for (fact, vector) in found.into_iter().zip(vectors) {
        let mut near: Vec<(f32, i64, &str)> = known
            .iter()
            .map(|(id, text, v)| (cosine(&vector, v), *id, text.as_str()))
            .filter(|(score, ..)| *score >= ALIKE)
            .collect();
        near.sort_by(|a, b| b.0.total_cmp(&a.0));
        near.truncate(NEIGHBOURS);
        let verdict = if near.is_empty() {
            Verdict::New
        } else {
            settle(memory, &fact.text, &near).await?
        };
        plan.push((fact, vector, verdict));
    }
    Ok(plan)
}

/// Asks the model for the facts in `lines`. A fact is kept only if it cites
/// at least one of the owner's own messages.
async fn extract(
    memory: &Memory,
    lines: &str,
    owner_line: &HashMap<i64, i64>,
) -> anyhow::Result<Vec<Found>> {
    let owner = &memory.owner;
    let system = format!(
        "You keep a record of lasting facts about {owner}, taken from what {owner} writes to their assistant bots.\n\
         Below are numbered lines. Lines from {owner} are evidence. Lines marked \"context only\" are a bot's earlier reply: \
         use them to understand a short answer such as \"yes\" or \"the second one\", and never as evidence by themselves.\n\
         List what a helpful assistant should still know next month: preferences, habits, people, places, projects, plans, \
         decisions, dates, tools, and how {owner} likes things done.\n\
         Leave out: one-off instructions for the task in hand, greetings and thanks, questions, and anything a bot said that {owner} didn't confirm.\n\
         Write each fact as one plain sentence that starts with \"{owner}\" and makes sense with nothing else to read: \
         name people and things in full, and turn \"tomorrow\" or \"next week\" into the actual date using the time on the line.\n\
         One fact per sentence. Don't say the same thing twice. If there is nothing worth keeping, return an empty list.\n\
         For each fact give the numbers of the lines from {owner} that it comes from."
    );
    let schema = json!({
        "type": "object",
        "properties": { "facts": { "type": "array", "items": {
            "type": "object",
            "properties": {
                "text": { "type": "string" },
                "sources": { "type": "array", "items": { "type": "integer" } },
            },
            "required": ["text", "sources"],
            "additionalProperties": false,
        } } },
        "required": ["facts"],
        "additionalProperties": false,
    });
    #[derive(Deserialize)]
    struct Out {
        facts: Vec<Raw>,
    }
    #[derive(Deserialize)]
    struct Raw {
        text: String,
        sources: Vec<i64>,
    }
    let out: Out = serde_json::from_value(memory.ask(&system, lines, "facts", schema).await?)
        .map_err(|e| Unusable(e.to_string()))?;
    Ok(out
        .facts
        .into_iter()
        .take(BATCH as usize * 3)
        .filter_map(|raw| {
            let text: String = raw.text.trim().chars().take(FACT_CHARS).collect();
            let mut sources: Vec<i64> = raw
                .sources
                .iter()
                .filter_map(|n| owner_line.get(n).copied())
                .collect();
            sources.sort_unstable();
            sources.dedup();
            (!text.is_empty() && !sources.is_empty()).then_some(Found { text, sources })
        })
        .collect())
}

#[derive(Debug, PartialEq)]
enum Verdict {
    New,
    /// Says the same as this fact.
    Same(i64),
    /// This fact is no longer true; the new one takes its place.
    Replaces(i64),
}

/// Asks the model how a new fact relates to the existing ones nearest to it.
async fn settle(memory: &Memory, fact: &str, near: &[(f32, i64, &str)]) -> anyhow::Result<Verdict> {
    let system = "You keep a record of facts about a person. Compare the NEW fact with each numbered EXISTING fact.\n\
        - \"same\": an existing fact already covers this, even in other words, or more broadly or more narrowly. Give its number.\n\
        - \"replaces\": an existing fact has stopped being true because of the new one: a plan was cancelled or reversed, \
        a choice was changed, or it was corrected. Give its number.\n\
        - \"new\": anything else, including a related fact about the same person, event or thing that adds to it. Give 0.\n\
        If both can be true at once, it is never \"replaces\".\n\
        Read carefully: \"before\" and \"after\", or \"from A to B\" and \"from B to A\", are opposites, not the same.";
    let mut user = format!("NEW: {fact}\n\nEXISTING:\n");
    for (n, (_, _, text)) in near.iter().enumerate() {
        user.push_str(&format!("{}. {text}\n", n + 1));
    }
    let schema = json!({
        "type": "object",
        "properties": {
            "relation": { "type": "string", "enum": ["same", "replaces", "new"] },
            "number": { "type": "integer" },
        },
        "required": ["relation", "number"],
        "additionalProperties": false,
    });
    let out = memory.ask(system, &user, "relation", schema).await?;
    let id = out["number"]
        .as_u64()
        .and_then(|n| near.get((n as usize).checked_sub(1)?))
        .map(|(_, id, _)| *id);
    Ok(match (out["relation"].as_str(), id) {
        (Some("same"), Some(id)) => Verdict::Same(id),
        (Some("replaces"), Some(id)) => Verdict::Replaces(id),
        // An answer that names no existing fact adds one: nothing is lost.
        _ => Verdict::New,
    })
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    let (mut dot, mut aa, mut bb) = (0.0f32, 0.0f32, 0.0f32);
    for (x, y) in a.iter().zip(b) {
        dot += x * y;
        aa += x * x;
        bb += y * y;
    }
    if aa == 0.0 || bb == 0.0 {
        0.0
    } else {
        dot / (aa.sqrt() * bb.sqrt())
    }
}

#[derive(Deserialize)]
pub struct Search {
    #[serde(default)]
    q: String,
}

/// `GET /api/memory?q=`: what has been learned, newest first, or the facts
/// nearest a search. Each comes with the messages it rests on.
pub async fn list(
    State(app): State<Shared>,
    Query(s): Query<Search>,
) -> Result<Json<Value>, ApiError> {
    let err = |e| internal("reading memory", e);
    let q = s.q.trim();
    let ids: Vec<i64> = if q.is_empty() || !app.memory.enabled() {
        sqlx::query_scalar!(
            "select id from memory_fact where replaced_by is null order by last_seen_at desc, id desc limit 200"
        )
        .fetch_all(&app.db)
        .await
        .map_err(err)?
    } else {
        let query: String = q.chars().take(500).collect();
        let vector = app
            .memory
            .embed(&[query], true)
            .await
            .map_err(|e| {
                warn!("embedding a memory search: {e:#}");
                (StatusCode::BAD_GATEWAY, "Memory's search isn't answering")
            })?
            .remove(0);
        let mut scored: Vec<(f32, i64)> =
            sqlx::query!("select id, embedding from memory_fact where replaced_by is null")
                .fetch_all(&app.db)
                .await
                .map_err(err)?
                .into_iter()
                .map(|r| (cosine(&vector, &r.embedding), r.id))
                .collect();
        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        scored.into_iter().take(30).map(|(_, id)| id).collect()
    };

    let facts = sqlx::query!(
        "select id, text, times_seen, created_at, last_seen_at from memory_fact where id = any($1)",
        &ids
    )
    .fetch_all(&app.db)
    .await
    .map_err(err)?;
    let sources = sqlx::query!(
        "select s.fact_id, h.text, h.heard_at, b.name as bot
         from memory_fact_source s
         join memory_heard h on h.id = s.heard_id
         join thread t on t.id = h.thread_id join bot b on b.id = t.bot_id
         where s.fact_id = any($1) order by h.id",
        &ids
    )
    .fetch_all(&app.db)
    .await
    .map_err(err)?;
    let mut by_fact: HashMap<i64, Vec<Value>> = HashMap::new();
    for s in sources {
        by_fact.entry(s.fact_id).or_default().push(json!({
            "text": s.text, "heard_at": s.heard_at.to_rfc3339(), "bot": s.bot,
        }));
    }
    let mut by_id: HashMap<i64, Value> = facts
        .into_iter()
        .map(|f| {
            (
                f.id,
                json!({
                    "id": f.id, "text": f.text, "times_seen": f.times_seen,
                    "created_at": f.created_at.to_rfc3339(),
                    "last_seen_at": f.last_seen_at.to_rfc3339(),
                    "sources": by_fact.remove(&f.id).unwrap_or_default(),
                }),
            )
        })
        .collect();
    // In the order chosen above (newest first, or nearest first).
    let facts: Vec<Value> = ids.iter().filter_map(|id| by_id.remove(id)).collect();
    Ok(Json(
        json!({ "enabled": app.memory.enabled(), "facts": facts }),
    ))
}

/// `DELETE /api/memory/{id}`: forget a fact. The messages it came from stay in
/// their threads; it would only come back if the owner said it again.
pub async fn forget(
    State(app): State<Shared>,
    Path(id): Path<i64>,
) -> Result<StatusCode, ApiError> {
    // With the facts it replaced: forgetting the newest mustn't bring an
    // older version back as current.
    let gone = sqlx::query!(
        "with recursive gone as (
             select id from memory_fact where id = $1
             union all
             select f.id from memory_fact f join gone g on f.replaced_by = g.id
         )
         delete from memory_fact where id in (select id from gone)",
        id
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("forgetting a fact", e))?
    .rows_affected();
    if gone == 0 {
        return Err((StatusCode::NOT_FOUND, "No such fact"));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::routing::post;
    use std::sync::{Arc, Mutex};

    /// A stand-in for the model and embedding servers. The model answers each
    /// call with the next scripted reply; an embedding is `[1, 0]` for a text
    /// about mornings or appointments and `[0, 1]` for anything else.
    async fn fake(replies: Vec<Value>) -> (Memory, Arc<Mutex<Vec<String>>>) {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let replies = Arc::new(Mutex::new(replies.into_iter()));
        let a = asked.clone();
        let app = axum::Router::new()
            .route(
                "/chat/completions",
                post(move |Json(body): Json<Value>| async move {
                    a.lock()
                        .unwrap()
                        .push(body["messages"][1]["content"].as_str().unwrap().to_owned());
                    let reply = replies
                        .lock()
                        .unwrap()
                        .next()
                        .expect("an unscripted model call");
                    Json(json!({ "choices": [{ "message": { "content": reply.to_string() } }] }))
                }),
            )
            .route(
                "/embeddings",
                post(|Json(body): Json<Value>| async move {
                    let data: Vec<Value> = body["input"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|t| {
                            let t = t.as_str().unwrap();
                            let v = if t.contains("appointment") {
                                [1.0, 0.0]
                            } else {
                                [0.0, 1.0]
                            };
                            json!({ "embedding": v })
                        })
                        .collect();
                    Json(json!({ "data": data }))
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let memory = Memory {
            llm_url: Some(url.clone()),
            embed_url: Some(url),
            ..Memory::off()
        };
        (memory, asked)
    }

    async fn say(db: &PgPool, text: &str) -> i64 {
        // Old enough to count as settled.
        sqlx::query_scalar!(
            "insert into memory_heard (thread_id, text, heard_at) values (1, $1, now() - interval '5 minutes') returning id",
            text
        )
        .fetch_one(db)
        .await
        .unwrap()
    }

    async fn current(db: &PgPool) -> Vec<(String, i32)> {
        sqlx::query!(
            "select text, times_seen from memory_fact where replaced_by is null order by id"
        )
        .fetch_all(db)
        .await
        .unwrap()
        .into_iter()
        .map(|r| (r.text, r.times_seen))
        .collect()
    }

    fn facts(list: &[(&str, &[i64])]) -> Value {
        json!({ "facts": list.iter().map(|(t, s)| json!({ "text": t, "sources": s })).collect::<Vec<_>>() })
    }

    #[test]
    fn cosine_is_safe_on_odd_input() {
        assert_eq!(cosine(&[1.0, 0.0], &[1.0, 0.0]), 1.0);
        assert_eq!(cosine(&[1.0, 0.0], &[0.0, 1.0]), 0.0);
        assert_eq!(cosine(&[1.0], &[1.0, 0.0]), 0.0);
        assert_eq!(cosine(&[0.0, 0.0], &[1.0, 0.0]), 0.0);
    }

    #[sqlx::test]
    async fn learns_facts_with_their_sources(db: PgPool) {
        let (memory, asked) = fake(vec![facts(&[
            ("Sam prefers appointments after 11:00.", &[1]),
            ("Sam is moving the shop to Shopify in January 2027.", &[2]),
            // Cites nothing the owner said: dropped.
            ("Sam likes tea.", &[9]),
        ])])
        .await;
        let first = say(
            &db,
            "move my dentist, I hate early appointments so after 11",
        )
        .await;
        say(&db, "also the shop goes to shopify in january").await;

        assert!(learn_due(&memory, &db).await.unwrap());
        assert!(
            !learn_due(&memory, &db).await.unwrap(),
            "nothing left to read"
        );

        assert_eq!(
            current(&db).await,
            [
                ("Sam prefers appointments after 11:00.".to_owned(), 1),
                (
                    "Sam is moving the shop to Shopify in January 2027.".to_owned(),
                    1
                ),
            ]
        );
        let source = sqlx::query_scalar!(
            "select heard_id from memory_fact_source s join memory_fact f on f.id = s.fact_id where f.text like '%appointments%'"
        )
        .fetch_all(&db)
        .await
        .unwrap();
        assert_eq!(source, [first]);
        let prompt = asked.lock().unwrap()[0].clone();
        assert!(prompt.contains("[1] Sam ("), "{prompt}");
        assert!(prompt.contains("[2] Sam ("), "{prompt}");
    }

    #[sqlx::test]
    async fn a_repeat_is_counted_and_a_change_replaces(db: PgPool) {
        let (memory, _) = fake(vec![
            facts(&[("Sam prefers appointments after 11:00.", &[1])]),
            // Said again in other words: the model is asked, and says "same".
            facts(&[("Sam wants appointments later than 11:00.", &[1])]),
            json!({ "relation": "same", "number": 1 }),
            // He changed his mind.
            facts(&[("Sam prefers appointments before 11:00.", &[1])]),
            json!({ "relation": "replaces", "number": 1 }),
        ])
        .await;

        say(&db, "appointments after 11 please").await;
        learn_due(&memory, &db).await.unwrap();
        say(&db, "as I said, later than 11").await;
        learn_due(&memory, &db).await.unwrap();
        assert_eq!(
            current(&db).await,
            [("Sam prefers appointments after 11:00.".to_owned(), 2)]
        );
        let sources = sqlx::query_scalar!("select count(*) from memory_fact_source")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(sources, Some(2), "both messages back the one fact");

        say(&db, "actually mornings are better now, before 11").await;
        learn_due(&memory, &db).await.unwrap();
        assert_eq!(
            current(&db).await,
            [("Sam prefers appointments before 11:00.".to_owned(), 1)]
        );
        let kept = sqlx::query_scalar!("select count(*) from memory_fact")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(kept, Some(2), "the old fact is kept as history");
    }

    #[sqlx::test]
    async fn a_failing_message_is_retried_then_skipped(db: PgPool) {
        // The model's reply isn't the JSON asked for.
        let (memory, _) = fake(vec![json!("nonsense"); MAX_ATTEMPTS as usize]).await;
        say(&db, "something").await;
        for _ in 0..MAX_ATTEMPTS {
            assert!(learn_due(&memory, &db).await.is_err());
        }
        assert!(
            !learn_due(&memory, &db).await.unwrap(),
            "it has been given up on"
        );
        assert!(current(&db).await.is_empty());
    }

    #[sqlx::test]
    async fn an_outage_never_uses_up_a_messages_tries(db: PgPool) {
        // Nothing listens here, so every call fails to connect.
        let memory = Memory {
            llm_url: Some("http://127.0.0.1:1".into()),
            embed_url: Some("http://127.0.0.1:1".into()),
            ..Memory::off()
        };
        say(&db, "something").await;
        for _ in 0..MAX_ATTEMPTS + 2 {
            assert!(learn_due(&memory, &db).await.is_err());
        }
        let waiting = sqlx::query_scalar!(
            "select count(*) from memory_heard where learned_at is null and attempts = 0"
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(
            waiting,
            Some(1),
            "it still waits for the servers to come back"
        );
    }

    #[sqlx::test]
    async fn a_batch_that_fails_part_way_files_nothing(db: PgPool) {
        let (memory, _) = fake(vec![
            facts(&[("Sam prefers appointments after 11:00.", &[1])]),
            // The first fact is new; the second needs the model again, and
            // that call fails (nothing is scripted for it).
            facts(&[
                ("Sam drinks tea.", &[1]),
                ("Sam wants appointments later than 11:00.", &[1]),
            ]),
        ])
        .await;
        say(&db, "appointments after 11 please").await;
        learn_due(&memory, &db).await.unwrap();
        say(&db, "tea, and later than 11 as I said").await;
        assert!(learn_due(&memory, &db).await.is_err());
        assert_eq!(
            current(&db).await,
            [("Sam prefers appointments after 11:00.".to_owned(), 1)],
            "the tea fact waits for the whole batch"
        );
    }

    #[sqlx::test]
    async fn a_fact_forgotten_while_a_batch_is_read_does_not_come_back(db: PgPool) {
        let (memory, _) = fake(vec![
            facts(&[("Sam prefers appointments after 11:00.", &[1])]),
            facts(&[("Sam prefers appointments before 11:00.", &[1])]),
            json!({ "relation": "replaces", "number": 1 }),
        ])
        .await;
        say(&db, "appointments after 11 please").await;
        learn_due(&memory, &db).await.unwrap();
        let heard = say(&db, "actually before 11").await;
        let batch = [Heard {
            id: heard,
            text: "actually before 11".into(),
            heard_at: Utc::now(),
        }];
        let planned = plan(&memory, &db, 1, &batch).await.unwrap();
        assert!(matches!(planned[0].2, Verdict::Replaces(_)));
        // Forgotten after the model was asked, before the batch is filed.
        sqlx::query!("delete from memory_fact")
            .execute(&db)
            .await
            .unwrap();
        file(&db, planned, &[heard]).await.unwrap();
        assert!(current(&db).await.is_empty(), "it stays forgotten");
        assert!(
            !learn_due(&memory, &db).await.unwrap(),
            "the message counts as read"
        );
    }

    #[sqlx::test]
    async fn forgetting_a_fact_forgets_what_it_replaced(db: PgPool) {
        let (memory, _) = fake(vec![
            facts(&[("Sam prefers appointments after 11:00.", &[1])]),
            facts(&[("Sam prefers appointments before 11:00.", &[1])]),
            json!({ "relation": "replaces", "number": 1 }),
        ])
        .await;
        say(&db, "appointments after 11 please").await;
        learn_due(&memory, &db).await.unwrap();
        say(&db, "actually before 11").await;
        learn_due(&memory, &db).await.unwrap();
        let newest = sqlx::query_scalar!("select id from memory_fact where replaced_by is null")
            .fetch_one(&db)
            .await
            .unwrap();

        let app = crate::auth::tests::app(db.clone());
        forget(State(app.clone()), Path(newest)).await.unwrap();
        let left = sqlx::query_scalar!("select count(*) from memory_fact")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(left, Some(0), "the older version doesn't come back");
        assert_eq!(
            forget(State(app), Path(newest)).await.unwrap_err().0,
            StatusCode::NOT_FOUND
        );
    }

    #[sqlx::test]
    async fn a_reply_from_when_the_bot_was_private_is_not_context(db: PgPool) {
        use orphusbot_proto::{Role, ThreadEvent};
        let (memory, asked) = fake(vec![facts(&[])]).await;
        for (text, minutes) in [("PRIVATE-REPLY", 10), ("TEAM-REPLY", 6)] {
            let event = ThreadEvent::Message {
                role: Role::Assistant,
                text: text.into(),
            };
            let id = crate::db::append(&db, 1, &event).await.unwrap();
            sqlx::query!(
                "update event set created_at = now() - make_interval(mins => $2) where id = $1",
                id,
                minutes
            )
            .execute(&db)
            .await
            .unwrap();
        }
        // The bot became a team bot between the two replies.
        sqlx::query!(
            "update bot set team_since = now() - interval '7 minutes'
             where id = (select bot_id from thread where id = 1)"
        )
        .execute(&db)
        .await
        .unwrap();
        say(&db, "yes").await;
        learn_due(&memory, &db).await.unwrap();
        let prompt = asked.lock().unwrap()[0].clone();
        assert!(prompt.contains("TEAM-REPLY"), "{prompt}");
        assert!(!prompt.contains("PRIVATE-REPLY"), "{prompt}");
    }

    /// Against real servers: `ORPHUSBOT_MEMORY_LLM_URL=… ORPHUSBOT_MEMORY_EMBED_URL=… cargo test live_memory -- --ignored --nocapture`.
    #[sqlx::test]
    #[ignore = "needs a model server and an embedding server"]
    async fn live_memory(db: PgPool) {
        let memory = Memory {
            owner: "Sam".into(),
            ..Memory::from_env()
        };
        assert!(memory.enabled(), "set the two URLs");
        for text in [
            "morning. can you move my dentist to next tuesday, I hate early ones so after 11",
            "thanks. also I'm switching the shop site from woocommerce to shopify in january",
            "my sister Priya is visiting from Leeds on the 28th, block that weekend out",
        ] {
            say(&db, text).await;
        }
        learn_due(&memory, &db).await.unwrap();
        for text in [
            "like I said, no dentist or doctor before 11",
            "change of plan: the shop is staying on woocommerce, shopify fees are too high",
            "ok thanks",
        ] {
            say(&db, text).await;
        }
        learn_due(&memory, &db).await.unwrap();
        let all = sqlx::query!(
            "select text, times_seen, replaced_by is not null as \"replaced!\" from memory_fact order by id"
        )
        .fetch_all(&db)
        .await
        .unwrap();
        for f in &all {
            println!(
                "{}x{} {}",
                if f.replaced { "(replaced) " } else { "" },
                f.times_seen,
                f.text
            );
        }
        assert!(
            all.iter().any(|f| f.replaced),
            "the Shopify plan should have been replaced"
        );
    }

    #[sqlx::test]
    async fn a_recent_message_waits(db: PgPool) {
        let (memory, _) = fake(vec![]).await;
        sqlx::query!("insert into memory_heard (thread_id, text) values (1, 'just now')")
            .execute(&db)
            .await
            .unwrap();
        assert!(!learn_due(&memory, &db).await.unwrap());
    }
}
