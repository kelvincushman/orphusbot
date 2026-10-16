<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable review findings

## Hardening phases summary (2026-04-26 to 2026-04-27)

**Phases 1–5** shipped as a coordinated hardening pass following the 9 original phases. Each phase addressed a distinct security or correctness domain and was reviewed by both `typescript-reviewer` and `security-reviewer` agents before merge:

1. **Phase 1** — Auth hardening (S-1, S-2, S-4): loopback bypass removal, mandatory WEARABLE_DASHBOARD_TOKEN at startup, `?token=` WS fallback block, LiveKit room/identity pinning, Math.random → crypto, XFF header spoofing fix, dev+0.0.0.0 rejection.
2. **Phase 2** — Agent sandbox (S-3, S-5, S-7): voice routing prefix-strip, Unicode-homoglyph sanitization on hive_mind, plugin-runner `allowedTools: []` enforcement, Obsidian symlink containment, atomic chmod 0o444 on contract.json, writeState key validation.
3. **Phase 3** — Dispatch loop correctness (S-5, S-6): stale RESPONSE.md detection + mtime guard, Inngest taskId memoization, businessId threading, atomic karpathy memory rename, 10MB output cap + SIGTERM→SIGKILL escalation, delivery channel handling, Obsidian scan caps.
4. **Phase 4** — Defense in depth: per-request CSP nonces (`'strict-dynamic'`, no `'unsafe-inline'`), sessionStorage token storage, JSON.parse guards, audit-log JSONL archive before prune.
5. **Phase 5** — PDD gap closure: Active Sessions card, floating chat FAB, Harness Replay tab, trace filter pills + sessionStorage persistence, POST /api/safety-rules with AtomicWrite + backup, ASK_USER → pending_input.json producer.

All phases hold 460/464 tests passing (4 pre-existing LiveKit env-dependent failures). Typecheck clean.

---

## Prior review pass (2026-04-18)

Three reviewers dispatched in parallel — TypeScript correctness, security, firmware+Flutter. Below is the full punch list with disposition: **fixed this pass**, **deferred** (needs design decision or deeper surgery), or **noted** (low priority / tracked).

Reviewer agents now live at `.claude/agents/{typescript-reviewer,security-reviewer}.md` — they're the canonical two-reviewer gate referenced in `CLAUDE.md` and are runnable via the `subagent_type` in future sessions.

---

## Fixed in follow-up pass (all deferred items + deeper tickets)

| ID | Title | File |
|---|---|---|
| TS-C2 | Overheard routing: `orchestrator.intake` now short-circuits `overheard:true` turns to `curateOverheardTurn` unless a first-person intent marker is present. Cheap regex (`INTENT_MARKERS`) — zero model-call cost. | `src/orchestrator.ts` |
| TS-H2 | Inngest step side-effects idempotent — `enqueueCommands` moved outside `step.run` in both device-prompt + device-delivery; retries no longer re-push alerts. | `src/harness/inngest/device-prompt.ts`, `device-delivery.ts` |
| TS-H3 | `captureBuffer` now keyed by `(chatId, sessionId)` with TTL check on read; `sessionId` plumbed through `wearable/device.audio.final` → `agent.prompt` → `agent.result`. | `src/harness/inngest/{conversation-log,device-prompt}.ts`, `client.ts`, `ws-audio.ts` |
| TS-H4 | Dropped `tableReady` cache in `plugins/loader.ts::ensureTable` — schema run on every call, matches `src/db.ts` pattern. | `src/harness/plugins/loader.ts` |
| TS-M5 | Button-prompt no longer dispatches a stub agent prompt. AGENT_REQUEST queues the habitat alert and waits for the matching audio-final (which IS now wired); no more duplicate dispatch per press. | `src/harness/inngest/device-prompt.ts` |
| SEC-H1 | WS pairing token moved to `Sec-WebSocket-Protocol` subprotocol (`wearable-token, <token>`). Server echoes the marker only, never the token. URL-query fallback kept for one cycle with warning log; client updated. | `src/harness/device/ws-audio.ts`, `devices/wearable-kelvinlee/app/lib/wearable/wearable_client.dart` |
| SEC-M1 | Plugin `metadata.full_output` now `sanitizeHiveField`'d before persist so prompt-injection from a hostile plugin can't reach a downstream consumer unchecked. | `src/harness/inngest/plugin-runner.ts` |
| SEC-M5 | Plugin runner gates on `checkBusinessBudget` pre-flight, enforces `CUMULATIVE_BUDGET_MS=60_000` across all plugins per turn, and calls `recordDispatchUsage` per plugin so `business_usage.dispatches` and `wall_clock_ms` now reflect plugin spend. | `src/harness/inngest/plugin-runner.ts` |
| FW-C3 | Single active audio stream per `WearableClient`: last-requester wins, old stream closed with code 4000 (`superseded by <owner>`). `openAudioStream` now requires an `owner:` tag (`'ble'` / `'phone_mic'`). | `devices/wearable-kelvinlee/app/lib/wearable/wearable_client.dart`, `device_bridge.dart`, `phone_mic.dart` |
| FW-C4 | `device_bridge.dart::_drainCommandQueue` re-checks `_running` after every await; audio listener re-reads `_audioWs` locally and drops frames silently instead of tearing the bridge down. | `devices/wearable-kelvinlee/app/lib/wearable/device_bridge.dart` |
| FW-H1 | `neopixel.c` state mutations serialised through `K_MUTEX_DEFINE(state_mutex)`. `pattern_tick` snapshots state under the lock, renders outside it. Protects against BLE-RX-thread vs system-work-queue race. | `devices/wearable-kelvinlee/firmware/devkit/src/neopixel.c` |
| FW-H7 | `FlutterSecureStorage` now uses `IOSOptions(accessibility: first_unlock_this_device)` + `AndroidOptions(encryptedSharedPreferences: true, resetOnError: true)` — credentials don't survive device migration / keystore corruption. | `devices/wearable-kelvinlee/app/lib/wearable/wearable_client.dart` |

Typecheck clean after each batch; test suite holds at 318/319 (same unchanged LiveKit env failure).

---

## Fixed in first pass (9 items)

| ID | Title | File |
|---|---|---|
| TS-C1 | Dead ternary in device-prompt; overheard turns now skip the LED-running signal entirely | `src/harness/inngest/device-prompt.ts` |
| TS-C3 | ws-audio supersede race — old close-handler no longer clears the new stream's slot | `src/harness/device/ws-audio.ts` |
| TS-H1 | `enrollProfile` demote + insert now wrapped in a SQLite transaction (no concurrent-owner race) | `src/harness/device/voice-profiles.ts` |
| TS-H5 | Removed dead `state.buffer` write-then-drain — emits one audio.final per Deepgram final | `src/harness/device/ws-audio.ts` |
| SEC-H2 | WebSocket upgrade gated by per-IP token bucket (20 + 1/s) — matches `/api/*` middleware | `src/harness/device/ws-audio.ts` |
| FW-C1 | Added `spi1_wearable_led_sleep` pinctrl with `low-power-enable` — no PM suspension leak | `devices/wearable-kelvinlee/firmware/devkit/overlay/wearable-peripherals.overlay` |
| FW-C2 | A2 IoT button ISR now submits to a `k_work`; `bt_gatt_notify` no longer runs from ISR context. Debounce bumped to 150 ms | `devices/wearable-kelvinlee/firmware/devkit/src/button.c` |
| FW-H3 | Pulse pattern no longer busy-polls forever on `durationMs=0` — stops after the pulse completes | `devices/wearable-kelvinlee/firmware/devkit/src/neopixel.c` |
| FW-H4 | NeoPixel brightness hard-capped at 180/255 in `write_rgb` — defensive against LDO brownout under SD-write + BT-TX + LED-full-white concurrency | `devices/wearable-kelvinlee/firmware/devkit/src/neopixel.c` |

Tests still 318/319 (the one unchanged LiveKit env-dependent failure). Typecheck clean.

---

## ~~Deferred (design-decision needed)~~  — ALL FIXED, see top

Kept below for historical context; every item listed here now has a disposition in the "Fixed in follow-up pass" table above.



### TS-C2 — Overheard turns still dispatch the user-intent agent + curator

The scaffolding is complete (`curateOverheardTurn`, `appendOverheardFacts`, separate `overheard.md`, 1 KB injection cap in `context.ts`) but nothing in the runtime actually routes an `overheard: true` turn to the overheard curator. `overheard` arrives on `wearable/device.audio.final` → `deviceAudioPrompt` → emits `wearable/agent.prompt` → full agent dispatch → `orchestrator.intake` calls `curateAfterTurn` (the explicit-intent curator) regardless of the overheard flag.

**Options:**
- **A.** In `deviceAudioPrompt`, short-circuit `overheard: true` away from agent dispatch — call `curateOverheardTurn` directly and emit a lightweight `wearable/overheard.captured` event. Pros: no wasted agent budget on ambient chatter. Cons: device never responds to "overheard" requests that would be useful (e.g. Kelvin talking to himself with "remind me to…").
- **B.** Gate in `orchestrator.intake` — dispatch normally but route the curator call based on the flag. Pros: one entry point, preserves agent response for overheard turns that happen to contain intent. Cons: every overheard turn still consumes agent budget.

Recommend **B** with a heuristic: agent is dispatched only if the transcript contains first-person intent markers ("remind me", "find X", "schedule", "note that", etc.). That's a Haiku-cheap classifier, similar to the skill router. Medium-sized change, deserves its own PR.

### TS-H3 — `captureBuffer` in `conversation-log.ts` keyed only by `chatId`

If two device turns for the same chatId overlap (plugin-runner result + device-delivery result both fire `agent.result` for the same chatId, or Inngest retries), utterances can attach to the wrong turn and land in the wrong Obsidian record.

**Fix:** plumb `sessionId` onto `wearable/device.audio.final` event data and through to `wearable/agent.result`, key buffer by `(chatId, sessionId)`. Also validate `Date.now() - capturedAt <= TTL` on the read side (expired entries currently pop silently with stale content).

~30 lines of changes across three files. Moderate risk if done carelessly — add a test that fires two simultaneous captures and verifies attribution.

### SEC-H1 — Pairing token in WS URL query (`?token=…`)

Query-string tokens can leak into access logs (current server doesn't have one but a reverse proxy or future journalctl change would capture them), proxy logs, browser history, `strace` of the node process. The HTTP device routes also accept `?token=` as a fallback.

**Fix:** move to `Sec-WebSocket-Protocol` subprotocol for WS auth (mirror Deepgram's own `["token", <key>]` pattern used in `stt.ts`), and strip `?token=` from HTTP fallbacks. Requires coordinated Flutter-side change in `wearable_client.dart::openAudioStream`.

Not urgent — Wearable has no request-logging middleware today, and tokens aren't echoed. But worth doing before the first production access-log lands.

### FW-C3 — Phone mic and BLE audio both open WS streams to the same devId

`ws-audio.ts` supersede logic was designed for reconnection, not arbitration between two active audio sources. If the user has both the BLE bridge (Opus) and phone mic (PCM) attempting to stream, whichever connected last wins, and the loser's frames silently disappear.

**Fix:** two options —
- **A.** Shared WS singleton in `wearable_client.dart`; BLE bridge and phone mic both request it, last-requester wins with visible UI log.
- **B.** Extend `/api/device/ws/audio` with a `source=ble|phone` query param + bookkeep on the server; real multiplex.

**A** is simpler and enough for v1 (Kelvin wears one device at a time). **B** is the real architectural answer if we ever add a laptop-mic secondary or a car microphone path.

### FW-C4 — `_agentCmdChar`/`_audioWs` mutated across async awaits in `device_bridge.dart`

Dart is single-threaded but async. `_drainCommandQueue` reads `_agentCmdChar`, awaits `_client.pollCommands()`, then iterates `cmdChar.write(...)` — if `dispose()` runs during any await, the handle is null or the BLE device is disconnected and writes throw `FlutterBluePlusException`. Same for the audio listener pushing to a closed sink.

**Fix:** re-check `_running` after every await; bail early. Copy `cmdChar` into a local only once and abort the iteration loop if `!_running`.

Small fix but best tested with a real device. Flagged for Phase 3's surgical wiring pass on Kelvin's dev machine.

### FW-H7 — `FlutterSecureStorage` defaults persist across Android reinstalls

On some Android builds, the Keystore alias `flutter_secure_storage` persists across uninstall → reinstall, so a reinstalled app can still decrypt prior pairing credentials. iOS Keychain default access group has similar persistence semantics.

**Fix:** pass explicit platform options — `IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device)` and detect first-run-after-install via `package_info_plus` build number, wiping credentials on change. Small fix, land with the rest of the Flutter wiring work.

---

## Deeper design tickets (follow-up work)

### TS-H2 — Inngest step side effects (`enqueueCommands`, `appendHive`) are not idempotent on retry

A step that completes then throws before the next step sees the next retry re-fire the side effects. For alert commands this means double-flashes; for hive audit rows it means duplicate entries. Long-term fix is sequence-tagged enqueue + server-side dedup on poll, or move non-idempotent side effects out of `step.run` and into post-dispatch.

### TS-H4 — `loader.ts::ensureTable` module-scope caching

Run `CREATE IF NOT EXISTS` unconditionally to match `src/db.ts` pattern and drop the `tableReady` cache. Small.

### TS-M5 — Button-prompt step fn fires stub even after WS audio lands

Button AGENT_REQUEST currently dispatches an immediate stub; when audio arrives right after, a second dispatch runs. Fix: `step.sleep(1500)` then check for a recent `wearable/device.audio.final` before firing the stub.

### SEC-M1 — Plugin output `metadata.full_output` in `hive_mind` is unsanitised

The 500-char `summary` is sanitised; `metadata.full_output` is stored raw. If any future consumer reads `metadata.full_output` back into a system prompt, prompt-injection from a malicious plugin lands uncontested. Either sanitise the full output too or drop it from metadata entirely.

### SEC-M5 — Plugin runner doesn't charge the business budget

`pluginRunner` calls `runAgent` directly and doesn't pass `businessId`, so curator-LLM spend on plugin output isn't counted toward `kelvin-personal`'s daily USD cap. Fix: thread `businessId` through to `runAgent` and cap cumulative plugin wall-clock per turn.

### FW-H1 — NeoPixel state machine races (pattern vs color vs tick_counter)

On nRF52840 (single-core) preemption between BLE RX thread and k_work can happen at any suspension point. The pragmatic fix is to have write handlers submit a state-update work item of their own — single-threaded mutation on the same queue. Medium refactor of `neopixel.c`.

### SEC-M4 / TS-L9 / various LOW — assorted

- Overheard sanitiser doesn't strip obvious injection patterns ("ignore previous instructions") — open question whether to harden or rely on DATA-framing.
- `conversation-log.ts::collate` double-reverses `recentTurns` output — cosmetic, code reads as fighting the helper.
- `dev.business_id ?? DEFAULT_BUSINESS_ID` is dead (`business_id` is `NOT NULL DEFAULT 'default'`).
- L2: `device_registrations` FK to `voice_profiles` has no `ON DELETE CASCADE`; `deleteDevice` silently fails with FK violation if profiles exist.
- L3: mDNS TXT leaks Wearable version — drop `version=` or bucket to major version only.

All flagged but not blocking.

---

## Wire format parity matrix (TS ↔ C ↔ Dart)

Verified by the firmware reviewer:

| Symbol | `commands.ts` | `agent_commands.h` | `command_codec.dart` | Status |
|---|---|---|---|---|
| Service UUID | `CAB1AB90-…` | `WEARABLE_CMD_SERVICE_UUID_VAL` | `CAB1AB90-…` | ✅ |
| Char UUID | `CAB1AB97-…` | `WEARABLE_AGENT_CMD_UUID_VAL` | `CAB1AB97-…` | ✅ |
| OP_LED_COLOR | 0x01 | 0x01 | 0x01 | ✅ |
| OP_LED_PATTERN | 0x02 | 0x02 | 0x02 | ✅ |
| OP_HAPTIC | 0x03 | 0x03 | 0x03 | ✅ |
| OP_STATUS_QUERY | 0x04 | 0x04 | 0x04 | ✅ |
| PATTERN_OFF..FLASH | 0x00..0x05 | 0x00..0x05 | 0x00..0x05 | ✅ |
| PATTERN_HAPTIC_SINGLE..LONG | 0x10..0x13 | 0x10..0x13 | 0x10..0x13 | ✅ |
| Duration endianness | BE u16 at [2..3] | `(pkt[2]<<8)\|pkt[3]` | `(v>>8)&0xFF, v&0xFF` at [2..3] | ✅ |
| Packet length | 4 bytes | `len != 4 → -EINVAL` | `Uint8List(4)` | ✅ |
| Haptic default pattern (missing in JSON) | `undefined & 0xff` → 0 | treats 0 as haptic default 120 ms | defaults to `SINGLE` (0x10) | ⚠ cosmetic drift — see MED M3 |
| Button AGENT_REQUEST | `"AGENT_REQUEST"` string over HTTP | `AGENT_REQUEST = 6` byte over GATT notify | `_ButtonCode.agentRequest = 6` → `"AGENT_REQUEST"` in HTTP payload | ✅ |

Every op code, pattern code, and endianness matches byte-for-byte across all three stacks. The only drift is a no-op cosmetic default that produces identical observable behaviour in v1.

---

## Praise (things to keep doing)

- **Pure-helper extraction** for bun/SQLite split (`alert-mapping.ts`, `prompt-format.ts`) is the right move, not a hack.
- **`PLUGIN_ID_RE` / `DEV_ID_RE` / `SKILL_ID_RE` sharing the same slug alphabet** reduces future foot-guns.
- **Plugin schema `.catchall(z.unknown())`** — correct choice for an integration-point schema that must round-trip upstream additions.
- **`conversation_index` composite PK + `ON CONFLICT DO UPDATE`** — idempotent, order-insensitive, no unique-constraint violations on retry.
- **Pairing token crypto** — 24 random bytes, SHA-256 hash, `timingSafeEqual` with length check first. Matches `src/security.ts`.
- **Wire-format parity discipline** across TS / C / Dart — every op + pattern + byte order checks out. This is the kind of thing that usually drifts and is painful to catch later.
- **`HABITAT_ALERTS` as a pure table** with `resolveAlert` returning `[]` for unknowns — right error posture for a device-facing mapping.

---

## Reviewer agents

Project-local definitions live at `.claude/agents/`:

- `.claude/agents/typescript-reviewer.md`
- `.claude/agents/security-reviewer.md`

Per `CLAUDE.md`'s "two-reviewer gate" rule — after any non-trivial code change, dispatch both in parallel and address every CRIT and HIGH before push. They're gitignored (local state) but should be treated as a committed operational contract — write them once, rely on them from every session.
