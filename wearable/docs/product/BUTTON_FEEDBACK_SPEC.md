<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable button + habitat feedback spec (v1.0)

Single source of truth for the **A2 single-button** scheme + the **LED/haptic feedback vocabulary** + the **byte protocol** + the **power state machine**. Firmware, app and server-contract all build against this.

Supersedes the Phase A scheme (short tap = Note, double = Ask, triple = Reply, hold 3 s on / 10 s off). **Every gesture row below has changed.** Nothing in the old table survives except the byte *values*.

Hardware: A2 IoT button = **P0.28** · NeoPixel WS2812 = **A3/P0.29** (GRB) · haptic motor = **D6/TX/P1.11**. NeoPixel brightness cap 180/255 (allow brighter on critical cues).

## The whole scheme in three rules

> **Tap = yes. Tap twice = no. Hold is power.**

State supplies the fourth dimension for free: a tap means *start talking* when idle, *stop and file* when listening, *yes* when alerting. Triple tap is a link-recovery hatch, not a product gesture. There is **no pairing gesture** — see §Pairing.

## Colour + haptic legend
🟢 green `(0,200,60)` good/on/done · 🔵 blue `(0,80,200)` working/listening · 🟠 amber `(220,140,0)` needs-you/warning · 🔴 red `(220,20,20)` error/off · ⚪ white `(180,180,180)` capture.
Haptic notation: `·`=tick ≈30 ms · `●`=120 ms pulse · `▬`=500 ms · `●●`=120/100/120 · `●●●`=triple · `ramp`=80/40/120 **rising** · `ramp↓`=120/40/80 **falling** (the deliberate inverse of `ramp`).

## Button gestures (A2)
Timings: tap ≤ 700 ms · multi-tap commit window 750 ms (commits immediately on the 3rd tap) · hold bands: **2 s** on, **4 s** off. A single tap commits only after the 750 ms window passes; the 1500 ms audio pre-roll (§App tunables) is what stops that costing the wearer their first word.

Every A2 release shorter than 700 ms fires `·` **immediately**, before the commit window closes. That is the mechanical click. It is state-neutral and means only "I felt that" — correct, because the firmware genuinely does not know what the tap meant.

### Power (firmware-local, no app involvement)

| Gesture | From | Action | Timings | Byte → phone |
|---|---|---|---|---|
| Press, release < 2 s | OFF | **Abort.** Back to System OFF, nothing happened | dark, then `sys_poweroff()` after 50 ms | — |
| Press, reach 2 s | OFF | Power **on**. Release is swallowed, never read as a tap. Must **never** chain into power-off | ticks 800 ms, 1600 ms; commit 2000 ms | — |
| Press, release 700 ms–4 s | ON | **Abort power-off.** Explicitly *not* a tap | — | `POWER_OFF_ABORTED` = 10 |
| Press, reach 4 s | ON | Power **off** — but only once the line goes high (§Power state machine) | ramp 1500 ms, tick 3000 ms, commit 4000 ms, cue 1100 ms, then wait for release ≤ 30 s | `POWER_OFF_ARMED` = 9 at 1500 ms · `POWER_OFF_COMMITTED` = 11 at 4000 ms |
| Any press ≥ 30 s | any | **Stuck-line latch.** Stop processing that press, resume on release | `A2_STUCK_MS` 30000 | — |

### Content (taps — meaning resolved by the app)

| Gesture | App state | Action | Byte → phone |
|---|---|---|---|
| Single tap | `IDLE` | **Start capture.** Mic opens, Opus → phone → Gemma. Intent inferred from the words, not the gesture | `CAPTURE_TOGGLE` = 7 |
| Single tap | `CAPTURING` | **Stop and file** | `CAPTURE_TOGGLE` = 7 |
| Single tap | `ALERT_PENDING`, alert is a **question** | **Acknowledge and open the mic** in one motion — just answer aloud | `CAPTURE_TOGGLE` = 7 |
| Single tap | `ALERT_PENDING`, alert is **informational** | **Acknowledge and dismiss.** No mic | `CAPTURE_TOGGLE` = 7 |
| Double tap | `CAPTURING` | **Cancel the note.** Buffer discarded, no transcript, no upload; recoverable on the phone for 10 min | `CANCEL` = 6 |
| Double tap | `ALERT_PENDING` | **Dismiss unactioned.** Nothing goes back to the agent | `CANCEL` = 6 |
| Double tap | `IDLE` | **Nothing.** Explicit safe no-op — never an error | `CANCEL` = 6 |
| Triple tap | link absent or stale (no `0xCAB1AB97` write in 30 s) | **Firmware-local link recovery.** Disconnect, restart connectable advertising. Acts unilaterally, because the reason you pressed it is that the app is wedged | `LINK_RECOVER` = 8 |
| Triple tap | link healthy | **App answers, firmware does nothing.** Never drops a healthy link, never kills a note | `LINK_RECOVER` = 8 |
| Any tap | ON, no BLE connection | Code is not delivered. **No watchdog armed** — 🟠 double-blink `·` locally, "you are not connected", not a generic error | *(undeliverable)* |

The app resolves a tap against the state at the **moment the notify was received**. State priority is `CAPTURING > ALERT_PENDING > IDLE`. Tie-break: if an alert became pending fewer than **300 ms** before the notify timestamp, the tap resolves against the **pre-alert** state — nobody reacts faster than that. Alerts arriving during `CAPTURING` queue silently and replay after filing; capture always wins.

### D5 (developer button)
Telemetry only. `SINGLE`=1 / `DOUBLE`=2 / `LONG`=3 / `RELEASE`=5 still notify; **no product behaviour, and no power action.** The old D5 single-tap `SYSTEMOFF` is **deleted** — uncued, unconfirmed power-off on a button worn against the body defeats every protection in this document, and "developer only" is not a mitigation while the device is being worn.

## Feedback groups (LED + haptic)

### A. Agent/task states (exist — reuse `HABITAT_ALERTS`)
| State | LED | Haptic |
|---|---|---|
| task_queued | 🔵 pulse 1 s | ● |
| task_running | 🔵 breathing | — |
| awaiting_input | 🟠 pulse (continuous) | ▬ once, then silent pulse |
| task_done | 🟢 flash 2 s | ●● |
| error | 🔴 flash 3 s | ●●● |
| budget_warn | 🟠 breathing | — |

### B. Power lifecycle (firmware-local)
| Moment | LED | Haptic |
|---|---|---|
| Holding 0→2 s to confirm on | 🔵 breathing (indefinite) | `·` at 800 ms, 1600 ms |
| On — "hi I'm here" (2 s) | 🟢 flash 800 ms | ● 150 ms |
| Released before 2 s | dark → System OFF | **none** — silence is correct, nothing happened |
| Holding toward off (already on) | 🟠 breathing from 1500 ms | `·` at 3000 ms |
| Power-off aborted (released 700 ms–4 s) | 🟢 blink 250 ms | **none** |
| Off (4 s, and line released) | 🔴 fade-out 1 s | ●● |
| Idle/armed | dark | — |

### C. Capture + acknowledgement acks (app-sent, ≤ 1500 ms after the code)
| Moment | LED | Haptic |
|---|---|---|
| Capture open | ⚪ blink, **duration 0** (persistent tell-tale) | `ramp` |
| Note filed | 🟢 double-blink 400 ms | ● |
| Acknowledge | LED off | `·` |
| Discarded / dismissed | 🟠 double-blink 400 ms | `ramp↓` |
| Idle double-tap (no-op) | ⚪ dim blink 150 ms @ 60/255 | **none** |

The white capture tell-tale is a **consent signal** — visible to people near you for the whole capture, and **non-suppressible**. No future battery optimisation may dim it or drop it.

`ramp↓` carries cancel: the owner does not memorise "double tap = cancel", he feels the thing he started being un-started. **Bench-test that the motor renders the inversion distinguishably at these durations before shipping.** If it cannot, keep the amber double-blink and fall back to `▬`.

### D. BLE connection (firmware-local)
| State | LED | Haptic |
|---|---|---|
| No link / searching | **🟠+🔵 alternating flash** (indefinite) | — |
| Just connected | 🟢 blink 250 ms | `·` |
| Connected + idle | dark | — |
| Link lost | 🟠 double-blink 400 ms → then searching | `·` |

There is no "pairing mode" row any more. See §Pairing.

### E. Notification tiers (phone → queued cmd, importance byte)
| Tier | LED | Haptic |
|---|---|---|
| low (FYI/note filed) | 🟢 double-blink | ● |
| normal (reply/reminder) | 🔵 flash 1.5 s | ●● |
| high (needs-you) | 🟠 pulse until answered | ▬ once |
| alert (error) | 🔴 flash 3 s | ●●● |

### F. Battery
| State | LED | Haptic |
|---|---|---|
| Low battery (cross threshold) | 🔴 slow breath | ● once |
| Charging | onboard charge LED (P0.17) — no NeoPixel | — |

## Pairing

**There is no pairing gesture. There is nothing to press, ever.**

`CONFIG_BT_SMP` is commented out (`prj_xiao_ble_sense_devkitv1.conf:36`, `-spisd.conf:32`) — there are **no bonds**, so there is nothing to clear and no `bt_unpair` to call. `transport.c` already advertises connectably and indefinitely at boot and after every disconnect. Pairing is a colour to **recognise** (🟠+🔵 alternating), not a gesture to recall. Do **not** add a discoverable timeout: it would turn an always-findable device into one that goes dark after two minutes.

Triple tap is a recovery hatch for a wedged link, not a pairing gesture.

## Firmware vs app — the split

**Firmware owns** (knows locally, acts unilaterally): debounce, tap counting, hold bands, all power state; the instant `·` on every sub-700 ms release; every power cue; BLE link truth and the link-recovery action; the 1500 ms app-confirmation watchdog; the 30 s stuck-line latch; waiting for the line to go high before sleeping.

**App owns** (only it knows): what a tap *means* — the whole `IDLE`/`CAPTURING`/`ALERT_PENDING` resolution; every semantic cue in group C; the utterance buffer, the 1500 ms pre-roll, transcription, the discards list; and disarming the watchdog.

**App-confirmation watchdog.** Firmware arms a **1500 ms** timer whenever it emits code 6, 7 or 8 *and a BLE connection exists*. Any write on `0xCAB1AB97` disarms it. On expiry it plays 🔴 flash 3 s + `●●●`. The confirmation **must** be written by the app locally on receipt of the notify, before any other work — never round-tripped through the server, because `_drainCommandQueue` polls on a 1 s timer and cannot make a 1500 ms deadline. When there is no connection at all the watchdog is skipped, so a disconnected device says "not connected" instead of "something went wrong".

## Power state machine
```
SYSTEM_OFF ──button edge──► POWER_BOOT_HOLD
POWER_BOOT_HOLD ── held 2 s ──► (green + ●) ──► POWER_ON
POWER_BOOT_HOLD ── released <2 s ──► SYSTEM_OFF   (swallow the release)
POWER_ON ── held 1.5 s ──► (amber ramp, emit code 9)
POWER_ON ── released 0.7–4 s ──► (green blink, emit code 10) ──► POWER_ON
POWER_ON ── held 4 s ──► (red fade + ●●, emit code 11) ──► POWER_OFF_PENDING_RELEASE
POWER_OFF_PENDING_RELEASE ── line goes high ──► SYSTEM_OFF
POWER_ON ── tap/double/triple ──► notify + group C/D cues ──► POWER_ON
```
- A2 (P0.28) is a **System OFF wake source** (`nrf_gpio_cfg_sense_set`, SENSE_LOW).
- **`POWER_OFF_PENDING_RELEASE` is not optional.** Because SENSE_LOW is armed while the button is still down, committing `sys_poweroff()` on a held line latches DETECT and the SoC wakes straight back up: power-off → instant wake → boot → ON. Wait for the line to go high (≤ 30 s, then force sleep).
- **`POWER_BOOT_HOLD` does not exist yet.** `button_init()` adopts a held A2 but never arms `a2_hold_armed` or seeds `a2_press_start_ms`, so `a2_track_hold()` never runs and the device is simply ON as soon as boot finishes. Until that is fixed the two OFF-state rows above do not run at all.
- **Nothing powers the device off on a timer.** An earlier draft of this spec had
  a 120 s unattended auto-off (on, no gesture committed, no BLE link since
  power-on → System OFF). It is deleted, by owner decision, because it contradicts
  what the device is for: there is a MicroSD card on the board, so a wearable with
  no phone in range is not abandoned — it is doing its job, recording locally and
  waiting to sync when the phone comes back into proximity. A timer that powers it
  off after two minutes would silently end exactly the session the SD card exists
  to capture. The only ways off are a 4 s hold and a flat battery.
- After a power-on, **swallow the button release** so it isn't read as a tap.
- Measure System-OFF-wake-to-LED-alive latency and size `A2_HOLD_ON_MS` so the **felt** hold is ~2.5 s.

## Byte protocol

**Up (button char `0x23BA7925`, `int32 code + int32 sequence`).** Codes 6, 7 and 8 keep their **values** and change only their **meaning** — this is a free change on the wire and a breaking change in source, because their *names* move in `app/lib/wearable/device_bridge.dart` and `server-contract/src/device/channel.ts`. An older app against new firmware will silently mis-route a cancel as an agent request: **app and server-contract must ship in the same release.**

| Code | Was | Is now |
|---|---|---|
| 1 / 2 / 3 / 5 | D5 SINGLE / DOUBLE / LONG / RELEASE | unchanged (telemetry only) |
| 4 | `PRESS` (reserved, never emitted) | unchanged, still never emitted |
| 6 | `AGENT_REQUEST` | **`CANCEL`** — value unchanged |
| 7 | `NOTE` | **`CAPTURE_TOGGLE`** — value unchanged |
| 8 | `REPLY` | **`LINK_RECOVER`** — value unchanged |
| 9 | — | **`POWER_OFF_ARMED`** (new) |
| 10 | — | **`POWER_OFF_ABORTED`** (new) |
| 11 | — | **`POWER_OFF_COMMITTED`** (new) |

Three-file change for 9/10/11: `firmware/devkit/src/button.c` + `app/lib/wearable/device_bridge.dart` + `server-contract/src/device/channel.ts`.

**No button code dispatches an agent turn any more** — the transcript does. The `channel.ts` branch that dispatched on `AGENT_REQUEST | NOTE | REPLY` is deleted, and `ws-audio.ts`'s `{"kind":"mark","code":"AGENT_REQUEST"}` becomes `{"kind":"mark","code":"CAPTURE"}`, emitted by the app when the capture window opens.

**Down (agent-command char `0xCAB1AB97`, 4 bytes).** Existing ops `LED_COLOR`=0x01, `LED_PATTERN`=0x02, `HAPTIC`=0x03, `STATUS_QUERY`=0x04, `NOTIFY`=0x05. Add **`HABITAT`=0x06**, byte 1 = habitat cue id, bytes 2–3 = 0. One write per cue instead of three, named identically on both sides, no pattern-enum drift. Cue ids and rationale: `docs/HABITAT_ALERTS.md`.

## Firmware tunables

| Constant | Was | Is now |
|---|---|---|
| `A2_POLL_MS` | 20 | 20 |
| `A2_DEBOUNCE_MS` | 30 | 30 |
| `A2_TAP_MS` | 700 | 700 |
| `A2_DOUBLE_WINDOW_MS` | 750 | 750 (commit immediately at 3 taps) |
| `A2_HOLD_ON_MS` | 3000 | **2000** |
| `A2_ON_TICK1_MS` | 1000 | **800** |
| `A2_ON_TICK2_MS` | 2000 | **1600** |
| `A2_WAKE_ABORT_MS` | 50 | 50 |
| `A2_OFF_RAMP_MS` | 3000 | **1500** (also the `POWER_OFF_ARMED` emit point) |
| `A2_OFF_TICK_MS` | 6000 | **3000** |
| `A2_HOLD_OFF_MS` | 10000 | **4000** |
| `A2_OFF_GESTURE_MS` | 2500 | **700** (one tap/hold threshold in the system, not two) |
| `A2_POWER_OFF_CUE_MS` | 1100 | 1100 |
| `A2_NOTIFY_RETRY_MS` | 40 | 40 |
| `A2_APP_ACK_MS` | — | **1500** (watchdog) |
| `A2_LINK_STALE_MS` | — | **30000** (triple-tap: firmware acts vs app answers) |
| `A2_STUCK_MS` | — | **30000** (stuck-line latch) |
| `A2_OFF_RELEASE_WAIT_MS` | — | **30000** (max wait for release before forcing sleep) |

LED brightness: `LED_BRIGHT_CAP=180` · `LED_BRIGHT_CRIT=255` · idle-nop blink 60.

## App tunables

| Constant | Was | Is now |
|---|---|---|
| `_voiceNoteMaxWindow` | 60 s | **120 s**, with a 90 s `budget_warn` |
| audio pre-roll ring | none (`openWindow()` calls `_samples.clear()`) | **1500 ms** |
| discard recovery | none | **600 s**, surfaced on the phone screen |
| alert/tap tie-break | none | **300 ms** |

## Build scope

**Firmware** — in this order, because each unblocks the next:
1. Delete the D5 single-tap `SYSTEMOFF` (safety, first).
2. Fix `AGENT_OP_HAPTIC` to call `haptic_play()` instead of `play_haptic_milli()`; add `AGENT_OP_HABITAT`=0x06 + cue table; add `HAPTIC_RAMP_DOWN`; add the five new `habitat_*` cues; change `habitat_note_capturing()` duration 600 → 0.
3. Add `POWER_BOOT_HOLD`; retune the constants above.
4. Add `POWER_OFF_PENDING_RELEASE`.
5. Add codes 9/10/11, the watchdog + `button_note_app_ack()` hook, `A2_LINK_STALE_MS` gating, the stuck-line latch.

**App** — 1500 ms pre-roll ring; rename `_ButtonCode` 6/7/8 and add 9/10/11; replace the `NOTE`/`AGENT_REQUEST` branch with the three-state resolver; **write the watchdog disarm as the first action on every notify**; add the `'habitat'` case to `command_codec.dart`; discards list; capture cap 60 → 120 s.

**Server-contract** — `OP.HABITAT` + `HABITAT_CUE` + the new `HABITAT_ALERTS` entries; `ButtonCode` union and `KNOWN_BUTTON_CODES`; delete the dispatch-on-button-code branch in `channel.ts`; `ws-audio.ts` mark `AGENT_REQUEST` → `CAPTURE`; extend `tests/device.test.ts`.

## Known blockers

None of the app-sent cues in group C work until these land:

1. **`AGENT_OP_HAPTIC` ignores its pattern byte** — `agent_commands.c` calls `play_haptic_milli(duration_ms)`, never `haptic_play()`. Every app-sent haptic today is one undifferentiated buzz, so `·` / `●` / `●●` / `ramp` / `ramp↓` are all unreachable from the phone.
2. **`AGENT_OP_LED_PATTERN` maps only OFF/SOLID/BREATHING/PULSE/BLINK/FLASH** — `FADE`, `ALT_FLASH` and `DOUBLE_BLINK` exist in `neopixel.h` but cannot be commanded. `AGENT_OP_HABITAT` routes around this rather than extending the pattern enum piecemeal.
3. **`HABITAT_ALERTS` carried only the six group A cues** — fixed in `server-contract/src/device/commands.ts`; the firmware half of `AGENT_OP_HABITAT` is still outstanding.
4. **No audio pre-roll** — `audio_buffer.dart` `openWindow()` calls `_samples.clear()`. Without a 1500 ms ring the wearer loses their first word to the commit window and learns *"tap, wait for the buzz, then talk"* — a fourth rule, and the worst one.
5. **The boot-hold path is dead code** (see §Power state machine).

## Measure on hardware before this is final

Three things paper cannot settle:
- System-OFF-wake-to-LED-alive latency, which sizes `A2_HOLD_ON_MS` so the felt hold is 2.5 s.
- Whether the motor renders `ramp↓` as distinguishable from `ramp`.
- Whether the watchdog false-fires on loaded Android BLE. If it does, raise `A2_APP_ACK_MS` to 2000 — **never disable it**. A false warning is cheap; a silently lost note is not.

## Deliberately not supported

- **Hold-to-talk.** The hold band is spoken for by power, and power must never be ambiguous. Anyone arriving from a push-to-talk radio or an AirPods stem will hold this button first and get the amber ramp. That is the sharpest edge in the design: it costs one second, is silently reversible, and teaches itself in one try.
- **A pairing gesture** (§Pairing).
- **A power-off composite** (tap-tap-hold). Accident cost is bounded instead by `POWER_OFF_ARMED`, the release-gated sleep, and auto-off.
- **Undo-after-file.** Replaced by the phone's 10-minute discards list, which needs no gesture and no hidden device state.
- **Explicit note / agent-request / reply routing from the device.** A wearer under a coat cannot verify which bucket he selected, so offering the choice is a silent mis-filing trap. Verbal override ("note to self") is cheaper to remember than a gesture and works in the dark. **If the server-side `explicit_request` classifier proves imprecise on real transcripts, this is the decision to revisit** — and triple tap is the only slot left, which would be a genuine regression in guessability.
- **Offline capture on tap.** When BLE is down a tap plays link-lost and does nothing else. The firmware SD recording path is untouched; sync-on-reconnect is out of scope for v1.
- **Any product behaviour on D5.**
- **A 400 ms multi-tap window** and an accessibility "slower" setting. Revisit only if bench testing shows the delay is perceptible *after* pre-roll and the instant tick are in.

## What the owner reads

> **One button, three moves.** Hold it to turn it on — about two seconds, until it flashes green and buzzes once; let go early and nothing happens. Once it's on, **tap it once and start talking.** The light blinks white the whole time it's listening, so people near you can see it too. Tap once more when you're done and it flashes green — filed. Changed your mind? **Tap twice** and the buzz falls away instead of rising: gone, nothing saved (and it's still on your phone for ten minutes if you want it back). That same tap-twice works when it has buzzed at you and you'd rather not deal with it, and **a single tap is how you say yes** to anything it asks — if it wanted an answer, it starts listening straight away so you can just say it. To switch it off, **hold it again**: the light goes amber after a second and a half as a warning, ticks once more, and at four seconds it fades red and double-buzzes goodbye — let go any time before that and it stays on. You never have to put it into pairing mode: from the moment it's on it's looking for your phone, and amber-and-blue flickering is what that looks like. If it ever seems stuck, tap three times and it'll go looking again. That's the whole thing — **tap means yes, two taps mean no, and holding is power.**
