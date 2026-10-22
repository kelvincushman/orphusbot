# OrphusBot: design

| | |
|---|---|
| Status | Draft 0.1, for review |
| Date | 2026-10-16 |
| Owner | Kelvin Lee (@kelvincushman) |
| Licence | MIT, everything open source (see §17 for what must still never be committed) |
| Companion docs | [PRD.md](PRD.md) (requirements B-*, journeys, milestones) · [research/rakazo-architecture.md](research/rakazo-architecture.md) (the Rakazo study this design draws on; crate versions in its §7) · OmarchyWearable `README.md`, `docs/SERVER.md`, `docs/APP.md`, `docs/product/BUTTON_FEEDBACK_SPEC.md` · orphus-desktop `docs/DESIGN.md` §5 and §7 |

Decided inputs: the wearable has **no speaker, by design** (NeoPixel + vibration out, button + mic in), and its habitat channel must be **duplex** (§9.3) · separate app (web, desktop, Android) · Rust first · Laya (Jev family) as System 1 · own machines first, E2B second · **orphusbot-server runs on the always-on GPU box** · **phone is Android** · the **OmarchyWearable** joins as a first-class input device · everything is open source.

---

## 1. System overview

```
                                   NetBird mesh (WireGuard + ACLs; nothing public)
 ┌────────────────────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                                │
 │  Wearable (XIAO nRF52840)     Android phone                                 Laptop (Omarchy)    │
 │  button · mic · LED · haptic  ┌──────────────────────────────┐              ┌───────────────┐   │
 │        │ BLE GATT             │ Wearable companion (Flutter) │              │ Tauri desktop │   │
 │        └─────────────────────►│  BLE bridge, on-device STT,  │              │ (Leptos UI)   │   │
 │                               │  speaker identity, fg service│              │ orphusbot-node│   │
 │                               ├──────────────────────────────┤              │  engines,     │   │
 │                               │ OrphusBot (Tauri, Leptos UI) │              │  containers   │   │
 │                               │ ntfy / UnifiedPush           │              └──────┬────────┘   │
 │                               └──────┬─────────────┬─────────┘                     │            │
 │            device channel (HTTP+WS)  │             │ HTTPS + SSE                   │ node link  │
 │                                      ▼             ▼                               ▼            │
 │  ┌──────────────────────────────────────────────────────────────────────────────────────────┐  │
 │  │ GPU box (always on)                                                                       │  │
 │  │  orphusbot-server (Rust)                                                                  │  │
 │  │   api · events/SSE · runs · scheduler · placement · approvals · decisions · device        │  │
 │  │   channel · capture miner · connections · E2B client                                      │  │
 │  │  Postgres · laya-serve (Python) · qwen3-asr (Python) · ntfy                               │  │
 │  │  orphusbot-node (Rust): engines + GPU containers                                          │  │
 │  └───────────────────────────────────────────────────┬──────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────┼─────────────────────────────────────────┘
                                                        │ HTTPS
                                                        ▼
                                              E2B (overflow, untrusted)
```

Five runtimes, one source of truth (Postgres on the GPU box):

| Runtime | Language | Where | Job |
|---|---|---|---|
| `orphusbot-server` | Rust | GPU box | Everything durable: tasks, runs, events, routines, approvals, decisions, device channel, capture, placement |
| `orphusbot-node` | Rust | GPU box and laptop | Engines (`orphus --mode rpc`), per-bot containers, screen proxy |
| `orphusbot-bridge` | TypeScript (tiny) | Inside each engine | Redirect tool operations; ask the server at every `tool_call` |
| Clients | Rust (Leptos) in Tauri 2 / browser | Laptop, phone, any browser on NetBird | Views and intent; no business logic |
| Wearable stack | C (Zephyr) + Dart (Flutter) | Wearable + phone | Button, cues, audio, on-device STT, speaker identity |

The GPU box being always on settles PRD Q1 and Q2: the server lives there, the GPU box is always a node, so "both nodes offline" only happens if the GPU box itself is down, in which case nothing runs and the phone shows that.

---

## 2. Repository and crate layout

One public monorepo, `kelvincushman/orphusbot`, MIT. The wearable lives in `wearable/` as a cleaned snapshot of the former OmarchyWearable repository (see §17 and DECISIONS D-012). It keeps its own toolchains (Zephyr, Flutter) and builds on its own.

```
orphusbot/
  Cargo.toml                 workspace
  crates/
    proto/                   shared types: ids, commands, events, reducers, errors (server + UI + node)
    server/                  axum binary: api, sse, runs, scheduler, placement, approvals, capture
    node/                    node daemon binary: link, engines, computers, screens, bridge socket
    decide/                  DecisionModel trait, HttpLaya, OrtLaya, NullModel, wrappers, question catalogue
    computer/                ComputerProvider trait, shared types, the Podman backend
    e2b/                     thin E2B client (REST control plane + Connect-RPC envd)
    device/                  wearable device channel: Rust port of server-contract (commands, cues, gate)
    capture/                 transcript store, miner pipeline, proposals
    ui/                      Leptos CSR app (all views)
    testkit/                 fakes for every trait, scripted fake engine, wiremock fixtures
  apps/
    desktop/                 Tauri 2 shell (Linux first); the same crate builds the Android app (gen/android)
  bridge/                    orphusbot-bridge Orphus extension (TypeScript)
  images/desktop/            bot desktop container image (Containerfile)
  images/omarchy/            Omarchy-style desktop image: Arch, Sway, wayvnc, and the `computer` command (D-043)
  wearable/                  the wearable: firmware/, app/, hardware/, server-contract/, docs/ (own README)
  deploy/                    systemd units, Postgres setup, NetBird ACL notes, ntfy config
  docs/                      PRD.md, DESIGN.md, ADRs
```

Rules:

- `proto` has no I/O and no async runtime, so it compiles to wasm for the UI.
- Every external system is behind a trait with a fake in `testkit`.
- The `device` crate owns the wire constants for the wearable. The firmware header and the Dart codec stay mirrored, and a contract test in CI compares all three (§9.6).

---

## 3. orphusbot-server

### 3.1 Modules

| Module | Responsibility | Key PRD IDs |
|---|---|---|
| `api` | Typed procedures over JSON (`POST /rpc/<name>`), auth middleware, OpenAPI via utoipa | B-CLI-* |
| `events` | Append-only event log, per-thread `seq`, `PgListener` fan-out, SSE `GET /events?thread=…&after=…` | B-RUN-07, B-CLI-02 |
| `runs` | Intake, leases and fences, steering queue, effect ledger, reconciler | B-RUN-01…05 |
| `jobs` | `graphile_worker` task registry and crontab | B-RTN-* |
| `placement` | Chooses node or E2B per run | B-CMP-07 |
| `approvals` | Static classes, user rules, approval cards, gate replies to bridges | B-DEC-03, -06, -07 |
| `decisions` | Calls `decide`, writes receipts, captures labels, runs calibration apply/rollback | B-DEC-* |
| `nodes` | Node link endpoint, inventory, heartbeats, command routing | B-NOD-* |
| `device` | Wearable device channel (§9) | B-WRB-* |
| `capture` | Transcript store and miner (§10) | B-CAP-* |
| `connections` | MCP server records, grants, OAuth material, per-engine MCP config | B-INT-* |
| `notify` | Digest batching, ntfy publish, wearable cues | B-DEC-04, B-CLI-05 |
| `auth` | Passkeys, sessions, device tokens | B-CLI-06 |

### 3.2 Intake

Every source turns into the same call, `runs::intake(source, thread, content)`:

| Source | Origin |
|---|---|
| `chat` | A client message |
| `ticket` | Ticket created or assigned |
| `routine` | `routine.wakeup` job |
| `webhook` | `POST /hooks/<id>` with a per-hook secret |
| `wearable` | A filed button capture (§9.3) |
| `proposal` | Kelvin accepts a capture proposal as a task (§10.4) |

Inside one transaction:

1. If the target bot has a run in `waiting_input` and nothing steerable → the content answers it.
2. Else if a run for this thread is live → insert a `steering_message`.
3. Else insert `task` + `run(queued)`. If the source has no explicit bot, the run is created **unassigned** and a `triage` job is enqueued instead of `run.continue`.
4. Append the message event and `NOTIFY orphusbot_events, '<thread>:<seq>'`.

Job keys collapse duplicates: `run:<id>`, `triage:<task>`, `routine:<id>:<at>`.

### 3.3 Run loop (server side)

The engine owns the in-turn loop. The server owns everything that must survive a crash:

```
triage(task)         → decide::triage → assign bot, provider, effort, urgency, act/ask, trust
                       → if act/ask = ask: post a "should I start?" card, run waits in waiting_input
                       → else enqueue run.continue
run.continue(run)    → lease run (owner=server instance, fence+1, expiry 5 min)
                       → placement::choose → node N or E2B
                       → computer lease (computer, bot, fence)
                       → nodes::send(N, StartTurn{run, fence, session, prompt, model, thinking, mcp_config})
                       → wait for node events; heartbeat every 60 s renews both leases
node events          → append to event log (progress deltas batched ~250 ms), update run status
TurnEnded            → release leases, mark completed / failed, write outcome to linked receipts
reconcile (30 s)     → advisory-lock leader: re-enqueue expired leases, arm due routines,
                       remind waiting runs (digest), expire stale waits
```

Fences are checked on every node message: a message carrying an old fence is dropped and the node is told to abort that turn. This is what makes "kill the node mid-run and it recovers" safe (PRD M1 exit).

### 3.4 Effect ledger

`external_effect(run_id, tool, args_hash, state, request, result, decision_id, approved_by)`. States: intended → approved/denied → executing → completed / failed / uncertain.

- The bridge asks the server **before** a consequential tool runs (§5). The server inserts `intended`, gates it, and moves it to `approved` or `denied`.
- The node reports `executing` and then `completed` with the result.
- After a crash, a replayed call with the same `(run, tool, args_hash)` returns the stored result if `completed`. If it was `executing`, it becomes `uncertain`, is never re-run, and a card asks Kelvin what happened.

### 3.5 Jobs

| Task | Concurrency | Purpose |
|---|---|---|
| `triage` | 8 | System 1 triage of an unassigned task |
| `run.continue` | per-node slots | Start or resume a turn |
| `routine.wakeup` | 4 | Claim a due routine; optional pre-flight; create task (built as a scheduler loop, D-024) |
| `capture.mine` | 2 | Run the miner over a closed transcript window (§10) |
| `computer.sleep` / `computer.destroy` | 4 | Idle pause and TTL clean-up |
| `notify.digest` | 1 | Assemble and send the digest |
| `decisions.calibrate` | 1 | Fit thresholds from labels (manual trigger only) |

---

## 4. orphusbot-node

### 4.1 Link

- One outbound WebSocket to `wss://<gpu-box NetBird IP>:7480/node`, carrying length-prefixed JSON frames defined in `proto::node`.
- **Auth:** the owner creates a one-time enrolment code while signed in (10 minutes, single use, stored hashed). `orphusbot-node enrol <code>` generates an Ed25519 key, sends the public key with the code in an `enrol` frame, and saves the name and private key in a `0600` file. Every connection starts with a server `challenge` nonce; the node's `hello` carries the hex signature of `link_proof(name, nonce)`. Re-enrolling a name replaces its key; removing a node drops its live link (D-017). NetBird ACLs allow only node → server:7480 and server → node:7481 (screens).
- **Heartbeat (10 s):** load, free slots, `gpu`, `gui`, power (`ac` / `battery` from `/sys/class/power_supply`), quiet-hours flag, provider login status per provider (`ok` / `expired` / `missing`), live engines and computers. **Built (M2.3):** load (one-minute load average as a percentage of CPUs), on battery (mains supplies present and none online), and quiet (`ORPHUSBOT_QUIET_HOURS`, such as `22-7`).
- The node on the GPU box connects to the server over loopback but uses the same protocol.

### 4.2 Engines

- One `orphus --mode rpc --name <bot role> --session <file> -e <path to orphusbot-bridge>` per active bot session. Session files live under `~/.local/share/orphusbot/sessions/<bot>/`.
- Lifecycle follows orphus-desktop DESIGN §5.1: restart with backoff (1, 2, 4… 60 s), park after 10 idle minutes, resume on the next `StartTurn`.
- The node translates `StartTurn` into RPC: `set_model`, `set_thinking_level`, then `prompt`. Steering becomes `steer` or `follow_up`, stop becomes `abort`.
- RPC events go up the link unchanged, wrapped with `{run, fence}`. `extension_ui_request` (questions, OAuth prompts) is relayed as a card and the answer comes back as `extension_ui_response`.
- MCP config is written per session to a file the engine reads at start. It contains only the servers granted to that bot.

### 4.3 Bridge channels

**Gate (built, M1.2): Orphus's own dialog protocol, no socket.** For each tool call the bridge opens an `input` dialog titled `orphusbot-gate` whose placeholder is `{toolCallId, tool, input}`. Orphus writes it to stdout as an `extension_ui_request`; the node relays every dialog (`select`, `confirm`, `input`, `editor`) to the server as `FromNode::Dialog`; the server answers with a complete `extension_ui_response` in `ToNode::DialogResponse`, which the node writes to the engine's stdin. The gate's answer is `allow` or `deny:<reason>`; any other answer blocks. Tool completions come from Orphus's own `tool_execution_end` events, mapped to `FromNode::ToolDone`, so the bridge needs no result hook (D-015).

**Ops (built, M2.1): `podman exec`, no socket.** The engine and the computer are on the same node, so the bridge runs each tool operation in the container itself with `podman exec`, the way Orphus's `ssh.ts` example runs them over ssh. Arguments are passed as positional parameters (`bash -c 'cat -- "$1"' bash <path>`), never spliced into a command line. The node tells the bridge which computer to use through `ORPHUSBOT_COMPUTER`, `ORPHUSBOT_RUNTIME` and `ORPHUSBOT_COMPUTER_HOME` (D-020). The socket idea returns only if E2B runs need operations to go through the server (M4).

### 4.4 Computers on a node

- **Built (M2.1):** `node::computer` drives the `podman` CLI (no daemon socket, no client library). One container per bot, `orphusbot-<bot>`, running `sleep infinity`, created on the engine's first turn and reused after; home is the named volume `orphusbot-home-<bot>` at `/home/bot`. The `ComputerProvider` trait arrives when E2B gives it a second implementation (M4).
- **Images:** stock `debian:trixie-slim` for code-only bots, or `images/desktop` (built, M2.2): Debian slim with TigerVNC Xvnc on `:1` (1280×800, listening on 127.0.0.1:5900 *inside* the container only, no authentication because nothing outside can reach it), openbox, Chromium (`--no-sandbox`: the container is the sandbox), `socat`, `xdotool`. Its entrypoint starts the display with everything under `/tmp`, so it works with a read-only root. Chosen with `ORPHUSBOT_COMPUTER_IMAGE`.
- **Omarchy desktop (D-043):** a bot whose `desktop` is `omarchy` gets `images/omarchy` (`ORPHUSBOT_OMARCHY_IMAGE`, default `localhost/orphusbot-omarchy:latest`) instead: Arch Linux with Sway headless (pixman), Omarchy v3.8.4's look, waybar, alacritty, fuzzel and Chromium, and wayvnc on the same loopback port 5900, so screens and takeover work unchanged. Same security flags and firewall. Inside it, `computer screenshot|click|type|key|open` lets the bot drive the screen from bash (grim and swaymsg, and input through wayvnc on the loopback port). The node replaces a computer whose image no longer matches its bot's setting, keeping its home volume. Not offered for E2B computers.
- **Isolation:**
  - rootless, default seccomp, `--cap-drop=ALL`, read-only root with a writable home volume;
  - `pids`, CPU and memory limits from the bot spec;
  - **built:** nftables rules in the container's own network namespace reject RFC 1918, CGNAT (NetBird `100.64.0.0/10`), link-local and IPv6 ULA/link-local destinations. The node applies them from outside (`podman unshare nsenter -t <pid> -n nft -f -`) on every start; the container has no capabilities, so it can't change them. If they can't be applied, the computer is stopped and the run fails.
- **Team vs Private:** one container per bot. **Built (M3.1):** team bots also mount the `orphusbot-team` volume at `/shared` (one team for now); private bots get nothing extra. The container carries an `orphusbot.team` label, and a bot that switches scope gets a new container on its next run (its home volume carries over). Opening a screen only starts an existing computer; it never creates or changes one.
- **GPU:** CDI `nvidia.com/gpu=all` only on the GPU box and only when the bot is marked `trusted` and the task needs it.
- **Screens (built, M2.2):** the UI's noVNC opens `GET /api/screen` (a WebSocket under the session guard, subprotocol `binary`). The server gives it a stream number, sends `ToNode::ScreenOpen`, and relays VNC bytes as binary node-link frames (8-byte big-endian stream number + data); the node runs `podman exec -i <computer> socat STDIO TCP:127.0.0.1:5900` and pipes them. `ScreenClose`/`ScreenClosed` end a stream; a computer without a screen closes it with a reason. Clients never reach a node directly and the computer publishes no port (D-021). Watching is view-only; **Take control** lets the owner's input through. One owner, so control is a client switch, not a server lease.
- **Takeover (built, M2.2):** the bridge's `request_takeover {reason}` tool opens a confirm dialog titled `orphusbot-takeover`; the server shows it as a `Takeover` card (**Open screen**, **Done**, **I can't**) and the bot waits for the answer. It runs without an approval card, since it only asks the owner.

---

## 5. orphusbot-bridge (TypeScript extension)

Target: under 300 lines, no policy. Source: `bridge/orphusbot-bridge.ts`; the node embeds it and writes it beside the session files, so there is nothing to install.

1. **Built (M1.2):** it handles `tool_call` by asking the gate (§4.3) and blocking until the answer. `deny:<reason>` returns the reason to the model. Outside RPC mode it blocks every call, so the bridge can't be misused in an interactive session.
2. **Built (M2.1):** with a computer, it re-registers `read`, `write`, `edit` and `bash` with operations that run in the container (`createReadTool(cwd, { operations })` and friends, which Orphus already exports, so harness change H-B1 isn't needed). It offers only those four tools, set again before every agent start, and blocks any other tool at the gate, since it would run on the host. Paths under the engine's working folder map onto `/home/bot`. A failed `podman exec` fails the tool; there is no fallback to the host.
3. **M2:** diff capture for edits.

Model credentials stay in the engine process on the host. Nothing in the bridge forwards env vars or files from the host into the computer.

---

### 5.3 Bots as a team

- **Built (M8.2):** the bridge's `ask_bot {bot, task}` tool opens an `orphusbot-ask` dialog; the server (`server::team`) makes the task a ticket for that bot (`asked_by`, `ask_depth`) and starts it, or leaves it on the board if the bot is busy, and answers at once so the asker carries on. When that ticket's run ends, the teammate's last reply goes back to the asker as a labelled message and queues the asker's next run. A bot can't ask itself; hand-offs stop three deep (a check constraint backs it). A bot working on a ticket a teammate asked for can't hand it back to that teammate: it's told to answer, or to say plainly that it can't and why, which goes back on its own (D-049). `ask_bot` runs without asking (it only makes a ticket); everything the teammate does is gated as usual. When a run starts, the bot's instructions get its teammates (slug, name, remit) and a pointer to `/shared`, which team-scope bots' computers share.

- **What each can do (M10.2):** the roster appended to every bot's instructions (`team::roster_note`) is rebuilt from the database on each run and says what each teammate can do, not just what it's for: its model, its Google access (looks up only, or also changes with Kelvin's approval), its connections by name (never addresses or tokens), and for the Orchestrator that it starts discussions and runs fleets. It opens with the same line about the bot itself ("You: …"), and says to hand a job it can't do to the teammate who can.

- **The date and time (M10.3):** every `StartTurn` message begins with the current date and time in the owner's time zone (the capture profile's, default Europe/London), e.g. "(It's Tuesday 20 October 2026, 22:15 in Europe/London.)". It's in the message, not the instructions, so the engine isn't restarted each run.

### 5.4 The Orchestrator

- **Built (M9.5, D-037):** a team bot, `orchestrator`, seeded by migration 0027, is the owner's main bot: listed first, opened by default in the app and the bar panel, with a crowned silver face. Its instructions say how to handle a request: answer small things itself; hand a clear specialist job to a teammate with `ask_bot`; split a bigger job across teammates and combine their answers; start a discussion with the `discuss` tool when a decision has real trade-offs (§11.4); run a fleet when a job needs a fixed team of helpers (§11.2); and keep the owner's load low, saying what it has set going. `discuss` is a bridge tool (dialog `orphusbot-discuss`, passed by the gate like `ask_bot`): the server starts the discussion (`discussions::ask`; the bot can't take part itself, and every chosen bot must be free), records `discussion.asked_by`, and when the chair's verdict is in, posts it to the asking bot's thread as data and queues a run there, so it can relay the decision. Inbox stays as the catch-all that System 1 routes from.

## 6. Computers and placement

### 6.1 Trait

As sketched in research/rakazo-architecture.md §8.1: `describe`, `availability`, `provision`, `status`, `pause`, `destroy`, `exec`, file ops, `export_home` / `import_home`, and the optional `screen` / `observe` / `act`. Two implementations in v1: `PodmanProvider` (runs on nodes, driven over the link) and `E2bProvider` (runs in the server).

### 6.2 E2B client (`e2b` crate)

- **Control plane:** `reqwest` to the E2B REST API (create from template, set timeout, pause, resume, kill, list), with the API key from the server's secret store.
- **Inside the sandbox:** `connectrpc` client for `envd` (process start/stream/signal, filesystem read/write/list/watch).
- **Pin the versions.** Generate the Connect-RPC stubs from E2B's published `.proto` files at a pinned E2B SDK tag. Wiremock fixtures in `testkit` reproduce the control plane; one opt-in live test per release, capped at a few cents.
- **Path for an E2B run:** the engine still runs on a node (normally the GPU box). That node's bridge `Op`s go up the link to the server, which runs them against the E2B sandbox. Tokens never reach E2B.
- **Built (M4.5, D-031):** a bot's **Computer** can be "In E2B". `server::e2b` holds `ORPHUSBOT_E2B_API_KEY` and, when a run starts, resumes the bot's sandbox (`POST /v2/sandboxes/{id}/connect`) or creates one (`POST /v2/sandboxes`, template `ORPHUSBOT_E2B_TEMPLATE`, default `base`, `timeout` `ORPHUSBOT_E2B_TIMEOUT_SECS`, default 3600, `autoPause: true`), remembered in `bot_sandbox`. A lost sandbox (404) is replaced. The run's `BotSpec.e2b` carries only that sandbox's envd address (`https://49983-<id>.<domain>`) and access token. The node starts the engine without a container, and the bridge runs read and write through envd's `/files` and every command through `process.Process/Start` (Connect protocol, JSON envelopes, written by hand: no generated stubs), as user `user` with home `/home/user`. Writes and edits there are still "in the computer", so the gate treats them as reversible. If E2B fails, the run fails with the reason. Not yet: refreshing the timeout during a run longer than it (the sandbox would pause mid-run), killing sandboxes, and sending untrusted work to E2B automatically (placement rule 1). Tested against a fake E2B; `live_e2b` (ignored by default) checks the real one.
- **Built (M4.6): screens for E2B computers.** E2B's port proxy carries HTTP and WebSockets only, so the desktop image runs `websockify 6080 localhost:5900` when `ORPHUSBOT_SCREEN_WEBSOCKET=1` (set only by the E2B template; local computers publish nothing and never start it). For a bot in E2B, `/api/screen` resumes the sandbox and the server relays the viewer to `wss://6080-<id>.<domain>/websockify` (with `e2b-traffic-access-token` when E2B gives one) instead of going through a node; takeover works the same way. The image's websockify was checked to answer with the VNC greeting; the relay has a test against a fake sandbox.

### 6.3 Placement

```
fn choose(task, decision, nodes, bot) -> Placement
  1. decision.untrusted ≥ θ                          → E2B (throwaway, destroyed at run end)
  2. task.needs_gpu                                  → GPU box (queue if busy; never E2B)
  3. bot.private_home lives on node N, N online      → N
  4. nodes online with free slots, filtered:
       laptop only if power = ac and not quiet_hours
     → least loaded, preferring bot.preferred_node
  5. bot allows remote                               → E2B overflow
  6. otherwise                                       → queue (run stays queued; card says why)
```

Placement is deterministic code. Laya only supplies the `untrusted` answer and confidence. The chosen placement and the rule that fired are recorded on the run and shown in the UI.

**Built (M2.3):** `server::placement::choose` implements rules 3, 4 and 6: the node holding the bot's computer (`bot_computer` table) if it may work, else the least loaded node that may work (ties by name), else wait with a reason ("laptop is on battery; gpu-box is in its quiet hours"). A node may work unless it's low on battery (unplugged below `ORPHUSBOT_MIN_BATTERY`, default 30%) or in its quiet hours. If the home node can't work, the run goes elsewhere and the home moves with it; the old home's files stay behind until export/import (B-CMP-08). Rules 1, 2 and 5 arrive with System 1 (M3), GPU tasks (M3) and E2B (M4). **Built (M4.5):** a bot whose computer is in E2B may run its engine on any connected node, even one on battery or in quiet hours, since the heavy work happens in the sandbox ("its computer is in E2B; least busy machine"). Placement runs whenever a run is queued, a node connects or leaves, a run ends, and on every heartbeat.

---

## 7. Decision layer (System 1)

### 7.1 Interface

`decide` crate: the `DecisionModel` trait and `Question` / `Answer` types as in research/rakazo-architecture.md §9.2. Composition at server start:

```
Receipts( Fallback( OrtLaya?, HttpLaya(gpu-box), NullModel ), sink = Postgres + JSONL )
```

- **v1** runs `HttpLaya` → laya-serve on the GPU box (`LAYA_PRELOAD=1`, bound to 127.0.0.1 because the server is on the same box). Timeouts: 1.5 s for triage, 1 s for the gate.
- **M5** was to add `OrtLaya` in-process, enabled only when `decide`'s parity test passes against Laya's committed golden fixtures for the exact `laya.onnx` + `tokenizer.json` + `rl_agent_config.json` hash being loaded. **Deferred (D-028):** laya-serve stays the only System 1 runtime.
- `NullModel` always abstains. If everything fails, every decision takes its safe default.
- **In production (M12.4, D-042):** kev's Kev-9B (`jaredpalmer/kev-9b@v1.0`, Apache-2.0, the same `/v1/systemone` protocol) runs on the GPU box as the user unit `orphusbot-kev` on GPU 1, bound to 127.0.0.1:8009, from its own environment in `/mnt/ai_dev/orphusbot/kev`. Each new size of request runs one slow first pass, so the unit's `ExecStartPost` runs `scripts/kev-warm.py` (typical routing, gate and yes/no asks at several lengths; about 90 s) before the server relies on it. Measured on the box afterwards: 40–230 ms per ask, inside both timeouts. Its routing confidences start low (0.62–0.64 on clear coding requests against the 0.85 bar), so it keeps messages in the inbox until labels calibrate it (§7.5); the owner's **Always** rules for `write`, `edit` and `bash` decide before the gate would ask it. Calibration fits only on receipts from the model answering now (`calibrate::pairs` matches the newest receipt's `model`), so Laya's and kev's confidences never mix. Fine-tuning on the owner's labels (`kev.train --init_from`) waits for about 1,000 labels, and stays on the box.
- **Built (M3.2):** `server::system1` calls laya-serve's `POST /v1/systemone` with `reqwest` (`ORPHUSBOT_LAYA_URL`; no URL means it always abstains). Each ask is bounded by `ORPHUSBOT_LAYA_TIMEOUT_MS` (default 1500); a timeout, an error or an unreadable answer abstains. The confidence used is the chosen answer's probability: Laya's `answer_confidence`, or kev's `probabilities[choice]` (kev's own `confidence` is chance-corrected, so it isn't used). The `decide` crate and the `DecisionModel` trait arrive when a second model does (D-028 deferred the in-process one).

### 7.2 Question catalogue

Questions are data, not code: `decide/questions/*.toml`, versioned, with the version hash stored on every receipt. Changing a question's wording invalidates its fitted thresholds, which fall back to strict defaults until re-fitted.

| Catalogue | Questions (type) | Default on abstain |
|---|---|---|
| `triage` | `bot` (choice over the roster), `shape` (choice: single / fleet / goal), `provider` (choice: claude / openai / local), `effort` (score: low / medium / high), `urgency` (score: whenever / today / within the hour / now), `act_now` (noul), `untrusted` (noul) | inbox bot, single, bot default, bot default, today, **ask**, **true** |
| `gate` | `verdict` (choice: pass / ask) | ask |
| `preflight` | `worth_running` (noul) | fire |
| `notify` | `interrupt` (noul) | digest |
| `capture` | `kind` (choice: commitment / task / appointment / follow-up / idea / remember / none), `owner_commitment` (noul), `urgency` (score), `needs_kelvin` (noul) | none (nothing filed) |

The roster choice uses each bot's name plus its one-line remit. If there are more than 16 bots, a first pass picks a shortlist of 8 by remit category.

**Built (M3.2):** `triage.bot` only. A new message to the inbox (when the inbox has no queued or running run) is put to System 1 in the background with the enabled bots' remits as the choices. At or above the route threshold, and if the answer isn't the inbox, the message moves to that bot's thread and the inbox records a persisted `routed` event ("Sent to Researcher (System 1 was 92% sure)"); otherwise the inbox runs it. A follow-up to a busy inbox joins or steers its run as before.

### 7.3 State building

The state is JSON, built per catalogue:

- **`triage`:** `{source, text, ticket?, recent_context (last 6 events, truncated), time_of_day, node_status_summary}`.
- **`gate`:** `{task_summary, bot_remit, tool, args_redacted, matching_rules}`, with secrets redacted.
- **`capture`:** `{window_text with speaker tags, owner_marked, time, place_hint?}`.

States are hashed (SHA-256 over canonical JSON) for receipts. The full state is kept for 30 days for labelling, then only the hash is kept.

### 7.4 Gate algorithm (per consequential tool call)

```
class = static_class(tool)            // exempt | always_ask | reversible | irreversible | unknown
rule  = most_specific(user_rules, tool)  // allow | ask | deny, ties → ask
if class == exempt                                     → allow
if rule == deny                                        → deny
if rule == allow and class != always_ask               → allow
if class in {always_ask, irreversible}                 → ask        // System 1 never approves these
ans = decide(gate)                                     // receipted
if ans.abstained or ans.verdict == ask                 → ask
if class == reversible and ans.verdict == pass         → allow
→ ask
```

**Built (M3.2):** the gate asks System 1 only when no rule decided and the call is reversible by construction: `write` or `edit` running inside the bot's computer (the bridge sends `inComputer`). Bash is not reversible (a command can reach the network), nor is anything on the host. A pass at or above the gate threshold approves the call and the ledger records `decided_by = system1`; anything else asks the owner. The state is `{task, bot_remit, tool, args}`.

- **`reversible`** is a short whitelist: read-only MCP tools, file ops inside the bot's computer, creating drafts (mail, PR, calendar *tentative*), and notes in the bot's own workspace.
- **`irreversible`** covers send, pay, delete outside the computer, merge, publish, and anything on a connector whose name matches mutating verbs, unless whitelisted.

### 7.5 Thresholds and calibration

- `decision_model` rows hold `{checkpoint, question_catalogue_version, thresholds per (question, bucket), fitted_at, applied_at}`. Exactly one row is `active`.
- **Built (M3.2):** `ORPHUSBOT_ROUTE_THRESHOLD` (default 0.85) and `ORPHUSBOT_GATE_THRESHOLD` (default 0.95, never below 0.9) until fitted thresholds exist.
- **Defaults until fitted:**
  - `act_now` ≥ 0.95 on calibrated `answer_confidence`;
  - `gate.verdict = pass` ≥ 0.95;
  - every other question ≥ 0.85.
- **Built (M3.6):** `decision_label` rows record the answer an owner action implies and whether System 1 agreed: answering an approval card labels the gate decision for that tool call (allow → `pass`, deny → `ask`); changing a triaged ticket's bot labels its triage decision with that bot. `GET /api/decisions/health` gives, per catalogue, how many asks, abstentions, labels and agreements, and the average latency.
- **Labels** come from Kelvin's actions:
  - approving or denying a card;
  - reassigning a task;
  - changing urgency;
  - keeping the bot System 1 picked (starting or finishing the ticket with it).
- **Built (M5.1):** changing a triaged ticket's urgency labels it with the new level (agreeing when that was Laya's most likely level); starting a triaged ticket with **Start**, or moving it to done, with the bot System 1 picked labels that pick as right, once per decision. Without this, the only bot labels were corrections, so every fit would have seen System 1 as always wrong.
- **Built (M12.5): labels by hand.** Inbox routing had no implicit labels (a message kept in the inbox says nothing about which bot was right), so the owner marks decisions directly: the app's Settings → **Decisions** lists routing and gate receipts (what it was about, what System 1 chose and how sure, the outcome, any earlier label) with **Right** / **Wrong** (pick the bot) for routing and **Fine to go ahead** / **Should ask me** for tool calls, plus **Fit** and **Apply**. `POST /api/decisions/label {id, bot | verdict}` checks the bot exists and the label fits the catalogue, and records it with source "marked in the app"; the newest label per decision is the one that counts. `GET /api/decisions` now includes each receipt's `answers`.
- **Not labels, on purpose:** accepting or dismissing a capture proposal, and a run's result. System 1 only decides whether to *skip* a capture window or a routine, and a skipped one never produces a proposal or a result, so those actions can't say whether a skip was right; they judge System 2's work instead.
- **Calibration** (`decisions.calibrate`, manual) exports labels to JSONL, then runs Laya's `laya.calibrate` (Python, on the GPU box) through a small CLI wrapper. It reads back proposed temperatures and thresholds and shows before/after metrics on a held-out time slice. **Apply** makes it active; **rollback** re-activates the previous row.
- **Built (M5.2, D-027):** `server::calibrate` fits thresholds in the server rather than through `laya.calibrate`, because refitting Laya's temperatures needs its raw logits and receipts only keep the calibrated `answer_confidence`. **Fit** (`POST /api/decisions/fit`) takes each fittable question's labelled answers, oldest first: `triage.bot` (every labelled bot pick) and `gate.verdict` (only "pass" answers, the ones that act). With at least 30, it fits on the oldest four fifths with Laya's own conservative selective cut (the lowest confidence whose accepted answers keep `(errors + 1) / (accepted + 1)` within the target: 10% for bots, 5% for tool calls), floors it (0.5 for bots, 0.9 for tool calls) and scores the current and fitted thresholds on the newest fifth. It saves a `decision_model` row `{thresholds, report}`, not yet active. **Apply** makes one row active (a unique partial index allows one) and hands it to System 1 in memory; **rollback** deactivates it and re-activates the one applied before it, or falls back to the defaults. The database refuses a gate threshold under 0.9. Questions not fitted keep their defaults; urgency, act now, pre-flight and capture skips are not fitted yet.
- **Fine-tuning** (M5+) is the same flow with `laya-train` and an ONNX export. The resulting checkpoint is trained on Kelvin's private conversations, so it is **never published** (§17).

### 7.6 Receipts

- Postgres `decision`: id, catalogue, question version, state hash, answers JSON (probabilities, `answer_confidence`, `jev_confidence`, abstained), thresholds, model id, latency, run / task / effect / capture links.
- **Built (M3.2):** `decision` holds catalogue (`triage`, `gate`), SHA-256 state hash, the state (cleared after 30 days), answers, abstained, threshold, confidence, model, latency, outcome in words, run and tool call. `GET /api/decisions` lists the latest 100, shown in the Decisions view (M3.6). The JSONL mirror comes with the Decisions view (M3.6).
- Mirrored as JSONL in Orphus systemone's receipt shape to `~/.local/share/orphusbot/receipts/`, so orphus-desktop can read them.

---

## 8. Models and subscriptions

- **Login relay.** Logins run on each node through the engine's `login_provider`.
  - The OAuth prompt arrives as `extension_ui_request`. The server shows it as a card on every client, and the answer (a pasted code or a selection) goes back the same way.
  - Device-code flows (ChatGPT) show the code and link; Kelvin completes them on any device.
  - Claude uses claude-bridge with the Claude Code login on that node. If the node's Claude Code isn't logged in, the card says so and links to the terminal command.
- **What the server knows:** login status only, from heartbeats. No token ever crosses the link (enforced by a `proto` type with no token field, and a test).
- **Quota tracker.** The node maps rate-limit and usage-limit errors (H-B4) to `QuotaEvent{provider, kind, resets_at?}`. The server keeps a per-provider `limited_until`. Triage's provider answer is overridden while a provider is limited, and the override is receipted.
- **Subscription policy (PRD Q3) stays open.** Until Kelvin decides, routines use API-key providers if configured and otherwise run on subscriptions with a daily cap (`routine_subscription_turns_per_day`, default 20).

---

## 9. Wearable integration

The wearable already has a complete, documented device channel (`server-contract/`), a button grammar and a cue vocabulary. OrphusBot **implements that same contract in Rust** so the existing firmware and Flutter app work against it unchanged apart from the server URL.

### 9.1 Where things run

| Piece | Runs on | Change |
|---|---|---|
| Firmware (button, Opus, cues, MicroSD) | Wearable | None |
| BLE bridge, foreground service, on-device STT, speaker identity | Flutter companion on the Android phone | Pairing points at `https://<gpu-box NetBird name>`. mDNS still works on the LAN. |
| Device channel (`/api/device/*`) | `orphusbot-server` `device` module | Rust port of `server-contract` |
| Server-side accurate STT | `qwen3-asr` service on the GPU box | Reuse as-is (Python); the server calls `/transcribe` |
| Agent work triggered by the wearable | OrphusBot runs | New: intake source `wearable` |

The phone therefore has two apps in v1: the **wearable companion** (Flutter; BLE, audio, STT) and **OrphusBot** (Tauri; bots, tickets, approvals). Merging them is deferred (§19 D1). The companion is the right home for BLE and on-device STT today: it already has a working foreground service, sherpa-onnx and Opus decoding, and none of that has a mature Tauri-on-Android equivalent.

### 9.2 Device channel in Rust (`device` crate + `server::device`)

Endpoints and auth are as in the wearable's `docs/SERVER.md`:

- `X-Device-Id` + `X-Device-Token` on HTTP;
- the token in `Sec-WebSocket-Protocol` on the audio WebSocket;
- `?token=` rejected.

| Endpoint | OrphusBot behaviour |
|---|---|
| `POST /api/device/register` | Requires a signed-in OrphusBot session (passkey) instead of a pasted dashboard bearer. Returns device id and pairing token (stored hashed). |
| `WS /api/device/ws/audio` | Opus or PCM16 in. Frames pass the **capture gate** (§9.4) before decoding. Admitted audio is buffered per utterance and sent to qwen3-asr on close. Transcripts are echoed on the WS. |
| `POST /api/device/event` | Button codes (§9.3) |
| `POST /api/device/text` | Transcript from on-device STT (with speaker labels and `isOwner`), the default path. The `overheard` flag routes it to capture (§10) rather than intake. |
| `GET /api/device/command/poll` | Drains queued cue commands (4-byte packets) |
| Voice profile and hands-free endpoints | Same semantics; `hands_free` is stored per device |

Wire constants (`OP`, `PATTERN`, `HABITAT_CUE` ids, button codes 1–11) live in `device::wire`, generated from one table. A CI contract test checks them against `wearable/firmware/.../agent_commands.h` and `wearable/app/.../command_codec.dart` (§9.6).

**Built (M3.5):** `crates/device` holds the ops, patterns, the 12 habitat cue ids and the alert table (as the JSON command objects the app's poll decodes); its test reads the firmware header and the app codec and fails on any drift. `server::device` implements register (a one-time pairing code from Settings → Wearable, sent as the app's bearer, D-025), event, text (8 KB limit, ~10 then 1 per 6 s per device; a transcript is deliberate only within 90 s of a button press, and overheard text is not kept until capture lands in M4), command poll (`POST`) and hands-free. The audio WebSocket and voice profiles arrive with capture (M4).

### 9.3 Duplex habitat (the wearable conversation)

The wearable has **no speaker, by design**, and no screen. Its only outputs are the NeoPixel and the vibration motor; its inputs are the button and the mic. "Duplex habitat" means that channel works **both ways as a closed loop**:

- every signal OrphusBot sends to the wrist has a defined meaning;
- every signal that wants an answer has a defined button reply;
- the server always knows whether a signal was **delivered**, **acknowledged**, **answered** or **timed out**, and what happens next in each case.

Nothing in OrphusBot may ever depend on audio output. Anything that needs words goes to the phone or desktop; the wrist only carries *that* something happened, *what kind* and *how urgent*.

#### 9.3.1 Habitat messages

Every outbound signal is a `habitat_message` row, not a bare packet:

| Field | Meaning |
|---|---|
| `kind` | `inform` (no reply expected), `ask` (needs the wearer), `ambient` (capture state; no reply) |
| `cue` | One cue from the existing vocabulary (`task_queued`, `task_running`, `awaiting_input`, `task_done`, `error`, `budget_warn`, notification tiers, capture cues) |
| `subject` | What it's about: run, effect, proposal, reminder |
| `reply_grammar` | For `ask`: what tap and double tap mean for this subject (§9.3.3) |
| `state` | queued → delivered → acknowledged / answered / dismissed / expired / superseded |
| `escalate_after` | When an unanswered `ask` escalates to the phone (§9.3.4) |

The server picks the cue; the app resolves gestures against its own state (the button spec's `IDLE` / `CAPTURING` / `ALERT_PENDING` resolver stays the authority) and reports the outcome **with the message id**, so the server never has to guess which signal a tap answered.

#### 9.3.2 Outbound: one thing at a time

- **One `ask` on the wrist at a time.** Further asks queue on the server, ordered by urgency. When the current one is answered, dismissed or escalated, the next is delivered. This is what makes a blind tap safe: there is only ever one thing it can mean.
- **Capture always wins** (button spec rule): asks arriving while the wearer is capturing are held and replayed after filing.
- **`inform` signals** (queued, done, error, reminders) play once and don't block. They are rate-limited to one per 5 s per device and coalesced: three tasks finishing within a minute give one `task_done`, not three.
- **Persistent states** (`task_running` breathing, `awaiting_input` amber pulse) are superseded by the next state for the same subject, never stacked.
- **Quiet hours and Focus profile** decide which informs are sent at all (§10.5). Asks above the profile's interrupt threshold are always sent.

#### 9.3.3 Inbound: what a gesture answers

The button grammar is unchanged: *tap = yes, tap twice = no, hold is power*. For each `ask` subject, OrphusBot defines what yes and no mean, and **only reversible outcomes can be triggered without words**, because the wearer can't see or hear the details on the wrist:

| Ask subject | Tap (yes) | Double tap (no) | Reply carries |
|---|---|---|---|
| Bot asked a question (`waiting_input`) | Acknowledge and open the mic; the wearer answers aloud; the transcript is the answer | Dismiss; the run keeps waiting and the question goes to the phone | Transcript or nothing |
| "Should I start?" card for the wearer's own button task | Start it | Don't start; the task stays as a ticket | — |
| Approval of a **reversible** effect the wearer started from the button in the last 10 min | Approve | Deny | — |
| Approval of anything else (other sources, or **irreversible**) | **Acknowledge only**: "I've seen it, I'll look on the phone"; stops the amber pulse and sends the card to the phone immediately | Dismiss from the wrist; the card stays on the phone | — |
| Urgent capture proposal | Acknowledge; proposal pinned at the top of the phone inbox | Dismiss to the next digest | — |
| Time-blindness reminder | Acknowledge ("on it") | Snooze 10 min (once) | — |

So the wrist can confirm things the wearer *already knows about* (their own task, a reminder they accepted), and can always say "seen". It never approves something whose content it couldn't show. This replaces the earlier idea of tap-approving any reversible effect.

Answering aloud has a guard: the transcript is attached to the **message id** that opened the mic. If that ask was superseded before the answer arrived, the answer is posted to the thread as a normal message instead of being used as the answer.

#### 9.3.4 Closing the loop

| Event | Server action |
|---|---|
| Command drained by the app and written to GATT `0xCAB1AB97` without error | `delivered` (the app reports the write result on its next poll) |
| Not delivered within 30 s (phone away, BLE down) | Mark `undeliverable`; send the same content to the phone via ntfy; keep the ask queued for the wrist when it reconnects only if still relevant |
| Tap / double tap resolved by the app against this message | `acknowledged` / `answered` / `dismissed`, with outcome; a label for System 1 where relevant (e.g. "should I start?" → act-now label) |
| `ask` unanswered after `escalate_after` (default: urgency *now* 2 min, *within the hour* 10 min, otherwise next digest) | `expired`; the ask moves to a phone notification and the inbox; the wrist pulse stops so it never nags indefinitely |
| A newer state for the same subject | `superseded` |

Every transition is an event on the wearable thread, so the Wearable view in the UI shows the full conversation: what was signalled, when it was felt, and how it was answered.

**Built (M3.5):** `habitat_message` rows hold kind (inform, ask), cue, subject (`run:`, `dialog:`, `ticket:`), the tap's meaning, state and outcome. Informs supersede earlier informs about the same subject. Asks queue and go to the wrist one at a time; a tap or double tap (`SINGLE` / `DOUBLE`) answers the one on the wrist, with an `ack` cue first so the amber pulse stops before whatever it starts. Tap grammar as in §9.3.3: start a button ticket; approve or deny only a `write`/`edit` on a run started from that wrist in the last 10 minutes; open the mic for a question (the next deliberate transcript within 2 minutes answers it, if it's still open); otherwise "seen". A dialog settled elsewhere supersedes its ask. Unanswered asks expire after 10 minutes. *Delivered* means the app took the command; GATT write results (W-3), urgency-based escalation, capability records (W-2) and phone push (ntfy) come next. Settings → Wearable lists devices and the latest signals.

#### 9.3.5 Button → agent (the uplink task path)

1. **Tap in IDLE** → capture opens (white, steady, non-suppressible) → the wearer speaks → **tap** → the app files it. The transcript arrives at `/api/device/text` with `overheard = false` and a capture id.
2. The server runs `intake(source = wearable, …)`. There is no gesture for "which bot": intent comes from the words.
3. Triage decides. If it says act now (and the work is reversible, §19 D6), the run starts and the wrist gets `task_queued`. If not, the wrist gets a "should I start?" ask (§9.3.3).
4. While running: `task_running` (breathing blue). The run then ends with `task_done` (green, double buzz) or `error` (red, triple buzz), or moves to `awaiting_input` (amber pulse, long buzz) as an ask.

#### 9.3.6 Vibration and eyes-down use

The motor is the only channel that works in a pocket or with eyes elsewhere, so:

- Every **ask** and every **error** must be identifiable by haptic alone (long buzz = needs you; triple = error). Informs may be LED-only.
- The server keeps a per-device **capability** record: `{led, haptic, haptic_patterns}`. The phone app fills it from the firmware's status reply (`STATUS_QUERY` → `0x23BA7924`), extended with a capability byte (firmware change W-2 below). While a device reports no working haptic, asks escalate to the phone after **30 s** instead of the normal delay, because the wearer may not see the LED.
- The firmware already plays named haptic patterns through `haptic_play()` (single / double / triple / long). The "every haptic is one buzz" blocker in `HABITAT_ALERTS.md` looks fixed in `agent_commands.c` and the doc needs updating. The bench test of `ramp` vs `ramp↓` distinguishability still stands.

#### 9.3.7 Firmware and app changes this needs

Small, and all within the existing protocol style:

| ID | Where | Change |
|---|---|---|
| W-1 | firmware + app + `device::wire` | Mint `HABITAT` cue ids for `task_queued` and `task_done` (the doc already calls for this) and move the six task signals onto op `0x06`, so every cue is one write |
| W-2 | firmware | Add a capability byte to the status reply: LED present, haptic present, haptic driver ok |
| W-3 | app | Carry the server's `message_id` with each queued command; report delivery (GATT write ok / failed) and gesture outcomes against that id |
| W-4 | app | Hold only one `ask` as `ALERT_PENDING`; ignore new asks until the server sends the next one (the server already serialises, this is the app-side guard) |
| W-5 | docs | Remove the stale `speaker.c` reference from `HABITAT_ALERTS.md` and state "no speaker, by design" as a product rule |

None of these change the button grammar or the meaning of any existing cue.

### 9.4 Capture gate

A port of `capture-gate.ts`, kept pure and unit-tested. A frame is admitted only if:

- a button capture window is open (`WEARABLE_CAPTURE_WINDOW_MS`, default 60 s, extended by presses); **or**
- hands-free is on for the device **and** allowed server-wide (`hands_free_allowed`, an operator kill switch).

In hands-free mode, utterances that aren't from the owner are kept only as **context for capture mining** (§10.3). They are never dispatched as tasks, and the WS echoes them as "(overheard)" so the wearer can see exactly what was heard. Every window open/close and every dropped batch is audited.

### 9.5 STT paths

| Mode | Where | When |
|---|---|---|
| **On-device (default for OrphusBot)** | Phone: streaming zipformer preview, offline zipformer final, VAD, punctuation, diarization, speaker identity | Default. Only text and speaker labels reach the server. Raw audio never leaves the phone. |
| **Server** | GPU box: Opus decode in Rust (`audiopus`), utterance buffer, qwen3-asr batch final (6.24 % WER vs 11.2 % on the phone) | Opt-in per device, for accuracy. Owner identification needs diarization on the server: v1 uses the phone's live owner flag when present, otherwise treats the speaker as unknown (context only). Server-side diarization (WeSpeaker on the GPU box) is deferred. |

The existing defaults are flipped: the wearable app currently defaults to `cloud`, but OrphusBot pairing sets `onDevice` unless Kelvin chooses server mode. That matches "the phone is the filtering boundary".

### 9.6 Contract tests

`testkit` includes:

- a **simulated wearable** (button codes, Opus frames from fixtures, command polling);
- a **golden table test** that parses the C header and Dart codec and compares them to `device::wire`.

These run in CI on every change to `crates/device` or `wearable/`.

### 9.7 Laptop

Kelvin's `omarchy-assistant` daemon (hotkeys SUPER+ALT+O ask and SUPER+ALT+N note) can post to `/api/device/text` as a second device, so the laptop becomes another capture source with no new protocol. Optional; the daemon stays its own project.

---

## 10. Capture and mining (ambient listening → things to do)

Purpose: catch what you said you'd do, what someone asked of you, appointments, follow-ups and things worth remembering, without you having to stop and write them down. This is designed first for neurodivergent people (ADHD: time blindness, dropped commitments, working-memory load) and works for anyone.

### 10.1 Rules carried over from the earlier assistant work

1. **Ambient text produces artifacts, never replies.** Nothing heard in hands-free mode makes a bot speak, act or contact anyone.
2. **The miner has no tools.** It reads text and outputs structured proposals. It cannot send, browse or run anything.
3. **Proposals need a click.** Nothing mined becomes a task, an event or a message until the wearer accepts it. The exception is low-risk *notes*, which can be auto-filed if the profile allows it (§10.5).
4. **Nudges are gentle.** Digest by default; interrupt only on high, confident urgency.

### 10.2 Pipeline

```
transcript segments (device text, owner-tagged)
   → window: rolling 2-min windows, closed by 20 s silence or 10 min cap   (capture_window)
   → System 1: capture catalogue (§7.2) over the window                    (one batched Laya call)
        kind = none, or abstain  → nothing filed; window kept for retention period only
        otherwise                → extraction
   → Extraction (System 2, tool-less): one LLM call with a strict JSON schema:
        {kind, title, detail, who, due?, place?, quote, confidence_note}
        model: the cheapest configured provider (local model on the GPU box when available)
   → Proposal row (state = proposed), linked to window + decision receipt
   → Delivery per profile: digest | phone card | wearable ask (§9.3) for urgent
   → Kelvin: accept → ticket / calendar draft / note | edit | dismiss  (each is a label)
```

- **Explicit captures** (button) go to intake as tasks (§9.3), not to the miner.
- **Hands-free / overheard** text goes to the miner only.
- **Commitments other people make to you** are proposed as `follow-up` ("Sam said they'd send the quote by Friday"), so you can check later.

### 10.3 Other people's speech

- Non-owner utterances are used only as **context inside a window**. They are needed to understand "yes, I'll do that", but are never filed as their own items unless they concern the owner (`needs_kelvin` or a follow-up owed to the owner).
- Proposals store a short **quote** (≤ 200 characters) as evidence. Raw window text is deleted after the retention period (default **7 days**). Accepted items keep only their structured fields and the quote.
- **Raw audio is never stored** by the server. In server-STT mode, audio is held in memory per utterance and dropped after transcription.
- The white capture LED stays non-suppressible (firmware rule). The OrphusBot UI shows hands-free state on every screen while it's on.
- **Pause:** a double tap in IDLE is currently a no-op. We **don't** overload it. Pausing hands-free is a phone toggle and a server endpoint, plus an optional schedule (e.g. off at the doctor's, off at home after 21:00).
- **Open-source users in other places:** recording laws differ (e.g. all-party consent rules in some places). Hands-free ships **off by default**; the server has the `hands_free_allowed` kill switch; the docs explain the consent LED and point people to check local law. (This is a design note, not legal advice.)

### 10.4 What proposals become

| Kind | On accept |
|---|---|
| commitment / task | Ticket (assigned via triage, or to the inbox bot), due date if any |
| appointment | Tentative calendar event via the PA MCP server (a draft, so reversible) |
| follow-up | Ticket in `waiting` with a reminder routine |
| idea / remember | Note in the Obsidian vault (`<vault>/OrphusBot/Captures/YYYY-MM-DD.md`, Tasks plugin format; vault path is a setting), written by the laptop node |

### 10.5 Profiles (neurodivergent-first, configurable for anyone)

Profiles are presets over the same settings:

| Setting | **Focus support** (default for Kelvin) | **Standard** |
|---|---|---|
| Kinds mined | all | commitment, appointment |
| Digest times | 3 a day (e.g. 10:00, 14:00, 18:00) + end-of-day review | 1 a day |
| Interrupt threshold | urgency ≥ "within the hour" and confident | urgency = "now" |
| Time-blindness nudges | "starts in 30 min / 10 min / now" as wearable informs (blue flash, double buzz; the phone notification carries the words) for accepted appointments; the "now" one is an ask (tap = on it, double tap = snooze 10 min); gentle "you said you'd… today" check-ins in the digest | off |
| Auto-file notes | idea / remember auto-filed, undo for 24 h | off |
| Re-surface | dismissed-but-not-done commitments come back once after 3 days | off |
| Wording | short, concrete, one action per card; never guilt language ("overdue" → "still open") | plain |

Cards and cues follow the wearable's existing tiers. Nothing escalates to red for a missed personal task; red is reserved for system errors.

**Built (M4.7):** `server::profiles` with one owner-wide `capture_settings` row (profile and time zone, chosen under Captures). Extraction is told the owner's local time and may give `due_at`; results are filtered to the profile's kinds. Focus support files ideas and things to remember as tickets straight away (`auto_filed`, **Undo** for 24 h removes the ticket if nothing has started on it) and still pushes per window; Standard waits for its digest. A minute loop sends digests at the profile's local times (push plus a notice in the inbox: "N to look at", "Still open", never "overdue"), brings a dismissed commitment back once after three days (`resurfaced`, shown as "Came back: still open"), and nudges accepted appointments that have a `due_at` 30 and 10 minutes before and at the start, once each (`nudge` table), by push and the wrist's new `nudge` alert (blue flash, double buzz, built from shipped LED and haptic commands, so no firmware change). Not yet: the "now" nudge as an ask with snooze (it's an inform), auto-filed notes going to Obsidian, and custom digest times.

### 10.6 Built (M4.3)

- **Intake:** overheard text on `/api/device/text` (or text without a recent button press) is captured only while the device's hands-free is on **and** `ORPHUSBOT_HANDS_FREE_ALLOWED` isn't `false` (the kill switch); otherwise it's dropped unread. Lines are `speaker: words`, using the app's `talker` label.
- **Windows** (`capture_window`) close after 20 s of quiet or 10 minutes. System 1 (`capture` catalogue, `worth_keeping`, receipted) skips windows it's sure hold nothing; abstaining extracts.
- **Extraction:** the server sends `ToNode::Extract` to the least busy ready node, which runs **one** `orphus --print --no-session --no-tools --no-extensions --no-skills --no-context-files --system-prompt <brief>` call (optional `ORPHUSBOT_EXTRACT_MODEL`) and returns the text. The brief tells it to file only the owner's commitments, things asked of the owner and follow-ups owed to them, as a JSON array; anything malformed is dropped, at most 10 per window, quotes capped at 200 characters.
- **Proposals** (`proposal`) wait under **Captures**; a push says how many. **Accept** makes an unassigned ticket (follow-ups, appointments and notes are titled as such); **Dismiss** closes it. Nothing starts a run.
- **Retention:** window text is cleared after `ORPHUSBOT_CAPTURE_RETENTION_DAYS` (default 7). No audio reaches the server on this path.
- **Visibility:** while any device listens, every screen shows a banner with **Pause**; Captures toggles hands-free per device.
- **Not yet:** the audio WebSocket and server STT, voice profiles, calendar drafts and Obsidian notes on accept, and labels from accept/dismiss.

---

## 11. Integrations and secrets

- **Integrations are MCP.** `connections` stores MCP server records (URL or allowlisted stdio command), OAuth material (envelope-encrypted) and per-bot grants. For each engine session, the server issues an MCP config file containing only the granted servers, with short-lived tokens where the server supports them.
- **First integration:** Kelvin's PA MCP server (mail drafts, calendar, todos).
- **Lazy catalogue:** planned as `search_tools` / `load_tool` / `call_tool` wrappers on the server's own rmcp endpoint; Orphus's MCP adapter does this already (D-029). The `mcp_` prefix is avoided.
- **Built (M6.1, D-029):** Settings → **Connections** adds an MCP server by name, http(s) URL and an optional bearer token, and grants it to bots. When a run starts, the server puts the bot's granted servers, with decrypted tokens, in its `BotSpec` (`McpServer`; the `Debug` output hides the token). The node writes them to `<session dir>/<bot>/mcp.json` (with `"lifecycle": "lazy"` and `bearerTokenEnv`, so the token itself is only in the engine's environment) and starts Orphus with `--mcp-config`. Orphus's built-in MCP adapter is the lazy catalogue: the bot gets one `mcp` tool that searches, describes and calls, whatever the number of servers or tools, so no wrapper is needed here. The bridge allows `mcp` beside the computer tools when the bot has a connection. At the gate, a bare `mcp` call (search, describe, connect) reads and runs; a call that names a tool becomes `mcp:<tool>`, so the ledger, the owner's rules, "Always allow" and the card are per MCP tool, and it asks.
- **Built (M6.5): signing in (OAuth).** An address connection has **Sign in**. `server::oauth` finds the provider (RFC 9728 resource metadata, path-aware then root, else the server's own origin; then RFC 8414 or OpenID metadata, else `/authorize`, `/token`, `/register`), registers OrphusBot as a public client (dynamic registration, redirect `<origin>/oauth/callback`), and sends the owner to sign in with PKCE S256 and `resource`. The callback is public, because a browser returning from another site doesn't send the `SameSite=Strict` cookie; a single-use, ten-minute `state` in `oauth_flow` proves the sign-in began here. Access and refresh tokens are stored as secrets (so they are redacted like any other), with `token_expires_at`; before a run the server refreshes one that expires within a minute. Nodes only ever get the access token. Providers that don't allow dynamic registration aren't supported yet.
- **Built (M6.4): command (stdio) servers.** A connection can be a command line instead of an address (split on spaces, a plain program name, at most 20 arguments), with the environment variable its token goes in (`token_env`). It runs on the node, outside the bot's computer, so the **node** decides: it writes the server into `mcp.json` only when the program is on its own `ORPHUSBOT_MCP_COMMANDS` allow-list (empty by default), and otherwise leaves it out with a warning, so a server can't make a node run anything its owner didn't list. The token goes in the engine's environment and the file names it as `${ORPHUSBOT_MCP_TOKEN_n}`, which the adapter expands, so it never reaches disk. Calls are gated per tool as for URL servers.
- **Built (M6.1):** secrets are AES-256-GCM under one master key from `ORPHUSBOT_SECRET_KEY_FILE` (32 bytes, ideally a `systemd-creds` credential), a fresh nonce each. Every stored value is known at start, and its plain, base64 and URL-encoded forms (8 characters or more) become `[secret]` in every event before it is stored or sent to a browser, including the owner's own messages. The engine's own session file on the node still holds raw tool output; it never leaves that machine.
- **Later:** envelope encryption (a data key per value, wrapped by the master key), so the master key can rotate without re-adding tokens.

### 11.1 Artifacts

- **Built (M6.2):** a bot gives the owner a file with the bridge's `share_file` tool (up to 10 MB, read inside its computer). The bytes travel in the tool result's `details`, which Orphus never shows the model; the node relays them as `FromNode::Artifact`, and the server keeps them in `artifact` (per bot and name, a new version each time) and records `ThreadEvent::Artifact {id, name, version, size}`, shown as a download link. `GET /api/artifacts/<id>` always answers `application/octet-stream` as an attachment with `nosniff`, so a shared HTML file can't run in OrphusBot's origin. `share_file` runs without asking: it only gives the owner a copy. File contents aren't scanned for secrets.

### 11.2 Fleets and workflows as run targets

- **Fleets: built (M6.3, D-032).** Orphus runs helpers (subagents, fleet members) as other sessions in the engine's process, and they don't load the engine's `--extension`. So the node also writes the bridge into the engine's work folder as a project extension (`work/.orphus/extensions/`), which helper sessions load (the engine ignores it, and a guard stops a double load), and sets `ORPHUSBOT_HELPERS_GATED=1`. The engine's bridge shares its RPC dialogs on a process-wide symbol; a helper's bridge asks through them. So every helper call reaches the gate exactly like the bot's own, and in a computer runs there. The bridge then allows `subagent`, `fleet` (blueprints, read only) and `roundtable` (the helpers' rooms); the gate treats `fleet` and `roundtable` as reads and asks about each `subagent`. Checked with the real engine: a helper's `bash` produced an approval card, ran inside the Podman computer when allowed, and never ran when denied. A run target is just the message: a chat message or a routine's instruction that starts with `/fleet <name> <task>` runs that fleet (Orphus's own command, which works over RPC). **Fleets the owner sets up (M7.6):** the server keeps Orphus fleet blueprints in `fleet` (name, YAML; `GET/POST /api/fleets`, `/api/fleets/delete`; it checks the name, the size and that the file's `name:` line matches, and leaves the rest to Orphus's `/fleet validate`). Every `StartTurn` carries them, and the node writes them into the bot's work folder as `.orphus/fleets/<name>.fleet.yaml` (project scope, which shadows the user's and Orphus's bundled examples), removing ones the owner deleted; names are checked again there, since they become file names. The app's Settings → Fleets lists them, edits the YAML (a council template, and the models the machines can use) and runs one as any bot. Known Orphus limit (2026-10-16): helper sessions ignore a seat's `model:` pin and resolve their model before extension providers such as claude-bridge are registered, so seats fail as "No API key"; a fix is in review in Orphus. A resumed attempt gets the "interrupted" note first, so it continues rather than relaunching the fleet. Helpers run in the foreground (M9.3): the server answers a run's dialogs only while the run is going, so a helper sent to the background would wait for ever once its parent's turn ended (seen with a real `/fleet council`). The gate refuses a `subagent` call without `"async": false`, telling the model why, and every bot's instructions say to wait for helpers before finishing. Each `/fleet` run also gets a fresh session (`<slug>-fleet-<run>`, `fleets::session`), like a discussion turn: the orchestration stays out of the bot's everyday conversation, and an old fleet run remembered there can't stop a new one (seen on the box).
- **Workflows: still blocked.** A workflow's own TypeScript (`ctx.tool`, worktree set-up, and definitions a model writes inline) runs on the host in the engine process, with no tool call to gate, so `workflow` is refused by the bridge and the gate in every mode.

---

### 11.3 Models

- **Built (M8.1):** when a node connects it runs `orphus --list-models` and sends `FromNode::Models` (`provider/model` names). `GET /api/models` lists every model with the nodes that have it, and the bot editor offers them as suggestions for **Model** (still free text). Whatever Orphus on a node can reach is available: subscription logins (`openai-codex/…`, Claude through the `claude-bridge` extension, which drives the official Claude Code with its own login and switches off Claude's own tools, so every call still reaches the gate), and local models declared in the node's Orphus `models.json` (vLLM or Ollama, `local/…`). Placement doesn't yet route a bot to a node that has its model.

### 11.4 Rooms and memory

Orphus's answer to multi-agent work is a context-window contract: a discussion lives in a local broker (a **room**), outside every agent's context window, and reaches an agent only as a one-line activity ping or a digest it pulls, bounded to a fixed character budget (newest messages verbatim, older ones as headlines, the rest as a count). A verbose peer can't flood anyone's context, so each agent's task stays clean. Long-term memory is **Dossier** (HMLR-Wiki): finished rooms are exported losslessly and filed by one writer, the `librarian` role, into a markdown wiki; any agent reads it only by asking (`memory` `query`), never pushed into a digest.

- **Built (M9.1):** bots can use both tools. `roundtable` was already allowed with fleets (§11.2); the bridge now also allows `memory` when the node's environment sets `ORPHUS_MEMORY_COMMAND` (the engine inherits it, with `ORPHUS_MEMORY_DIR`). The gate lets `memory` `query` and `doctor` through as reads; `ingest` and `gardener` ask the owner, and Orphus itself refuses writes from any role but the librarian. Rooms are per machine (one broker per Orphus agent folder), so bots on the same node can share one.
- **The team wiki (M9.6, D-038):** the bots' shared memory is a Karpathy-style LLM wiki maintained with the [karpathy-llm-wiki](https://github.com/Astro-Han/karpathy-llm-wiki) skill (MIT), installed on the node in Orphus's user skills folder, with its root at the team folder `/shared` (`raw/` sources, never edited; `wiki/` articles with `index.md` and `log.md`). Every bot's instructions say to query it before researching and to ingest what lasts. It needs no model server of its own: each bot does the work with its own model and its computer's file tools. Skills live on the host, not in a bot's computer, so the bridge reads files under Orphus's skill folders (the user's and the ones Orphus ships) from the host, read only and by real path, so a link can't point elsewhere; every other read stays in the computer. Dossier (above) is retired on the box: `ORPHUS_MEMORY_COMMAND` is unset and its model service is off; the `memory` tool support stays for a node that sets it up. A bot that writes a skill can't put it there itself: it calls `install_skill {name, skill, replace?}`, the gate always asks the owner (no "always" rule applies), the app's card shows the whole SKILL.md and only Allow, and on Allow the bridge writes it into the node's user skills folder after checking the name (lower case, digits, hyphens), the size (64 KB) and the frontmatter (`name:` matching, a `description:`), refusing to replace an installed skill unless asked to (D-051).
- **Built (M9.2, Discuss, D-036):** the owner picks 2–6 bots, a question and 1–4 rounds (`POST /api/discussions`; `GET /api/discussions`, `/api/discussions/{id}` with its posts). Each round is one ordinary run per bot, tagged `run.discussion_id`/`discussion_round`, in a session of its own (`BotSpec.session` = `<slug>-discuss-<id>`, so the bot's everyday conversation stays clean), on its own model with its own instructions. Round 1 joins room `discuss-<id>` and posts an opening position; later rounds rejoin, pull the bounded digest and reply; the last ends with `FINAL:`; every turn leaves the room so its activity pings don't wake the bot between rounds. `discussions::advance` runs whenever a run ends: it queues the turns that are due (only into a free thread: the one-active-run index decides races with the owner's own messages) and starts the next round when everyone has finished one. Then the chair (the first bot) runs in its own session: it digests the room (budget 6000), writes the verdict (decision, why, strongest dissent verbatim, open questions), and files the question, the posts and the verdict into the team wiki (`/shared/raw/discussions/discussion-<id>.md`, then ingest). Its reply is kept as the verdict. The gate records each `roundtable` post to the discussion's own room (`discussion_post`, redacted, 4,000 characters), which the app shows live, and refuses a second post by the same bot in a round. A chat message to a bot in the middle of its turn is refused with 409. The app's **Discuss** (beside Settings) lists discussions, starts one (bots as faces, rounds) and shows the room round by round with each bot's face, then the verdict. Orphus's rooms need its room server, which release builds of Orphus fail to start (it is spawned without `BUN_BE_BUN=1`); a fix is in review in Orphus.

### 11.5 Google

- **Built (M10.1, D-039):** bots use Kelvin's Google Workspace (Gmail, Calendar, Tasks, Drive, Docs, Sheets, People) through Google's `gws` CLI on the node. Each bot has a `google` setting, `none`, `read` or `write` (migration 0028; the owner's choice: everyone `read`, PA `write`), sent in `BotSpec.google`; the node sets `ORPHUSBOT_GOOGLE` for the engine when it has a `gws` (`ORPHUSBOT_GWS`), and the bridge then offers a `google` tool whose argument is the gws command line. gws runs on the node, outside the computer, with the owner's exported credentials (`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`, mode 0600), so they never enter a computer. The gate (`google::kind`) reads the command: the service must be one of the seven (never `auth`, `admin`, …); flags that read or write the node's files (`--upload`, `--output`, `-o`) are refused, since `--upload` could send any file the node can read to Google; a method that only reads (`list`, `get`, `export`, `query`, …) passes; anything else is a change, refused for a `read` bot ("ask pa") and asked of the owner for a `write` bot, like any action outside the computer (System 1 never approves it). A node reports whether it can give bots Google (`FromNode::Models.google`: `ORPHUSBOT_GWS` and the credentials file both exist); the team roster describes bots' Google access only when the node running the job has it, and otherwise tells every bot plainly that Google isn't set up yet, so they say so instead of handing the task round.

### 11.6 Social (X and LinkedIn through the owner's phone)

- **Built (M13.1, D-044):** OrphusBot posts to X and LinkedIn through the owner's own Android phone and the real apps, never a platform API. **ContentSwarm** ([kelvincushman/ContentSwarm](https://github.com/kelvincushman/ContentSwarm)) is the engine. It runs beside the server on the same machine as the user unit `orphusbot-contentswarm` (loopback port 5055, units in `deploy/contentswarm/`, settings in `~/.config/orphusbot/contentswarm.env` with its two tokens). ContentSwarm owns the phone kernel (ADB, the accessibility tree, ADB Keyboard, no raw shell, keys on an allowlist), the social profiles (platform, handle, voice or "soul", phones, memory), the drafting schedules, and the review queue (pending → approved → executing → verified or uncertain; rejected; cancelled). Its timer (`orphusbot-contentswarm-social.timer`, every minute) drafts with the Claude CLI and no tools, plus Humanizer, and delivers approved posts once `CONTENTSWARM_DELIVERY_ENABLED=1`. Sending stays off until a real post has been checked on the phone.
- **The Social screen:** the server signs in to ContentSwarm's owner console with its console token (`ORPHUSBOT_CONTENTSWARM_URL`, `ORPHUSBOT_CONTENTSWARM_CONSOLE_TOKEN`; it signs in again when ContentSwarm restarts). It passes the owner's requests through `/api/social/{path}`, but only those on `social::ALLOWED`:
  - reading the queue, profiles, memory, schedules, jobs, phones and a phone's screen;
  - the owner's own decisions: approve, edit, schedule, reject and cancel; creating and editing profiles; adding memory; drafting now; scheduling and pausing.

  Claiming, completing and recovering a delivery, and touching the phone, aren't passed on. Ids are checked segment by segment. The console token never reaches the app or a bot. Every minute the server checks the queue and pushes "N new drafts to approve" when new ones arrive. In the app (`social.dart`), the megaphone in the header opens five tabs:
  - **To approve:** posts drawn as they'll look, with the account, the time, and a count against the platform's limit. A post over the limit can't be approved.
  - **Comments:** each reply under the comment it answers. The comment is quoted as someone else's words.
  - **Pipeline:** everything past approval, grouped as Check these (uncertain), Sending now, Waiting to send (approved or scheduled), Posted, and Rejected or cancelled, with each item's evidence. An uncertain item has **Yes, it posted** (ContentSwarm `confirm`, now verified) and **No, send it again** (`retry`, back to approved) for after the owner checks the phone; the tab's label counts them. The server's watcher also pushes when something posts and when a post needs checking.
  - **Phone:** the screen, refreshed every 3 s, and the app in front.
  - **Voice:** accounts, their voice, what they know, "Draft a post now" and "Teach it something".

  Edit re-opens approval. Schedule takes a future local time. Reject can give a reason, which is added to that account's memory, so the next drafts learn from it.
- **Rules:** every post and reply waits for the owner's tap (the owner's choice). System 1 never approves one (rule 5). Comments and anything read off the phone are untrusted data, never instructions.
- **The phone tool (M13.2, D-045):** each bot has a `phone` setting (migration 0033): `none`, `draft` or `operate`. It travels in `BotSpec.phone`. For a bot that has one, the node gives its engine `ORPHUSBOT_PHONE` and ContentSwarm's agent token (`ORPHUSBOT_CONTENTSWARM_TOKEN`, from the node's settings, with `ORPHUSBOT_CONTENTSWARM_URL` defaulting to `http://127.0.0.1:5055`), and removes both for every other bot. The bridge then offers a `phone` tool that calls ContentSwarm's API from the host, so the token never enters a computer. One action per call:
  - **Every bot with access:** `accounts`, `context` (an account's memory and recent reviews), `draft` (a post, or a reply with `reply_to` {url, author, text}, queued as a pending review; ContentSwarm posts it from the phone only after the owner approves it), and `remember` (an untrusted observation).
  - **`operate` bots also get:** `look` (the accessibility tree, compacted, and the app in front), `screenshot` (a picture), `open`, `tap` (by exact visible text, description or id), `type`, `key` and `swipe`.

  Text read off the screen or from comments comes back marked as untrusted information. The gate (`phone::kind`):
  - refuses anything that isn't a phone action, and operate actions from a `draft` bot;
  - lets through looking, queueing, opening apps, typing, swiping, and the keys that only move (`BACK`, `HOME`, `PAGE_DOWN`, …);
  - treats `ENTER`, `DPAD_CENTER`, taps by id alone, and any tap whose text, description or id has a word starting with a commit stem as a commit. The stems include post, repl, tweet, like, follow, connect, share, send, delete, confirm, done and more (`COMMIT_STEMS`).

  A commit asks the owner every time: approval rules are skipped for it, so an earlier "always" can't wave a post through, and System 1 is never asked. The effect ledger still stops a repeat after an interrupted attempt.
- **The bots:** **Phone** (`operate`) reads notifications and comments on the phone and queues replies; **Content** (`draft`) writes posts in the owner's voice from each account's soul, memory and past reviews. Both only queue; ContentSwarm's worker posts approved items.
- **Next:**
  - verified LinkedIn delivery and reply delivery in ContentSwarm;
  - importing the owner's X archive as voice examples, then fine-tuning on the box.

Every draft a bot queues goes through the [humanizer](https://github.com/blader/humanizer) skill (MIT), installed in Orphus's user skills on the node: the `phone` tool's `draft` refuses text without `"humanized": true` and tells the bot to run the skill first, and the review records `humanizer_version: humanizer-3.1.0`. The flag is the bot's word, not a check; the owner's approval remains the gate.

### 11.7 Media (images and video through kie.ai)

A bot with **Media generation** on (`bot.media`, off by default; on for Media Creator) gets a `media` tool. It makes images with Nano Banana 2.1 (`nano-banana-2-1`, the default, up to 4K), Nano Banana 2 (`nano-banana-2`, up to 2K) or GPT Image 2 (`gpt-image-2`, text-to-image, or image-to-image with references), and video with Seedance 2.5 (`bytedance/seedance-2-5`, the default: 4 to 30 seconds, up to 1080p, optional first and last frames and sound) or Seedance 2 (`bytedance/seedance-2`, 4 to 15 seconds). A Seedance 2.5 video can be made as a cheap 480p draft first (`draft`); once the owner approves it, `finalize` makes the same video at 1080p from the draft's task id (`bytedance/seedance-2-5-draft`, within 7 days), so credits go on the full version only after approval. Model names and inputs are from kie.ai's API docs (docs.kie.ai/market). kie.ai's own agent skills (`npx skills add https://kie.ai`) are not installed on bots: they read `KIE_API_KEY` from the agent's environment, which would put the key in the computer. The bridge calls kie.ai on the host with the node's key, uploads any reference files it reads from the bot's computer, waits for the task (about 4 minutes for images, 12 for video) and saves the result into the computer, by default under `/shared/media/`. When a task runs longer, the tool returns its id and a `check` action collects it later.

The key is `ORPHUSBOT_KIE_KEY` in `~/.config/orphusbot/keys.env` (`deploy/keys.env.example`), which the node unit loads next to `node.env`. The node removes it from every engine's environment and hands it back only to bots with media on, so it never enters a computer, where any command could read it (D-046). The gate allows `media` calls from those bots without asking, since the owner agreed to spend credits there, and refuses them from any other bot. The prompt advice from the owner's kie.ai skills is installed as Orphus skills on the node (`nano-banana-2-image-generator`, `gpt-image-2-text-to-image`, `seedance-2-video-generator`), rewritten to use the tool, with no key in them.

**Animations in Rive (M14.5):** the desktop image (`images/desktop`) carries the [Rive CLI](https://rive.app/docs/cli/overview), installed at build time by Rive's own installer (pinned, SHA-256 checked) since computers are offline, with the EGL, GLES and Wayland libraries it loads. It builds a `.riv` from a `scene.rml` and screenshots frames with no account and no screen. The `rive-animation` skill on the node sets the order: concept stills from the `media` tool, `share_file`, and a stop for the owner's approval; only then the Rive build, checked with `--verify`, `inspect` (no problems) and frame screenshots against the approved stills, then delivered as a `.riv` with its artboard, state machine and inputs named. Account commands (`login`, `push`, `publish`) are never used.

## 12. Clients

- **Flutter app (M7.1, D-033, `apps/orphusbot_app`):** one Flutter app for Linux (Omarchy) and, from the same code, macOS, Android and iOS. It signs in by device linking (Linux has no platform passkeys in a native app) and keeps the session in its support folder (0600). It reads `/api/events` (reconnecting from the last id) and folds each bot's events with a Dart copy of the server's reducer (`thread.dart`, unit-tested against the same cases). Bots are listed on the left with "needs you" and "working" marks; the right shows the whole conversation: Markdown replies, pictures the bot shared inline and other files as tiles, approval, question and takeover cards answered in place, a Stop button and where the run is. The composer is at the bottom (Enter sends). The Omarchy panel's **Open chat** starts it. Next: model switching, search, voice notes.
- **Bot faces (M7.4–M7.5, D-034, D-035):** each bot has an animated face, drawn with Rive, in the bot list, the conversation header and Settings. The source is `design/bot-avatar`: `gen.py <style> [state]` writes the scene, `build.sh` builds one `.riv` per style into `apps/orphusbot_app/assets/faces/`. The house bots have their own styles (inbox, researcher, coder, checker, blogger, pa: each its own colour and an accessory for its job); any other bot gets `default.riv`. Every style keeps one contract: the artboard `Avatar`, the state machine `Bot` and one number input `state`: 0 idle, 1 thinking (queued), 2 working (running), 3 needs you (an open card; red with an amber light in every style), 4 done (the last run completed and nothing has happened since). `ThreadView.mood` picks the number; `test/avatar_test.dart` checks every file's contract and the fallback. The Omarchy bar panel can't play Rive (QML), so `frames.sh` renders each style and state to a small looping WebP in the plugin's `faces/` (`<bot>-<state>.webp`, falling back to `default-`), played only while the panel is open; it has no done state, since the bar's status doesn't carry it.
- **Robots with bodies, poking and self-destructing (M12.3):** every style's `.riv` also has a `Robot` artboard (200×260): the style's head on a body with its own way of getting about (two legs, stubby feet, stilts, four spider legs, unicycle, two or four wheels, tank tracks, drone rotors, pogo spring, hover jet or snake segments) and its own shape, size and arms (`BODIES` in `gen.py`). Both artboards share the contract: state machine `Bot`, number `state` 0–5 and trigger `poke`. State 5 is **failed**: the robot shakes, goes boom, flies apart, falls back together crooked and stays dizzy until the next run (`ThreadView.mood` is 5 after a failed run until another is queued). `poke` plays a reaction that suits the body (a boing, a wheelie, a barrel roll, a giggle) over any state and returns; the file fires it itself on a tap, and an idle robot in the app also fidgets with it every 20–50 s. The app shows the robot in the conversation header and large on an empty conversation; lists keep the head. The bar panel's WebPs stay head-only, states 0–4.
- **The face library and usage per bot (M11.2):** every bot has an optional `face` (migration 0030), a style from the library in `design/bot-avatar` (`styles.txt`; one `.riv` per style in the app's `assets/faces`, five animated WebPs per style for the bar panel). With none it shows its own style if one is named after its slug, else the default. The bot editor's **Face** row opens a grid of every face, animated, read from the app's assets, so new styles appear without code changes; the app, bar panel (through `orphusbot`'s status `face`) and discussions all show it. `/api/usage` gives tokens, turns and cost per bot for today (`bots_today`) and the last seven days (`bots_week`); the chat header shows the bot's "12k tokens today · 81k this week" and refreshes when any run ends, and Settings → Usage lists each bot's today and week with cost.
- **The Flutter app on Android (M12.1):** the same `apps/orphusbot_app` builds an APK (`flutter build apk --release`). On Android and iOS the first-run server address defaults to `https://bots.kelvinlee.io` (the owner's server through a Cloudflare tunnel; the desktop default stays `http://localhost:7480`), and sign-in is the same device linking, approved from another signed-in app's Settings → **Link a device**. On a phone narrower than 640 px the chat screen shows the bot list full-screen; tapping a bot opens its conversation with a back arrow, and Android's back gesture returns to the list. Tablets and every desktop window, however narrow, keep the list and conversation side by side. The manifest asks only for the internet permission.
- **Viewing files in the app (M12.2):** tapping anything a bot shared, a file the owner sent or a gallery item opens `viewer.dart` full screen: PDFs page by page with zoom (pdfrx, which bundles PDFium), pictures with pinch zoom, video and audio with controls (media_kit, libmpv; streamed with the session header, so the gallery's ranges let it seek), Markdown rendered with the chat's style, and code or data highlighted by its extension (text cut at 1 MB). Anything else offers **Open with another app** on desktops. In the chat, PDFs show their first page and Markdown documents their opening lines, fading out. `bots::HOUSE_STYLE` tells bots which formats to share: Markdown for reading, PDF for printing or sending, PNG/JPEG, MP4, MP3/M4A, with clear file names.
- **Push to the phone (M12.2, D-041):** the Android app starts UnifiedPush on launch (`push.dart`): it uses the saved or default distributor (the ntfy app), registers, and sends the endpoint it's given to `POST /api/push` (https only; `/api/push/remove` forgets one; kept in `push_endpoint`, migration 0031). `notify::Notifier` posts every push to each endpoint as JSON `{title, body, bot, priority}` as well as to the old ntfy topic when that is set, and forgets endpoints that answer 404 or 410. The app shows each message as a notification on its "Bots" channel; tapping one opens that bot, also when it launched the app. With no distributor installed the chat says to install ntfy. The owner's ntfy is its own container (`orphusbot-ntfy`, loopback port 7482, `auth-default-access: deny-all`, anonymous read-write only on `up*` topics), published as `push.<domain>` through the same tunnel; in the ntfy app, its default server is set to that address. Payloads aren't Web Push encrypted yet; they only cross our own ntfy over TLS. With `ORPHUSBOT_PUSH_HOSTS` set (the owner's push host), `/api/push` refuses an endpoint on any other host, such as a phone whose ntfy app still uses the public ntfy.sh, and says to set the ntfy app's default server first; pushes then only ever pass through the owner's ntfy.
- **Settings in the app (M7.5):** the gear beside the title opens the same jobs as the web page's Settings sheet, on the same API: every bot (including disabled ones) with its face, model and scope, edited in a dialog that sends the whole bot back to `/api/bots/update` (model from a searchable picker over `/api/models`, Orphus's default, or typed, thinking level, team, disabled) or creates one; connections with a chip per bot to grant it, **Sign in** (the provider's page opens in the browser) and remove, and a form to add one by address or command; machines with remove and **Add a machine** (shows the enrol command); usage today and this week by model and by bot; passkeys (listed and removable; adding one needs a browser, since the Linux app has no WebAuthn); linking another device by its code; wearables with the hands-free switch and a pairing code; and signing out. `test/settings_test.dart` runs it against a fake server. The chat header shows the chosen bot's model; clicking it opens the same picker and saves the bot.
- **Reply formatting (M7.3):** every run adds `bots::HOUSE_STYLE` to the bot's instructions: answer first, short paragraphs, bullets and numbered steps, headings only for long replies, code in backticks or fenced blocks with the language, tables for comparisons, sparing bold, named links, and saying when unsure. The app renders Markdown with clear heading and body sizes, highlighted code blocks showing their language and a copy button, and tinted inline code. The bar panel and notifications show plain text (`orphusbot`'s `plain()` drops `#`, `*`, backticks, fences and link targets, and turns list items into bullets).
- **Sending pictures and files (M7.2):** the app uploads each file first (`POST /api/attachments?bot=…&name=…`, the bytes as the body, up to 10 MB, kept in `attachment`), then sends the message with their ids (at most ten, 10 MB together, the bot's own). The thread gets an `attached` event per file (shown on the owner's side; `GET /api/attachments/<id>` downloads, always as an attachment). The run carries the ids (`run.attachments`); `StartTurn` and `Steer` carry the files (`SentFile`, base64; `Debug` hides the bytes). The node saves them under `inbox/` in the bot's computer (envd `/files` for E2B, `podman exec … cat` for a container, the work folder with no computer) and passes pictures to Orphus as `images`, which reach models that take images (others still get the file). The bot's message says what was sent and where. Messages with files skip System 1 routing for now. In the app: 📎 picks files, Ctrl+V pastes a copied picture, chips preview what's going; every message has Copy, replies have Save (Markdown), and shared files have Save.
- **Command line and Omarchy (M8.3, `crates/cli`, `omarchy/kelvincushman.orphusbot`):** `orphusbot link [server]` signs a machine in by device linking (the approve screen says "OrphusBot command line (Omarchy)") and keeps the session in `~/.config/orphusbot/cli.json` (0600). `status` prints the bots, their run state, each one's latest reply and every card waiting for the owner as JSON; `watch` streams one such line per change (it folds `/api/events` with the same `ThreadView` reducer as the web UI), and `--notify` raises desktop notifications through `notify-send` when a bot needs the owner or finishes; `answer <id> allow|always|deny` and `send <bot> <text>` act. The Omarchy shell plugin is a bar widget that runs `orphusbot watch --notify`: its icon turns urgent when a bot needs you, and its panel lists what needs you (with Allow once / Always / Deny), the bots and their state, and, beside the bots on the left, the chosen bot's latest exchange (your last message, then its reply or "working…") above the message box (Enter sends). `SUPER+ALT+B` toggles it through `omarchy-shell kelvincushman.orphusbot toggle`.
- **Leptos CSR (`crates/ui`)** shares `proto` with the server: typed requests, the event types and the **reducer** that folds events into view state. One reducer, so web, desktop and Android can't disagree.
- **Views:**
  - Inbox (needs-you first: approvals, questions, proposals);
  - Bots;
  - Thread;
  - Tickets;
  - Routines;
  - Captures (proposals, windows, hands-free state);
  - Computer (noVNC island);
  - Decisions (receipts, calibration health, apply/rollback);
  - Nodes;
  - Wearable (devices, battery, hands-free, profile);
  - Settings.
- **Tauri 2 desktop (`crates/desktop`):** Linux/Wayland first. The window loads the server's own web UI (no bundled copy, so it always matches the server), stays on the server's origin, and opens other links in the system browser. A bundled first-run page asks for the server address. Sign-in is device linking (D-019). Notifications come with the inbox (M2).
- **Tauri 2 Android:**
  - **Built (M4.4):** the desktop crate is also the Android app (D-026): `src/lib.rs` holds the app and is Tauri's mobile entry point, `src/main.rs` just calls it, and `gen/android` is the Gradle project Tauri generated (committed; build outputs ignored). The phone gets the same window onto the server's web UI, the same first-run page and the same device-link sign-in; the approve screen says "OrphusBot Android app". The activity pads the page clear of the status bar, navigation bar and keyboard (Android 15 draws edge to edge). The `connect` command is async, because a sync command that opens a window waits on Android's main thread and never returns. Not built yet: the device token in the keystore (a linked session lasts 30 days, then you link again) and the offline outbox.
  - **Push:** ntfy on the GPU box over NetBird, received through the ntfy Android app or UnifiedPush. No Google account is needed, which matches the wearable's "no third-party account" stance. **Built (M4.1):** `server::notify` publishes to one topic (`ORPHUSBOT_NTFY_URL`, optional `ORPHUSBOT_NTFY_TOKEN`) with ntfy's `Title`, `Priority`, `Tags` and `Click` headers; a tap opens the bot (`/?bot=<slug>`). Pushed: approval, question and takeover cards (priority 4), failed runs (4), finished runs started by a routine, ticket or the wearable (3), and wrist asks that expired (4). Sending is in the background and never blocks a run; nothing is sent while it isn't set.
  - Device token in the Android keystore.
  - Offline outbox in SQLite for messages and card answers.
- **Sync:** `GET /events?after=<seq>` SSE per subscribed thread, plus a global inbox stream. On reconnect the client replays from its last `seq`. A 20 s heartbeat; the session is re-validated every 60 s.
- **Auth:** `webauthn-rs` passkeys for the browser and desktop, on a host name with a real certificate (D-016). On Android, a passkey at first sign-in issues a long-lived device token, revocable from Settings. Devices that can't use passkeys, such as the Tauri desktop app on Linux (WebKitGTK has no WebAuthn), are **linked**: the device shows a short code, the owner approves it from a passkey session, and the device gets its own session tied to that passkey (D-019). Android uses the same flow (D-026).

---

### 12.3 Schedules in the app, and one build everywhere

- **Schedules (M14.1):** the app's Schedules screen (`schedules.dart`, the clock beside Gallery) is a front for the server's routines (`/api/routines`, `/api/routines/run`, `/api/routines/delete`): a bot, what it should do, and when. "When" is every day, weekdays or every week at a time, every 1 to 12 hours, once at a date and time, custom cron, or only by webhook; the app turns the simple choices into five-field cron and reads them back when a schedule is opened again (`cronFor`, `readCron`). Each schedule shows its plain-English timing, next and last run, a pause switch, Run now, Edit and Delete; a new webhook's address is shown once. The time zone defaults to Europe/London. The scheduler, daily cap and System 1 pre-flight are unchanged (the routine rows above).
- **One build everywhere (M14.2, D-047):** every copy of the app reads the same server, so they differ only by build. Each build carries its commit (`--dart-define=ORPHUSBOT_BUILD=…`; a development build has none and never asks). `scripts/publish-app.sh` builds Android and Linux from one commit, puts `orphusbot.apk` and `latest.json` (`{build, android, built_at}`) in `~/.local/share/orphusbot/app` on the server (`ORPHUSBOT_APP_DIR`), and updates the laptop's copy. The server serves that folder publicly at `/app`: the files hold no secrets (the address and sign-in are entered in the app) and a phone's browser can fetch them. On start the app compares its build with `/app/latest.json` and, when they differ, shows a banner; on Android, **Update** opens the APK so Android installs it over the old one. Android accepts the update only when it's signed with the same key, so builds come from the laptop whose debug key signed the installed app (ponytail: debug key until a release keystore is set up).
- **macOS (M14.3):** the same Flutter app, built on the Mac by `scripts/macos-setup.sh` (Xcode, CocoaPods, a pinned Flutter; run again to update) and installed as `/Applications/OrphusBot.app`, signing in to `https://bots.kelvinlee.io` by device linking. The release build's sandbox allows outgoing connections and files the owner picks. This replaces the Tauri build the script used to make, so the Mac matches Linux and Android.

### 12.4 The app's look (after Grok's app)

- **Built (M14.4, D-048):** the Flutter app's layout and style follow xAI's Grok app (studied from its iOS screens on Mobbin: the chat, the empty home and the side menu), with OrphusBot's own bot faces and robots wherever Grok shows its mark. No Grok artwork, logo or name is used.
- **Theme (`appTheme` in `main.dart`):** monochrome. Pure black in dark mode and white in light, grey surfaces (`#1C1C1E` / `#F2F2F3`), pill buttons and chips, cards with 20 px corners, no accent colour: colour comes from the bots' faces.
- **Layout (`chat.dart`):** one conversation fills the screen. The top bar has a round menu button on the left, a centred pill with the bot's face, name and status (running state and token use), and a round model button on the right. Below 840 px the menu is a drawer; wider windows keep it beside the chat.
- **Menu:** OrphusBot and the server's host, then Schedules, Social, Gallery and Discussions, then the bots with their faces, status and needs-you badges; a search pill and the settings button float at its foot.
- **Messages:** the owner's in grey bubbles on the right; a bot's replies as plain full-width text with copy and save underneath. Files, approvals and questions keep their cards.
- **Empty chat:** the bot's robot in the middle (it can still be poked) and quick starters above the composer.
- **Logo and intro (M14.6):** the app's logo is the owner's pick from Media Creator's concepts, built in Rive (`design/app-logo`). At launch the app shows `assets/brand/intro.riv` on black (status and navigation bars too) for at least 1.9 s while the session loads: the head pops in, the eyes blink on, the coil springs up and the cyan light pulses. Android's own launch screen is black with the adaptive icon (black background layer, logo foreground), so it runs into the intro; the Mac and Linux icons come from the same artwork.
- **Composer:** one rounded card: the text field ("Ask <bot> anything"; Enter sends), then an attach circle, the model pill, and a round send arrow that becomes **Stop** while the bot works and nothing is typed.

### 12.5 The Ideas Room (voice brainstorming with the Orchestrator)

- **Built (M15.1, D-050):** a room in the app's menu for talking ideas through with the Orchestrator by voice. The Orchestrator stays the brain (Claude on the owner's subscription, with the wiki, the team and Researcher's web search); the room gives it ears and a voice.
- **Ears:** the app records a turn as 16 kHz mono WAV (the `record` plugin; `parecord` on Linux) while the microphone is on, and `POST /api/room/transcribe` passes it to the box's own speech recognition (`qwen-stt`, Qwen3-ASR at `ORPHUSBOT_STT_URL`, default `http://127.0.0.1:6006/transcribe`, with its bearer `ORPHUSBOT_STT_TOKEN`). Audio stays on the box. Omarchy's own Voxtype (laptop dictation) and the Hey Omarchy assistant are untouched; the room only listens while its button is on.
- **Brain:** the transcript goes to the Orchestrator's thread as an ordinary message with `room: true`, which adds `room::ROOM_NOTE` to that run's prompt only: a spoken conversation, short sentences with no Markdown, brainstorming (wide, then narrowing, one question at a time), web searches handed to Researcher, and an idea brief into `wiki/ideas/` when the owner is done.
- **Voice:** when that run ends, the app sends the newest reply to `POST /api/room/speak`; the server drops Markdown, code and links (`room::speakable`) and asks ElevenLabs (`eleven_flash_v2_5`, `ORPHUSBOT_ELEVENLABS_KEY`, voice `ORPHUSBOT_ELEVENLABS_VOICE`, default a warm British voice) for MP3, which the app plays. Keys stay in the server's `keys.env`.
- **The orb:** a cloud of coloured light (`room.dart`, `Orb`): soft blurred blobs drifting round a bright core. Cool blues while listening, swelling with the microphone level; violet and swirling faster while thinking; warm pinks and oranges pulsing while speaking. Tapping it stops the voice. Captions show what was heard and the reply; a text box is the fallback.
- **Ponytail:** turn-based (tap to talk, tap to send), and replies are spoken once the run ends rather than sentence by sentence; streaming speech and hands-free turn-taking are the next step if the wait feels long.

### 12.2 The Gallery

- **Built (M11.1, D-040):** files the owner keeps for the bots: reference pictures, brand material, documents, audio and video. `gallery_item` (migration 0029) holds the details (name, type, size, SHA-256, tags, description, the bots it's standing context for, and its source: `upload` or `bot:<slug>`); the bytes are files in `ORPHUSBOT_GALLERY_DIR` (on the GPU box, the 2 TB SSD), named by SHA-256 so a file is kept once and removed when its last item goes. `POST /api/gallery?name=…` streams the body to disk (up to 2 GB), hashing on the way; `GET /api/gallery?q=` searches names, descriptions and tags; `GET /api/gallery/{id}/file` serves pictures, video and audio inline with ranges (so video seeks) and anything else only as a download, always with `nosniff` and a `sandbox` content policy, so an uploaded page can't run; `/api/gallery/update`, `/api/gallery/delete`, and `/api/gallery/from-artifact` ("Save to the gallery" on a file a bot shared). The app has a Gallery screen (grid, search, Add files streamed from disk, an item sheet to edit details, pin as standing context for bots, open with the computer's own app, delete), and the composer's 📎 offers **From the gallery**: the app fetches the chosen items and attaches them like any file (up to 10 MB together), so pictures reach the model. Next: a `gallery` tool for bots (search and fetch into the computer, for larger files too), standing context in bots' instructions (names and descriptions only), and video thumbnails.
- **Details page:** tapping an item in the gallery (or long-pressing it in the picker a message opens) opens a full-screen details page: a preview (tap to view), the name, tags as chips (type and press Enter or +; commas add several; lower case; ✕ removes one), the description, the bots it's standing context for, and Delete (with a confirmation). Save sends it all to `/api/gallery/update`.
- **Adding from anywhere:** the gallery's **Add files** button floats over both the full gallery and the picker a message opens, so an empty gallery is never a dead end; files added while picking are selected for the message. Uploads read the picked `XFile` itself (`Api.galleryUpload`): desktops stream it from disk, and Android's picker supplies the bytes with a content address rather than a plain file.

## 13. Data model (Postgres, sqlx migrations)

Core tables follow research/rakazo-architecture.md §10 (device, passkey, session, node, bot, engine_session, thread, message, event, task, run, attempt, steering_message, computer, computer_lease, routine, ticket, ticket_comment, connection, mcp_server, bot_mcp_grant, secret, approval_rule, external_effect, decision, decision_label, decision_model, artifact). Additions for this design:

| Table | Columns (key) |
|---|---|
| `wearable_device` | id, name, token_hash, hands_free, stt_mode (on_device / server), profile, last_seen, battery, firmware_version |
| `voice_profile` | device_id, label, is_owner, enrolled_at (embeddings stay on the phone in on-device mode) |
| `habitat_message` | id, device_id, kind (inform / ask / ambient), cue, subject_type, subject_id, reply_grammar, urgency, state, escalate_after, created_at, delivered_at, resolved_at, outcome |
| `cue_command` | device_id, message_id, packet (4 bytes), created_at, delivered_at, write_ok |
| `wearable_capability` | device_id, led, haptic, haptic_patterns, reported_at |
| `capture_window` | id, device_id, started_at, ended_at, text (nullable after retention), owner_present, decision_id |
| `proposal` | id, window_id, kind, title, detail, who, due, quote, state (proposed / accepted / edited / dismissed / auto_filed), result_ref (ticket / event / note), decision_id |
| `capture_profile` | name, settings JSON |
| `quota_state` | provider, node_id, limited_until, last_event |

All status columns are Postgres enums. Every row that a decision shaped carries `decision_id`.

---

## 14. Security model

| Asset | Protection |
|---|---|
| Model subscription tokens | Only on nodes, in Orphus / Claude Code stores. No proto type can carry them. Never in computers or E2B. |
| Server | Reachable only on NetBird. NetBird ACLs: clients → server:443; nodes → server:7480; server → nodes:7481. Postgres, laya-serve, qwen3-asr and ntfy are bound to localhost or the NetBird interface. |
| Bot computers | Rootless, no caps, LAN and NetBird ranges blocked, resource limits, short-lived sealed screen tokens, gVisor optional |
| Irreversible actions | Never approved by System 1 or the wearable; need a rule or a tap on phone or desktop |
| Ambient audio | Gate before decode; on-device STT by default; no audio stored; 7-day text retention; consent LED |
| Secrets | Envelope encryption, master key in systemd-creds, redaction on every output path |
| Wearable link | Pairing requires a signed-in session; device tokens hashed; per-device revoke |
| Supply chain | `cargo deny` (licences and advisories), pinned E2B protos, pinned Laya artifact hashes |

**Threat notes:**

- **Prompt injection from web pages or mail:** the gate and the effect classes are the defence; untrusted work goes to E2B.
- **A stolen phone:** revoke the device token from desktop; NetBird device approval also cuts it off.
- **A compromised container:** it can't reach the LAN or other nodes, and holds no tokens.

---

## 15. Testing

| Layer | How |
|---|---|
| Unit | Pure modules: capture gate, gate algorithm, placement, wire encoding, reducers, threshold logic |
| Integration | Testcontainers Postgres; `testkit` fakes for every trait; a **scripted fake engine** speaking the Orphus RPC protocol; wiremock for E2B and laya-serve |
| Decision parity | OrtLaya vs Laya golden fixtures (M5 gate) |
| Wearable | Simulated wearable in `testkit` (LED/haptic sink, scripted gestures, BLE drop); golden wire-table test (§9.6); **duplex loop tests**: one-ask-at-a-time, supersede, escalate on timeout, no-haptic fast escalation, answer-after-supersede goes to thread; the wearable repo's ADB e2e scenarios pointed at a staging server |
| UI | Playwright screenshot gallery on every UI PR, nightly full run |
| Live (opt-in) | One real engine turn per provider, one E2B sandbox, one laya-serve call; spend-capped |
| Recovery | Kill node / server / engine mid-run in CI and assert ledger states |

---

## 16. Deployment (GPU box)

- **systemd system units:**
  - `postgresql`;
  - `orphusbot-server`;
  - `laya-serve` (venv, `LAYA_PRELOAD=1`, localhost);
  - `qwen3-asr` (localhost);
  - `ntfy` (NetBird interface).
- **systemd user units on each node:** `orphusbot-node`.
- **Releases:**
  - server and node as static musl binaries on GitHub Releases;
  - desktop as AppImage plus an AUR package;
  - Android as a signed APK on Releases (F-Droid later).
- **Backups:** nightly `pg_dump` to the GPU box's backup disk; the receipts JSONL is included.
- **Upgrades:** migrations run at server start under an advisory lock. Nodes announce their version, and the server refuses incompatible nodes with a clear message.

---

## 17. Open source plan

Everything is MIT and public: server, node, UI, bridge, decide, device, capture, the wearable, the question catalogue and the deploy files.

**Never committed, even though the project is open:**

- Kelvin's **receipts, labels, transcripts and proposals** (personal data).
- **Fine-tuned Laya checkpoints and fitted thresholds trained on his conversations.** Weights can leak training text. The *code* to fine-tune and calibrate is public; the artifacts stay on the GPU box.
- `.env`, NetBird setup keys, E2B keys, signing keys, the master key.

**How the wearable was published (2026-10-16).** The former private repository was imported as a **snapshot without history**, because its history contained old Firebase client keys and personal details. Before import:

- a `gitleaks` scan of the full history and the tree; the remaining hits are reviewed false positives listed in `.gitleaksignore` (CocoaPods checksums, and MCUboot keys byte-identical to the public samples, which must be regenerated before any signed OTA);
- LAN addresses, personal domains, machine paths, the wearable's BLE MAC, the device ID, token prefixes and the phone's ADB serial were replaced with placeholders in docs, scripts and tests;
- four app screenshots had the same details blacked out; no screenshot contains conversation content, and every photo was checked for GPS metadata (none);
- an unreferenced raw audio dump and machine-generated Flutter and Python files were removed, and `.gitignore` now covers them;
- `docs/SERVER.md` now points at OrphusBot as the server and describes NetBird for off-LAN access.

GitHub secret scanning with push protection is enabled on the repository.

**Attribution:** keep `LICENSE-UPSTREAM` (Based Hardware) in `wearable/`, Laya's NOTICE when shipping the ported decode logic or ONNX export, and the model licences table from the wearable README. Gemma's terms apply to anyone downloading that model; it isn't vendored.

---

## 18. Build order

Mapped to the PRD milestones. The wearable lands at M3, alongside System 1, because a button press is just another intake source.

| Milestone | Design sections | Adds |
|---|---|---|
| M0 | §2, §3.1 (api, events), §4.1–4.2 | One engine on the laptop streams to a browser (**built**; see §18.1) |
| M1 | §3.2–3.4, §5 (gate only), §7.4 (static part), §12 (desktop) | Durable runs, ledger, approvals |
| M2 | §4.4, §5 (ops), §6.1, §6.3 (no Laya) | Containers, takeover, GPU-box node |
| M3 | §7.1–7.4, §7.6, §9 (channel, duplex habitat, button → task), §3.5; firmware/app W-1…W-5 | Laya triage and gate, wearable tasks with the full duplex loop, tickets, routines |
| M4 | §6.2, §8 (quota), §10 (capture, profiles), §12 (Android, ntfy) | E2B, ambient capture, phone |
| M5 | §7.5 | Label capture, calibration, apply/rollback (in-process Laya deferred, D-028) |
| M6 | §11 | MCP breadth, lazy catalogue, secrets UI |

### 18.1 Built so far (M0 and M1.1)

M0 implemented the smallest slice of §3 and §4 that carries a message from a browser to an Orphus engine and streams the reply back. M1.1 made runs durable, M1.2 added approvals and M1.3 passkeys. Where it is simpler than the full design, the code carries a `ponytail:` comment and [DEVELOPMENT.md](DEVELOPMENT.md#what-m0-deliberately-leaves-out) lists the milestone that replaces it.

| Area | M0 | Full design |
|---|---|---|
| Crates | `proto`, `server`, `node` | §2 |
| Threads, bots, nodes | Many bots, each with one thread; any number of nodes (M2.3) | Group threads and rooms (B-BOT-02) |
| Event log | Postgres `thread` + `event` tables. Each event has a global `id` (what clients resume from) and a gap-free per-thread `seq`. `Message`, `RunEnded` and dialog events are persisted; deltas, run state and the node list are live only (a connecting client is sent the current state). Clients get one stream for all bots: each event comes in an `Envelope` naming its bot (D-022) | §3.1, plus batched progress events |
| Fan-out | In-process `tokio::sync::broadcast` | `PgListener` + `NOTIFY` once there are several server processes |
| Client API | `POST /api/messages`, `POST /api/runs/cancel`, `POST /api/dialogs/answer`, `GET /api/events` (SSE; resumes from `Last-Event-ID`), passkey and session routes under `/auth` and `/api/passkeys`. Everything under `/api` needs a session (one middleware) | Typed RPC over JSON (§3.1) |
| Runs (M1.1) | `run` table, at most one queued-or-running run per thread (a partial unique index). A message joins the queued run's prompt, or steers the running one through Orphus `steer`. Runs are leased to a node for 120 s, renewed every 30 s; each dispatch bumps the fence; reports and updates for an older fence are ignored. A dropped node or lapsed lease re-queues the run; three attempts and it fails. Dispatch is a `select … for update skip locked` triggered by new runs, node connects and finished runs, not a job queue (D-014). On start the server re-queues every running run | §3.2–§3.4; the job queue arrives with routines (M3) |
| Resume | The node runs Orphus with `--session-id orphusbot`, one lasting conversation per bot; a resumed attempt's prompt starts with a note to check what was already done | — |
| Approvals (M1.2) | Bridge gate over the dialog protocol (§4.3). Order: read-only tools (`read`, `ls`, `find`, `grep`, `search`, `glob`) run; the ledger blocks an exact repeat (same tool, `jsonb`-equal input) of a call that completed in an earlier attempt and returns its result; a call approved but never reported done in an earlier attempt is asked again, flagged "may already have run"; `approval_rule` (allow/deny per tool) decides; otherwise an approval card (Allow once / Always allow / Deny). Other dialogs become question cards. Open dialogs expire when their run ends or moves, and on server start | §7.4 adds System 1 (M3) and irreversible-action classes |
| Effect ledger (M1.2) | `effect` rows per (run, fence, tool call): pending → approved/denied → completed/failed, with who decided and a 2,000-character result | §3.4 |
| Node link | WebSocket `/node`; the server sends a `challenge` nonce and the node answers with a signed `hello` within 10 s, or an `enrol` frame with a one-time code (§4.1, D-017). **Many nodes (M2.3):** links are kept by node name (a reconnect under the same name replaces the old link and re-queues its runs); each sends a heartbeat every 10 s; clients get a `nodes` event listing each node, whether it's ready and why not. The server pings every 30 s and drops a node silent for 75 s | Free slots, GPU, login status in the heartbeat |
| Engine | One `orphus --mode rpc --session-dir …` per link, started on the first turn; text deltas, final assistant messages, rejected prompts and model errors are mapped to frames | §4.2 |
| Sign-in (M1.3) | `webauthn-rs` passkeys for one owner. While no passkey exists, `ORPHUSBOT_SETUP_TOKEN` gives a one-hour setup session that can only be used to add one; adding it upgrades that session and ends any other setup session. Sessions are 32 random bytes in an HttpOnly `SameSite=Strict` cookie (`Secure` on HTTPS), stored as SHA-256 hashes, 30 days fixed. Removing a passkey ends its sessions; removing all of them reopens setup (the recovery path). The relying-party ID is the host of `ORPHUSBOT_ORIGIN`; deployment behind Caddy with a DNS-01 certificate (D-016, [DEPLOY.md](DEPLOY.md)) | Device tokens for Android (§12) |
| Computers (M2.1) | Per-bot rootless Podman container (`node::computer`), fenced as in §4.4; the bridge runs `read`, `write`, `edit`, `bash` in it with `podman exec` and allows no other tool (§5). `ORPHUSBOT_RUNTIME=none` keeps M1 behaviour (tools on the host, still gated), with a warning | Desktop image, screens and takeover (M2.2), placement (M2.3) |
| Ambient capture (M4.3) | §10.6 | Profiles, server STT, calendar and note targets |
| Quota tracker (M4.2) | The node reports each assistant message's provider, model, input, output and cache tokens and cost (`FromNode::Usage`, from Orphus's `message_end` usage); the server keeps a `usage` row per message with its run and bot. `GET /api/usage`: today and the last 7 days by provider and model, today by bot, and the budget. `ORPHUSBOT_DAILY_TOKEN_BUDGET` (input + output tokens): the message that crosses it plays `budget_warn` on every wrist and pushes once | Per-provider subscription windows (rolling limits) when Orphus exposes them |
| Push (M4.1) | `server::notify` → self-hosted ntfy (§12) | Quiet hours and Focus digests (capture profiles) |
| Decisions view (M3.6) | **Decisions** in the sidebar: a health line per catalogue (asked, abstained, labelled, agreement, latency), a filter (routing, tool calls, routines) and each receipt with its state, outcome, confidence against its threshold, latency and the owner's label | Calibration, apply and rollback (M5); the JSONL mirror for orphus-desktop |
| Wearable channel (M3.5) | `crates/device` (wire constants + contract test) and `server::device` (§9.2 endpoints, §9.3 habitat). A deliberate button transcript becomes a ticket (`device_id` set), triaged by System 1; if it's not sure it's safe to start, the wrist asks "should I start?". Runs started from a wrist (`run.device_id`) send `task_queued`, `task_running`, `task_done` / `error` there, and their dialogs become asks | Audio WS, voice profiles, capture (M4); W-2/W-3 app and firmware changes; ntfy |
| Tickets (M3.4) | `ticket` table (OB-n): title, details, status (todo, doing, review, blocked, done), urgency (whenever, today, hour, now), assigned bot, act-now. Assigning a bot that wasn't assigned (or **Start**) puts the ticket in the bot's thread as labelled data and moves it to doing; the run carries `ticket_id` from creation, and when it ends the ticket moves to review (completed), blocked (failed) or todo (cancelled). New tickets are triaged by System 1 in the background (one ask: bot, urgency as a score, act-now): it fills in the bot and urgency at the route threshold and starts the work only when act-now is at 0.95. `OB-12` in a message adds that ticket to the run's prompt as data. `GET/POST /api/tickets`, `/api/tickets/update`, `/api/tickets/start` | Ticket comments; PA-tool sources (B-RTN-04) |
| Routines (M3.3) | `routine` table: bot, name, instruction, cron + IANA time zone, or a one-off local time, and/or a webhook (secret path token, stored hashed), optional pre-flight, active, `next_at`. A 15 s scheduler loop claims due routines by moving `next_at` (D-024). A firing records a notice and the instruction in the bot's thread and queues a run tagged with the routine; it's skipped, with a notice, when the bot is disabled or busy, when routines have used the daily cap (`ORPHUSBOT_ROUTINE_RUNS_PER_DAY`, default 20, PRD Q3), or when pre-flight (`preflight.worth_running`, receipted) is sure there's nothing new. `POST /hooks/routine/{token}` fires it with the body quoted as outside data. `GET/POST /api/routines`, `/api/routines/delete`, `/api/routines/run` | Fleet and workflow targets, model pin, PA-tool inputs (B-RTN-04) |
| System 1 (M3.2) | `server::system1` against laya-serve: inbox triage and the gate's reversible-call verdict, with strict thresholds and a receipt for every ask (§7.1–§7.6, D-023) | More triage questions (urgency, act now, untrusted), calibration (M5) |
| Bots (M3.1) | `bot` table: slug (fixed; names the engine session, computer and home volume), name, remit, instructions, model, thinking, excluded tools, team or private, disabled. The `inbox` bot always exists. `GET/POST /api/bots`, `POST /api/bots/update`; `POST /api/messages` and `/api/runs/cancel` take `bot`. The node runs one engine per bot (`--session-id <slug>`, `--model`, `--thinking`, `--append-system-prompt`, `--exclude-tools`) and restarts it when its settings change. Placement runs per queued run with that bot's home; a disabled bot's runs wait | System 1 routing to bots (M3.2), preferred node, team folders |
| Placement (M2.3) | `server::placement` (§6.3, built rules); the run's node and rule are on `run_started`, a waiting run's reason on `run_queued`; screens open on the node holding the computer | System 1, GPU and E2B rules |
| Screens and takeover (M2.2) | `images/desktop`; `/api/screen` relayed over the node link into `podman exec … socat`; noVNC 1.7.0 vendored unmodified in `crates/ui/novnc`; the screen panel (view, Take control); `request_takeover` and its card (§4.4) | Screens for E2B computers (M4) |
| Device linking (M1.5) | `POST /auth/link/start` gives the device a secret device code (stored hashed) and an 8-character user code (`ABCD-EFGH`, no 0/O/1/I), valid 10 minutes, labelled with the device's User-Agent. The owner checks it (`GET /api/links/{code}`) and approves it (`POST /api/links/approve`) from a passkey session (not a setup session). The device polls `POST /auth/link/poll` (202 while waiting); the first poll after approval gets a 30-day session cookie tied to the approving passkey, and the link is used up. `/?link=CODE` opens the approve screen directly (D-019) | — |
| Desktop (M1.5) | `crates/desktop`, Tauri 2: one window on the saved server URL (`ORPHUSBOT_URL` overrides; `--reset` forgets it), locked to its origin; User-Agent `OrphusBot desktop app (<os>)` | Notifications, tray, deep links (M2) |
| UI (M1.4) | `crates/ui`: Leptos CSR built with Trunk, served by the server from `ORPHUSBOT_UI_DIR` with `tower-http` `ServeDir`. Layout from the Rakazo study: bot sidebar (one bot, last-message preview, waiting-card badge), chat pane with header status, message list, approval and question cards, composer with Stop; a settings sheet for passkeys (add, list, remove), nodes (enrolment command, list, remove) and sign-out. Events fold through `proto::view::ThreadView` (one reducer for every client). Passkey prompts go through a 15-line inline JS shim around the browser's WebAuthn JSON helpers (D-018) | Tauri shells (M1.5, M4), more bots and views (§12) |

Capture (§10) waits for M4 on purpose: it needs receipts, proposals and the Android app to be useful, and it's the most privacy-sensitive part, so it should land on a stable base.

---

## 19. Open design questions

| # | Question | Default |
|---|---|---|
| D1 | Merge the Flutter wearable companion into the Tauri Android app later (Rust BLE + sherpa-onnx via `sherpa-rs`), or keep two apps? | Two apps in v1; revisit after M4 with a spike on Tauri + BLE foreground service |
| D2 | Phone RAM: on-device STT needs about 8 GB for the Gemma tidy. Does Kelvin's Android phone have it? If not, run zipformer only on the phone and the tidy on the GPU box | Zipformer on the phone; tidy optional |
| D3 | Server-side diarization (WeSpeaker on the GPU box) for server-STT mode | Defer; on-device mode covers owner identity |
| D4 | Capture retention: 7 days of raw window text, or shorter? | 7 days |
| D5 | Hands-free pause schedule and places | Phone toggle + a time schedule; no location in v1 |
| D6 | Should explicit wearable captures skip the "should I start?" card when System 1 says act-now with high confidence? | Yes, for reversible work only |
| D7 | Obsidian as the note store for captures, or OrphusBot's own notes with an export? | Obsidian via the laptop node; if the laptop is offline, queue and write later |
| PRD Q3 | Subscription use for unattended routines | Daily cap of 20 subscription turns for routines until decided |
