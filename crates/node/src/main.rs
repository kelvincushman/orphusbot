//! orphusbot-node, milestone M0: connects out to the server and runs one
//! `orphus --mode rpc` engine for the one bot (DESIGN §4).

mod engine;

use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, bail};
use futures_util::{SinkExt, StreamExt};
use orphusbot_proto::{Attempt, FromNode, ToNode};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tracing::{info, warn};

struct Config {
    server: String,
    token: String,
    name: String,
    orphus: String,
    session_dir: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let home = std::env::var("HOME").context("HOME is not set")?;
    let cfg = Config {
        server: std::env::var("ORPHUSBOT_SERVER")
            .unwrap_or_else(|_| "ws://127.0.0.1:7480/node".into()),
        token: std::env::var("ORPHUSBOT_NODE_TOKEN").context("ORPHUSBOT_NODE_TOKEN is not set")?,
        name: std::env::var("ORPHUSBOT_NODE_NAME").unwrap_or_else(|_| hostname()),
        orphus: std::env::var("ORPHUS_BIN").unwrap_or_else(|_| "orphus".into()),
        session_dir: std::env::var("ORPHUSBOT_SESSION_DIR")
            .unwrap_or_else(|_| format!("{home}/.local/share/orphusbot/sessions")),
    };
    if !cfg.server.starts_with("ws://") && !cfg.server.starts_with("wss://") {
        bail!("ORPHUSBOT_SERVER must be a ws:// or wss:// URL");
    }

    // Reconnect forever, backing off up to 30 s.
    let mut backoff = 1;
    loop {
        match session(&cfg).await {
            Ok(()) => backoff = 1,
            Err(e) => warn!("link: {e:#}"),
        }
        info!("reconnecting in {backoff}s");
        tokio::time::sleep(Duration::from_secs(backoff)).await;
        backoff = (backoff * 2).min(30);
    }
}

fn hostname() -> String {
    std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|_| "node".into())
}

/// One connection to the server, until it drops.
async fn session(cfg: &Config) -> anyhow::Result<()> {
    let mut req = cfg.server.as_str().into_client_request()?;
    req.headers_mut().insert(
        "authorization",
        HeaderValue::from_str(&format!("Bearer {}", cfg.token))?,
    );
    let (ws, _) = tokio_tungstenite::connect_async(req)
        .await
        .context("connecting to the server")?;
    let (mut sink, mut stream) = ws.split();
    info!(server = %cfg.server, "connected");

    let hello = FromNode::Hello {
        node: cfg.name.clone(),
        version: env!("CARGO_PKG_VERSION").into(),
    };
    sink.send(Message::text(serde_json::to_string(&hello)?))
        .await?;

    // Frames from the engine reader go out through one channel.
    let (out_tx, mut out_rx) = mpsc::channel::<FromNode>(256);
    let mut engine: Option<Engine> = None;

    loop {
        tokio::select! {
            frame = stream.next() => {
                let Some(frame) = frame else { break };
                let Message::Text(text) = frame? else { continue };
                match serde_json::from_str::<ToNode>(&text) {
                    Ok(ToNode::StartTurn { attempt, text, resumed }) => {
                        if let Err(e) = start_turn(cfg, &mut engine, &out_tx, attempt, &text, resumed).await {
                            warn!(?attempt, "starting run: {e:#}");
                            engine = None;
                            let _ = out_tx.send(FromNode::TurnEnded { attempt, error: Some(format!("{e:#}")) }).await;
                        }
                    }
                    Ok(ToNode::Steer { attempt, text }) => {
                        if let Some(e) = engine.as_mut().filter(|e| e.current == Some(attempt)) {
                            let cmd = serde_json::json!({ "type": "steer", "message": text });
                            e.command(&cmd.to_string()).await.ok();
                        }
                    }
                    Ok(ToNode::Abort { attempt }) => {
                        if let Some(e) = engine.as_mut().filter(|e| e.current == Some(attempt)) {
                            e.command(r#"{"type":"abort"}"#).await.ok();
                        }
                    }
                    Err(e) => warn!("unreadable frame from server: {e}"),
                }
            }
            Some(frame) = out_rx.recv() => {
                sink.send(Message::text(serde_json::to_string(&frame)?)).await?;
            }
        }
    }

    // The server re-queues the run when the link drops; stop this attempt so it can't act twice.
    if let Some(e) = engine.as_mut() {
        e.command(r#"{"type":"abort"}"#).await.ok();
    }
    Ok(())
}

/// A running `orphus --mode rpc` process.
struct Engine {
    _child: Child,
    stdin: ChildStdin,
    attempts: mpsc::Sender<Attempt>,
    /// The attempt the engine was last given.
    current: Option<Attempt>,
}

impl Engine {
    fn spawn(cfg: &Config, out: mpsc::Sender<FromNode>) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&cfg.session_dir)
            .with_context(|| format!("creating {}", cfg.session_dir))?;
        let mut child = Command::new(&cfg.orphus)
            .args([
                "--mode",
                "rpc",
                "--name",
                "orphusbot",
                // One lasting conversation per bot, so a resumed run keeps its context.
                "--session-id",
                "orphusbot",
                "--session-dir",
                &cfg.session_dir,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("starting {}", cfg.orphus))?;
        let stdin = child.stdin.take().context("engine stdin")?;
        let stdout = child.stdout.take().context("engine stdout")?;

        // The reader learns the current attempt over a channel and maps every line for it.
        let (attempts, mut attempt_rx) = mpsc::channel::<Attempt>(4);
        tokio::spawn(async move {
            // tokio's `lines` splits on LF only, as the RPC framing requires.
            let mut lines = BufReader::new(stdout).lines();
            let mut current = None;
            let mut state = engine::TurnState::default();
            loop {
                tokio::select! {
                    // Biased: a new attempt must be seen before its first output line.
                    biased;
                    Some(a) = attempt_rx.recv() => { current = Some(a); state = engine::TurnState::default(); }
                    line = lines.next_line() => match line {
                        Ok(Some(line)) => {
                            let Some(a) = current else { continue };
                            for frame in engine::map_line(&line, a, &mut state) {
                                if matches!(frame, FromNode::TurnEnded { .. }) { current = None; }
                                if out.send(frame).await.is_err() { return; }
                            }
                        }
                        _ => {
                            if let Some(attempt) = current {
                                let _ = out.send(FromNode::TurnEnded { attempt, error: Some("The Orphus engine exited".into()) }).await;
                            }
                            return;
                        }
                    }
                }
            }
        });
        Ok(Self {
            _child: child,
            stdin,
            attempts,
            current: None,
        })
    }

    async fn command(&mut self, json: &str) -> std::io::Result<()> {
        self.stdin.write_all(json.as_bytes()).await?;
        self.stdin.write_all(b"\n").await?;
        self.stdin.flush().await
    }
}

async fn start_turn(
    cfg: &Config,
    engine: &mut Option<Engine>,
    out: &mpsc::Sender<FromNode>,
    attempt: Attempt,
    text: &str,
    resumed: bool,
) -> anyhow::Result<()> {
    // Start the engine on first use, or again if it has exited.
    if engine.as_ref().is_none_or(|e| e.attempts.is_closed()) {
        *engine = Some(Engine::spawn(cfg, out.clone())?);
    }
    let Some(e) = engine.as_mut() else {
        bail!("no engine")
    };
    e.attempts
        .send(attempt)
        .await
        .context("engine reader stopped")?;
    e.current = Some(attempt);
    let message = if resumed {
        format!(
            "(An earlier attempt at this was interrupted. Check what was already done before repeating any step.)\n\n{text}"
        )
    } else {
        text.to_owned()
    };
    let id = format!("run-{}-{}", attempt.run, attempt.fence);
    let cmd = serde_json::json!({ "id": id, "type": "prompt", "message": message });
    e.command(&cmd.to_string())
        .await
        .context("writing to the engine")?;
    info!(
        run = attempt.run,
        fence = attempt.fence,
        resumed,
        "run started"
    );
    Ok(())
}
