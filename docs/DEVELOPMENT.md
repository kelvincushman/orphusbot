# Developing OrphusBot

How to build, run and test OrphusBot on your own machine. This covers what is built so far (M0 and M1.1 to M1.4): one server, one node and one bot, with durable runs, approvals, passkey sign-in, node enrolment and the Leptos web UI. The node loads the `orphusbot-bridge` extension into Orphus automatically, so every tool call the bot makes is checked first; read-only tools run, and anything else shows an approval card on the page.

## What you need

| Tool | Why | Notes |
|---|---|---|
| [rustup](https://rustup.rs) | Builds the Rust code | The exact toolchain is pinned in `rust-toolchain.toml`; rustup installs it on first build |
| PostgreSQL 16 or newer | The server's database | Any local install, a container, or the GPU box |
| [Podman](https://podman.io), rootless | Runs each bot's computer | Your distribution's package (Arch: `podman`), set up for rootless use (`/etc/subuid` and `/etc/subgid` entries for your user); `nft` and `nsenter` must be installed. Set `ORPHUSBOT_RUNTIME=none` to run tools on this machine instead, without isolation |
| [Trunk](https://trunkrs.dev) | Builds the web UI to WebAssembly | `cargo install --locked trunk`, or a release binary. The `wasm32-unknown-unknown` target comes with the pinned toolchain |
| [Orphus](https://github.com/kelvincushman/orphus) | The agent the node runs | `orphus --mode rpc` must work, and you must be signed in to a model provider (`orphus` then `/login`) |

## Run it

1. **Create a database** (once):

   ```sh
   createdb orphusbot
   ```

2. **Pick a setup token** of at least 16 characters, for your first sign-in:

   ```sh
   export ORPHUSBOT_SETUP_TOKEN=$(openssl rand -base64 24)
   ```

3. **Build the web UI** (again after changing `crates/ui`; `trunk watch` rebuilds on save):

   ```sh
   (cd crates/ui && trunk build --release)
   ```

4. **Start the server.** It applies database migrations on start, and serves the UI from `crates/ui/dist`.

   ```sh
   DATABASE_URL=postgres://localhost/orphusbot cargo run -p orphusbot-server
   ```

5. **Sign in.** Open <http://localhost:7480> (use `localhost`, not `127.0.0.1`: passkeys need a host name). Enter the setup token, then add a passkey when the page asks. After that you sign in with the passkey, and the setup token stops working.

6. **Enrol the node** (once per machine). On the page choose **Add a node**; it shows a command with a one-time code that works for 10 minutes. Run it in another terminal:

   ```sh
   cargo run -p orphusbot-node -- enrol <code>
   ```

   The node makes its own Ed25519 key and saves it in `~/.config/orphusbot/node.json`, readable only by you.

7. **Start the node** and send a message on the page; the reply streams in from Orphus.

   ```sh
   cargo run -p orphusbot-node
   ```

## System 1 (Laya)

Optional. Run laya-serve (Apache-2.0) and point the server at it:

```sh
uv venv ~/.local/share/laya-venv --python 3.12
uv pip install --python ~/.local/share/laya-venv/bin/python torch --index-url https://download.pytorch.org/whl/cpu
uv pip install --python ~/.local/share/laya-venv/bin/python 'laya[serve]==0.4.8'
LAYA_HOST=127.0.0.1 LAYA_PORT=7600 LAYA_MODELS=english ~/.local/share/laya-venv/bin/laya-serve
export ORPHUSBOT_LAYA_URL=http://127.0.0.1:7600
```

The English checkpoint needs about 2.5 GB of memory. On a small laptop answers can take seconds, so raise `ORPHUSBOT_LAYA_TIMEOUT_MS` for local testing; on the GPU box they take tens of milliseconds. Settings → **Decisions** shows what it decided.

## Desktop app

Needs WebKitGTK 4.1 and its development files (Arch: `webkit2gtk-4.1`; Debian and Ubuntu: `libwebkit2gtk-4.1-dev librsvg2-dev libayatana-appindicator3-dev`).

```sh
ORPHUSBOT_URL=http://localhost:7480 cargo run -p orphusbot-desktop
```

**A bot computer with a screen.** Build the desktop image once, then point the node at it:

```sh
podman build -t localhost/orphusbot-desktop images/desktop
export ORPHUSBOT_COMPUTER_IMAGE=localhost/orphusbot-desktop
```

**The same screen in E2B.** Build the image as an E2B template once (needs `E2B_API_KEY` in your shell):

```sh
npx @e2b/cli template create orphusbot-desktop --path images/desktop --dockerfile Containerfile \
  --cmd "env ORPHUSBOT_SCREEN_WEBSOCKET=1 /usr/local/bin/start-screen sleep infinity" \
  --ready-cmd "test -e /tmp/.X11-unix/X1"
```

Then set `ORPHUSBOT_E2B_TEMPLATE=orphusbot-desktop` on the server. A bot in E2B gets a screen you can watch and take over like a local one.

The chat header's **Screen** button shows the bot's screen live; **Take control** lets you use it.

Without `ORPHUSBOT_URL`, the first run asks for the server address and saves it; `--reset` forgets it. Sign in with **Sign in with another device**: approve the code it shows from a browser where you have a passkey (Settings → Link a device, or open the link it shows). To build installable packages (`.deb`, `.rpm`, AppImage): `cd crates/desktop && npx @tauri-apps/cli@2 build`.

**Flutter app.** Needs the Flutter SDK (`git clone -b stable https://github.com/flutter/flutter ~/.local/share/flutter`), and for Linux `cmake`, `ninja`, `clang` and GTK 3 headers. Then:

```sh
cd apps/orphusbot_app
flutter test                       # the reducer tests
flutter build linux --release      # build/linux/x64/release/bundle/orphusbot-app
```

The bot faces come from `design/bot-avatar` and are built with the [Rive CLI](https://rive.app/docs/cli/overview) (no account needed); its README has the commands, which put one `.riv` per style in `apps/orphusbot_app/assets/faces/` and animated WebPs for the bar panel in `omarchy/kelvincushman.orphusbot/faces/`.

On Omarchy, copy the bundle to `~/.local/share/orphusbot-app`, link `orphusbot-app` into `~/.local/bin`, and the bar panel's **Open chat** starts it.

**macOS app.** It has to be built on a Mac. With Xcode's command line tools, Rust and Node.js installed, and the Mac's SSH key on the GPU box, run `sh scripts/macos-setup.sh <user>@<gpu-box>` from a clone: it builds the app, installs `/Applications/OrphusBot.app`, and adds a launchd agent that keeps the tunnel to the server open at `http://localhost:7480` (see DEPLOY.md, "Before the domain").

**Android app.** The same crate builds an APK. You need the Android SDK (platform-tools, a platform, build-tools, the NDK) and JDK 17 or newer, the Rust Android targets (`rustup target add x86_64-linux-android aarch64-linux-android`), and these set:

```sh
export ANDROID_HOME=~/Android/Sdk NDK_HOME=~/Android/Sdk/ndk/<version> JAVA_HOME=<your JDK>
cd crates/desktop && npm install
npm run tauri -- android build --debug --apk --target x86_64   # an emulator; aarch64 for a phone
```

The APK lands in `gen/android/app/build/outputs/apk/`. In an emulator, run `adb reverse tcp:7480 tcp:7480` so the app can reach a server on your machine at `http://localhost:7480` (plain http only works for localhost). Sign in the same way as the desktop app. A real phone needs your server's https address.

## Settings

All settings are environment variables.

### Server

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | Postgres connection string. For a Unix socket use `postgres://user@localhost/db?host=/socket/dir` |
| `ORPHUSBOT_SETUP_TOKEN` | required | Signs you in for one hour to add your first passkey. Works only while no passkey exists |
| `ORPHUSBOT_ORIGIN` | `http://localhost:7480` | The address browsers use. Passkeys are tied to its host name, so it can't be an IP address. An `https` origin also marks cookies `Secure` |
| `ORPHUSBOT_UI_DIR` | `crates/ui/dist` | The built web UI, served at `/` |
| `ORPHUSBOT_LAYA_URL` | none | laya-serve for System 1, such as `http://127.0.0.1:7600`. Without it System 1 abstains: the inbox keeps its messages and every non-read tool call asks |
| `ORPHUSBOT_LAYA_TIMEOUT_MS` | `1500` | How long to wait for Laya before abstaining |
| `ORPHUSBOT_ROUTE_THRESHOLD` | `0.85` | Confidence Laya needs to move an inbox message to another bot |
| `ORPHUSBOT_GATE_THRESHOLD` | `0.95` | Confidence Laya needs to let a file change inside a bot's computer through (never below 0.9) |
| `ORPHUSBOT_ROUTINE_RUNS_PER_DAY` | `20` | How many runs routines may start per day, across all routines (PRD Q3) |
| `ORPHUSBOT_NTFY_URL` | none | An ntfy topic to push to, such as `https://ntfy.example.com/orphusbot-<random>`; nothing is pushed without it |
| `ORPHUSBOT_NTFY_TOKEN` | none | ntfy access token, if the topic needs one |
| `ORPHUSBOT_DAILY_TOKEN_BUDGET` | none | Input + output tokens a day; crossing it warns on the wrist and by push, once a day |
| `ORPHUSBOT_MIN_BATTERY` (node) | `30` | An unplugged laptop node takes work only with at least this much charge (percent); `101` never works unplugged |
| `ORPHUSBOT_MCP_COMMANDS` (node) | none | Programs this node may run as MCP servers, comma-separated, such as `npx,uvx`. A connection whose command isn't listed is left out on this node |
| `ORPHUSBOT_E2B_API_KEY` | none | Lets bots keep their computer in E2B (the bot's **Computer** setting). Optional: `ORPHUSBOT_E2B_TEMPLATE` (default `base`), `ORPHUSBOT_E2B_TIMEOUT_SECS` (default 3600: a sandbox pauses itself this long after a run starts), `ORPHUSBOT_E2B_API_URL`, `ORPHUSBOT_E2B_SANDBOX_URL` (tests). Check a key with `cargo test -p orphusbot-server live_e2b -- --ignored` (makes and deletes one sandbox). For a screen, build the desktop image as a template (below) and set `ORPHUSBOT_E2B_TEMPLATE=orphusbot-desktop` |
| `ORPHUSBOT_SECRET_KEY_FILE` | none | A file of exactly 32 random bytes (`head -c 32 /dev/urandom > key`) that encrypts stored tokens; without it, connections can't keep a token. Losing it loses every stored token |
| `ORPHUSBOT_HANDS_FREE_ALLOWED` | on | Set to `false` to switch hands-free capture off for every device (the kill switch) |
| `ORPHUSBOT_CAPTURE_RETENTION_DAYS` | `7` | Days to keep captured conversation text |
| `ORPHUSBOT_BIND` | `127.0.0.1:7480` | Address to listen on. Bind to your NetBird address to reach it from other machines; **never** to a public interface |
| `RUST_LOG` | off | Log level, e.g. `info` |

### Node

| Variable | Default | Meaning |
|---|---|---|
| `ORPHUSBOT_EXTRACT_MODEL` | Orphus default | Model for capture extraction (pick a cheap or local one) |
| `ORPHUSBOT_QUIET_HOURS` | none | Local hours when this node takes no new work, such as `22-7` |
| `ORPHUSBOT_RUNTIME` | `podman` | The container runtime for bots' computers, or `none` to run tools on this machine (not isolated) |
| `ORPHUSBOT_COMPUTER_IMAGE` | `docker.io/library/debian:trixie-slim` | Image for a bot's computer |
| `ORPHUSBOT_NODE_KEY` | `~/.config/orphusbot/node.json` | The node's name and private key, written by `enrol` |
| `ORPHUSBOT_SERVER` | `ws://127.0.0.1:7480/node` | The server's node endpoint; `wss://` when the server is behind HTTPS ([DEPLOY.md](DEPLOY.md)) |
| `ORPHUSBOT_NODE_NAME` | the host name | The name to enrol under (letters, digits, `.`, `_`, `-`). After enrolling, the name comes from the key file |
| `ORPHUS_BIN` | `orphus` | Path to the Orphus binary |
| `ORPHUSBOT_SESSION_DIR` | `~/.local/share/orphusbot/sessions` | Where Orphus keeps the bot's sessions |

## Over NetBird (laptop node, GPU-box server)

Passkeys need HTTPS on a host name, so the server sits behind Caddy with a real certificate for a name that points at the GPU box's NetBird address. [DEPLOY.md](DEPLOY.md) walks through it.

## Test

```sh
DATABASE_URL=postgres://localhost/postgres cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo clippy -p orphusbot-ui --target wasm32-unknown-unknown -- -D warnings
cargo fmt --all --check
```

The computer test needs rootless Podman, so it only runs when asked: `cargo test -p orphusbot-node -- --ignored`.

Database tests use `#[sqlx::test]`, which creates and drops a temporary database for each test, so `DATABASE_URL` must point at a server where you can create databases.

## Changing SQL

Queries are checked at compile time. CI builds with `SQLX_OFFLINE=true` against the query data committed in `.sqlx/`. After adding or changing a query or a migration:

1. Apply the migrations to a scratch database, for example `orphusbot_build`.
2. Rebuild with that database and the offline directory set, which rewrites `.sqlx/`:

   ```sh
   DATABASE_URL=postgres://localhost/orphusbot_build SQLX_OFFLINE_DIR=$PWD/.sqlx cargo build --workspace
   ```

3. Commit the changed files in `.sqlx/` with your change. Delete any that no longer match a query.

## Layout

| Path | What |
|---|---|
| `crates/proto` | Wire types shared by server, node and (later) the UI |
| `crates/server` | The server: HTTP API, event stream, node link, database |
| `crates/server/migrations` | SQL migrations, applied on start |
| `crates/proto/src/view.rs` | The thread reducer every client uses to turn events into what it shows |
| `crates/ui` | The Leptos web UI (browser only; built with Trunk) |
| `crates/desktop` | The Tauri 2 desktop and Android app: a window onto the server (`gen/android` is the Android project) |
| `crates/device` | The wearable's wire constants and cue table, tested against its firmware and app |
| `crates/ui/novnc` | noVNC 1.7.0, vendored unmodified (MPL-2.0), for the screen panel |
| `images/desktop` | The bot computer image with a screen (VNC, openbox, Chromium) |
| `crates/node` | The node daemon: server link and the Orphus engine |

## What M0 deliberately leaves out

These are known simplifications, each marked `ponytail:` in the code, with the milestone that replaces it:

| Simplification | Replaced in |
|---|---|
| System 1 asks which bot (inbox messages), which bot / urgency / act-now (tickets), pass or ask (gate) and worth running (routines); untrusted comes with E2B | M4 |
| Streaming text isn't stored; only finished messages are replayed after a reconnect | M2 (batched progress events) |
| Read-only tools still round-trip to the server before running | When it measurably slows bots down |
| Live events fan out inside one server process, not through Postgres `NOTIFY` | When there's more than one server process |
| Passkey prompts in progress are kept in memory, so a server restart mid-sign-in means trying again | When there's more than one server process |
| The UI shows one bot and re-renders the whole conversation when an item changes | M3 (bots), and a keyed list when threads get long |

**Google for bots (D-039).** On a node: install Google's [`gws`](https://github.com/googleworkspace/cli) (a release binary in `~/.local/bin`). Sign in once on a machine with a browser: `gws auth login -s gmail,calendar,tasks,drive,docs,sheets,people` (an OAuth Desktop client from your Google Cloud project, with yourself as a test user), then `gws auth export --unmasked > gws-credentials.json`. Copy that file to the node (`chmod 600`), and add to its `node.env`: `ORPHUSBOT_GWS=/path/to/gws` and `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/gws-credentials.json`. Each bot's Google access is in its settings.

**Gallery (D-040).** The server keeps gallery files in `ORPHUSBOT_GALLERY_DIR` (default `~/.local/share/orphusbot/gallery`); point it at a disk with room for video.
