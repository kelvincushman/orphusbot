# Developing OrphusBot

How to build, run and test OrphusBot on your own machine. This covers what is built so far (M0, M1.1 and M1.2): one server, one node, one bot and one browser page, with durable runs and approvals. The node loads the `orphusbot-bridge` extension into Orphus automatically, so every tool call the bot makes is checked first; read-only tools run, and anything else shows an approval card on the page.

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

2. **Pick two secrets**, each at least 16 characters: one for signing in to the web page, one for the node.

   ```sh
   export ORPHUSBOT_UI_TOKEN=$(openssl rand -base64 24)
   export ORPHUSBOT_NODE_TOKEN=$(openssl rand -base64 24)
   ```

3. **Start the server.** It applies database migrations on start.

   ```sh
   DATABASE_URL=postgres://localhost/orphusbot cargo run -p orphusbot-server
   ```

4. **Start the node** in another terminal, with the same node token:

   ```sh
   cargo run -p orphusbot-node
   ```

5. **Open <http://127.0.0.1:7480>**, sign in with the UI token, and send a message. The reply streams in from Orphus.

## Settings

All settings are environment variables.

### Server

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | Postgres connection string. For a Unix socket use `postgres://user@localhost/db?host=/socket/dir` |
| `ORPHUSBOT_UI_TOKEN` | required | Shared secret for the web page (M0 only; passkeys replace it in M1) |
| `ORPHUSBOT_NODE_TOKEN` | required | Shared secret the node presents (M0 only; per-node keys replace it in M1) |
| `ORPHUSBOT_BIND` | `127.0.0.1:7480` | Address to listen on. Bind to your NetBird address to reach it from other machines; **never** to a public interface |
| `RUST_LOG` | off | Log level, e.g. `info` |

### Node

| Variable | Default | Meaning |
|---|---|---|
| `ORPHUSBOT_NODE_TOKEN` | required | Must match the server's |
| `ORPHUSBOT_SERVER` | `ws://127.0.0.1:7480/node` | The server's node endpoint |
| `ORPHUSBOT_NODE_NAME` | the host name | Shown in the web page |
| `ORPHUS_BIN` | `orphus` | Path to the Orphus binary |
| `ORPHUSBOT_SESSION_DIR` | `~/.local/share/orphusbot/sessions` | Where Orphus keeps the bot's sessions |

## Over NetBird (laptop node, GPU-box server)

Run the server on the GPU box with `ORPHUSBOT_BIND=<gpu-box NetBird IP>:7480`, and the node on the laptop with `ORPHUSBOT_SERVER=ws://<gpu-box NetBird IP>:7480/node`. NetBird encrypts the traffic and its access policies decide which peers can reach the port. M0 has no TLS of its own, so don't expose it any other way.

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
| Shared-token sign-in, with the token kept in an HttpOnly cookie | M1 (passkeys and sessions) |
| Shared node token | M1.3 (per-node keys) |
| Streaming text isn't stored; only finished messages are replayed after a reconnect | M2 (batched progress events) |
| Read-only tools still round-trip to the server before running | When it measurably slows bots down |
| Live events fan out inside one server process, not through Postgres `NOTIFY` | When there's more than one server process |
| Plain HTML page instead of the Leptos UI | M1 |
