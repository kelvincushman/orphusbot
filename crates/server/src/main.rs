//! orphusbot-server, milestone M1: durable runs for one thread, one bot, one node.
//!
//! A browser posts a message; it becomes a run in Postgres. When a node is
//! connected the run is leased to it, and the node's streamed reply comes back
//! to every open browser over Server-Sent Events. If the node drops or its
//! lease lapses, the run goes back to the queue and resumes on the next node
//! (DESIGN §3.2, §3.3).

mod auth;
mod db;
mod gate;
mod links;
mod nodes;
mod runs;
mod screens;

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
    Attempt, Dialog, DialogKind, FromNode, Role, RunOutcome, ThreadEvent, ToNode,
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

/// An event on its way to browsers; `seq` is set for persisted events.
#[derive(Clone)]
struct Live {
    seq: Option<i64>,
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
}

/// A dialog the engine is blocked on.
#[derive(Clone)]
struct Pending {
    attempt: Attempt,
    /// Set for approval gates: the tool call being decided.
    tool_call_id: Option<String>,
    /// A takeover request: its yes and no read "Done" and "Couldn't help".
    takeover: bool,
}

/// In-memory view of the link. Postgres stays the source of truth for runs;
/// `active` only lets the server drop stale frames without a query per delta.
#[derive(Default)]
struct Runtime {
    node: Option<NodeLink>,
    next_conn: u64,
    active: Option<Attempt>,
    /// Open dialogs by Orphus request id.
    dialogs: HashMap<String, Pending>,
    /// Open screen viewers by stream number.
    screens: HashMap<u64, mpsc::Sender<screens::ToViewer>>,
    next_screen: u64,
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
    let app = Arc::new(App {
        db,
        live,
        rt: Mutex::default(),
        auth,
        ui_dir,
    });
    tokio::spawn(reconcile_forever(app.clone()));

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
        .route("/node", get(node_link))
        .merge(api)
        .fallback_service(ServeDir::new(&app.ui_dir))
        .with_state(app)
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
    text: String,
}

/// Stores the message, then queues a run, joins the waiting one, or steers the
/// running one (B-RUN-01).
async fn send_message(
    State(app): State<Shared>,
    Json(msg): Json<NewMessage>,
) -> Result<StatusCode, ApiError> {
    let text = msg.text.trim().to_owned();
    if text.is_empty() || text.chars().count() > MAX_MESSAGE_CHARS {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Message must be 1 to 32,000 characters",
        ));
    }

    let event = ThreadEvent::Message {
        role: Role::User,
        text: text.clone(),
    };
    let seq = db::append(&app.db, &event)
        .await
        .map_err(|e| internal("storing message", e))?;
    publish(&app, Some(seq), event);

    match runs::submit(&app.db, &text)
        .await
        .map_err(|e| internal("queueing run", e))?
    {
        Submitted::Queued(run) => {
            publish(&app, None, ThreadEvent::RunQueued { run });
            dispatch(&app).await;
        }
        Submitted::Joined(_) => {}
        Submitted::Steer { run, fence } => {
            let attempt = Attempt { run, fence };
            if let Some(tx) = node_for(&app, attempt) {
                // If this fails the node is going away; the run is re-queued and the text is
                // already in the thread for the resumed attempt to see.
                let _ = tx.send(ToNode::Steer { attempt, text }).await;
            }
        }
    }
    Ok(StatusCode::ACCEPTED)
}

/// Stops the thread's active run (B-RUN-03).
async fn cancel_run(State(app): State<Shared>) -> Result<StatusCode, ApiError> {
    let Some((run, fence)) = runs::cancel_active(&app.db)
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
        if rt.active == Some(attempt) {
            rt.active = None;
        }
    }
    run_ended(&app, run, RunOutcome::Cancelled, None).await;
    dispatch(&app).await;
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize)]
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
    let Some(pending) = lock(&app.rt).dialogs.remove(&answer.id) else {
        return Err((StatusCode::GONE, "That question is no longer open"));
    };
    let id = answer.id.clone();
    let (response, outcome) = match (&pending.tool_call_id, answer.decision.as_deref()) {
        (Some(call), Some(decision @ ("allow" | "always" | "deny"))) => {
            let allow = decision != "deny";
            let always = decision == "always";
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
    respond(&app, pending.attempt, response).await;
    dialog_closed(&app, id, outcome).await;
    Ok(StatusCode::ACCEPTED)
}

async fn respond(app: &App, attempt: Attempt, response: Value) {
    if let Some(tx) = node_for(app, attempt) {
        let _ = tx.send(ToNode::DialogResponse { attempt, response }).await;
    }
}

async fn dialog_closed(app: &App, id: String, outcome: String) {
    let event = ThreadEvent::DialogClosed { id, outcome };
    match db::append(&app.db, &event).await {
        Ok(seq) => publish(app, Some(seq), event),
        Err(e) => warn!("storing dialog close: {e}"),
    }
}

/// Closes every open dialog for `run`: its attempt ended, so nobody is waiting.
async fn expire_dialogs(app: &App, run: i64) {
    let ids: Vec<String> = {
        let mut rt = lock(&app.rt);
        let ids: Vec<String> = rt
            .dialogs
            .iter()
            .filter(|(_, p)| p.attempt.run == run)
            .map(|(id, _)| id.clone())
            .collect();
        for id in &ids {
            rt.dialogs.remove(id);
        }
        ids
    };
    for id in ids {
        dialog_closed(app, id, "Expired: the run moved on".to_owned()).await;
    }
}

/// The engine is waiting on a dialog: decide gates here, ask the owner otherwise.
async fn on_dialog(app: &App, attempt: Attempt, request: Value) {
    let Some(id) = request["id"].as_str().map(str::to_owned) else {
        return warn!("dialog without an id");
    };
    let method = request["method"].as_str().unwrap_or_default().to_owned();
    let title = request["title"].as_str().unwrap_or_default().to_owned();

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
        let gate_call = gate::Call {
            attempt,
            tool_call_id: call_id,
            tool,
            input: &input,
        };
        let verdict = gate::decide(&app.db, &gate_call).await.unwrap_or_else(|e| {
            warn!("deciding a tool call: {e}");
            gate::Verdict::Deny("OrphusBot could not check this call, so it was blocked.".into())
        });
        match verdict {
            gate::Verdict::Allow => {
                return respond(app, attempt, ui_response(&id, "value", json!("allow"))).await;
            }
            gate::Verdict::Deny(reason) => {
                let value = json!(format!("deny:{reason}"));
                return respond(app, attempt, ui_response(&id, "value", value)).await;
            }
            gate::Verdict::Ask { uncertain } => (
                DialogKind::Approval {
                    tool: tool.to_owned(),
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
        takeover: matches!(kind, DialogKind::Takeover { .. }),
        tool_call_id,
    };
    lock(&app.rt).dialogs.insert(id.clone(), pending);
    let dialog = Dialog {
        id,
        run: attempt.run,
        kind,
    };
    let event = ThreadEvent::DialogOpened { dialog };
    match db::append(&app.db, &event).await {
        Ok(seq) => publish(app, Some(seq), event),
        Err(e) => warn!("storing dialog: {e}"),
    }
}

/// The node's sender if it is working on exactly this attempt.
fn node_for(app: &App, attempt: Attempt) -> Option<mpsc::Sender<ToNode>> {
    let rt = lock(&app.rt);
    if rt.active == Some(attempt) {
        rt.node.as_ref().map(|n| n.tx.clone())
    } else {
        None
    }
}

/// Leases the next queued run to the connected node, if it is free.
async fn dispatch(app: &App) {
    let node = {
        let rt = lock(&app.rt);
        match (&rt.node, rt.active) {
            (Some(node), None) => node.clone(),
            _ => return,
        }
    };
    let claimed = match runs::claim(&app.db, &node.name).await {
        Ok(Some(c)) => c,
        Ok(None) => return,
        Err(e) => return warn!("claiming a run: {e}"),
    };
    let attempt = Attempt {
        run: claimed.run,
        fence: claimed.fence,
    };
    lock(&app.rt).active = Some(attempt);
    publish(
        app,
        None,
        ThreadEvent::RunStarted {
            run: claimed.run,
            resumed: claimed.resumed,
        },
    );
    let start = ToNode::StartTurn {
        attempt,
        text: claimed.prompt,
        resumed: claimed.resumed,
    };
    if node.tx.send(start).await.is_err() {
        // The link closed under us; its disconnect handler re-queues the run.
        warn!(run = claimed.run, "node went away while starting a run");
    }
}

/// Renews leases for the connected node and re-queues lapsed ones, forever.
async fn reconcile_forever(app: Shared) {
    let mut tick = tokio::time::interval(RECONCILE_EVERY);
    loop {
        tick.tick().await;
        let node = lock(&app.rt).node.as_ref().map(|n| n.name.clone());
        if let Some(name) = node
            && let Err(e) = runs::renew(&app.db, &name).await
        {
            warn!("renewing leases: {e}");
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
        {
            let mut rt = lock(&app.rt);
            if rt.active.is_some_and(|a| a.run == r.run) {
                rt.active = None;
            }
        }
        expire_dialogs(app, r.run).await;
        if r.failed {
            let error = Some("The bot lost its node too many times".to_owned());
            run_ended(app, r.run, RunOutcome::Failed, error).await;
        } else {
            publish(app, None, ThreadEvent::RunQueued { run: r.run });
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
        for (seq, event) in history {
            last = seq;
            yield Ok(sse(Some(seq), &event));
        }
        for event in &current {
            yield Ok(sse(None, event));
        }
        loop {
            match rx.recv().await {
                Ok(Live { seq: Some(seq), .. }) if seq <= last => continue,
                Ok(Live { seq, event }) => {
                    if let Some(seq) = seq { last = seq; }
                    yield Ok(sse(seq, &event));
                }
                // ponytail: a slow client that lags just reconnects and replays from Last-Event-ID.
                Err(_) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(20))))
}

/// The live-only state a newly connected client needs: node status and the active run.
async fn current_state(app: &App) -> sqlx::Result<Vec<ThreadEvent>> {
    let node = lock(&app.rt).node.as_ref().map(|n| n.name.clone());
    let mut out = vec![ThreadEvent::NodeStatus {
        online: node.is_some(),
        node,
    }];
    let active = sqlx::query!(
        r#"select id, status::text as "status!", attempts from run
           where thread_id = $1 and status in ('queued', 'running')"#,
        db::THREAD
    )
    .fetch_optional(&app.db)
    .await?;
    if let Some(r) = active {
        out.push(if r.status == "running" {
            ThreadEvent::RunStarted {
                run: r.id,
                resumed: r.attempts > 1,
            }
        } else {
            ThreadEvent::RunQueued { run: r.id }
        });
    }
    Ok(out)
}

fn sse(seq: Option<i64>, event: &ThreadEvent) -> Event {
    let data = serde_json::to_string(event).unwrap_or_default();
    let ev = Event::default().data(data);
    match seq {
        Some(seq) => ev.id(seq.to_string()),
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
        rt.active = None;
        let link = NodeLink {
            conn,
            name: name.clone(),
            tx,
            kick: kick.clone(),
            screen: screen_tx,
        };
        (conn, rt.node.replace(link))
    };
    if replaced.is_some() {
        warn!("a second node connected; the newest one wins (M1 supports one node)");
    }
    // Anything leased under this name belongs to an earlier connection that can't finish it.
    match runs::release(&app.db, Some(&name)).await {
        Ok(released) => announce_released(&app, released).await,
        Err(e) => warn!("releasing runs from an earlier connection: {e}"),
    }
    publish(
        &app,
        None,
        ThreadEvent::NodeStatus {
            online: true,
            node: Some(name.clone()),
        },
    );
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
                        Ok(msg) => on_node_message(&app, msg).await,
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
        let current = rt.node.as_ref().is_some_and(|n| n.conn == conn);
        if current {
            rt.node = None;
            rt.active = None;
            // Dropping the senders ends every viewer's stream.
            rt.screens.clear();
        }
        current
    };
    if was_current {
        info!(node = %name, "node disconnected");
        publish(
            &app,
            None,
            ThreadEvent::NodeStatus {
                online: false,
                node: None,
            },
        );
        match runs::release(&app.db, Some(&name)).await {
            Ok(released) => announce_released(&app, released).await,
            Err(e) => warn!("re-queueing runs: {e}"),
        }
    }
}

async fn on_node_message(app: &App, msg: FromNode) {
    let active = lock(&app.rt).active;
    match msg {
        FromNode::Hello { .. } | FromNode::Enrol { .. } => {}
        FromNode::ScreenClosed { stream, error } => screens::closed(app, stream, error).await,
        FromNode::Delta { attempt, text } if active == Some(attempt) => {
            let event = ThreadEvent::Delta {
                run: attempt.run,
                text,
            };
            publish(app, None, event);
        }
        FromNode::Reply { attempt, text } if active == Some(attempt) => {
            let event = ThreadEvent::Message {
                role: Role::Assistant,
                text,
            };
            match db::append(&app.db, &event).await {
                Ok(seq) => publish(app, Some(seq), event),
                Err(e) => warn!("storing reply: {e}"),
            }
        }
        FromNode::TurnEnded { attempt, error } if active == Some(attempt) => {
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
                    lock(&app.rt).active = None;
                    run_ended(app, attempt.run, shown, error).await;
                    dispatch(app).await;
                }
                Ok(false) => warn!(?attempt, "run already ended or moved on"),
                Err(e) => warn!("finishing run: {e}"),
            }
        }
        FromNode::Dialog { attempt, request } if active == Some(attempt) => {
            on_dialog(app, attempt, request).await;
        }
        FromNode::ToolDone {
            attempt,
            tool_call_id,
            ok,
            result,
        } if active == Some(attempt) => {
            if let Err(e) = gate::tool_done(&app.db, attempt, &tool_call_id, ok, &result).await {
                warn!("recording tool result: {e}");
            }
        }
        other => warn!(
            ?other,
            "ignoring a frame for an attempt that is not current"
        ),
    }
}

async fn run_ended(app: &App, run: i64, outcome: RunOutcome, error: Option<String>) {
    expire_dialogs(app, run).await;
    let event = ThreadEvent::RunEnded {
        run,
        outcome,
        error,
    };
    match db::append(&app.db, &event).await {
        Ok(seq) => publish(app, Some(seq), event),
        Err(e) => warn!("storing run end: {e}"),
    }
}

fn publish(app: &App, seq: Option<i64>, event: ThreadEvent) {
    // No receivers is normal when no browser is open.
    let _ = app.live.send(Live { seq, event });
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // A poisoned lock only means another task panicked mid-update; the state is still usable.
    m.lock().unwrap_or_else(|p| p.into_inner())
}
