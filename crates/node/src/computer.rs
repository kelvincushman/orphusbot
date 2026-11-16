//! The bot's computer: one rootless Podman container per bot (DESIGN §4.4).
//!
//! The engine, and the subscription logins it holds, stay on this machine.
//! Only tool operations run in the container, sent there by the bridge with
//! `podman exec` (DECISIONS D-020). The container:
//! - drops every capability and can't gain new privileges;
//! - has a read-only root, a writable home volume and a small `/tmp`;
//! - has pid, memory and CPU limits;
//! - can reach the internet but not private, CGNAT (NetBird) or link-local
//!   addresses, through nftables rules set in its network namespace from
//!   outside, where the container can't change them.

use std::process::Stdio;

use anyhow::{Context, bail};
use tokio::io::AsyncWriteExt;
use tokio::process::{Child, Command};
use tracing::{info, warn};

/// The home folder inside every computer; the engine's working folder maps onto it.
pub const HOME: &str = "/home/bot";

/// Dropped from inside the container: private, CGNAT (NetBird) and link-local ranges.
const FIREWALL: &str = "table inet orphusbot {
  chain out {
    type filter hook output priority 0; policy accept;
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } reject
    ip6 daddr { fc00::/7, fe80::/10 } reject
  }
}
";

pub struct Spec<'a> {
    /// The container runtime's command, normally `podman`.
    pub runtime: &'a str,
    pub image: &'a str,
    /// Container and volume names derive from this.
    pub bot: &'a str,
    /// Also mount the shared team folder at `/shared` (DESIGN §4.4, Team vs Private).
    pub team: bool,
    /// The memory limit, such as `2g`; set when the computer is created.
    pub memory: &'a str,
    /// For the computer's home page (images/desktop/render-home, which escapes the
    /// text and checks the colour): the bot's name, remit and face colour.
    pub dress: [&'a str; 3],
}

/// Stops a bot's computer, if it's running. Its home volume stays.
pub async fn stop(runtime: &str, bot: &str) {
    let name = format!("orphusbot-{bot}");
    match Command::new(runtime)
        // `--ignore`: every node is told to stop a retired chief's computer,
        // and most never had it.
        .args(["stop", "--ignore", "--time", "0", &name])
        .output()
        .await
    {
        Ok(out) if out.status.success() => {}
        Ok(out) => warn!(
            "stopping {name}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ),
        Err(e) => warn!("stopping {name}: {e}"),
    }
}

impl Spec<'_> {
    pub fn container(&self) -> String {
        format!("orphusbot-{}", self.bot)
    }

    async fn podman(&self, args: &[&str]) -> anyhow::Result<String> {
        let out = Command::new(self.runtime)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .await
            .with_context(|| format!("running {} (is it installed?)", self.runtime))?;
        if !out.status.success() {
            bail!(
                "{} {}: {}",
                self.runtime,
                args.first().unwrap_or(&""),
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    /// Makes sure the computer is running and fenced in; returns its name.
    pub async fn ensure(&self) -> anyhow::Result<String> {
        let name = self.container();
        let team = if self.team { "1" } else { "0" };
        let state = self
            .podman(&[
                "container",
                "inspect",
                "-f",
                "{{.State.Running}} {{.ImageName}} {{index .Config.Labels \"orphusbot.team\"}}",
                &name,
            ])
            .await
            .ok();
        // A bot that moved between team and private needs its mounts changed, and one
        // whose desktop changed needs another image; either means a new container, and
        // its home volume carries over.
        let state = match state {
            Some(s) if !s.ends_with(team) || s.split_whitespace().nth(1) != Some(self.image) => {
                self.podman(&["rm", "-f", "-t", "0", &name]).await?;
                None
            }
            other => other,
        };
        match state.as_deref().and_then(|s| s.split_whitespace().next()) {
            Some("true") => return Ok(name),
            Some(_) => {
                self.podman(&["start", &name]).await?;
            }
            None => {
                let label = format!("orphusbot.team={team}");
                let home = format!("orphusbot-home-{}:{HOME}", self.bot);
                let env = format!("HOME={HOME}");
                // One argument each, never through a shell.
                let dress = ["NAME", "REMIT", "COLOUR"]
                    .iter()
                    .zip(self.dress)
                    .map(|(k, v)| format!("ORPHUSBOT_BOT_{k}={v}"));
                let dress: Vec<String> = dress.collect();
                let memory = format!("--memory={}", self.memory);
                let mut args = vec![
                    "run",
                    "--detach",
                    "--name",
                    &name,
                    "--label",
                    "orphusbot.bot",
                    "--label",
                    &label,
                    "--cap-drop=ALL",
                    "--security-opt=no-new-privileges",
                    "--read-only",
                    "--tmpfs=/tmp:size=512m",
                    "--pids-limit=512",
                    &memory,
                    "--cpus=2",
                    "--volume",
                    &home,
                    "--workdir",
                    HOME,
                    "--env",
                    &env,
                ];
                for d in &dress {
                    args.extend(["--env", d]);
                }
                if self.team {
                    args.extend(["--volume", "orphusbot-team:/shared"]);
                }
                args.extend([self.image, "sleep", "infinity"]);
                self.podman(&args).await?;
                info!(%name, image = self.image, "computer created");
            }
        }
        // The rules live in the container's network namespace, which a (re)start makes
        // new, so apply them every time. If that fails, don't hand out the computer.
        if let Err(e) = self.fence(&name).await {
            let _ = self.podman(&["stop", "--time", "0", &name]).await;
            return Err(e.context("blocking local networks for the computer"));
        }
        Ok(name)
    }

    /// A raw VNC stream to the computer's screen, on the child's stdin and stdout.
    /// The VNC server listens only inside the container (images/desktop).
    pub async fn open_screen(&self) -> anyhow::Result<Child> {
        let name = self.start_existing().await?;
        Command::new(self.runtime)
            .args(["exec", "-i", &name, "socat", "STDIO", "TCP:127.0.0.1:5900"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("starting the screen stream")
    }

    /// Starts the bot's computer if it's stopped, without creating or changing it
    /// (a screen request doesn't know the bot's settings; its runs do).
    async fn start_existing(&self) -> anyhow::Result<String> {
        let name = self.container();
        let running = self
            .podman(&["container", "inspect", "-f", "{{.State.Running}}", &name])
            .await
            .map_err(|_| anyhow::anyhow!("This bot has no computer on this node yet"))?;
        if running != "true" {
            self.podman(&["start", &name]).await?;
            if let Err(e) = self.fence(&name).await {
                let _ = self.podman(&["stop", "--time", "0", &name]).await;
                return Err(e.context("blocking local networks for the computer"));
            }
        }
        Ok(name)
    }

    async fn fence(&self, name: &str) -> anyhow::Result<()> {
        let pid = self
            .podman(&["container", "inspect", "-f", "{{.State.Pid}}", name])
            .await?;
        let mut nft = Command::new(self.runtime)
            .args(["unshare", "nsenter", "-t", &pid, "-n", "nft", "-f", "-"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("starting nft")?;
        nft.stdin
            .take()
            .context("nft stdin")?
            .write_all(FIREWALL.as_bytes())
            .await?;
        let out = nft.wait_with_output().await?;
        if !out.status.success() {
            bail!("nft: {}", String::from_utf8_lossy(&out.stderr).trim());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The home page a computer renders at start: the owner's text is escaped
    /// and a colour that isn't `#RRGGBB` is replaced, so neither can add markup,
    /// CSS or (through `xsetroot` in start-screen) a shell command.
    #[test]
    fn the_home_page_escapes_what_the_owner_wrote() {
        let images = concat!(env!("CARGO_MANIFEST_DIR"), "/../../images/desktop");
        let page = std::env::temp_dir().join(format!("home-{}.html", std::process::id()));
        let render = |name: &str, remit: &str, colour: &str| {
            let out = std::process::Command::new("python3")
                .arg(format!("{images}/render-home"))
                .arg(format!("{images}/home.html"))
                .arg(&page)
                .env("ORPHUSBOT_BOT_NAME", name)
                .env("ORPHUSBOT_BOT_REMIT", remit)
                .env("ORPHUSBOT_BOT_COLOUR", colour)
                .output()
                .expect("python3 is installed");
            assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
            let html = std::fs::read_to_string(&page).unwrap();
            (String::from_utf8(out.stdout).unwrap(), html)
        };

        let (colour, html) = render(
            "<script>alert(1)</script>\"'</style>$name",
            "a & b </style><img src=x onerror=1> ${colour}",
            "red;}</style><script>x</script>$(touch /tmp/x)",
        );
        assert_eq!(colour, "#2F6BFF\n", "a bad colour becomes the default");
        assert!(html.contains("<h1>&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#x27;&lt;/style&gt;$name</h1>"));
        assert!(html.contains("<p>a &amp; b &lt;/style&gt;&lt;img src=x onerror=1&gt; ${colour}</p>"));
        assert!(!html.contains("alert(1)</script>") && !html.contains("<img"));
        // Only the template's own tags: one style block, one script block.
        assert_eq!(html.matches("</style>").count(), 1);
        assert_eq!(html.matches("<script").count(), 1);
        assert!(!html.contains("red;") && !html.contains("touch"));

        for bad in ["#FFF", "#12345G", "#1234567", "#123456\n", " #123456", "blue", ""] {
            assert_eq!(render("Rex", "", bad).0, "#2F6BFF\n", "{bad:?}");
        }
        let (colour, html) = render("Rex", "Reads the post", "#ff9a1f");
        assert_eq!(colour, "#ff9a1f\n");
        assert!(html.contains("solid #ff9a1f") && html.contains("<h1>Rex</h1>"));
        let _ = std::fs::remove_file(page);
    }

    /// `cargo test -p orphusbot-node -- --ignored` on a machine with rootless Podman.
    #[tokio::test]
    #[ignore = "needs rootless podman and a network to pull the image"]
    async fn a_computer_is_fenced_in() {
        let spec = Spec {
            runtime: "podman",
            image: "docker.io/library/debian:trixie-slim",
            bot: "fence-test",
            team: true,
            memory: "2g",
            dress: ["Fence", "", ""],
        };
        let name = spec.ensure().await.unwrap();
        let ok = |args: &[&str]| {
            std::process::Command::new("podman")
                .args(args)
                .output()
                .unwrap()
                .status
                .success()
        };
        let pid = spec
            .podman(&["container", "inspect", "-f", "{{.State.Pid}}", &name])
            .await
            .unwrap();
        let fenced = ok(&[
            "unshare",
            "nsenter",
            "-t",
            &pid,
            "-n",
            "nft",
            "list",
            "table",
            "inet",
            "orphusbot",
        ]);
        let root_writable = ok(&["exec", &name, "touch", "/x"]);
        let home_writable = ok(&["exec", &name, "touch", "/home/bot/x"]);
        let shared_writable = ok(&["exec", &name, "touch", "/shared/x"]);
        let caps = spec
            .podman(&["exec", &name, "grep", "CapEff", "/proc/self/status"])
            .await
            .unwrap();
        // A second ensure reuses the running computer.
        assert_eq!(spec.ensure().await.unwrap(), name);
        let _ = spec.podman(&["rm", "-f", "-t", "0", &name]).await;
        let _ = spec
            .podman(&["volume", "rm", "orphusbot-home-fence-test"])
            .await;

        assert!(
            fenced,
            "the firewall table is in the container's network namespace"
        );
        assert!(!root_writable, "root is read-only");
        assert!(home_writable, "home is writable");
        assert!(shared_writable, "a team bot gets the shared folder");
        assert!(
            caps.ends_with("0000000000000000"),
            "no capabilities: {caps}"
        );
    }
}
