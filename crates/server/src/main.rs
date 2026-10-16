//! orphusbot-server, milestone M0: one thread, one bot, one node.
//!
//! A browser posts a message, the server stores it and hands the turn to the
//! connected node, and the node's streamed reply comes back to every open
//! browser over Server-Sent Events (DESIGN §3, PRD M0).

mod db;

use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, bail};
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Form, Json, Router};
use futures_util::{SinkExt, Stream, StreamExt};
use orphusbot_proto::{FromNode, Role, ThreadEvent, ToNode};
use serde::Deserialize;
use sqlx::PgPool;
use subtle::ConstantTimeEq;
use tokio::sync::{broadcast, mpsc};
use tracing::{info, warn};

const UI_HTML: &str = include_str!("ui.html");
const COOKIE: &str = "orphusbot_session";
const MAX_MESSAGE_CHARS: usize = 32_000;
const MIN_TOKEN_CHARS: usize = 16;

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
}

/// The one node link and the one turn in flight.
/// `turn` is `Some(0)` while a send is claiming the slot, then the turn id.
#[derive(Default)]
struct Runtime {
    node: Option<NodeLink>,
    next_conn: u64,
    turn: Option<i64>,
}

struct App {
    db: PgPool,
    live: broadcast::Sender<Live>,
    // ponytail: one std Mutex for all link and turn state; per-bot state when there is more than one bot.
    rt: Mutex<Runtime>,
    ui_token: String,
    node_token: String,
}

type Shared = Arc<App>;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let bind = std::env::var("ORPHUSBOT_BIND").unwrap_or_else(|_| "127.0.0.1:7480".into());
    let db_url = std::env::var("DATABASE_URL").context("DATABASE_URL is not set")?;
    let ui_token = token_from_env("ORPHUSBOT_UI_TOKEN")?;
    let node_token = token_from_env("ORPHUSBOT_NODE_TOKEN")?;

    let db = PgPool::connect(&db_url)
        .await
        .context("connecting to Postgres")?;
    sqlx::migrate!()
        .run(&db)
        .await
        .context("running migrations")?;

    let (live, _) = broadcast::channel(1024);
    let app = Arc::new(App {
        db,
        live,
        rt: Mutex::default(),
        ui_token,
        node_token,
    });

    let router = Router::new()
        .route("/", get(|| async { Html(UI_HTML) }))
        .route("/login", post(login))
        .route("/api/messages", post(send_message))
        .route("/api/events", get(events))
        .route("/node", get(node_link))
        .with_state(app);

    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .with_context(|| format!("binding {bind}"))?;
    info!("listening on http://{bind}");
    axum::serve(listener, router).await?;
    Ok(())
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

// ponytail: the cookie holds the shared UI token itself; passkeys and real sessions replace this in M1 (PRD B-CLI-06).
fn signed_in(app: &App, headers: &HeaderMap) -> bool {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|kv| kv.trim().split_once('='))
        .any(|(k, v)| k == COOKIE && tokens_match(v, &app.ui_token))
}

#[derive(Deserialize)]
struct LoginForm {
    token: String,
}

async fn login(State(app): State<Shared>, Form(form): Form<LoginForm>) -> Response {
    if !tokens_match(&form.token, &app.ui_token) {
        return (StatusCode::UNAUTHORIZED, "Wrong token").into_response();
    }
    let cookie = format!("{COOKIE}={}; HttpOnly; SameSite=Strict; Path=/", form.token);
    (
        StatusCode::SEE_OTHER,
        [(header::SET_COOKIE, cookie), (header::LOCATION, "/".into())],
    )
        .into_response()
}

#[derive(Deserialize)]
struct NewMessage {
    text: String,
}

async fn send_message(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(msg): Json<NewMessage>,
) -> Result<StatusCode, (StatusCode, &'static str)> {
    if !signed_in(&app, &headers) {
        return Err((StatusCode::UNAUTHORIZED, "Sign in first"));
    }
    let text = msg.text.trim().to_owned();
    if text.is_empty() || text.chars().count() > MAX_MESSAGE_CHARS {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Message must be 1 to 32,000 characters",
        ));
    }

    // Claim the turn slot before writing anything, so two sends can't both start a turn.
    let node_tx = {
        let mut rt = lock(&app.rt);
        let Some(NodeLink { tx, .. }) = rt.node.clone() else {
            return Err((StatusCode::SERVICE_UNAVAILABLE, "No node is connected"));
        };
        if rt.turn.is_some() {
            return Err((
                StatusCode::CONFLICT,
                "The bot is still working on the last message",
            ));
        }
        rt.turn = Some(0);
        tx
    };

    let event = ThreadEvent::Message {
        role: Role::User,
        text: text.clone(),
    };
    let seq = match db::append(&app.db, &event).await {
        Ok(seq) => seq,
        Err(e) => {
            lock(&app.rt).turn = None;
            warn!("storing message: {e}");
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "Could not store the message",
            ));
        }
    };
    publish(&app, Some(seq), event);

    // The user message's sequence number doubles as the turn id.
    lock(&app.rt).turn = Some(seq);
    publish(&app, None, ThreadEvent::TurnStarted { turn: seq });
    if node_tx
        .send(ToNode::StartTurn { turn: seq, text })
        .await
        .is_err()
    {
        end_turn(&app, seq, Some("The node disconnected".into())).await;
    }
    Ok(StatusCode::ACCEPTED)
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
    if !signed_in(&app, &headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
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
    let status = {
        let rt = lock(&app.rt);
        let node = rt.node.as_ref().map(|n| n.name.clone());
        (
            ThreadEvent::NodeStatus {
                online: node.is_some(),
                node,
            },
            rt.turn.filter(|t| *t > 0),
        )
    };

    let stream = async_stream::stream! {
        let mut last = after;
        for (seq, event) in history {
            last = seq;
            yield Ok(sse(Some(seq), &event));
        }
        yield Ok(sse(None, &status.0));
        if let Some(turn) = status.1 {
            yield Ok(sse(None, &ThreadEvent::TurnStarted { turn }));
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

fn sse(seq: Option<i64>, event: &ThreadEvent) -> Event {
    let data = serde_json::to_string(event).unwrap_or_default();
    let ev = Event::default().data(data);
    match seq {
        Some(seq) => ev.id(seq.to_string()),
        None => ev,
    }
}

/// The node's WebSocket. Authenticated by bearer token before the upgrade.
async fn node_link(
    State(app): State<Shared>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    if !token.is_some_and(|t| tokens_match(t, &app.node_token)) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    ws.on_upgrade(move |socket| run_node(app, socket))
}

async fn run_node(app: Shared, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();

    // The first frame must say who the node is.
    let name = match stream.next().await {
        Some(Ok(WsMessage::Text(t))) => match serde_json::from_str(&t) {
            Ok(FromNode::Hello { node, version }) => {
                info!(%node, %version, "node connected");
                node
            }
            _ => return warn!("node sent something other than hello first"),
        },
        _ => return,
    };

    let (tx, mut rx) = mpsc::channel::<ToNode>(16);
    let (conn, replaced) = {
        let mut rt = lock(&app.rt);
        rt.next_conn += 1;
        let conn = rt.next_conn;
        (
            conn,
            rt.node.replace(NodeLink {
                conn,
                name: name.clone(),
                tx,
            }),
        )
    };
    if replaced.is_some() {
        warn!("a second node connected; the newest one wins (M0 supports one node)");
    }
    publish(
        &app,
        None,
        ThreadEvent::NodeStatus {
            online: true,
            node: Some(name.clone()),
        },
    );

    let writer = tokio::spawn(async move {
        while let Some(cmd) = rx.recv().await {
            let Ok(json) = serde_json::to_string(&cmd) else {
                continue;
            };
            if sink.send(WsMessage::Text(json.into())).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(frame)) = stream.next().await {
        let WsMessage::Text(text) = frame else {
            continue;
        };
        match serde_json::from_str::<FromNode>(&text) {
            Ok(msg) => on_node_message(&app, msg).await,
            Err(e) => warn!("unreadable frame from node: {e}"),
        }
    }
    writer.abort();

    // Only clear state if this connection is still the current one.
    let (was_current, turn) = {
        let mut rt = lock(&app.rt);
        let current = rt.node.as_ref().is_some_and(|n| n.conn == conn);
        if current {
            rt.node = None;
        }
        (current, rt.turn.filter(|t| *t > 0))
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
        if let Some(turn) = turn {
            // ponytail: M0 fails the turn; M1 recovers it with leases and fences (DESIGN §3.3).
            end_turn(&app, turn, Some("The node disconnected".into())).await;
        }
    }
}

async fn on_node_message(app: &App, msg: FromNode) {
    let current = lock(&app.rt).turn;
    match msg {
        FromNode::Hello { .. } => {}
        FromNode::Delta { turn, text } if current == Some(turn) => {
            publish(app, None, ThreadEvent::Delta { turn, text });
        }
        FromNode::Reply { turn, text } if current == Some(turn) => {
            let event = ThreadEvent::Message {
                role: Role::Assistant,
                text,
            };
            match db::append(&app.db, &event).await {
                Ok(seq) => publish(app, Some(seq), event),
                Err(e) => warn!("storing reply: {e}"),
            }
        }
        FromNode::TurnEnded { turn, error } if current == Some(turn) => {
            end_turn(app, turn, error).await;
        }
        other => warn!(?other, "ignoring a frame for a turn that is not running"),
    }
}

async fn end_turn(app: &App, turn: i64, error: Option<String>) {
    {
        let mut rt = lock(&app.rt);
        if rt.turn != Some(turn) {
            return;
        }
        rt.turn = None;
    }
    let event = ThreadEvent::TurnEnded { turn, error };
    match db::append(&app.db, &event).await {
        Ok(seq) => publish(app, Some(seq), event),
        Err(e) => warn!("storing turn end: {e}"),
    }
}

fn publish(app: &App, seq: Option<i64>, event: ThreadEvent) {
    // No receivers is normal when no browser is open.
    let _ = app.live.send(Live { seq, event });
}

fn lock(m: &Mutex<Runtime>) -> std::sync::MutexGuard<'_, Runtime> {
    // A poisoned lock only means another task panicked mid-update; the state is still usable.
    m.lock().unwrap_or_else(|p| p.into_inner())
}
