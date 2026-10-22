//! orphusbot-server: bots, their threads and durable runs, placed on nodes.
//!
//! A browser posts a message to a bot; it becomes a run in Postgres. Placement
//! leases the run to a node, and the node's streamed reply comes back to every
//! open browser over Server-Sent Events. If the node drops or its lease lapses,
//! the run goes back to the queue and resumes on the next node (DESIGN §3, §6.3).

mod artifacts;
mod attachments;
mod auth;
mod bots;
mod calibrate;
mod capture;
mod connections;
mod db;
mod device;
mod discussions;
mod e2b;
mod fleets;
mod gallery;
mod gate;
mod google;
mod links;
mod nodes;
mod notify;
mod oauth;
mod phone;
mod placement;
mod profiles;
mod room;
mod routines;
mod runs;
mod screens;
mod secrets;
mod social;
mod system1;
mod team;
mod tickets;
mod usage;

use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, bail};
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::response::Response;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{SinkExt, Stream, StreamExt};
use orphusbot_proto::{
    Attempt, Dialog, DialogKind, Envelope, FromNode, NodeView, Role, RunOutcome, ThreadEvent,
    ToNode,
};
use runs::{Outcome, Submitted};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use subtle::ConstantTimeEq;
use tokio::sync::{Notify, broadcast, mpsc};
use tower_http::services::ServeDir;
use tracing::{info, warn};

const MAX_MESSAGE_CHARS: usize = 32_000;
const MIN_TOKEN_CHARS: usize = 16;
/// How often leases are renewed and lapsed ones swept (DESIGN §3.3).
const RECONCILE_EVERY: Duration = Duration::from_secs(30);
/// A node that sends nothing (not even a pong) for this long is treated as gone.
const NODE_SILENCE_LIMIT: Duration = Duration::from_secs(75);

/// An event on its way to browsers: `id` is set for persisted events, `bot`
/// for events in a bot's thread.
#[derive(Clone)]
struct Live {
    id: Option<i64>,
    bot: Option<String>,
    event: ThreadEvent,
}

/// The connected node. `conn` tells one connection from the next.
#[derive(Clone)]
struct NodeLink {
    conn: u64,
    name: String,
    tx: mpsc::Sender<ToNode>,
    /// Drops the link, when the node is removed.
    kick: Arc<Notify>,
    /// Binary screen frames for the node (see `screens`).
    screen: mpsc::Sender<Vec<u8>>,
    /// From its latest heartbeat; until the first one it counts as idle and ready.
    load: u32,
    on_battery: bool,
    quiet: bool,
    /// `provider/model` names its Orphus can use.
    models: Vec<String>,
    /// It can give bots Google (gws set up with the owner's credentials).
    google: bool,
}

impl NodeLink {
    fn candidate(&self) -> placement::Candidate {
        placement::Candidate {
            name: self.name.clone(),
            load: self.load,
            on_battery: self.on_battery,
            quiet: self.quiet,
        }
    }
}

/// A running attempt: where it runs and whose thread it's in.
#[derive(Clone)]
struct Active {
    attempt: Attempt,
    node: String,
    thread: db::Thread,
}

/// A dialog the engine is blocked on.
#[derive(Clone)]
struct Pending {
    attempt: Attempt,
    thread: db::Thread,
    /// Set for approval gates: the tool call being decided.
    tool_call_id: Option<String>,
    /// A takeover request: its yes and no read "Done" and "Couldn't help".
    takeover: bool,
}

/// In-memory view of the link. Postgres stays the source of truth for runs;
/// `active` only lets the server drop stale frames without a query per delta.
#[derive(Default)]
struct Runtime {
    /// Connected nodes by name.
    nodes: HashMap<String, NodeLink>,
    next_conn: u64,
    /// Running attempts by run id.
    active: HashMap<i64, Active>,
    /// Why each queued run is waiting, as last told to clients.
    waiting: HashMap<i64, String>,
    /// Open dialogs by Orphus request id.
    dialogs: HashMap<String, Pending>,
    /// Capture windows sent to a node for extraction and not yet answered.
    extracting: std::collections::HashSet<i64>,
    /// Open screen viewers by stream number, with the node serving each.
    screens: HashMap<u64, (String, mpsc::Sender<screens::ToViewer>)>,
    next_screen: u64,
}

impl Runtime {
    /// The running attempt, if `attempt` is still the current one for its run.
    fn current(&self, attempt: Attempt) -> Option<&Active> {
        self.active
            .get(&attempt.run)
            .filter(|a| a.attempt == attempt)
    }
}

/// Title the bridge extension gives its approval requests (bridge/orphusbot-bridge.ts).
const GATE_TITLE: &str = "orphusbot-gate";
/// Title of the bridge's `request_takeover` confirm dialog.
const TAKEOVER_TITLE: &str = "orphusbot-takeover";

struct App {
    db: PgPool,
    live: broadcast::Sender<Live>,
    // ponytail: one std Mutex for all link state; per-node state when there is more than one node.
    rt: Mutex<Runtime>,
    auth: auth::Auth,
    system1: system1::System1,
    secrets: secrets::Secrets,
    e2b: e2b::E2b,
    devices: device::Devices,
    notifier: notify::Notifier,
    /// ContentSwarm's owner console, for the Social screen (DESIGN §11.6).
    social: social::Social,
    /// The built web UI (crates/ui/dist), served at `/`.
    ui_dir: String,
}

type Shared = Arc<App>;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let bind = std::env::var("ORPHUSBOT_BIND").unwrap_or_else(|_| "127.0.0.1:7480".into());
    let db_url = std::env::var("DATABASE_URL").context("DATABASE_URL is not set")?;
    let setup_token = token_from_env("ORPHUSBOT_SETUP_TOKEN")?;
    let origin =
        std::env::var("ORPHUSBOT_ORIGIN").unwrap_or_else(|_| "http://localhost:7480".into());
    let auth = auth::Auth::new(&origin, setup_token)?;
    let system1 = system1::System1::from_env();
    let secrets = secrets::Secrets::from_env()?;
    if system1.enabled() {
        info!("System 1 is on: inbox messages are routed and reversible calls may pass");
    }
    let ui_dir = std::env::var("ORPHUSBOT_UI_DIR").unwrap_or_else(|_| "crates/ui/dist".into());
    if !std::path::Path::new(&ui_dir).join("index.html").exists() {
        warn!(
            "no web UI in {ui_dir}: run `trunk build --release` in crates/ui, or set ORPHUSBOT_UI_DIR"
        );
    }

    let db = PgPool::connect(&db_url)
        .await
        .context("connecting to Postgres")?;
    sqlx::migrate!()
        .run(&db)
        .await
        .context("running migrations")?;
    secrets.load(&db).await.context("reading stored secrets")?;
    let orphaned = runs::release_all(&db).await?;
    let expired = db::expire_open_dialogs(&db).await?;
    if expired > 0 {
        info!(
            expired,
            "closed dialogs left open by the last server process"
        );
    }
    if orphaned > 0 {
        info!(
            orphaned,
            "re-queued runs left running by the last server process"
        );
    }

    let (live, _) = broadcast::channel(1024);
    let notifier = notify::Notifier::from_env(&origin, db.clone());
    let app = Arc::new(App {
        db,
        live,
        rt: Mutex::default(),
        auth,
        system1,
        secrets,
        e2b: e2b::E2b::from_env(),
        devices: device::Devices::default(),
        notifier,
        social: social::Social::from_env(),
        ui_dir,
    });
    calibrate::load(&app).await;
    tokio::spawn(reconcile_forever(app.clone()));
    tokio::spawn(routines::schedule_forever(app.clone()));
    tokio::spawn(device::expire_forever(app.clone()));
    tokio::spawn(capture::mine_forever(app.clone()));
    tokio::spawn(profiles::tend_forever(app.clone()));
    tokio::spawn(social::watch_forever(app.clone()));

    let router = router(app);

    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .with_context(|| format!("binding {bind}"))?;
    info!("listening on http://{bind}; browsers sign in at {origin}");
    axum::serve(listener, router).await?;
    Ok(())
}

fn router(app: Shared) -> Router {
    let api = Router::new()
        .route("/api/messages", post(send_message))
        .route("/api/runs/cancel", post(cancel_run))
        .route("/api/dialogs/answer", post(answer_dialog))
        .route("/api/events", get(events))
        .route("/api/passkeys", get(auth::list_passkeys))
        .route("/api/passkeys/start", post(auth::register_start))
        .route("/api/passkeys/finish", post(auth::register_finish))
        .route("/api/passkeys/remove", post(auth::remove_passkey))
        .route("/api/logout", post(auth::logout))
        .route("/api/bots", get(bots::list).post(bots::create))
        .route("/api/models", get(models))
        .route("/api/bots/update", post(bots::update))
        .route("/api/decisions", get(system1::list))
        .route("/api/decisions/health", get(system1::health))
        .route("/api/decisions/calibrations", get(calibrate::list))
        .route(
            "/api/connections",
            get(connections::list).post(connections::create),
        )
        .route("/api/connections/delete", post(connections::delete))
        .route(
            "/api/discussions",
            get(discussions::list).post(discussions::create),
        )
        .route("/api/discussions/{id}", get(discussions::get))
        .route(
            "/api/gallery",
            get(gallery::list)
                .post(gallery::upload)
                .layer(axum::extract::DefaultBodyLimit::disable()),
        )
        .route("/api/gallery/{id}/file", get(gallery::file))
        .route("/api/gallery/update", post(gallery::update))
        .route("/api/gallery/delete", post(gallery::delete))
        .route("/api/gallery/from-artifact", post(gallery::from_artifact))
        .route(
            "/api/social/{*path}",
            axum::routing::get(social::proxy).post(social::proxy),
        )
        .route("/api/push", post(notify::register))
        .route("/api/push/remove", post(notify::unregister))
        .route("/api/fleets", get(fleets::list).post(fleets::save))
        .route("/api/fleets/delete", post(fleets::delete))
        .route("/api/connections/grant", post(connections::grant))
        .route("/api/connections/oauth", post(oauth::start))
        .route("/api/artifacts/{id}", get(artifacts::download))
        .route(
            "/api/attachments",
            post(attachments::upload).layer(axum::extract::DefaultBodyLimit::max(
                attachments::MAX_BYTES + 1024,
            )),
        )
        .route("/api/attachments/{id}", get(attachments::download))
        .route("/api/decisions/label", post(system1::label_by_owner))
        .route("/api/decisions/fit", post(calibrate::fit))
        .route("/api/decisions/apply", post(calibrate::apply))
        .route("/api/decisions/rollback", post(calibrate::rollback))
        .route("/api/usage", get(usage::summary))
        .route("/api/room/voice", post(room::voice))
        .route("/api/routines", get(routines::list).post(routines::save))
        .route("/api/routines/delete", post(routines::delete))
        .route("/api/routines/run", post(routines::run_now))
        .route("/api/tickets", get(tickets::list).post(tickets::create))
        .route("/api/tickets/update", post(tickets::update))
        .route("/api/tickets/start", post(tickets::start_now))
        .route("/api/devices", get(device::list))
        .route("/api/devices/pairing-code", post(device::pairing_code))
        .route("/api/devices/hands-free", post(capture::set_hands_free))
        .route("/api/captures", get(capture::list))
        .route("/api/proposals/accept", post(capture::accept))
        .route("/api/proposals/dismiss", post(capture::dismiss))
        .route("/api/proposals/undo", post(profiles::undo))
        .route(
            "/api/captures/profile",
            get(profiles::get).post(profiles::set),
        )
        .route("/api/screen", get(screens::open))
        .route("/api/links/{code}", get(links::lookup))
        .route("/api/links/approve", post(links::approve))
        .route("/api/nodes", get(nodes::list))
        .route("/api/nodes/code", post(nodes::create_code))
        .route("/api/nodes/remove", post(nodes::remove))
        .route_layer(from_fn_with_state(app.clone(), auth::require_session));
    Router::new()
        .route("/auth/state", get(auth::state))
        .route("/auth/setup", post(auth::setup))
        .route("/auth/login/start", post(auth::login_start))
        .route("/auth/login/finish", post(auth::login_finish))
        .route("/auth/link/start", post(links::start))
        .route("/auth/link/poll", post(links::poll))
        // Public: the secret token in the path is the credential.
        .route("/hooks/routine/{token}", post(routines::hook))
        // Public: the single-use sign-in state is the credential (see `oauth::callback`).
        .route("/oauth/callback", get(oauth::callback))
        // The wearable's channel (wearable/docs/SERVER.md): device tokens, not sessions.
        .route("/api/device/register", post(device::register))
        .route("/api/device/event", post(device::event))
        .route(
            "/api/device/text",
            post(device::text).layer(axum::extract::DefaultBodyLimit::max(8_192)),
        )
        .route("/api/device/command/poll", post(device::poll))
        .route(
            "/api/device/hands-free",
            get(device::hands_free).post(device::set_hands_free),
        )
        .route("/node", get(node_link))
        // Public: the newest app builds (`latest.json`, `orphusbot.apk`), so a
        // phone can update itself from the browser (DESIGN §12.3). They hold no
        // secrets: the server address and sign-in are entered in the app.
        .nest_service("/app", ServeDir::new(app_builds_dir()))
        .merge(api)
        .fallback_service(ServeDir::new(&app.ui_dir))
        .with_state(app)
}

/// Where `scripts/publish-app.sh` puts the newest app builds.
fn app_builds_dir() -> String {
    std::env::var("ORPHUSBOT_APP_DIR").unwrap_or_else(|_| {
        format!(
            "{}/.local/share/orphusbot/app",
            std::env::var("HOME").unwrap_or_default()
        )
    })
}

fn token_from_env(name: &str) -> anyhow::Result<String> {
    let token = std::env::var(name).with_context(|| format!("{name} is not set"))?;
    if token.chars().count() < MIN_TOKEN_CHARS {
        bail!("{name} must be at least {MIN_TOKEN_CHARS} characters");
    }
    Ok(token)
}

fn tokens_match(given: &str, expected: &str) -> bool {
    given.as_bytes().ct_eq(expected.as_bytes()).into()
}

type ApiError = (StatusCode, &'static str);

fn internal(context: &str, e: impl std::fmt::Display) -> ApiError {
    warn!("{context}: {e}");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "Something went wrong; see the server log",
    )
}

#[derive(Deserialize)]
struct NewMessage {
    #[serde(default = "inbox")]
    bot: String,
    #[serde(default)]
    text: String,
    /// Uploaded first with `POST /api/attachments`.
    #[serde(default)]
    attachments: Vec<i64>,
    /// Said in the Ideas Room: the bot is told it's a spoken conversation.
    #[serde(default)]
    room: bool,
}

fn inbox() -> String {
    "inbox".into()
}

#[derive(Deserialize)]
struct WhichBot {
    #[serde(default = "inbox")]
    bot: String,
}

/// Stores the message, then queues a run, joins the waiting one, or steers the
/// running one (B-RUN-01).
async fn send_message(
    State(app): State<Shared>,
    Json(msg): Json<NewMessage>,
) -> Result<StatusCode, ApiError> {
    let text = msg.text.trim().to_owned();
    if (text.is_empty() && msg.attachments.is_empty()) || text.chars().count() > MAX_MESSAGE_CHARS {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Message must be 1 to 32,000 characters",
        ));
    }
    let bot = bots::get(&app.db, &msg.bot)
        .await
        .map_err(|e| internal("finding the bot", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such bot"))?;
    if bot.disabled {
        return Err((StatusCode::CONFLICT, "That bot is disabled"));
    }
    let thread = bot_thread(&app, &bot.slug).await?;
    if discussions::in_turn(&app.db, thread.id)
        .await
        .map_err(|e| internal("checking the bot", e))?
    {
        return Err((
            StatusCode::CONFLICT,
            "It's taking its turn in a discussion; send this when it's done",
        ));
    }
    let files = attachments::check(&app.db, &bot.slug, &msg.attachments).await?;

    if !text.is_empty() {
        let event = app.secrets.redact_event(ThreadEvent::Message {
            role: Role::User,
            text: text.clone(),
        });
        record(&app, &thread, event).await;
    }
    for (id, name, size, image) in &files {
        let event = ThreadEvent::Attached {
            id: *id,
            name: name.clone(),
            size: *size,
            image: *image,
        };
        record(&app, &thread, event).await;
    }

    // Tickets named in the message (OB-12) go to the bot as labelled data (B-TKT-03).
    let mut run_text = format!("{text}{}", tickets::referenced(&app.db, &text).await);
    if msg.room {
        run_text.push_str(room::ROOM_NOTE);
    }
    if !files.is_empty() {
        let list: Vec<String> = files
            .iter()
            .map(|(_, name, size, _)| format!("inbox/{name} ({} KB)", size.div_ceil(1024)))
            .collect();
        run_text.push_str(&format!(
            "\n\nI've sent you {} file{}, saved in your computer: {}. Pictures are also attached for you to look at.",
            files.len(),
            if files.len() == 1 { "" } else { "s" },
            list.join(", ")
        ));
    }
    let source = runs::Source {
        attachments: msg.attachments.clone(),
        ..Default::default()
    };
    // A new task for the inbox goes to System 1 first; a follow-up joins the inbox's run.
    // ponytail: messages with files skip routing; route them too if that's wanted.
    if thread.bot == "inbox" && app.system1.enabled() && files.is_empty() {
        let busy = runs::busy(&app.db, thread.id)
            .await
            .map_err(|e| internal("checking the inbox", e))?;
        if !busy {
            tokio::spawn(triage(app.clone(), thread, text, run_text));
            return Ok(StatusCode::ACCEPTED);
        }
    }
    submit(&app, &thread, run_text, source)
        .await
        .map_err(|e| internal("queueing run", e))?;
    Ok(StatusCode::ACCEPTED)
}

/// Queues `text` as a run in `thread`, or adds it to the thread's active run.
async fn submit(
    app: &App,
    thread: &db::Thread,
    text: String,
    source: runs::Source,
) -> sqlx::Result<()> {
    let sent = source.attachments.clone();
    match runs::submit(&app.db, thread.id, &text, source).await? {
        Submitted::Queued(run) => {
            lock(&app.rt).waiting.remove(&run);
            let event = ThreadEvent::RunQueued { run, waiting: None };
            publish(app, None, Some(&thread.bot), event);
            device::run_news(app, run, device::RunNews::Queued).await;
            dispatch(app).await;
        }
        Submitted::Joined(_) => {}
        Submitted::Steer { run, fence } => {
            let attempt = Attempt { run, fence };
            if let Some(tx) = node_for(app, attempt) {
                // If this fails the node is going away; the run is re-queued and the text is
                // already in the thread for the resumed attempt to see.
                let files = attachments::by_ids(&app.db, &sent).await;
                let _ = tx
                    .send(ToNode::Steer {
                        attempt,
                        text,
                        files,
                    })
                    .await;
            }
        }
    }
    Ok(())
}

/// Asks System 1 which bot an inbox message is for (DESIGN §7.2). If it's sure,
/// the message moves to that bot's thread and the inbox says so; otherwise the
/// inbox keeps it (PRD B-BOT-03).
async fn triage(app: Shared, inbox: db::Thread, text: String, run_text: String) {
    let roster = bots::all(&app.db).await.unwrap_or_default();
    let routed = app.system1.route(&app.db, &text, &roster).await;
    let target = match &routed {
        Some((bot, _)) => db::bot_thread(&app.db, &bot.slug).await.ok().flatten(),
        None => None,
    };
    let thread = match (routed, target) {
        (Some((bot, sure)), Some(target)) => {
            let sure = (sure * 100.0).round().clamp(0.0, 100.0) as u8;
            let event = ThreadEvent::Routed {
                to: bot.slug,
                name: bot.name,
                sure,
            };
            record(&app, &inbox, event).await;
            let copy = ThreadEvent::Message {
                role: Role::User,
                text: text.clone(),
            };
            record(&app, &target, copy).await;
            target
        }
        _ => inbox,
    };
    if let Err(e) = submit(&app, &thread, run_text, runs::Source::default()).await {
        warn!("queueing a run: {e}");
    }
}

async fn bot_thread(app: &App, slug: &str) -> Result<db::Thread, ApiError> {
    db::bot_thread(&app.db, slug)
        .await
        .map_err(|e| internal("finding the bot's thread", e))?
        .ok_or((StatusCode::NOT_FOUND, "No such bot"))
}

/// Stops the thread's active run (B-RUN-03).
async fn cancel_run(
    State(app): State<Shared>,
    body: Option<Json<WhichBot>>,
) -> Result<StatusCode, ApiError> {
    let slug = body.map_or_else(inbox, |Json(b)| b.bot);
    let thread = bot_thread(&app, &slug).await?;
    let Some((run, fence)) = runs::cancel_active(&app.db, thread.id)
        .await
        .map_err(|e| internal("cancelling run", e))?
    else {
        return Err((StatusCode::CONFLICT, "Nothing is running"));
    };
    let attempt = Attempt { run, fence };
    if let Some(tx) = node_for(&app, attempt) {
        let _ = tx.send(ToNode::Abort { attempt }).await;
    }
    {
        let mut rt = lock(&app.rt);
        rt.active.remove(&run);
        rt.waiting.remove(&run);
    }
    run_ended(&app, &thread, run, RunOutcome::Cancelled, None).await;
    dispatch(&app).await;
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize, Default)]
struct Answer {
    id: String,
    /// For approvals: "allow", "always" or "deny".
    decision: Option<String>,
    /// For questions: the chosen option or typed text.
    value: Option<String>,
    /// For yes/no questions.
    confirmed: Option<bool>,
}

fn ui_response(id: &str, field: &str, value: Value) -> Value {
    let mut r = json!({ "type": "extension_ui_response", "id": id });
    r[field] = value;
    r
}

/// The owner answers an approval card or a question (B-RUN-05, B-CLI-04).
async fn answer_dialog(
    State(app): State<Shared>,
    Json(answer): Json<Answer>,
) -> Result<StatusCode, ApiError> {
    resolve_dialog(&app, answer).await
}

/// Answers an open dialog, from a card or from the wrist.
async fn resolve_dialog(app: &App, answer: Answer) -> Result<StatusCode, ApiError> {
    let Some(pending) = lock(&app.rt).dialogs.remove(&answer.id) else {
        return Err((StatusCode::GONE, "That question is no longer open"));
    };
    let id = answer.id.clone();
    let (response, outcome) = match (&pending.tool_call_id, answer.decision.as_deref()) {
        (Some(call), Some(decision @ ("allow" | "always" | "deny"))) => {
            let allow = decision != "deny";
            let always = decision == "always";
            system1::label_gate(&app.db, call, allow).await;
            if let Err(e) = gate::owner_decides(&app.db, pending.attempt, call, allow, always).await
            {
                lock(&app.rt).dialogs.insert(id, pending);
                return Err(internal("recording approval", e));
            }
            let value = if allow {
                "allow"
            } else {
                "deny:The owner did not approve this tool call."
            };
            let outcome = match decision {
                "always" => "Always allowed",
                "allow" => "Allowed once",
                _ => "Denied",
            };
            (ui_response(&id, "value", json!(value)), outcome.to_owned())
        }
        (Some(_), _) => {
            lock(&app.rt).dialogs.insert(id, pending);
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "Choose allow, always or deny",
            ));
        }
        (None, _) => match (answer.value, answer.confirmed) {
            (Some(value), _) => {
                let outcome = format!("Answered: {value}");
                (ui_response(&id, "value", json!(value)), outcome)
            }
            (None, Some(yes)) => {
                let outcome = match (pending.takeover, yes) {
                    (true, true) => "Done",
                    (true, false) => "Couldn't help",
                    (false, true) => "Yes",
                    (false, false) => "No",
                }
                .to_owned();
                (ui_response(&id, "confirmed", json!(yes)), outcome)
            }
            (None, None) => (
                ui_response(&id, "cancelled", json!(true)),
                "Dismissed".to_owned(),
            ),
        },
    };
    respond(app, pending.attempt, response).await;
    dialog_closed(app, &pending.thread, id, outcome).await;
    Ok(StatusCode::ACCEPTED)
}

async fn respond(app: &App, attempt: Attempt, response: Value) {
    if let Some(tx) = node_for(app, attempt) {
        let _ = tx.send(ToNode::DialogResponse { attempt, response }).await;
    }
}

async fn dialog_closed(app: &App, thread: &db::Thread, id: String, outcome: String) {
    device::dialog_settled(app, &id).await;
    record(app, thread, ThreadEvent::DialogClosed { id, outcome }).await;
}

/// Stores an event in a thread and sends it to browsers.
async fn record(app: &App, thread: &db::Thread, event: ThreadEvent) {
    let event = app.secrets.redact_event(event);
    match db::append(&app.db, thread.id, &event).await {
        Ok(id) => publish(app, Some(id), Some(&thread.bot), event),
        Err(e) => warn!("storing an event: {e}"),
    }
}

/// Closes every open dialog for `run`: its attempt ended, so nobody is waiting.
async fn expire_dialogs(app: &App, run: i64) {
    let closed: Vec<(String, db::Thread)> = {
        let mut rt = lock(&app.rt);
        let ids: Vec<String> = rt
            .dialogs
            .iter()
            .filter(|(_, p)| p.attempt.run == run)
            .map(|(id, _)| id.clone())
            .collect();
        ids.into_iter()
            .filter_map(|id| rt.dialogs.remove(&id).map(|p| (id, p.thread)))
            .collect()
    };
    for (id, thread) in closed {
        dialog_closed(app, &thread, id, "Expired: the run moved on".to_owned()).await;
    }
}

/// The engine is waiting on a dialog: decide gates here, ask the owner otherwise.
async fn on_dialog(app: &App, active: Active, request: Value) {
    let attempt = active.attempt;
    let Some(id) = request["id"].as_str().map(str::to_owned) else {
        return warn!("dialog without an id");
    };
    let method = request["method"].as_str().unwrap_or_default().to_owned();
    let title = request["title"].as_str().unwrap_or_default().to_owned();

    if method == "input" && title == discussions::DISCUSS_TITLE {
        let request: Value = request["placeholder"]
            .as_str()
            .and_then(|p| serde_json::from_str(p).ok())
            .unwrap_or_default();
        let answer = discussions::ask(app, &active.thread.bot, &request).await;
        return respond(app, attempt, ui_response(&id, "value", json!(answer))).await;
    }
    if method == "input" && title == team::ASK_TITLE {
        let ask: Value = request["placeholder"]
            .as_str()
            .and_then(|p| serde_json::from_str(p).ok())
            .unwrap_or_default();
        let answer = team::ask(app, attempt.run, &active.thread.bot, &ask).await;
        return respond(app, attempt, ui_response(&id, "value", json!(answer))).await;
    }
    let (kind, tool_call_id) = if method == "input" && title == GATE_TITLE {
        let call: Value = request["placeholder"]
            .as_str()
            .and_then(|p| serde_json::from_str(p).ok())
            .unwrap_or_default();
        let (Some(call_id), Some(tool)) = (call["toolCallId"].as_str(), call["tool"].as_str())
        else {
            let deny = json!("deny:Malformed approval request.");
            return respond(app, attempt, ui_response(&id, "value", deny)).await;
        };
        let input = call["input"].clone();
        // An MCP call is judged, ruled and shown as the tool it calls (DESIGN §11).
        let tool = match input["tool"].as_str() {
            Some(inner) if tool == "mcp" => format!("mcp:{inner}"),
            _ => tool.to_owned(),
        };
        let gate_call = gate::Call {
            attempt,
            tool_call_id: call_id,
            tool: &tool,
            input: &input,
            in_computer: call["inComputer"].as_bool().unwrap_or(false),
            helpers_gated: call["helpersGated"].as_bool().unwrap_or(false),
        };
        let verdict = gate::decide(&app.db, &app.system1, &gate_call)
            .await
            .unwrap_or_else(|e| {
                warn!("deciding a tool call: {e}");
                gate::Verdict::Deny(
                    "OrphusBot could not check this call, so it was blocked.".into(),
                )
            });
        match verdict {
            gate::Verdict::Allow => {
                if tool == "roundtable" {
                    discussions::posted(app, attempt.run, &active.thread.bot, &input).await;
                }
                return respond(app, attempt, ui_response(&id, "value", json!("allow"))).await;
            }
            gate::Verdict::Deny(reason) => {
                let value = json!(format!("deny:{reason}"));
                return respond(app, attempt, ui_response(&id, "value", value)).await;
            }
            gate::Verdict::Ask { uncertain } => (
                DialogKind::Approval {
                    tool,
                    input,
                    uncertain,
                },
                Some(call_id.to_owned()),
            ),
        }
    } else {
        let message = ["message", "placeholder", "prefill"]
            .iter()
            .find_map(|k| request[*k].as_str())
            .map(str::to_owned);
        let options = request["options"]
            .as_array()
            .map(|o| {
                o.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();
        let kind = if method == "confirm" && title == TAKEOVER_TITLE {
            DialogKind::Takeover {
                reason: message.unwrap_or_default(),
            }
        } else {
            DialogKind::Question {
                method,
                title,
                message,
                options,
            }
        };
        (kind, None)
    };

    let pending = Pending {
        attempt,
        thread: active.thread.clone(),
        takeover: matches!(kind, DialogKind::Takeover { .. }),
        tool_call_id,
    };
    lock(&app.rt).dialogs.insert(id.clone(), pending);
    let news = device::RunNews::Dialog {
        id: &id,
        kind: &kind,
    };
    device::run_news(app, attempt.run, news).await;
    let dialog = Dialog {
        id,
        run: attempt.run,
        kind,
    };
    push_dialog(app, &active.thread.bot, &dialog).await;
    record(app, &active.thread, ThreadEvent::DialogOpened { dialog }).await;
}

/// The bot's display name, for pushes.
async fn bot_name(app: &App, slug: &str) -> String {
    bots::get(&app.db, slug)
        .await
        .ok()
        .flatten()
        .map_or_else(|| slug.to_owned(), |b| b.name)
}

/// A card that needs the owner goes to the phone too (PRD B-CLI-05).
async fn push_dialog(app: &App, slug: &str, dialog: &Dialog) {
    let name = bot_name(app, slug).await;
    let (title, body, tags) = match &dialog.kind {
        DialogKind::Approval { tool, input, .. } => (
            format!("{name} asks to use {tool}"),
            serde_json::to_string(input).unwrap_or_default(),
            "raising_hand",
        ),
        DialogKind::Question { title, message, .. } => (
            format!("{name} has a question"),
            message.clone().unwrap_or_else(|| title.clone()),
            "question",
        ),
        DialogKind::Takeover { reason } => (
            format!("{name} needs you on its screen"),
            reason.clone(),
            "computer",
        ),
    };
    app.notifier.send(notify::Push {
        title,
        body,
        priority: 4,
        tags,
        bot: Some(slug),
    });
}

/// The node's sender if it is working on exactly this attempt.
fn node_for(app: &App, attempt: Attempt) -> Option<mpsc::Sender<ToNode>> {
    let rt = lock(&app.rt);
    let active = rt.current(attempt)?;
    rt.nodes.get(&active.node).map(|n| n.tx.clone())
}

/// Every model a connected node can use, with the nodes that have it.
async fn models(State(app): State<Shared>) -> Json<Value> {
    let rt = lock(&app.rt);
    let mut all: std::collections::BTreeMap<&str, Vec<&str>> = Default::default();
    for link in rt.nodes.values() {
        for m in &link.models {
            all.entry(m).or_default().push(&link.name);
        }
    }
    let list: Vec<Value> = all
        .into_iter()
        .map(|(id, nodes)| json!({ "id": id, "nodes": nodes }))
        .collect();
    Json(json!(list))
}

/// Sends every client the node list.
fn publish_nodes(app: &App) {
    let event = nodes_event(&lock(&app.rt));
    publish(app, None, None, event);
}

fn nodes_event(rt: &Runtime) -> ThreadEvent {
    let mut nodes: Vec<NodeView> = rt
        .nodes
        .values()
        .map(|n| {
            let held = n.candidate().held_back();
            NodeView {
                name: n.name.clone(),
                ready: held.is_none(),
                note: held.map(str::to_owned),
            }
        })
        .collect();
    nodes.sort_by(|a, b| a.name.cmp(&b.name));
    ThreadEvent::Nodes { nodes }
}

/// Places the next queued run on a node (DESIGN §6.3), or says why it waits.
async fn dispatch(app: &App) {
    let queued = match runs::queued(&app.db).await {
        Ok(queued) => queued,
        Err(e) => return warn!("listing queued runs: {e}"),
    };
    for q in queued {
        let bot = match bots::get(&app.db, &q.bot).await {
            Ok(Some(bot)) => bot,
            Ok(None) => continue,
            Err(e) => return warn!("reading a bot: {e}"),
        };
        let placed = if bot.disabled {
            placement::Placement::Wait {
                why: format!("{} is disabled", bot.name),
            }
        } else {
            let candidates: Vec<placement::Candidate> = lock(&app.rt)
                .nodes
                .values()
                .map(NodeLink::candidate)
                .collect();
            if bot.computer == "e2b" {
                placement::choose_for_cloud(&candidates)
            } else {
                let home = match db::computer_home(&app.db, &q.bot).await {
                    Ok(home) => home,
                    Err(e) => return warn!("reading where the computer is: {e}"),
                };
                placement::choose(&candidates, home.as_deref())
            }
        };
        match placed {
            placement::Placement::Run { node, why } => start(app, q.run, &bot, node, why).await,
            placement::Placement::Wait { why } => {
                let changed =
                    lock(&app.rt).waiting.insert(q.run, why.clone()).as_ref() != Some(&why);
                if changed {
                    let event = ThreadEvent::RunQueued {
                        run: q.run,
                        waiting: Some(why),
                    };
                    publish(app, None, Some(&bot.slug), event);
                }
            }
        }
    }
}

/// Leases `run` to `node` and starts it there.
async fn start(app: &App, run: i64, bot: &bots::Bot, node: String, why: &str) {
    let Some(link) = lock(&app.rt).nodes.get(&node).cloned() else {
        return;
    };
    let claimed = match runs::claim(&app.db, run, &node).await {
        Ok(Some(c)) => c,
        Ok(None) => return,
        Err(e) => return warn!("claiming a run: {e}"),
    };
    let thread = match db::run_thread(&app.db, run).await {
        Ok(thread) => thread,
        Err(e) => return warn!("finding the run's thread: {e}"),
    };
    let mut spec = bot.spec();
    if claimed.prompt.contains(room::ROOM_NOTE) {
        room::quick(&mut spec);
    }
    if let Some((session, name)) = discussions::session(&app.db, run, &bot.slug).await {
        spec.session = Some(session);
        spec.name = Some(name);
    } else if let Some(session) = fleets::session(&claimed.prompt, &bot.slug, run) {
        spec.session = Some(session);
    }
    if bot.computer == "e2b" {
        match app.e2b.computer(&app.db, &bot.slug).await {
            Ok(computer) => spec.e2b = Some(computer),
            Err(e) => {
                let error = format!("Couldn't get its E2B computer: {e:#}");
                warn!(run, "{error}");
                if let Err(e) =
                    runs::finish(&app.db, run, claimed.fence, Outcome::Failed, Some(&error)).await
                {
                    warn!("finishing run: {e}");
                }
                lock(&app.rt).waiting.remove(&run);
                return run_ended(app, &thread, run, RunOutcome::Failed, Some(error)).await;
            }
        }
    } else if let Err(e) = db::set_computer_home(&app.db, &bot.slug, &node).await {
        warn!("recording where the computer is: {e}");
    }
    let attempt = Attempt {
        run,
        fence: claimed.fence,
    };
    {
        let mut rt = lock(&app.rt);
        let active = Active {
            attempt,
            node: node.clone(),
            thread,
        };
        rt.active.insert(run, active);
        rt.waiting.remove(&run);
    }
    info!(run, bot = %bot.slug, %node, why, "placed run");
    let event = ThreadEvent::RunStarted {
        run,
        resumed: claimed.resumed,
        node: Some(node),
        why: Some(why.to_owned()),
    };
    publish(app, None, Some(&bot.slug), event);
    device::run_news(app, run, device::RunNews::Running).await;
    spec.mcp = connections::for_bot(app, &bot.slug).await;
    spec.instructions.push_str(bots::HOUSE_STYLE);
    // Bots are told about Google only when the node running this has it set up.
    let google_ready = link.google;
    if let Ok(roster) = bots::all(&app.db).await
        && let Some(note) = team::roster_note(
            &roster,
            &bot.slug,
            &connections::names_by_bot(&app.db).await,
            google_ready,
        )
    {
        spec.instructions.push_str(&note);
    }
    // The date and time, in the owner's time zone: models don't know them, and
    // in the message (not the instructions) so the engine isn't restarted for it.
    let now = time_line(chrono::Utc::now(), profiles::current(&app.db).await.tz);
    let start = ToNode::StartTurn {
        attempt,
        text: format!("{now}\n\n{}", claimed.prompt),
        resumed: claimed.resumed,
        bot: Box::new(spec),
        files: attachments::for_run(&app.db, run).await,
        fleets: fleets::all(&app.db).await,
    };
    if link.tx.send(start).await.is_err() {
        // The link closed under us; its disconnect handler re-queues the run.
        warn!(run, "node went away while starting a run");
    }
}

/// "(It's Tuesday 20 October 2026, 22:15 in Europe/London.)"
fn time_line(now: chrono::DateTime<chrono::Utc>, tz: chrono_tz::Tz) -> String {
    format!(
        "(It's {} in {tz}.)",
        now.with_timezone(&tz).format("%A %-d %B %Y, %H:%M")
    )
}

/// Renews leases for connected nodes and re-queues lapsed ones, forever.
async fn reconcile_forever(app: Shared) {
    let mut tick = tokio::time::interval(RECONCILE_EVERY);
    loop {
        tick.tick().await;
        let names: Vec<String> = lock(&app.rt).nodes.keys().cloned().collect();
        for name in names {
            if let Err(e) = runs::renew(&app.db, &name).await {
                warn!("renewing leases: {e}");
            }
        }
        match runs::release(&app.db, None).await {
            Ok(released) if !released.is_empty() => {
                info!(count = released.len(), "lease lapsed; re-queued");
                announce_released(&app, released).await;
                dispatch(&app).await;
            }
            Ok(_) => {}
            Err(e) => warn!("sweeping leases: {e}"),
        }
    }
}

async fn announce_released(app: &App, released: Vec<runs::Released>) {
    for r in released {
        lock(&app.rt).active.remove(&r.run);
        expire_dialogs(app, r.run).await;
        let thread = match db::run_thread(&app.db, r.run).await {
            Ok(thread) => thread,
            Err(e) => {
                warn!("finding a run's thread: {e}");
                continue;
            }
        };
        if r.failed {
            let error = Some("The bot lost its node too many times".to_owned());
            run_ended(app, &thread, r.run, RunOutcome::Failed, error).await;
        } else {
            lock(&app.rt).waiting.remove(&r.run);
            let event = ThreadEvent::RunQueued {
                run: r.run,
                waiting: None,
            };
            publish(app, None, Some(&thread.bot), event);
        }
    }
}

#[derive(Deserialize)]
struct EventsQuery {
    after: Option<i64>,
}

/// Replays persisted events after the client's last one, then streams live.
/// Browsers resume automatically: `EventSource` resends the last `id` as `Last-Event-ID`.
async fn events(
    State(app): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<EventsQuery>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, StatusCode> {
    let after = headers
        .get("last-event-id")
        .and_then(|v| v.to_str().ok()?.parse().ok())
        .or(q.after)
        .unwrap_or(0);

    // Subscribe before reading history so nothing falls between the two.
    let mut rx = app.live.subscribe();
    let history = db::since(&app.db, after).await.map_err(|e| {
        warn!("reading history: {e}");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    let current = current_state(&app).await.map_err(|e| {
        warn!("reading run state: {e}");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    let stream = async_stream::stream! {
        let mut last = after;
        for (id, bot, event) in history {
            last = id;
            yield Ok(sse(Some(id), Some(bot), event));
        }
        for (bot, event) in current {
            yield Ok(sse(None, bot, event));
        }
        loop {
            match rx.recv().await {
                Ok(Live { id: Some(id), .. }) if id <= last => continue,
                Ok(Live { id, bot, event }) => {
                    if let Some(id) = id { last = id; }
                    yield Ok(sse(id, bot, event));
                }
                // ponytail: a slow client that lags just reconnects and replays from Last-Event-ID.
                Err(_) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(20))))
}

/// The live-only state a newly connected client needs: node status and the active run.
async fn current_state(app: &App) -> sqlx::Result<Vec<(Option<String>, ThreadEvent)>> {
    let (nodes, waiting) = {
        let rt = lock(&app.rt);
        (nodes_event(&rt), rt.waiting.clone())
    };
    let mut out = vec![(None, nodes)];
    let runs = sqlx::query!(
        r#"select r.id, r.status::text as "status!", r.attempts, r.node, b.slug from run r
           join thread t on t.id = r.thread_id join bot b on b.id = t.bot_id
           where r.status in ('queued', 'running')"#
    )
    .fetch_all(&app.db)
    .await?;
    for r in runs {
        let event = if r.status == "running" {
            ThreadEvent::RunStarted {
                run: r.id,
                resumed: r.attempts > 1,
                node: r.node,
                why: None,
            }
        } else {
            ThreadEvent::RunQueued {
                run: r.id,
                waiting: waiting.get(&r.id).cloned(),
            }
        };
        out.push((Some(r.slug), event));
    }
    Ok(out)
}

fn sse(id: Option<i64>, bot: Option<String>, event: ThreadEvent) -> Event {
    let data = serde_json::to_string(&Envelope { bot, event }).unwrap_or_default();
    let ev = Event::default().data(data);
    match id {
        Some(id) => ev.id(id.to_string()),
        None => ev,
    }
}

/// The node's WebSocket. The node proves who it is inside the link, by
/// signing the server's challenge (DESIGN §4.1).
async fn node_link(State(app): State<Shared>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| run_node(app, socket))
}

async fn run_node(app: Shared, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();

    // Challenge first: the node signs the nonce, or enrols with a one-time code.
    let Ok(nonce) = auth::random_token() else {
        return warn!("no randomness for a node challenge");
    };
    let challenge = ToNode::Challenge {
        nonce: nonce.clone(),
    };
    let Ok(json) = serde_json::to_string(&challenge) else {
        return;
    };
    if sink.send(WsMessage::Text(json.into())).await.is_err() {
        return;
    }
    let answer = match tokio::time::timeout(Duration::from_secs(10), stream.next()).await {
        Ok(Some(Ok(WsMessage::Text(t)))) => serde_json::from_str::<FromNode>(&t).ok(),
        _ => None,
    };
    let name = match answer {
        Some(FromNode::Hello {
            node,
            version,
            signature,
        }) => match nodes::verify(&app.db, &node, &nonce, &signature).await {
            Ok(true) => {
                info!(%node, %version, "node connected");
                node
            }
            Ok(false) => return warn!(%node, "node failed the challenge; is it enrolled?"),
            Err(e) => return warn!("checking a node's key: {e}"),
        },
        Some(FromNode::Enrol {
            code,
            node,
            public_key,
        }) => {
            let error = nodes::enrol(&app.db, &code, &node, &public_key).await.err();
            match &error {
                None => info!(%node, "node enrolled"),
                Some(e) => warn!(%node, "enrolment refused: {e}"),
            }
            if let Ok(json) = serde_json::to_string(&ToNode::Enrolled { error }) {
                let _ = sink.send(WsMessage::Text(json.into())).await;
            }
            let _ = sink.close().await;
            return;
        }
        _ => return warn!("node didn't answer the challenge"),
    };

    let (tx, mut rx) = mpsc::channel::<ToNode>(16);
    let kick = Arc::new(Notify::new());
    let (screen_tx, mut screen_rx) = mpsc::channel::<Vec<u8>>(256);
    let (conn, replaced) = {
        let mut rt = lock(&app.rt);
        rt.next_conn += 1;
        let conn = rt.next_conn;
        rt.active.retain(|_, a| a.node != name);
        let link = NodeLink {
            conn,
            name: name.clone(),
            tx,
            kick: kick.clone(),
            screen: screen_tx,
            load: 0,
            on_battery: false,
            quiet: false,
            models: Vec::new(),
            google: false,
        };
        (conn, rt.nodes.insert(name.clone(), link))
    };
    if replaced.is_some() {
        warn!(node = %name, "node reconnected; the newer link wins");
    }
    // Anything leased under this name belongs to an earlier connection that can't finish it.
    match runs::release(&app.db, Some(&name)).await {
        Ok(released) => announce_released(&app, released).await,
        Err(e) => warn!("releasing runs from an earlier connection: {e}"),
    }
    publish_nodes(&app);
    dispatch(&app).await;

    let mut ping = tokio::time::interval(Duration::from_secs(30));
    let mut last_heard = Instant::now();
    loop {
        tokio::select! {
            cmd = rx.recv() => {
                let Some(cmd) = cmd else { break };
                let Ok(json) = serde_json::to_string(&cmd) else { continue };
                if sink.send(WsMessage::Text(json.into())).await.is_err() { break; }
            }
            frame = stream.next() => {
                let Some(Ok(frame)) = frame else { break };
                last_heard = Instant::now();
                match frame {
                    WsMessage::Text(text) => match serde_json::from_str::<FromNode>(&text) {
                        Ok(msg) => on_node_message(&app, &name, msg).await,
                        Err(e) => warn!("unreadable frame from node: {e}"),
                    },
                    WsMessage::Binary(data) => screens::from_node(&app, &data).await,
                    _ => {}
                }
            }
            frame = screen_rx.recv() => {
                let Some(frame) = frame else { break };
                if sink.send(WsMessage::Binary(frame.into())).await.is_err() { break; }
            }
            _ = kick.notified() => {
                warn!(node = %name, "node removed; dropping its link");
                break;
            }
            _ = ping.tick() => {
                if last_heard.elapsed() > NODE_SILENCE_LIMIT {
                    warn!(node = %name, "node went silent");
                    break;
                }
                if sink.send(WsMessage::Ping(Default::default())).await.is_err() { break; }
            }
        }
    }

    // Only clean up if this connection is still the current one.
    let was_current = {
        let mut rt = lock(&app.rt);
        let current = rt.nodes.get(&name).is_some_and(|n| n.conn == conn);
        if current {
            rt.nodes.remove(&name);
            rt.active.retain(|_, a| a.node != name);
            // Dropping the senders ends the viewers' streams on this node.
            rt.screens.retain(|_, (node, _)| *node != name);
        }
        current
    };
    if was_current {
        info!(node = %name, "node disconnected");
        publish_nodes(&app);
        match runs::release(&app.db, Some(&name)).await {
            Ok(released) => announce_released(&app, released).await,
            Err(e) => warn!("re-queueing runs: {e}"),
        }
    }
}

async fn on_node_message(app: &App, node: &str, msg: FromNode) {
    // Frames for an attempt that's no longer current (a fenced-off retry) are dropped.
    let current = |attempt: Attempt| lock(&app.rt).current(attempt).cloned();
    match msg {
        FromNode::Models { models, google } => {
            info!(
                node,
                count = models.len(),
                google,
                "node reported its models"
            );
            if let Some(link) = lock(&app.rt).nodes.get_mut(node) {
                link.models = models;
                link.google = google;
            }
        }
        FromNode::Heartbeat {
            load,
            on_battery,
            quiet,
        } => {
            let changed = {
                let mut rt = lock(&app.rt);
                let Some(link) = rt.nodes.get_mut(node) else {
                    return;
                };
                let before = link.candidate().held_back();
                (link.load, link.on_battery, link.quiet) = (load, on_battery, quiet);
                before != link.candidate().held_back()
            };
            if changed {
                publish_nodes(app);
            }
            dispatch(app).await;
        }
        FromNode::Hello { .. } | FromNode::Enrol { .. } => {}
        FromNode::ScreenClosed { stream, error } => screens::closed(app, stream, error).await,
        FromNode::Extracted { id, text, error } => capture::extracted(app, id, text, error).await,
        FromNode::Delta { attempt, text } => {
            if let Some(a) = current(attempt) {
                let event = ThreadEvent::Delta {
                    run: attempt.run,
                    text,
                };
                publish(app, None, Some(&a.thread.bot), event);
            }
        }
        FromNode::Usage {
            attempt,
            provider,
            model,
            input,
            output,
            cache_read,
            cache_write,
            cost_micros,
        } => {
            if let Some(a) = current(attempt) {
                let tokens = [input, output, cache_read, cache_write];
                usage::record(
                    app,
                    attempt.run,
                    &a.thread.bot,
                    &provider,
                    &model,
                    tokens,
                    cost_micros,
                )
                .await;
            }
        }
        FromNode::Reply { attempt, text } => {
            if let Some(a) = current(attempt) {
                let event = ThreadEvent::Message {
                    role: Role::Assistant,
                    text,
                };
                record(app, &a.thread, event).await;
            }
        }
        FromNode::TurnEnded { attempt, error } => {
            let Some(a) = current(attempt) else {
                return warn!(?attempt, "turn ended for an attempt that is not current");
            };
            let (outcome, shown) = match error {
                Some(_) => (Outcome::Failed, RunOutcome::Failed),
                None => (Outcome::Completed, RunOutcome::Completed),
            };
            let finished = runs::finish(
                &app.db,
                attempt.run,
                attempt.fence,
                outcome,
                error.as_deref(),
            )
            .await;
            match finished {
                Ok(true) => {
                    lock(&app.rt).active.remove(&attempt.run);
                    run_ended(app, &a.thread, attempt.run, shown, error).await;
                    dispatch(app).await;
                }
                Ok(false) => warn!(?attempt, "run already ended or moved on"),
                Err(e) => warn!("finishing run: {e}"),
            }
        }
        FromNode::Dialog { attempt, request } => {
            if let Some(a) = current(attempt) {
                on_dialog(app, a, request).await;
            }
        }
        FromNode::Artifact {
            attempt,
            name,
            data,
        } => {
            if let Some(a) = current(attempt) {
                artifacts::shared(app, &a.thread, attempt.run, &name, &data).await;
            }
        }
        FromNode::ToolDone {
            attempt,
            tool_call_id,
            ok,
            result,
        } => {
            if current(attempt).is_some()
                && let Err(e) = gate::tool_done(&app.db, attempt, &tool_call_id, ok, &result).await
            {
                warn!("recording tool result: {e}");
            }
        }
    }
}

async fn run_ended(
    app: &App,
    thread: &db::Thread,
    run: i64,
    outcome: RunOutcome,
    error: Option<String>,
) {
    expire_dialogs(app, run).await;
    tickets::run_ended(&app.db, run, outcome).await;
    team::answered(app, run, outcome, error.as_deref()).await;
    let news = match outcome {
        RunOutcome::Completed => device::RunNews::Done,
        RunOutcome::Failed => device::RunNews::Failed,
        RunOutcome::Cancelled => device::RunNews::Cancelled,
    };
    device::run_news(app, run, news).await;
    push_run_end(app, thread, run, outcome, error.as_deref()).await;
    let event = ThreadEvent::RunEnded {
        run,
        outcome,
        error,
    };
    record(app, thread, event).await;
    discussions::advance(app).await;
}

/// Failures always reach the phone; finished work does when the owner didn't
/// start it from a chat (a routine, a ticket or the wearable).
async fn push_run_end(
    app: &App,
    thread: &db::Thread,
    run: i64,
    outcome: RunOutcome,
    error: Option<&str>,
) {
    let unattended = sqlx::query_scalar!(
        r#"select (routine_id is not null or ticket_id is not null or device_id is not null) as "u!"
           from run where id = $1"#,
        run
    )
    .fetch_optional(&app.db)
    .await
    .ok()
    .flatten()
    .unwrap_or(false);
    let name = bot_name(app, &thread.bot).await;
    let (title, body, priority, tags) = match outcome {
        RunOutcome::Failed => (
            format!("{name}'s task failed"),
            error.unwrap_or("It stopped with an error.").to_owned(),
            4,
            "warning",
        ),
        RunOutcome::Completed if unattended => (
            format!("{name} finished"),
            "Its result is in its thread.".to_owned(),
            3,
            "white_check_mark",
        ),
        _ => return,
    };
    app.notifier.send(notify::Push {
        title,
        body,
        priority,
        tags,
        bot: Some(&thread.bot),
    });
}

fn publish(app: &App, id: Option<i64>, bot: Option<&str>, event: ThreadEvent) {
    let event = app.secrets.redact_event(event);
    // No receivers is normal when no browser is open.
    let bot = bot.map(str::to_owned);
    let _ = app.live.send(Live { id, bot, event });
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // A poisoned lock only means another task panicked mid-update; the state is still usable.
    m.lock().unwrap_or_else(|p| p.into_inner())
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    #[test]
    fn the_time_line_is_in_the_owners_zone() {
        let at = chrono::Utc
            .with_ymd_and_hms(2026, 10, 20, 21, 15, 0)
            .unwrap();
        assert_eq!(
            super::time_line(at, chrono_tz::Europe::London),
            "(It's Tuesday 20 October 2026, 22:15 in Europe/London.)"
        );
    }
}
