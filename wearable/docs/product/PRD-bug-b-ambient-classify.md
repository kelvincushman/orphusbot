<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Server spec — Bug B: ambient/overheard turns must NOT get chat replies (classify instead)

**For:** the Wearable **server-side** coding assistant. **Status:** Draft v1 · 2026-06-08.
**Related:** the "user-editable trigger words" task (same `hasIntentMarker` gate) and PRD-wearable-agentic-cos R2.

## Problem
The wearable does **continuous ambient capture** (no physical button yet), so the phone transcribes everything it overhears (e.g. a YouTube video, nearby conversation) on-device and POSTs each utterance to `POST /api/device/text` with `overheard: true` (the app sets this correctly — continuous = overheard). Today these ambient turns get **answered in the chat**: Wearable replies to overheard content, cluttering the user's chat thread and acting on things they never asked.

## Root cause (confirmed)
`src/orchestrator.ts` overheard gate (~lines 199–222):
- `overheard === true && !hasIntentMarker(text)` → `curateOverheardTurn()` (memory only, **no reply**) — correct.
- `overheard === true && hasIntentMarker(text)` → **falls through to full agent dispatch** → the CoS runs and an `assistant_message` streams to the device chatId → shows in the app chat.

So any ambient line containing an intent phrase ("remind me…", "create…", "research…", "I need…", "help…") triggers a full agent reply. Ambient speech is full of these, so Wearable "answers the room."

## Desired behavior
Ambient/overheard turns should be **processed silently into the knowledge/action layer**, never produce a conversational chat reply. Only **explicit** input (typed in the app chat, or a wearable button press → `overheard:false`) gets an agent reply.

Specifically, for `overheard === true`:
1. **Never** emit a user-facing `assistant_message` to the chat thread.
2. Run the **ambient classifier** (PRD R2): extract from the transcript →
   - **meeting notes / useful context** → Obsidian (PRD R3),
   - **action items** → create tasks / propose calendar (PRD R5) — but **silently** (no chat reply); if details are missing, prefer a **habitat alert / pending confirmation** over a chat answer,
   - **ideas** → Ideas inbox (PRD R4).
3. Always curate ambient facts to memory (`curateOverheardTurn` — keep).
4. Optionally surface a non-conversational signal (a habitat LED/haptic, or a Mission-Control entry) when an action was created — but NOT a chat message.

## Implementation notes
- The `hasIntentMarker` gate should be **kept as a routing signal** but its TRUE branch must route to the **ambient classifier**, not `wearable/agent.prompt` with a chat reply. I.e. `overheard:true` never reaches the conversational reply path regardless of intent markers.
- **Trigger words integration:** read the enabled phrases from the new editable trigger-words store (the other task) instead of the hardcoded `INTENT_MARKERS` regex. A trigger-word match on an ambient turn means "this ambient line is actionable" → run the classifier/action path **silently**, still no chat reply.
- Explicit turns (`overheard:false`, from button press or the app chat composer) keep the current behavior: full dispatch + chat reply.
- Keep the device chatId mapping; just gate what streams back to it.

## Acceptance criteria
- An ambient utterance with an intent phrase (e.g. overheard "remind me to call the bank") produces **no chat reply**, but DOES create the task/note (or a pending confirmation via habitat alert) — verify via audit + the task/Obsidian store, not the chat.
- An ambient utterance with no intent → memory curation only (unchanged).
- A **typed chat message** or a **button-press (overheard:false)** turn → normal agent reply (unchanged).
- The actionable-ambient decision reads the **editable trigger-words store**, live (no restart).

## App side (already correct — no change needed)
The phone already sets `overheard:true` for continuous capture and `overheard:false` for button windows (`device_bridge.dart`). Ambient transcripts also show in the app's local **Transcripts** feed regardless. So once the server stops replying to overheard, the "Wearable answers the room" problem is fixed.
