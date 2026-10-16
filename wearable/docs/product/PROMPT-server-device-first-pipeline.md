<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Server prompt — move Wearable to a device-first processing pipeline

Paste the section below to the server-side coding assistant.

---

## Context

Wearable is a privacy-first AI wearable. The phone already does **on-device STT** (Gemma 4) + **speaker diarization** (sherpa) — raw audio never leaves the device. We are changing the **device → server contract** so the phone becomes the **filtering boundary**: instead of POSTing every overheard utterance to the server and letting the server gate it, the device will **triage and distill locally** and send only:

1. **Explicit asks** — the user pressed the button, said a wake/trigger word, or typed in chat → sent immediately for an agent reply (today's `/api/device/text` with `overheard:false`, and `/api/chat`).
2. **Distilled ambient summaries** — periodically, the phone runs on-device Gemma over buffered ambient conversation and extracts structured items `{ notes, tasks, ideas }`, and sends only those — **never the raw transcript stream**.

The server's job shrinks from "filter the firehose" to "act on explicit asks + file the distilled items." This fixes three things at once: Wearable answering ambient/overheard speech, bystander speech leaking into `memory.md`, and bandwidth/cost.

## Server changes required

### 1. Expose trigger words to the device (read path)
You are already building user-editable **trigger words** (CRUD + store). The **device** needs to read the *enabled* phrases so it can do wake/intent detection **locally** before sending anything.
- Add **`GET /api/trigger-words`** (or extend the existing one) so it is readable with **device auth** (`X-Device-Id` + `X-Device-Token`), scoped to that device's business, returning `{ phrases: [{ id, phrase, enabled }] }` (enabled only is fine).
- The phone will poll/cache this and only treat ambient lines that match as "actionable."

### 2. New structured-digest ingestion endpoint
Add **`POST /api/device/digest`** (device auth, same headers as `/api/device/text`):
- Body: `{ at, sessionId?, items: { notes?: string[], tasks?: Array<{title, due?, detail?}>, ideas?: string[] }, sourceWindow?: {startedAt, endedAt} }`.
- Behavior (all **silent — no chat reply**): file `notes` → Obsidian (PRD R3 path), `tasks` → the task store / propose-calendar path (PRD R5), `ideas` → the Ideas inbox (PRD R4). Always curate salient facts to memory.
- Validate + cap sizes (e.g. ≤4 KB per item, ≤25 items). Audit each.
- Return `{ ok, filed: { notes, tasks, ideas } }`. This is the channel for the phone's on-device summaries — it must **never** trigger an agent conversation turn.

### 3. Finish the overheard gate (Bug B) — defense in depth
Even with device-side triage, any `overheard:true` turn that still arrives via `/api/device/text` must be handled silently:
- `overheard:true` → route to the ambient classifier (notes/tasks/ideas) / `curateOverheardTurn`, **never** emit an `assistant_message` to the chat thread, regardless of intent markers.
- Use the **trigger-words store** (same as §1) as the actionable signal, not the hardcoded `INTENT_MARKERS` regex.
- (Full spec already in `docs/PRD-bug-b-ambient-classify.md`.)

### 4. Chat message size
`POST /api/chat` rejects `message` > 8,000 chars / 16 KB body (413). The app now auto-sends long messages as a `.txt` attachment (works today), but please also **raise the inline cap** to ~32,000 chars and the body limit to ~64 KB so normal long prompts don't 413. Keep the attachment path working.

### 5. Image vision (already implemented client+server — confirm deployed)
The app uploads chat images via the existing two-step `/api/chat/uploads` → `/api/chat` (attachment IDs). A committed change (`feat(server): agent views image chat attachments via Read tool`) makes `appendAttachmentContext` instruct the agent to **Read** the image path so the vision-capable model sees it. **Confirm this is deployed + that the web chat role retains the `Read` tool.**

## New device → server contract (summary)

| Device sends | Endpoint | Auth | Server action |
|---|---|---|---|
| Explicit ask (button/wake/owner directive) | `POST /api/device/text` `{text, overheard:false}` | device | full agent dispatch + reply |
| Typed chat (+ optional files) | `POST /api/chat` (+ `/api/chat/uploads`) | bearer | full agent dispatch + SSE reply |
| Distilled ambient `{notes,tasks,ideas}` | **`POST /api/device/digest`** (NEW) | device | file silently, no reply |
| (fallback) raw overheard line | `POST /api/device/text` `{overheard:true}` | device | classify silently, no reply |
| Trigger-word pull | **`GET /api/trigger-words`** (device-readable) | device | return enabled phrases |

## Acceptance criteria
- The device can read enabled trigger words with device auth.
- `POST /api/device/digest` files notes/tasks/ideas into the right stores with **no** chat reply; verify via the stores + audit, not the chat.
- No `overheard:true` turn ever produces an `assistant_message`.
- `/api/chat` accepts a ~30k-char message inline; long ones still work via attachment.
- Image chat attachments are visible to the agent (Read), verified on a deployed build.
- Existing tests pass; new tests cover the digest endpoint (validation + filing + no-reply) and the device-readable trigger-words path.

## Non-goals / keep working
- Don't break the existing `/api/device/text`, `/api/chat`, `/api/chat/uploads`, `/api/device/event` behavior.
- On-device summarization (the Gemma distillation that produces the digest) is **app-side** — you only need to accept + file the result.
