<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# PRD — Wearable Wearable: Agentic Capture & Chief-of-Staff Loop

**Status:** Draft v1 · **Date:** 2026-06-07 · **Owner:** Kelvin
**Audience:** Wearable **server-side** coding assistant (Bun/TypeScript backend on the Wearable VM).
**Boundary:** This PRD is for **server-side** work. The **Wearable** (Seeed XIAO) firmware,
the Flutter app, and on-device Gemma transcription are owned by the device/app team
(developed locally over ADB + flashed here) — they appear below only as **contracts**.

> Terminology: **"Wearable"** = the Seeed XIAO nRF52840 device (formerly "the kelvinlee/XIAO").

---

## 1. Vision

Wearable is a wearable + server that turns everything the owner says or thinks into
**memory, tasks, and completed work**, and signals back through the Wearable. The
Wearable is a **two-way** device:

- **Capture (in):** ambient conversation, explicit button requests, and ideas/thoughts.
- **Feedback (out):** habitat alerts (LED/haptic), including *"an agent needs your input."*

Wearable classifies each capture, writes durable knowledge to **Obsidian**, creates/edits
**tasks, notes, and calendar** via agent tools, drafts **emails/tweets/blogs**, runs
**research**, and **asks for confirmation** when details are missing — with the
**Chief of Staff (CoS)** agent orchestrating specialists.

---

## 2. Goals / Non-goals

**Goals**
- G-A. Turn ambient conversation into **meeting notes** (Obsidian) + **action items** (tasks/calendar).
- G-B. Route **explicit button requests** to the CoS to execute end-to-end (email draft, research, blog/tweet, reminders).
- G-C. Capture **ideas/thoughts** (product idea, inspiration, tweet, social-ad concept) into an **Ideas inbox** and optionally develop them (content/research).
- G-D. **Confirmation loop**: when the agent lacks details, it asks; the owner answers **from the Wearable** (button/voice).
- G-E. **Habitat feedback**: agents signal status + "need input" to the Wearable (LED/haptic).
- G-F. Everything created (notes, tasks, calendar) is **agent-accessible as tools** (create/edit/delete) and visible in **Mission Control**.

**Non-goals (v1)**
- Cloud STT replacement is optional; on-device Gemma is the default capture path (device team).
- Multi-user/business expansion beyond `default` (keep the isolation model, but single user for now).
- Real-time streaming agent responses to the Wearable beyond habitat alerts.

---

## 3. Current baseline (build on this — ~70% exists)

From the capability audit. Server assistant should **extend**, not rebuild.

| Area | Exists today | Key files |
|---|---|---|
| Device channel intake | `POST /api/device/event` (button), **`POST /api/device/text`** (on-device transcript — just deployed), `WS /api/device/ws/audio` (cloud STT), `POST /api/device/command/poll`, `register`, `list`, hands-free, voice-profile | `src/harness/device/channel.ts` |
| Turn dispatch | `deviceAudioPrompt`, `deviceTextPrompt`, `deviceButtonPrompt` → `wearable/agent.prompt` (channel=`device`, forces role=main) | `src/harness/inngest/device-prompt.ts`, `src/orchestrator.ts` |
| Ambient vs explicit | server-derived `overheard` flag; intent-marker heuristic; separate memory lanes | `src/orchestrator.ts:124,199`, `src/memory/karpathy.ts` (`main.md`/`overheard.md`) |
| Obsidian | per-day conversation logs (audio path diarized) | `src/harness/inngest/conversation-log.ts`, `src/memory/obsidian-writer.ts` |
| Habitat alerts (out) | `task_queued/running/awaiting_input/task_done/error/budget_warn` → command queue → app drains to `0xCAB1AB97` | `src/harness/device/commands.ts`, `src/harness/inngest/device-delivery.ts` |
| Confirmation | `ASK_USER:` → `wearable/agent.asked_user` → `pending_input`; delivered to web/telegram/discord | `src/harness/inngest/delivery.ts`, `src/harness/task-status.ts` |
| Agent tools | `gws_run` (Calendar/Tasks/Gmail/Docs/Drive/Sheets), `schedule_management`, `agent_management`, Firecrawl research, `Himalaya` email, ImageGen | `src/harness/tool-registry.ts`, `src/harness/role-permissions.ts`, `src/skills/*` |
| Roles | main(CoS), comms(email), content(blog/image), ops(deep ops), research | `src/harness/role-permissions.ts` |
| Mission Control | read-only aggregation of task state | `src/mission-control.ts` |

---

## 4. System overview & ownership

```
[Wearable] --BLE--> [Flutter app] --HTTPS--> [Wearable server] --> agents + tools
  mic/button/LED      on-device Gemma          classify+route      Obsidian / Tasks / Calendar / Email
   (FIRMWARE)          (APP)                    (SERVER ← PRD)      (SERVER ← PRD)
       ^------------------ habitat alerts (LED/haptic) <-- command queue <-----------'
```

- **FIRMWARE (device team):** mic audio (Opus/linear16), button events, LED/haptic execution of habitat commands, BLE GATT (KelvinLee service + `0xCAB1AB97` agent-command char).
- **APP (device team):** on-device Gemma transcription, `device_bridge`, `POST /api/device/text`, command-poll → LED/haptic, settings, on-device toggle.
- **SERVER (this PRD):** intake → classification → memory/notes → tasks/calendar → agent execution → confirmation → habitat-alert decisions.

---

## 5. Requirements (server-side)

Each: **[NEW]/[EXTEND]/[EXISTS]**, description, acceptance criteria (AC).

### R1 — Capture intake (EXISTS, verify)
`POST /api/device/text` + audio path dispatch to the agent path with `overheard` derived server-side.
**AC:** an authenticated `POST /api/device/text {text,at}` after a button press dispatches a non-overheard CoS turn; without a recent press it is treated as ambient. (Already deployed — confirm regression-free.)

### R2 — Capture classifier & router [NEW]
Add a server step that runs on **every** finalized capture (`wearable/device.text.final` and `wearable/device.audio.final`) and classifies the content into one or more of:
`{ explicit_request, action_item, meeting_note, idea }`.
- **explicit_request** (button press / imperative) → dispatch to CoS as today.
- **action_item** → R5 (task/calendar w/ confirmation).
- **meeting_note** → R3 (Obsidian meeting note).
- **idea** → R4 (Ideas inbox + optional develop).
Use a cheap model pass (e.g. the existing curator/classifier model) producing structured JSON; classification must be **conservative** for ambient/overheard turns (don't act on chit-chat).
**AC:** unit tests over representative transcripts produce the correct category set; ambient noise → no action; "remind me to call Alice Friday 3pm" → action_item with {title, due}; "we should get the team together next week" → action_item flagged `needs_confirmation`; "idea: a tweet about X" → idea(subtype=tweet).

### R3 — Meeting-notes extraction → Obsidian [NEW]
For `meeting_note` content, extract structured notes (summary, participants if known, decisions, action items) and write to `…/<business>/MeetingNotes/YYYY-MM-DD/<chatId-or-slug>.md` with YAML frontmatter; link action items to created tasks (R5).
**AC:** a meeting-style transcript yields a readable Obsidian note with the four sections + frontmatter; action items cross-reference task ids.

### R4 — Ideas inbox + develop [NEW]
For `idea` content, append to `…/<business>/Ideas/inbox.md` (timestamped, subtype: product|inspiration|tweet|ad|other). When the owner explicitly asks (or per a setting), route to a specialist: **content** to draft the tweet/ad/blog, **research** to validate a product idea — output saved as an artifact + summarized back.
**AC:** "idea: …" capture lands in `Ideas/inbox.md` with subtype; an explicit "draft that tweet" produces a content-agent draft artifact and a reply.

### R5 — Action items → tasks/calendar with confirmation [EXTEND]
From `action_item`, the CoS creates the right object via tools:
- reminder/todo → Google Tasks (`gws_run` tasks.insert) and/or the Wearable task ledger,
- time-bound → Calendar event (`gws_run` calendar insert),
- when **details are missing** (no time/attendees) → emit `ASK_USER` (R7) instead of guessing.
**AC:** "remind me to renew insurance Friday" → a task/event created without asking; "set up a meeting with Sam" (no time) → `ASK_USER` for time, no event created until answered.

### R6 — First-class agent tools for todo / notes / calendar [EXTEND]
Calendar + Tasks exist via `gws_run`; add a **dedicated `notes_management` tool** (create/read/update/delete notes in the Obsidian KB) symmetrical to `schedule_management`, and ensure todo/calendar are reliably exposed to CoS/ops with create/edit/delete. Expose via the tool registry + role permissions.
**AC:** CoS can, in one turn, create a note, create a task, and create a calendar event via tools; deletion/edit paths covered by tests.

### R7 — Confirmation loop incl. Wearable answer [EXTEND]
`ASK_USER` exists for web/telegram/discord. Add **device-channel** support:
- deliver the question to the device as an `awaiting_input` habitat alert (R8) + keep the question retrievable (e.g. `GET /api/device/pending` for the app to show/read it),
- accept the owner's answer from the Wearable via a new `POST /api/device/reply { taskId, text }` (device-token auth) that resumes the paused task with the answer in context.
**AC:** a CoS `ASK_USER` on a device turn surfaces `awaiting_input` + a retrievable question; `POST /api/device/reply` resumes and completes the task. (App/firmware own the button/voice capture of the answer; server owns the endpoint + resume.)

### R8 — Habitat feedback decisions (EXTEND)
Server-side alert mapping already maps results → alerts. Ensure:
- `awaiting_input` fires when a turn enters `pending_input` (not just on result),
- alerts distinguish ambient (no LED) from explicit (LED) — already partially done,
- the command queue stays per-device and idempotent.
**AC:** entering pending_input enqueues `awaiting_input`; completion enqueues `task_done`; overheard turns enqueue nothing. (Firmware renders them.)

### R9 — On-device text turns → Obsidian (diarized) [NEW, small]
`conversation-log` currently buffers utterances only for the audio path. Add capture for `wearable/device.text.final` so on-device text turns are logged with at least a single "Wearer" utterance (text, timestamp) rather than a bare user/assistant pair.
**AC:** an on-device text turn appears in the Obsidian Conversations log attributed to the wearer.

### R10 — Mission Control write surface [EXTEND]
Mission Control is read-only. Add HTTP APIs (operator/bearer auth) to list/create/edit/delete **tasks, notes, calendar events** so the dashboard + agent share one source of truth, and surface the Ideas inbox.
**AC:** dashboard can CRUD a task/note/event; agent tool calls and dashboard reflect the same store.

---

## 6. Device ⇄ Server contracts (do not break — app/firmware depend on these)

| Endpoint | Auth | Purpose | Status |
|---|---|---|---|
| `POST /api/device/register` | bearer | mint devId + pairing token | EXISTS |
| `POST /api/device/event` `{kind,code,at}` | device token | button (AGENT_REQUEST/SINGLE/…) | EXISTS |
| `POST /api/device/text` `{text,overheard?,at}` → `{ok,chatId}` | device token | on-device transcript intake | EXISTS (deployed) |
| `WS /api/device/ws/audio` | device token | raw audio (cloud STT fallback) | EXISTS |
| `POST /api/device/command/poll` → `{commands:[…]}` | device token | drain habitat LED/haptic commands | EXISTS |
| `GET /api/device/pending` → `{taskId,question}` | device token | fetch an open confirmation | **[NEW R7]** |
| `POST /api/device/reply` `{taskId,text}` | device token | answer a confirmation from the Wearable | **[NEW R7]** |

Security invariants (keep): device-token auth (constant-time), `channel:"device"` forces role=main, strip `@role:`/`@agent:` prefixes (S-3), body-size + per-device rate limits.

---

## 7. Data & storage

- **Obsidian vault** (`OBSIDIAN_VAULT_PATH/<business>/`): `Conversations/`, `MeetingNotes/`, `Ideas/inbox.md`. Existing memory: `main.md`, `overheard.md`.
- **Tasks/calendar:** Google Tasks + Calendar via `gws_run` (auth already configured) and/or Wearable task ledger; one canonical source surfaced in Mission Control.
- **Confirmations:** existing `pending_input.json` task state, extended with a device-retrievable question.

---

## 8. Milestones

- **P1 — Transport (DONE):** on-device transcript intake (`/api/device/text` + `deviceTextPrompt`) deployed.
- **P2 — Classify & route (R2, R3, R4, R9):** the brain — notes, ideas, action items.
- **P3 — Act & confirm (R5, R6, R7):** create tasks/notes/calendar; Wearable confirmation loop.
- **P4 — Feedback polish (R8, R10):** awaiting-input alerts; Mission Control write APIs.

Each milestone: `bun run typecheck` clean, `bun test` green (add tests per R), two-reviewer gate (typescript-reviewer + security-reviewer) on CRIT/HIGH, then deploy + restart guidance.

---

## 9. Out of scope for the server assistant (owned here — device/app team)
- Wearable **firmware** (Wearable Zephyr build: button, LED/haptic rendering of habitat commands, audio codec, `0xCAB1AB97`). Flashing.
- **App**: on-device Gemma transcription, `device_bridge`, settings, command-poll→LED, the button/voice **capture** of confirmation answers (server provides `/api/device/reply`).
- On-device model lifecycle (download/verify/install).

---

## 10. Open questions
1. Tasks/notes/calendar **canonical store** — Google Workspace (via `gws_run`) as source of truth, or a Wearable-native store mirrored to Obsidian? (Affects R6/R10.)
2. Idea **auto-develop** — always summarize-only, or auto-draft tweets/blogs by default? (Affects R4 cost/noise.)
3. Confirmation answer modality on the Wearable — button yes/no only, or voice answer (re-uses on-device Gemma)? (Server endpoint R7 supports text either way.)
