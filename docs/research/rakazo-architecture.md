# Rakazo architecture study → OrphusBot design

| | |
|---|---|
| Date | 2026-10-16 |
| Subject | Rakazo (`github.com/elie222/rakazo`), commit `7d5e64c` (2026-10-15), v0.2.0 |
| Purpose | Design input for **OrphusBot**: a separate app (web, desktop and mobile clients) where bots work on Kelvin's tasks through the Orphus harness, using his Claude and OpenAI subscriptions, with a fast decision layer (Laya / "Jev" family) |
| Sources | Rakazo source at the commit above (read only; nothing installed or run), Laya source (read only), [orphus](https://github.com/kelvincushman/orphus), [orphus-desktop](https://github.com/kelvincushman/orphus-desktop) (CLEANROOM.md, docs/PRD.md, docs/DESIGN.md), crates.io API (2026-10-16) |

---

## 0. TL;DR

- **Licence:** Rakazo is **Apache-2.0** (root `LICENSE` and `package.json`). Laya is also **Apache-2.0**. Both are compatible with MIT projects. Copying code would require keeping the licence and a NOTICE. We copy nothing anyway: this document is a behavioural spec in our own words, and OrphusBot is in Rust, so nothing is transliterated.
- **Rakazo in one line:** a TypeScript monorepo. Hono + oRPC API, a Graphile Worker process running a ~9,000-line run executor around the Pi agent loop, Postgres as the single source of truth (a durable event log plus `pg_notify`), and pluggable adapters for computers, connectors, auto-review, memory, voice and secrets. The web, Electron and Expo clients are thin views over one SSE event stream.
- **OrphusBot shape:** a Rust server (axum, sqlx, a Postgres job queue) plus a small Rust **node daemon** on each of Kelvin's machines, reached over **NetBird**. The daemon supervises `orphus --mode rpc` engines and per-bot containers. E2B is the overflow and untrusted-work backend. The UI is one Leptos codebase shipped as a web app and as Tauri 2 desktop and mobile apps. A `DecisionModel` trait backed by Laya makes the fast calls (System 1); Orphus agents do the slow work (System 2).
- **Process boundary that stays:** the model loop, Pi providers and subscription auth stay inside the TypeScript Orphus engine, driven over its documented stdio JSONL RPC. Rust never speaks to Anthropic or OpenAI directly.

---

## 1. Licence verdict

| Item | Licence | Verdict |
|---|---|---|
| Rakazo repo | Apache-2.0 (`LICENSE`, root `package.json`). No `NOTICE` file in the repo. | Permissive and compatible with MIT. Reading it and writing a spec is fine. If any code were ever copied: keep the Apache header, add a NOTICE, mark changes. **Policy: copy nothing.** |
| `@earendil-works/pi-ai`, `pi-agent-core` 0.87.1 | MIT (per orphus-desktop CLEANROOM.md) | Already used by Orphus. OrphusBot does not import them; it reaches them through Orphus. |
| graphile-worker 0.17.3, Hono, oRPC, Prisma, Better Auth | MIT / Apache-2.0 | Not used: replaced by Rust equivalents. |
| Laya (`NandhaKishorM/laya`) and checkpoints `convaiinnovations/laya` on Hugging Face | Apache-2.0 (repo `LICENSE`; HF card `license: apache-2.0`) | Use freely. **Keep NOTICE attribution** in OrphusBot when we ship the ONNX export or port `laya-go`'s sequence/decode logic to Rust. Porting Laya's logic (unlike Rakazo's) is acceptable and intended, with attribution. |
| Rust crates proposed in §7 | MIT / Apache-2.0, except `webauthn-rs` (MPL-2.0, file-level copyleft: fine as an unmodified dependency) | OK. |

How clean-room is this? Apache-2.0 doesn't require clean-room. We still follow orphus-desktop's CLEANROOM.md habits: the spec is in our own words, and implementers work from this doc rather than with Rakazo source open. That keeps provenance simple and avoids importing Rakazo's design debt (see §3.10).

---

## 2. Rakazo at a glance

### 2.1 Component diagram

```
 Clients (thin; render state, express intent)
 ┌──────────────┐  ┌────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────┐
 │ apps/web     │  │ apps/desktop (Electron)│  │ apps/mobile (Expo)       │  │ Messaging        │
 │ React 19,    │  │ loads web build; setup │  │ hand-written fetch to    │  │ Slack, Telegram, │
 │ oRPC client, │  │ screen: "This computer"│  │ /rpc, bearer token, SSE, │  │ WhatsApp, Lark,  │
 │ cookie auth  │  │ (docker compose stack) │  │ disk outbox, Expo push   │  │ iMessage (Send-  │
 └──────┬───────┘  │ or "Existing instance" │  └────────────┬─────────────┘  │ blue), via Chat  │
        │          └───────────┬────────────┘               │                │ SDK              │
        │  /rpc (oRPC)  /api/auth (Better Auth)  SSE threads.subscribe(cursor)   └────────┬─────────┘
        ▼                      ▼                            ▼                             ▼
 ┌────────────────────────────────────────────────────────────────────────────────────────────────┐
 │ apps/api (Hono + oRPC 1.15)                                                                     │
 │ writes Message+Task+Run in one txn → appends Event(seq) → pg_notify → enqueues run.continue    │
 │ webhooks (bot, GitHub, messaging, phone), screen-proxy check, team-chat judge, OAuth endpoints  │
 └───────────────┬───────────────────────────────────────────────────────────┬────────────────────┘
                 │ Graphile Worker jobs (job keys)                           │ LISTEN rakazo_events
                 ▼                                                           │
 ┌─────────────────────────────────────────────────────────┐                 │
 │ apps/worker                                              │                │
 │  RunExecutor (packages/adapters/src/executor.ts)         │                │
 │   lease+fence run → computer lease → load context        │                │
 │   → PiAgentRuntime (pi-agent-core Agent, pi-ai models)   │                │
 │   → tool calls dispatched to adapters ──────────────┐    │                │
 │  Background handlers, job reconciler (leader lock)  │    │                │
 └──────────────────────────┬──────────────────────────┼────┘                │
                            │                          │                     │
          ┌─────────────────┼────────────┬─────────────┼───────────────┬─────┴──────────┐
          ▼                 ▼            ▼             ▼               ▼                ▼
 ┌────────────────┐ ┌─────────────┐ ┌──────────┐ ┌───────────────┐ ┌──────────┐ ┌───────────────┐
 │ SandboxProvider│ │ Connectors  │ │AutoReview│ │ SecretStore   │ │ Memory   │ │ Postgres      │
 │ docker (super- │ │ Composio,   │ │ llm |    │ │ AES-GCM in PG │ │ provider │ │ (Prisma 7)    │
 │ visor), e2b,   │ │ Pipedream   │ │ jev |    │ │ or Infisical  │ │ (Serenity│ │ events, runs, │
 │ daytona, box,  │ │ (MCP), MCP, │ │ scripted │ │               │ │ Super-   │ │ graphile_     │
 │ createos,      │ │ OpenAPI,    │ │          │ │               │ │ memory)  │ │ worker schema │
 │ railway, local │ │ GraphQL     │ │          │ │               │ │          │ │               │
 └────────────────┘ └─────────────┘ └──────────┘ └───────────────┘ └──────────┘ └───────────────┘
```

### 2.2 Corrections to the video summary

| Claim (as relayed) | What the source shows |
|---|---|
| tRPC | **oRPC 1.15** (`@orpc/server`, `@orpc/contract`); the contract lives in `packages/contracts/src/rpc.ts`. |
| "Boat.dev" sandbox | **Box** (`box-sandbox.ts`), plus Docker, E2B, Daytona, CreateOS, Railway and a trusted local computer. |
| emulate.dev local service emulators | **Not present.** No dependency or string anywhere. Rakazo uses **home-grown in-repo emulators** (`*-emulator.ts` for E2B, Daytona, Box, Composio, MCP, Stripe, Cursor, Sendblue, email, GitHub webhooks …) plus a loopback OpenAI-compatible model emulator in `packages/testkit`. |
| PRs reviewed by cron-scheduled agents | **No.** Scheduled workflows are a nightly screenshot run and a weekly PR that bumps the pinned Pi version. Reviews come from external bots (CodeRabbit, Greptile). Coding agents babysit PRs with the `.agents/skills/pr-watch` skill, which polls CI and reviews. |
| Playwright screenshot galleries | Yes. About 90 specs in `apps/web/e2e`, run by a harness (Testcontainers Postgres + emulators). A screenshot gallery is uploaded to S3 and linked on the PR; AGENTS.md requires it for UI changes. |
| Avatar studio | Thin. No avatar model in the DB: just `User.avatarStyle` / `image` and generated bot shapes and colours (`packages/core/src/bot-avatar-*`). |

---

## 3. Subsystems: interface and behaviour

### 3.1 Chat turn → run → tool calls (the runtime loop)

**Intake (API).** A user send is routed by a small decision function, the "thread target":

1. If the bot has a run `waiting_input` and nothing steerable, the text **answers the pending ask**.
2. If a conversational run is queued, leased, running or `waiting_takeover`, the text becomes a **SteeringMessage** injected into that live run.
3. Otherwise the API creates a **Task + Run** (`status=queued`, `trigger=user`) in one transaction with the message.

It then appends a thread `Event` with a per-thread `seq`, fires `pg_notify`, and enqueues the `run.continue` job keyed `run:<id>`, so duplicate enqueues collapse. Older superseded queued runs are cancelled.

**Run states:** queued → leased → running → (waiting_input | waiting_takeover) → completed | failed | cancelled.
**Triggers:** user, routine, resume, follow_up, reaction, call_end, spawn, skill, bot_message, webhook, messaging, cloud_agent, created, tickets.

**Execution (worker).**

1. **Claim:** the executor claims the run with a fenced lease (owner, monotonically increasing fence, 5-minute expiry).
2. **Computer lease:** it takes the bot's computer execution lease. If the computer is busy, the run is requeued with backoff.
3. **Attempt and heartbeat:** it creates an `Attempt` row. A heartbeat every 60 s renews both leases and aborts if either is lost.
4. **Context:** it loads bot, thread window, memory, skills, connections, secrets (decrypted, each also added to a **redaction list**) and builds the system prompt.
5. **Model:** it resolves the model (§3.2) plus an ordered list of backup models.
6. **Runtime:** it runs the Pi `Agent` with callbacks: `executeTool`, `claimSteering` (polled between turns), `onUsage`, `onModelChange`, `resolveFallbackModel`.

**Tool dispatch.** Each model tool call goes back to the executor, which dispatches by tool name:

- **Shell and file tools** go to `sandbox.execute`.
- **`computer_observe` / `computer_act`** go to `sandbox.act`, which batches up to 24 GUI actions and refuses after three no-change repeats.
- **Connector and MCP tools** go to `connector.execute`.

Every side-effecting call passes the approval gate (§3.6) and is recorded in an idempotency ledger (`ExternalEffect`, keyed by run + tool + hash of the arguments). After a crash the ledger replays completed results and never re-executes an effect that was in flight: that case is marked `uncertain`.

**Loop guards:**

- Six identical tool calls in a row stop the run.
- Each turn has a tool-call budget.
- Text emitted next to tool calls counts as narration. If tool work ends without a final answer, the runtime nudges the model up to three times.
- Subagents run as nested Agents, at most four in parallel.

**Streaming:** text deltas are batched about every 250 ms into `thread.progress` events. Final text becomes a durable message event. Clients receive both over SSE.

**Retries and fallback:** model streams get a 120 s header timeout and Pi's own retries. Retryable errors (408, 429, 5xx, quota wording) back off 2 s / 8 s / 20 s, then switch to the next backup model, but only if nothing has streamed yet. A backup never borrows the primary's credential.

**Interruption:** the executor re-checks run status and fence every second and aborts the Agent (and its children) if either changed.

**Takeover:** the `request_takeover` tool parks the run in `waiting_takeover` while the user drives the screen. Release stamps a checkpoint and resumes the run.

**Compaction:** after a run, if 100 or more uncompacted messages exist, a `history.compact` job summarises them under a compare-and-swap cursor.

**Stuck work:** a leader-elected reconciler runs every 30 s and re-enqueues lost work. Runs waiting on a human get a push reminder at 4 h and are cancelled at 24 h.

**Orphus mapping.** Almost all of the in-run loop (Agent, tools, retries, compaction, steering, subagents) already exists in `orphus --mode rpc`. OrphusBot keeps **only the durable outer loop**: Task/Run rows, leases and fences, the steering queue, the effect ledger, reminders and the reconciler. One run turn maps onto RPC commands:

| Run step | Orphus RPC mechanism |
|---|---|
| Start a turn | `prompt` |
| Barge-in | `steer` / `follow_up` |
| Stop | `abort` |
| Model and thinking level | `set_model`, `set_thinking_level` |
| Read results | `get_last_assistant_text`, plus `agent_*` / `message_*` / `tool_execution_*` events |
| Human asks | `extension_ui_request` (select / confirm / input) relayed as cards |

This is the same mapping orphus-desktop DESIGN §5.2 already defines. Reuse its **desktop-bridge extension** pattern as an **orphusbot-bridge** extension: it gates `tool_call`, captures diffs and redirects tool operations into the bot's computer (§8.3).

### 3.2 Model providers and subscriptions (via Pi)

**Interface.**

- Credentials are **per user**, not per bot: `UserModelCredential` → an encrypted `Secret` of kind `oauth` | `api_key` | `openai_compatible`.
- Bots store only an optional provider, model and thinking-level override. Runs may pin a model (routines do).
- Precedence: run pin → bot override with a matching credential → credential's preferred model → catalogue default → deployment default → environment. A per-member ordered `SpaceBackupModel` list supplies fallbacks.

**Subscription sign-in:**

| Provider | Method |
|---|---|
| `openai-codex` (ChatGPT Plus/Pro) | Pi `login()` device-code |
| `github-copilot` | Pi `login()` device-code |
| `xai` | Pi `login()` device-code |
| `anthropic` (Claude Pro/Max) | **custom PKCE paste-the-code flow that reuses Claude Code's public OAuth client id** and asks for `user:inference` and `user:sessions:claude_code` scopes |

- The browser UI starts the flow through oRPC endpoints (`beginOAuth` → `submitOAuthCode` / `completeOAuth` → `finishOAuth`).
- Login sessions live in memory for about 15 minutes, keyed by user, space and provider.
- **Refresh:** at run setup the executor refreshes under a per-secret lock if the token expires within 5 minutes. Pi refreshes mid-run through a request-scoped credential store.
- **Retirement:** terminal refresh errors (400/401/403) retire the credential. A refresh that returns a different ChatGPT account is rejected.
- **Codex catalogue:** fetched per account from the ChatGPT backend, cached for 15 minutes.
- **Local models:** a keyless `local` provider for Ollama or LM Studio at an OpenAI-compatible URL.

**Orphus mapping:**

- **ChatGPT:** Orphus RPC already exposes `login_provider` (`authType: "oauth"`), `save_provider_credential`, `cancel_login_provider` and `logout_provider`. The OAuth prompts travel as extension-UI requests (`oauth_prompt` / `oauth_select` / `oauth_manual_code`). OrphusBot relays those to whichever client Kelvin is on; tokens stay in that node's `~/.orphus` and **never reach the OrphusBot server or database**.
- **Claude:** Orphus's `@orphus/claude-bridge` drives **the official Claude Agent SDK with the existing Claude Code login**. That is a cleaner route than Rakazo's reuse of the Claude Code client id. Policy risk remains: the claude-bridge README notes that Anthropic has changed its stance on Agent SDK billing before (see Q3).
- **Backup models:** Rakazo's ordered fallback becomes a node-local Orphus setting plus an OrphusBot policy, informed by the decision layer and a quota tracker (§9.4).

### 3.3 Computers (sandbox adapter)

**Interface (`SandboxProvider`), in our words:**

| Group | Methods |
|---|---|
| Describe | `describe()` returns capabilities: graphical, pty, snapshots, takeover, persistentHome, multiScreen |
| Lifecycle | `provision(bot, home, priorRef?)` returns a `ComputerRef` early (fresh / started flags); `isRunning?`; idempotent `prepare`; `keepAlive?`, `stop`, `destroy` |
| Execution | `execute(ref, {argv, cwd, env, unsetEnv, pty, timeout})` streams stdout, stderr and exit; `inspectBackgroundWork?` |
| Screens | `connectScreen(view \| control)` returns a URL session; `connectTerminal?`, `setScreenControl?`, `releaseScreen?` |
| GUI | `sendInput` (needs a fenced control lease); `observe` returns a frame plus cursor and active window; `act(actions[])`; `pageBrowser?` drives a live Chromium tab |
| Files | `listFiles`, `readFile`, `writeFile`, `exportWorkspace`, `importWorkspace` (streams), `snapshot` |

**Providers:**

- **Docker:** an HTTP client to an in-stack supervisor that creates sibling containers from a desktop image (Xvnc + noVNC + Chromium + helper scripts).
- **Remote providers** share one Linux-desktop implementation and supply only `run`, `env` and screen URL: E2B, Daytona, Box, CreateOS, Railway.
- **Trusted local computer:** spawns processes on the host, no GUI.
- **None:** every method throws; used when no provider is configured or a key is missing.

**Lifecycle:**

- A Postgres compare-and-swap state machine: stopped / booting / running / suspended / error.
- Desktops start lazily on first graphical use.
- **Idle sleep** after 10 minutes, with a background-work probe that fails closed. The workspace is checkpointed before stop.
- Durable update and recover jobs take a maintenance reservation that blocks leases and sleep.

**Team vs Private:**

- **Team** (default): one container per workspace with folders `bots/<id>/` and `shared/`. Each active bot gets its own X display, Chrome process and profile, up to a concurrency cap.
- **Private:** the whole home belongs to one bot.

**Screens:** provider URLs are sealed with AES-GCM, bound to view or control mode, and expire after an hour. The API re-validates each one against bot and computer "generation" counters, which Postgres triggers bump on state or ref changes. User takeover is a 15-minute fenced lease.

**Doc vs code drift:** VISION.md promises a shared Team browser identity with fenced checkpointing. The code keeps **one browser profile per bot**, and "generation" only fences screen links.

**Orphus mapping:** see the Rust `ComputerProvider` design in §8. Rakazo's interface is a good checklist of capabilities, but OrphusBot's first backend is Kelvin's own machines over NetBird, with E2B second.

### 3.4 Integrations (connectors)

**Interface:**

- `ConnectorProvider { describe, discoverTools(ctx), resolveCall?, execute(call) → events }`.
- Each tool carries `{name, description, inputSchema, readOnly?, route}`. The `route` stays server-side and is never shown to the model.
- `ConnectionAuthProvider { begin, complete, revoke }` handles OAuth for apps.
- A registry fans discovery out to every provider. One failing provider doesn't hide the rest, and name collisions are renamed `<connector>.<name>`.

**Providers:**

- **Composio:** official SDK, per-user sessions.
- **Pipedream Connect:** really **remote MCP** at `remote.mcp.pipedream.net`, one endpoint per connected app.
- **Remote MCP servers:** streamable HTTP with SSE fallback; stdio only for allowlisted binaries; OAuth broker with early refresh.
- **User-installed tool sources:** OpenAPI (operations imported) and GraphQL (introspected), plus an MCP preset called "Treg".

**Safety:**

- SSRF-safe fetch (private and metadata addresses blocked), payload caps, redaction of secrets and tokens in errors and results.

**Lazy tool catalogue:** a provider with more than 20 tools is exposed as three wrapper tools (`*_search_tools`, `*_load_tool`, `*_execute_tool`) instead of every schema. The prefix deliberately avoids `mcp_`, because Claude Code OAuth rejects tools with that prefix. **Adopt this idea.**

**Orphus mapping:**

- Orphus already has `@orphus/mcp`, so integrations should reach the model **as MCP servers attached to the engine**.
- OrphusBot's server owns connection records, OAuth tokens and the allowlist, and hands each engine a scoped MCP configuration.
- Composio and Pipedream both offer MCP endpoints, so one MCP path covers all three in Rust (rmcp, §7.3).

### 3.5 Secrets

**Interface:** `SecretStore { put, load, delete, redact, onChange }`. The default is AES-256-GCM in Postgres with a deployment key; Infisical is optional. Changes are broadcast across processes.

**How bots use them:**

- `request_secret` shows a masked card bound to one HTTPS origin.
- `secret_request` makes a server-side authenticated HTTP call. The bot never sees the value.
- Command variables are exported to the bot's shell as env vars, redacted in plain, base64 and URL-encoded forms.
- Website logins are filled through `fill_secret`, only on the saved origin.

**Orphus mapping:**

- On nodes: the OS keychain (`keyring` crate) for node and service tokens.
- On the server: AES-GCM envelope encryption with the key in a file outside the database (or systemd-creds).
- Model subscription tokens stay in Orphus's own store on each node and are never centralised.

### 3.6 Decisions and approvals (where a decision model plugs in)

**Rakazo's approval pipeline:**

1. **Static classification.**
   - Some tools are always exempt (shell, files, browser, spawn, schedule).
   - Some always require approval (secret operations, delete bot, cloud agents, destination writes).
   - `create_space` can never be auto-allowed.
   - Connector tools are classified by name: mutating verbs or compound names are consequential. A declared write is always consequential, and a declared read never overrides the name check.
   - Webhook-triggered runs must ask for any side effect.
2. **User rules** match by tool, connector or category. The most specific match wins; require-approval wins ties.
3. **Gate.**
   - Rule says ask → ask. Always-allow → run.
   - Default + consequential + auto-review on → **judge**.
   - Otherwise → run. **The default is "YOLO": with no rules and auto-review off, consequential connector actions run without asking.**
4. **Judge outcome.** pass → run; ask → ask; error → ask if consequential.

**Auto-review providers:** `AutoReviewProvider.review(request) → pass | ask | error`. The request carries tool name, connector kind, redacted args, user task, bot description and matching rules.

| Provider | How it decides |
|---|---|
| `llm` | A no-tools chat call that returns JSON |
| `scripted` | Fixed answer, for tests |
| **`jev`** | `POST https://api.typesafe.ai/v1/systemone` with one `choice` question {pass: clearly fits the task and low risk; ask: unexpected, high risk or outside the task}. "pass" below `RAKAZO_AUTO_REVIEW_MIN_CONFIDENCE` (default 0.5) → **ask**. Errors → ask. Timeout 1.5 s. |

**This is the same wire protocol laya-serve speaks.** Rakazo's Jev adapter could be pointed at a self-hosted Laya by changing one URL. Its endpoint is hard-coded today.

**Other decision points:**

| Decision | Who or what decides | Seam? |
|---|---|---|
| Which model | Deterministic precedence plus backup list | No (pure function) |
| Which bot (group chat) | Mentions, else **first member by join order**; handoff is a tool the LLM calls (max 6 hops) | No |
| Spawn a child bot | The LLM calls `spawn_bot` | No |
| Reply in team chat (Slack) | `TeamChatEngagementJudge` LLM call: "silence is the default"; error → silent | **Yes** |
| Routine fires | Cron + `nextRunAt` claim | No |
| Stay silent after a routine | Model outputs a `NO_RESPONSE` token | No (prompt convention) |
| Approve a consequential action | Gate + AutoReviewProvider | **Yes** |
| Nag or cancel stuck work | Fixed 4 h / 24 h thresholds | No |

**Lesson for OrphusBot:** make these decisions **one explicit service with typed questions and receipts**, instead of scattered pure functions and prompt conventions (§9).

### 3.7 Routines, jobs and tickets (Graphile Worker)

**Routines:**

- A routine is: a list of cron strings + timezone (or `@once`), a prompt, an optional target thread and model pin, `active` / `notify`, `nextRunAt` / `lastRunAt`, and optional webhook, GitHub-event and inbound-message triggers.
- **Agent tools:** `schedule_create`, `schedule_list`, `schedule_cancel`. `schedule_create` is hidden from runs that a routine started, so routines can't spawn routines.

**Graphile tasks** (concurrency 4, 500 ms poll, job keys for dedupe):

| Task | Purpose |
|---|---|
| `run.continue` | Run an agent turn |
| `routine.wakeup` | Claim a due routine and queue its run |
| `history.compact` | Summarise long thread history |
| `messaging.deliver` | Send the messaging outbox |
| `cloud_agent.poll` | Poll a remote coding agent |
| `computer.update` / `sleep` / `control-expire` | Computer maintenance |
| `skill.teaching-expire` | End a skill-teaching session |

**`routine.wakeup` semantics:** it fires only if the routine is active and `nextRunAt` equals the scheduled time. In one transaction it claims the routine (computes the next time, deactivates one-shots) and creates a Task + Run. If enqueueing `run.continue` fails, the claim is rolled back. It then schedules the next wakeup.

**Reconciler:** a Postgres advisory-lock leader runs every 30 s. It re-enqueues lost runs and expired leases, arms routines due within 60 s, drains outboxes and handles stuck work.

**Tickets** (feature-flagged):

- One board per space. Tickets have status todo / doing / review / blocked / done / closed and priority low / normal / high / urgent, plus an assignee bot and comments.
- **Assigning a ticket to a bot wakes it** with a `tickets` run.
- Ticket references like `RAK-12` in a prompt inject a 4 KB context block, labelled as data.

**Orphus mapping:**

- Routines and tickets map directly onto OrphusBot.
- A ticket board is the natural "Kelvin's tasks" inbox, and the decision layer triages each new ticket (§9.3).
- orphus-desktop PRD §29 already plans scheduled tasks that can launch a fleet or a Goal workflow. OrphusBot routines should allow the same targets: a prompt, a fleet, or a workflow.

### 3.8 Cross-client sync

- **Single source of truth:** Postgres. Every thread event is a row with a per-thread `seq`.
- **NOTIFY is only a wake-up signal** carrying a cursor, never data.
- **Subscription:** `threads.subscribe(cursor)` is an SSE event iterator. It reads events after the cursor in batches of 200, waits on NOTIFY (or polls), sends a 20 s heartbeat and re-checks the session every 10 s.
- **Clients** keep their last `seq` and resubscribe from it, so a reconnect replays exactly what was missed. Shared reducers in `packages/core/src/events.ts` rebuild live message state on every client.

**Per client:**

| Client | Behaviour |
|---|---|
| Web | oRPC client, cookie session, no offline cache |
| Mobile | Hand-written fetch with a bearer token; SSE read by hand; polling fallback (750 ms / 1.5 s / 5 s); disk outbox for unsent messages (50 MB); secure-store session; Expo push for run-finished, needs-help and takeover |
| Desktop | Electron does **not** embed the server. Either it runs `docker compose` with a bundled image set on loopback ("This computer"), or it points at a URL ("Existing instance"). It serves the web build locally and proxies `/api`, `/rpc` and `/novnc`. |

**Auth:** Better Auth with bearer, Expo and organization plugins, plus optional OIDC SSO. A sign-up allowlist and a first-account gate.

**Orphus mapping:** the "append-only event log + cursor + wake-up signal" pattern is exactly right for OrphusBot and simple in Rust: sqlx `PgListener` plus axum SSE. Clients share one Rust reducer crate, because the UI is Leptos (§7).

### 3.9 Data model (Prisma, 1,478 lines; statuses are strings validated by zod)

| Domain | Models (key fields) |
|---|---|
| Tenancy and auth | User, Session, Account, Verification, Organization → Member → **Space** (tenancy root) → SpaceMember, Invitation, AiDataConsent, DeploymentSettings |
| Bots | **Bot** (instructions, model override, `parentBotId` / `spawnKey`, `computerId`, `memoryScope`, voice, disabled tools, team-chat rules; exactly one Thread), BotSection, BotDeletion, ChatGroup / ChatGroupMember, AgentConnection (bot-to-bot permission) |
| Conversation and runs | **Thread** (bot \| group \| external conversation; seq counters; compaction cursor), **Message** (seq, role, JSON blocks, runId, clientNonce), **Event** (thread log), **Task** → **Run** (status, trigger, model pin, lease owner / fence / expiry, checkpoint, routineId) → **Attempt**, SteeringMessage, CloudAgent |
| Computers | **Computer** (scope team \| dedicated, kind, state, control holder plus lease, `screenUrl`, home revision, generation), ComputerExecutionLease (per computer + bot, fence), ComputerUpdate, AgentHome, BrowserProfile |
| Automation | **Routine** (crons[], tz, active, notify, next/last run, triggers, model pin), Board, **Ticket** (number, status, priority, assignee bot), TicketComment, ScratchpadItem, TaughtSkill, AgentSkill |
| Integrations and secrets | Connection, CapabilityInstall, McpServer / McpOAuthSession / BotMcpServer, **Secret** (ciphertext), BotSecret, AgentSecret, IntegrationProviderConfig, Messaging* (identity, channel, link code, outbound outbox), ExternalConversation / ExternalMessage |
| Approvals | ActionApprovalRule (effect, match kind \| value), ActionAutoReviewPreference, **ExternalEffect** (idempotency key, request, result, review decision, reason, model) |
| Other | Artifact (versions via root + version), MemoryDocument / MemoryRevision / SpaceMemoryConfig, UserModelCredential / SpaceModelPreference / SpaceBackupModel, UserVoiceCredential / SpaceVoicePreference, BillingAccount, UsageRecord, NotificationPreference |

### 3.10 Verification and engineering practice

- **Deterministic offline tests by default.** Every external provider has an emulator implementation of its adapter interface.
- **Test switches:** a scripted agent runtime (`AGENT_RUNTIME=scripted`), a fake sandbox and an in-memory queue.
- **Live model evals** are opt-in, with a spend cap.
- **Screenshots:** a Playwright screenshot gallery is attached to each PR, plus a nightly run.
- **Design debt to avoid copying:** `executor.ts` is ~8,940 lines and owns almost every policy decision. Several decisions are pure functions with no seam, and VISION.md and the code disagree on browser identity.

---

## 4. Summary map: Rakazo → Orphus / orphus-desktop / OrphusBot

| Rakazo subsystem | Orphus already has | orphus-desktop reuse | OrphusBot builds |
|---|---|---|---|
| Pi Agent loop, tools, retries, compaction, subagents | `orphus --mode rpc` engine, `@orphus/subagents` | DESIGN §5 lifecycle, supervisor, park/resume | Node daemon that supervises engines; nothing in-loop |
| Steering / barge-in | RPC `steer`, `follow_up`, queue modes | §5.2 mapping | Durable steering queue on the server |
| Model selection and backups | Pi providers, `set_model`, claude-bridge | Provider settings UX | Quota-aware choice via the decision layer |
| Subscription OAuth | RPC `login_provider` + oauth extension-UI | OAuth card UX | Relay login prompts to any client |
| Approval gate | Extensions can block `tool_call` | **desktop-bridge** pattern | **orphusbot-bridge** extension → server policy + Laya |
| Auto-review (Jev) | `@orphus/systemone` (noul / choice / score; abstain; "deny, never approve"; receipts; `typesafe` adapter) | DESIGN §7 S1/S2, Decisions view, receipts | `DecisionModel` trait (Laya), shared receipt format |
| Multi-bot groups and handoff | Rooms (roundtable broker), fleets, intercom | Rooms and fleets UX | Bot ↔ role mapping; rooms as group chats |
| Computers | `BashOperations` and similar pluggable tool operations; `ssh.ts` example | Remote hosts (SSH) | `ComputerProvider`: self-hosted (NetBird) + E2B |
| Integrations | `@orphus/mcp` | MCP workbench UX | Connection store + scoped MCP config per engine |
| Routines | n/a (desktop plans scheduled tasks) | PRD §29 | Scheduler + decision gate |
| Sync and clients | n/a | Not applicable (desktop is local-first) | Event log + SSE + Leptos / Tauri |
| Verification | evals, vitest | DESIGN §12 | Fakes per trait, wiremock, Playwright screenshots |

---

## 5. OrphusBot: proposed shape

OrphusBot is **a separate product** from orphus-desktop.

- **orphus-desktop** is a local-first workbench for one person at one machine.
- **OrphusBot** is an always-on bot service with web, desktop and mobile clients, like Rakazo.

Both drive the same engine (`orphus --mode rpc`) and should share one receipt and decision format.

### 5.1 Topology

```
                          NetBird mesh (WireGuard; ACL policies; no public ports)
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │                                                                                           │
  │  Clients (one Leptos UI)                                                                  │
  │  ┌──────────────┐ ┌──────────────────┐ ┌───────────────────────┐                          │
  │  │ Browser (web)│ │ Tauri 2 desktop  │ │ Tauri 2 mobile        │  ── HTTPS + SSE ──┐      │
  │  └──────────────┘ └──────────────────┘ └───────────────────────┘                   │      │
  │                                                                                     ▼      │
  │  ┌──────────────────────────────────────────────────────────────────────────────────────┐ │
  │  │ orphusbot-server (Rust; axum)          on the always-on box (GPU box or a VPS peer)   │ │
  │  │  api: typed RPC + SSE event stream     auth: passkeys + device tokens                 │ │
  │  │  core: tasks/runs/leases/fences, steering queue, effect ledger, approvals, tickets     │ │
  │  │  scheduler: routines (croner) → job queue (graphile_worker-rs on Postgres)             │ │
  │  │  decisions: DecisionModel (Laya: ort in-process │ laya-serve HTTP)  → receipts         │ │
  │  │  connections: OAuth store, MCP config issuer (rmcp client for discovery)               │ │
  │  │  computers: placement + lifecycle; E2B backend (reqwest + connectrpc)                  │ │
  │  │  Postgres (sqlx)                                                                       │ │
  │  └───────────────┬────────────────────────────────────────────────────┬─────────────────┘ │
  │                  │ node protocol (WebSocket/gRPC over NetBird, mTLS)   │ HTTPS (E2B API)   │
  │                  ▼                                                     ▼                   │
  │  ┌─────────────────────────────────────────┐   ┌─────────────────────────────────────────┐│
  │  │ orphusbot-node (Rust) on laptop/GPU box │   │ E2B cloud (Firecracker microVMs)        ││
  │  │  engine supervisor: orphus --mode rpc   │   │  overflow, offline nodes, untrusted     ││
  │  │   + orphusbot-bridge extension (TS)     │   │  or throwaway work                      ││
  │  │  computer manager: rootless Podman/     │   └─────────────────────────────────────────┘│
  │  │   Docker per bot, Xvnc+noVNC desktop    │                                              │
  │  │  exec/file agent, screen proxy          │                                              │
  │  │  subscription creds stay here (~/.orphus│                                              │
  │  │   + Claude Code login)                  │                                              │
  │  └─────────────────────────────────────────┘                                              │
  └──────────────────────────────────────────────────────────────────────────────────────────┘
```

**Key choice: the engine runs on the node, outside the computer.**

- `orphus --mode rpc` runs on the host under orphusbot-node, where the subscriptions are logged in.
- The **orphusbot-bridge** extension swaps Orphus's pluggable tool operations (bash, read, write, edit, find …) for calls to the node daemon over a unix socket. The daemon executes them in the bot's computer: a local container or an E2B sandbox.
- Result: model credentials **never enter a sandbox**. This matches Rakazo's property that tokens stay in the worker and only tool execution is remote. It is also what makes E2B safe to use with subscription-backed engines.

### 5.2 One run, end to end

1. **Intake.** Kelvin sends a message, or a ticket, routine or webhook arrives. The server writes Message + Task + Run (queued) and an Event, then signals NOTIFY.
2. **Triage (System 1).** The decision layer answers one batched Laya call (§9.3): which bot, which provider class, urgency, act-now vs ask, local vs E2B. Low-confidence answers fall through to defaults or to asking Kelvin.
3. **Placement.** The server picks a node (heartbeat, load, subscription quota) or E2B. It leases the run (fence) and the computer.
4. **Execute (System 2).** The node spawns or resumes the bot's engine session (`--session <file>`) and sends `prompt`. Events stream back to the node, then to the server, which appends them to the log and fans out over SSE.
5. **Tool gate.** On `tool_call`, the bridge asks the server. The server applies static rules, user rules and Laya `needs_approval`. If the answer is ask, an approval card goes to every client and the effect is recorded in the ledger.
6. **Finish.** The run completes and the result is posted. A receipt and outcome label feed calibration. Push notifications fire for finished / needs-you / takeover.

---

## 6. Where Rust can't (yet) sensibly be used: keep these behind process boundaries

| Component | Language | Boundary | Why not Rust (yet) |
|---|---|---|---|
| Orphus engine (`orphus --mode rpc`) incl. Pi (`@earendil-works/pi-ai` / `pi-agent-core`), tools, compaction, subagents, rooms and fleets, `@orphus/systemone` | TypeScript (Bun/Node). Only `crates/atomic-natives` is Rust (napi) | stdio JSONL RPC, one process per session; node daemon is the parent | It's the harness itself. Porting Pi means chasing every provider's wire format and OAuth quirks. orphus-desktop's constraint #1 applies: never import pi directly. |
| Subscription auth (ChatGPT/Codex OAuth via Pi; Claude via claude-bridge + Claude Agent SDK + Claude Code login) | TypeScript, plus the Claude Code CLI | Same RPC: `login_provider`, oauth extension-UI | No supported Rust path. Reimplementing these flows is fragile and, for Claude, a policy risk. |
| orphusbot-bridge extension | TypeScript (tiny) | Inside the engine; talks to the node daemon over a unix socket | Orphus extensions are TS modules. Keep it under ~300 lines, with all policy in Rust. |
| Laya training, calibration fitting, ONNX export | Python (`laya-train`, `scripts/export_onnx.py`, `laya.calibrate`) | Offline batch jobs on the GPU box; artifacts are `laya.onnx` + config | Training stays in PyTorch. **Inference** is Rust (§9). |
| laya-serve (fallback backend) | Python / FastAPI | HTTP `/v1/systemone` over NetBird | Existing service; useful from day one. |
| noVNC viewer, xterm-style terminal, possibly markdown / mermaid rendering | JS libraries inside the Leptos UI | wasm-bindgen interop islands | Mature JS, no Rust equivalent worth the effort. |
| Playwright screenshot e2e | TypeScript, test-only | CI only | Best screenshot tooling. `fantoccini` is an option later. |

---

## 7. Rust stack

### 7.1 TypeScript piece → Rust equivalent

| Rakazo (TypeScript) | OrphusBot (Rust) | Crate (version, licence) | Notes |
|---|---|---|---|
| Hono HTTP server | **axum** | `axum` 0.8.9 MIT; `tower-http` | — |
| oRPC typed contract + event iterator (SSE) | **Shared `orphusbot-proto` crate** (serde types + a procedure enum), JSON over HTTP, SSE for streams | `axum::response::sse`; `utoipa` 6.0 (MIT/Apache) for OpenAPI; `ts-rs` 12 MIT only if a JS island needs types | With a Rust (Leptos) UI the client imports the same crate, so there's no codegen. `rspc` 0.4.1 exists but releases are slow; not recommended. |
| Prisma 7 | **sqlx** (compile-checked SQL + migrations) | `sqlx` 0.9.0 MIT/Apache | The schema is lease, fence and CAS-heavy; hand-written SQL fits better than an ORM. `sea-orm` 2.0.4 is the alternative. |
| Graphile Worker 0.17 | **graphile_worker (Rust port)**: job keys, run_at, retries, named queues, crontab | `graphile_worker` 0.14.1 MIT | Keeps Rakazo's job-key dedupe semantics (`run:<id>`, `routine:<id>`). Alternative: `apalis` 1.0 + `apalis-postgres` 1.0 (MIT on GitHub; crate metadata says "non-standard") + apalis-cron. `underway` 0.2 has been stale since 2025-07. |
| pg_notify fan-out | `sqlx::postgres::PgListener` | sqlx | Same "signal only, DB is truth" pattern. |
| croner (cron) | **croner** (Rust) + timezones | `croner` 4.0.1 MIT; `chrono-tz` 0.10 | Supports `@once`-style one-shots via `run_at` jobs. |
| Better Auth | **axum-login + tower-sessions + passkeys**, plus long-lived device tokens for mobile | `axum-login` 0.18 MIT; `tower-sessions` 0.15 MIT; `webauthn-rs` 0.5.5 MPL-2.0; `oauth2` 5.0 | Single user. NetBird is the network boundary, so passkey + device token is enough. Watch `better-auth` 0.10 (a Rust port), which is too young to bet on. |
| Electron | **Tauri 2** | `tauri` 2.12.4 MIT/Apache; `tauri-plugin-deep-link` 2.6; updater, notification and stronghold plugins | — |
| Expo (React Native) | **Tauri 2 mobile** (iOS / Android) | tauri 2 | Push needs APNs/FCM through a plugin, **or** ntfy (self-hosted over NetBird) for Android and Linux (Q6). |
| React 19 web | **Leptos 0.8 (CSR)**, one UI for web, desktop and mobile | `leptos` 0.8.22 MIT | See §7.2. Alternative: Dioxus 0.7.10. |
| Electron-embedded docker-compose "This computer" | Not needed: nodes run `orphusbot-node` (systemd user unit) | — | — |
| Docker supervisor (sibling containers) | **orphusbot-node** computer manager | `bollard` 0.21.1 Apache-2.0 (Docker *and* Podman's Docker-compatible socket); `podman-api` 0.11 MIT | — |
| noVNC screen proxy + sealed URLs | axum WebSocket proxy on the node; tokens sealed with AES-GCM | `tokio-tungstenite` 0.30 MIT; `aes-gcm` 0.11 | noVNC JS in the client. |
| SecretStore (AES-GCM / Infisical) | Envelope AES-GCM on the server; OS keychain on nodes | `aes-gcm`; `keyring` 4.2 MIT/Apache | — |
| `@modelcontextprotocol/sdk` | **rmcp** (official Rust MCP SDK) | `rmcp` 3.5.1 Apache-2.0 | Server-side discovery, health checks, and serving OrphusBot's own MCP tools to engines. |
| `@composio/core` | Composio **MCP endpoint via rmcp**, plus a thin `reqwest` client for connect links | `composio-sdk` 0.3.0 (community, 87 downloads): don't depend on it | — |
| Pipedream Connect | Remote MCP (`remote.mcp.pipedream.net`) via rmcp, plus a thin `reqwest` client for Connect tokens | **No crate** | — |
| `@e2b/desktop` SDK | **Thin client:** `reqwest` for the control-plane REST API (create, pause, resume, kill, timeout) and `connectrpc` for the in-sandbox `envd` (process, filesystem) | `e2b-sdk` 0.1.1 (community, stale since 2025-02): don't depend on it; `connectrpc` 0.9.1 Apache-2.0 | Verify envd's current API surface before building (Q8). |
| `@daytona/sdk` | Later: the official `daytona` crate (0.1.0-alpha, Apache-2.0) or `daytona-client` 0.5 | — | Not designed now. |
| Jev auto-review (HTTP) | **`DecisionModel` trait**: `ort` + `tokenizers` in-process, with a laya-serve HTTP fallback | `ort` 2.0.0-rc.14 MIT/Apache; `tokenizers` 0.23.2 Apache-2.0 | §9. |
| Model emulator, provider emulators | Fake implementations of every trait, plus `wiremock` for HTTP providers, plus a scripted fake engine speaking the RPC protocol | `wiremock` 0.6.5 | — |
| JSON schema validation (tool schemas, Laya `decide` subset) | `jsonschema` 0.58 MIT | — | — |
| Chat SDK messaging (Slack, Telegram …) | **Skip for v1.** Later: `teloxide` (Telegram) or Slack via HTTP | — | — |

### 7.2 UI: web stack in Tauri, or Leptos / Dioxus?

**Recommendation: Leptos (client-side rendered), one UI crate shipped to the browser (served by axum) and inside Tauri 2 desktop and mobile.**

- **One language end to end.** The protocol, event reducers and validation are shared Rust crates on server and client. Rakazo needs `packages/core` reducers plus a hand-written mobile client because RN and web diverge; we avoid that.
- **Tauri provides the platform glue** Dioxus would make us rebuild: updater, deep links, notifications, a secure store, biometrics and the mobile build pipeline. Leptos-in-Tauri is a standard template.
- **JS where JS is clearly better**, as interop islands: noVNC (computer view), xterm.js (takeover terminal), a markdown and code renderer.

**Alternative: Dioxus 0.7.** Pick it if Kelvin would rather have one framework covering web, desktop and mobile without Tauri. It is also webview-based on desktop and mobile. Trade-off: fewer platform plugins, and a smaller set of web-first component libraries.

**Not recommended: a React/TS UI inside Tauri.** It works and is fastest to build, but it splits the codebase into two languages and contradicts "Rust as the main language".

### 7.3 Crate availability for providers

| Provider | Rust crate? | Plan |
|---|---|---|
| MCP | **Yes:** `rmcp` 3.5.1 (official, ~36 M downloads) | Use. |
| E2B | Only community `e2b-sdk` 0.1.1 (stale) | **Thin HTTP + Connect-RPC client** (~500–800 lines) behind `ComputerProvider`. |
| Daytona | Official `daytona` 0.1.0-alpha; community `daytona-client` 0.5 | Later. |
| Composio | Community `composio-sdk` 0.3 (tiny) | Use its MCP endpoint via rmcp, plus a thin REST client. |
| Pipedream | None | Remote MCP via rmcp, plus a thin REST client for Connect tokens. |
| Docker / Podman | `bollard` 0.21 (mature), `podman-api` 0.11 | `bollard` against the rootless Podman or Docker socket. |
| Anthropic / OpenAI | `async-openai` 0.42, `genai` 0.6, `rig-core` 0.44 exist (API keys only) | **Don't use for bot work** (subscriptions go through Orphus). Possibly for small server-side utilities on API keys, e.g. summarising receipts. Not needed for v1. |

---

## 8. Computers: Rust `ComputerProvider` design

### 8.1 Trait (our design; general enough for Daytona and others later)

```rust
// orphusbot-computer crate (server and node both depend on it)
#[async_trait]
pub trait ComputerProvider: Send + Sync {
    fn describe(&self) -> ProviderInfo;                 // id, Capabilities { gui, pty, snapshots, takeover,
                                                        //   persistent_home, pause_resume, max_concurrency }
    async fn availability(&self) -> Availability;       // Online{load, free_slots} | Busy | Offline   (feeds placement)

    async fn provision(&self, spec: &ComputerSpec, prior: Option<&ComputerRef>) -> Result<Provisioned>;
        // spec: bot_id, scope (Team{team_id} | Private), image, resources, network policy, ttl
        // returns ComputerRef early; Provisioned { r#ref, fresh: bool, resumed: bool }
    async fn status(&self, r: &ComputerRef) -> Result<ComputerState>;   // Booting|Running|Paused|Stopped|Gone
    async fn pause(&self, r: &ComputerRef) -> Result<()>;               // idle sleep (checkpoint first)
    async fn destroy(&self, r: &ComputerRef) -> Result<()>;

    async fn exec(&self, r: &ComputerRef, cmd: ExecRequest) -> Result<ExecStream>; // argv|shell, cwd, env, pty, timeout
    async fn read_file(&self, r: &ComputerRef, path: &Path, max: u64) -> Result<Bytes>;
    async fn write_file(&self, r: &ComputerRef, path: &Path, data: Bytes) -> Result<()>;
    async fn list(&self, r: &ComputerRef, path: &Path) -> Result<Vec<DirEntry>>;
    async fn export_home(&self, r: &ComputerRef) -> Result<ArchiveStream>;  // portability across providers
    async fn import_home(&self, r: &ComputerRef, a: ArchiveStream) -> Result<()>;

    // optional GUI surface (Capabilities.gui)
    async fn screen(&self, r: &ComputerRef, mode: ScreenMode) -> Result<ScreenSession>; // View|Control{lease}
    async fn observe(&self, r: &ComputerRef) -> Result<Frame>;
    async fn act(&self, r: &ComputerRef, actions: Vec<GuiAction>, lease: &ControlLease) -> Result<ActOutcome>;
}
```

- **Placement** is a separate server component, `Placer::choose(task, decision, providers) → ProviderId`. Providers don't decide where they run.
- Server state follows Rakazo's useful parts: a CAS state machine on the `computer` row, fenced execution leases per (computer, bot), idle-sleep jobs, sealed screen tokens, and an effect ledger.

### 8.2 Backend 1 (primary): self-hosted nodes over NetBird

**Machines:** the Omarchy laptop and the GPU box, already on Kelvin's NetBird mesh.

**orphusbot-node** is a single static Rust binary run as a systemd user service:

| Module | Job |
|---|---|
| `link` | One outbound, persistent WebSocket (or gRPC stream) to orphusbot-server over the NetBird IP. Mutual auth: a node keypair enrolled once (server-issued cert or a pinned key), plus NetBird ACLs that allow only server ↔ node on that port. **The node listens on nothing public.** For screen streams it binds only to its NetBird interface address. Heartbeats carry load, free slots and engine and computer inventory. |
| `engines` | Supervises `orphus --mode rpc --session <file> -e <orphusbot-bridge>` per active bot session (restart with backoff, park when idle, resume on demand: the orphus-desktop DESIGN §5.1 rules). Relays RPC events up and commands down. Owns the unix socket the bridge extension calls for tool operations and gate decisions. |
| `computers` | Implements `ComputerProvider` over rootless Podman (or Docker, already installed on the laptop) through `bollard`. |
| `screens` | WebSocket proxy from sealed, short-lived tokens to the container's VNC socket. |
| `creds` | Never sends subscription tokens anywhere. Reports only "provider X logged in / expired" to the server. Login flows run through the engine's RPC and are relayed. |

**Isolation tiers (start simple):**

| Tier | What | When |
|---|---|---|
| **T1 (default)** | Rootless Podman/Docker container per bot. Seccomp default profile. No host mounts except the bot's home volume (Private) or the home volume plus a `shared` volume (Team). Egress allowed; LAN and NetBird ranges blocked by default (nftables in the container network). CPU and memory limits. | Kelvin's own trusted work |
| **T2** | Same image run under **gVisor (`runsc`)** as the OCI runtime | Semi-trusted content, e.g. browsing arbitrary sites with logins |
| **T3** | Firecracker microVMs on the GPU box (needs KVM and a rootfs pipeline) | **Defer.** E2B already provides Firecracker isolation for untrusted work, so local microVMs aren't needed in v1. |

**Desktop image:**

- Debian slim, Xvnc (TigerVNC) or Xvfb + x11vnc, a light WM, Chromium, and a small in-container helper for screenshots and input (xdotool / xdg tools). VNC is exposed only on a socket the node proxies.
- The client renders **noVNC** in a view-only or control mode.
- **Later:** a WebRTC stream (Selkies-style) if latency matters.

**Team vs Private computers.** Rakazo puts several bots in one container with separate displays. **We recommend one container per bot instead:**

- **Team** bots additionally mount a shared volume, plus a shared browser-profile *template* that is copied in at start (not live-shared: avoids Chromium profile corruption, the problem Rakazo's docs gesture at but the code sidesteps).
- **Private** bots mount nothing shared.
- Containers are cheap, so this removes multi-display bookkeeping and gives a real boundary between Team bots.

**GPU access:** pass the GPU through (CDI / `--device nvidia.com/gpu=all`) only for bots whose spec asks for it, and only on the GPU box.

### 8.3 Backend 2: E2B

**Used when:**

- the nodes are offline or saturated;
- the task needs a throwaway environment;
- the decision layer flags the work as untrusted (unknown repos, attachments, arbitrary web).

**Implementation:** a server-side `E2bProvider` behind the same trait.

- The control plane is plain REST: create from a template, pause, resume, set timeout, kill.
- Exec and filesystem go to the sandbox's `envd` over Connect-RPC.
- GUI uses the E2B desktop template's VNC stream.

**The engine still runs on a node.** The bridge redirects tool operations to the node, and the node forwards them to the server's E2B client. Tokens never enter E2B. If *both* nodes are offline, there's no engine host. Option: a server-hosted engine pool, if the server box has subscription logins. See Q2.

### 8.4 Placement policy (Laya-informed, deterministic last word)

```
inputs: decision.sandbox ∈ {local, e2b} (+ answer_confidence), decision.untrusted (noul),
        node availability, bot.preferred_node, task needs (gpu, gui, home continuity)
rule order:
  1. untrusted ≥ θ_untrusted                    → E2B (throwaway)
  2. needs GPU                                  → GPU box (queue if busy; never E2B)
  3. bot has a live Private home on node N      → N if online (continuity), else export/import home → other node
  4. some node online with free slots           → least-loaded node (laptop only if on AC power & not "focus mode")
  5. otherwise                                  → E2B overflow (if task allows remote), else queue
```

---

## 9. Decision layer: Laya ("Jev" family) as System 1

### 9.1 Laya's contract (from its README, docs and `laya-go`)

**Request** (the same shape as TypeSafe's `/v1/systemone` and Orphus `@orphus/systemone`):

```json
{ "model": "english|multilingual|typed-decisions|<extra>",
  "state": <any JSON: string | object | list (list = conversation, end is kept on truncation)>,
  "questions": {
    "<name>": { "type": "choice", "instructions": "...", "criteria": { "<label>": "<description>", ... } },
    "<name>": { "type": "score",  "instructions": "...", "criteria": [ "<level0 desc>", "<level1 desc>", ... ] },
    "<name>": { "type": "noul",   "instructions": "...", "criteria": { "false": "...", "true": "..." }, "labels"?: {...} } },
  "min_confidence"?: number | { "choice:3-5": 0.9, "noul:2": 0.95, "default": 0.85 } }
```

**Response:** `answers.<name>`:

| Field | Meaning |
|---|---|
| `type` | choice, score or noul |
| `choice` / `score` / `noul` | The answer. `score` is the expected level; `noul` is P(true). |
| `probabilities` | Per option, keyed in the caller's order |
| `confidence` | Normalised entropy for choice and score; max(p, 1−p) for noul |
| `answer_confidence` | max(p): the calibrated quantity to gate on |
| `low_confidence`, `abstention`, `abstention_threshold` | Present only when `min_confidence` was sent |

The response also has a `usage` block: input tokens, output tokens (always 0), and a truncation report.

**Schema mode:** `decide(state, json_schema)` turns enum → choice, bounded integer → score, boolean → noul (≥ 0.5). With `return_details`, it returns per-field `answer_confidence`.

**Limits:**

- Options share a 192–256-token head budget, trimmed beyond roughly 20 options. The server caps at 100 options.
- Every score level needs a description.
- Option position biases the answer; average it out with `option_order` rotations.
- The shipped checkpoints are **over-confident**, and the multilingual one has no fitted temperatures. **Calibrate before trusting any threshold.**

**Confidence formulas:**

- `laya.jev_confidence(answer)` reproduces TypeSafe's formula: choice `(max p − 1/n)/(1 − 1/n)`; score is an ordinal spread measure; noul returns `None`.
- Orphus `@orphus/systemone` uses the same `(max p − 1/n)/(1 − 1/n)` formula, with `|2p − 1|` for noul.
- **Policy:** gate on per-bucket fitted `answer_confidence` (Laya's recommendation; buckets = type × option band). **Also record `jev_confidence`** (with `|2p − 1|` for noul) in every receipt, so OrphusBot, Orphus's systemone receipts and orphus-desktop's Decisions view compare on one scale.

**HTTP:** `POST /v1/systemone` and `POST /v1/systemone/batch` (≤ 64 states), optional bearer `LAYA_API_KEY`. Hooks are refused over HTTP.

**ONNX graph (fused `laya.onnx` + `.data` sidecar), from `laya-go/onnx` and `infer`:**

- **Inputs:** `input_ids` int64 [rows, seq], `attention_mask` int64 [rows, seq], `marker_pos` int64 [rows, markers], `marker_mask` bool [rows, markers], `qtype` int64 [rows].
- **Outputs:** `logits` f32 [rows, markers], `act_logits` f32 [rows, 2].
- One row per (state, question). Markers ≥ 2.
- **Sequence layout:** `[CLS] <type> question: <instructions> [SEP] [MASK] opt0 [MASK] opt1 … [SEP] state [SEP]`. Each option's `[MASK]` position is its marker.
- **Budgets:** options are capped at 48 tokens each and shrink when the head is short. The instruction gets at least 8 tokens. The state takes what's left. Mask text in user content is neutralised.
- **Outside the graph** (must be ported): tokenisation (HF `tokenizer.json`), sequence building and windowing, collation, and decoding of logits → probabilities with per-type temperatures, `temperature_by_options` and binning from `rl_agent_config.json`.
- **The checkpoints on Hugging Face are safetensors only.** The ONNX file is produced once with `scripts/export_onnx.py --model convaiinnovations/laya --output laya.onnx [--quantize]` (Python, offline).

### 9.2 Rust trait and backends

```rust
// orphusbot-decide crate
pub enum Question {
    Choice { instructions: String, options: IndexMap<String, String> },
    Score  { instructions: String, levels: Vec<String> },
    Noul   { instructions: String, if_false: String, if_true: String },
}
pub struct Answer {
    pub value: AnswerValue,                 // Choice(String) | Score(f32) | Noul(f32)
    pub probabilities: Vec<(String, f32)>,
    pub answer_confidence: f32,             // max(p) after calibration — the gate input
    pub jev_confidence: Option<f32>,        // for cross-system receipts
    pub abstained: bool,                    // below the per-bucket threshold → caller must take the S2/ask path
}
#[async_trait]
pub trait DecisionModel: Send + Sync {
    fn id(&self) -> &str;                   // "laya-ort:english@<sha>", "laya-http:gpu-box"
    async fn ask(&self, state: &serde_json::Value, qs: &IndexMap<String, Question>,
                 gate: &Thresholds) -> Result<Decision>;          // Decision { answers, usage, latency, model_id }
    async fn ask_batch(&self, states: &[serde_json::Value], qs: &IndexMap<String, Question>,
                       gate: &Thresholds) -> Result<Vec<Decision>>;
}
// Wrappers (decorators), all implementing DecisionModel:
//   Fallback(primary, secondary)   — ort fails/unloaded → HTTP; HTTP down → NullModel (always abstains)
//   Receipts(inner, sink)          — writes every decision (incl. abstentions) to Postgres + JSONL
//   Rotated(inner, k)              — option_order rotations to cancel position bias on high-stakes choices
//   NullModel                      — always abstains (the safe default; mirrors Orphus systemone `null`)
```

| Backend | How | Status |
|---|---|---|
| **`OrtLaya` (target primary)** | In-process `ort` session on the fused graph. `tokenizers` loads `tokenizer.json` directly (simpler than laya-go, which wrote its own BPE). Ports of laya-go's `sequence`, `collate` and `decode` (Apache-2.0, with NOTICE). CPU execution provider on the server; CUDA EP if the server is the GPU box. **Parity tests** against Laya's committed golden fixtures (`laya-java/fixtures`, `laya-go/fixtures`) gate every release. | Build in phase 2 |
| **`HttpLaya` (start here)** | `reqwest` to laya-serve on the GPU box over NetBird (`LAYA_PRELOAD=1`, `LAYA_API_KEY`). Same wire as Jev. | Day one |

**Start with `HttpLaya`.**

- It works today with no porting.
- Laya runs where the GPU is.
- The *same* endpoint can serve Orphus's own `@orphus/systemone` (its `typesafe` adapter is a thin client for the identical wire), so the harness and OrphusBot share one System 1 from the start.

**Make `OrtLaya` primary once parity tests pass.** That removes the Python service from the critical path, gives single-digit-millisecond batching in-process, and lets the server decide while the GPU box is asleep. ModernBERT-large is ~395 M parameters, so expect a ~1.6 GB fp32 / ~0.4 GB INT8 ONNX file. **CPU latency on the laptop and server must be measured** (the 33 ms figure is T4 GPU).

### 9.3 The decisions to make (System 1 asks; System 2 works)

One triage call per new task batches all questions into a single forward pass (state = task text + source + recent context + bot roster summary):

| Decision | Question shape | Default when abstaining | Who acts on it |
|---|---|---|---|
| **Which bot / role takes it** | `choice` over the bot roster (each option = bot name + one-line remit); > 20 bots → shortlist first | Kelvin's "inbox" bot, or ask | Dispatcher |
| **Solo vs fleet vs Goal workflow** | `choice {single, fleet:<name>, goal}` | single | Dispatcher → Orphus RPC / workflow |
| **Provider / subscription class** | `choice {claude, openai, local}` (descriptions: strengths, e.g. "long refactors / careful prose" vs "fast coding / tool-heavy") | bot's configured provider | **Quota tracker overrides** if that subscription is rate-limited (429 / usage-limit seen) |
| **Thinking effort** | `score [low, medium, high]` | bot default | Engine `set_thinking_level` |
| **Urgency / priority** | `score [whenever, today, within the hour, now]` | today | Queue priority, notify policy |
| **Act now vs ask Kelvin** | `noul` "Can this be done without Kelvin's input, consistent with standing instructions?" | **ask** | Dispatcher |
| **Untrusted content** | `noul` "Does this involve untrusted code, attachments or arbitrary websites?" | true (→ E2B) | Placer |
| **Local vs E2B** | derived from the two above plus availability (§8.4) | local | Placer |
| **Tool-call approval** (per consequential call, in the bridge gate) | `choice {pass, ask}` with state = task + bot remit + tool + redacted args + matching rules (Rakazo's Jev shape) | ask | Bridge gate |
| **Routine pre-flight** ("should this fire now?") | `noul` over the routine prompt + a cheap delta (new mail count, calendar, repo activity) | fire | Scheduler: skipping no-op runs **saves subscription quota** |
| **Interrupt Kelvin?** (notify now vs batch into a digest) | `noul` + urgency | digest | Notifier, ADHD-friendly gentle nudges |
| **Team-chat engagement** (later, if Slack is added) | `noul` "Should the bot speak?" | silent | Messaging bridge |

**Thresholds:**

- Per decision and per bucket, fitted from Kelvin's own labelled history.
- **Start strict:** "act now" requires `answer_confidence ≥ 0.95`, and every other gate falls back to its default until fitted.
- Expose the thresholds in settings with plain-language explanations (as in orphus-desktop O-SYS-02).

**Safety rule (adapted from `@orphus/systemone`):** System 1 **may escalate, defer, deny or route; it may only *approve* inside a whitelisted reversible class.** Examples of that class: read-only connector calls, edits inside the bot's own workspace, drafts rather than sends. Irreversible or external effects (send, pay, delete, merge, publish) require a user rule or a human approval, whatever Laya says. This is stricter than Rakazo, where "pass" above 0.5 auto-runs. See Q5.

**Receipts:**

- Every decision, abstentions included, is stored with state hash, questions, probabilities, both confidence measures, threshold, model id and latency.
- The record links to the run it shaped and to the eventual **outcome label**: Kelvin overrode it, approved it, or the task succeeded or failed.
- Use the same JSONL shape as Orphus systemone receipts so orphus-desktop's Decisions view can read them.

### 9.4 Fine-tuning on Kelvin's decisions: worth planning? **Yes, but phase it.**

| Phase | When | What |
|---|---|---|
| **0** | Day one | Zero-shot Laya + strict thresholds + receipts. Every approval card, override and reassignment Kelvin makes is a free label. |
| **1** | ~200–500 labels per question | **Calibration only:** fit temperatures and per-bucket abstention thresholds (`laya.calibrate.fit_abstention_thresholds`). This alone makes "act now" usable, and costs minutes on the GPU box. |
| **2** | ~1–2 k labels per question, or where calibration plateaus | `laya-train` fine-tune of the English checkpoint (full fine-tune fits one T4-class GPU; `--freeze-encoder` for a cheap first try) → re-export ONNX → parity and eval on held-out data → **explicit human apply**, with rollback to the previous checkpoint. Same loop as Orphus's distillation design. |

**Data hygiene:**

- Labels come only from outcome-verified decisions.
- Hold out a time-sliced eval set.
- Never train on receipts from untrusted content without review.
- The fine-tuned checkpoint is Kelvin's private model: keep it off public hubs.

---

## 10. Data model for OrphusBot (sqlx / Postgres, single-tenant)

Drop Rakazo's Organization/Space/Billing tenancy. Keep the useful core:

| Table | Notes |
|---|---|
| `device`, `passkey`, `session` | Single owner (Kelvin). Device tokens for mobile. |
| `node` | id, name, NetBird IP, pubkey, capabilities (gpu, gui), last heartbeat, load, logged-in providers (status only) |
| `bot` | name, remit / instructions, orphus role (`--name`), default provider / model / thinking, computer scope (team / private), preferred node, disabled tools, notify prefs |
| `engine_session` | bot ↔ node ↔ Orphus session file path, state (live / parked) |
| `thread`, `message`, `event` | Per-thread `seq`; event log is the sync source |
| `task`, `run`, `attempt`, `steering_message` | Run: status, trigger, decision_id, provider / model pin, lease owner / fence / expiry, checkpoint |
| `computer`, `computer_lease` | provider (node:<id> \| e2b), ref, state (CAS), scope, generation, control lease |
| `routine` | crons[], tz, one-shot `run_at`, target (prompt \| fleet \| workflow), preflight question, active, next / last |
| `ticket`, `ticket_comment` | Kelvin's task inbox; assignment wakes the bot |
| `connection`, `mcp_server`, `bot_mcp_grant` | Integration records; OAuth material encrypted |
| `secret` | Envelope-encrypted (never model subscriptions) |
| `approval_rule`, `external_effect` | Rule matching + idempotency ledger (intended / approved / denied / executing / completed / uncertain) |
| `decision`, `decision_label`, `decision_model` | Receipts, outcome labels, registered checkpoints and thresholds (versioned; apply / rollback) |
| `artifact` | Versioned outputs |
| Job tables | Owned by graphile_worker-rs (its own schema) |

---

## 11. Reuse, build, skip

### Reuse as-is

| What | Notes |
|---|---|
| **Orphus engine** (`orphus --mode rpc`), its providers (Pi), `claude-bridge`, `@orphus/mcp`, subagents, rooms, fleets, workflows, `@orphus/systemone` | — |
| **orphus-desktop docs** | DESIGN §5 (engine lifecycle, RPC mapping, bridge-extension pattern), §7 (S1/S2 receipts and UX), CLEANROOM.md habits |
| **Laya** | Checkpoints, laya-serve (phase 1), `laya-train` / calibrate / export scripts (offline), golden fixtures for parity |
| **E2B** | The service, via our thin client |
| **NetBird** | Network boundary and ACLs; its mobile clients reach the server from the phone |
| **Rust crates in §7.1** | axum, sqlx, graphile_worker, croner, axum-login, webauthn-rs, tauri, leptos, bollard, rmcp, ort, tokenizers, reqwest, connectrpc, wiremock |
| **Test-only tools** | Playwright (TS) for screenshot e2e |
| **emulate.dev** | Rakazo doesn't actually use it. If Kelvin wants hosted emulators, evaluate separately (Q9). Otherwise follow Rakazo's real pattern: a fake per trait plus wiremock. |

### Build

1. **orphusbot-proto** (shared types, events, reducers).
2. **orphusbot-server:**
   - API and SSE
   - durable run loop (leases, fences, steering, ledger, reconciler)
   - scheduler
   - placement
   - E2B client
   - connection store and MCP config issuer
   - auth
3. **orphusbot-node:** link, engine supervisor, Podman computers, screen proxy, bridge socket.
4. **orphusbot-bridge** (a small TS Orphus extension): tool-operation redirect, `tool_call` gate, diff capture.
5. **orphusbot-decide:** `DecisionModel`, HttpLaya, then OrtLaya with parity tests, receipts, calibration tooling glue.
6. **orphusbot-ui** (Leptos) + Tauri desktop and mobile shells.
7. Desktop container image (Xvnc + noVNC + Chromium + helper).

### Skip (v1)

| Skip | Why |
|---|---|
| Multi-tenant organisations / spaces, billing, sign-up policy | Single user |
| Messaging surfaces (Slack, Telegram, WhatsApp, iMessage) and the team-chat judge | Revisit after v1 |
| Avatar studio; voice calls | Voice later; Orphus `@orphus/transcribe` exists for dictation |
| Composio *and* Pipedream both | Start with plain MCP servers + one aggregator (Q7) |
| Cursor cloud agents | Orphus fleets cover this |
| Daytona, Box, CreateOS, Railway; local Firecracker | Not needed in v1 |
| Rakazo's in-loop machinery | The engine owns it |
| Infisical | — |

---

## 12. Suggested milestones

| Milestone | Scope | Exit |
|---|---|---|
| **M0** | proto + server skeleton (axum, sqlx, events, SSE) + node link + one engine over RPC on the laptop | A message from the browser streams a reply from `orphus --mode rpc` on the laptop over NetBird |
| **M1** | Runs: leases, fences, steering, reconciler; bridge gate with static rules; approval cards; Tauri desktop shell | Approve a write from the desktop app; kill the node mid-run and it recovers |
| **M2** | Podman computers + tool redirect + noVNC view and takeover; GPU-box node | A bot browses in its own container, and Kelvin takes over from his phone |
| **M3** | Decision layer: HttpLaya triage + receipts + strict thresholds; tickets as the task inbox; routines with pre-flight | A new ticket is routed to the right bot with a visible receipt; a no-op routine is skipped |
| **M4** | E2B backend + placement; Tauri mobile + push | Laptop asleep → task overflows to E2B; push arrives |
| **M5** | OrtLaya with parity gate; calibration fit from labels; apply / rollback | In-process decisions match laya-serve on the goldens; per-bucket thresholds applied |
| **M6** | MCP connections + lazy catalogue; artifacts; memory | — |

---

## 13. Open questions for Kelvin

| # | Question | Default if undecided |
|---|---|---|
| Q1 | **Where does orphusbot-server live?** The GPU box (always on?) or a small VPS joined to NetBird? The phone needs it reachable when the laptop sleeps. | GPU box, if it's always on |
| Q2 | When both nodes are offline, should the server host an engine pool (subscription logins on the server box), or should tasks queue? | Queue (keeps credentials on Kelvin's machines) |
| Q3 | **Subscription use policy.** Using Claude Pro/Max and ChatGPT Plus/Pro for always-on, unattended bots may conflict with provider terms or rate limits (claude-bridge notes Anthropic's Agent SDK billing stance has changed before). Accept the risk, cap automated usage, or keep API keys as overflow? | Subscriptions for interactive and owner-initiated work; API-key fallback for routines |
| Q4 | Leptos (recommended) or Dioxus, or accept a TS UI inside Tauri for speed? | Leptos + Tauri |
| Q5 | Safety rule: may Laya ever auto-approve an irreversible external action (send, pay, publish) given a high fitted confidence, or is human/rule approval always required? | Never auto-approve irreversible actions |
| Q6 | Push: APNs/FCM (needs Apple/Google accounts, and the app must be reachable through their services) or self-hosted ntfy over NetBird (simple on Android, harder on iOS)? Is the phone iOS or Android? | ntfy on Android; APNs only if iOS |
| Q7 | Integrations: plain MCP servers only, or also an aggregator (Composio or Pipedream Connect)? Which apps matter first (Gmail, Calendar, GitHub …)? Kelvin's PA MCP server already covers mail, calendar and todos. | Plain MCP + Kelvin's PA server; no aggregator in v1 |
| Q8 | E2B: which plan or region, and do we need the desktop (GUI) template or just code sandboxes? Confirm the current envd API before writing the thin client. | Code sandbox first; desktop later |
| Q9 | emulate.dev: Rakazo doesn't actually use it. Still want it evaluated, or are in-repo fakes plus wiremock enough? | Fakes + wiremock |
| Q10 | Bots ↔ Orphus roles: is every OrphusBot bot an Orphus role (`--name`) usable in rooms and fleets, so group chats are rooms? | Yes |
| Q11 | Should OrphusBot and Orphus's own `@orphus/systemone` share one Laya endpoint and one receipt store from day one? | Yes (one System 1) |
| Q12 | Repo visibility: OrphusBot public (MIT) with the decision layer as a generic `DecisionModel` trait, and the Laya/Jev specifics, thresholds and fine-tuned checkpoints in a private crate or config? | Public core, private decision config and checkpoints |
| Q13 | Laptop as a node: run bots only on AC power and outside "focus" hours? Any hours when nothing should run on it? | AC only; Kelvin sets quiet hours |
| Q14 | GPU box isolation for GPU tasks: is container GPU passthrough acceptable, or should GPU work go only to trusted bots? | Trusted bots only |
