//! The Health screen (DESIGN §16.1, D-076): one place that says when an
//! outside service the bots rely on has stopped working, and a push when one
//! breaks or comes back.
//!
//! Every 15 minutes, and when the owner taps Check now, the server runs a
//! cheap check of each thing that is set up (nodes, the xAI key, the model
//! servers it calls, ntfy, the disk) and keeps the latest result of each in
//! `health_check`. Google is not checked here: gws runs on a node, so its
//! state comes from bots' real `google` calls (`google_used`). A check that
//! isn't set up is left out, not shown red.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::Context as _;
use axum::Json;
use axum::extract::State;
use futures_util::future::{BoxFuture, join_all};
use serde_json::{Value, json};
use tracing::warn;

use crate::{ApiError, App, Shared, internal, lock};

/// What the bridge puts in a `google` result when gws's sign-in was refused
/// (bridge/orphusbot-bridge.ts). The bot sees the whole sentence.
pub const GOOGLE_EXPIRED: &str = "Google access has expired";
const EVERY: Duration = Duration::from_secs(15 * 60);
/// The first round waits for nodes to reconnect after a server restart.
const FIRST_AFTER: Duration = Duration::from_secs(2 * 60);
/// Each outside call gives up after this, so one hung service can't stall the rest.
const TIMEOUT: Duration = Duration::from_secs(10);
/// Less free space than this on the server's disk is a problem.
const DISK_MIN_BYTES: u64 = 5 * 1024 * 1024 * 1024;

/// What a failing check found, in plain words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub problem: String,
    pub fix: String,
}

fn problem(problem: impl Into<String>, fix: impl Into<String>) -> Option<Problem> {
    Some(Problem {
        problem: problem.into(),
        fix: fix.into(),
    })
}

/// The outside world, as the checks see it: xAI, the model servers, ntfy and
/// the disk. A fake in tests, so no test calls a real service.
pub trait Probe: Send + Sync {
    /// The status of a GET (with a bearer token when given), within [`TIMEOUT`].
    fn status<'a>(
        &'a self,
        url: &'a str,
        bearer: Option<&'a str>,
    ) -> BoxFuture<'a, anyhow::Result<u16>>;
    /// Free bytes on the filesystem holding `path`.
    fn free_bytes<'a>(&'a self, path: &'a str) -> BoxFuture<'a, anyhow::Result<u64>>;
}

struct Real {
    http: reqwest::Client,
}

impl Probe for Real {
    fn status<'a>(
        &'a self,
        url: &'a str,
        bearer: Option<&'a str>,
    ) -> BoxFuture<'a, anyhow::Result<u16>> {
        Box::pin(async move {
            let mut req = self.http.get(url).timeout(TIMEOUT);
            if let Some(token) = bearer {
                req = req.bearer_auth(token);
            }
            Ok(req.send().await?.status().as_u16())
        })
    }

    fn free_bytes<'a>(&'a self, path: &'a str) -> BoxFuture<'a, anyhow::Result<u64>> {
        let path = path.to_owned();
        Box::pin(async move {
            // POSIX `df` rather than a new dependency for statvfs.
            let out = tokio::task::spawn_blocking(move || {
                std::process::Command::new("df")
                    .args(["-Pk", "--", &path])
                    .output()
            })
            .await??;
            anyhow::ensure!(out.status.success(), "df failed");
            available_kib(&String::from_utf8_lossy(&out.stdout))
                .map(|kib| kib * 1024)
                .context("reading df's output")
        })
    }
}

/// The "Available" column of `df -Pk`'s last line.
fn available_kib(df: &str) -> Option<u64> {
    df.lines().last()?.split_whitespace().nth(3)?.parse().ok()
}

/// A model server the server calls itself, checked with a read-only GET.
struct Endpoint {
    name: &'static str,
    label: &'static str,
    /// Where its address is set, for the fix line.
    env: &'static str,
    url: String,
    /// Up when it answers below this status: 300 for a `/models` list, 500
    /// for a server with no read-only path (any answer means it's running).
    below: u16,
}

/// The checks as the server has them set up.
pub struct Health {
    probe: Box<dyn Probe>,
    xai_key: Option<String>,
    endpoints: Vec<Endpoint>,
    /// ntfy's own health address, from `ORPHUSBOT_NTFY_URL`.
    ntfy: Option<String>,
    /// A path on the server's data disk.
    disk: Option<String>,
    /// One result written at a time, so a change is pushed once.
    writing: tokio::sync::Mutex<()>,
    /// One round at a time, so an older round's results (a node seen
    /// offline before a slow probe) can't land after a newer round's.
    round: tokio::sync::Mutex<()>,
}

impl Health {
    /// Reads the same settings as the parts it checks; nothing of its own
    /// except that the disk checked is the one holding `$HOME`.
    pub fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        let url = |name: &str| var(name).map(|u| u.trim().trim_end_matches('/').to_owned());
        let mut endpoints = Vec::new();
        let mut add = |name, label, env, path: &str, below| {
            if let Some(base) = url(env) {
                endpoints.push(Endpoint {
                    name,
                    label,
                    env,
                    url: format!("{base}{path}"),
                    below,
                });
            }
        };
        add(
            "memory-llm",
            "Memory's chat model",
            "ORPHUSBOT_MEMORY_LLM_URL",
            "/models",
            300,
        );
        add(
            "memory-embed",
            "Memory's embedding model",
            "ORPHUSBOT_MEMORY_EMBED_URL",
            "/models",
            300,
        );
        add("laya", "System 1 (Laya)", "ORPHUSBOT_LAYA_URL", "/", 500);
        Self {
            probe: Box::new(Real {
                http: reqwest::Client::new(),
            }),
            xai_key: var("ORPHUSBOT_XAI_KEY").map(|k| k.trim().to_owned()),
            endpoints,
            ntfy: var("ORPHUSBOT_NTFY_URL").and_then(|topic| ntfy_health(&topic)),
            disk: var("HOME"),
            writing: Default::default(),
            round: Default::default(),
        }
    }

    #[cfg(test)]
    pub fn off() -> Self {
        Self {
            probe: Box::new(testkit::FakeProbe::default()),
            xai_key: None,
            endpoints: Vec::new(),
            ntfy: None,
            disk: None,
            writing: Default::default(),
            round: Default::default(),
        }
    }
}

/// ntfy's health address on the server of a topic URL; asking it publishes nothing.
fn ntfy_health(topic: &str) -> Option<String> {
    let mut url = reqwest::Url::parse(topic).ok()?;
    url.set_path("/v1/health");
    url.set_query(None);
    Some(url.to_string())
}

async fn check_xai(probe: &dyn Probe, key: &str) -> Option<Problem> {
    // Listing models is free; it only proves the key is accepted.
    match probe.status("https://api.x.ai/v1/models", Some(key)).await {
        Ok(200..=299) => None,
        Ok(401 | 403) => problem(
            "xAI refused the key",
            "Make a new key at console.x.ai, put it in ORPHUSBOT_XAI_KEY in the server's keys.env and restart the server.",
        ),
        _ => problem(
            "xAI isn't answering",
            "Usually xAI's side: X search and the Ideas Room's voice fail until it's back. Check now again later.",
        ),
    }
}

async fn check_endpoint(probe: &dyn Probe, e: &Endpoint) -> Option<Problem> {
    match probe.status(&e.url, None).await {
        Ok(status) if status < e.below => None,
        _ => problem(
            format!("{} isn't answering", e.label),
            format!(
                "Check its service is running on the server machine, at the address in {}.",
                e.env
            ),
        ),
    }
}

async fn check_ntfy(probe: &dyn Probe, url: &str) -> Option<Problem> {
    match probe.status(url, None).await {
        Ok(200..=299) => None,
        _ => problem(
            "Pushes can't reach ntfy",
            "Check the ntfy service on the server machine is running. Until then, look here for problems.",
        ),
    }
}

async fn check_disk(probe: &dyn Probe, path: &str) -> Option<Problem> {
    match probe.free_bytes(path).await {
        Ok(free) if free >= DISK_MIN_BYTES => None,
        Ok(free) => problem(
            format!(
                "The server's disk is nearly full: {:.1} GB free",
                free as f64 / 1e9
            ),
            "Free space on the server machine: old images (`podman image prune`), logs or old captures.",
        ),
        Err(e) => {
            warn!("checking free disk space: {e:#}");
            problem(
                "The server's free disk space couldn't be read",
                "See the server's log.",
            )
        }
    }
}

/// Every mail account any bot may use (DESIGN §11.11).
async fn mail_accounts(app: &App) -> sqlx::Result<Vec<String>> {
    sqlx::query_scalar!(
        r#"select distinct unnest(mail_accounts) as "account!" from bot order by 1"#
    )
    .fetch_all(&app.db)
    .await
}

async fn check_mail(app: &App, account: String) -> Option<Problem> {
    match app.mail.reachable(&account).await {
        Ok(()) => None,
        Err(e) => {
            // Himalaya's own words stay in the log: they may name addresses.
            warn!(account, "checking a mail account: {e:#}");
            problem(
                format!("Mail account {account} isn't working"),
                format!("Check the Himalaya account {account} on the server."),
            )
        }
    }
}

fn node_problem(node: &str) -> Option<Problem> {
    problem(
        format!("The node {node} is offline"),
        "Start it on that machine (`systemctl --user start orphusbot-node`) or wake the machine. Bots placed there wait until it's back.",
    )
}

fn google_problem() -> Problem {
    Problem {
        problem: "Google needs reconnecting".into(),
        fix: "On a machine with a browser run `gws auth login -s gmail,calendar,tasks,drive,docs,sheets,people`, \
              then `gws auth export --unmasked` over the node's credentials file (DEVELOPMENT.md, Google for bots). \
              This turns green after the next Google call that works: ask a bot to look at your calendar."
            .into(),
    }
}

/// Runs every check that is set up, stores the results and pushes changes.
pub async fn check_now(app: &App) -> anyhow::Result<()> {
    let h = &app.health;
    let _round = h.round.lock().await;
    let enrolled = sqlx::query_scalar!("select name from node order by name")
        .fetch_all(&app.db)
        .await?;
    let connected: HashSet<String> = lock(&app.rt).nodes.keys().cloned().collect();

    type Check<'a> = (String, String, BoxFuture<'a, Option<Problem>>);
    let mut checks: Vec<Check> = Vec::new();
    for node in enrolled {
        let found = (!connected.contains(&node))
            .then(|| node_problem(&node))
            .flatten();
        let check: BoxFuture<_> = Box::pin(async move { found });
        checks.push((format!("node:{node}"), format!("Node {node}"), check));
    }
    if let Some(key) = &h.xai_key {
        let check = Box::pin(check_xai(&*h.probe, key));
        checks.push(("xai".into(), "xAI key".into(), check));
    }
    for e in &h.endpoints {
        let check = Box::pin(check_endpoint(&*h.probe, e));
        checks.push((e.name.into(), e.label.into(), check));
    }
    if let Some(url) = &h.ntfy {
        let check = Box::pin(check_ntfy(&*h.probe, url));
        checks.push(("ntfy".into(), "Pushes (ntfy)".into(), check));
    }
    if let Some(path) = &h.disk {
        let check = Box::pin(check_disk(&*h.probe, path));
        checks.push(("disk".into(), "Disk space".into(), check));
    }
    if app.mail.ready() {
        for account in mail_accounts(app).await? {
            let check = Box::pin(check_mail(app, account.clone()));
            checks.push((
                format!("mail:{account}"),
                format!("Mail ({account})"),
                check,
            ));
        }
    }
    // A new check is one more entry here.

    let names: Vec<String> = checks.iter().map(|(name, ..)| name.clone()).collect();
    let results = join_all(checks.into_iter().map(|(name, label, check)| async move {
        // A backstop: each probe has its own timeout.
        let found = tokio::time::timeout(TIMEOUT + Duration::from_secs(1), check)
            .await
            .unwrap_or_else(|_| {
                problem(
                    format!("{label} didn't answer in time"),
                    "Check now again later; if it stays red, see the server's log.",
                )
            });
        (name, label, found)
    }))
    .await;
    for (name, label, found) in results {
        tell(app, record(app, &name, &label, found.as_ref()).await?);
    }
    // Checks that are no longer set up, and removed nodes. Google's state
    // comes from bots' calls, not from this round.
    sqlx::query!(
        "delete from health_check where not (name = any($1)) and name <> 'google'",
        &names
    )
    .execute(&app.db)
    .await?;
    Ok(())
}

/// The push for a change, if it is one: a check that started failing (or is
/// new and failing), or one that was failing and works again.
fn news(label: &str, was_ok: Option<bool>, found: Option<&Problem>) -> Option<(String, String)> {
    match (was_ok, found) {
        (Some(true) | None, Some(p)) => {
            Some((format!("{} — see Health", p.problem), p.fix.clone()))
        }
        (Some(false), None) => Some((
            format!("{label} is working again"),
            "Fixed; nothing to do.".into(),
        )),
        _ => None,
    }
}

/// Stores a check's result; returns the push to send if its state changed.
async fn record(
    app: &App,
    name: &str,
    label: &str,
    found: Option<&Problem>,
) -> sqlx::Result<Option<(String, String)>> {
    let _one = app.health.writing.lock().await;
    let was_ok = sqlx::query_scalar!(
        "with before as (select ok from health_check where name = $1)
         insert into health_check (name, label, ok, problem, fix, since)
         values ($1, $2, $3, $4, $5, case when $3 then null else now() end)
         on conflict (name) do update set
             label = excluded.label, ok = excluded.ok, problem = excluded.problem,
             fix = excluded.fix, checked_at = now(),
             since = case when excluded.ok then null else coalesce(health_check.since, now()) end
         returning (select ok from before)",
        name,
        label,
        found.is_none(),
        found.map(|p| p.problem.as_str()),
        found.map(|p| p.fix.as_str()),
    )
    .fetch_one(&app.db)
    .await?;
    Ok(news(label, was_ok, found))
}

fn tell(app: &App, news: Option<(String, String)>) {
    if let Some((title, body)) = news {
        let broke = !title.ends_with("working again");
        app.notifier.send(crate::notify::Push {
            title,
            body,
            priority: if broke { 4 } else { 3 },
            tags: if broke { "warning" } else { "white_check_mark" },
            bot: None,
        });
    }
}

/// A bot's `google` call that reached Google finished: its result marks
/// Google red (the bridge reported a refused sign-in) or green (it worked).
/// Any other failure (a bad command, a refused change) says nothing about the sign-in.
pub async fn google_used(app: &App, ok: bool, result: &str) {
    let found = if ok {
        None
    } else if result.contains(GOOGLE_EXPIRED) {
        Some(google_problem())
    } else {
        return;
    };
    match record(app, "google", "Google", found.as_ref()).await {
        Ok(news) => tell(app, news),
        Err(e) => warn!("recording Google's health: {e}"),
    }
}

pub async fn check_forever(app: Shared) {
    let start = tokio::time::Instant::now() + FIRST_AFTER;
    let mut tick = tokio::time::interval_at(start, EVERY);
    loop {
        tick.tick().await;
        if let Err(e) = check_now(&app).await {
            warn!("checking health: {e:#}");
        }
    }
}

async fn all(app: &App) -> Result<Json<Value>, ApiError> {
    let rows = sqlx::query!(
        "select name, label, ok, problem, fix, since, checked_at from health_check order by ok, label"
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("reading health checks", e))?;
    let checks: Vec<Value> = rows
        .into_iter()
        .map(|r| {
            json!({
                "name": r.name,
                "label": r.label,
                "ok": r.ok,
                "problem": r.problem,
                "fix": r.fix,
                "since": r.since.map(|t| t.to_rfc3339()),
                "checked_at": r.checked_at.to_rfc3339(),
            })
        })
        .collect();
    Ok(Json(json!(checks)))
}

/// `GET /api/health`: every check's latest result, failing ones first.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    all(&app).await
}

/// `POST /api/health/check`: runs the checks now, then lists them.
pub async fn run(State(app): State<Shared>) -> Result<Json<Value>, ApiError> {
    check_now(&app)
        .await
        .map_err(|e| internal("checking health", format!("{e:#}")))?;
    all(&app).await
}

/// The fake for tests (the repository has no `testkit` crate yet; DESIGN §2).
#[cfg(test)]
pub mod testkit {
    use super::*;
    use std::collections::HashMap;

    /// Answers each URL with the status given for it (no entry: unreachable),
    /// and the disk with `free`.
    #[derive(Default)]
    pub struct FakeProbe {
        pub statuses: HashMap<String, u16>,
        pub free: Option<u64>,
    }

    impl Probe for FakeProbe {
        fn status<'a>(
            &'a self,
            url: &'a str,
            _bearer: Option<&'a str>,
        ) -> BoxFuture<'a, anyhow::Result<u16>> {
            let status = self.statuses.get(url).copied().context("unreachable");
            Box::pin(async move { status })
        }

        fn free_bytes<'a>(&'a self, _path: &'a str) -> BoxFuture<'a, anyhow::Result<u64>> {
            let free = self.free.context("no disk");
            Box::pin(async move { free })
        }
    }

    /// Every check set up, answered by `probe`.
    pub fn fake(probe: FakeProbe) -> Health {
        Health {
            probe: Box::new(probe),
            xai_key: Some("test-key".into()),
            endpoints: vec![Endpoint {
                name: "memory-llm",
                label: "Memory's chat model",
                env: "ORPHUSBOT_MEMORY_LLM_URL",
                url: "http://llm.test/v1/models".into(),
                below: 300,
            }],
            ntfy: Some("https://push.example.com/v1/health".into()),
            disk: Some("/".into()),
            writing: Default::default(),
            round: Default::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testkit::{FakeProbe, fake};
    use super::*;
    use sqlx::PgPool;
    use std::sync::Arc;

    fn app_with(db: &PgPool, health: Health) -> Shared {
        let mut app = crate::auth::tests::app(db.clone());
        Arc::get_mut(&mut app).unwrap().health = health;
        app
    }

    async fn states(db: &PgPool) -> Vec<(String, bool)> {
        sqlx::query!("select name, ok from health_check order by name")
            .fetch_all(db)
            .await
            .unwrap()
            .into_iter()
            .map(|r| (r.name, r.ok))
            .collect()
    }

    #[test]
    fn pushes_only_changes() {
        let p = google_problem();
        let broke = news("Google", Some(true), Some(&p)).unwrap();
        assert_eq!(broke.0, "Google needs reconnecting — see Health");
        assert!(news("Google", None, Some(&p)).is_some(), "new and failing");
        assert_eq!(news("Google", Some(false), Some(&p)), None, "still red");
        assert_eq!(news("Google", Some(true), None), None);
        assert_eq!(news("Google", None, None), None, "new and fine");
        assert_eq!(
            news("Google", Some(false), None).unwrap().0,
            "Google is working again"
        );
    }

    #[test]
    fn reads_df_and_ntfy_addresses() {
        let df = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
                  /dev/sda2 100 40 60 40% /\n";
        assert_eq!(available_kib(df), Some(60));
        assert_eq!(available_kib(""), None);
        assert_eq!(
            ntfy_health("https://push.example.com/orphusbot-abc?x=1").as_deref(),
            Some("https://push.example.com/v1/health")
        );
        assert_eq!(ntfy_health("not a url"), None);
    }

    #[sqlx::test]
    async fn checks_what_is_set_up_and_keeps_since(db: PgPool) {
        sqlx::query!(
            "insert into node (name, public_key) values ('laptop', decode(repeat('00', 32), 'hex'))"
        )
        .execute(&db)
        .await
        .unwrap();
        let probe = FakeProbe {
            statuses: [
                ("https://api.x.ai/v1/models".to_owned(), 401),
                ("http://llm.test/v1/models".to_owned(), 200),
            ]
            .into(),
            free: Some(DISK_MIN_BYTES - 1),
        };
        let app = app_with(&db, fake(probe));
        check_now(&app).await.unwrap();
        assert_eq!(
            states(&db).await,
            [
                ("disk".to_owned(), false),
                ("memory-llm".to_owned(), true),
                ("node:laptop".to_owned(), false),
                ("ntfy".to_owned(), false),
                ("xai".to_owned(), false),
            ]
        );
        let xai = sqlx::query!("select problem, fix, since from health_check where name = 'xai'")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(xai.problem.as_deref(), Some("xAI refused the key"));
        assert!(xai.fix.unwrap().contains("ORPHUSBOT_XAI_KEY"));

        // Still red a round later: `since` stays when it first failed, and no push.
        assert_eq!(
            record(
                &app,
                "xai",
                "xAI key",
                check_xai(&*app.health.probe, "k").await.as_ref()
            )
            .await
            .unwrap(),
            None
        );
        let since = sqlx::query_scalar!("select since from health_check where name = 'xai'")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(since, xai.since);

        // A removed node and a check no longer set up drop off; Google stays.
        google_used(&app, true, "{}").await;
        sqlx::query!("delete from node").execute(&db).await.unwrap();
        let app = app_with(&db, Health::off());
        check_now(&app).await.unwrap();
        assert_eq!(states(&db).await, [("google".to_owned(), true)]);
    }

    #[sqlx::test]
    async fn checks_each_mail_account_a_bot_may_use(db: PgPool) {
        sqlx::query!(
            "insert into bot (slug, name, mail_accounts) values
             ('mail-one', 'Mail one', '{personal,work}'), ('mail-two', 'Mail two', '{work}')"
        )
        .execute(&db)
        .await
        .unwrap();
        let (mail, ran) = crate::mail::testkit::fake(None);
        let mut app = app_with(&db, Health::off());
        Arc::get_mut(&mut app).unwrap().mail = mail;
        check_now(&app).await.unwrap();
        assert_eq!(
            states(&db).await,
            [
                ("mail:personal".to_owned(), false),
                ("mail:work".to_owned(), false),
            ]
        );
        let fix = sqlx::query_scalar!("select fix from health_check where name = 'mail:work'")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(
            fix.as_deref(),
            Some("Check the Himalaya account work on the server.")
        );
        // Read-only: each account's folders listed once, nothing else run.
        let ran: Vec<Vec<String>> = ran.lock().unwrap().iter().map(|r| r.args.clone()).collect();
        assert_eq!(ran.len(), 2);
        for args in &ran {
            assert_eq!(args[2..4], ["folder", "list"]);
        }

        let (mail, _) = crate::mail::testkit::fake(Some("[]"));
        Arc::get_mut(&mut app).unwrap().mail = mail;
        check_now(&app).await.unwrap();
        assert!(states(&db).await.iter().all(|(_, ok)| *ok));
    }

    #[sqlx::test]
    async fn google_turns_red_and_green_from_real_calls(db: PgPool) {
        let app = app_with(&db, Health::off());
        // A failure that isn't about the sign-in says nothing.
        google_used(&app, false, "gws exited 1: unknown method").await;
        assert!(states(&db).await.is_empty());

        let expired =
            format!("{GOOGLE_EXPIRED}; Kelvin has been told to reconnect (Health screen).");
        google_used(&app, false, &expired).await;
        assert_eq!(states(&db).await, [("google".to_owned(), false)]);
        let problem = sqlx::query_scalar!("select problem from health_check where name = 'google'")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(problem.as_deref(), Some("Google needs reconnecting"));

        // One push when it breaks, none while it stays broken, one when fixed.
        let p = google_problem();
        assert_eq!(
            record(&app, "google", "Google", Some(&p)).await.unwrap(),
            None
        );
        let fixed = record(&app, "google", "Google", None).await.unwrap();
        assert_eq!(fixed.unwrap().0, "Google is working again");
        assert_eq!(states(&db).await, [("google".to_owned(), true)]);
    }

    #[sqlx::test]
    async fn the_api_lists_failing_checks_first(db: PgPool) {
        let app = app_with(&db, Health::off());
        record(&app, "disk", "Disk space", None).await.unwrap();
        google_used(&app, false, GOOGLE_EXPIRED).await;
        let Json(listed) = list(State(app)).await.unwrap();
        assert_eq!(listed[0]["name"], "google");
        assert_eq!(listed[0]["ok"], false);
        assert!(listed[0]["since"].is_string());
        assert_eq!(listed[1]["name"], "disk");
        assert!(listed[1]["problem"].is_null());
    }
}
