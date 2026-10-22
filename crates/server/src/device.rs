//! The wearable's device channel and duplex habitat (DESIGN §9.2, §9.3).
//!
//! The phone app talks to `/api/device/*` with `X-Device-Id` + `X-Device-Token`,
//! as in `wearable/docs/SERVER.md`, so the app needs no change: pairing uses a
//! one-time code from OrphusBot in the app's "bearer" field.
//!
//! **Uplink.** A deliberate button capture (`/api/device/text`, not overheard)
//! becomes a ticket, triaged by System 1. If System 1 is sure it's safe to
//! start, it starts; otherwise the wrist gets a "should I start?" ask.
//! Overheard text is ambient capture (M4) and is not kept.
//!
//! **Downlink.** Every signal is a `habitat_message`. Informs (queued, running,
//! done, error) play and don't block; a newer state for the same subject
//! supersedes the old one. Asks go **one at a time**, so a blind tap or
//! double tap always means exactly one thing; the next is sent when it's
//! answered, dismissed or expired. A tap can only approve what the wearer
//! already knows: a reversible file change on a run they started from the
//! button in the last 10 minutes. Anything else is "seen" on the wrist and
//! stays on the phone and desktop. Unanswered asks expire and stop pulsing.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use orphusbot_device::alert;
use orphusbot_proto::DialogKind;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tracing::{info, warn};

use crate::auth::{digest, random_token};
use crate::{Answer, App, Shared, internal, lock, resolve_dialog, tickets};

/// A button press makes the next transcript a deliberate capture for this long.
/// The phone listens in 30 s windows and can take another 90 s to transcribe one.
const EXPLICIT_GRACE: Duration = Duration::from_secs(180);
/// After a tap on a question, the next transcript is its spoken answer for this long.
const ANSWER_WINDOW: Duration = Duration::from_secs(120);
const QUEUE_MAX: usize = 32;
const MAX_TEXT_CHARS: usize = 4_000;
/// The same transcript from the same device within this long is a resend.
const RESEND_WINDOW: Duration = Duration::from_secs(60);

/// Commands waiting for a device's next poll, each with the message it belongs to.
type Queue = Vec<(Option<i64>, Value)>;

/// Per-device state that doesn't need to survive a restart.
#[derive(Default)]
pub struct Devices {
    /// Commands waiting for the app's next poll, with the message each belongs to.
    queues: Mutex<HashMap<String, Queue>>,
    /// When each device's button last asked for a capture.
    intent: Mutex<HashMap<String, Instant>>,
    /// A question the wearer tapped to answer aloud: (message, dialog id, when).
    answering: Mutex<HashMap<String, (i64, String, Instant)>>,
    /// Token bucket for `/text`: (tokens, last refill).
    text_rate: Mutex<HashMap<String, (f64, Instant)>>,
    /// Each device's last transcript and when, to drop one sent twice.
    last_text: Mutex<HashMap<String, (String, Instant)>>,
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": message }))).into_response()
}

/// The device the request comes from, by `X-Device-Id` + `X-Device-Token`.
async fn authed(app: &App, headers: &HeaderMap) -> Result<String, (StatusCode, &'static str)> {
    let get = |h: &str| headers.get(h).and_then(|v| v.to_str().ok());
    let (Some(id), Some(token)) = (get("x-device-id"), get("x-device-token")) else {
        return Err((
            StatusCode::UNAUTHORIZED,
            "device auth required (X-Device-Id + X-Device-Token)",
        ));
    };
    let ok = sqlx::query_scalar!(
        "update device set last_seen_at = now() where id = $1 and token_hash = $2 returning id",
        id,
        digest(token)
    )
    .fetch_optional(&app.db)
    .await
    .map_err(|e| {
        warn!("checking a device: {e}");
        (StatusCode::INTERNAL_SERVER_ERROR, "server error")
    })?;
    ok.ok_or((StatusCode::UNAUTHORIZED, "invalid device credentials"))
}

// --- Pairing ---------------------------------------------------------------

/// A one-time pairing code (10 minutes) for the app's "bearer" field.
pub async fn pairing_code(State(app): State<Shared>) -> Result<Json<Value>, crate::ApiError> {
    let code = random_token().map_err(|e| internal("making a pairing code", e))?;
    let stored = async {
        sqlx::query!("delete from device_pairing_code where expires_at <= now()")
            .execute(&app.db)
            .await?;
        sqlx::query!(
            "insert into device_pairing_code (code_hash, expires_at) values ($1, now() + interval '10 minutes')",
            digest(&code)
        )
        .execute(&app.db)
        .await
    };
    stored
        .await
        .map_err(|e| internal("storing a pairing code", e))?;
    Ok(Json(json!({ "code": code, "expires_in_secs": 600 })))
}

#[derive(Deserialize)]
pub struct Register {
    #[serde(rename = "devId")]
    dev_id: String,
    label: Option<String>,
}

/// `POST /api/device/register`: the app sends a pairing code as its bearer and
/// gets the device's pairing token. Registering the same `devId` again replaces it.
pub async fn register(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(body): Json<Register>,
) -> Response {
    let code = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    let used = match code {
        Some(code) => sqlx::query!(
            "delete from device_pairing_code where code_hash = $1 and expires_at > now()",
            digest(code.trim())
        )
        .execute(&app.db)
        .await
        .map(|d| d.rows_affected()),
        None => Ok(0),
    };
    match used {
        Ok(1) => {}
        Ok(_) => {
            return error(
                StatusCode::UNAUTHORIZED,
                "pairing code wrong, used or expired",
            );
        }
        Err(e) => {
            warn!("pairing a device: {e}");
            return error(StatusCode::INTERNAL_SERVER_ERROR, "server error");
        }
    }
    let valid = (1..=64).contains(&body.dev_id.len())
        && body
            .dev_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "._:-".contains(c));
    if !valid {
        return error(
            StatusCode::BAD_REQUEST,
            "devId must be 1-64 of letters, digits, . _ : -",
        );
    }
    let Ok(token) = random_token() else {
        return error(StatusCode::INTERNAL_SERVER_ERROR, "server error");
    };
    let label: String = body.label.unwrap_or_default().chars().take(60).collect();
    let saved = sqlx::query!(
        "insert into device (id, label, token_hash) values ($1, $2, $3)
         on conflict (id) do update set label = excluded.label, token_hash = excluded.token_hash",
        body.dev_id,
        label,
        digest(&token)
    )
    .execute(&app.db)
    .await;
    if let Err(e) = saved {
        warn!("saving a device: {e}");
        return error(StatusCode::INTERNAL_SERVER_ERROR, "server error");
    }
    info!(device = %body.dev_id, "wearable paired");
    Json(json!({ "ok": true, "devId": body.dev_id, "pairingToken": token })).into_response()
}

/// The owner's wearables and their recent signals, for the Wearable view.
pub async fn list(State(app): State<Shared>) -> Result<Json<Value>, crate::ApiError> {
    let devices = sqlx::query!(
        r#"select id, label, hands_free, captures_to, last_seen_at::text as last_seen from device order by id"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing devices", e))?;
    let messages = sqlx::query!(
        r#"select id, device_id, kind, cue, subject, state, outcome, created_at::text as "at!"
           from habitat_message order by id desc limit 30"#
    )
    .fetch_all(&app.db)
    .await
    .map_err(|e| internal("listing habitat messages", e))?;
    Ok(Json(json!({
        "devices": devices.into_iter().map(|d| json!({
            "id": d.id, "label": d.label, "hands_free": d.hands_free,
            "captures_to": d.captures_to, "last_seen": d.last_seen,
        })).collect::<Vec<_>>(),
        "messages": messages.into_iter().map(|m| json!({
            "id": m.id, "device": m.device_id, "kind": m.kind, "cue": m.cue, "subject": m.subject,
            "state": m.state, "outcome": m.outcome, "at": m.at,
        })).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
pub struct Route {
    id: String,
    to: String,
}

/// `POST /api/devices/route`: where a device's deliberate captures go, `inbox` or `room`.
pub async fn route(
    State(app): State<Shared>,
    Json(r): Json<Route>,
) -> Result<StatusCode, crate::ApiError> {
    if !matches!(r.to.as_str(), "inbox" | "room") {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send captures to inbox or room",
        ));
    }
    let done = sqlx::query!(
        "update device set captures_to = $2 where id = $1",
        r.id,
        r.to
    )
    .execute(&app.db)
    .await
    .map_err(|e| internal("routing captures", e))?;
    if done.rows_affected() == 0 {
        return Err((StatusCode::NOT_FOUND, "No such device"));
    }
    Ok(StatusCode::NO_CONTENT)
}

// --- Device-facing ---------------------------------------------------------

#[derive(Deserialize)]
pub struct Event {
    kind: String,
    code: Option<String>,
    at: Option<i64>,
}

/// `POST /api/device/event`: heartbeats and button codes. A tap or double tap
/// answers the one ask on the wrist (DESIGN §9.3.3).
pub async fn event(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(ev): Json<Event>,
) -> Response {
    let device = match authed(&app, &headers).await {
        Ok(d) => d,
        Err((status, why)) => return error(status, why),
    };
    if ev.kind == "button" {
        info!(%device, code = ev.code.as_deref().unwrap_or(""), "wearable button");
    }
    match (ev.kind.as_str(), ev.code.as_deref()) {
        ("heartbeat", _) => return Json(json!({ "ok": true, "at": ev.at })).into_response(),
        ("button", Some("AGENT_REQUEST" | "NOTE" | "REPLY")) => {
            lock(&app.devices.intent).insert(device, Instant::now());
        }
        ("button", Some(code @ ("SINGLE" | "DOUBLE"))) => {
            if let Err(e) = answer(&app, &device, code == "SINGLE").await {
                warn!("answering on the wearable: {e}");
            }
        }
        // Newer firmware: a tap answers the ask if there is one, otherwise it's
        // push-to-talk; a double tap says no. Like the app, it leaves a press open.
        ("button", Some("CAPTURE_TOGGLE")) => {
            match answer(&app, &device, true).await {
                Ok(true) => {}
                Ok(false) => {
                    lock(&app.devices.intent).insert(device, Instant::now());
                }
                // Not knowing whether an ask is waiting, open nothing.
                Err(e) => warn!("answering on the wearable: {e}"),
            }
        }
        ("button", Some("CANCEL")) => {
            if let Err(e) = answer(&app, &device, false).await {
                warn!("answering on the wearable: {e}");
            }
        }
        // Hold is power and a triple tap re-links; the firmware handles them.
        (
            "button",
            Some(
                "LONG"
                | "LINK_RECOVER"
                | "POWER_OFF_ARMED"
                | "POWER_OFF_ABORTED"
                | "POWER_OFF_COMMITTED",
            ),
        ) => {}
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "kind must be button (with a known code) or heartbeat",
            );
        }
    }
    Json(json!({ "ok": true })).into_response()
}

#[derive(Deserialize)]
pub struct Text {
    text: String,
    #[serde(default)]
    overheard: bool,
    /// The speaker's label from the phone, kept apart from the words.
    #[serde(default)]
    talker: String,
}

/// `POST /api/device/text`: a transcript made on the phone (DESIGN §9.3.5).
pub async fn text(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(body): Json<Text>,
) -> Response {
    let device = match authed(&app, &headers).await {
        Ok(d) => d,
        Err((status, why)) => return error(status, why),
    };
    if !take_token(&app, &device) {
        return error(StatusCode::TOO_MANY_REQUESTS, "rate limited");
    }
    let text: String = body.text.trim().chars().take(MAX_TEXT_CHARS).collect();
    if text.is_empty() {
        return error(StatusCode::BAD_REQUEST, "text is empty");
    }
    let chat_id = format!("device:{device}");
    if resent(&app, &device, &text) {
        info!(%device, chars = text.chars().count(), "wearable text: resent, dropped");
        return Json(json!({ "ok": true, "chatId": chat_id, "filed": "duplicate" }))
            .into_response();
    }
    // The client may say it's ambient, but can't make it deliberate: that needs a recent press.
    let pressed = lock(&app.devices.intent)
        .get(&device)
        .is_some_and(|at| at.elapsed() < EXPLICIT_GRACE);
    if body.overheard || !pressed {
        // Ambient: never a task or a reply. Kept for mining only while hands-free is on (DESIGN §10).
        let filed = match crate::capture::overheard(&app, &device, &body.talker, &text).await {
            Ok(true) => "capture",
            Ok(false) => "ignored",
            Err(e) => {
                warn!("capturing: {e}");
                "ignored"
            }
        };
        info!(%device, filed, overheard = body.overheard, pressed, chars = text.chars().count(), "wearable text");
        return Json(json!({ "ok": true, "chatId": chat_id, "filed": filed })).into_response();
    }
    // Where it goes is read before the press is used up, so a failed lookup can be resent.
    let to_room = match sqlx::query_scalar!(
        r#"select captures_to = 'room' as "room!" from device where id = $1"#,
        device
    )
    .fetch_one(&app.db)
    .await
    {
        Ok(room) => room,
        Err(e) => {
            warn!("reading where captures go: {e}");
            forget_text(&app, &device);
            return error(StatusCode::INTERNAL_SERVER_ERROR, "server error");
        }
    };
    info!(%device, to_room, chars = text.chars().count(), "wearable text: deliberate");
    lock(&app.devices.intent).remove(&device);
    // A tap on a question opened the mic: this is its answer, if the question is still open.
    let answering = lock(&app.devices.answering).remove(&device);
    if let Some((msg, dialog, at)) = answering
        && at.elapsed() < ANSWER_WINDOW
    {
        let answered = resolve_dialog(
            &app,
            Answer {
                id: dialog,
                value: Some(text.clone()),
                ..Answer::default()
            },
        )
        .await;
        if answered.is_ok() {
            close(&app.db, msg, "answered", "answered aloud").await;
            return Json(json!({ "ok": true, "chatId": chat_id, "filed": "answer" }))
                .into_response();
        }
    }
    if to_room {
        return match crate::room::from_wearable(&app, &text).await {
            Ok(id) => {
                if let Err(e) = inform(&app, &device, "task_done", &format!("idea:{id}")).await {
                    warn!("telling the wrist an idea was kept: {e}");
                }
                Json(json!({ "ok": true, "chatId": chat_id, "filed": "idea" })).into_response()
            }
            Err(e) => {
                warn!("keeping a wearable idea: {e}");
                forget_text(&app, &device);
                error(StatusCode::INTERNAL_SERVER_ERROR, "server error")
            }
        };
    }
    match wearable_task(&app, &device, &text).await {
        Ok(()) => Json(json!({ "ok": true, "chatId": chat_id, "filed": "task" })).into_response(),
        Err(e) => {
            warn!("filing a wearable task: {e}");
            forget_text(&app, &device);
            error(StatusCode::INTERNAL_SERVER_ERROR, "server error")
        }
    }
}

/// Whether `device` sent this same text within [RESEND_WINDOW]; remembers it either way.
fn resent(app: &App, device: &str, text: &str) -> bool {
    let mut last = lock(&app.devices.last_text);
    let again = last
        .get(device)
        .is_some_and(|(t, at)| t == text && at.elapsed() < RESEND_WINDOW);
    last.insert(device.to_owned(), (text.to_owned(), Instant::now()));
    again
}

/// Filing failed: the phone's resend must get through, as the same press.
fn forget_text(app: &App, device: &str) {
    lock(&app.devices.last_text).remove(device);
    lock(&app.devices.intent).insert(device.to_owned(), Instant::now());
}

/// ~10 at once, then one every 6 s (the reference server's limit).
fn take_token(app: &App, device: &str) -> bool {
    let mut rates = lock(&app.devices.text_rate);
    let (tokens, at) = rates
        .entry(device.to_owned())
        .or_insert((10.0, Instant::now()));
    *tokens = (*tokens + at.elapsed().as_secs_f64() / 6.0).min(10.0);
    *at = Instant::now();
    if *tokens < 1.0 {
        return false;
    }
    *tokens -= 1.0;
    true
}

/// The wearer's spoken task becomes a ticket, routed by System 1 and started.
async fn wearable_task(app: &App, device: &str, text: &str) -> anyhow::Result<()> {
    let title: String = text.chars().take(80).collect();
    let id = sqlx::query_scalar!(
        "insert into ticket (title, body, device_id, bot_id)
         values ($1, $2, $3, (select id from bot where slug = 'inbox')) returning id",
        title,
        text,
        device
    )
    .fetch_one(&app.db)
    .await?;
    let roster = crate::bots::all(&app.db).await.unwrap_or_default();
    let triage = app
        .system1
        .triage_ticket(&app.db, text, &roster, Some(id))
        .await
        .unwrap_or_default();
    if let Some(bot) = &triage.bot {
        sqlx::query!(
            "update ticket set bot_id = (select id from bot where slug = $2), urgency = coalesce($3, urgency),
                    act_now = $4 where id = $1",
            id,
            bot.slug,
            triage.urgency,
            triage.act_now
        )
        .execute(&app.db)
        .await?;
    }
    // The press was the owner's go-ahead (D-056), so the bot starts now; the
    // gate still asks about anything irreversible. A busy bot takes it next
    // (`start_waiting`); anything else that stops it, the wrist asks.
    match tickets::start(app, id).await {
        Ok(()) => {}
        Err((_, tickets::BUSY)) => {
            inform(app, device, "task_queued", &format!("ticket:{id}")).await?
        }
        Err(e) => {
            warn!("starting a wearable ticket: {e:?}");
            ask(
                app,
                device,
                "awaiting_input",
                &format!("ticket:{id}"),
                "start",
            )
            .await?;
        }
    }
    Ok(())
}

/// When `bot` finishes a run, starts the oldest wearable capture that was
/// waiting for it (D-056), unless the owner said no to it or is still being asked.
pub async fn start_waiting(app: &App, bot: &str) {
    let next = sqlx::query_scalar!(
        "select t.id from ticket t join bot b on b.id = t.bot_id
         where b.slug = $1 and t.status = 'todo' and t.device_id is not null
           and t.created_at > now() - interval '1 day'
           and not exists (select 1 from habitat_message m where m.kind = 'ask' and m.subject = 'ticket:' || t.id
                           and m.state in ('queued', 'sent', 'delivered', 'dismissed'))
         order by t.id limit 1",
        bot
    )
    .fetch_optional(&app.db)
    .await;
    match next {
        Ok(Some(id)) => match tickets::start(app, id).await {
            Ok(()) | Err((_, tickets::BUSY)) => {}
            Err(e) => warn!("starting a waiting wearable ticket: {e:?}"),
        },
        Ok(None) => {}
        Err(e) => warn!("finding a waiting wearable ticket: {e}"),
    }
}

/// `POST /api/device/command/poll`: the commands waiting for this wrist.
pub async fn poll(State(app): State<Shared>, headers: HeaderMap) -> Response {
    let device = match authed(&app, &headers).await {
        Ok(d) => d,
        Err((status, why)) => return error(status, why),
    };
    let drained = lock(&app.devices.queues)
        .remove(&device)
        .unwrap_or_default();
    // ponytail: "delivered" means the app took it; its GATT write result (W-3) refines this later.
    let ids: Vec<i64> = drained.iter().filter_map(|(m, _)| *m).collect();
    if !ids.is_empty()
        && let Err(e) = sqlx::query!(
            "update habitat_message set state = 'delivered' where id = any($1) and state = 'sent'",
            &ids
        )
        .execute(&app.db)
        .await
    {
        warn!("marking habitat messages delivered: {e}");
    }
    let commands: Vec<Value> = drained.into_iter().map(|(_, c)| c).collect();
    Json(json!({ "commands": commands })).into_response()
}

#[derive(Deserialize)]
pub struct HandsFree {
    #[serde(rename = "handsFree")]
    hands_free: bool,
}

/// `GET /api/device/hands-free`.
pub async fn hands_free(State(app): State<Shared>, headers: HeaderMap) -> Response {
    let device = match authed(&app, &headers).await {
        Ok(d) => d,
        Err((status, why)) => return error(status, why),
    };
    let on = sqlx::query_scalar!("select hands_free from device where id = $1", device)
        .fetch_one(&app.db)
        .await
        .unwrap_or(false);
    Json(json!({ "handsFree": on })).into_response()
}

/// `POST /api/device/hands-free`.
pub async fn set_hands_free(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(body): Json<HandsFree>,
) -> Response {
    let device = match authed(&app, &headers).await {
        Ok(d) => d,
        Err((status, why)) => return error(status, why),
    };
    let saved = sqlx::query!(
        "update device set hands_free = $2 where id = $1",
        device,
        body.hands_free
    )
    .execute(&app.db)
    .await;
    if saved.is_err() {
        return error(StatusCode::INTERNAL_SERVER_ERROR, "server error");
    }
    Json(json!({ "ok": true, "handsFree": body.hands_free })).into_response()
}

// --- Habitat ---------------------------------------------------------------

fn enqueue(app: &App, device: &str, msg: Option<i64>, cue: &str) {
    let commands = alert(cue);
    let mut queues = lock(&app.devices.queues);
    let queue = queues.entry(device.to_owned()).or_default();
    queue.extend(commands.into_iter().map(|c| (msg, c)));
    let excess = queue.len().saturating_sub(QUEUE_MAX);
    queue.drain(..excess);
}

/// Sends an inform; it supersedes earlier signals about the same subject (§9.3.2).
async fn inform(app: &App, device: &str, cue: &str, subject: &str) -> sqlx::Result<()> {
    sqlx::query!(
        "update habitat_message set state = 'superseded', closed_at = now()
         where device_id = $1 and subject = $2 and kind = 'inform' and state in ('sent', 'delivered')",
        device,
        subject
    )
    .execute(&app.db)
    .await?;
    let id = sqlx::query_scalar!(
        "insert into habitat_message (device_id, kind, cue, subject, state, sent_at)
         values ($1, 'inform', $2, $3, 'sent', now()) returning id",
        device,
        cue,
        subject
    )
    .fetch_one(&app.db)
    .await?;
    enqueue(app, device, Some(id), cue);
    Ok(())
}

/// Queues an ask; it goes to the wrist when nothing else is waiting there (§9.3.2).
async fn ask(app: &App, device: &str, cue: &str, subject: &str, tap: &str) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into habitat_message (device_id, kind, cue, subject, tap) values ($1, 'ask', $2, $3, $4)",
        device,
        cue,
        subject,
        tap
    )
    .execute(&app.db)
    .await?;
    send_next_ask(app, device).await
}

async fn send_next_ask(app: &App, device: &str) -> sqlx::Result<()> {
    let busy: bool = sqlx::query_scalar!(
        r#"select exists (select 1 from habitat_message
                          where device_id = $1 and kind = 'ask' and state in ('sent', 'delivered')) as "b!""#,
        device
    )
    .fetch_one(&app.db)
    .await?;
    if busy {
        return Ok(());
    }
    let next = sqlx::query!(
        "update habitat_message set state = 'sent', sent_at = now()
         where id = (select id from habitat_message where device_id = $1 and kind = 'ask' and state = 'queued'
                     order by id limit 1)
         returning id, cue",
        device
    )
    .fetch_optional(&app.db)
    .await?;
    if let Some(next) = next {
        enqueue(app, device, Some(next.id), &next.cue);
    }
    Ok(())
}

async fn close(db: &PgPool, msg: i64, state: &str, outcome: &str) {
    let closed = sqlx::query!(
        "update habitat_message set state = $2, outcome = $3, closed_at = now() where id = $1",
        msg,
        state,
        outcome
    )
    .execute(db)
    .await;
    if let Err(e) = closed {
        warn!("closing a habitat message: {e}");
    }
}

/// A tap (yes) or double tap (no) answers the one ask on the wrist (§9.3.3).
/// Answers the ask on the wearable, if there is one; false when there wasn't.
async fn answer(app: &App, device: &str, yes: bool) -> sqlx::Result<bool> {
    let current = sqlx::query!(
        "select id, subject, tap from habitat_message
         where device_id = $1 and kind = 'ask' and state in ('sent', 'delivered') order by id limit 1",
        device
    )
    .fetch_optional(&app.db)
    .await?;
    let Some(m) = current else {
        return Ok(false);
    };
    // Stop the amber pulse first, so whatever the answer starts (queued, running) plays after it.
    enqueue(app, device, None, "ack");
    let tap = m.tap.unwrap_or_default();
    let (subject_kind, subject_id) = m.subject.split_once(':').unwrap_or_default();
    let (state, outcome) = match (tap.as_str(), yes) {
        ("start", true) => {
            let started = subject_id.parse().ok();
            match started {
                Some(ticket) if tickets::start(app, ticket).await.is_ok() => {
                    ("answered", "started")
                }
                _ => ("answered", "couldn't start; it's on the board"),
            }
        }
        ("start", false) => ("dismissed", "not started; it stays a ticket"),
        ("approve", yes) if subject_kind == "dialog" => {
            let decision = if yes { "allow" } else { "deny" };
            let answer = Answer {
                id: subject_id.to_owned(),
                decision: Some(decision.to_owned()),
                ..Answer::default()
            };
            match resolve_dialog(app, answer).await {
                Ok(_) => ("answered", if yes { "approved" } else { "denied" }),
                Err(_) => ("expired", "the card had already closed"),
            }
        }
        ("answer", true) => {
            // Opens the mic on the app; the next deliberate transcript answers the question.
            lock(&app.devices.answering).insert(
                device.to_owned(),
                (m.id, subject_id.to_owned(), Instant::now()),
            );
            // The answer is spoken next, so it counts as a press.
            lock(&app.devices.intent).insert(device.to_owned(), Instant::now());
            ("answered", "answering aloud")
        }
        (_, true) => ("answered", "seen; it's on the phone"),
        (_, false) => ("dismissed", "dismissed on the wrist; it's on the phone"),
    };
    close(&app.db, m.id, state, outcome).await;
    if let Err(e) = send_next_ask(app, device).await {
        warn!("sending the next ask: {e}");
    }
    Ok(true)
}

/// What happened to a run, for the wrist that started it.
pub enum RunNews<'a> {
    Queued,
    Running,
    Done,
    Failed,
    Cancelled,
    /// The engine opened a dialog: an approval, a question or a takeover.
    Dialog {
        id: &'a str,
        kind: &'a DialogKind,
    },
}

/// Tells the wrist about a run it started, if it did (§9.3.5 step 4).
pub async fn run_news(app: &App, run: i64, news: RunNews<'_>) {
    let device = sqlx::query!(
        "select device_id, (created_at > now() - interval '10 minutes') as \"recent!\" from run where id = $1",
        run
    )
    .fetch_optional(&app.db)
    .await;
    let Ok(Some(row)) = device else {
        return;
    };
    let Some(device) = row.device_id else {
        return;
    };
    let subject = format!("run:{run}");
    let done = match news {
        RunNews::Queued => inform(app, &device, "task_queued", &subject).await,
        RunNews::Running => inform(app, &device, "task_running", &subject).await,
        RunNews::Done => inform(app, &device, "task_done", &subject).await,
        RunNews::Failed => inform(app, &device, "error", &subject).await,
        RunNews::Cancelled => inform(app, &device, "nop", &subject).await,
        RunNews::Dialog { id, kind } => {
            // A tap may approve only a reversible change the wearer started just now.
            let tap = match kind {
                DialogKind::Approval { tool, .. }
                    if row.recent && matches!(tool.as_str(), "write" | "edit") =>
                {
                    "approve"
                }
                DialogKind::Question { .. } => "answer",
                _ => "ack",
            };
            ask(app, &device, "awaiting_input", &format!("dialog:{id}"), tap).await
        }
    };
    if let Err(e) = done {
        warn!("signalling the wrist: {e}");
    }
}

/// An inform for every paired wrist, such as `budget_warn`.
pub async fn warn_all(app: &App, cue: &str, subject: &str) {
    let devices = sqlx::query_scalar!("select id from device")
        .fetch_all(&app.db)
        .await
        .unwrap_or_default();
    for device in devices {
        if let Err(e) = inform(app, &device, cue, subject).await {
            warn!("signalling the wrist: {e}");
        }
    }
}

/// A dialog closed (answered on the phone or desktop, or expired): its ask on
/// any wrist is no longer live, so stop it and send the next.
pub async fn dialog_settled(app: &App, dialog: &str) {
    let live = sqlx::query!(
        "update habitat_message set state = 'superseded', closed_at = now(), outcome = 'settled elsewhere'
         where subject = $1 and kind = 'ask' and state in ('queued', 'sent', 'delivered')
         returning device_id, (sent_at is not null) as \"was_on_wrist!\"",
        format!("dialog:{dialog}")
    )
    .fetch_all(&app.db)
    .await;
    for row in live.unwrap_or_default() {
        if row.was_on_wrist {
            enqueue(app, &row.device_id, None, "ack");
            if let Err(e) = send_next_ask(app, &row.device_id).await {
                warn!("sending the next ask: {e}");
            }
        }
    }
}

/// What an unanswered ask was about, and the bot a tap on its push opens.
async fn expired_push(app: &App, subject: &str) -> (String, Option<String>) {
    let unanswered = "It wasn't answered on the wearable.".to_owned();
    match subject.split_once(':') {
        Some(("ticket", id)) => {
            let ticket = match id.parse() {
                Ok(id) => tickets::get(&app.db, id).await.ok().flatten(),
                Err(_) => None,
            };
            match ticket {
                Some(t) => {
                    let name = match &t.bot {
                        Some(slug) => crate::bot_name(app, slug).await,
                        None => "a bot".to_owned(),
                    };
                    (
                        format!("“{}” is waiting to start. Ask {name} in its chat.", t.title),
                        t.bot,
                    )
                }
                None => (unanswered, None),
            }
        }
        Some(("dialog", id)) => {
            let bot = lock(&app.rt).dialogs.get(id).map(|p| p.thread.bot.clone());
            ("It's waiting for you in the bot's chat.".to_owned(), bot)
        }
        _ => (unanswered, None),
    }
}

/// Expires asks nobody answered, so the wrist never nags forever (§9.3.4).
pub async fn expire_forever(app: Shared) {
    let mut tick = tokio::time::interval(Duration::from_secs(15));
    loop {
        tick.tick().await;
        let expired = sqlx::query!(
            "update habitat_message set state = 'expired', closed_at = now(), outcome = 'not answered; on the phone'
             where kind = 'ask' and state in ('sent', 'delivered') and sent_at + escalate_after < now()
             returning device_id, subject"
        )
        .fetch_all(&app.db)
        .await;
        match expired {
            Ok(rows) => {
                for row in rows {
                    let (body, bot) = expired_push(&app, &row.subject).await;
                    app.notifier.send(crate::notify::Push {
                        title: "Your wearable asked something".into(),
                        body,
                        priority: 4,
                        tags: "watch",
                        bot: bot.as_deref(),
                    });
                    let device = row.device_id;
                    enqueue(&app, &device, None, "ack");
                    if let Err(e) = send_next_ask(&app, &device).await {
                        warn!("sending the next ask: {e}");
                    }
                }
            }
            Err(e) => warn!("expiring asks: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::tests::{app, call};
    use axum::body::{Body, to_bytes};
    use axum::http::Request;
    use tower::ServiceExt;

    /// A device call with the app's headers; returns status and JSON body.
    async fn device(
        app: &Shared,
        path: &str,
        auth: (&str, &str),
        bearer: Option<&str>,
        body: Value,
    ) -> (StatusCode, Value) {
        let mut req = Request::builder()
            .method("POST")
            .uri(path)
            .header("content-type", "application/json")
            .header("x-device-id", auth.0)
            .header("x-device-token", auth.1);
        if let Some(b) = bearer {
            req = req.header("authorization", format!("Bearer {b}"));
        }
        let res = crate::router(app.clone())
            .oneshot(req.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        let status = res.status();
        let bytes = to_bytes(res.into_body(), 1 << 20).await.unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn paired(app: &Shared, db: &PgPool) -> String {
        let session = crate::auth::create_session(db, None, crate::auth::SESSION)
            .await
            .unwrap();
        let (_, _, code) = call(app, "/api/devices/pairing-code", &session, Some(json!({}))).await;
        let code = code["code"].as_str().unwrap().to_owned();
        let (status, reg) = device(
            app,
            "/api/device/register",
            ("", ""),
            Some(&code),
            json!({ "devId": "wrist-1" }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (again, _) = device(
            app,
            "/api/device/register",
            ("", ""),
            Some(&code),
            json!({ "devId": "wrist-2" }),
        )
        .await;
        assert_eq!(again, StatusCode::UNAUTHORIZED, "a pairing code works once");
        reg["pairingToken"].as_str().unwrap().to_owned()
    }

    fn cues(poll: &Value) -> Vec<String> {
        poll["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                c["cue"]
                    .as_str()
                    .map_or_else(|| c["kind"].as_str().unwrap().to_owned(), str::to_owned)
            })
            .collect()
    }

    #[sqlx::test]
    async fn pairing_and_device_auth(db: PgPool) {
        let app = app(db.clone());
        let token = paired(&app, &db).await;
        let (status, poll) = device(
            &app,
            "/api/device/command/poll",
            ("wrist-1", &token),
            None,
            json!({}),
        )
        .await;
        assert_eq!((status, poll), (StatusCode::OK, json!({ "commands": [] })));
        let (status, _) = device(
            &app,
            "/api/device/command/poll",
            ("wrist-1", "wrong"),
            None,
            json!({}),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[sqlx::test]
    async fn newer_firmware_taps_talk_answer_and_cancel(db: PgPool) {
        let app = app(db.clone());
        let token = paired(&app, &db).await;
        let me = ("wrist-1", token.as_str());
        let press = |code: &'static str| json!({ "kind": "button", "code": code });
        let say = |text: &'static str| json!({ "text": text, "overheard": false });

        // A tap with nothing to answer is push-to-talk.
        let (status, _) =
            device(&app, "/api/device/event", me, None, press("CAPTURE_TOGGLE")).await;
        assert_eq!(status, StatusCode::OK);
        let (_, r) = device(&app, "/api/device/text", me, None, say("book the dentist")).await;
        assert_eq!(r["filed"], "task");
        // The phone sending the same words again makes no second ticket.
        let (_, r) = device(&app, "/api/device/text", me, None, say("book the dentist")).await;
        assert_eq!(r["filed"], "duplicate");

        // With a question on the wearable, a tap answers it and opens nothing.
        sqlx::query!(
            "insert into habitat_message (device_id, kind, cue, subject, tap, state)
             values ('wrist-1', 'ask', 'awaiting_input', 'ticket:1', 'start', 'sent')"
        )
        .execute(&db)
        .await
        .unwrap();
        device(&app, "/api/device/event", me, None, press("CAPTURE_TOGGLE")).await;
        let answered: Option<String> =
            sqlx::query_scalar!("select outcome from habitat_message where kind = 'ask'")
                .fetch_one(&db)
                .await
                .unwrap();
        assert!(answered.is_some());
        let (_, r) = device(&app, "/api/device/text", me, None, say("and buy milk")).await;
        assert_eq!(r["filed"], "ignored");

        // A tap on a question to answer aloud lets the next words through.
        sqlx::query!(
            "insert into habitat_message (device_id, kind, cue, subject, tap, state)
             values ('wrist-1', 'ask', 'awaiting_input', 'dialog:q-1', 'answer', 'sent')"
        )
        .execute(&db)
        .await
        .unwrap();
        device(&app, "/api/device/event", me, None, press("CAPTURE_TOGGLE")).await;
        let (_, r) = device(&app, "/api/device/text", me, None, say("Thursday works")).await;
        assert_ne!(r["filed"], "ignored", "the spoken answer is deliberate");

        // A double tap with nothing to answer leaves the press open, as the app does.
        sqlx::query!("update habitat_message set state = 'answered' where kind = 'ask'")
            .execute(&db)
            .await
            .unwrap();
        device(&app, "/api/device/event", me, None, press("CAPTURE_TOGGLE")).await;
        device(&app, "/api/device/event", me, None, press("CANCEL")).await;
        let (_, r) = device(&app, "/api/device/text", me, None, say("order cable clips")).await;
        assert_eq!(r["filed"], "task");

        // Sent to the Ideas Room, a press keeps an idea instead of making a task.
        sqlx::query!("update habitat_message set state = 'answered' where kind = 'ask'")
            .execute(&db)
            .await
            .unwrap();
        sqlx::query!("update device set captures_to = 'room'")
            .execute(&db)
            .await
            .unwrap();
        // If keeping it fails, the phone's resend goes through as the same press.
        sqlx::query!("alter table room_idea add constraint test_refuse check (false) not valid")
            .execute(&db)
            .await
            .unwrap();
        device(&app, "/api/device/event", me, None, press("CAPTURE_TOGGLE")).await;
        let (status, _) = device(
            &app,
            "/api/device/text",
            me,
            None,
            say("a quoting app for sparks"),
        )
        .await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        sqlx::query!("alter table room_idea drop constraint test_refuse")
            .execute(&db)
            .await
            .unwrap();
        let (_, r) = device(
            &app,
            "/api/device/text",
            me,
            None,
            say("a quoting app for sparks"),
        )
        .await;
        assert_eq!(r["filed"], "idea");
        let title: String = sqlx::query_scalar!("select title from room_idea")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(title, "a quoting app for sparks");

        // Power and re-link codes are the firmware's own.
        let (status, _) = device(&app, "/api/device/event", me, None, press("LINK_RECOVER")).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[sqlx::test]
    async fn a_press_starts_the_task_and_a_busy_bot_takes_it_next(db: PgPool) {
        let app = app(db.clone());
        let token = paired(&app, &db).await;
        let me = ("wrist-1", token.as_str());
        let say = |text: &'static str| json!({ "text": text, "overheard": false });
        let press = |code: &'static str| json!({ "kind": "button", "code": code });

        // No button press first: it's ambient, and not kept.
        let (_, r) = device(&app, "/api/device/text", me, None, say("buy milk")).await;
        assert_eq!(r["filed"], "ignored");

        // A press is the go-ahead: the ticket starts, its run carries the device.
        device(&app, "/api/device/event", me, None, press("AGENT_REQUEST")).await;
        let (_, r) = device(
            &app,
            "/api/device/text",
            me,
            None,
            say("compare e-bike batteries"),
        )
        .await;
        assert_eq!(r["filed"], "task");
        let run_device: Option<String> = sqlx::query_scalar!("select device_id from run")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(run_device.as_deref(), Some("wrist-1"));
        let (_, poll) = device(&app, "/api/device/command/poll", me, None, json!({})).await;
        let got = cues(&poll);
        assert!(
            got.contains(&"led_pattern".to_owned()),
            "task_queued: {got:?}"
        );
        assert!(
            !got.contains(&"awaiting_input".to_owned()),
            "no start ask: {got:?}"
        );

        // The bot is busy, so the next one waits, with no question anywhere.
        device(&app, "/api/device/event", me, None, press("AGENT_REQUEST")).await;
        let (_, r) = device(&app, "/api/device/text", me, None, say("book the dentist")).await;
        assert_eq!(r["filed"], "task");
        let (_, poll) = device(&app, "/api/device/command/poll", me, None, json!({})).await;
        let got = cues(&poll);
        assert!(
            !got.contains(&"awaiting_input".to_owned()),
            "no start ask: {got:?}"
        );
        let asks = sqlx::query_scalar!(
            r#"select count(*) as "n!" from habitat_message where kind = 'ask'"#
        )
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(asks, 0);

        // When the bot finishes, the waiting one starts by itself.
        sqlx::query!("update run set status = 'completed'")
            .execute(&db)
            .await
            .unwrap();
        start_waiting(&app, "inbox").await;
        let statuses: Vec<String> =
            sqlx::query_scalar!(r#"select status::text as "s!" from ticket order by id"#)
                .fetch_all(&db)
                .await
                .unwrap();
        assert_eq!(statuses, ["doing", "doing"]);
        let runs =
            sqlx::query_scalar!(r#"select count(*) as "n!" from run where device_id = 'wrist-1'"#)
                .fetch_one(&db)
                .await
                .unwrap();
        assert_eq!(runs, 2);

        // An unanswered question about a ticket says what it was and opens its bot.
        let (body, bot) = expired_push(&app, "ticket:2").await;
        assert!(body.contains("book the dentist"), "{body}");
        assert_eq!(bot.as_deref(), Some("inbox"));
    }
}
