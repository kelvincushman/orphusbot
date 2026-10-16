//! orphusbot-node, milestone M0: connects out to the server and runs one
//! `orphus --mode rpc` engine per bot, each with its own computer (DESIGN §4).

mod beat;
mod computer;
mod engine;
mod key;

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, bail};
use futures_util::{SinkExt, Stream, StreamExt};
use key::NodeKey;
use orphusbot_proto::{Attempt, BotSpec, FromNode, ToNode, screen_frame, split_screen_frame};
use std::collections::HashMap;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
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
    /// `None` (`ORPHUSBOT_RUNTIME=none`): tools run on this machine, not isolated.
    runtime: Option<String>,
    image: String,
    /// `START-END` local hours when this node takes no new work, such as `22-7`.
    quiet_hours: Option<String>,
    /// Programs this node may run as MCP servers (`ORPHUSBOT_MCP_COMMANDS=npx,uvx`); none by default.
    mcp_commands: Vec<String>,
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
        runtime: match std::env::var("ORPHUSBOT_RUNTIME").as_deref() {
            Ok("none") => None,
            Ok(other) => Some(other.to_owned()),
            Err(_) => Some("podman".to_owned()),
        },
        quiet_hours: std::env::var("ORPHUSBOT_QUIET_HOURS").ok(),
        image: std::env::var("ORPHUSBOT_COMPUTER_IMAGE")
            .unwrap_or_else(|_| "docker.io/library/debian:trixie-slim".into()),
        mcp_commands: std::env::var("ORPHUSBOT_MCP_COMMANDS")
            .unwrap_or_default()
            .split(',')
            .map(|p| p.trim().to_owned())
            .filter(|p| !p.is_empty())
            .collect(),
    };
    if cfg.runtime.is_none() {
        warn!("ORPHUSBOT_RUNTIME=none: the bot's tools run on this machine, not in a computer");
    }
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
    // One engine per bot, by slug.
    let mut engines: HashMap<String, Engine> = HashMap::new();
    // Screen streams: binary frames out, and each stream's VNC pipe in.
    let (screen_tx, mut screen_rx) = mpsc::channel::<Vec<u8>>(256);
    let mut screens: HashMap<u64, (Child, ChildStdin)> = HashMap::new();
    let mut heartbeat = tokio::time::interval(Duration::from_secs(10));
    // The models it can use, so bots can be pointed at them by name.
    {
        let (out, orphus) = (out_tx.clone(), cfg.orphus.clone());
        tokio::spawn(async move {
            match list_models(&orphus).await {
                Ok(models) => {
                    let _ = out.send(FromNode::Models { models }).await;
                }
                Err(e) => warn!("listing Orphus's models: {e:#}"),
            }
        });
    }

    loop {
        tokio::select! {
            frame = stream.next() => {
                let Some(frame) = frame else { break };
                let text = match frame? {
                    Message::Text(text) => text,
                    Message::Binary(data) => {
                        if let Some((stream, bytes)) = split_screen_frame(&data)
                            && let Some((_, pipe)) = screens.get_mut(&stream)
                        {
                            pipe.write_all(bytes).await.ok();
                        }
                        continue;
                    }
                    _ => continue,
                };
                match serde_json::from_str::<ToNode>(&text) {
                    Ok(ToNode::StartTurn { attempt, text, resumed, bot }) => {
                        if let Err(e) = start_turn(cfg, &mut engines, &out_tx, attempt, &text, resumed, &bot).await {
                            warn!(?attempt, "starting run: {e:#}");
                            engines.remove(&bot.slug);
                            let _ = out_tx.send(FromNode::TurnEnded { attempt, error: Some(format!("{e:#}")) }).await;
                        }
                    }
                    Ok(ToNode::Steer { attempt, text }) => {
                        if let Some(e) = engines.values_mut().find(|e| e.current == Some(attempt)) {
                            let cmd = serde_json::json!({ "type": "steer", "message": text });
                            e.command(&cmd.to_string()).await.ok();
                        }
                    }
                    Ok(ToNode::DialogResponse { attempt, response }) => {
                        let is_response = response["type"] == "extension_ui_response";
                        if let Some(e) = engines.values_mut().find(|e| e.current == Some(attempt) && is_response) {
                            e.command(&response.to_string()).await.ok();
                        }
                    }
                    Ok(ToNode::Abort { attempt }) => {
                        if let Some(e) = engines.values_mut().find(|e| e.current == Some(attempt)) {
                            e.command(r#"{"type":"abort"}"#).await.ok();
                        }
                    }
                    Ok(ToNode::ScreenOpen { stream, bot }) => {
                        match open_screen(cfg, stream, &bot, screen_tx.clone(), out_tx.clone()).await {
                            Ok(pipe) => { screens.insert(stream, pipe); }
                            Err(e) => {
                                let _ = out_tx.send(FromNode::ScreenClosed { stream, error: Some(format!("{e:#}")) }).await;
                            }
                        }
                    }
                    Ok(ToNode::ScreenClose { stream }) => { screens.remove(&stream); }
                    Ok(ToNode::Extract { id, system, text }) => {
                        let (out, orphus) = (out_tx.clone(), cfg.orphus.clone());
                        tokio::spawn(async move {
                            let (text, error) = match extract(&orphus, &system, &text).await {
                                Ok(reply) => (Some(reply), None),
                                Err(e) => (None, Some(format!("{e:#}"))),
                            };
                            let _ = out.send(FromNode::Extracted { id, text, error }).await;
                        });
                    }
                    Ok(ToNode::Challenge { .. } | ToNode::Enrolled { .. }) => {}
                    Err(e) => warn!("unreadable frame from server: {e}"),
                }
            }
            Some(frame) = out_rx.recv() => {
                sink.send(Message::text(serde_json::to_string(&frame)?)).await?;
            }
            Some(frame) = screen_rx.recv() => {
                sink.send(Message::binary(frame)).await?;
            }
            _ = heartbeat.tick() => {
                let beat = FromNode::Heartbeat {
                    load: beat::load(),
                    on_battery: beat::on_battery(),
                    quiet: beat::quiet(cfg.quiet_hours.as_deref(), beat::local_hour().await),
                };
                sink.send(Message::text(serde_json::to_string(&beat)?)).await?;
            }
        }
    }

    // The server re-queues the run when the link drops; stop this attempt so it can't act twice.
    for e in engines.values_mut() {
        e.command(r#"{"type":"abort"}"#).await.ok();
    }
    Ok(())
}

/// Starts piping the computer's screen for `stream`: its output goes up as binary
/// frames, and the returned pipe takes the viewer's input.
async fn open_screen(
    cfg: &Config,
    stream: u64,
    bot: &str,
    frames: mpsc::Sender<Vec<u8>>,
    out: mpsc::Sender<FromNode>,
) -> anyhow::Result<(Child, ChildStdin)> {
    let Some(runtime) = &cfg.runtime else {
        bail!(
            "This node runs tools without a computer (ORPHUSBOT_RUNTIME=none), so there's no screen"
        );
    };
    let spec = computer::Spec {
        runtime,
        image: &cfg.image,
        bot,
        // Unused: opening a screen never creates or changes the computer.
        team: false,
    };
    let mut child = spec.open_screen().await?;
    let pipe = child.stdin.take().context("screen stdin")?;
    let mut screen = child.stdout.take().context("screen stdout")?;
    let mut errors = child.stderr.take().context("screen stderr")?;
    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        while let Ok(n @ 1..) = screen.read(&mut buf).await {
            if frames.send(screen_frame(stream, &buf[..n])).await.is_err() {
                return;
            }
        }
        let mut why = String::new();
        let _ = errors.read_to_string(&mut why).await;
        // socat missing (a plain image) or nothing listening: there's no screen to show.
        let error = (!why.trim().is_empty()).then(|| {
            if why.contains("not found") || why.contains("Connection refused") {
                "This bot's computer has no screen (its image has no VNC server)".to_owned()
            } else {
                why.trim().to_owned()
            }
        });
        let _ = out.send(FromNode::ScreenClosed { stream, error }).await;
    });
    Ok((child, pipe))
}

/// One capture extraction (DESIGN §10.2): a single Orphus call with no tools, no
/// extensions, no skills or context files and no saved session, so ambient text
/// can't make anything happen. `ORPHUSBOT_EXTRACT_MODEL` picks a cheap model.
async fn extract(orphus: &str, system: &str, text: &str) -> anyhow::Result<String> {
    let mut command = Command::new(orphus);
    command.args([
        "--print",
        "--no-session",
        "--no-tools",
        "--no-extensions",
        "--no-skills",
        "--no-context-files",
        "--system-prompt",
        system,
    ]);
    if let Ok(model) = std::env::var("ORPHUSBOT_EXTRACT_MODEL") {
        command.args(["--model", &model]);
    }
    let run = command
        .arg(text)
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(120), run)
        .await
        .context("the extractor took over two minutes")?
        .with_context(|| format!("starting {orphus}"))?;
    if !out.status.success() {
        bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `orphus --list-models` as `provider/model` names.
async fn list_models(orphus: &str) -> anyhow::Result<Vec<String>> {
    let out = Command::new(orphus)
        .arg("--list-models")
        .output()
        .await
        .with_context(|| format!("running {orphus} --list-models"))?;
    Ok(parse_models(&String::from_utf8_lossy(&out.stdout)))
}

/// The table's first two columns, skipping its header.
fn parse_models(table: &str) -> Vec<String> {
    table
        .lines()
        .filter_map(|line| {
            let mut cols = line.split_whitespace();
            let (provider, model) = (cols.next()?, cols.next()?);
            (provider != "provider").then(|| format!("{provider}/{model}"))
        })
        .collect()
}

/// The Orphus extension that sends every tool call to OrphusBot for approval.
const BRIDGE: &str = include_str!("../../../bridge/orphusbot-bridge.ts");

/// A running `orphus --mode rpc` process.
struct Engine {
    _child: Child,
    stdin: ChildStdin,
    attempts: mpsc::Sender<Attempt>,
    /// The settings it was started with; changed settings mean a new engine.
    bot: BotSpec,
    /// The attempt the engine was last given.
    current: Option<Attempt>,
}

impl Engine {
    async fn spawn(
        cfg: &Config,
        out: mpsc::Sender<FromNode>,
        bot: &BotSpec,
    ) -> anyhow::Result<Self> {
        // Each bot keeps its sessions (its lasting conversation) in its own folder.
        let dir = format!("{}/{}", cfg.session_dir, bot.slug);
        std::fs::create_dir_all(&dir).with_context(|| format!("creating {dir}"))?;
        let bridge = format!("{dir}/orphusbot-bridge.ts");
        std::fs::write(&bridge, BRIDGE).with_context(|| format!("writing {bridge}"))?;
        // The engine works in this empty folder. A copy of the bridge in its
        // project extensions is what helper sessions (subagents, fleet members)
        // load, so their calls are gated too (DESIGN §11.2); the engine itself
        // loads the bridge from `--extension` and ignores the copy.
        let work = format!("{dir}/work");
        let helpers = format!("{work}/.orphus/extensions");
        std::fs::create_dir_all(&helpers).with_context(|| format!("creating {helpers}"))?;
        std::fs::write(format!("{helpers}/orphusbot-bridge.ts"), BRIDGE)
            .with_context(|| format!("writing the bridge into {helpers}"))?;
        let mut command = Command::new(&cfg.orphus);
        command
            .current_dir(&work)
            .env("ORPHUSBOT_HELPERS_GATED", "1");
        if let Some(model) = &bot.model {
            command.args(["--model", model]);
        }
        if let Some(thinking) = &bot.thinking {
            command.args(["--thinking", thinking]);
        }
        if !bot.instructions.trim().is_empty() {
            command.args(["--append-system-prompt", &bot.instructions]);
        }
        if !bot.exclude_tools.is_empty() {
            command.args(["--exclude-tools", &bot.exclude_tools.join(",")]);
        }
        if !bot.mcp.is_empty() {
            // Orphus's MCP adapter reads this file; tokens go in through the
            // environment so they're never written to disk.
            let mut servers = serde_json::Map::new();
            for (i, server) in bot.mcp.iter().enumerate() {
                let var = format!("ORPHUSBOT_MCP_TOKEN_{i}");
                let mut entry = match &server.command {
                    // A command runs here, outside the bot's computer: only programs this
                    // node's owner listed in ORPHUSBOT_MCP_COMMANDS.
                    Some(program) if !cfg.mcp_commands.iter().any(|p| p == program) => {
                        warn!(server = %server.name, %program, "not on ORPHUSBOT_MCP_COMMANDS; leaving this MCP server out");
                        continue;
                    }
                    Some(program) => {
                        let mut entry = serde_json::json!({ "command": program, "args": server.args, "lifecycle": "lazy" });
                        if let (Some(name), Some(_)) = (&server.token_env, &server.token) {
                            // The adapter fills ${…} from the engine's environment.
                            entry["env"] = serde_json::json!({ name: format!("${{{var}}}") });
                        }
                        entry
                    }
                    None => {
                        let mut entry =
                            serde_json::json!({ "url": server.url, "lifecycle": "lazy" });
                        if server.token.is_some() {
                            entry["auth"] = "bearer".into();
                            entry["bearerTokenEnv"] = var.clone().into();
                        }
                        entry
                    }
                };
                if let Some(token) = &server.token {
                    command.env(&var, token);
                }
                entry["lifecycle"] = "lazy".into();
                servers.insert(server.name.clone(), entry);
            }
            let file = format!("{dir}/mcp.json");
            let config = serde_json::json!({ "mcpServers": servers });
            std::fs::write(&file, config.to_string()).with_context(|| format!("writing {file}"))?;
            command
                .args(["--mcp-config", &file])
                .env("ORPHUSBOT_MCP", "1");
        }
        if let Some(sandbox) = &bot.e2b {
            // The computer is an E2B sandbox: the bridge reaches its envd over HTTPS.
            command
                .env("ORPHUSBOT_COMPUTER", format!("e2b:{}", sandbox.sandbox))
                .env("ORPHUSBOT_E2B_URL", &sandbox.url)
                .env("ORPHUSBOT_COMPUTER_HOME", "/home/user");
            if let Some(token) = &sandbox.token {
                command.env("ORPHUSBOT_E2B_TOKEN", token);
            }
        } else if let Some(runtime) = &cfg.runtime {
            let spec = computer::Spec {
                runtime,
                image: &cfg.image,
                bot: &bot.slug,
                team: bot.team,
            };
            let name = spec.ensure().await?;
            // The bridge maps the work folder onto the computer's home and runs every tool there.
            command
                .env("ORPHUSBOT_COMPUTER", name)
                .env("ORPHUSBOT_RUNTIME", runtime)
                .env("ORPHUSBOT_COMPUTER_HOME", computer::HOME);
        }
        let mut child = command
            .args([
                "--mode",
                "rpc",
                "--name",
                &bot.slug,
                // One lasting conversation per bot, so a resumed run keeps its context.
                "--session-id",
                &bot.slug,
                "--session-dir",
                &dir,
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
            bot: bot.clone(),
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
    engines: &mut HashMap<String, Engine>,
    out: &mpsc::Sender<FromNode>,
    attempt: Attempt,
    text: &str,
    resumed: bool,
    bot: &BotSpec,
) -> anyhow::Result<()> {
    // Start the bot's engine on first use, again if it exited, and afresh if its
    // settings changed (the old one is killed when dropped).
    let stale = engines
        .get(&bot.slug)
        .is_none_or(|e| e.attempts.is_closed() || e.bot != *bot);
    if stale {
        engines.remove(&bot.slug);
        let engine = Engine::spawn(cfg, out.clone(), bot).await?;
        engines.insert(bot.slug.clone(), engine);
    }
    let Some(e) = engines.get_mut(&bot.slug) else {
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
        bot = %bot.slug,
        resumed,
        "run started"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_the_model_table() {
        let table = "provider       model                 context  max-out\nlocal          qwen3.8-27b-abl       65.5K    8.2K\nclaude-bridge  claude-sonnet-5       1M       128K\n";
        assert_eq!(
            super::parse_models(table),
            ["local/qwen3.8-27b-abl", "claude-bridge/claude-sonnet-5"]
        );
    }
}
