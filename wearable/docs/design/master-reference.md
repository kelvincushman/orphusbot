<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

<!-- Converted from .docx via textutil. Source .docx in docs/plans/. -->





Wearable
Master Project Reference
Agentic AI System · Mobile App · Wearable Device
v1.0  ·  April 2026  ·  Kelvin Lee



This document is the single source of truth for the Wearable system. It describes what the system does, how its parts connect, and what needs to be built — covering the AI agent harness, mobile app, wearable hardware, skills system, and multi-business capabilities.

## 1. What Is Wearable
Wearable is a personal AI Chief of Staff that lives across three surfaces: a server-side agent harness, a mobile app, and a wearable device worn on the body. The user interacts with a single intelligent agent — the Chief of Staff — by speaking, pressing a button, or typing. The Chief of Staff understands the request, silently delegates to specialist agents when needed, and returns a unified response. The user never needs to know which specialist handled which part.

The three surfaces
Surface
What it is
Primary use
Server + Dashboard
Node/TypeScript agent harness on a local server (wearable-server.local). Accessible via browser dashboard SPA.
Operations console: task Kanban, memory landscape, schedule admin, audit logs. Desk view.
Mobile App
Flutter app on Android/iOS connecting to the server over LAN/internet.
Pocket boardroom: chat with the Chief of Staff, see tasks, manage schedules, monitor device.
Wearable Device
Custom BLE device (nRF52840 Sense) worn as a clip or pendant.
Ear + input: ambient voice capture on gate, button press actions, haptic + LED feedback.

The single user flow

Canonical scenario
## 1. Kelvin presses the wearable button and says: "Draft a thank-you email to Andrej and remind me every morning at 7 to check my inbox."
## 2. Wearable streams audio to the app, which forwards it to the server.
## 3. Server voice gate opens (button press = 60-second capture window). Audio goes to speech-to-text.
## 4. Chief of Staff receives the transcript. It understands two tasks: email draft + recurring reminder.
## 5. CoS silently delegates: @comms writes the email draft, @ops creates the schedule.
## 6. Both sub-tasks complete. CoS composes a single reply summarising the result.
## 7. App Boardroom thread shows the CoS response. Tasks tab shows both tasks. Schedules tab shows the new 7 AM entry.
## 8. Kelvin takes off the wearable. TV plays for an hour. Server logs: zero captured utterances. The silence is the product working.

## 2. Agent System
The agent system is the spine of Wearable. Every capability — answering questions, drafting content, running automation, doing research — is delivered by one of five AI roles running on the server.

### 2.1 The Five Roles
Role
Title
What it does
Allowed tools
main
Chief of Staff
Receives every user prompt. Parses intent. Responds directly if simple. Delegates to specialists if needed. Owns the final response and status.
Read, Grep, Glob, Dispatch (child tasks)
comms
Communications
Drafts emails, messages, letters, meeting notes, and any outward-facing text.
Read, Write (artifacts/), Edit
content
Content Creator
Long-form writing: blog posts, scripts, social content, research-backed articles.
Read, Write, WebFetch (allowlist)
ops
Operations COO
Automation and system tasks: scheduling, bash commands, LAN-scoped operations.
Bash (safety-gated), LAN network, Read/Write
research
Research Analyst
Deep web research. Returns structured briefs, comparisons, and summaries.
Read, WebFetch (allowlist)

### 2.2 How the Chief of Staff Delegates
The user never routes directly to a specialist. The Chief of Staff (main) reads the request, decides if delegation is needed, and ends its first response with delegation tokens on their own lines:

# CoS first response (internal — not shown to user)
The user wants two things: an email draft and a daily reminder.
 
@comms: Draft a warm thank-you email to Andrej Karpathy referencing last week's paper on scaling laws.
@ops: Create a daily schedule: every morning at 07:00, message "Check inbox — Andrej follow-up pending".

The server dispatcher detects these tokens and automatically enqueues two child tasks tagged to the same session. When both children complete, the CoS is re-entered to compose the final user-facing reply — a single message that references both outcomes. The user sees one coherent answer, not five agent chips.

### 2.3 Task Lifecycle
Status
Meaning
Transition
active
Task is running or queued.
Created when dispatched.
awaiting_children
CoS has delegated; waiting for specialists.
CoS emits delegation tokens → dispatcher spawns children.
pending_input
Task needs the user to answer a question.
Worker calls ask_user() — server writes pending_input.json.
completed
Response delivered and verified.
RESPONSE.md written + completion gate passed.
failed
Retries exhausted or user cancelled.
After max attempts or POST /api/tasks/:id/cancel.

### 2.4 Memory Stack
Every agent prompt is assembled from four memory layers, merged in order:
	•	Karpathy memory (memory.md per chat ID) — atomic facts extracted after each conversation turn. 8 KB cap; oldest facts pruned on overflow.
	•	Pinned memory (SQLite table) — user-explicit pins that never decay.
	•	Obsidian vault — top 3 snippet matches from the local Vault grep.
	•	Hive mind (SQLite table) — last 8 cross-agent activity entries, giving each agent visibility into what the others have recently done.

### 2.5 Skills System
A Skill is a reusable capability bundle that can be granted to any role. It consists of a prompt fragment (injected into the agent's system prompt), a set of allowed tools, guardrails (max cost, max tokens), and optional Vault reference files.

Skill concept
Detail
Skill definition
Stored in /src/skills/<id>/SKILL.md + manifest.json. Mirrors the existing NLAH/SKILL.md pattern.
Granting skills
Skills are granted per-role via the role_skills table. A dispatcher resolves granted skills at task-creation time.
Prompt injection
Skill prompt fragments are appended after the agent's base persona, before the user message.
Tool union
Skill tools are unioned with the role's base tools, then intersected with the business tool allowlist.
Guardrails
Tightest (min) values win: if the skill caps at 2000 tokens and the role caps at 4000, 2000 applies.
Examples
blog-writer: SEO-aware long-form writing prompts + WebFetch. seo-audit: structured checklist + search tools. ad-creative: tone guidance + image tool access.

### 2.6 Multi-Business Support
Kelvin operates multiple businesses. Each business has its own Chief of Staff session, memory namespace, artifact directory, budget caps, and tool allowlist. Specialist agents are shared code but run in the context of the dispatching business — there is no cross-business data bleed.
	•	One logical Chief of Staff per business (same code, different context).
	•	Specialists are shared across businesses; isolation comes from the BusinessContext object passed through every dispatch.
	•	Concurrent tasks across businesses run independently: Business A's research and Business B's email draft proceed in parallel with separate traces and budget draws.

## 3. Wearable Device
The wearable is the ear of the system. It is a small hardware device (nRF52840-based) worn on the body. Its job is to capture the owner's voice on demand, signal intent via button presses, and deliver feedback via LED and vibration. Everything else is handled by the server.

### 3.1 Hardware Overview
Component
Specification
MCU
Nordic nRF52840 Sense (Bluetooth 5.3, BLE audio)
Microphone
PDM MEMS microphone, 16 kHz sample rate, Opus codec for BLE streaming
Button
Capacitive or mechanical single button; multi-press gestures firmware-detected
LED feedback
NeoPixel RGB LED (WS2812B or similar); full colour control via BLE command from server
Haptic feedback
ERM or LRA vibration motor; pattern control via BLE command
Connectivity
BLE 5.x to phone app; no direct Wi-Fi (phone is the bridge)
Firmware
Zephyr RTOS, built with west. Button + audio characteristics already implemented.

### 3.2 Button Press Actions
The wearable button supports four distinct gestures. Each maps to a different Wearable action. Gestures are detected in firmware and sent to the server as named events via the app bridge.

Gesture
How to perform
Action
Server event code
Single press
One tap
Open capture window (60 s). Start listening for a voice command.
AGENT_REQUEST
Double press
Two taps within 400 ms
Read back last completed task / CoS response via TTS on phone.
REPLAY_LAST
Triple press
Three taps within 600 ms
Dismiss / cancel the current in-flight task.
CANCEL_ACTIVE
Long press
Hold ≥ 800 ms
Toggle hands-free mode on/off (requires enrolled voice profile).
TOGGLE_HANDS_FREE


Capture window
A single press opens a 60-second rolling window. Audio frames are only forwarded to speech-to-text during this window. After 60 seconds with no further press, the window closes and all frames are dropped. A subsequent press resets the 60-second clock. This is the core privacy gate: the device is never hot unless you pressed the button.

### 3.3 Wake Words
In addition to button presses, the wearable supports spoken wake words as trigger alternatives. Wake word detection runs on-device (lightweight keyword spotter) and emits the same server events as button presses — no cloud call is needed for the wake word itself.

Wake word
Equivalent to
Notes
"Wearable" / "Hey Wearable"
Single press (AGENT_REQUEST)
Opens capture window. Subsequent speech is the command.
"Tasks" / "What's on"
System status query
Triggers a GET /api/tasks?status=active response via TTS.
"Done" / "Complete that"
Mark last task done (if pending_input)
Equivalent to a POST /api/tasks/:id/reply with "done".
"Cancel"
Triple press (CANCEL_ACTIVE)
Cancels the most recent in-flight task for this device.


Wake word privacy note
Wake word detection is entirely on-device. No audio is streamed to any server until the wake word fires and a capture window opens. The keyword spotter uses a small local model — it cannot understand arbitrary speech, only the enrolled wake phrases.

### 3.4 LED Feedback (NeoPixel)
The NeoPixel LED provides instant, non-intrusive visual feedback for device state. Colours and patterns are commanded by the Wearable server via BLE, routed through the app bridge. The following table defines the full LED vocabulary:

State
Colour
Pattern
Meaning
Idle / disconnected
Off
Off
Device is not connected to the app.
Connected, waiting
Soft white
Slow breathe (3 s cycle)
Paired and ready. No active session.
Capture window open
Emerald green
Fast pulse (0.5 s)
Listening. Speak now.
Processing / thinking
Blue
Spinning chase
Request received, agents working.
Task completed
Emerald green
3 quick flashes
Response ready. Check app.
Pending your input
Amber
Slow double-flash
Agent needs your answer.
Error / failed
Red
Rapid flash × 5
Task failed. Check app for detail.
Hands-free active
Cyan
Slow breathe
Hands-free mode on, listening for owner voice.
Habitat alert
Magenta
Custom pattern
Triggered by server habitat alert command.
Low battery
Red
Single flash every 10 s
Battery below 20%. Charge soon.

### 3.5 Haptic Feedback
Vibration patterns complement the LED for situations where the user cannot see the device (e.g. in a pocket or under clothing).
Event
Haptic pattern
Capture window open
Single long buzz (300 ms) — "I'm listening."
Task completed
Two short buzzes (100 ms + 100 ms) — "Done."
Pending input
Three quick buzzes (80 ms × 3) — "I need you."
Error
One long + one short (400 ms + 200 ms) — "Something went wrong."
Habitat alert
Custom pattern from server command — configurable via app.
Hands-free toggle
Distinct pattern: short-long (on) or long-short (off).

### 3.6 Voice Identity & Privacy Gate
The wearable can be configured in one of two capture modes. Button-press mode is the default and the most private.

Mode 1 — Button-press only (default)
	•	Audio is captured only during an active capture window (opened by button press or wake word).
	•	No voice identity check is needed — the physical gesture is the authorisation.
	•	This is sufficient for 95% of use cases and closes the worst privacy hole (ambient capture).

Mode 2 — Hands-free (opt-in)
	•	Requires prior voice profile enrollment (minimum 3 audio samples, ≥ 3 seconds each).
	•	Capture window is always open, but utterances where the speaker is not identified as the enrolled owner are dropped before dispatch. They are still echoed back on the WebSocket as "(overheard, not dispatched)" for UX transparency.
	•	Enable via app: Settings → Wearable Advanced → Hands-free capture toggle.
	•	Long-press the button to toggle hands-free on/off without opening the app.


Privacy guarantee
The server drops all audio frames that arrive outside an active capture window before they reach the speech-to-text provider. Zero frames = zero transcript = zero billing = zero Obsidian write. In hands-free mode, the server additionally drops all utterances where isOwner=false before dispatching to the agent. The LED and logs make the current state auditable.

## 4. Mobile App
The mobile app is the pocket boardroom. It is the user's primary interface for talking to the Chief of Staff, tracking what agents are doing, and managing schedules. It pairs with the wearable over BLE and connects to the Wearable server over the local network or internet.

### 4.1 Navigation Structure
Tab
Icon
Route
What's here
Boardroom
forum_outlined
/boardroom
Chat with the Chief of Staff. The home screen.
Tasks
checklist_outlined
/tasks
Unified task ledger: Active, Needs Input, Done.
Schedules
alarm_outlined
/schedules
Cron-based recurring tasks. Create, edit, run now.

The side drawer (swipe right or hamburger icon) holds: Device Status, Dashboard WebView, Settings, and the Delegation Ledger (operator-level hive mind view).

### 4.2 Boardroom Tab
The Boardroom is a single-thread chat interface with the Chief of Staff. It is the first tab the user sees on launch.

Layout
	•	Full-screen chat thread — message bubbles, timestamps, streaming responses.
	•	Pinned input bar at the bottom: text field + mic button + send button.
	•	Mic button: if wearable connected, tap opens the capture window on the device (same as pressing the physical button). If no wearable, uses the phone microphone.
	•	When a CoS delegation is in progress, an inline TaskChip appears in the thread: "Delegating to @comms · 12 s ago · running". Tap to see task detail. This is informational — the user cannot route to roles directly.

Thread history
	•	Swipe from left edge or tap the menu icon to open a side sheet of past conversation sessions.
	•	Tap a past session to load it into the Boardroom for review. A breadcrumb "Viewing past session" appears at the top.
	•	Tap "Return to live" to go back to the current active thread.

Wearable mic indicator
	•	A small 🎙 icon tinted emerald appears in the input bar when hands-free mode is active on the paired wearable.
	•	The WearableStatusDot in the app bar shows device connection state at all times.

### 4.3 Tasks Tab
The Tasks tab is the unified ledger of everything the agent system has been asked to do. It reads from the server, not from KelvinLee's Firebase Action Items — those are deprecated.

Segment
What shows here
User action
Active
Tasks currently running or queued with agents.
Tap to see detail + trace. Cancel button if needed.
Needs Your Input
Tasks paused because an agent has a question.
Inline reply box. Type answer → POST /api/tasks/:id/reply.
Done
Completed tasks (last 30 days by default).
Tap to see full response and any child task summaries.

Task row anatomy
	•	Left stripe: 4 dp colour band in the role's accent colour (identifies which agent handled it).
	•	Title: first line of the task description.
	•	Summary: first 120 characters of the response, or "Working…" if still active.
	•	Meta line: status dot · last updated · parent task link if this is a child task.

Task detail screen
	•	Full response text (selectable). Copy to clipboard button.
	•	Children section: list of sub-tasks if CoS delegated, each tappable.
	•	Trace toggle: shows last 50 trace.jsonl events (for debugging, collapsible).
	•	Actions: Reply (if pending_input), Cancel (if active).

### 4.4 Schedules Tab
The Schedules tab lists and manages all cron-based recurring tasks. These are tasks that fire automatically on a schedule — "every morning at 7", "every Monday", etc.

Schedule list
	•	Each row: schedule name · human-readable cadence ("Every day at 07:00") · next 3 fire times · last run status (✅ / ❌ / never) · enable/disable toggle.
	•	Pull-to-refresh. FAB: + to create new schedule.

Create / edit schedule
	•	Name field.
	•	Cron picker: presets (Every hour / Every morning at X / Every weekday at X / Every Monday / Custom) + raw cron input for advanced users.
	•	Message template: what the CoS will receive when the schedule fires. Supports {date} and {time} placeholders.
	•	Channel selector: Boardroom (default) or Telegram (if configured).

Row actions (long-press)
	•	Run now — fires the schedule once immediately (with confirmation dialog).
	•	Edit — opens create/edit sheet pre-filled.
	•	Duplicate — clones the schedule with "Copy of" prefix.
	•	Delete — removes the schedule (with confirmation).

### 4.5 Device Status Screen (Drawer)
Accessible from the side drawer. Shows the full health of the paired wearable.
	•	Connection hero orb: large animated circle. Emerald glow = connected. Amber pulse = syncing. Grey = disconnected.
	•	Device name, BLE signal bars, battery percentage.
	•	Audio capture state: waveform animation if capture window open; flat line otherwise.
	•	Capture window setting: how long a button press keeps the mic hot (30 s / 60 s / 90 s / 120 s).
	•	Hands-free toggle: requires enrolled voice profile. If not enrolled, shows "Enroll your voice first" prompt.
	•	Sync queue: count of audio segments pending upload. Swipe-to-discard individual segments.
	•	Habitat alerts: enable/disable, alert type (LED / haptic / both), test button, last 5 alerts history.

### 4.6 Dashboard WebView (Drawer)
	•	Full-screen embedded web view of the Wearable dashboard (http://wearable-server.local:3141).
	•	Bearer token injected from secure storage — no second login required.
	•	Offline card shown if server is unreachable (not on LAN).
	•	Open-in-browser icon in the app bar for full desktop view.

### 4.7 Settings
Group
Items
Account
Name, email, language, custom vocabulary.
Voice & Audio
Speech profile (enrollment), conversation timeout, hands-free toggle, wearable mic priority.
Notifications
Frequency, daily summary, daily reflection timing.
Wearable Advanced
AI persona config, safety rules viewer (read-only), session server (shows paired URL + change pairing), delegation ledger (operator-level hive mind view).
Integrations
Google Calendar, Apple Health, custom webhooks (POST to your own endpoints on task events).
Privacy & Data
Data privacy settings, offline sync, export all data to JSON.
Support
Help, feedback/bug report, what's new.

## 5. Server & API
The Wearable server is a Node/TypeScript (Bun) application running locally. It hosts the agent harness, the Inngest event bus, the dashboard SPA, and all HTTP endpoints consumed by the app and the wearable bridge.

### 5.1 Architecture
	•	src/index.ts — entry point. Starts the HTTP server and Inngest client.
	•	src/orchestrator.ts — intake() receives every inbound prompt, runs the security gate, assembles memory context, emits wearable/agent.prompt event.
	•	src/harness/dispatcher.ts — picks up wearable/agent.prompt, creates the task store entry, invokes the worker (Claude Code or Pi CLI).
	•	src/harness/inngest/ — durable event handlers for agent.prompt, agent.result, device.audio.final, device.button, conversation.finalized.
	•	src/dashboard.ts — Express/Hono router for all HTTP API endpoints.
	•	src/dashboard-html.ts — server-side rendered dashboard SPA (emerald theme).
	•	src/harness/device/ — WebSocket audio handler (ws-audio.ts), speech-to-text pipeline (stt.ts), device registry, voice profiles.
	•	src/scheduler.ts — reads scheduled_tasks table on a per-minute Inngest tick and fires due schedules.

### 5.2 Full API Surface
Core
GET  /api/health                            Server reachability + version
POST /api/chat         { message }           Send message to CoS (main role)

Tasks
GET  /api/tasks?status=active|pending_input|completed|failed&limit=N
GET  /api/tasks/:id/detail                  Full task: contract + response + children + pending_input
POST /api/tasks/:id/reply   { answer }       Answer a pending_input question
POST /api/tasks/:id/cancel                  Cancel an active task
GET  /api/tasks/:id/trace?limit=N           trace.jsonl events for debugging

Schedules
POST   /api/schedules     { name, cron, message, chatId?, channel? }
GET    /api/schedules                        All schedules ordered by next_run_at
GET    /api/schedules/:id
PATCH  /api/schedules/:id
DELETE /api/schedules/:id
POST   /api/schedules/:id/run-now           Fire once immediately

Voice profiles
POST   /api/voice-profile  { samples:[base64_pcm16_wav], deviceId }
GET    /api/voice-profile/:deviceId          Enrolled? Timestamp?
DELETE /api/voice-profile/:deviceId          Clear enrollment

Device / wearable
POST /api/device/event    { kind, code, at? }   Button press / wake word event
POST /api/device/hands-free { enabled }               Toggle hands-free per device
GET  /api/device/ws/audio                             WebSocket: binary audio frames

Agent system (operator)
GET  /api/agents/status                    Last-active + task count per role
GET  /api/hive-mind?limit=N&role=…        Cross-agent activity feed
GET  /api/safety-rules                     Read-only view of config/safety.rules

Skills & Businesses
GET    /api/skills
POST   /api/skills             { id, name, version, systemPrompt, tools, guardrails }
PUT    /api/skills/:id
DELETE /api/skills/:id
POST   /api/skills/:id/sync    Re-read from /src/skills/:id/SKILL.md
 
GET    /api/businesses
POST   /api/businesses
PATCH  /api/businesses/:id
DELETE /api/businesses/:id

### 5.3 Database
The server uses a single SQLite database file (wearable.db / wearable.db). All tables use CREATE TABLE IF NOT EXISTS for idempotent migration. Key tables:
Table
Purpose
scheduled_tasks
Cron schedules: id, name, cron, message, channel, chatId, enabled, next_run_at, last_run_at.
pinned_memory
User-pinned memory facts that never decay.
hive_mind
Last N cross-agent activity entries (ring buffer).
plugin_enabled
Which KelvinLee-compatible plugins are enabled per business.
devices
Connected wearable devices: id, name, hands_free_mode, last_seen.
voice_profiles
Owner voice enrollment records per device.
businesses
Multi-business records: id, name, vault_root, default_main_agent_id, budgets, tool_allowlist.
skills
Skill definitions: id, version, system_prompt, tools, guardrails, vault_refs.
role_skills
Junction: which skills are granted to which roles.

## 6. How Everything Connects
### 6.1 Full Request Flow (voice to response)

Step
What happens
Component
1
User presses wearable button.
Firmware (button.c) → BLE AGENT_REQUEST characteristic
2
App receives BLE event; forwards to server.
device_bridge.dart → POST /api/device/event
3
Server opens 60-second capture window for this device.
ws-audio.ts: markAgentRequestAt()
4
Wearable streams Opus audio over BLE.
Firmware transport.c → BLE audio characteristic
5
App forwards binary audio frames to server WebSocket.
device_bridge.dart → WS /api/device/ws/audio
6
Server gate: inside capture window → decode → Deepgram STT.
ws-audio.ts frame handler + stt.ts
7
Utterance assembled. isOwner flag set from voice profiles.
stt.ts onUtterance()
8
wearable/device.audio.final event emitted with transcript.
stt.ts → Inngest
9
Orchestrator intake(): security gate + memory stack assembly.
orchestrator.ts
10
wearable/agent.prompt { role:"main" } emitted.
orchestrator.ts → Inngest
11
Dispatcher creates task store: TASK.md + contract.json + trace.jsonl.
dispatcher.ts
12
Claude Code worker invoked with assembled system prompt.
claude-worker.ts
13
CoS responds. If delegation tokens present, child tasks enqueued.
dispatcher.ts: parse @role: tokens
14
Specialist agents run concurrently (comms, ops, etc.).
Inngest parallel steps
15
All children complete. CoS re-entered to compose final response.
inngest/result.ts
16
RESPONSE.md written. wearable/agent.result emitted.
harness artifact writer
17
Delivery handler routes response to originating channel.
inngest/delivery.ts
18
App receives response via SSE or polling. Boardroom thread updates.
WearableTaskProvider in app
19
LED: 3 green flashes. Haptic: two short buzzes. "Done."
ws command → device_bridge → BLE → firmware

### 6.2 File System Layout
/                                    Wearable server root
├── src/
│   ├── orchestrator.ts              Prompt intake + security gate
│   ├── harness/
│   │   ├── dispatcher.ts            Task creation + child dispatch
│   │   ├── inngest/                 Durable event handlers
│   │   ├── device/                  WebSocket audio, STT, voice profiles
│   │   ├── nlah/<role>/v1/SKILL.md  Per-role persona + skills
│   │   └── role-permissions.ts      Tool allowlists per role
│   ├── skills/<id>/                 Composable skill bundles
│   │   ├── SKILL.md                 Prompt fragment
│   │   └── manifest.json            Tools, guardrails, vault refs
│   ├── scheduler.ts                 Cron task runner
│   ├── dashboard.ts                 HTTP API router
│   └── dashboard-html.ts            Dashboard SPA (server-side rendered)
├── store/
│   └── tasks/<ulid>/run/
│       ├── contract.json            Frozen task spec (chmod 444)
│       ├── TASK.md                  Task description
│       ├── RESPONSE.md              Agent output
│       ├── trace.jsonl              Append-only event log
│       └── state/
│           ├── children.json        Child task IDs (if delegated)
│           ├── child-summaries.jsonl Child response excerpts
│           └── pending_input.json  Question waiting for user reply
├── config/
│   ├── safety.rules                 AgentSpec grammar (hot-reloadable)
│   └── karpathy-guidelines.md       Per-agent coding guidelines
└── devices/
    └── wearable-kelvinlee/
        ├── app/                     Flutter mobile app
        └── firmware/                Zephyr RTOS firmware

## 7. Implementation Roadmap
Work is split into four phases. Server phases must ship before their dependent mobile phases. Each phase is independently deployable.

Phase α — Server Foundation (must ship first)
Item
What it delivers
Est. effort
S-1
CoS auto-delegation: dispatcher parses @role: tokens from main's response, enqueues child tasks, merges results back into parent RESPONSE.md.
3–5 days
S-2
Task status + filter endpoints: GET /api/tasks?status=… derives status from on-disk state. pending_input.json schema. POST /api/tasks/:id/reply.
1–2 days
S-3
Schedule CRUD over HTTP: POST/GET/PATCH/DELETE /api/schedules wrapping existing scheduler.ts functions.
1 day
S-4
Voice-gated audio capture: capture window in ws-audio.ts. Hands-free mode flag in devices table. POST /api/device/hands-free. Voice profile enrollment endpoint.
2–3 days
S-5
Audit + observability: capture window open/close events, dropped frame counts, child dispatch events all logged to existing audit trail.
### 0.5 days

Phase β — Mobile App Rebuild (requires S-1 + S-2)
Item
What it delivers
Est. effort
M-1
Shell rewrite: collapse 4 tabs → 3 (Boardroom, Tasks, Schedules). Remove Agent Hub tab. Rewire navigation.
2 days
M-2
Boardroom tab: elevate chat/page.dart to primary surface. Persistent input bar with wearable mic button. Side sheet for past sessions. Inline TaskChip for delegation status.
2–3 days
M-3
Tasks tab: new tasks_ledger_page.dart reading from /api/tasks. Segmented control (Active/Needs Input/Done). Task detail with reply/cancel. Deprecate ActionItems.
2 days
M-4
Schedules tab: new schedules_page.dart. Cron picker widget. Create/edit/delete/run-now flow.
2 days
M-5
Voice enrollment rewire: repoint speech_profile/page.dart to POST /api/voice-profile instead of KelvinLee's endpoint.
1 day
M-6
Role-chip removal: delete Agent Hub page, remove all role-selection UI from routing sheet and conversation items. Routing is CoS-only.
1 day
M-7
Token convergence: diff wearable_theme.dart against dashboard CSS. Fix all colour/font/radius drift. Add wearable_tokens.dart constants file.
1 day
M-8
KelvinLee residue cleanup: replace all remaining "KelvinLee" strings with "Wearable". Audit assets, error messages, settings pages.
1 day

Phase γ — Wearable Integration (requires S-4)
Item
What it delivers
Est. effort
W-1
Button capture window: verify app correctly sends AGENT_REQUEST to server; server extends window. Double-press → TTS replay. Triple-press → cancel. Long-press → toggle hands-free.
0 days (server done in S-4; app wiring in M-2)
W-2
Hands-free flag: server flag in SQLite. App toggle in Settings → Wearable Advanced. LED indicator in app input bar.
### 0.5 days
W-3
Voice enrollment end-to-end: app guides through 3-sample recording via wearable, uploads to /api/voice-profile, shows success screen.
### 0.5 days

Phase δ — Skills & Multi-Business (can run in parallel with β)
Item
What it delivers
Est. effort
SK-1
Skills schema + registry: skills table in SQLite, /src/skills/registry.ts, first example skill (blog-writer).
1–2 days
SK-2
Skill injection into dispatcher: resolveSkillsForTask() merges prompt fragment + tools + guardrails into child task contract.
1 day
SK-3
Skills API + basic UI: /api/skills CRUD. Settings → Skills admin page in dashboard.
1–2 days
BIZ-1
Business isolation: businesses table, business_id column on tasks/memory/artifacts, BusinessContext plumbing through dispatch stack.
2–3 days
BIZ-2
Business switcher UI: dropdown in dashboard nav. /api/businesses CRUD. Per-business Chief of Staff sessions.
1–2 days


Total estimate
Server (α): 8–12 days. Mobile (β): 12–15 days. Wearable (γ): 1 day (mostly bundled). Skills + Business (δ): 6–10 days. Grand total: 27–38 dev-days. Realistic calendar at 1 dev, non-fulltime: 6–9 weeks.

## 8. Verification
Each capability below has a specific, runnable check. All checks should pass before a phase is marked shipped.

### 8.1 Agent System
Capability
How to verify
CoS auto-delegates
POST /api/chat with "draft email to Andrej and set a 7am reminder" → dashboard Kanban shows parent task + two child tasks (comms + ops). Parent RESPONSE.md references both children.
Delegation tokens NOT user-visible
Open app Boardroom. Send same message. No role picker shown. TaskChip appears inline with "Delegating" status.
Task filter endpoints
GET /api/tasks?status=active returns the task while running. After RESPONSE.md written, it moves to ?status=completed.
Pending input flow
Worker emits ASK_USER → task appears in app "Needs Your Input" segment → user types reply → task returns to Active → completes.
Cancel active task
While task running, POST /api/tasks/:id/cancel → task moves to failed in under 2 seconds.

### 8.2 Wearable
Capability
How to verify
Capture window gate
WS open, no button press, play audio near mic → journalctl shows audio_dropped events, zero utterances dispatched, zero Deepgram bytes sent.
Button opens window
Press AGENT_REQUEST → within 60 s, speak → utterance dispatched. After 60 s with no further press, audio drops again.
Double press = replay
After a completed task: double-press button → phone TTS reads the last response aloud.
Triple press = cancel
While task in-flight: triple-press → task moves to failed, LED shows red flash × 5.
LED vocabulary
Check each LED state against the table in §3.4 using a test script that forces each state.
Haptic patterns
Verify each haptic event against §3.5 by ear/hand.
Hands-free drops non-owner
Enroll owner voice, toggle hands-free ON, play TV audio near mic → journalctl shows utterances emitted on WS as isOwner:false but NOT dispatched to wearable/device.audio.final.

### 8.3 Mobile App
Capability
How to verify
Boardroom is tab 0
Fresh install → Boardroom is the first tab open. Tasks and Schedules are tabs 2 and 3.
Tasks tab reads server
Create task via Boardroom → appears under Active in Tasks tab. Completes → moves to Done. No Firebase reads.
Schedules CRUD
Create "Every morning at 7" in Schedules tab → row in SQLite scheduled_tasks → fires at 07:00 → last_run_at updates after pull-to-refresh.
No role chips anywhere
Open persistent input bar. No role selector. Long-press CoS message. No "re-route" option in menu.
Token convergence
Screenshot Boardroom + dashboard chat side-by-side → colours, font weights, and radii match exactly.

### 8.4 End-to-End Scenario

Full walkthrough test
## 1. Press wearable button and say: "Draft a thank-you email to Andrej about last week's paper and remind me every morning at 7 to re-check my inbox."
## 2. Verify: capture window opens (LED pulses emerald). Audio streamed. Utterance dispatched.
## 3. Verify: CoS task appears as Active in app Tasks tab. Two child tasks appear under it (@comms and @ops).
## 4. Verify: dashboard Kanban shows parent + children.
## 5. Verify: @comms completes — email draft in child RESPONSE.md. @ops completes — schedule created in scheduled_tasks table.
## 6. Verify: parent CoS task moves to Done. Final response in Boardroom thread summarises both outcomes.
## 7. Verify: Schedules tab shows new 07:00 entry.
## 8. Remove wearable. Play TV for 5 minutes. Run: journalctl -u wearable-core.service | grep utterance. Result: zero lines. Silence = pass.

## 9. Open Questions & Decisions
Capture these before starting Phase α. Each question has a current default — override as needed.

#
Question
Current default
Status
Q1
Should CoS be able to ask the user a clarifying question without delegating? (i.e. can "main" use ASK_USER independently of any delegation token?)
Yes — ASK_USER is a valid terminal state. pending_input.json is written; task pauses until user replies.
Decided
Q2
Hands-free mode default: on or off for new devices?
Off until explicitly enabled in Settings.
Decided
Q3
Conversation history side-sheet in Boardroom: retain or cut entirely?
Retain as side-sheet (swipe from left). Gives access to past sessions without giving them a tab.
Decided
Q4
Mobile Tasks tab layout: list (Active/Pending/Done) or Kanban columns?
Segmented list on mobile. Kanban stays on dashboard (screen real-estate).
Decided
Q5
Schedule message templates: basic placeholders only ({date}, {time}) or richer ({weather}, {email-count})?
Basic only in this phase. Richer templates require a template evaluator — deferred.
Decided
Q6
Wake word implementation: on-device keyword spotter or server-side?
On-device (lightweight model). No audio leaves the device until wake word fires.
Decided
Q7
Multi-business: when switching businesses in the app, should the Boardroom show the correct business's CoS thread automatically?
Yes — Boardroom thread is scoped to the active BusinessContext.
Open
Q8
Should the Delegation Ledger (hive mind) be visible to Kelvin in the app, or operator-only?
Settings → Wearable Advanced → Delegation Ledger. Not surfaced in main nav.
Decided

## 10. What This Is Not (Anti-Goals)
These are things that are explicitly out of scope for this product phase, to avoid scope creep.

	•	Not a multi-user system. Wearable is built for one owner (Kelvin). No accounts, no sharing, no permissions management for external users.
	•	Not a phone-first assistant. The phone app is secondary to the wearable for input. The app is the control plane and the screen; the wearable is the primary voice entry point.
	•	Not a replacement for Siri or Google Assistant. Wearable does not intercept system-level intents. It is a focused work assistant.
	•	Not a real-time streaming voice assistant. Responses may take 10–60 seconds depending on delegation depth. This is a deliberate trade-off for quality.
	•	Not cloud-dependent. All processing runs locally on the Wearable server (wearable-server.local). Cloud services (Deepgram, Claude API) are used for specific steps but no data is permanently stored externally.
	•	Not a marketplace. The skills system is for Kelvin's own capability bundles, not a public plugin store.
	•	Not building true speaker embedding (pyannote/speechbrain) in this phase. Hands-free mode uses Deepgram diarisation + session isOwner flag. Embedding-based matching is deferred.

## Appendix A — Design Tokens
All tokens are defined in devices/wearable-kelvinlee/app/lib/wearable/wearable_theme.dart and must match the dashboard CSS in src/dashboard-html.ts exactly.

Token
Value
Usage
background
#0A0A0A
Scaffold / page background
card
#141414
Default card surface
cardAlt / muted
#1F1F1F
Chips, tags, secondary surfaces
border
#333333
1 px hairlines on cards
foreground
#FAFAFA
Primary text on dark
mutedFg
#A0A0A0
Timestamps, labels, secondary text
primary (emerald)
#10B981
All interactive + brand elements
primaryGlow
#14C491
Glow effect on active FAB / status dot
onPrimary
#FAFAFA
Text/icon on primary-filled elements
destructive
#EF4444
Delete, error, cancel
warning
#F59E0B
Overdue, pending, low battery
info
#3B82F6
Informational badges, links
Font
Montserrat 400/500/600/700
All text (Google Fonts or bundled asset)
radiusSm
6 dp
Tags, chips, small badges
radiusMd
8 dp
Inputs, outlined buttons, search bar
radiusLg
12 dp
Cards, primary buttons, bottom sheets
