//! Watching and taking over a bot's screen (DESIGN §4.4, PRD B-CMP-05).
//!
//! The browser's VNC client opens `/api/screen` (a WebSocket, signed in like
//! everything under `/api`). The server relays it over the node link as binary
//! frames tagged with a stream number, and the node pipes it into the bot's
//! computer. Clients never connect to a node, and the computer publishes no port.

use axum::extract::State;
use axum::extract::ws::{CloseFrame, Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use orphusbot_proto::{ToNode, screen_frame, split_screen_frame};
use tokio::sync::mpsc;
use tracing::warn;

use crate::{App, Shared, lock};

/// Bytes for a viewer, or the reason its stream ended.
pub type ToViewer = Result<Vec<u8>, String>;

pub async fn open(State(app): State<Shared>, ws: WebSocketUpgrade) -> Response {
    // noVNC asks for the "binary" subprotocol.
    ws.protocols(["binary"])
        .on_upgrade(move |socket| relay(app, socket))
}

async fn relay(app: Shared, socket: WebSocket) {
    let (mut sink, mut source) = socket.split();
    // ponytail: a viewer that reads slowly slows the whole node link; per-stream flow control if it bites.
    let (to_viewer, mut from_node) = mpsc::channel::<ToViewer>(256);
    let (stream, link) = {
        let mut rt = lock(&app.rt);
        rt.next_screen += 1;
        let stream = rt.next_screen;
        rt.screens.insert(stream, to_viewer);
        (stream, rt.node.clone())
    };
    let mut ended = "The screen closed".to_owned();
    match &link {
        None => ended = "No node is connected".into(),
        Some(link) if link.tx.send(ToNode::ScreenOpen { stream }).await.is_ok() => loop {
            tokio::select! {
                data = from_node.recv() => match data {
                    Some(Ok(data)) => if sink.send(WsMessage::Binary(data.into())).await.is_err() { break },
                    Some(Err(reason)) => { ended = reason; break }
                    None => break,
                },
                msg = source.next() => match msg {
                    Some(Ok(WsMessage::Binary(data))) => {
                        if link.screen.send(screen_frame(stream, &data)).await.is_err() { break }
                    }
                    Some(Ok(WsMessage::Close(_)) | Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
            }
        },
        Some(_) => ended = "The node went away".into(),
    }
    lock(&app.rt).screens.remove(&stream);
    if let Some(link) = link {
        let _ = link.tx.send(ToNode::ScreenClose { stream }).await;
    }
    // Close reasons are limited to 123 bytes.
    let reason: String = ended.chars().take(100).collect();
    let close = CloseFrame {
        code: 1011,
        reason: reason.into(),
    };
    let _ = sink.send(WsMessage::Close(Some(close))).await;
}

/// A binary frame from the node: pass its bytes to the viewer.
pub async fn from_node(app: &App, frame: &[u8]) {
    let Some((stream, data)) = split_screen_frame(frame) else {
        return warn!("screen frame too short");
    };
    let viewer = lock(&app.rt).screens.get(&stream).cloned();
    if let Some(viewer) = viewer {
        let _ = viewer.send(Ok(data.to_vec())).await;
    }
}

/// The node ended a stream, perhaps because the computer has no screen.
pub async fn closed(app: &App, stream: u64, error: Option<String>) {
    let viewer = lock(&app.rt).screens.remove(&stream);
    if let (Some(viewer), Some(error)) = (viewer, error) {
        let _ = viewer.send(Err(error)).await;
    }
}
