//! Watching and taking over a bot's screen (DESIGN §4.4, PRD B-CMP-05).
//!
//! The browser's VNC client opens `/api/screen` (a WebSocket, signed in like
//! everything under `/api`). The server relays it over the node link as binary
//! frames tagged with a stream number, and the node pipes it into the bot's
//! computer. Clients never connect to a node, and the computer publishes no port.

use axum::extract::ws::{CloseFrame, Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use orphusbot_proto::{ToNode, screen_frame, split_screen_frame};
use tokio::sync::mpsc;
use tracing::warn;

use crate::{App, Shared, db, lock};

/// Bytes for a viewer, or the reason its stream ended.
pub type ToViewer = Result<Vec<u8>, String>;

#[derive(serde::Deserialize)]
pub struct Which {
    #[serde(default = "crate::inbox")]
    bot: String,
}

pub async fn open(
    State(app): State<Shared>,
    Query(which): Query<Which>,
    ws: WebSocketUpgrade,
) -> Response {
    // noVNC asks for the "binary" subprotocol.
    ws.protocols(["binary"])
        .on_upgrade(move |socket| relay(app, which.bot, socket))
}

async fn relay(app: Shared, bot: String, socket: WebSocket) {
    let in_e2b =
        matches!(crate::bots::get(&app.db, &bot).await, Ok(Some(b)) if b.computer == "e2b");
    if in_e2b {
        return relay_e2b(app, bot, socket).await;
    }
    let (mut sink, mut source) = socket.split();
    // ponytail: a viewer that reads slowly slows the whole node link; per-stream flow control if it bites.
    let (to_viewer, mut from_node) = mpsc::channel::<ToViewer>(256);
    // The screen is on whichever node holds the bot's computer.
    let home = db::computer_home(&app.db, &bot).await.ok().flatten();
    let (stream, link) = {
        let mut rt = lock(&app.rt);
        rt.next_screen += 1;
        let stream = rt.next_screen;
        let link = home.as_ref().and_then(|h| rt.nodes.get(h)).cloned();
        if let Some(link) = &link {
            rt.screens.insert(stream, (link.name.clone(), to_viewer));
        }
        (stream, link)
    };
    let mut ended = "The screen closed".to_owned();
    match &link {
        None if home.is_none() => {
            ended = "The bot has no computer yet; it gets one with its first task".into()
        }
        None => ended = "The node with the bot's computer isn't connected".into(),
        Some(link)
            if link
                .tx
                .send(ToNode::ScreenOpen {
                    stream,
                    bot: bot.clone(),
                })
                .await
                .is_ok() =>
        {
            loop {
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
            }
        }
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

/// A computer in E2B: the server connects to the sandbox's websockify through
/// E2B's port proxy and passes bytes both ways (DESIGN §6.2). No node is involved.
async fn relay_e2b(app: Shared, bot: String, socket: WebSocket) {
    use tokio_tungstenite::tungstenite::{Message as Up, client::IntoClientRequest};
    let (mut sink, mut source) = socket.split();
    let connected = async {
        let screen = app.e2b.screen(&app.db, &bot).await?;
        let mut request = screen.url.as_str().into_client_request()?;
        request
            .headers_mut()
            .insert("Sec-WebSocket-Protocol", "binary".parse()?);
        if let Some(token) = &screen.token {
            request
                .headers_mut()
                .insert("e2b-traffic-access-token", token.parse()?);
        }
        let (upstream, _) = tokio_tungstenite::connect_async(request).await?;
        anyhow::Ok(upstream)
    };
    let ended = match connected.await {
        Err(e) => format!("Couldn't reach the E2B screen: {e:#}"),
        Ok(upstream) => {
            let (mut up_sink, mut up_source) = upstream.split();
            loop {
                tokio::select! {
                    msg = up_source.next() => match msg {
                        Some(Ok(Up::Binary(data))) => if sink.send(WsMessage::Binary(data)).await.is_err() { break "The screen closed".to_owned() },
                        Some(Ok(Up::Close(_)) | Err(_)) | None => break "The screen closed".to_owned(),
                        Some(Ok(_)) => {}
                    },
                    msg = source.next() => match msg {
                        Some(Ok(WsMessage::Binary(data))) => if up_sink.send(Up::Binary(data)).await.is_err() { break "The screen closed".to_owned() },
                        Some(Ok(WsMessage::Close(_)) | Err(_)) | None => break "The screen closed".to_owned(),
                        Some(Ok(_)) => {}
                    },
                }
            }
        }
    };
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
    let viewer = lock(&app.rt).screens.get(&stream).map(|(_, v)| v.clone());
    if let Some(viewer) = viewer {
        let _ = viewer.send(Ok(data.to_vec())).await;
    }
}

/// The node ended a stream, perhaps because the computer has no screen.
pub async fn closed(app: &App, stream: u64, error: Option<String>) {
    let viewer = lock(&app.rt).screens.remove(&stream).map(|(_, v)| v);
    if let (Some(viewer), Some(error)) = (viewer, error) {
        let _ = viewer.send(Err(error)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::ws::WebSocketUpgrade;
    use axum::routing::get;
    use sqlx::PgPool;
    use tokio_tungstenite::tungstenite::Message as Up;

    /// Serves `router` on a free port; returns its address.
    async fn serve(router: axum::Router) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        addr
    }

    #[sqlx::test]
    async fn an_e2b_screen_is_relayed_both_ways(db: PgPool) {
        // The sandbox's websockify: greets like a VNC server, then echoes.
        let screen = serve(axum::Router::new().route(
            "/websockify",
            get(|ws: WebSocketUpgrade| async move {
                ws.protocols(["binary"]).on_upgrade(|mut s| async move {
                    let _ = s
                        .send(WsMessage::Binary(b"RFB 003.008\n".to_vec().into()))
                        .await;
                    while let Some(Ok(WsMessage::Binary(b))) = s.recv().await {
                        let _ = s.send(WsMessage::Binary(b)).await;
                    }
                })
            }),
        ))
        .await;
        let (mut fake, _) = crate::e2b::tests::fake_e2b("sbx-new").await;
        fake.screen_url = Some(format!("ws://{screen}/websockify"));
        let mut app = crate::auth::tests::app(db.clone());
        std::sync::Arc::get_mut(&mut app).unwrap().e2b = fake;
        sqlx::query!("update bot set computer = 'e2b' where slug = 'inbox'")
            .execute(&db)
            .await
            .unwrap();
        let relay_app = app.clone();
        let server = serve(axum::Router::new().route(
            "/api/screen",
            get(move |ws: WebSocketUpgrade| async move {
                ws.protocols(["binary"])
                    .on_upgrade(move |s| relay(relay_app, "inbox".into(), s))
            }),
        ))
        .await;

        let (mut viewer, _) = tokio_tungstenite::connect_async(format!("ws://{server}/api/screen"))
            .await
            .unwrap();
        assert_eq!(
            viewer.next().await.unwrap().unwrap(),
            Up::Binary(b"RFB 003.008\n".to_vec().into())
        );
        viewer
            .send(Up::Binary(b"hello".to_vec().into()))
            .await
            .unwrap();
        assert_eq!(
            viewer.next().await.unwrap().unwrap(),
            Up::Binary(b"hello".to_vec().into())
        );
    }
}
