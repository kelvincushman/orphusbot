//! `orphusbot`: the command-line side of OrphusBot, used by the Omarchy plugin
//! (DESIGN §12) and handy on its own.
//!
//! ```text
//! orphusbot link [server]          sign this machine in (approve it from a signed-in device)
//! orphusbot status                 bots, what they're doing and what needs you, as JSON
//! orphusbot watch [--notify]       the same, one JSON line per change; --notify also sends desktop notifications
//! orphusbot answer <id> allow|always|deny
//! orphusbot send <bot> <text…>
//! ```
//!
//! It signs in by device linking (D-019) and keeps the session in
//! `~/.config/orphusbot/cli.json` (mode 0600). It folds the server's event
//! stream with the same reducer as the web UI (`orphusbot_proto::view`).

use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, bail};
use futures_util::StreamExt;
use orphusbot_proto::view::{Item, RunState, ThreadView};
use orphusbot_proto::{DialogKind, Envelope, Role, RunOutcome, ThreadEvent};
use serde_json::{Value, json};

const AGENT: &str = "OrphusBot command line (Omarchy)";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    match words.as_slice() {
        ["link"] => {
            link(
                &Config::load()
                    .map(|c| c.server)
                    .unwrap_or_else(|_| "http://localhost:7480".into()),
            )
            .await
        }
        ["link", server] => link(server).await,
        ["status"] => {
            println!("{}", Session::open()?.status().await?);
            Ok(())
        }
        ["watch", rest @ ..] => {
            let notify = rest.contains(&"--notify");
            Session::open()?.watch(notify).await
        }
        ["answer", id, decision @ ("allow" | "always" | "deny")] => {
            Session::open()?
                .post(
                    "/api/dialogs/answer",
                    json!({ "id": id, "decision": decision }),
                )
                .await
        }
        ["send", bot, text @ ..] if !text.is_empty() => {
            Session::open()?
                .post(
                    "/api/messages",
                    json!({ "bot": bot, "text": text.join(" ") }),
                )
                .await
        }
        _ => {
            eprintln!(
                "usage: orphusbot link [server] | status | watch [--notify] | answer <id> allow|always|deny | send <bot> <text>"
            );
            std::process::exit(2)
        }
    }
}

struct Config {
    server: String,
    cookie: String,
}

impl Config {
    fn path() -> anyhow::Result<PathBuf> {
        let base = std::env::var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")))
            .context("neither XDG_CONFIG_HOME nor HOME is set")?;
        Ok(base.join("orphusbot").join("cli.json"))
    }

    fn load() -> anyhow::Result<Self> {
        let path = Self::path()?;
        let v: Value = serde_json::from_str(
            &std::fs::read_to_string(&path)
                .context("not signed in: run `orphusbot link <server>`")?,
        )?;
        Ok(Self {
            server: v["server"]
                .as_str()
                .context("cli.json has no server")?
                .to_owned(),
            cookie: v["cookie"].as_str().unwrap_or_default().to_owned(),
        })
    }

    /// Only the owner can read it: it holds a session.
    fn save(&self) -> anyhow::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let path = Self::path()?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)?;
        f.write_all(
            json!({ "server": self.server, "cookie": self.cookie })
                .to_string()
                .as_bytes(),
        )?;
        Ok(())
    }
}

/// Device linking: show a code, wait for the owner to approve it, keep the session.
async fn link(server: &str) -> anyhow::Result<()> {
    let server = server.trim_end_matches('/').to_owned();
    let http = reqwest::Client::builder().user_agent(AGENT).build()?;
    let started: Value = http
        .post(format!("{server}/auth/link/start"))
        .json(&json!({}))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let (device, user) = (
        started["device_code"].as_str().context("no device_code")?,
        started["user_code"].as_str().context("no user_code")?,
    );
    println!("On a device where you're signed in, open {server}/?link={user}");
    println!("or go to Settings → Link a device and enter {user}");
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let res = http
            .post(format!("{server}/auth/link/poll"))
            .json(&json!({ "device_code": device }))
            .send()
            .await?;
        match res.status().as_u16() {
            202 => continue,
            200 => {
                let cookie = res
                    .headers()
                    .get("set-cookie")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.split(';').next())
                    .context("approved, but no session came back")?
                    .to_owned();
                Config { server, cookie }.save()?;
                println!("Linked. Try `orphusbot status`.");
                return Ok(());
            }
            code => bail!("linking stopped ({code}): the code expired or was refused"),
        }
    }
}

struct Session {
    cfg: Config,
    http: reqwest::Client,
}

impl Session {
    fn open() -> anyhow::Result<Self> {
        Ok(Self {
            cfg: Config::load()?,
            http: reqwest::Client::builder().user_agent(AGENT).build()?,
        })
    }

    fn get(&self, path: &str) -> reqwest::RequestBuilder {
        self.http
            .get(format!("{}{path}", self.cfg.server))
            .header("cookie", &self.cfg.cookie)
    }

    async fn post(&self, path: &str, body: Value) -> anyhow::Result<()> {
        let res = self
            .http
            .post(format!("{}{path}", self.cfg.server))
            .header("cookie", &self.cfg.cookie)
            .json(&body)
            .send()
            .await?;
        check(res).await.map(drop)
    }

    async fn bots(&self) -> anyhow::Result<Vec<(String, String)>> {
        let list: Vec<Value> = check(self.get("/api/bots").send().await?)
            .await?
            .json()
            .await?;
        Ok(list
            .iter()
            .filter(|b| b["disabled"] != true)
            .map(|b| {
                let s = |k: &str| b[k].as_str().unwrap_or_default().to_owned();
                (s("slug"), s("name"))
            })
            .collect())
    }

    /// The server's event stream, as `(bot, event)`. `None` means it has been
    /// quiet for `quiet`: history and the current state are in.
    async fn events(
        &self,
        quiet: Duration,
    ) -> anyhow::Result<
        impl futures_util::Stream<Item = anyhow::Result<Option<(String, ThreadEvent)>>>,
    > {
        let res = check(self.get("/api/events?after=0").send().await?).await?;
        let mut bytes = res.bytes_stream();
        Ok(async_stream::try_stream! {
            let mut pending = String::new();
            loop {
                let chunk = match tokio::time::timeout(quiet, bytes.next()).await {
                    Err(_) => { yield None; continue; }
                    Ok(None) => Err(anyhow::anyhow!("the server closed the event stream"))?,
                    Ok(Some(chunk)) => chunk?,
                };
                pending.push_str(&String::from_utf8_lossy(&chunk));
                while let Some(end) = pending.find("\n\n") {
                    let block: String = pending.drain(..end + 2).collect();
                    let data: String = block.lines().filter_map(|l| l.strip_prefix("data:")).map(str::trim_start).collect();
                    if let Ok(Envelope { bot: Some(bot), event }) = serde_json::from_str::<Envelope>(&data) {
                        yield Some((bot, event));
                    }
                }
            }
        })
    }

    /// Bots, what they're doing and what needs the owner, once.
    async fn status(&self) -> anyhow::Result<Value> {
        let bots = self.bots().await?;
        let mut views: BTreeMap<String, ThreadView> = BTreeMap::new();
        let events = self.events(Duration::from_millis(700)).await?;
        futures_util::pin_mut!(events);
        while let Some(next) = events.next().await {
            match next? {
                Some((bot, event)) => views.entry(bot).or_default().apply(event),
                None => break,
            }
        }
        Ok(status(&bots, &views))
    }

    /// One JSON status line per change; `--notify` also tells the desktop when
    /// a bot needs you or finishes.
    async fn watch(&self, notify: bool) -> anyhow::Result<()> {
        let bots = self.bots().await?;
        let mut views: BTreeMap<String, ThreadView> = BTreeMap::new();
        let (mut last, mut caught_up) = (String::new(), false);
        let mut told: HashSet<String> = HashSet::new();
        let events = self.events(Duration::from_millis(500)).await?;
        futures_util::pin_mut!(events);
        while let Some(next) = events.next().await {
            match next? {
                None => caught_up = true,
                Some((bot, event)) => {
                    // History is replayed first; only what happens after it is news.
                    if notify && caught_up {
                        let name = bots
                            .iter()
                            .find(|(s, _)| *s == bot)
                            .map_or(bot.as_str(), |(_, n)| n.as_str());
                        match &event {
                            ThreadEvent::DialogOpened { dialog }
                                if told.insert(dialog.id.clone()) =>
                            {
                                desktop(
                                    &format!("{name} needs you"),
                                    &card_text(&dialog.kind),
                                    "critical",
                                );
                            }
                            ThreadEvent::RunEnded {
                                outcome: RunOutcome::Completed,
                                ..
                            } => {
                                let said = views.get(&bot).map(last_reply).unwrap_or_default();
                                desktop(&format!("{name} finished"), &said, "normal");
                            }
                            ThreadEvent::RunEnded {
                                outcome: RunOutcome::Failed,
                                error,
                                ..
                            } => {
                                desktop(
                                    &format!("{name} couldn't finish"),
                                    error.as_deref().unwrap_or(""),
                                    "normal",
                                );
                            }
                            _ => {}
                        }
                    }
                    views.entry(bot).or_default().apply(event);
                }
            }
            if caught_up {
                let now = status(&bots, &views).to_string();
                if now != last {
                    println!("{now}");
                    last = now;
                }
            }
        }
        Ok(())
    }
}

async fn check(res: reqwest::Response) -> anyhow::Result<reqwest::Response> {
    match res.status().as_u16() {
        401 => bail!("signed out: run `orphusbot link`"),
        s if s >= 400 => bail!(
            "the server said {s}: {}",
            res.text().await.unwrap_or_default()
        ),
        _ => Ok(res),
    }
}

/// What a card asks, in a line.
fn card_text(kind: &DialogKind) -> String {
    match kind {
        DialogKind::Approval { tool, .. } => format!("May it use {tool}?"),
        DialogKind::Takeover { reason } => format!("Take over its screen: {reason}"),
        DialogKind::Question { title, message, .. } => {
            message.clone().unwrap_or_else(|| title.clone())
        }
    }
}

/// The bar's view: each bot's state, and every card waiting for the owner.
fn status(bots: &[(String, String)], views: &BTreeMap<String, ThreadView>) -> Value {
    let empty = ThreadView::default();
    let mut waiting = Vec::new();
    let list: Vec<Value> = bots
        .iter()
        .map(|(slug, name)| {
            let view = views.get(slug).unwrap_or(&empty);
            for item in &view.items {
                if let Item::Card { dialog, outcome: None } = item {
                    let approval = matches!(dialog.kind, DialogKind::Approval { .. });
                    waiting.push(json!({ "id": dialog.id, "bot": slug, "name": name, "text": card_text(&dialog.kind), "approval": approval }));
                }
            }
            let state = match view.run {
                RunState::Idle => "idle",
                RunState::Queued => "queued",
                RunState::Running { .. } => "running",
            };
            json!({ "slug": slug, "name": name, "state": state, "waiting": view.waiting(), "reply": last_reply(view), "asked": last_said(view, Role::User) })
        })
        .collect();
    let running = list.iter().filter(|b| b["state"] == "running").count();
    json!({ "running": running, "needs_you": waiting.len(), "bots": list, "waiting": waiting })
}

/// The bot's latest answer, shortened for the bar and notifications.
fn last_reply(view: &ThreadView) -> String {
    last_said(view, Role::Assistant)
}

/// The latest message from `role`, shortened.
fn last_said(view: &ThreadView, role: Role) -> String {
    let text = view.items.iter().rev().find_map(|i| match i {
        Item::Message { role: r, text } if *r == role => Some(text.as_str()),
        _ => None,
    });
    let text = text.unwrap_or_default().trim();
    if text.chars().count() > 400 {
        format!("{}…", text.chars().take(400).collect::<String>())
    } else {
        text.to_owned()
    }
}

/// A desktop notification through `notify-send` (mako on Omarchy). Best effort.
fn desktop(title: &str, body: &str, urgency: &str) {
    let _ = std::process::Command::new("notify-send")
        .args(["--app-name=OrphusBot", "--urgency", urgency, title, body])
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;
    use orphusbot_proto::Dialog;

    #[test]
    fn status_counts_running_bots_and_waiting_cards() {
        let bots = vec![
            ("coder".to_owned(), "Coder".to_owned()),
            ("pa".to_owned(), "PA".to_owned()),
        ];
        let mut coder = ThreadView::default();
        coder.apply(ThreadEvent::RunStarted {
            run: 1,
            resumed: false,
            node: None,
            why: None,
        });
        coder.apply(ThreadEvent::DialogOpened {
            dialog: Dialog {
                id: "d1".into(),
                run: 1,
                kind: DialogKind::Approval {
                    tool: "bash".into(),
                    input: json!({}),
                    uncertain: false,
                },
            },
        });
        coder.apply(ThreadEvent::Message {
            role: Role::User,
            text: "hi".into(),
        });
        coder.apply(ThreadEvent::Message {
            role: Role::Assistant,
            text: "Hi!".into(),
        });
        let views = BTreeMap::from([("coder".to_owned(), coder)]);
        let s = status(&bots, &views);
        assert_eq!(
            (s["running"].as_u64(), s["needs_you"].as_u64()),
            (Some(1), Some(1))
        );
        assert_eq!(s["waiting"][0]["text"], "May it use bash?");
        assert_eq!(s["bots"][1]["state"], "idle");
        assert_eq!(s["bots"][0]["reply"], "Hi!");
        assert_eq!(s["bots"][0]["asked"], "hi");
    }
}
