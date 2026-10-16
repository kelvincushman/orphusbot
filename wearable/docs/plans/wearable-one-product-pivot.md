<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable Strategic Pivot — One Product, One Agent, Three Surfaces

**Status:** Proposal — awaiting approval
**Author:** Kelvin Lee (via Claude / Wearable agent harness)
**Created:** 2026-04-20
**Supersedes:** Per-screen rebrand plan (Chunks A–J shipped `b070989`…`72544f3`, now archival)
**Related docs:** `docs/PDD.md`, `docs/RUNBOOK.md`, `docs/plans/Wearable App Design System v1.0.docx`, `docs/plans/Wearable Per-Screen Implementation Spec v1.0.docx`, `CLAUDE.md`, `config/karpathy-guidelines.md`

---

## 1. Executive Summary

Wearable is one product distributed across three surfaces (dashboard SPA, mobile app, wearable device). Today it behaves like three products stitched together — different mental models, different data ledgers, different degrees of KelvinLee residue. This document consolidates the strategic pivot that returns the system to a single coherent product: **one Chief of Staff agent, one task ledger, one voice gate, three surfaces that all speak the same emerald/Montserrat boardroom language.**

The target is not a rewrite. It is a disciplined simplification + three concrete capability additions that the server doesn't yet have:

1. **CoS auto-delegation** — `main` role recursively dispatches to specialists without the user typing `@role:`.
2. **Unified task ledger over HTTP** — active / pending-input / completed + scheduled, with CRUD.
3. **Voice-gated wearable capture** — audio is never ingested without either a button press or a verified owner-voice match.

Everything else in this document (app nav collapse, drawer cleanup, badge removal, token convergence) follows from those three.

---

## 2. Why Now — The "3 Products" Symptom

Two parallel forensic audits (run 2026-04-20) confirmed:

### 2.1 The app stacks three mental models
- **KelvinLee-original:** Conversations + Action Items + Memories bottom tabs — all still reading from Firebase/KelvinLee cloud through `ConversationProvider`, `ActionItemsProvider`, `MemoriesProvider`.
- **Wearable-added:** Agents tab, 5-role WearableRoutingSheet with chips, WearableAgentBadge, AgentHubPage, contextual Ask-Wearable FABs, WearableDrawer with Hive Mind / Device Status / Dashboard targets.
- **Overlap & leakage:** Chat surface (`lib/pages/chat/page.dart`) is already a single-thread Messenger-style page but is buried 3 taps deep. The bottom nav is list-first, but the user's vision is thread-first. Every widget we added tonight made the **role routing more visible** — the exact opposite of the CoS-only model.

### 2.2 The server has the bones but not the connective tissue
- `main` role is scoped for orchestration (`role-permissions.ts:32-37`, `childDispatches: 4`, tools limited to Read/Grep/Glob/Respond), and the SKILL.md documents the `@role: …` delegation contract — but the dispatcher does not yet recursively enqueue a child task when `main` emits a delegation token. The SKILL file calls this out explicitly as "Phase 3".
- `store/tasks/<ulid>/` is the real task ledger. Endpoints exist (`GET /api/tasks`, `/api/tasks/:id`, `/api/tasks/:id/trace`) but there is no status filter (active / pending-input / completed), and KelvinLee's `ActionItems` are a *parallel ledger* that the app mistakenly shows to the user.
- `scheduled_tasks` SQLite table is populated by `bun run cli schedule --cron` and fires via `src/scheduler.ts::runDue()` on a per-minute Inngest tick, but there is **zero HTTP CRUD** surface. "Check emails every morning at 7" cannot be created without shelling into the VM.

### 2.3 The wearable is privacy-weak
- `src/harness/device/ws-audio.ts` accepts every binary frame whenever the device WS is open. There is no capture window, no button-press gate, no owner-voice gate.
- `src/harness/device/voice-profiles.ts` emits an `isOwner` flag on utterances based on enrolled profiles, but the flag is only *tagged* on downstream events — never used to *drop* audio before Deepgram.
- `wearable/device.button` with `code="AGENT_REQUEST"` flips an `overheard` flag (10-second lookback) for classification, not for recording. Capture continues regardless.
- **Result:** TV in the background for an hour = one hour of Deepgram bill + Obsidian writes that look like the user's conversation.

### 2.4 Three-product impact in one sentence
> "We have a dashboard operator sees at a desk, an KelvinLee app the user's phone thinks it has, and a wearable recording everything — and the user wants one boardroom that the wearable attends, the phone mirrors, and the dashboard archives."

---

## 3. Target Architecture

### 3.1 Conceptual model

```
                ┌───────────────────────────────────────────┐
                │          Chief of Staff (CoS)             │
                │          sole user-facing agent           │
                │  → parses intent                          │
                │  → delegates silently to specialists      │
                │  → owns the result + status transitions   │
                └───────────────────────────────────────────┘
                                │
              ┌────────┬────────┼────────┬────────┐
              ▼        ▼        ▼        ▼        ▼
           comms   content    ops    research   (future roles)

                ┌───────────────────────────────────────────┐
                │  Unified task ledger  (store/tasks/)      │
                │  status: active | pending_input | done    │
                │  +  scheduled_tasks  (cron)               │
                └───────────────────────────────────────────┘
                                ▲
               ┌────────────────┼─────────────────┐
               ▼                ▼                 ▼
         Dashboard SPA      App (pocket)     Wearable (ear)
         operator           Boardroom        button + voice
         console            thread + tasks   identity gating
```

### 3.2 Surface responsibilities

| Surface | Role | Primary use |
|---|---|---|
| Dashboard SPA | Ops console | Kanban + memory landscape + schedules admin + audit; desk view |
| Mobile app | Pocket boardroom | Chat with CoS, see tasks, manage schedules; on-the-go view |
| Wearable | Ear | Ambient context + user-voice capture on gate; always worn, rarely active |

### 3.3 Canonical user flow (single scenario that exercises everything)

1. User presses wearable button and speaks: *"Draft a thank-you email to Andrej about last week's paper and remind me every morning at 7 to re-check my inbox."*
2. Wearable BLE stack streams Opus → app `WearableDeviceBridge` → server `ws-audio.ts`.
3. Server gate: button press opened a 60-second capture window → frames flow to Deepgram → utterance with `isOwner=true`.
4. `wearable/device.audio.final` → orchestrator `intake()` → `wearable/agent.prompt { role: "main" }`.
5. CoS parses two intents: (a) email draft, (b) recurring reminder. Writes RESPONSE.md with two delegation tokens: `@comms:` + `@ops:` (schedule creation).
6. Dispatcher detects tokens, enqueues two child `agent.prompt` events tagged with the same sessionId + parentTaskId.
7. `@comms` drafts the email; `@ops` POSTs to `/api/schedules` to add the 7 AM cron. Both write RESPONSE.md.
8. Children resolve → parent task flips to `completed` with a summary reference to both child outputs.
9. App Tasks tab (Active) shows 3 rows briefly → flips to Done with children linked under parent. Schedules tab shows new row.
10. Dashboard Kanban reflects identical state; same RESPONSE.md viewer is reachable from both surfaces.
11. User removes wearable. TV plays evening news for one hour. `journalctl -u wearable-core.service -f | grep utterance` → **zero events**. *That silence is the product working.*

---

## 4. SERVER

### 4.1 Overview
The server is the spine. Every change below must ship before any mobile collapse is meaningful, because without CoS auto-delegation the simplified app is a lie.

### 4.2 CoS auto-delegation (S-1)

**Intent:** when `main` finishes an attempt with one or more `@role:` markers, dispatcher enqueues child tasks, waits on their results, and merges outputs back into the parent's RESPONSE.md before the parent is marked done.

**Files to modify:**

- `src/harness/dispatcher.ts`
  - After a successful attempt by `main`, scan RESPONSE.md for delegation tokens matching `/^@(comms|content|ops|research):\s*(.+)$/m` (one token per line).
  - For each token: emit `wearable/agent.prompt` with:
    ```ts
    {
      message: <token body>,
      role: <matched role>,
      parentTaskId: <current ulid>,
      sessionId: <inherit from parent>,
      businessId: <inherit>,
      chatId: <inherit>,
    }
    ```
  - Record child task IDs in parent's `state/children.json` (new file).
  - Mark parent status `awaiting_children` in `contract.json` extension; do not run any more attempts on the parent until all children resolve.

- `src/harness/inngest/prompt.ts`
  - Handle `parentTaskId` by linking the child to the parent in the task store (see S-3 status model).
  - Already calls `dispatcher.dispatch()`; no change to that call site.

- `src/harness/inngest/result.ts` (new OR extend existing)
  - When a child task emits `wearable/agent.result`, look up its `parentTaskId`. If parent exists and is `awaiting_children`:
    - Append child's RESPONSE.md excerpt (first 400 chars) to parent's `state/child-summaries.jsonl`.
    - If **all** children for parent are resolved (not just this one), re-enter the orchestrator for the parent with a synthesised "children complete" prompt so CoS can compose the final user-facing RESPONSE.md.
  - This creates a two-attempt flow for `main`: attempt 1 delegates, attempt 2 (after children resolve) finalises.

- `src/harness/role-permissions.ts` (no change — budget already supports 4 child dispatches)

- `src/harness/nlah/main/v1/SKILL.md`
  - Update §2 to state: "If delegation is needed, end the turn with one or more `@role: <subtask>` lines on their own line at the end of RESPONSE.md. The dispatcher will enqueue those specialists automatically and re-enter you when they've all responded. Never ask the user to type `@role:` themselves."
  - Add worked example: user request → first RESPONSE.md with two delegation lines → (system re-entry after children) → second RESPONSE.md summarising both.

**Edge cases:**
- Zero tokens in `main`'s first attempt → treat as terminal (today's behaviour).
- Infinite recursion (child is `main` again) → forbid via `childDispatches: 4` budget cap; if exceeded, fail parent with `BUDGET_EXCEEDED`.
- Child fails (non-zero exit, completion gate negative) → bubble failure status up to parent's summary; don't block other siblings.
- User sends a new message while parent is `awaiting_children` → queue via existing orchestrator `intake()` serialisation (per-devId single-flight already enforced).

**Tests (`tests/harness.test.ts`):**
- `main` with single `@comms: draft` token → two tasks in store, one linked as child, both reach `completed`, parent's final RESPONSE.md contains child reference.
- `main` with no tokens → single task, no child dispatch.
- Child budget exceeded → parent marked `budget_exceeded`, trace shows denial event.
- Two parallel delegation tokens → both children run concurrently under same Inngest step, both results merge.

### 4.3 Task status model + filter endpoints (S-2)

**Intent:** expose task state transitions over HTTP so the app's Tasks tab can render Active / Needs Input / Completed without scanning files.

**Schema extension (no SQL schema; derived from `store/tasks/<id>/`):**
Each task gets a `status` computed from on-disk state:
- `active` — `contract.json` exists, `RESPONSE.md` absent AND no `state/pending_input.json`.
- `pending_input` — `state/pending_input.json` exists (new file; see below).
- `completed` — `RESPONSE.md` exists AND `contract.json.ok === true` (or the completion gate passed).
- `failed` — `RESPONSE.md` absent after retries exhausted OR `contract.json.ok === false`.
- `awaiting_children` — `state/children.json` non-empty AND not all children resolved (from S-1).

**New `pending_input.json` schema:**
```json
{
  "question": "string — what we need the user to answer",
  "askedAt": 1776712345000,
  "expiresAt": 1776799999000,
  "kind": "confirmation | choice | free_text",
  "choices": ["optional array"]
}
```
Created by any worker that calls `ask_user()` (new utility). When the app POSTs `/api/tasks/:id/reply`, this file is deleted and the orchestrator re-enters with the user's answer merged into the prompt.

**New endpoints (`src/dashboard.ts`):**

- `GET /api/tasks?status=active|pending_input|completed|failed|awaiting_children&limit=N`
  - Scans `store/tasks/` sorted by mtime desc, derives status per task, filters, returns:
    ```json
    { "tasks": [{"id","role","chatId","status","createdAt","updatedAt","title","summary","parentTaskId?","childTaskIds?"}] }
    ```
  - `title` = first line of TASK.md; `summary` = first 200 chars of RESPONSE.md (empty if active).

- `GET /api/tasks/:id/detail`
  - Returns contract.json + RESPONSE.md raw + pending_input.json + children summary.

- `POST /api/tasks/:id/reply`
  - Body: `{ "answer": "<user text>" }`.
  - Only valid when status = `pending_input`. Deletes `pending_input.json`, re-enters orchestrator with the answer merged into the task's next prompt, marks the task active.
  - Returns 409 if already resolved.

- `POST /api/tasks/:id/cancel`
  - Sets `contract.json.cancelled = true`, prevents further attempts, marks `failed` with reason = `user_cancelled`.

**Completion condition integration:**
- Update `attempt-loop.ts` completion gate to write `state/pending_input.json` when a worker returns a special `ASK_USER` response shape: `{ kind: "ask", question, choices? }`.

**Tests:**
- Create task → GET `/api/tasks?status=active` includes it → complete task → GET `?status=completed` includes it, `?status=active` excludes it.
- Worker emits `ASK_USER` → task moves to `pending_input`, POST `/api/tasks/:id/reply` resolves it.
- Cancel while active → status flips to `failed`, subsequent attempts blocked.

### 4.4 Schedule CRUD over HTTP (S-3)

**Intent:** expose the already-working `scheduled_tasks` SQLite table via HTTP so the app (and the dashboard, if it still lacks it) can manage cron entries.

**Files:**

- `src/dashboard.ts` — add route handlers wrapping existing `src/scheduler.ts` functions:
  - `POST /api/schedules` — body `{ name, cron, message, chatId?, channel? }`, validates cron via existing `cron-parser`, inserts row, returns full schedule.
  - `GET /api/schedules` — returns all rows, ordered by `next_run_at ASC`.
  - `GET /api/schedules/:id` — single row.
  - `PATCH /api/schedules/:id` — update name/cron/message/enabled.
  - `DELETE /api/schedules/:id` — remove.
  - `POST /api/schedules/:id/run-now` — force-fire the schedule once, independent of cron (audit logged with reason `manual_run`).

- `src/scheduler.ts` — expose `updateSchedule(id, patch)` and `deleteSchedule(id)` if not already. `runOnce(id)` helper for the manual-run endpoint.

- `src/dashboard.ts` header section — register body limits + `requireWriteAuth` on the POST/PATCH/DELETE routes.

**Human-readable cron:**
- Use existing `cron-parser` to derive "next 3 fires" and return them alongside the raw cron expression so the app can render "Every day at 07:00 · next fires tomorrow 07:00, day after 07:00, …".

**Tests:**
- Create schedule → appears in GET list → next_run_at populated → after Inngest tick fires, last_run_at + last_ok update → audit row logged.
- Delete active schedule → future cron ticks don't fire it (row gone).
- POST run-now on a disabled schedule → returns 409.

### 4.5 Voice-gated audio capture (S-4)

**Intent:** never send audio to Deepgram without either an explicit button-press window OR an enrolled-owner voice match (hands-free mode, opt-in).

**Files:**

- `src/harness/device/ws-audio.ts`
  - Add `StreamState.captureWindowUntil?: number` (epoch ms).
  - `markAgentRequestAt(devId, now)` — extend: also set `captureWindowUntil = now + CAPTURE_WINDOW_MS` (default 60000, configurable via env `WEARABLE_CAPTURE_WINDOW_MS`).
  - In the binary-frame handler, BEFORE calling the decoder:
    ```ts
    const now = Date.now();
    const handsFree = state.handsFreeMode;
    const inWindow = (state.captureWindowUntil ?? 0) > now;
    if (!inWindow && !handsFree) return; // drop frame
    ```
  - Drop-counter metric: log every 1000 dropped frames (once per 10 s) so we can see the gate working.

- `src/harness/device/stt.ts`
  - In `onUtterance` post-diarisation: if `state.handsFreeMode && !u.isOwner`, return before `emitAudioFinal` (don't dispatch). Still **echo** the transcript back on the WS so the app can show "(overheard, dropped)" for UX honesty.

- `src/harness/device/registry.ts`
  - Persist per-device `handsFreeMode: boolean` flag (default false) in the existing `devices` SQLite table. New column `hands_free_mode INTEGER NOT NULL DEFAULT 0`.

- `src/harness/device/channel.ts`
  - New endpoint `POST /api/device/hands-free` (auth: pairing token) — body `{ enabled: boolean }` → updates row → state is picked up by the next WS connection.

- `src/harness/device/voice-profiles.ts` (no functional change — already emits `isOwner`; S-4 just wires the consumer)

**Enrollment: new Wearable endpoint (replaces KelvinLee's `/speech_profile`):**
- `POST /api/voice-profile` — body `{ samples: [<base64 PCM16 wav>], deviceId }`. Server validates (minimum 3 samples, ≥ 3 s each), runs Deepgram diarisation to cluster, writes to `voice_profiles` table with `is_owner = 1` for the first enrolled profile per device.
- `GET /api/voice-profile/:deviceId` — returns whether an owner profile exists and its enrollment timestamp.
- `DELETE /api/voice-profile/:deviceId` — clears the owner profile (user must re-enroll before hands-free works).

**Embedding-based matching (explicitly deferred):**
- True speaker identification (pyannote / speechbrain embedding comparison) is Phase 1.1b in `voice-profiles.ts:11-14` comments and is **not** part of this pivot. Button-press gating alone closes the worst privacy hole; hands-free with diarisation gives probabilistic owner filtering within a session, which is sufficient for a "hands-free on, I'm about to have a meeting" mode.

**Config knobs:**
- `WEARABLE_CAPTURE_WINDOW_MS` (default 60000) — how long a button press keeps the mic hot.
- `WEARABLE_HANDS_FREE_ALLOWED` (default true) — operator can forbid hands-free in strict privacy jurisdictions.
- `WEARABLE_VOICE_PROFILE_MIN_SAMPLES` (default 3) — enrollment quality floor.

**Tests:**
- No button press, WS open, frames flow → decoder never invoked, Deepgram never receives bytes.
- Button press → 60 s window opens → frames decoded and transcribed normally → after 60 s with no follow-up press, frames dropped again.
- Hands-free on, owner speaks → utterance dispatched. TV speaks → utterance emitted on WS as `isOwner=false` but NOT dispatched to `wearable/device.audio.final`.

### 4.6 Audit + observability (S-5)

- Every capture window open/close → `audit("capture_window", { devId, openedMs, closedMs, reason })`.
- Every dropped frame batch → `audit("audio_dropped", { devId, reason: "no_window" | "no_match", count, byteCount })`.
- Every child dispatch from S-1 → `audit("child_dispatch", { parentTaskId, childTaskId, role })`.
- Dashboard audit viewer already exists; no UI change.

---

## 5. MOBILE

### 5.1 Overview
The mobile app becomes the pocket boardroom: **Chat with CoS is the home screen.** Every other surface (tasks, schedules, threads history, admin) is secondary. The role-chips / Agent Hub / contextual Ask-Wearable FAB complex that tonight's rebrand built is largely deleted. Every visual token matches the dashboard exactly.

Ships **after S-1 and S-2** at minimum; voice-profile enrollment rewire (M-5 below) requires S-4.

### 5.2 Shell rewrite (M-1)

**File:** `devices/wearable-kelvinlee/app/lib/pages/home/page.dart`

**Before (today):** 4 bottom tabs — Conversations, Tasks, Memories, Agents — each a list; central FAB; Wearable drawer with 5 destinations.

**After:**
- 3 bottom tabs:
  1. **Boardroom** — default. Single-thread chat with CoS (see M-2).
  2. **Tasks** — unified ledger from `GET /api/tasks?status=…` (see M-3).
  3. **Schedules** — cron list + create/edit (see M-4).
- Bottom-nav icons: `forum_outlined` / `checklist_outlined` / `alarm_outlined`.
- FAB removed (Boardroom has its own persistent input bar).
- WearableDrawer stays but items reorganised:
  - Boardroom sessions (swaps current "Threads" concept — opens a side sheet, see M-2.3)
  - Device Status (unchanged from Chunk D)
  - Dashboard (unchanged)
  - Settings (pushes to upstream settings_drawer)
  - (Removed) Hive Mind from drawer → lives in Settings → Advanced → "Delegation ledger"
- WearableStatusDot + WearableInFlightBanner from Chunk A remain.

**Pages deleted outright:**
- `devices/wearable-kelvinlee/app/lib/wearable/pages/agent_hub_page.dart`
- `devices/wearable-kelvinlee/app/lib/wearable/pages/wearable_home_page.dart` (minimal stub, unused after chunks A-J; confirm no imports)

**Pages repurposed:**
- `lib/pages/conversations/conversations_page.dart` — not deleted, but **not mounted** as a bottom tab. Accessed only via Boardroom side sheet for "switch thread".

### 5.3 Boardroom tab (M-2)

**File:** `devices/wearable-kelvinlee/app/lib/wearable/pages/boardroom_page.dart` (new, wrapping existing `lib/pages/chat/page.dart`).

**M-2.1 Page structure:**
- Single-thread chat like Claude/Messenger. Uses existing `ChatPage` as the base widget — already has scroll controller, message bubbles, long-press menus, voice recorder.
- Elevates `ChatPage` from "accessed via icon" to primary surface. Reuses:
  - `lib/pages/chat/widgets/message_widget.dart` (AI message bubble)
  - `lib/pages/chat/widgets/ai_message_widget.dart`
  - Existing `MessageProvider` for persistence.
- Rewire chat backend: every message sent goes to Wearable `POST /api/chat` (existing endpoint; no role param — defaults to `main`). Streaming response is shown as the CoS response.
- Role chips on the routing sheet: **deleted** (see M-6).

**M-2.2 Persistent "Ask Wearable" input bar:**
- Pinned to bottom above the nav bar. Text input + mic button + send button.
- Mic button: if wearable connected AND enrolled, tap = open capture window on the wearable (POST to `/api/device/event { kind:"button", code:"AGENT_REQUEST" }`). If no wearable, use phone mic (existing phone mic path).
- Text input: auto-scrolls the thread, supports multi-line.

**M-2.3 Side sheet: thread history:**
- Swipe from left edge OR tap `Icons.menu_open_outlined` in app bar → opens `lib/pages/conversations/conversations_page.dart` rendered as a side sheet rather than a tab.
- Tap a past thread → replaces current Boardroom context with that thread's messages. A breadcrumb "Viewing past conversation" badge appears at the top; "Return to live" returns to the current CoS thread.
- This preserves the upstream KelvinLee conversation-browsing feature without giving it tab real-estate.

**M-2.4 In-thread task surfacing:**
- When CoS delegates, a compact `TaskChip` inline widget appears in the thread: `"Delegated · draft email · @comms · 23 s ago · running"`. Tap → task detail (M-3).
- When a delegated task completes, a follow-up message from CoS appears with the summary + links to the child tasks.
- Role `@` labels are **informational only** — not actionable; the user cannot pick them.

### 5.4 Tasks tab (M-3)

**File:** `devices/wearable-kelvinlee/app/lib/wearable/pages/tasks_ledger_page.dart` (new)

**M-3.1 Layout:**
- Top segmented control: **Active · Needs your input · Done**.
- Below: list of tasks for the selected segment.
- Pull-to-refresh calls the respective `GET /api/tasks?status=…`.
- Empty states per segment: *"Nothing active"*, *"Nothing needs your input"*, *"No completed tasks yet"*.

**M-3.2 Row shape:**
```
 [role-stripe colour 4dp]
 Task title (first line of TASK.md or synthesised from prompt)
 Summary (first 120 chars of RESPONSE.md, or "Working…" if active)
 Meta: status dot · last updated · parent task if child · role chip (small, greyed)
```
- Tapping opens `TaskDetailPage` (M-3.4).

**M-3.3 Needs-input tiles:**
- Inline reply box on each row. User types → POSTs `/api/tasks/:id/reply`. Row animates out of "Needs input" into "Active" while CoS processes.

**M-3.4 TaskDetailPage:**
- File: `lib/wearable/pages/task_detail_page.dart`
- Sections:
  - Header: task title + status + role + created/updated times.
  - Response: SelectableText of RESPONSE.md (or "Working…" if empty).
  - Children: list of child task rows if this is a parent (from S-1's `children.json`).
  - Trace toggle: expandable section showing `trace.jsonl` events (last 50).
  - Actions: Reply (if pending_input), Cancel (if active), Copy response to clipboard.

**M-3.5 Deprecating ActionItems:**
- `lib/providers/action_items_provider.dart` — keep the class (deep-link handlers still reference it) but stub its `getActionItems()` to return `[]` and remove the Firebase calls. Log a deprecation warning once per app launch.
- `lib/pages/action_items/` — no longer mounted. Deep links to specific action items redirect to the new Tasks tab with a snackbar: "Action items have moved to Tasks."

### 5.5 Schedules tab (M-4)

**File:** `devices/wearable-kelvinlee/app/lib/wearable/pages/schedules_page.dart` (new)

**M-4.1 Layout:**
- List of schedules from `GET /api/schedules`.
- Each row: name, human-readable cron ("Every day at 07:00"), next 3 fires (from server-computed preview), last run status (✅ / ❌ / never), toggle for enable/disable.
- FAB: `+` to create new schedule.

**M-4.2 Create / edit flow:**
- Bottom sheet: name input, cron picker (presets + advanced), message template input (supports `{date}`, `{time}` placeholders for the dispatched message), channel (default: Boardroom).
- On save: POST `/api/schedules` (or PATCH for edit). Refresh list.

**M-4.3 Cron picker widget:**
- File: `lib/wearable/widgets/wearable_cron_picker.dart` (new)
- Presets: "Every hour", "Every morning at X", "Every weekday at X", "Every Monday", "Custom cron".
- Custom toggle reveals a raw cron input with client-side validation (use Dart `cron` package or simple regex).

**M-4.4 Row actions:**
- Long-press: menu with Run now / Edit / Duplicate / Delete.
- Run now: POST `/api/schedules/:id/run-now` with confirmation dialog ("This will dispatch the schedule immediately, once").

### 5.6 Voice profile enrollment rewire (M-5)

**File:** `devices/wearable-kelvinlee/app/lib/pages/speech_profile/page.dart`

**Before:** calls KelvinLee's `/speech_profile` (api/speech_profile.dart).
**After:** calls Wearable's `POST /api/voice-profile` (S-4).

**M-5.1 Enrollment UX:**
- Unchanged visual flow — still "record these 3 phrases via your wearable".
- After each phrase, upload the captured PCM16 to Wearable endpoint. Server clusters + writes profile.
- Success screen: "Your voice is enrolled. Hands-free mode is now available in Settings → Wearable Advanced → Hands-free capture."

**M-5.2 Hands-free toggle:**
- New setting row in Wearable Advanced group: `Hands-free capture`.
- POSTs to `/api/device/hands-free { enabled }`.
- Description text under the toggle: *"When on, Wearable filters audio to your voice only (diarisation-based). When off, only the button press activates capture."*
- Warning banner if not yet enrolled: "Enroll your voice first" with a button that pushes `lib/pages/speech_profile/page.dart`.

### 5.7 Role-chip removal (M-6)

**Files:**
- `lib/wearable/widgets/wearable_routing_sheet.dart` — delete role chip row; sheet becomes just text input + mic. Internal `role = "main"` always.
- `lib/wearable/widgets/wearable_agent_badge.dart` — keep file (used internally in TaskDetailPage + Hive Mind operator view) but remove from: conversation list items, task tiles, memory cards, chat messages. Wearable `@role` attributions are internal metadata.
- `lib/wearable/pages/agent_hub_page.dart` — delete file, remove import from `lib/pages/home/page.dart`.
- All `showWearableRoutingSheet` call sites:
  - `lib/wearable/widgets/wearable_ask_fab.dart` — repoint to simplified sheet
  - `lib/pages/action_items/action_items_page.dart` — delete (page not mounted)
  - `lib/pages/conversation_detail/page.dart` — update "Ask Wearable about this conversation" to use simplified sheet
  - `lib/pages/memories/page.dart` — delete contextual FAB call (Boardroom input bar is the new entry)
  - `lib/wearable/pages/hive_mind_page.dart` — remove (Hive Mind moves to Settings → Advanced)

### 5.8 Token convergence (M-7)

**Intent:** app visual identity is a 1:1 mirror of the dashboard tokens. Not "close enough".

**Reference:**
- Dashboard CSS lives in `src/dashboard-html.ts` (inline) and `src/skills/ab-test-setup/` samples.
- Flutter tokens live in `devices/wearable-kelvinlee/app/lib/wearable/wearable_theme.dart`.

**Actions:**
- Diff every colour hex, font weight, radius, spacing between the two. Any drift > 0 → fix Flutter to match.
- Load Montserrat weights 400/500/600 explicitly (currently bundled; verify).
- Kill every remaining `Colors.deepPurpleAccent`, `AppStyles.backgroundSecondary`, etc. — replace with WearableColors equivalents.
- Refresh indicators: use `WearableColors.primary` (currently Conversations + Memories still show `Colors.deepPurpleAccent`).
- Add a Dart constants file `lib/wearable/wearable_tokens.dart` mirroring the dashboard's design-system variables 1:1 so future drift is auditable.

**Verification:** side-by-side screenshot of app Boardroom + dashboard chat view should be indistinguishable in colour + typography.

### 5.9 KelvinLee residue cleanup (M-8)

- Strings: "KelvinLee" → "Wearable" everywhere the user sees (already partially done tonight in chat_apps_dropdown_widget + chat/page.dart). Remaining sweep: splash/about page, shared preference labels shown in settings, error messages, firmware-update dialogs.
- Asset files: `assets/images/app_launcher_icon.png` — confirm it's the emerald Wearable icon (Chunk 7 said done; verify).
- Unused code paths: once action_items / conversations tabs are unmounted, audit for dead widgets imported nowhere.

---

## 6. WEARABLE

### 6.1 Overview
The wearable is the ear. Its job is to capture only when explicitly authorised (button press) or when the owner's voice is likely present (hands-free mode). Otherwise, every frame is dropped server-side before Deepgram bills a cent.

Firmware work in this pivot is minimal — the existing button + audio characteristic already does the right thing. The server is where the gating happens.

### 6.2 Button press = capture window (W-1)

**Files on the firmware side (no changes needed):**
- `devices/wearable-kelvinlee/firmware/devkit/src/button.c` already emits `AGENT_REQUEST` (code 6) on long or triple press.
- `devices/wearable-kelvinlee/firmware/devkit/src/transport.c` already notifies the button characteristic.

**App side:**
- `devices/wearable-kelvinlee/app/lib/wearable/device_bridge.dart` already forwards `AGENT_REQUEST` to Wearable via `POST /api/device/event`.
- No change needed.

**Server side (S-4):**
- `markAgentRequestAt(devId, now)` extends capture window by 60 s (configurable).
- Subsequent presses within the window reset the deadline (rolling window).

**UX in the app (M-2.2):**
- Mic button tap in the persistent input bar ALSO triggers a remote button press (same endpoint). So the user has two identical "start capture" affordances: physical button on wearable + mic icon in app.

### 6.3 Hands-free mode = owner-gated diarisation (W-2)

**Files:** S-4 handles this server-side; W-2 is the firmware/app state coordination.

**State:**
- Per-device flag in SQLite `devices.hands_free_mode`.
- Toggle via `POST /api/device/hands-free` (from app Settings → Wearable Advanced → Hands-free capture).

**Behaviour:**
- Flag on + enrolled owner profile exists → server passes all frames through Deepgram but drops utterances where `isOwner=false` before dispatch.
- Flag on + no enrolled profile → log warning, behave as flag off (button-only).
- Flag off → button-only gating.

**Indicators:**
- App Boardroom input bar shows a small 🎙 icon tinted emerald when hands-free is active. Tapping opens Settings.
- WearableStatusDot in appbar gains a secondary state `hands_free_active` (emerald with a slight pulse) to distinguish from plain `connected`.

### 6.4 Voice profile enrollment end-to-end (W-3)

**Flow (initiated from app):**
1. User navigates Settings → Wearable Advanced → Hands-free capture → "Enroll my voice".
2. App pushes `lib/pages/speech_profile/page.dart` (rewired in M-5).
3. App coordinates wearable recording of 3 phrases via existing `CaptureProvider.streamDeviceRecording()`.
4. Each sample uploaded to `POST /api/voice-profile { samples: [base64], deviceId }`.
5. Server clusters → writes owner profile → returns profile id + confidence.
6. Success screen → hands-free toggle becomes enableable.

**Failure modes:**
- Too much background noise during enrollment → server returns 422 `{ reason: "low_signal" }` → app shows "Try again in a quieter environment".
- Multiple voices detected in a sample → server returns 422 `{ reason: "multiple_speakers" }` → app re-records that phrase.

### 6.5 Device firmware follow-ups (separate from this pivot)

Not blocking; mentioned for completeness:
- **MCUboot OTA sysbuild** (existing task #7) — separate firmware update track.
- **Battery telemetry over BLE** — already present, surface on DeviceStatusPage (low-hanging, can piggyback on this pivot if time permits).
- **LED habitat-alert expansion** — already implemented (`src/harness/device/commands.ts` encodes LED/haptic); no change here.

---

## 7. Cross-cutting

### 7.1 Data model alignment (C-1)

Single source of truth for each concept:

| Concept | Source | Consumers |
|---|---|---|
| Tasks | `store/tasks/<ulid>/` | Dashboard Kanban + App Tasks tab (via `/api/tasks`) |
| Schedules | `scheduled_tasks` SQLite table | Dashboard admin + App Schedules tab (via `/api/schedules`) |
| Voice profiles | `voice_profiles` SQLite table | Server STT pipeline + App enrollment page |
| Conversations (legacy) | KelvinLee Firebase | App side-sheet only (secondary, read-only) |
| Memories (Karpathy) | `memory.md` per chatId | Server memory stack (internal) — not surfaced in app main flow |

### 7.2 Branding sweep (C-2)

- Purge "KelvinLee" strings from user-facing surfaces.
- Audit settings sub-pages, error toasts, notification titles.
- Replace any remaining `Colors.deepPurpleAccent` / `AppStyles.*` with WearableColors equivalents.

### 7.3 Documentation (C-3)

- Update `README.md` "Phases Shipped" to add Wearable/α–δ when each lands.
- New `docs/plans/wearable-one-product-pivot.md` (this file) lives as the single source of truth.
- Update `CLAUDE.md` with the CoS-auto-delegation model once S-1 lands (so the agent harness knows the new contract).
- User-facing walkthrough video recorded after Phase γ verifies end-to-end.

### 7.4 Rollback strategy (C-4)

Each phase shippable independently:
- Phase α (server) is backward-compatible: if the app still sends `@role:` manually, the server still handles it (just adds auto-delegation when the user omits the prefix).
- Phase β (app) can ship against an older server — the simplified shell just falls back to "no delegation occurred" messaging.
- Phase γ (wearable) defaults to button-press-only; hands-free is opt-in.

If a phase regresses, revert the single feature flag (e.g. `WEARABLE_COS_AUTO_DELEGATE=false`) without rolling back the deploy.

---

## 8. Sequencing + Effort

| Phase | Scope | Blocks | Estimated effort |
|---|---|---|---|
| S-1 CoS auto-delegation | Server dispatcher + Inngest handlers + SKILL.md | — | 3–5 d |
| S-2 Task status + filter endpoints | Server HTTP + schema derivation | — | 1–2 d |
| S-3 Schedule CRUD | Server HTTP wrapping existing scheduler | — | 1 d |
| S-4 Voice-gated capture | Server ws-audio + stt + voice-profiles endpoint | — | 2–3 d |
| M-1 Shell rewrite | App bottom nav collapse | S-1 | 2 d |
| M-2 Boardroom tab | Chat elevation + side sheet | M-1 | 2–3 d |
| M-3 Tasks tab | New page + detail | S-2, M-1 | 2 d |
| M-4 Schedules tab | New page + cron picker | S-3, M-1 | 2 d |
| M-5 Voice enrollment rewire | Repoint KelvinLee endpoint to Wearable | S-4, M-1 | 1 d |
| M-6 Role-chip removal | Delete widgets + update callers | M-1 | 1 d |
| M-7 Token convergence | Visual diff + fixes | M-1 | 1 d |
| M-8 KelvinLee residue cleanup | String + asset sweep | M-1 | 1 d |
| W-1 Button capture window | Server-side (same as S-4) | S-4 | 0 d (bundled) |
| W-2 Hands-free flag | Server + app toggle | S-4, M-5 | 0.5 d |
| W-3 Voice enrollment flow | Coordinated rewire | S-4, M-5 | 0.5 d |
| C-1 Data model alignment | Verify all consumers point at canonical sources | Above | 0.5 d |
| C-2 Branding sweep | Strings + colours | M-8 | 0.5 d |
| C-3 Docs | README + CLAUDE.md updates | All | 0.5 d |
| **Total** | | | **18–23 dev-days** |

Realistic calendar (1 dev, pivot not fulltime): **4–6 weeks**.

---

## 9. Verification Matrix

| Capability | How to verify |
|---|---|
| CoS auto-delegates | `curl -X POST .../api/chat -d '{"message":"draft an email to mom"}'` → dashboard Kanban shows parent + child; parent's RESPONSE.md references the child's draft. |
| Task filter endpoints | `curl /api/tasks?status=active` → non-empty while a task runs; flips to `completed` list after RESPONSE.md lands. |
| Schedule CRUD | App Schedules tab creates "Every 7 AM"; `ssh pai-server "sqlite3 wearable.db 'SELECT * FROM scheduled_tasks'"` shows the row; next_run_at within 24 h. |
| Capture window works | Start WS, no button press, play audio → `journalctl -u wearable-core.service -n 100 | grep 'audio_dropped'` shows drop events; zero utterances. |
| Button opens window | Press AGENT_REQUEST → within 60 s, speak → utterance emitted; after 60 s with no further press, frames drop again. |
| Hands-free drops non-owner | Enroll owner voice; toggle hands-free ON; TV plays speech → utterances emitted on WS with `isOwner:false` but NOT dispatched as `wearable/device.audio.final`. |
| App Boardroom is home | Fresh install → Boardroom tab is tab 0 and open by default. Tasks + Schedules tabs secondary. |
| Role chips gone | Open persistent input bar. No role selector visible. Long-press a CoS message → no "re-route to" menu (feature cut). |
| Tasks tab renders server data | Create a task via Boardroom → appears under Active → moves to Done when resolved. No reads from KelvinLee cloud. |
| Schedules tab renders server data | Cron row created in app → same row in `scheduled_tasks` table → fires at scheduled time → last_run_at updates visible via pull-to-refresh. |
| Token convergence | Screenshot Boardroom + dashboard chat side-by-side → hex colours + font weights match within design-system tolerance. |
| End-to-end scenario (§3.3) | Walkthrough: wearable button → spoken request → CoS delegates → draft email task + schedule task land in app → dashboard mirrors → TV in background causes zero captures. |

---

## 10. What NOT to do (anti-goals for this pivot)

- **Don't build an ActionItemsPage replacement.** It's being retired. Tasks tab is the one place.
- **Don't add Memory source filter chips.** More list-first complexity when the target is Boardroom-first.
- **Don't add Hive Mind live data fetch UX.** It was a drawer destination; in the pivot it becomes a developer-only Settings → Advanced "Delegation ledger". Fetch logic can come later if needed.
- **Don't ship per-role View History.** The user doesn't pick roles, so per-role history is wrong abstraction.
- **Don't rewrite KelvinLee's MessageProvider or ChatPage internals.** Wrap them; the bubble widgets are mature.
- **Don't implement true speaker embedding (pyannote/speechbrain).** Deferred to Phase 1.1b. Button-press gating + diarisation is sufficient for the privacy posture today.
- **Don't ship production RevenueCat keys.** Sandbox is fine until product shape stabilises.
- **Don't delete `action_items_provider.dart` outright in Phase M.** Stub to empty to avoid breaking deep-link + notification handlers. Delete in a future cleanup once those callers are migrated.

---

## 11. Open Questions for User

Capture here; to be resolved before starting S-1:

1. **CoS end-of-turn contract:** should `main` ALWAYS end with either a final answer or a delegation token, or can it ask the user a clarifying question without delegating? (Implied answer: yes, ASK_USER is a third terminal state — via pending_input.json.)
2. **Hands-free default:** off until explicitly enabled? (Current plan: yes.)
3. **Conversation-history side-sheet:** is past-thread browsing useful to retain at all, or drop entirely? KelvinLee's conversation-list UX is quite different from the boardroom-thread mental model. Could be a cleaner cut than a side-sheet.
4. **Dashboard parity:** the app mirrors dashboard tokens, but should the mobile Tasks tab look like the dashboard Kanban (5 columns) or like a list? Mobile screen real-estate says list; boardroom vibe says Kanban-like. Current plan: segmented list (Active/Pending/Done).
5. **Schedule message template:** how much templating power? The minimum is `{date}`, `{time}`. Do we want `{weather}`, `{email-count}`, etc.? If yes, Wearable needs a template evaluator before the scheduled dispatch. Current plan: basic placeholders only in this pivot.
6. **Role attribution in Boardroom thread:** show the inline TaskChip ("delegated to @comms") in the thread, or hide entirely? Spec §Screen 1 implies show; user's vision says CoS-only UX. Compromise: show the TaskChip (it's a status indicator, not a routing choice) but never present @role as a picker.

---

## 12. Appendix A — Full File Change Map

### 12.1 Server — new files

| Path | Purpose |
|---|---|
| `src/harness/inngest/result.ts` (if not existing) | Handler for `wearable/agent.result` that resolves parent `awaiting_children` status |
| `src/harness/device/voice-profile-enroll.ts` | Enrollment endpoint logic wrapping voice-profiles.ts |

### 12.2 Server — modified files

| Path | Change |
|---|---|
| `src/harness/dispatcher.ts` | Parse `@role:` tokens from `main`'s RESPONSE.md, enqueue child prompts, track in `state/children.json` |
| `src/harness/inngest/prompt.ts` | Thread `parentTaskId` through to dispatcher |
| `src/harness/nlah/main/v1/SKILL.md` | Document the delegation-token contract; forbid `@role:` from user-facing side |
| `src/harness/role-permissions.ts` | (No change — budget already right) |
| `src/dashboard.ts` | Add `/api/tasks?status=`, `/api/tasks/:id/detail`, `/api/tasks/:id/reply`, `/api/tasks/:id/cancel`, `/api/schedules` CRUD, `/api/voice-profile` CRUD, `/api/device/hands-free` |
| `src/scheduler.ts` | Export `updateSchedule`, `deleteSchedule`, `runOnce` helpers |
| `src/harness/device/ws-audio.ts` | Add capture window gate, drop-counter audit, handsFreeMode flag plumbing |
| `src/harness/device/stt.ts` | In onUtterance, drop isOwner=false dispatch when handsFreeMode=true |
| `src/harness/device/registry.ts` | Add `hands_free_mode` column to devices table |
| `src/harness/device/channel.ts` | Add `POST /api/device/hands-free` endpoint |
| `src/harness/device/voice-profiles.ts` | Expose enroll/list/delete functions used by new endpoint |
| `tests/harness.test.ts` | Add tests for CoS auto-delegation, task status derivation |
| `tests/scheduler.test.ts` | Add tests for HTTP CRUD wrappers |
| `tests/device.test.ts` (new or extend) | Capture window gate, hands-free filtering |

### 12.3 Mobile — new files

| Path | Purpose |
|---|---|
| `devices/wearable-kelvinlee/app/lib/wearable/pages/boardroom_page.dart` | Primary tab wrapping chat |
| `devices/wearable-kelvinlee/app/lib/wearable/pages/tasks_ledger_page.dart` | Unified Tasks tab |
| `devices/wearable-kelvinlee/app/lib/wearable/pages/task_detail_page.dart` | Task detail incl. reply/cancel |
| `devices/wearable-kelvinlee/app/lib/wearable/pages/schedules_page.dart` | Schedules tab |
| `devices/wearable-kelvinlee/app/lib/wearable/pages/schedule_edit_sheet.dart` | Create/edit sheet with cron picker |
| `devices/wearable-kelvinlee/app/lib/wearable/widgets/wearable_cron_picker.dart` | Cron picker widget (presets + advanced) |
| `devices/wearable-kelvinlee/app/lib/wearable/widgets/wearable_task_chip.dart` | Inline delegation status chip in Boardroom messages |
| `devices/wearable-kelvinlee/app/lib/wearable/widgets/wearable_boardroom_input_bar.dart` | Persistent Ask-Wearable input at bottom of Boardroom |
| `devices/wearable-kelvinlee/app/lib/wearable/services/wearable_tasks_service.dart` | HTTP client wrapping `/api/tasks*` |
| `devices/wearable-kelvinlee/app/lib/wearable/services/wearable_schedules_service.dart` | HTTP client wrapping `/api/schedules` |
| `devices/wearable-kelvinlee/app/lib/wearable/providers/wearable_tasks_provider.dart` | ChangeNotifier backing TasksLedger |
| `devices/wearable-kelvinlee/app/lib/wearable/providers/wearable_schedules_provider.dart` | ChangeNotifier backing Schedules tab |
| `devices/wearable-kelvinlee/app/lib/wearable/wearable_tokens.dart` | 1:1 mirror of dashboard CSS tokens |

### 12.4 Mobile — modified files

| Path | Change |
|---|---|
| `devices/wearable-kelvinlee/app/lib/pages/home/page.dart` | Collapse 4 bottom tabs → 3 (Boardroom, Tasks, Schedules); swap mounted widgets |
| `devices/wearable-kelvinlee/app/lib/main.dart` | Register new providers (tasks, schedules) |
| `devices/wearable-kelvinlee/app/lib/wearable/widgets/wearable_routing_sheet.dart` | Strip role chips; pure text+mic sheet |
| `devices/wearable-kelvinlee/app/lib/wearable/widgets/wearable_ask_fab.dart` | Remove (all callers deleted or moved) |
| `devices/wearable-kelvinlee/app/lib/wearable/widgets/wearable_drawer.dart` | Reorder items; remove Hive Mind to Settings → Advanced |
| `devices/wearable-kelvinlee/app/lib/wearable/pages/hive_mind_page.dart` | Move to `lib/wearable/pages/settings/delegation_ledger_page.dart`; hidden from drawer |
| `devices/wearable-kelvinlee/app/lib/pages/settings/settings_drawer.dart` | Add hands-free toggle; add Delegation ledger under Advanced |
| `devices/wearable-kelvinlee/app/lib/pages/speech_profile/page.dart` | Repoint enrollment to `/api/voice-profile` |
| `devices/wearable-kelvinlee/app/lib/pages/chat/page.dart` | Expose as primary via BoardroomPage wrapper; strip "KelvinLee" labels |
| `devices/wearable-kelvinlee/app/lib/providers/action_items_provider.dart` | Stub methods to no-op + log deprecation |
| `devices/wearable-kelvinlee/app/lib/pages/action_items/action_items_page.dart` | Unmount (not deleted yet — keep for deep-link routing with redirect snackbar) |
| `devices/wearable-kelvinlee/app/lib/providers/conversations_provider.dart` | Narrow to side-sheet consumer only |
| `devices/wearable-kelvinlee/app/lib/providers/memories_provider.dart` | No change in this pivot; Memory tab removed from bottom nav. Page accessible via drawer if desired (TBD). |
| `devices/wearable-kelvinlee/app/lib/wearable/wearable_theme.dart` | Token diff against dashboard; fix drift |

### 12.5 Mobile — deleted files

| Path | Why |
|---|---|
| `devices/wearable-kelvinlee/app/lib/wearable/pages/agent_hub_page.dart` | AgentHub is not part of the CoS-only model |
| `devices/wearable-kelvinlee/app/lib/wearable/pages/wearable_home_page.dart` | Minimal stub, superseded by BoardroomPage |

### 12.6 Wearable — changes

No firmware source changes required for this pivot. All gating is server-side.

---

## 13. Appendix B — API surface summary (post-pivot)

```
Server endpoints consumed by app + dashboard:

  GET    /api/health
  POST   /api/chat                        { message }
  
  GET    /api/tasks?status=…&limit=N
  GET    /api/tasks/:id/detail
  POST   /api/tasks/:id/reply             { answer }
  POST   /api/tasks/:id/cancel
  GET    /api/tasks/:id/trace?limit=N
  
  POST   /api/schedules                   { name, cron, message, chatId?, channel? }
  GET    /api/schedules
  GET    /api/schedules/:id
  PATCH  /api/schedules/:id
  DELETE /api/schedules/:id
  POST   /api/schedules/:id/run-now
  
  POST   /api/voice-profile               { samples:[base64], deviceId }
  GET    /api/voice-profile/:deviceId
  DELETE /api/voice-profile/:deviceId
  
  POST   /api/device/event                { kind, code, at? }    (existing, wearable-side)
  POST   /api/device/hands-free           { enabled }            (new)
  GET    /api/device/ws/audio             (existing WebSocket)
  
  GET    /api/hive-mind?limit=…&role=…    (existing, operator-only)
  GET    /api/safety-rules                 (existing, read-only view)
```

---

## 14. Appendix C — Migration / deprecation notes

- **ActionItems**: classes remain but methods are empty-return. Adds `@Deprecated` annotation + one-time log on app launch. Removes from Phase M in one future release after deep-link audit.
- **Agent Hub**: deleted in M-6. External references (Hive Mind page, Agent meta list) remain — Hive Mind becomes Delegation ledger under Settings → Advanced.
- **Role chip callers**: route to simplified sheet. Existing `initialRole` parameter becomes no-op (ignored, left in for API stability within the app).
- **KelvinLee /speech_profile**: replaced by Wearable `/api/voice-profile`. Existing voice_profiles table remains canonical.

---

## 15. Acceptance Criteria (product)

A user who has never seen Wearable before should, within 2 minutes of opening the app:
- Understand that they talk to one agent (CoS) on the Boardroom tab.
- See any delegated tasks in the Tasks tab without needing to understand that delegation happened.
- Create a recurring schedule from the Schedules tab using a preset.
- Trust that the wearable is not listening until they press the button (indicated by absence of status dot "active" state).
- Recognise that the app looks like a smaller version of the dashboard they've seen on desktop.

A returning operator should, within 10 seconds:
- Know which tasks need their input.
- Know whether any scheduled task has failed recently.
- Hear dead silence in the logs when they walk away from the device.

---

*End of document. Any change request should append a dated note below this line and include the signature of the approver.*
