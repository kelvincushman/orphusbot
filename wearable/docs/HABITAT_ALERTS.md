<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Habitat alerts — Wearable's LED + haptic vocabulary

Habitat alerts are the non-verbal channel for the wearable to communicate with the wearer. **No speaker, by design**, and no screen — just colour and vibration out, button and voice back in. In OrphusBot the channel is **duplex**: every signal is a tracked message and every ask has a defined button reply (OrphusBot DESIGN §9.3). The vocabulary is intentionally small so it learns fast and every signal has a distinct feel: **6 task signals** the agent raises, and **8 button cues** the app plays back the instant a gesture lands.

Signals flow: Wearable agent result → `src/harness/inngest/device-delivery.ts` picks an alert name → `src/harness/device/commands.ts` encodes 4-byte packets → `src/harness/device/channel.ts` queues them → app polls `/api/device/command/poll` → app writes to BLE GATT `0xCAB1AB97` → `devices/wearable-kelvinlee/firmware/devkit/src/agent_commands.c` dispatches to `neopixel.c` / `haptic.c`. (The upstream speaker was removed from this build; there is no audio output.)

## Vocabulary

| Signal | LED colour | LED pattern | Haptic | Meaning |
|---|---|---|---|---|
| **task_queued** | Wearable blue (0, 80, 200) | PULSE, 1 s | single short | Got it; dispatching. |
| **task_running** | Wearable blue | BREATHING, continuous | — | Working. Arrival of `task_done` or `error` supersedes. |
| **awaiting_input** | Amber (220, 140, 0) | PULSE, continuous | LONG (500 ms) | Agent needs Kelvin. **Single tap = yes** (the mic opens straight away if it asked a question); **double tap = dismiss unactioned.** |
| **task_done** | Green (0, 200, 60) | FLASH, 2 s | DOUBLE short | Complete. Summary visible in Wearable dashboard / Obsidian. |
| **error** | Red (220, 20, 20) | FLASH, 3 s | TRIPLE short | Failed — pairing, network, or worker crash. |
| **budget_warn** | Amber | BREATHING, continuous | — | Business is approaching its daily USD cap. Next dispatch may be refused. |

## Button cues

The A2 button scheme (`docs/product/BUTTON_FEEDBACK_SPEC.md`) needs cues the *app* plays within 1500 ms of a gesture, because only the phone knows what a tap meant. These go out as one `HABITAT` write each — see Packet authority.

| Signal | LED colour | LED pattern | Haptic | Meaning |
|---|---|---|---|---|
| **capture_open** | White (180, 180, 180) | **SOLID**, continuous | RAMP (80/40/120, rising) | Listening. Lit steadily for the whole capture. |
| **note_filed** | Green | DOUBLE_BLINK, 400 ms | single short | Captured, transcribed, sent. |
| **discarded** | Amber | DOUBLE_BLINK, 400 ms | RAMP_DOWN (120/40/80, falling) | Scratch that — the note or the alert, nothing kept. |
| **ack** | — (LED off) | — | TICK (≈30 ms) | Heard you. Clears whatever was showing. |
| **nop** | White @ 60/255 | BLINK, 150 ms | — | Double tap with nothing to cancel. Seen if you look, ignorable if you don't. |
| **ble_searching** | Amber + blue | ALT_FLASH, continuous | — | Looking for the phone. Also what "pairing" looks like — there is no pairing gesture. |
| **ble_connected** | Green | BLINK, 250 ms | TICK | Your phone is right here. |
| **ble_idle** | — | OFF | — | Connected, nothing to say. |

`capture_open`'s steady white is a **consent signal**, not a status light: it is visible to people nearby for the whole capture and is **non-suppressible**. No battery optimisation may dim or drop it.

> **Steady, not blinking.** This cue was originally written as `NEOPIXEL_BLINK` with a `duration_ms` of 0. `duration_ms` is the auto-stop *timeout*, not the blink period — `pattern_tick` blinks BLINK at a fixed 4 Hz regardless — so "BLINK, 0" rendered as *rapid white strobing for the whole capture*. It is `NEOPIXEL_SOLID` now: a single steady write that holds until the next cue, which is what "lit for the whole capture" always meant (fixed in `habitat_capture_open`, `firmware/devkit/src/habitat.c`).

## LED brightness

Every LED write passes through a single global dimmer in `neopixel.c`: each channel is scaled by `NEOPIXEL_BRIGHTNESS / 255` before the `NEOPIXEL_MAX_CHANNEL` safety cap. Colours across the codebase are authored at full `0–255`; this one constant sets the worn-on-body brightness so no individual cue has to know about it.

`NEOPIXEL_BRIGHTNESS` is **18** (~1/14 of full scale) — the bare NeoPixel at the raw cap was uncomfortably bright worn against the body. Raise the constant toward 255 for a brighter device; lower it to dim further. This scales *all* cues uniformly, including the white consent signal, which stays comfortably visible at 18.

## Packet authority

The 4-byte wire format is specified in `server-contract/src/device/commands.ts::encodeCommand` and mirrored verbatim in `firmware/devkit/src/agent_commands.h`. Any update to the ops / pattern codes must land in **both** files and be verified by `server-contract/tests/device.test.ts`. *(The `src/harness/...` paths above date from when this code lived in the nova-pai tree; the files are the same ones.)*

**`HABITAT` = op 0x06** carries a whole cue in one write: byte 1 is a cue id, bytes 2–3 are zero. Firmware dispatches byte 1 straight to its `habitat_*()` table, so the phone never composes a colour + pattern + haptic triple and the two sides cannot drift on pattern enums. Cue ids (`HABITAT_CUE` in `commands.ts`, mirrored in `agent_commands.h` and `app/lib/wearable/command_codec.dart`):

| 0x01 | 0x02 | 0x03 | 0x04 | 0x05 | 0x06 | 0x07 | 0x08 | 0x09 | 0x0A | 0x0B | 0x0C |
|---|---|---|---|---|---|---|---|---|---|---|---|
| capture_open | note_filed | discarded | ack | nop | ble_searching | ble_connected | ble_idle | budget_warn | error | task_running | awaiting_input |

The six task signals above still ship as LED + haptic triples because that already works on flashed firmware. Collapse them onto `HABITAT` once the op is proven on hardware — four of the six have an id reserved already (0x09–0x0C); `task_queued` and `task_done` would need a new id minted on both sides first.

**Haptic patterns.** `agent_commands.c` plays the named patterns (single, double, triple, long) through `haptic_play()`, so app-sent haptics are distinguishable on the wrist; a raw duration with no named pattern still falls back to one buzz of that length. Still bench-test that `RAMP` and `RAMP_DOWN` feel different on the fitted motor.

## Why this specific design

- **Colour is the primary dimension** — the human eye locks onto colour before pattern. Green-amber-red maps to done-attention-error in every operator's intuition.
- **Pattern is the tertiary dimension** — FLASH vs BREATHING distinguishes "done" (one-shot, closes out) from "running" (persistent, more to come).
- **Haptic pulse-count is the secondary dimension for eyes-down situations** — one-buzz / two-buzz / three-buzz maps to queued / done / error. Long buzz = stop what you're doing, I need you.
- **Budget warn is a recycled amber breathing** — intentionally identical to `awaiting_input` so Kelvin checks the dashboard and sees either "agent needs you" or "budget full" with the same one glance.
- **Cancel is a haptic played backwards** — `discarded` uses RAMP_DOWN, the exact inverse of the RAMP that opened the capture. Nobody memorises "double tap = cancel"; they feel the thing they started being un-started. This is the one cue whose meaning is carried by the haptic rather than the colour, so it must survive a coat pocket. *(Bench-test the inversion is distinguishable at these durations; if the motor can't render it, keep the amber double-blink and fall back to LONG.)*

## Extending the vocabulary

Add a new signal only when an existing one would mask meaning. The current 14 cost one `AGENT_OP_*` code between them, and a cue id is a byte, so headroom is not the constraint — the wearer's memory is. If you add one:
1. Add the cue id to `HABITAT_CUE` and the name + command array to `HABITAT_ALERTS` in `server-contract/src/device/commands.ts`
2. Mirror the cue id in `firmware/devkit/src/agent_commands.h` and give it a `habitat_*()` function to dispatch to
3. Mirror the name in `app/lib/wearable/command_codec.dart`
4. Add a firmware-side test case to `docs/TEST_HARNESS.md`
5. Document the new signal row in this file
6. Add a pure test in `server-contract/tests/device.test.ts` exercising `resolveAlert("newName")`

## Don't use habitat alerts for

- Long-form content (that's the phone app's job).
- Status polling (the dashboard already surfaces everything).
- Time-series metrics (same).
- Personal motivation messages (different trust model — alerts are operational, not emotional).
