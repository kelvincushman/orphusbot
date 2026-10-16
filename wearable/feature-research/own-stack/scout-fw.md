<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Scout: firmware provenance map (`firmware/devkit/`)

Scope: every file in the `target_sources` list of `firmware/devkit/CMakeLists.txt`
plus its headers. Evidence used: the attribution header on each file,
`git log --follow`, `git diff a913293..HEAD` (the import commit) and content
reading. No C source was modified.

Baseline import commit: `a913293` — *feat(monorepo): import wearable-omi device
subtree + hardware docs* (2026-04-18). Everything present at that commit and
carrying `Portions (c) 2024 Based Hardware Contributors` is upstream-derived.

---

## 0. Header caveat — read this before trusting the attribution line

`scripts/add-copyright-headers.sh` stamped
`/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */`
onto **205 files inside `src/lib/opus-1.2.1/`** as well as our own tree. Those
205 files are Xiph.Org / CSIRO / Skype BSD-3-Clause code; 201 of them still
carry the original BSD-3 grant directly underneath. The stamped line is a
**mis-attribution** — it claims Kelvin Lee copyright and an MIT grant over
third-party BSD-3 code, and it names Based Hardware as a portions-holder on
files they did not write either.

The same stamp is on `src/lib/battery/battery.c/.h`, which are Apache-2.0
(© 2024 Marcus Alexander Tjomsaas).

Two consequences for the rewrite:
1. **The header alone cannot be used as the provenance oracle.** The table
   below is based on header *plus* git history *plus* content.
2. Stripping the header from Opus and battery must be part of the licence
   cleanup, independently of any rewrite. Keep the upstream grants intact.

Second defect found while looking for that script:
`scripts/add-copyright-headers.sh` is **committed as a git-commit patch text,
not a shell script** (264 lines beginning `commit 68194d77…`, no shebang,
`file(1)` reports "Git commit"). It is executable and would fail if run. It
was clobbered in `ff95b76 docs: consolidate wearable documentation and server
contract`. Fix or delete before relying on it.

---

## 1. Classification table

LOC = `wc -l`. "Ours since import" = `git diff --numstat a913293 HEAD`.

### In the devkit build

| File | LOC | Class | Evidence | Ours since import |
|---|---:|---|---|---:|
| `src/main.c` | 362 | **UPSTREAM-DERIVED** | header + import commit | +54 / −33 |
| `src/transport.c` | 913 | **UPSTREAM-DERIVED** | header + import commit | +16 / −4 |
| `src/transport.h` | 29 | **UPSTREAM-DERIVED** | header | — |
| `src/button.c` | 902 | **UPSTREAM-DERIVED (mixed)** | header; A2 FSM is ours | +346 / −51 |
| `src/button.h` | 16 | **UPSTREAM-DERIVED** | header | — |
| `src/speaker.c` | 470 | **UPSTREAM-DERIVED (mixed)** | header; haptic sequencer is ours | +158 / −21 |
| `src/speaker.h` | 82 | **UPSTREAM-DERIVED (mixed)** | `haptic_pattern_t` block is ours | — |
| `src/sdcard.c` | 432 | **UPSTREAM-DERIVED** | header + import commit | +9 / −3 |
| `src/sdcard.h` | 108 | **UPSTREAM-DERIVED** | header | — |
| `src/storage.c` | 377 | **UPSTREAM-DERIVED** | header + import commit | +1 / −1 |
| `src/storage.h` | 15 | **UPSTREAM-DERIVED** | header | — |
| `src/codec.c` | 148 | **UPSTREAM-DERIVED** | header + import commit | +1 / −1 |
| `src/codec.h` | 23 | **UPSTREAM-DERIVED** | header | — |
| `src/mic.c` | 113 | **UPSTREAM-DERIVED** | header; self-declares port of Seeed_Arduino_Mic | +17 / −11 |
| `src/mic.h` | 23 | **UPSTREAM-DERIVED** | header | — |
| `src/led.c` | 37 | **UPSTREAM-DERIVED** | header | +1 / −1 |
| `src/led.h` | 24 | **UPSTREAM-DERIVED** | header | — |
| `src/usb.c` | 46 | **UPSTREAM-DERIVED** | header | +1 / −1 |
| `src/usb.h` | 7 | **UPSTREAM-DERIVED** | header | — |
| `src/config.h` | 42 | **UPSTREAM-DERIVED** | header; mostly hardware facts | — |
| `src/utils.h` | 20 | **UPSTREAM-DERIVED** | header; 3 trivial macros | — |
| `src/neopixel.c` | 295 | **OURS** | no upstream portion line; first written by us | +59 (post-import edits) |
| `src/neopixel.h` | 57 | **OURS** | no upstream portion line | — |
| `src/agent_commands.c` | 149 | **OURS** | no upstream portion line | +19 |
| `src/agent_commands.h` | 55 | **OURS** | no upstream portion line | — |
| `src/habitat.c` | 227 | **OURS** | first appears in `db23b24` (2026-06-10) | +227 (new) |
| `src/habitat.h` | 60 | **OURS** | first appears in `db23b24` | — |
| `src/lib/battery/battery.c` | 255 | **THIRD-PARTY-VENDORED** | Apache-2.0, © 2024 Marcus Alexander Tjomsaas | — |
| `src/lib/battery/battery.h` | 81 | **THIRD-PARTY-VENDORED** | Apache-2.0, same author | — |
| `src/lib/opus-1.2.1/**` (140 `.c`, 52 `.h`, 1 `.s`) | **53,651** | **THIRD-PARTY-VENDORED** | Xiph.Org / CSIRO / Skype, BSD-3-Clause | — |

### Present but not in `target_sources`

| File | LOC | Class | Note |
|---|---:|---|---|
| `src/nfc.c` | 169 | UPSTREAM-DERIVED | commented out: `# src/nfc.c future release` |
| `src/nfc.h` | 43 | UPSTREAM-DERIVED | ditto |

### Totals

| Bucket | LOC |
|---|---:|
| Upstream-derived, in build (incl. our in-file additions) | **4,189** |
| — of which our additions since import | ~600 |
| — true upstream-shaped remainder to rewrite | **~3,600** |
| Ours, in build | **843** |
| Third-party vendored, in build (battery) | **336** |
| Third-party vendored, in build (Opus) | **53,651** |
| Upstream-derived, out of build (nfc) | 212 |

The rewrite surface is ~3,600 lines of C. That is small. Opus is 94% of the
build's line count and is not in scope.

---

## 2. What each UPSTREAM-DERIVED file actually does + rewrite difficulty

### `transport.c` (913) — **HIGH**
Owns the whole BLE stack: `bt_enable`, advertising set, four GATT services
(audio `19B10000`, Nordic legacy DFU `00001530`, accel `32403790`, plus
registering `storage_service` defined in `storage.c`), connection callbacks,
MTU/PHY/data-length tracking, Zephyr BAS battery notify on a 15 s
`k_work_delayable`, LSM6DSL accel/gyro sample+notify on a 1 s
`k_work_delayable`, a 4 KB `pusher` thread at `K_PRIO_PREEMPT(7)` that drains a
`ring_buf` of Opus frames and fragments them into `bt_gatt_notify` packets
(3-byte header, 3 retries), and the SD fallback path (`write_to_storage`,
440-byte packed writes) taken when no subscriber exists. Also owns
`write_sdcard_mutex` and `bt_on`/`bt_off`.
*Why high:* it is the hub — it is the only file that knows the audio wire
format, the pusher/fallback policy, connection lifecycle and four service
definitions at once. Every other module's public API exists to serve it.

### `button.c` (902) — **HIGH**
Two independent FSMs sharing one GATT service (`23BA7924` / char `23BA7925`)
and one `final_button_state[2]` payload. (a) Upstream D5/P0.05 FSM: GPIO
interrupt sets `was_pressed`, a 25 Hz `k_work_delayable` classifies
press/release/single/double/long and notifies bytes 1–5; drives
`turnoff_all()` → `mic_off` + `sd_off` + `speaker_off` + `play_haptic_milli` +
LEDs off + `sys_poweroff`. (b) Ours: A2/P0.28 IoT-Button FSM — debounce work
(30 ms), 50 Hz poll work for hold bands (3 s power-on, 10 s power-off),
tap-count commit work (750 ms window) emitting bytes 6/7/8, a notify-retry
work item, and `a2_mutex`-guarded power state. Calls into `habitat_*` and
`neopixel_*` directly.
*Why high:* 350 of the 900 lines are already ours but interleaved with the
upstream FSM through shared file-scope statics (`final_button_state`,
`button_service`, `is_off`). A large block of the upstream FSM
(the `@deprecated check_button_level_2`, 171 commented lines at 616–787) are
dead code that still shapes the control flow around it.

### `sdcard.c` (432) — **MEDIUM**
FAT/ELM filesystem over `disk_access` + `zephyr/fs`. Mounts `/SD:/`, creates
`/SD:/audio`, enumerates and counts audio files, maintains `read_ptr` /
`write_ptr` path strings and an `info` file, exposes `write_to_file`,
`read_audio_data`, `get_file_size`, `save_offset`/`get_offset`, `sd_on`/
`sd_off` via a GPIO enable pin on gpio0. Owns the globals `file_count` and
`file_num_array[2]` that `storage.c` and `transport.c` read.
*Why medium:* the Zephyr FS API does the heavy lifting; the work is the file
naming/pointer scheme and its global state, which is straightforward but has
real bugs to not reproduce (`fs_stat(&current_full_path, …)` passes a `char(*)[]`
where a `const char*` is expected in three places).

### `storage.c` (377) — **MEDIUM**
GATT service `30295780` (write char `…81`, read char `…82`) plus a 4 KB
`storage_write` thread. Implements the phone-facing offline-audio protocol:
`READ_COMMAND` / `DELETE_COMMAND` / `NUKE` / `STOP_COMMAND` parsed from a write,
then streams file bytes back in 440-byte notifies with a 3-byte frame prefix and
a 50-frame heartbeat. Defines `storage_is_on` and `storage_service`.
*Why medium:* self-contained protocol, one thread, no interrupt work. Only
external couplings are `sdcard.h` and `get_current_connection()`.

### `main.c` (362) — **MEDIUM**
Boot orchestration only. Sets `NRF_POWER->DCDCEN`, reads `RESETREAS`, runs an
RGB boot-blink, then initialises in a fixed order behind `CONFIG_KELVINLEE_*`
guards: LED → battery → button → accel → speaker → SD+storage → haptic → USB →
transport → codec → mic → (deferred) NeoPixel/agent-commands. Wires
`mic_handler` → `codec_receive_pcm` and `codec_handler` →
`broadcast_audio_packets`. Then a 2 Hz `set_led_state()` loop.
*Why medium:* logically simple but the *ordering* is load-bearing — the
comments record that initialising NeoPixel before `transport_start` wedged
boot on the blocking WS2812 SPI write. There are also leftover bench-test
LED/`k_msleep(2000)` markers around `transport_start` that add ~5 s to boot and
should not be carried over.

### `speaker.c` (470) — **MEDIUM**
Two unrelated things in one file. (a) Upstream I2S speaker: `i2s_configure`
(8 kHz, 2 ch, 16-bit), `K_MEM_SLAB_DEFINE_STATIC` 2×10 KB blocks, `speak()`
reassembling 400-byte BLE writes into a buffer then `i2s_write` +
`I2S_TRIGGER_START`/`DRAIN`, `generate_gentle_chime` + `play_boot_sound`, and
GATT service `CAB1AB95` (haptic char `CAB1AB96`). (b) Ours: raw-PWM haptic on
`vibration_pwm` (A1/P0.03) — `play_haptic_milli` via a one-shot `k_timer`, and
a `haptic_play(haptic_pattern_t)` sequencer (`SEQ_MAX_PULSES` 4) built from a
`k_work_delayable` + a `k_timer` off-callback under `haptic_seq_mutex`.
*Why medium:* the two halves are cleanly separable and the I2S half is disabled
in the Wearable build (`CONFIG_I2S=n`, `&i2s0 disabled`). Effectively only the
haptic half needs to exist, and that half is already ours.

### `codec.c` (148) — **LOW**
A ring buffer (`AUDIO_BUFFER_SAMPLES`×2 = 32 KB) fed by `codec_receive_pcm`,
plus a 32 KB-stack thread at `K_PRIO_PREEMPT(4)` that pulls
`CODEC_PACKAGE_SAMPLES` (160) at a time, calls `opus_encode` into a statically
placed `OpusEncoder` (7180 B, CELT mode) and hands the frame to a callback.
*Why low:* it is a thin ring-buffer + thread + `opus_encoder_ctl` sequence. The
encoder settings are the contract (§4), not the code.

### `mic.c` (113) — **LOW**
Raw `nrfx_pdm` (not Zephyr DMIC): double-buffered 1600-sample (100 ms) capture
at `NRF_PDM_FREQ_1280K` / `RATIO_80X` mono → 16 kHz, gain 64, IRQ priority 7,
`IRQ_DIRECT_CONNECT(PDM_IRQn, 5, …)`, HFCLK start, and a `PDM_PWR_PIN`
(P1.10) power-up with a 10 ms settle. Callback delivers `int16_t*` from the
ISR.
*Why low:* ~110 lines, one nrfx driver, no state machine. The non-obvious parts
(power-before-clock ordering, and the `&pdm0 { status = "disabled" }` overlay
that keeps Zephyr from stealing the pins) are already documented in-tree.
`#include "led.h"` here is a dead include.

### `led.c` / `led.h` (37 + 24) — **LOW**
Three `gpio_dt_spec` from `DT_ALIAS(led0..2)` and three setters. Trivial;
arguably not copyrightable, but rewrite it anyway since it costs minutes.

### `usb.c` / `usb.h` (46 + 7) — **LOW**
`usb_enable()` with a status callback that sets the global `usb_charge` on
`USB_DC_CONNECTED`/`DISCONNECTED`, with a `CONFIG_UART_CONSOLE` branch that only
installs the callback. Includes `speaker.h` and `transport.h` without using
either — dead includes.

### `config.h` (42) / `utils.h` (20) — **LOW**
`config.h` is buffer sizes, mic gain, the three PDM pin macros and the Opus
parameter block. `utils.h` is `ASSERT_OK` / `ASSERT_TRUE` / `ASSERT_NULL`.
Most of `config.h` is unprotectable hardware fact, but the values are part of
the wire contract (§4) and must be carried over verbatim.

---

## 3. Coupling map

### Header dependency graph (in-build files)

```
main.c ──► everything (boot orchestrator; wires mic→codec→transport callbacks)

transport.c ──► config.h utils.h button.h habitat.h battery.h mic.h
                sdcard.h speaker.h storage.h        [+ dead: nfc.h friend.h]
button.c    ──► habitat.h led.h mic.h neopixel.h sdcard.h speaker.h transport.h
storage.c   ──► sdcard.h transport.h utils.h
usb.c       ──► usb.h                                [+ dead: speaker.h transport.h]
codec.c     ──► config.h utils.h lib/opus-1.2.1/opus.h
mic.c       ──► config.h utils.h nrfx                [+ dead: led.h]
agent_commands.c ──► habitat.h neopixel.h speaker.h
habitat.c        ──► neopixel.h speaker.h
sdcard.c   ──► (leaf)   speaker.c ──► (leaf)   neopixel.c ──► (leaf)
led.c      ──► utils.h  battery.c ──► (leaf)
```

### The coupling that actually matters: shared mutable globals

Includes understate the coupling. These cross-TU globals are the real edges:

| Symbol | Defined in | Read/written by | Notes |
|---|---|---|---|
| `is_connected` | `main.c` | `transport.c` | drives `set_led_state()` |
| `is_off` | `button.c` | `main.c` | power state |
| `usb_charge` | `usb.c` | `main.c` | charge LED |
| `storage_is_on` | `storage.c` | `transport.c` (4 sites) | gates the SD fallback in `pusher` |
| `file_count`, `file_num_array[2]` | `sdcard.c` | `storage.c`, `transport.c` | no lock |
| `storage_service` | `storage.c` | `transport.c` (`extern` + register) | service owned by one TU, registered by another |
| `write_sdcard_mutex` | `transport.c` | `transport.c` only | but guards `sdcard.c` state |
| `final_button_state[2]`, `button_service` | `button.c` | both FSMs inside `button.c` | the intra-file coupling that makes button.c hard |

### What can be rewritten independently

**Fully independent (no in-repo callers to coordinate with beyond a stable header):**
- `led.c` / `led.h` — leaf, 3 functions.
- `mic.c` / `mic.h` — callback-out only; `main.c` wires it.
- `codec.c` / `codec.h` — callback-in / callback-out only.
- `usb.c` / `usb.h` — one global out.
- `sdcard.c` / `sdcard.h` — leaf, but exports two globals that must keep their names or be changed in lockstep with `storage.c` + `transport.c`.
- `speaker.c` haptic half — already ours; `speaker.h` is the boundary.

**Must move together:**
1. `transport.c` + `storage.c` + `sdcard.c` — bound by `storage_service`,
   `storage_is_on`, `file_count`, `file_num_array` and `write_sdcard_mutex`.
   The SD-fallback path in `pusher()` cannot be reasoned about without all
   three.
2. `button.c` (whole file) + `habitat.h` + `neopixel.h` + `speaker.h` — the two
   FSMs share `final_button_state` and `button_service`; splitting them is
   itself a rewrite decision.
3. `main.c` lands **last** — its value is the initialisation order, which is
   only correct once every module's init signature is final.

---

## 4. Hardware contract that any rewrite MUST preserve

### 4.1 BLE — device identity & advertising
| Item | Value | Source |
|---|---|---|
| Advertised name | `wearable` (`CONFIG_BT_DEVICE_NAME`) | `prj_wearable.conf` |
| DIS model / manuf | `wearable` / `Kelvin Lee` | `prj_wearable.conf` |
| DIS firmware rev | `wearable-0.1.0+dk2-2.0.10` | `prj_wearable.conf` |
| AD payload | flags + **128-bit audio service UUID** + complete name | `transport.c` `bt_ad[]` |
| Scan response | 16-bit DIS UUID + **128-bit DFU service UUID** | `transport.c` `bt_sd[]` |

The app scans on the audio service UUID (`wearable_scan_page.dart` filters on
`19b10000`), so it must stay in the **advertisement**, not the scan response.

### 4.2 GATT services and characteristics
| Service | UUID | Characteristic | UUID | Props |
|---|---|---|---|---|
| Audio | `19B10000-E8F2-537E-4F6C-D104768A1214` | audio data | `19B10001-…` | READ, NOTIFY (+CCC) |
| | | codec id | `19B10002-…` | READ |
| | | speaker in | `19B10003-…` | WRITE, NOTIFY (speaker builds only) |
| Button | `23BA7924-0000-1000-7450-346EAC492E92` | button state | `23BA7925-…` | READ, NOTIFY (+CCC) |
| Storage | `30295780-4301-EABD-2904-2849ADFEAE43` | write/cmd | `30295781-…` | WRITE, NOTIFY |
| | | read/data | `30295782-…` | READ, NOTIFY |
| Accel | `32403790-0000-1000-7450-BF445E5829A2` | accel+gyro | `32403791-…` | READ, NOTIFY |
| Nordic legacy DFU | `00001530-1212-EFDE-1523-785FEABCD123` | control point | `00001531-…` | WRITE, NOTIFY |
| Speaker/haptic | `CAB1AB95-2EA5-4F4D-BB56-874B72CFC984` | haptic | `CAB1AB96-…` | WRITE (+CCC) |
| **Wearable agent cmds** | `CAB1AB90-0000-1000-8000-00805F9B34FB` | command | **`CAB1AB97-0000-1000-8000-00805F9B34FB`** | WRITE, WRITE_WITHOUT_RESP |

Consumers pinning these: `app/lib/wearable/device_bridge.dart` (audio, button,
agentCmd, storage), `app/lib/services/devices/models.dart` (audio, button,
storage, accel), `server-contract/src/device/commands.ts`
(`GATT_AGENT_COMMANDS_UUID`).

Note the asymmetry the app already codes around: the button **service** UUID is
`23BA7924` and the **characteristic** is `23BA7925`, but the agent-command
**service** is `CAB1AB90` and the **characteristic** is `CAB1AB97`. Do not
"tidy" either.

### 4.3 Agent-command wire format — 4 bytes, exactly
```
byte0 = op
byte1 = R  | pattern | tier
byte2 = G  | duration_hi   (big-endian u16 ms)
byte3 = B  | duration_lo
```
Writes with `offset != 0` → `BT_ATT_ERR_INVALID_OFFSET`;
`len != 4` → `BT_ATT_ERR_INVALID_ATTRIBUTE_LEN`. One packet per write.

| Op | Value | Payload |
|---|---|---|
| `LED_COLOR` | `0x01` | r, g, b |
| `LED_PATTERN` | `0x02` | pattern, duration BE u16 |
| `HAPTIC` | `0x03` | pattern, duration BE u16 (fw defaults 0→120 ms, caps at 2000 ms) |
| `STATUS_QUERY` | `0x04` | zeros (no response implemented yet) |
| `NOTIFY` | `0x05` | tier 0–3 → `habitat_notify()` |

| Pattern | Value |
|---|---|
| `OFF` / `SOLID` / `BREATHING` / `PULSE` / `BLINK` / `FLASH` | `0x00`–`0x05` |
| haptic `SINGLE` / `DOUBLE` / `TRIPLE` / `LONG` | `0x10`–`0x13` |

Three mirrors must stay byte-identical: `src/agent_commands.h`,
`server-contract/src/device/commands.ts`, `app/lib/wearable/command_codec.dart`.

**Known drift to resolve, not replicate:**
- `AGENT_OP_NOTIFY = 0x05` exists only in the firmware. Neither `commands.ts`
  nor `command_codec.dart` can emit it, so `habitat_notify` is unreachable
  over BLE today.
- `neopixel_pattern_t` has `FADE=6`, `ALT_FLASH=7`, `DOUBLE_BLINK=8`. The
  `PATTERN` enums on server and app stop at `FLASH=0x05`, so
  `agent_commands_apply` rejects 6–8 with `-EINVAL`. Those three are reachable
  only from in-firmware `habitat_*` calls.
- Firmware ignores the haptic *pattern* byte entirely and uses only the
  duration; `SINGLE`/`DOUBLE`/`TRIPLE`/`LONG` are indistinguishable over BLE.
  (`haptic_play()` implements them, but only in-firmware callers reach it.)
- `server-contract/tests/device.test.ts` imports from
  `../src/harness/device/commands.js` while the file sits at
  `server-contract/src/device/commands.ts` — the contract test does not
  currently resolve in this repo.

### 4.4 Button notify payload
`int final_button_state[2]` — **8 bytes**, little-endian, `[0] = code`,
`[1] = sequence`. Codes: `1` single tap, `2` double tap, `3` long tap,
`4` press, `5` release, `6` AGENT_REQUEST (A2 double-tap), `7` NOTE (A2 single),
`8` REPLY (A2 triple). Timing: D5 `TAP_THRESHOLD` 300 ms, `DOUBLE_TAP_WINDOW`
600 ms, `LONG_PRESS_TIME` 1000 ms, poll 40 ms. A2 `A2_DEBOUNCE_MS` 30,
`DOUBLE_WINDOW_MS` 750, `TAP_MS` 700, `HOLD_ON_MS` 3000, `HOLD_OFF_MS` 10000,
poll 20 ms.

### 4.5 Audio format
| Parameter | Value |
|---|---|
| Mic | PDM, mono, `NRF_PDM_FREQ_1280K` ÷ `RATIO_80X` → **16 kHz**, `EDGE_LEFTFALLING`, gain 64 |
| PCM | signed 16-bit LE |
| Mic DMA buffer | 1600 samples = 100 ms, double-buffered |
| Codec | **Opus 1.2.1, fixed-point, CELT-only** (`CONFIG_OPUS_MODE_CELT`) |
| Opus init | `opus_encoder_init(state, 16000, 1, OPUS_APPLICATION_RESTRICTED_LOWDELAY)` |
| Bitrate | **32000** |
| VBR | on, `VBR_CONSTRAINT 0` |
| Complexity | 3 |
| Signal | `OPUS_SIGNAL_VOICE`, LSB depth 16 |
| DTX / FEC / packet-loss | all 0 |
| Frame | `CODEC_PACKAGE_SAMPLES` = **160 samples = 10 ms** |
| Max frame bytes | `CODEC_OUTPUT_MAX_BYTES` = 320 |
| `CODEC_ID` (read on `19B10002`) | **20** |
| BLE packet | `[id_lo][id_hi][index]` + payload, fragment size `MTU − 3` |
| TX ring | 32 frames; `MINIMAL_PACKET_SIZE` 100 (below this MTU, don't send) |
| SD fallback record | 440-byte blocks, 1-byte length prefix per Opus frame |

Server side agrees: `ws-audio.ts` defaults `sampleRate=16000`, `frameMs=10`,
`encoding=opus`, and comments `10ms (CODEC_ID=20)`.

### 4.6 Pin assignments (authority: `docs/PIN_MAP.md` + `overlay/wearable-peripherals.overlay`)
| Pin | GPIO | Role |
|---|---|---|
| A0 / D0 | P0.02 | SPI2 CS — microSD BFF |
| A1 / D1 | P0.03 | **PWM0 ch0 → vibration motor** (`vibration_pwm`, period `PWM_MSEC(20)`) |
| A2 / D2 | P0.28 | **IoT Button**, `GPIO_PULL_UP | GPIO_ACTIVE_LOW`, `INPUT_KEY_0` |
| A3 / D3 | P0.29 | **SPIM3 MOSI → WS2812 DIN**, 4 MHz, one-frame `0x70`, zero-frame `0x40`, chain 1, GRB |
| D4 | P0.04 | I2C SDA + driven high by `button.c` `d4_pin` |
| D5 | P0.05 | I2C SCL + primary button input (`d5_pin_input`) |
| D6 | P1.11 | legacy haptic (`speaker.c` GPIO spec, gpio1 pin 11) |
| D7 | P1.12 | **dummy SPIM3 SCK** for the WS2812 |
| D8/D9/D10 | P1.13 / P1.14 / P1.15 | SPI2 SCK / MISO / MOSI — microSD |
| internal | P0.16 | PDM DIN |
| internal | P1.00 | PDM CLK |
| internal | P1.10 | PDM power enable (`PDM_PWR_PIN`) |
| internal | P1.08 | LSM6DSL power (`accel_gpio_pin`, gpio1 pin 8) |
| internal | P0.26 / P0.30 / P0.06 | RGB LED R / G / B via `DT_ALIAS(led0..2)` |
| internal | P0.13 / P0.14 / P0.17 / P0.31 | battery charge-speed / read-enable / charging-enable / AIN7 |

Two devicetree facts that are load-bearing and must survive:
- `&pdm0 { status = "disabled" }` — Zephyr's PDM node otherwise owns
  P1.00/P0.16 and parks DIN under `CONFIG_PM_DEVICE`, producing all-silence
  Opus frames. This firmware drives PDM via raw nrfx.
- WS2812 must be on **SPIM3**, not SPIM1. SPIM1 shares peripheral instance 1
  with the board's `i2c1`/TWIM1 and hard-faults. The GPIO bit-bang WS2812
  driver is also ruled out — its `irq_lock` starves the BLE radio.

### 4.7 Other behavioural contract
- `NEOPIXEL_MAX_CHANNEL = 180` brightness cap on every write (LDO headroom).
- Nordic legacy DFU: write `0x06` (1 byte) or `0x01 xx` (2 bytes) →
  `NRF_POWER->GPREGRET = 0xA8` + `NVIC_SystemReset()` into the bootloader.
- Battery: BAS notify every 15 s; accel/gyro notify every 1 s.
- Boot: `NRF_POWER->DCDCEN = 1` and `DCDCEN0 = 1`.

---

## 5. Do not rewrite — keep vendored

### `src/lib/opus-1.2.1/` — **CONFIRMED Xiph, BSD-3-Clause. Keep.**
- 193 top-level entries plus `arm/`; **53,651 lines** of `.c`/`.h`/`.s`.
- 201 files carry the verbatim three-clause BSD grant
  ("Redistribution and use in source and binary forms…"), attributed to
  Xiph.Org Foundation, CSIRO, Skype Limited, Gregory Maxwell, Jean-Marc Valin,
  Koen Vos.
- Built with `FIXED_POINT`, `DISABLE_FLOAT_API`, `OPUS_ARM_ASM` +
  `OPUS_ARM_INLINE_*`, `ARM_MATH_CM4`, `USE_ALLOCA`, and one hand-written
  assembly file (`arm/celt_pitch_xcorr_arm_gcc.s`).
- **Licence reasoning:** BSD-3-Clause is permissive and compatible with
  shipping MIT-licensed original work. It imposes only notice retention and a
  no-endorsement clause. Rewriting a psychoacoustic codec is not a licensing
  problem, it is a multi-person-year problem with a guaranteed-worse result.
  Everyone vendors it.
- **Action required:** remove the injected
  `Copyright (c) 2025-2026 Kelvin Lee … Portions (c) 2024 Based Hardware
  Contributors` line from all 205 files and add a `COPYING`/`LICENSE.opus`
  under `src/lib/opus-1.2.1/` (the directory currently has no licence file of
  its own). No `COPYING` or `LICENSE` file exists there today.

### `src/lib/battery/battery.{c,h}` — **THIRD-PARTY, Apache-2.0. Keep, or rewrite by choice.**
- 336 lines, © 2024 Marcus Alexander Tjomsaas, Apache-2.0, grant intact
  below the injected header.
- SAADC AIN7 read (12-bit, `ADC_GAIN_1_6`, internal 0.6 V ref, 10 samples at
  500 µs), a 16-entry mV→% curve, and charge-speed/enable GPIOs.
- **Licence reasoning:** Apache-2.0 is permissive and MIT-compatible for
  distribution, but it is *not* MIT — an "entirely MIT, all ours" claim on the
  repo requires either keeping it as an attributed third-party subdirectory
  (fine, and honest) or replacing it. It is only ~250 substantive lines and is
  pure hardware description, so a clean rewrite is cheap if a single-licence
  repo is the goal. **Recommendation: rewrite it** — it is the one third-party
  file small enough that keeping it costs more in licence-page complexity than
  replacing it costs in effort.
- **Action required either way:** strip the injected Kelvin/Based-Hardware
  header from both files; it currently overwrites an Apache-2.0 grant with an
  MIT claim.

### Other vendored third-party found in the repo (outside the devkit build)
- `firmware/bootloader/mcuboot/{root-rsa-2048.pem, enc-rsa2048-priv.pem,
  enc-rsa2048-pub.pem}` — MCUboot **sample** signing/encryption keys. Keep as
  build config, but treat as **publicly-known keys**: a production build must
  generate its own. A private key in version control is a finding regardless of
  its provenance.
- `firmware/bootloader/deprecated/*.hex`, `*.uf2` — prebuilt Seeed/Adafruit
  bootloader binaries. Redistributable artefacts, not source. Keep or delete;
  do not rewrite.
- `firmware/kelvinlee/` and `firmware/test/` — separate Zephyr apps not built
  by `firmware/devkit/CMakeLists.txt`. `firmware/kelvinlee/src/mic.c`,
  `mcuboot_boot_zephyr.c` and `src/lib/core/lib/battery/*` carry third-party
  notices (Nordic / Apache / Tjomsaas). **Out of scope for this rewrite** —
  but they are also upstream-derived and will block a clean "no upstream code
  remains" claim if they stay in the published tree. Decide delete-vs-rewrite
  separately.
- `src/nfc.c` / `src/nfc.h` — upstream-derived, 212 lines, commented out of the
  build, body is a stub ("for later……"). **Delete rather than rewrite.**

---

## 6. Proposed rewrite slices (parallel-agent sized)

Contract for every slice: no BLE UUID, no wire byte, no pin, no Opus parameter
in §4 may change. Each slice keeps its existing header file's symbol names
unless the slice explicitly owns the header.

### Wave 1 — four fully independent slices, no cross-talk

**S1 · Audio input path** — LOW/LOW
Files: `src/mic.c`, `src/mic.h`, `src/codec.c`, `src/codec.h`, `src/config.h`
(the mic + Opus constant block only).
~350 LOC. Preserve: PDM 16 kHz config, 100 ms double buffer, power-before-clock
ordering, the exact `opus_encoder_ctl` sequence, 160-sample frames,
`CODEC_ID = 20`, the two callback typedefs.
Dependency: none. Highest-value first slice — it is the whole capture chain and
it is only 350 lines.

**S2 · Status LEDs + USB** — LOW
Files: `src/led.c`, `src/led.h`, `src/usb.c`, `src/usb.h`, `src/utils.h`.
~130 LOC. Preserve: `DT_ALIAS(led0..2)`, the `usb_charge` global name and its
`USB_DC_*` semantics. Drop the dead `speaker.h`/`transport.h` includes.
Dependency: none.

**S3 · Battery** — LOW
Files: `src/lib/battery/battery.c`, `src/lib/battery/battery.h`.
~336 LOC. Preserve: `battery_init`, `battery_charge_start/stop`,
`battery_get_millivolt`, `battery_get_percentage` signatures; AIN7 / 12-bit /
`ADC_GAIN_1_6` / internal-ref; the mV→% curve endpoints.
Dependency: none. Optional (Apache-2.0 already permits keeping it) — run it
only if the goal is a single-licence repo.

**S4 · Haptic + speaker split** — MEDIUM
Files: `src/speaker.c`, `src/speaker.h`.
~550 LOC in, expect ~250 out. Split into a haptic module (already ours — keep
the `haptic_play` sequencer and `play_haptic_milli` verbatim) and a
deliberately-minimal I2S stub, since `CONFIG_I2S=n` in the Wearable build. Preserve
GATT `CAB1AB95`/`CAB1AB96` and `register_speaker_service()` so `transport.c`
compiles unchanged. **Decide explicitly whether the I2S speaker survives at all**
— if not, delete `speak()`, `play_boot_sound()`, `generate_gentle_chime()` and
the mem-slab, and drop ~300 lines from the rewrite surface.

### Wave 2 — one large slice, must move as a unit

**S5 · Storage + transport + SD** — HIGH
Files: `src/transport.c`, `src/transport.h`, `src/storage.c`, `src/storage.h`,
`src/sdcard.c`, `src/sdcard.h`.
~1,875 LOC. This is the bulk of the job and it cannot be split: `storage_service`,
`storage_is_on`, `file_count`, `file_num_array` and `write_sdcard_mutex` bind
the three files together, and the SD-fallback branch of `pusher()` reads all of
them.
Preserve: every UUID in §4.2, the AD/SR split, the 3-byte audio packet header,
`MTU − 3` fragmentation, the 3-retry loop, 15 s BAS / 1 s accel cadence, the DFU
`0x06` / `0x01` → `GPREGRET 0xA8` reset, the storage command bytes
(`READ`/`DELETE`/`NUKE`/`STOP`), 440-byte SD blocks and the 1-byte per-frame
length prefix.
Depends on: S1 (`broadcast_audio_packets` is the codec callback sink), S3
(`battery_*`), S4 (`register_speaker_service`, `speak`).
Suggested internal split for one agent, sequential: (a) GATT service definitions
+ connection callbacks; (b) `pusher` thread + ring buffer; (c) SD filesystem
layer; (d) storage GATT protocol. Do not hand (a)–(d) to different agents.

### Wave 3 — depends on Wave 2

**S6 · Button + input FSM** — HIGH
Files: `src/button.c`, `src/button.h`.
~918 LOC in, expect ~500 out. Rewrite as **one** FSM with two GPIO sources
rather than the current two FSMs sharing `final_button_state`. Delete the
171 commented-out lines at 616–787 (the `@deprecated check_button_level_2`).
Preserve: GATT `23BA7924`/`23BA7925`, the 8-byte `int[2]` notify payload, codes
1–8, all timing constants in §4.4, `turnoff_all()` semantics
(mic/sd/speaker/haptic/LED off then `sys_poweroff`), and the `is_off` global.
Depends on: S5 (`get_current_connection`, `bt_off`), S2 (`set_led_*`), S4
(`haptic_play`, `speaker_off`), S1 (`mic_off`/`mic_on`).

### Wave 4 — last

**S7 · Boot orchestration** — MEDIUM
Files: `src/main.c`, plus the residual `src/config.h`.
~400 LOC. Rewrite only once S1–S6 have final init signatures.
Preserve: `DCDCEN`/`DCDCEN0`, `RESETREAS` read, the `CONFIG_KELVINLEE_*` guard
set, the mic→codec→transport callback wiring, and — critically — the deferral
of `agent_commands_init()` until after `transport_start()`.
Remove: the bench-test `set_led_blue(true); k_msleep(2000)` markers around
`transport_start` (~5 s of dead boot time).

### Wave 0 — do these now, in parallel with everything, no C changes

**S0a · Licence hygiene** (no rewrite, blocking for the "original work" claim)
- Strip the injected Kelvin/Based-Hardware header from all 205
  `src/lib/opus-1.2.1/**` files and from `src/lib/battery/battery.{c,h}`.
- Add `src/lib/opus-1.2.1/COPYING` (Xiph BSD-3) — currently absent.
- Repair or delete `scripts/add-copyright-headers.sh` (currently a git-commit
  patch, not a script) and add a path exclusion for vendored trees before it is
  ever run again.
- Delete `src/nfc.c` / `src/nfc.h`.

**S0b · Contract reconciliation** (server + app, no firmware change)
- Add `NOTIFY = 0x05` to `commands.ts` and `command_codec.dart`, or delete
  `AGENT_OP_NOTIFY` from the firmware.
- Add `FADE`/`ALT_FLASH`/`DOUBLE_BLINK` (6/7/8) to the shared `PATTERN` enums,
  or document them as firmware-internal.
- Decide whether haptic pattern codes `0x10`–`0x13` should reach `haptic_play`
  instead of being collapsed to a duration.
- Fix the `server-contract/tests/device.test.ts` import path
  (`../src/harness/device/*` → `../src/device/*`) so the contract test actually
  runs in this repo.

### Dependency order

```
S0a ─┐ (independent, no code)
S0b ─┘

Wave 1:  S1   S2   S3   S4      (four agents, fully parallel)
              │    │    │
              └────┴────┴──► Wave 2:  S5        (one agent, sequential inside)
                                        │
                             Wave 3:  S6        (one agent)
                                        │
                             Wave 4:  S7        (one agent)
```

Effective parallel width is 4, then 1, then 1, then 1. The critical path is
S1 → S5 → S6 → S7 ≈ 3,600 lines, of which S5 alone is 1,875. If the schedule
needs compressing, the only real lever is the S4 decision to delete the I2S
speaker outright, which removes ~300 lines from S4 and simplifies S5's
`audio_data_write_handler`.

### Acceptance criteria applicable to every slice
1. `west build` succeeds with `-DEXTRA_CONF_FILE=prj_wearable.conf
   -DEXTRA_DTC_OVERLAY_FILE=overlay/wearable-peripherals.overlay`.
2. No file in the slice contains `Based Hardware`.
3. `nRF Connect`/LightBlue shows the identical service+characteristic UUID set
   from §4.2 with identical properties.
4. `server-contract/tests/device.test.ts` passes unchanged (after the S0b path
   fix) — the encoder is the contract.
5. A captured Opus stream decodes at 16 kHz mono with 10 ms frames.

**Blocking prerequisite for 1–5:** none of this is machine-verifiable until
Phase 0 of `feature-research/own-stack/plan.md` lands a working toolchain —
this machine currently has no `west`, `arm-none-eabi-gcc`, `nrfutil`,
`nrfjprog` or `JLinkExe`.
