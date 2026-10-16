# Developing OrphusBot

How to build, run and test OrphusBot on your own machine. This covers what is built so far (M0 and M1.1 to M1.3): one server, one node, one bot and one browser page, with durable runs, approvals, passkey sign-in and node enrolment. The node loads the `orphusbot-bridge` extension into Orphus automatically, so every tool call the bot makes is checked first; read-only tools run, and anything else shows an approval card on the page.

## What you need

| Tool | Why | Notes |
|---|---|---|
| [rustup](https://rustup.rs) | Builds the Rust code | The exact toolchain is pinned in `rust-toolchain.toml`; rustup installs it on first build |
| PostgreSQL 16 or newer | The server's database | Any local install, a container, or the GPU box |
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

3. **Start the server.** It applies database migrations on start.

   ```sh
   DATABASE_URL=postgres://localhost/orphusbot cargo run -p orphusbot-server
   ```

4. **Sign in.** Open <http://localhost:7480> (use `localhost`, not `127.0.0.1`: passkeys need a host name). Enter the setup token, then add a passkey when the page asks. After that you sign in with the passkey, and the setup token stops working.

5. **Enrol the node** (once per machine). On the page choose **Add a node**; it shows a command with a one-time code that works for 10 minutes. Run it in another terminal:

   ```sh
   cargo run -p orphusbot-node -- enrol <code>
   ```

   The node makes its own Ed25519 key and saves it in `~/.config/orphusbot/node.json`, readable only by you.

6. **Start the node** and send a message on the page; the reply streams in from Orphus.

   ```sh
   cargo run -p orphusbot-node
   ```

## Settings

All settings are environment variables.

### Server

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | Postgres connection string. For a Unix socket use `postgres://user@localhost/db?host=/socket/dir` |
| `ORPHUSBOT_SETUP_TOKEN` | required | Signs you in for one hour to add your first passkey. Works only while no passkey exists |
| `ORPHUSBOT_ORIGIN` | `http://localhost:7480` | The address browsers use. Passkeys are tied to its host name, so it can't be an IP address. An `https` origin also marks cookies `Secure` |
| `ORPHUSBOT_BIND` | `127.0.0.1:7480` | Address to listen on. Bind to your NetBird address to reach it from other machines; **never** to a public interface |
| `RUST_LOG` | off | Log level, e.g. `info` |

### Node

| Variable | Default | Meaning |
|---|---|---|
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
cargo fmt --all --check
```

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
| `crates/server/src/ui.html` | The M0 web page (replaced by the Leptos UI in M1) |
| `crates/node` | The node daemon: server link and the Orphus engine |

## What M0 deliberately leaves out

These are known simplifications, each marked `ponytail:` in the code, with the milestone that replaces it:

| Simplification | Replaced in |
|---|---|
| One thread, one bot, one node | M1–M3 |
| Streaming text isn't stored; only finished messages are replayed after a reconnect | M2 (batched progress events) |
| Read-only tools still round-trip to the server before running | When it measurably slows bots down |
| Live events fan out inside one server process, not through Postgres `NOTIFY` | When there's more than one server process |
| Plain HTML page instead of the Leptos UI | M1.4 |
| Passkey prompts in progress are kept in memory, so a server restart mid-sign-in means trying again | When there's more than one server process |
| Passkeys and nodes are listed and removed through the API (`GET /api/passkeys`, `POST /api/passkeys/remove`, `GET /api/nodes`, `POST /api/nodes/remove`); there's no settings screen yet | M1.4 (Settings) |
