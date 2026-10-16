# OrphusBot: product requirements

| | |
|---|---|
| Status | Draft 0.1, for review |
| Date | 2026-10-16 |
| Owner | Kelvin Lee (@kelvincushman) |
| Licence | MIT, everything open source. Personal data and checkpoints trained on it are never committed (DESIGN §17) |
| Companion docs | [DESIGN.md](DESIGN.md) · [research/rakazo-architecture.md](research/rakazo-architecture.md) (design input: subsystem specs, trait sketches, data model, crate table) · [orphus-desktop DESIGN.md](https://github.com/kelvincushman/orphus-desktop/blob/main/docs/DESIGN.md) §5 and §7 (engine lifecycle, bridge extension, S1/S2 receipts) · [orphus-desktop CLEANROOM.md](https://github.com/kelvincushman/orphus-desktop/blob/main/CLEANROOM.md) |

---

## 1. Summary

OrphusBot is an always-on bot service with web, desktop and mobile clients. Kelvin hands it tasks (by chat, a ticket, a schedule or a webhook) and named bots do the work on real computers, using his existing **Claude and ChatGPT subscriptions** through the Orphus harness.

It has three parts that make it different from a chat app:

1. **Bots with computers.** Each bot gets its own isolated computer: a container on Kelvin's own machines first (laptop and GPU box over NetBird), and an E2B sandbox when those are busy, offline, or the work is untrusted. Kelvin can watch any bot's screen live and take over from any device.
2. **A fast decision layer (System 1).** Every task, tool call and routine passes through **Laya**, a Jev-family decision model that answers typed questions (choice / score / yes-no) in one forward pass. It decides who takes a task, which subscription to use, how urgent it is, where it runs, and whether to act or ask Kelvin. Every decision leaves a receipt, and Kelvin's corrections become training labels.
3. **A wearable and ambient capture.** The OmarchyWearable's button sends a spoken task straight to the bots, and they report back through a two-way LED and vibration channel (no speaker, by design); the wearer answers with the button or by voice. In hands-free mode, what Kelvin hears and says is mined for commitments, appointments and follow-ups, proposed for one-tap acceptance. It is designed first for neurodivergent people and works for anyone.
4. **The real harness.** Bots are `orphus --mode rpc` engines (System 2). OrphusBot never reimplements the agent loop and never holds model subscription tokens.

The product is modelled on Rakazo (Apache-2.0), studied in [research/rakazo-architecture.md](research/rakazo-architecture.md). No Rakazo code is used. **Rust is the main language**; TypeScript and Python remain only behind process boundaries (§11).

## 2. Problem

- **Orphus only runs while Kelvin is at a terminal.** There is no way to hand it a task from his phone, have it run overnight on the GPU box, and be nudged when it needs him.
- **Hosted bot products want his credentials and his data in their cloud.** Rakazo-style products are good at the "bot with its own computer" experience, but they centralise subscription tokens, default to running consequential actions without asking, and lock decisions into hard-coded functions.
- **Decisions are scattered and invisible.** Which bot answers, which model runs, whether to interrupt: in Rakazo these are pure functions and prompt conventions with no receipts and no way to learn from Kelvin's corrections.
- **ADHD-hostile defaults.** Most agent tools either interrupt constantly or go silent. Kelvin needs calm, batched nudges with urgent things surfaced fast.

## 3. Goals and non-goals

### Goals

| # | Goal | Measure |
|---|---|---|
| G1 | Hand any task to a bot from web, desktop or phone and see it through | Journeys 1–3 (§8) pass on all three clients |
| G2 | Bots work on real computers on Kelvin's machines, with E2B as overflow | A task runs in a per-bot container on a node; with the laptop asleep and GPU box busy, it runs on E2B instead |
| G3 | Every routing and approval decision is made by one decision service, with receipts | 100 % of triage, placement and tool-gate decisions have a stored receipt linked to the run |
| G4 | The decision layer improves from Kelvin's own corrections | Calibration fit from labels changes thresholds via an explicit apply step, with rollback |
| G5 | Subscription tokens never leave Kelvin's machines, never enter a sandbox, never reach the server DB | Verified by test: grep of DB, server logs and sandbox env for token material is empty |
| G6 | Nothing irreversible happens without a human or a standing rule | No send / pay / delete / merge / publish executes on a System 1 "pass" alone |
| G7 | Rust-first, MIT, fully open source | All server, node, decision and UI code in Rust; non-Rust parts listed in §11 only; no personal data in the repo |
| G8 | A button press on the wearable gets a task to the right bot, and the result back to the wearer, with no screen | Journey 7 passes |
| G9 | Ambient capture turns conversation into accepted to-dos without anyone writing them down, and without storing audio | Journey 8 passes; no audio at rest on the server; window text deleted after retention |

### Non-goals (v1)

- Multi-tenant, teams, billing, sign-up. One owner.
- Messaging surfaces (Slack, Telegram, WhatsApp, iMessage).
- Voice calls and avatar studio.
- Reimplementing the agent loop, providers or subscription auth (the harness owns them).
- Local Firecracker microVMs (E2B covers untrusted work).
- Daytona, Box, Railway or other sandbox providers (the trait allows them later).
- Training Laya inside the app. The app collects labels and applies fitted artifacts; training runs offline.

## 4. Users

| Persona | Needs |
|---|---|
| **Kelvin, owner** (the reference and only user in v1) | Delegates real work (code, research, admin, email drafts) to bots across Claude and ChatGPT. Mostly on the Omarchy laptop, often on his phone. Wants to see what bots are doing, approve risky steps in one tap, and be nudged gently rather than alarmed. Runs a GPU box and NetBird already. |
| **Kelvin, model researcher** | Owns the Jev/Laya decision model. Wants receipts, calibration health, a clean label harvest, and a safe apply/rollback loop for new checkpoints. |
| **Contributor** (later, public core) | Builds on a clean Rust codebase with fakes for every provider. Never needs Kelvin's private decision config. |

Accessibility: WCAG 2.1 AA, full keyboard path on web and desktop, reduced motion respected, and **calm notifications** (digest by default, interrupt only when System 1 says it's urgent and confident).

## 5. Product principles

1. **Kelvin's machines first.** Local nodes are the default; the cloud is overflow, not home.
2. **Tokens stay home.** Subscriptions live in each node's Orphus store. The server only knows "logged in / expired".
3. **System 1 routes, System 2 works, humans approve the irreversible.** Laya may route, defer, deny or escalate. It may approve only inside a whitelisted reversible class.
4. **Every decision has a receipt.** If it shaped a run, it's stored, visible and correctable.
5. **One harness.** OrphusBot is a client of `orphus --mode rpc`. Anything a bot does, Orphus can do from the terminal.
6. **Durable by default.** Postgres is the single source of truth. A crash or a closed laptop never loses work and never replays a side effect.
7. **Quiet operator.** Dense, calm UI; gentle nudges; no decoration without state behind it.
8. **Ponytail.** Reuse Orphus, NetBird, Laya, E2B and mature crates; build only the glue.

## 6. Concepts and vocabulary

| Term | Meaning |
|---|---|
| **Bot** | A named worker with a remit, default provider/model, computer scope and an Orphus role (`--name`). Has one main thread. |
| **Task / Run** | A task is a unit of work from Kelvin, a ticket, a routine or a webhook. A run is one attempt at it by one bot, with a status (queued → leased → running → waiting_input / waiting_takeover → completed / failed / cancelled). |
| **Ticket** | An item on Kelvin's task board. Assigning it to a bot wakes the bot. |
| **Routine** | A scheduled or triggered task (cron, one-shot, webhook) with an optional pre-flight question. |
| **Node** | One of Kelvin's machines running `orphusbot-node`: hosts engines and computers, reached over NetBird. |
| **Engine** | An `orphus --mode rpc` process for one bot session, running on a node **outside** the bot's computer. |
| **Computer** | The bot's isolated environment: a container on a node, or an E2B sandbox. Team computers share a volume; Private ones don't. |
| **Takeover** | Kelvin drives a bot's screen directly while its run is parked. |
| **Decision** | One System 1 call: typed questions over a state, answered by Laya with calibrated confidence. Below threshold it **abstains** and the default or Kelvin decides. |
| **Receipt** | The stored record of a decision, linked to its run and its eventual outcome label. |
| **Effect ledger** | The idempotency record of every side-effecting tool call: intended, approved, denied, executing, completed or uncertain. |

## 7. Requirements

Priority: **P0** = v1 blocker, **P1** = v1 target, **P2** = later.

### 7.1 Tasks, runs and threads

| ID | Requirement | P |
|---|---|---|
| B-RUN-01 | A message to a bot either answers its pending question, steers its live run, or creates a new task and run, in one transaction with the message | P0 |
| B-RUN-02 | Runs are leased with a fence; a lost lease aborts the engine turn. A reconciler re-enqueues lost work every 30 s | P0 |
| B-RUN-03 | Kelvin can stop a run, steer it mid-turn, or queue a follow-up from any client | P0 |
| B-RUN-04 | Side-effecting tool calls are recorded in the effect ledger; after a crash, completed effects replay their result and in-flight ones are marked **uncertain** and shown to Kelvin, never re-executed | P0 |
| B-RUN-05 | A bot can ask Kelvin a question (select / confirm / input) and park in `waiting_input`; reminders are gentle and batched, and the run expires after a configurable time | P0 |
| B-RUN-06 | Runs can launch an Orphus fleet or a Goal workflow instead of a single turn | P1 |
| B-RUN-07 | Every message, progress delta, tool event, approval and decision is an event with a per-thread sequence number | P0 |

### 7.2 Bots

| ID | Requirement | P |
|---|---|---|
| B-BOT-01 | Create, edit and disable bots: name, remit, instructions, default provider/model/thinking, computer scope (team / private), preferred node, disabled tools | P0 |
| B-BOT-02 | Each bot is an Orphus role, so bots can sit in Orphus rooms and fleets; a group thread is a room | P1 |
| B-BOT-03 | An "inbox" bot exists by default and receives anything System 1 can't route confidently | P0 |
| B-BOT-04 | Per-bot memory and skills come from Orphus; OrphusBot shows and edits them | P2 |

### 7.3 Tickets and routines

| ID | Requirement | P |
|---|---|---|
| B-TKT-01 | A ticket board (todo / doing / review / blocked / done) with priority and assignee bot; assignment wakes the bot | P0 |
| B-TKT-02 | New tickets are triaged by System 1 (§7.6) and pre-filled with bot, urgency and act/ask; Kelvin can accept or change in one action | P0 |
| B-TKT-03 | Ticket references in a prompt (e.g. `OB-12`) inject the ticket as labelled data | P1 |
| B-RTN-01 | Routines: cron list + timezone, one-shot, or webhook trigger; target is a prompt, a fleet or a workflow; optional model pin | P0 |
| B-RTN-02 | Routines can't create routines | P0 |
| B-RTN-03 | Optional **pre-flight**: a System 1 yes/no over a cheap delta ("anything new?") skips no-op runs and saves subscription quota; skips are receipted | P1 |
| B-RTN-04 | Kelvin's PA tools (mail, calendar, todos) can be routine inputs and ticket sources | P1 |

### 7.4 Computers and placement

| ID | Requirement | P |
|---|---|---|
| B-CMP-01 | One `ComputerProvider` interface: provision, status, pause, destroy, exec, files, home export/import, and optional screen/observe/act | P0 |
| B-CMP-02 | **Self-hosted backend (primary):** one rootless Podman/Docker container per bot on a node, desktop image with Xvnc + Chromium; LAN and NetBird ranges blocked from inside by default; CPU/memory limits | P0 |
| B-CMP-03 | **E2B backend (secondary):** code sandboxes first, desktop template later, through a thin Rust client | P0 (code) / P1 (desktop) |
| B-CMP-04 | Tool operations from the engine (bash, read, write, edit, find…) are redirected into the bot's computer; the engine and its tokens never run inside it | P0 |
| B-CMP-05 | Live screen view (noVNC) for any bot with a GUI computer, and takeover with a time-limited control lease, from web, desktop and phone | P1 |
| B-CMP-06 | Idle computers pause after a configurable time and checkpoint the home first | P1 |
| B-CMP-07 | **Placement**, in order: untrusted work → E2B; needs GPU → GPU box (queue, never E2B); live Private home → same node; else least-loaded online node (laptop only on AC power and outside quiet hours); else E2B if allowed; else queue | P0 |
| B-CMP-08 | A Private home can move between nodes or to E2B via export/import | P2 |
| B-CMP-09 | Optional gVisor runtime for semi-trusted local work; GPU passthrough only for bots marked trusted | P2 |

### 7.5 Nodes

| ID | Requirement | P |
|---|---|---|
| B-NOD-01 | `orphusbot-node` is a single Rust binary run as a systemd user service | P0 |
| B-NOD-02 | It connects **out** to the server over NetBird with mutual auth; it listens on nothing public, and screen streams bind only to the NetBird address | P0 |
| B-NOD-03 | Heartbeats report load, free slots, GPU/GUI capability, power state (AC / battery), and which providers are logged in (status only) | P0 |
| B-NOD-04 | It supervises one `orphus --mode rpc` per active bot session (restart with backoff, park when idle, resume on demand) with the `orphusbot-bridge` extension loaded | P0 |
| B-NOD-05 | Kelvin sets quiet hours per node; nothing new starts on the laptop then | P1 |

### 7.6 Decision layer (System 1)

| ID | Requirement | P |
|---|---|---|
| B-DEC-01 | One `DecisionModel` interface for all System 1 calls; backends: **laya-serve over HTTP (first)**, in-process ONNX via `ort` (later), and a null model that always abstains (safe default) | P0 |
| B-DEC-02 | **Triage** on every new task, in one batched call: which bot; solo / fleet / goal; Claude / OpenAI / local; thinking effort; urgency; act now vs ask Kelvin; untrusted content | P0 |
| B-DEC-03 | **Tool gate**: every consequential tool call gets `pass / ask` with state = task + bot remit + tool + redacted args + matching rules | P0 |
| B-DEC-04 | **Notify**: interrupt now vs add to digest, from urgency and a yes/no | P1 |
| B-DEC-05 | Below threshold, a decision **abstains** and falls back to the documented default (inbox bot, ask, today, local, digest…) | P0 |
| B-DEC-06 | **Safety rule:** System 1 may approve only inside a whitelisted reversible class (read-only calls, edits in the bot's own workspace, drafts). Send / pay / delete / merge / publish always need a standing rule or a human tap | P0 |
| B-DEC-07 | Deterministic rules always have the last word: user rules, static tool classes and the quota tracker can override any System 1 answer | P0 |
| B-DEC-08 | Every decision, including abstentions, is stored with state hash, questions, probabilities, `answer_confidence`, `jev_confidence`, threshold, model id and latency, linked to its run | P0 |
| B-DEC-09 | Every approval, override and reassignment Kelvin makes is captured as an outcome label on the receipt | P0 |
| B-DEC-10 | Thresholds start strict (act-now ≥ 0.95, others default) and are shown in settings in plain language | P0 |
| B-DEC-11 | Calibration: fit temperatures and per-bucket thresholds from labels; new thresholds or checkpoints go live only by an explicit apply, with one-click rollback | P1 |
| B-DEC-12 | The in-process ONNX backend ships only after it matches Laya's golden fixtures | P1 |
| B-DEC-13 | Receipts use the same JSONL shape as Orphus `@orphus/systemone`, so orphus-desktop's Decisions view can read them | P1 |

### 7.7 Models and subscriptions

| ID | Requirement | P |
|---|---|---|
| B-MOD-01 | Sign-in to ChatGPT and Claude runs through Orphus on the node; OrphusBot relays the login prompts to whichever client Kelvin is on | P0 |
| B-MOD-02 | The server stores only login **status** per node and provider, never tokens | P0 |
| B-MOD-03 | A quota tracker records rate-limit and usage-limit signals per subscription and steers new work away from a limited one | P1 |
| B-MOD-04 | Per-bot backup models (ordered) when the primary fails before streaming | P1 |
| B-MOD-05 | Local models (Ollama / LM Studio on the GPU box) are a first-class provider class | P2 |

### 7.8 Integrations and secrets

| ID | Requirement | P |
|---|---|---|
| B-INT-01 | Integrations reach bots as **MCP servers** attached to the engine; the server owns connection records and grants per bot | P0 |
| B-INT-02 | Kelvin's PA MCP server is the first integration | P0 |
| B-INT-03 | Tool sources with more than 20 tools are exposed as search / load / execute wrappers | P1 |
| B-INT-04 | Secrets for bots are envelope-encrypted on the server, bound to an origin where relevant, redacted from all output | P1 |
| B-INT-05 | Composio or Pipedream as an aggregator | P2 |

### 7.9 Wearable

| ID | Requirement | P |
|---|---|---|
| B-WRB-01 | The server implements the OmarchyWearable device channel (`/api/device/*`) with the same wire format, so the existing firmware and companion app work unchanged apart from the server URL | P0 |
| B-WRB-02 | Pairing a wearable requires a signed-in OrphusBot session; device tokens are stored hashed and revocable | P0 |
| B-WRB-03 | A button capture (tap, speak, tap) becomes a task with source `wearable`, triaged by System 1 | P0 |
| B-WRB-04 | **Duplex habitat.** Every signal to the wrist is a tracked message (inform / ask) with a defined meaning, and every ask has a defined tap / double-tap reply. The server knows whether each message was delivered, acknowledged, answered, dismissed or expired | P0 |
| B-WRB-10 | **No speaker, by design.** Output is NeoPixel + vibration only; nothing in OrphusBot depends on audio output; anything needing words goes to the phone or desktop | P0 |
| B-WRB-11 | One ask on the wrist at a time; others queue by urgency; capture always wins | P0 |
| B-WRB-12 | Unanswered asks escalate to the phone after an urgency-based delay (faster if the device reports no working haptic) and stop pulsing on the wrist | P0 |
| B-WRB-13 | Asks and errors are identifiable by vibration alone, for eyes-down and in-pocket use | P0 |
| B-WRB-05 | A bot's question can be answered aloud: tap opens the mic, the transcript answers that specific message; if the ask was superseded, the answer goes to the thread instead | P1 |
| B-WRB-06 | A tap can only confirm things the wearer already knows about (their own button task, a reminder, an effect from a task they started in the last 10 min, reversible only). For anything else a tap means "seen" and sends the card to the phone | P0 |
| B-WRB-07 | Audio is admitted only inside a button window or in hands-free mode that is allowed server-wide | P0 |
| B-WRB-08 | On-device STT is the default; server STT (qwen3-asr on the GPU box) is opt-in per device | P0 |
| B-WRB-09 | A CI contract test keeps the server, firmware and app wire tables identical | P0 |

### 7.10 Ambient capture

| ID | Requirement | P |
|---|---|---|
| B-CAP-01 | Hands-free transcripts are windowed and mined: System 1 classifies, then a tool-less extraction call produces structured proposals | P1 |
| B-CAP-02 | Ambient text never makes a bot reply or act; proposals need acceptance (notes may auto-file, with undo, if the profile allows) | P0 |
| B-CAP-03 | Accepting a proposal creates a ticket, a tentative calendar draft, a follow-up with a reminder, or an Obsidian note | P1 |
| B-CAP-04 | Profiles: **Focus support** (neurodivergent-first: several digests, time-blindness nudges, re-surfacing, auto-filed notes, no guilt wording) and **Standard** | P1 |
| B-CAP-05 | No audio stored on the server; window text deleted after retention (default 7 days); accepted items keep only fields and a short quote | P0 |
| B-CAP-06 | Other people's speech is used only as context and is never filed as its own item unless it concerns the owner | P0 |
| B-CAP-07 | Hands-free is off by default, can be paused from the phone or on a schedule, has a server kill switch, and its state is visible on every screen | P0 |

### 7.11 Clients

| ID | Requirement | P |
|---|---|---|
| B-CLI-01 | One Leptos UI shipped as a web app (served by the server), a Tauri 2 desktop app and Tauri 2 mobile apps | P0 (web, desktop) / P1 (mobile) |
| B-CLI-02 | Live sync over SSE from the last seen event number; a reconnect replays exactly what was missed | P0 |
| B-CLI-03 | Views: inbox (needs-you first), bot list, thread, ticket board, routines, captures, computer view, decisions (receipts + calibration health), nodes, wearable, settings | P0 |
| B-CLI-04 | Approval cards show the action, the System 1 answer and confidence, and approve / deny / always-allow in one tap | P0 |
| B-CLI-05 | Android: offline outbox for unsent messages; push through self-hosted ntfy / UnifiedPush (no Google account) for needs-you / finished / takeover | P1 |
| B-CLI-06 | Sign-in with passkeys; long-lived device tokens on mobile; reachable only over NetBird | P0 |
| B-CLI-07 | Command palette and full keyboard path on web and desktop | P1 |

## 8. Key user journeys

1. **First task.** Install node on the laptop → server on the GPU box → open the web app over NetBird → sign in with a passkey → log in to Claude through the relayed prompt → message the inbox bot "summarise my unread PRs" → watch it stream → see its triage receipt.
2. **Ticket from the phone.** On the phone, add ticket "draft a reply to the supplier about the late order" → System 1 routes it to the admin bot, urgency *today*, act-now *yes* (draft is reversible) → the bot drafts via the PA server → a digest nudge later says it's ready → Kelvin reviews; the send itself needs his tap.
3. **Watch and take over.** A research bot browsing in its container hits a login wall → it asks for takeover → push on the phone → Kelvin opens the screen, logs in, releases → the run resumes.
4. **Overflow and untrusted work.** Laptop lid closed, GPU box busy with a GPU task → a new "try this random repo" ticket is flagged untrusted → placed on E2B → result posted; tokens never left the node.
5. **Teaching System 1.** After a few weeks, Decisions view shows 300 labels on "which bot" with calibration drift → Kelvin runs fit → reviews the before/after on held-out data → applies → a week later rolls back one bucket that got worse.
6. **Quiet routine.** "Every morning at 8: check my inbox for anything from customers" → pre-flight says nothing new → run skipped with a receipt, no quota used.
7. **Button to bot.** Walking, Kelvin taps the wearable: "ask the research bot to compare three e-bike batteries under £400", taps again → blue pulse (queued) → breathing blue (running) → later a green flash (done) and the result is in the OrphusBot inbox.
8. **Ambient capture.** In a supplier call with hands-free on, Kelvin says "I'll send the drawings by Thursday" and the supplier says "we'll confirm the delivery date tomorrow" → at the 14:00 digest the phone shows two proposals: a task "Send drawings, due Thursday" and a follow-up "Supplier to confirm delivery date" → two taps accept both → on Wednesday a gentle nudge says the drawings are still open.

## 9. Non-functional requirements

| Area | Requirement |
|---|---|
| Latency | Triage decision ≤ 150 ms p95 via laya-serve on the GPU box; tool-gate decision ≤ 300 ms p95 (timeout → ask). First streamed token in the client ≤ 1 s after the engine emits it. |
| Reliability | No data loss on a crash of the server, a node or an engine. No side effect replays after a restart. A node going offline mid-run leads to recovery or a clear "uncertain" state within 60 s. |
| Security | Subscription tokens only on nodes. No public ports on nodes; server reachable only over NetBird. Containers rootless, LAN-blocked by default. Secrets envelope-encrypted with the key outside the DB. Redaction on every output path. |
| Privacy | Zero telemetry. Data leaves Kelvin's machines only to the model providers, E2B (when placed there) and the integrations he connects. |
| Accessibility | WCAG 2.1 AA; full keyboard path; reduced motion; non-colour status cues; calm notification defaults. |
| Platforms | Web (current Chromium/Firefox/Safari), desktop Linux (Wayland/Hyprland) first then macOS/Windows, mobile Android and/or iOS (Q6). Nodes: Linux x64. |
| Footprint | Node daemon idle RSS ≤ 50 MB excluding engines and containers. Server runs comfortably on the GPU box alongside laya-serve. |
| Testability | Every provider trait has a fake; HTTP providers tested with wiremock; a scripted fake engine speaks the RPC protocol; Playwright screenshot gallery on every UI PR. |

## 10. Architecture in one paragraph

A Rust **orphusbot-server** (axum, sqlx, Postgres, `graphile_worker` jobs, croner) holds tasks, runs, tickets, routines, approvals, placement, the effect ledger and decision receipts, and streams events over SSE. A Rust **orphusbot-node** on each of Kelvin's machines links out over NetBird, supervises `orphus --mode rpc` engines with a small TypeScript **orphusbot-bridge** extension, and runs per-bot containers. **orphusbot-decide** wraps Laya behind a `DecisionModel` trait. **orphusbot-ui** is Leptos, shipped through Tauri 2. Full detail: [research/rakazo-architecture.md](research/rakazo-architecture.md) §5–§10.

## 11. What stays outside Rust

| Component | Language | Boundary |
|---|---|---|
| Orphus engine incl. Pi, subagents, rooms, fleets, `@orphus/systemone` | TypeScript | stdio JSONL RPC; node is the parent process |
| Subscription sign-in (Pi OAuth, claude-bridge / Claude Agent SDK) | TypeScript + Claude Code CLI | Same RPC (`login_provider`, OAuth UI prompts) |
| orphusbot-bridge extension (≤ ~300 lines, no policy) | TypeScript | Inside the engine; unix socket to the node |
| laya-serve (phase 1 backend) | Python | HTTP `/v1/systemone` over NetBird |
| Laya calibration, fine-tuning, ONNX export | Python | Offline jobs on the GPU box; artifacts versioned in `decision_model` |
| noVNC, terminal, markdown rendering | JS islands in the Leptos UI | wasm-bindgen interop |
| qwen3-asr (server STT, opt-in) | Python | HTTP `/transcribe` on localhost, GPU box |
| Wearable firmware and companion app | C (Zephyr) and Dart (Flutter) | BLE to the wearable; the existing device channel (HTTP + WS) to the server |
| Playwright screenshot tests | TypeScript | CI only |

## 12. Harness prerequisites (work in `kelvincushman/orphus`)

| ID | Change | Needed by |
|---|---|---|
| H-B1 | A supported way for an extension to **replace tool operations** (bash, read, write, edit, find, ls) with a remote implementation, generalising the `ssh.ts` example | B-CMP-04 |
| H-B2 | OAuth login prompts (`oauth_prompt` / `oauth_select` / `oauth_manual_code`) usable by an RPC host that is not on the same machine as the user (relay-safe: no localhost callback assumptions) | B-MOD-01 |
| H-B3 | A login-status query over RPC per provider (logged in / expired / missing), without exposing tokens | B-MOD-02, B-NOD-03 |
| H-B4 | Rate-limit and usage-limit signals surfaced as structured RPC events | B-MOD-03 |
| H-B5 | Same as orphus-desktop H-04: a named System 1 adapter for a self-hosted `/v1/systemone`, so engines and OrphusBot share one Laya endpoint | B-DEC-13 |
| H-B6 | Same as orphus-desktop H-03: structured RPC for fleet and workflow launch and state | B-RUN-06 |

## 13. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 Skeleton** | Proto crate, server (axum, sqlx, events, SSE), node link over NetBird, one engine over RPC on the laptop, bare Leptos web UI | Journey 1 up to "watch it stream" |
| **M1 Durable runs** | Leases, fences, steering, reconciler, effect ledger; bridge gate with static rules; approval cards; Tauri desktop shell; passkeys | Approve a write from the desktop app; kill the node mid-run and it recovers |
| **M2 Computers** | Podman computers, tool redirect, noVNC view and takeover; GPU-box node; placement rules without System 1 | Journey 3 on desktop |
| **M3 System 1 + wearable** | HttpLaya triage + tool gate + receipts + strict thresholds; tickets; routines with pre-flight; Decisions view; wearable device channel, button → task, cues | Journeys 2 (desktop), 6 and 7 |
| **M4 Reach + capture** | E2B backend; Tauri Android; ntfy push; quota tracker; ambient capture, proposals and profiles | Journeys 2 and 3 on the phone; Journeys 4 and 8 |
| **M5 Learning** | Label capture complete; calibration fit, apply and rollback; OrtLaya with golden-fixture parity | Journey 5 |
| **M6 Breadth** | MCP connections UI and lazy catalogue; artifacts; secrets; fleets and workflows as run targets | — |

Order is strict: M3 depends on M1's receipts and gates; M4's overflow depends on M2's placement.

## 14. Open questions

Defaults apply if Kelvin doesn't decide; already-decided items are recorded at the end.

| # | Question | Default |
|---|---|---|
| Q3 | Unattended bots on Claude/ChatGPT **subscriptions** may conflict with provider terms or limits. Accept, cap, or use API keys for routines? | Subscriptions for owner-initiated work; API keys for routines |
| Q4 | Leptos, Dioxus, or a TS UI in Tauri? | Leptos + Tauri |
| Q5 | Can System 1 ever auto-approve an irreversible action at very high fitted confidence? | Never |
| Q7 | Integrations beyond the PA server in v1: which apps first? Any aggregator? | PA server + plain MCP; no aggregator |
| Q8 | E2B plan and whether the desktop template is needed in v1 | Code sandboxes first |
| Q9 | Evaluate emulate.dev, or fakes + wiremock only? | Fakes + wiremock |
| Q10 | Should OrphusBot and Orphus's own System 1 share one Laya endpoint and receipt store from day one? | Yes |
| Q12 | Product name and ticket prefix (`OB-`)? | OrphusBot, `OB-` |

Wearable- and capture-specific questions are D1–D7 in [DESIGN.md](DESIGN.md) §19.

**Decided (2026-10-16):** separate app with web, desktop and mobile clients · Rust as the main language · Jev-family decision model, concretely Laya, as System 1 · own machines first, E2B second · server on the always-on GPU box (so the GPU box is always a node and tasks only queue if it is down) · Android phone, push via self-hosted ntfy · OmarchyWearable brought in as an input device · everything open source except personal data and checkpoints trained on it.

## 15. Out of scope for this document

Implementation detail lives in [DESIGN.md](DESIGN.md); the Rakazo study, crate versions and the Laya ONNX contract live in [research/rakazo-architecture.md](research/rakazo-architecture.md).
