//! orphusbot-node, milestone M0: connects out to the server and runs one
//! `orphus --mode rpc` engine for the one bot (DESIGN §4).

mod engine;
mod key;

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, bail};
use futures_util::{SinkExt, Stream, StreamExt};
use key::NodeKey;
use orphusbot_proto::{Attempt, FromNode, ToNode};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{self, Message};
use tracing::{info, warn};

struct Config {
    server: String,
    /// Used when enrolling; after that the name comes from the key file.
    name: String,
    key_path: PathBuf,
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
        name: std::env::var("ORPHUSBOT_NODE_NAME").unwrap_or_else(|_| hostname()),
        key_path: std::env::var("ORPHUSBOT_NODE_KEY")
            .map(PathBuf::from)
            .unwrap_or_else(|_| format!("{home}/.config/orphusbot/node.json").into()),
        orphus: std::env::var("ORPHUS_BIN").unwrap_or_else(|_| "orphus".into()),
        session_dir: std::env::var("ORPHUSBOT_SESSION_DIR")
            .unwrap_or_else(|_| format!("{home}/.local/share/orphusbot/sessions")),
    };
    if !cfg.server.starts_with("ws://") && !cfg.server.starts_with("wss://") {
        bail!("ORPHUSBOT_SERVER must be a ws:// or wss:// URL");
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => {}
        [cmd, code] if cmd == "enrol" || cmd == "enroll" => return enrol(&cfg, code).await,
        _ => bail!("usage: orphusbot-node [enrol <code>]"),
    }
    let key = NodeKey::load(&cfg.key_path)?;

    // Reconnect forever, backing off up to 30 s.
    let mut backoff = 1;
    loop {
        match session(&cfg, &key).await {
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

/// Waits for the server's first frame, its challenge nonce.
async fn challenge<S>(stream: &mut S) -> anyhow::Result<String>
where
    S: Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
{
    match stream.next().await {
        Some(Ok(Message::Text(text))) => match serde_json::from_str(&text)? {
            ToNode::Challenge { nonce } => Ok(nonce),
            _ => bail!("the server didn't start with a challenge"),
        },
        Some(Err(e)) => Err(e.into()),
        _ => bail!("the server closed the link before its challenge"),
    }
}

/// `orphusbot-node enrol <code>`: make a key, register it with a one-time
/// code from the web page, and save it (DESIGN §4.1).
async fn enrol(cfg: &Config, code: &str) -> anyhow::Result<()> {
    let key = NodeKey::generate(cfg.name.clone())?;
    let (ws, _) = tokio_tungstenite::connect_async(cfg.server.as_str())
        .await
        .context("connecting to the server")?;
    let (mut sink, mut stream) = ws.split();
    challenge(&mut stream).await?;
    let enrol = FromNode::Enrol {
        code: code.trim().to_owned(),
        node: key.name.clone(),
        public_key: key.public_hex()?,
    };
    sink.send(Message::text(serde_json::to_string(&enrol)?))
        .await?;
    while let Some(frame) = stream.next().await {
        let Message::Text(text) = frame? else {
            continue;
        };
        if let ToNode::Enrolled { error } = serde_json::from_str(&text)? {
            if let Some(error) = error {
                bail!("{error}");
            }
            key.save(&cfg.key_path)?;
            println!(
                "Enrolled as \"{}\". The key is in {}. Start the node with `orphusbot-node`.",
                key.name,
                cfg.key_path.display()
            );
            return Ok(());
        }
    }
    bail!("the server closed the link without answering")
}

/// One connection to the server, until it drops.
async fn session(cfg: &Config, key: &NodeKey) -> anyhow::Result<()> {
    let (ws, _) = tokio_tungstenite::connect_async(cfg.server.as_str())
        .await
        .context("connecting to the server")?;
    let (mut sink, mut stream) = ws.split();
    let nonce = challenge(&mut stream).await?;
    let hello = FromNode::Hello {
        node: key.name.clone(),
        version: env!("CARGO_PKG_VERSION").into(),
        signature: key.sign(&nonce)?,
    };
    sink.send(Message::text(serde_json::to_string(&hello)?))
        .await?;
    info!(server = %cfg.server, node = %key.name, "connected");

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
                    Ok(ToNode::DialogResponse { attempt, response }) => {
                        let is_response = response["type"] == "extension_ui_response";
                        if let Some(e) = engine.as_mut().filter(|e| e.current == Some(attempt) && is_response) {
                            e.command(&response.to_string()).await.ok();
                        }
                    }
                    Ok(ToNode::Abort { attempt }) => {
                        if let Some(e) = engine.as_mut().filter(|e| e.current == Some(attempt)) {
                            e.command(r#"{"type":"abort"}"#).await.ok();
                        }
                    }
                    Ok(ToNode::Challenge { .. } | ToNode::Enrolled { .. }) => {}
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

/// The Orphus extension that sends every tool call to OrphusBot for approval.
const BRIDGE: &str = include_str!("../../../bridge/orphusbot-bridge.ts");

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
        let bridge = format!("{}/orphusbot-bridge.ts", cfg.session_dir);
        std::fs::write(&bridge, BRIDGE).with_context(|| format!("writing {bridge}"))?;
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
                "--extension",
                &bridge,
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
