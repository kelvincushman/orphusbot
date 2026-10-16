<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# PRD — Wearable App (personal AI, mobile)

**Status:** Draft v1 · **Date:** 2026-06-07 · **Owner:** Kelvin
**App:** `devices/wearable-kelvinlee/app` (Flutter, package `kelvinlee`, app id `com.wearable.app.dev`)
**Companion docs:** `docs/APP-NAVIGATION.md` (current screen map + §8 KelvinLee triage) · `docs/PRD-wearable-agentic-cos.md` (server side).
**Build approach:** **A — in-place strip & rebrand** (reuse the working pairing / unified chat / on-device Gemma / BLE `device_bridge`; delete dead KelvinLee screens per §8; restructure nav; rebrand).

> Name: **Wearable** (evolved from Wearable → Wearable — intended, not a typo).

---

## 1. Vision

Wearable is a **personal** AI wearable + phone app: a single owner, no accounts, data on your own paired Wearable server. The phone app is the **command surface** — talk to Wearable, see what the agents are doing, browse what Wearable remembered, and manage the wearable. The wearable captures conversation/ideas and gives habitat feedback (LED/haptic); the app is where you chat, confirm, and review.

**Loop:** capture (wearable/app) → Wearable classifies → notes/tasks/ideas → agents act / ask → you see it in **Chat**, manage it in **Tasks**, recall it in **Knowledge**, feel it on the **Wearable**.

---

## 2. Goals / Non-goals

**Goals**
- G1. **Zero-friction entry** for a single user: pair to Wearable once, optional device lock, no sign-in/onboarding.
- G2. **One unified conversation** across every channel (app, dashboard, wearable, Telegram), with a **Boardroom** view of agent orchestration.
- G3. Surface the agentic system: **Tasks** (act) and **Knowledge** (remember) as first-class, owner-editable.
- G4. Full **wearable** lifecycle: connect, on-device STT, capture modes, **habitat feedback (LED/haptic)**, firmware/OTA.
- G5. **Wearable** identity throughout; remove all KelvinLee cloud/marketplace/monetization cruft.

**Non-goals (v1)**
- Multi-user / accounts / cloud identity.
- KelvinLee apps marketplace, personas/Twitter clone, payments, KelvinLee cloud STT/usage.
- Desktop build (`lib/desktop` out of scope).

---

## 3. Entry & auth (no onboarding)

- **First launch → single "Pair to Wearable" screen:** server URL + pairing token, or **mDNS auto-discover**. Self-registers a device (`kelvinlee-XXXXXX`) and stores creds in `flutter_secure_storage` (existing `WearableClient` pairing flow, minus Google).
- **Optional local lock:** device **PIN / biometric** to open the app (privacy for personal data). Set in Settings; off by default.
- **No Firebase/Google sign-in, no multi-step onboarding.** Remove `OnboardingWrapper` (auth→name→language→permissions→review→welcome→find-device→speech-profile) and the KelvinLee "Get Started" + "Data & Privacy (cloud)" screens.
- **Permissions** (BLE, mic, notifications) requested **in-context** on first use, not as an onboarding gate.
- **Re-pair / Forget server / device identity** live in Settings (existing `WearableSessionServerPage`, rebranded).

---

## 4. Information architecture (navigation)

**Bottom bar = a center hero Chat button + 4 destinations + menu:**
```
[ Tasks ]   [ Knowledge ]   ( ● CHAT )   [ Wearable ]   [ ⚙ Menu ]
                        big round, raised, center
```
- **Center round button = Chat** (primary). Tap → Chat/Boardroom. **Long-press = quick voice ask** to Wearable (phone mic → on-device STT → system chat; mirrors the wearable button).
- **Menu** opens Settings + secondary items (not a primary destination).

---

## 5. Features

Each: **R#**, description, acceptance criteria (AC). App-owned unless noted "(server)".

### R1 — Chat (unified + Boardroom)  [center hero]
- One **unified thread system** shared across channels via the Wearable chat backend (SSE `/api/chat/stream`); messages from app/dashboard/wearable/Telegram appear in the same threads. Thread list/switcher.
- **Boardroom overlay:** live CoS→specialist routing + in-flight task chips on top of the active thread.
- Text input + **mic** (on-device STT). **Long-press center button** = quick voice ask.
- **Inline confirmation:** when an agent emits `ASK_USER`, the question appears in-thread with a reply affordance → `POST /api/device/reply` (server R7). Answer by text or voice.
- **AC:** a message sent in-app appears in the same thread as the dashboard/wearable; an agent ASK_USER is answerable inline and resumes the task; voice ask produces an on-device transcript that dispatches a turn.

### R2 — Tasks (act)  [merged Mission + Tasks + Schedules]
- One surface for: **to-dos** (create/edit/complete), **in-flight agent tasks** + course-corrections (today's Mission Control), and **recurring schedules** (cron). Segmented or sectioned.
- Owner can CRUD tasks/schedules; reflects the agent's task/calendar tools (server R5/R6) so app + agent share one source of truth.
- Tap a task → detail (status, response, children, pending-input reply).
- **AC:** creating a to-do in-app shows up server-side and vice-versa; a schedule can be created/edited/deleted; an in-flight agent task shows live status.

### R3 — Knowledge (remember)  [Obsidian-backed, via Wearable APIs]
- Browse the Wearable knowledge base (server-owned Obsidian vault) through read APIs (server R3/R4/R10): **Meeting notes**, **Conversation log/transcripts**, and the **Ideas inbox** (product/inspiration/tweet/ad).
- **Search** across notes/ideas. Tap an **idea → "Develop"** → routes to content/research agent (server R4); result returns to Chat.
- Read-first in v1 (create/edit notes is a fast-follow); deleting/curating is allowed.
- **AC:** meeting notes + ideas captured via the wearable/ambient pipeline appear here; "Develop" on an idea produces an agent draft surfaced in Chat.

### R4 — Wearable (device)
- **Connect/manage** the wearable (in-app BLE scan — not phone Bluetooth settings); status, battery, disconnect.
- **On-device Gemma:** model install/sideload/remove + state (now durable across restarts — `warmInstalledState` fix), capture mode **Button / Continuous**, the on-device transcription toggle (fix stale subtitle).
- **Habitat feedback:** command-poll → LED/haptic; **awaiting-input** alert rendering; a **habitat test** screen.
- **Firmware:** show FW version; **OTA update / flash Wearable firmware** (Seeed Xiao BLE Sense; DK2 base today).
- **AC:** connect to the wearable from the app; on-device STT survives an app restart (shows "Installed"); pressing the wearable button + speaking dispatches a turn; an agent `awaiting_input` lights/buzzes the device; firmware version is shown and OTA is reachable.

### R5 — Settings (menu) [rebranded Wearable]
Pairing/session (re-pair, forget), device lock (PIN/biometric), voice profile, on-device model, safety rules (read-only), developer/debug logs (keep local logs; remove KelvinLee cloud Developer-API), about Wearable. Strip all "Share KelvinLee", KelvinLee help, cloud copy.

### R6 — Firmware track (Wearable wearable)  [parallel, in v1]
Build + flash **Wearable Zephyr firmware** (`devices/wearable-kelvinlee/firmware/`, `xiao_ble_sense`) so the wearable has the **button**, **LED/haptic**, and the **agent-command characteristic** (`0xCAB1AB97`). Prefer **OTA** (the app exposes an update path) over nrfjprog where possible. Habitat feedback + button are only fully live with this firmware.

---

## 6. Removed / cut (per APP-NAVIGATION §8)
Google onboarding + all onboarding steps; KelvinLee "Get Started"/cloud Data&Privacy; **Apps marketplace** (`pages/apps/**`); **Usage Insights** (cloud, broken); **Storage/cloud-WAL** (superseded by on-device STT); **Payments / Persona / Twitter**; Conversations/ActionItems/Memories legacy screens (superseded by Chat/Tasks/Knowledge); all DEAD/ORPHAN KelvinLee pages. Verify no provider/state refs before deleting.

---

## 7. Server dependencies (from `PRD-wearable-agentic-cos.md`)
- Unified chat threads API (shared across channels) — confirm thread model.
- Knowledge read APIs: meeting notes, conversation log, **Ideas inbox** (R3/R4) + Mission Control write APIs (R10).
- **Confirmation reply** `GET /api/device/pending` + `POST /api/device/reply` (R7).
- **Habitat alerts** incl. `awaiting_input` (R8). Ambient classify→notes/tasks/ideas (R2–R5).
- `/api/device/text` (shipped). The app should degrade gracefully (read-only / disabled affordances) when an endpoint isn't deployed yet.

---

## 8. Milestones
- **M1 — Shell & entry:** remove onboarding/Google, pairing-only entry + optional lock, Wearable rebrand, new 4-tab + center-Chat nav, delete dead KelvinLee screens.
- **M2 — Chat unified + Boardroom + inline confirm:** wire unified threads, Boardroom overlay, ASK_USER inline reply, long-press voice.
- **M3 — Tasks + Knowledge:** merged Tasks surface; Knowledge (notes/transcripts/ideas + Develop) against server APIs.
- **M4 — Wearable + firmware:** durable on-device model (done), capture modes, habitat feedback rendering, **flash Wearable firmware**, OTA, end-to-end button + LED/haptic.

Each milestone: `flutter analyze` clean, targeted tests for new logic, build+install verify on device, review pass before any push.

---

## 9. Open questions
1. **Unified thread model:** does the server expose a single cross-channel thread store, or per-channel threads the app aggregates? (Drives R1.)
2. **Knowledge transcripts:** include raw conversation transcripts in v1, or notes/ideas only? (Leaning: include, read-only.)
3. **Note creation in-app:** v1 read-first, or allow creating/editing notes from the app in v1?
4. **Local lock:** PIN, biometric, or both; lock on every foreground or after timeout?
