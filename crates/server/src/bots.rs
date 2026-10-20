//! Bots: create, edit, disable (PRD B-BOT-01, B-BOT-03).
//!
//! Each bot is an Orphus engine with its own instructions, model and
//! computer, and one thread. Its slug comes from its first name and never
//! changes, because it names the engine session, the computer and its home.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use orphusbot_proto::BotSpec;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

use crate::{ApiError, Shared, internal};

/// How every bot formats its replies (DESIGN §3.6). Added to its instructions
/// when a run starts; a bot's own instructions can override it.
pub const HOUSE_STYLE: &str = "\n\nHow to write replies (they are shown as Markdown in the chat):\n\
- Lead with the answer or the result in the first line. No preamble, no restating the question, no sign-off.\n\
- Plain, friendly British English. Short paragraphs of one to three sentences.\n\
- Bullet lists for options, findings and several points; numbered lists for steps in order.\n\
- Headings (##) only for long replies with distinct parts; never for a short answer.\n\
- Code, commands, paths and file names in backticks; longer code in fenced blocks with the language named.\n\
- A table when comparing several things on the same points.\n\
- Bold sparingly, for the one or two things that must not be missed.\n\
- Links as [what it is](url), not bare URLs. Say when you are unsure, and what would settle it.\n\n\
How your work runs: your turn is the whole task. When you start helpers (subagents or a /fleet), run them \
in the foreground and wait for their results before you finish; never send them to the background. Once \
your turn ends, nothing you started can be approved any more, so background helpers would wait for ever.\n\n\
The team's memory is a Karpathy-style LLM wiki in the shared folder: /shared/raw (sources, never edited) and \
/shared/wiki (articles, with wiki/index.md). Use the karpathy-llm-wiki skill with /shared as its root: before \
researching something, query the wiki; when you learn something lasting (a decision, a finding, a fact about \
Kelvin's work), ingest it so the next bot finds it. If /shared isn't there, you're a private bot: skip this.";

const THINKING: &[&str] = &["off", "minimal", "low", "medium", "high", "xhigh", "max"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bot {
    pub slug: String,
    pub name: String,
    pub remit: String,
    pub instructions: String,
    pub model: Option<String>,
    pub thinking: Option<String>,
    pub exclude_tools: Vec<String>,
    /// "team" or "private".
    pub scope: String,
    pub disabled: bool,
    /// Where its computer is: `node` (a container on a node) or `e2b`.
    #[serde(default = "on_node")]
    pub computer: String,
    /// What it may do in Google through `gog` (DESIGN §11.5): none, read or write.
    #[serde(default = "read")]
    pub google: String,
    /// Its face from the library; none keeps its own style or the default.
    #[serde(default)]
    pub face: Option<String>,
}

fn on_node() -> String {
    "node".into()
}

fn read() -> String {
    "read".into()
}

impl Bot {
    pub fn spec(&self) -> BotSpec {
        BotSpec {
            slug: self.slug.clone(),
            instructions: self.instructions.clone(),
            model: self.model.clone(),
            thinking: self.thinking.clone(),
            exclude_tools: self.exclude_tools.clone(),
            team: self.scope == "team",
            // Filled in when a run starts (`connections::for_bot`, `e2b`).
            mcp: Vec::new(),
            e2b: None,
            // A discussion turn sets these (`discussions::session`).
            session: None,
            name: None,
            google: (self.google != "none").then(|| self.google.clone()),
        }
    }

    /// The owner's input, trimmed and checked; the error is shown to them.
    fn check(mut self) -> Result<Self, &'static str> {
        self.name = self.name.trim().to_owned();
        self.remit = self.remit.trim().to_owned();
        self.model = self
            .model
            .map(|m| m.trim().to_owned())
            .filter(|m| !m.is_empty());
        self.thinking = self.thinking.filter(|t| !t.is_empty());
        let tool_ok = |t: &String| {
            (1..=40).contains(&t.len()) && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        };
        match () {
            _ if !(1..=40).contains(&self.name.chars().count()) => {
                Err("Name the bot in 1 to 40 characters")
            }
            _ if self.remit.chars().count() > 200 => {
                Err("Keep the remit to one line (200 characters)")
            }
            _ if self.instructions.chars().count() > 8000 => {
                Err("Instructions are limited to 8,000 characters")
            }
            _ if self.model.as_ref().is_some_and(|m| m.len() > 100) => {
                Err("That model name is too long")
            }
            _ if self
                .thinking
                .as_ref()
                .is_some_and(|t| !THINKING.contains(&t.as_str())) =>
            {
                Err("Thinking is one of off, minimal, low, medium, high, xhigh or max")
            }
            _ if !self.exclude_tools.iter().all(tool_ok) => {
                Err("Tool names are letters, digits and _")
            }
            _ if !["team", "private"].contains(&self.scope.as_str()) => {
                Err("Scope is team or private")
            }
            _ if !["node", "e2b"].contains(&self.computer.as_str()) => {
                Err("The computer is on a node or in E2B")
            }
            _ if !["none", "read", "write"].contains(&self.google.as_str()) => {
                Err("Google is none, read or write")
            }
            _ if self.face.as_deref().is_some_and(|f| {
                f.is_empty()
                    || f.len() > 40
                    || !f
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            }) =>
            {
                Err("A face is a style name from the library")
            }
            _ => Ok(self),
        }
    }
}

/// A computer in E2B needs the server's E2B key.
fn e2b_available(app: &crate::App, bot: &Bot) -> Result<(), ApiError> {
    if bot.computer == "e2b" && !app.e2b.enabled() {
        return Err((
            StatusCode::CONFLICT,
            "Set ORPHUSBOT_E2B_API_KEY on the server to put computers in E2B",
        ));
    }
    Ok(())
}

/// "Research Assistant!" → "research-assistant".
fn slugify(name: &str) -> String {
    let mut slug = String::new();
    for c in name.chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() {
            slug.push(c);
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug: String = slug.trim_end_matches('-').chars().take(24).collect();
    if slug.is_empty() {
        "bot".into()
    } else {
        slug.trim_end_matches('-').to_owned()
    }
}

pub async fn all(db: &PgPool) -> sqlx::Result<Vec<Bot>> {
    sqlx::query_as!(
        Bot,
        "select slug, name, remit, instructions, model, thinking, exclude_tools, scope, disabled, computer, google, face
         from bot order by disabled, slug <> 'orchestrator', slug <> 'inbox', name"
    )
    .fetch_all(db)
    .await
}

pub async fn get(db: &PgPool, slug: &str) -> sqlx::Result<Option<Bot>> {
    sqlx::query_as!(
        Bot,
        "select slug, name, remit, instructions, model, thinking, exclude_tools, scope, disabled, computer, google, face
         from bot where slug = $1",
        slug
    )
    .fetch_optional(db)
    .await
}

pub async fn list(State(app): State<Shared>) -> Result<Json<Vec<Bot>>, ApiError> {
    all(&app.db)
        .await
        .map(Json)
        .map_err(|e| internal("listing bots", e))
}

/// The fields the owner sets; the slug is made from the name.
#[derive(Deserialize)]
pub struct NewBot {
    name: String,
    #[serde(default)]
    remit: String,
    #[serde(default)]
    instructions: String,
    model: Option<String>,
    thinking: Option<String>,
    #[serde(default)]
    exclude_tools: Vec<String>,
    #[serde(default = "private")]
    scope: String,
    #[serde(default = "on_node")]
    computer: String,
    #[serde(default = "read")]
    google: String,
    #[serde(default)]
    face: Option<String>,
}

fn private() -> String {
    "private".into()
}

pub async fn create(
    State(app): State<Shared>,
    Json(new): Json<NewBot>,
) -> Result<Json<Bot>, ApiError> {
    let bot = Bot {
        slug: slugify(&new.name),
        name: new.name,
        remit: new.remit,
        instructions: new.instructions,
        model: new.model,
        thinking: new.thinking,
        exclude_tools: new.exclude_tools,
        scope: new.scope,
        disabled: false,
        computer: new.computer,
        google: new.google,
        face: new.face,
    }
    .check()
    .map_err(|why| (StatusCode::UNPROCESSABLE_ENTITY, why))?;
    e2b_available(&app, &bot)?;
    let mut tx = app
        .db
        .begin()
        .await
        .map_err(|e| internal("creating a bot", e))?;
    // A taken slug gets a number: "research", "research-2", …
    let taken: Vec<String> =
        sqlx::query_scalar!("select slug from bot where slug like $1 || '%'", bot.slug)
            .fetch_all(&mut *tx)
            .await
            .map_err(|e| internal("creating a bot", e))?;
    let slug = (1..)
        .map(|n| {
            if n == 1 {
                bot.slug.clone()
            } else {
                format!("{}-{n}", bot.slug)
            }
        })
        .find(|s| !taken.contains(s))
        .unwrap_or_default();
    let id = sqlx::query_scalar!(
        "insert into bot (slug, name, remit, instructions, model, thinking, exclude_tools, scope, computer, google, face)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) returning id",
        slug,
        bot.name,
        bot.remit,
        bot.instructions,
        bot.model,
        bot.thinking,
        &bot.exclude_tools,
        bot.scope,
        bot.computer,
        bot.google,
        bot.face
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| internal("creating a bot", e))?;
    sqlx::query!("insert into thread (bot_id) values ($1)", id)
        .execute(&mut *tx)
        .await
        .map_err(|e| internal("creating a bot", e))?;
    tx.commit()
        .await
        .map_err(|e| internal("creating a bot", e))?;
    Ok(Json(Bot { slug, ..bot }))
}

/// Replaces a bot's settings. Its engine picks them up on its next run.
pub async fn update(
    State(app): State<Shared>,
    Json(bot): Json<Bot>,
) -> Result<Json<Bot>, ApiError> {
    let bot = bot
        .check()
        .map_err(|why| (StatusCode::UNPROCESSABLE_ENTITY, why))?;
    e2b_available(&app, &bot)?;
    if bot.slug == "inbox" && bot.disabled {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "The inbox bot can't be disabled",
        ));
    }
    let done = sqlx::query!(
        "update bot set name = $2, remit = $3, instructions = $4, model = $5, thinking = $6,
                exclude_tools = $7, scope = $8, disabled = $9, computer = $10, google = $11, face = $12
         where slug = $1",
        bot.slug,
        bot.name,
        bot.remit,
        bot.instructions,
        bot.model,
        bot.thinking,
        &bot.exclude_tools,
        bot.scope,
        bot.disabled,
        bot.computer,
        bot.google,
        bot.face
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("updating a bot", e))?;
    if done.rows_affected() == 0 {
        return Err((StatusCode::NOT_FOUND, "No such bot"));
    }
    Ok(Json(bot))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(slugify("Research Assistant!"), "research-assistant");
        assert_eq!(slugify("  Ünïcode & co "), "n-code-co");
        assert_eq!(slugify("!!!"), "bot");
        assert_eq!(
            slugify("a very long bot name that goes on and on"),
            "a-very-long-bot-name-tha"
        );
    }

    #[test]
    fn checks() {
        let bot = |name: &str, thinking: Option<&str>| Bot {
            slug: "x".into(),
            name: name.into(),
            remit: String::new(),
            instructions: String::new(),
            model: Some("  ".into()),
            thinking: thinking.map(Into::into),
            exclude_tools: vec![],
            scope: "private".into(),
            disabled: false,
            computer: "node".into(),
            google: "read".into(),
            face: None,
        };
        let ok = bot(" Researcher ", Some("high")).check().unwrap();
        assert_eq!((ok.name.as_str(), ok.model), ("Researcher", None));
        assert!(bot("", None).check().is_err());
        assert!(bot("R", Some("turbo")).check().is_err());
        let face = |f: &str| {
            Bot {
                face: Some(f.into()),
                ..bot("R", None)
            }
            .check()
        };
        assert!(face("fox").is_ok() && face("cat-ears").is_ok());
        assert!(face("../x").is_err() && face("Fox").is_err() && face("").is_err());
    }

    #[sqlx::test]
    async fn the_inbox_exists_with_its_thread(db: PgPool) {
        let inbox = get(&db, "inbox").await.unwrap().unwrap();
        assert_eq!(inbox.name, "Inbox");
        assert!(crate::db::bot_thread(&db, "inbox").await.unwrap().is_some());
    }

    #[sqlx::test]
    async fn the_orchestrator_is_the_main_bot(db: PgPool) {
        let all = all(&db).await.unwrap();
        assert_eq!(all[0].slug, "orchestrator", "listed first");
        assert_eq!(all[1].slug, "inbox");
        assert_eq!(all[0].scope, "team");
        assert!(all[0].instructions.contains("discuss tool"));
        assert!(
            crate::db::bot_thread(&db, "orchestrator")
                .await
                .unwrap()
                .is_some()
        );
    }
}
