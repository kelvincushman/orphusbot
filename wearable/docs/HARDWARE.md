<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Hardware & firmware

The OmarchyWearable device is a **Seeed XIAO nRF52840 Sense** running a Zephyr
firmware fork. It captures audio through the onboard PDM microphone, streams it
as Opus over BLE, records to a MicroSD card when the phone is out of range, and
speaks back to the wearer only through a single NeoPixel and a vibration motor —
no screen, no voice.

This document is the map: the board, the peripheral stack, the pin assignments,
the BLE GATT surface, and how to build and flash. It links out to the specs that
own each subsystem rather than restating them.

- Authoritative pin table: [`PIN_MAP.md`](PIN_MAP.md)
- Button grammar + power state machine: [`product/BUTTON_FEEDBACK_SPEC.md`](product/BUTTON_FEEDBACK_SPEC.md)
- LED + haptic vocabulary: [`HABITAT_ALERTS.md`](HABITAT_ALERTS.md)
- Toolchain setup (the traps): [`TOOLCHAIN.md`](TOOLCHAIN.md)
- Build + flash walkthrough: [`BUILD_FIRMWARE.md`](BUILD_FIRMWARE.md)
- Capture pipeline & privacy boundary: [`ARCHITECTURE_CAPTURE_PIPELINE.md`](ARCHITECTURE_CAPTURE_PIPELINE.md)

---

## The board and the stack

| Layer | Part | Role |
|---|---|---|
| MCU | **Seeed XIAO nRF52840 Sense** | nRF52840 (Cortex-M4F, BLE 5.x), onboard PDM mic, LSM6DS3TR-C IMU |
| BFF | **Adafruit MicroSD BFF** | SPI card storage — offline capture |
| BFF | **Adafruit IoT Button + NeoPixel BFF** | A2 button, A3 WS2812 NeoPixel |
| Wired | **Vibration motor** | Haptic feedback (P1.11, with an optional PWM motor on A1) |

The build **diverges** from the upstream *triangle v2* reference under
[`hardware/cad/triangle v2 w memory/`](../hardware/cad). Triangle v2 uses the
Adafruit 5769 Audio BFF (speaker + button) which owns A1/A2/A3 for I2S. This
build **drops the speaker** — there is no on-device TTS in v1 — which frees
A1–A3 for the IoT Button, NeoPixel, and vibration motor. The firmware is a fork
of an MIT-licensed upstream (Based Hardware DK2 baseline **v2.0.10**); see
[`BUILD_FIRMWARE.md`](BUILD_FIRMWARE.md) for upstream compatibility and fallback.

The firmware advertises over BLE as **`wearable`** and reports firmware revision
**`wearable-0.1.0+dk2-2.0.10`** in the Device Information Service — the
"am I running the right fork?" signal on nRF Connect / LightBlue. There are **no
BLE bonds** (`CONFIG_BT_SMP` is off): the device advertises connectably and
indefinitely, so there is no pairing mode and no pairing gesture.

---

## Peripherals

### Microphone & audio codec

- **PDM mic**, 16 kHz mono, driven by raw nrfx (not the Zephyr DMIC driver).
  `MIC_GAIN 64`, 100 ms sample buffers (`config.h`).
- The Zephyr `&pdm0` node is deliberately **disabled** in
  [`overlay/wearable-peripherals.overlay`](../firmware/devkit/overlay/wearable-peripherals.overlay):
  it otherwise co-owns the mic pins (P0.16 / P1.00) and, under `CONFIG_PM_DEVICE`,
  parks DIN as a disconnected input so every Opus frame decodes to silence. nrfx
  is left as the sole configurator.
- **Opus** encode (`codec.c`, libopus 1.2.1): 16 kHz mono, **10 ms frames**
  (160 samples), **32 kbps VBR**, `OPUS_APPLICATION_RESTRICTED_LOWDELAY`, CELT
  mode (SILK compiled out). Frames stream out over the BLE audio characteristic.

### NeoPixel (status LED)

- One **WS2812** driven by the Zephyr `worldsemi,ws2812-spi` driver over
  **SPIM3** (EasyDMA), MOSI on **A3 / P0.29**, 4 MHz, GRB color mapping.
- SPIM3 is chosen because it has no TWIM sibling: SPIM1 shares peripheral
  instance 1 with the board's `i2c1`/TWIM1, and a GPIO bit-bang driver's
  `irq_lock` starved the BLE radio. SPIM3 + EasyDMA coexists cleanly with BLE.
- A single global dimmer scales every channel: **`NEOPIXEL_BRIGHTNESS = 18`**
  (of 255, ~1/14 scale) then a `NEOPIXEL_MAX_CHANNEL = 180` safety cap
  (`neopixel.c`). Colours are authored full-range; this one constant sets the
  worn-on-body brightness. The steady-white **capture-consent** signal is
  non-suppressible — see [`HABITAT_ALERTS.md`](HABITAT_ALERTS.md).

> **Corrected from earlier docs:** older text described the NeoPixel as "SPI1
> bit-bang". The shipping build drives it with the **SPIM3 EasyDMA ws2812-spi
> driver**; the bit-bang path was abandoned because it killed BLE.

### Haptics

- Vibration motor on **D6 / P1.11** (the existing devkit haptic channel), with an
  optional second PWM motor wired to **A1 / P0.03** (`pwm0`, unused unless
  soldered).
- **Known blocker:** `agent_commands.c` implements `AGENT_OP_HAPTIC` with
  `play_haptic_milli(duration_ms)` and never calls `haptic_play()`, so every
  app-sent haptic is currently one undifferentiated buzz — the tick / single /
  double / ramp vocabulary in the specs is not yet reachable from the phone.
  Tracked in [`HABITAT_ALERTS.md`](HABITAT_ALERTS.md) and
  [`product/BUTTON_FEEDBACK_SPEC.md`](product/BUTTON_FEEDBACK_SPEC.md).

### Storage

- **MicroSD BFF** on SPI2 (CS = A0 / P0.02). Records audio locally so a wearable
  with no phone in range is still doing its job; sync-on-reconnect is out of
  scope for v1 (`storage.c`, `sdcard.c`). This is also why there is no
  unattended auto-off timer.

### IMU

- Onboard **LSM6DS3TR-C** accelerometer, exposed over an upstream GATT service
  ("shake the necklace to strobe"); not used by the capture pipeline.

---

## BLE GATT map

Grep the UUIDs from `firmware/devkit/src/transport.c`, `button.c`,
`agent_commands.c`, and `storage.c`. All 128-bit.

| Service | UUID (base) | Characteristics | Purpose |
|---|---|---|---|
| **Audio** | `19B10000-E8F2-537E-4F6C-D104768A1214` | `19B10001` audio data (notify), `19B10002` codec/format | Opus frames → phone |
| **Button** | `23BA7924-0000-1000-7450-346EAC492E92` | `23BA7925` button events (notify) | Gesture codes → phone |
| **Commands** | `CAB1AB90-0000-1000-8000-00805F9B34FB` | `CAB1AB97` agent command (write, 4 bytes) | LED / haptic control → device |
| **Storage** | `30295780-4301-EABD-2904-2849ADFEAE43` | `30295781`, `30295782` | SD-card list / read |
| **Accelerometer** | `32403790-0000-1000-7450-BF445E5829A2` | `32403791` | Upstream IMU stream |
| **Legacy DFU** | `00001530-1212-EFDE-1523-785FEABCD123` | `00001531` | Enter bootloader |
| **DIS** | 0x180A (SIG) | FW rev, model, manufacturer | Fork identification |

Notes:

- The upstream phone→device speaker characteristic `19B10003` exists in source
  but is compiled out (`CONFIG_KELVINLEE_ENABLE_SPEAKER` is undefined) — this
  build has no speaker.
- **Button events** (`23BA7925`) are `int32 code + int32 sequence`. Codes:
  `1/2/3/5` = D5 developer button telemetry (SINGLE/DOUBLE/LONG/RELEASE, no
  product behaviour); **`6` = CANCEL**, **`7` = CAPTURE_TOGGLE**,
  **`8` = LINK_RECOVER**; `9/10/11` = power-off armed/aborted/committed. The
  meaning of a tap is resolved by the app against capture state, not by the
  firmware — see [`product/BUTTON_FEEDBACK_SPEC.md`](product/BUTTON_FEEDBACK_SPEC.md).
- **Agent commands** (`CAB1AB97`) are 4 bytes `[op, arg, hi, lo]`. Ops:
  `LED_COLOR 0x01`, `LED_PATTERN 0x02`, `HAPTIC 0x03`, `STATUS_QUERY 0x04`,
  `NOTIFY 0x05`, **`HABITAT 0x06`** (byte 1 = a habitat cue id, one write per
  cue). The wire format is defined in the server's `commands.ts`, mirrored
  verbatim in `agent_commands.h` and the app's `command_codec.dart`.
- **Legacy DFU**: writing `0x06` to `00001531` sets `GPREGRET = 0xA8` and resets
  into MCUboot (`transport.c`). Host-side OTA steps are not yet documented.

---

## Button grammar (summary)

Full spec, timings, and power state machine:
[`product/BUTTON_FEEDBACK_SPEC.md`](product/BUTTON_FEEDBACK_SPEC.md).

> **Tap = yes. Tap twice = no. Hold is power.**

The A2 IoT button (P0.28, active-low, internal pull-up) carries the whole
product grammar. State supplies the fourth dimension: a single tap means *start
talking* when idle, *stop and file* when capturing, and *yes* when the device is
asking a question. Double tap cancels / dismisses. A ≥2 s hold from off powers
on; a ≥4 s hold while on powers off (gated on the button line going high so the
SoC does not immediately re-wake). Triple tap is a link-recovery hatch. The
developer button D5 is telemetry only.

Two firmware caveats are documented in the spec and hold in the current tree:
the `POWER_BOOT_HOLD` path is not yet armed (the device is simply ON after
boot), and the app-sent haptic vocabulary is blocked by the `AGENT_OP_HAPTIC`
issue above.

---

## Building the firmware

The authoritative, verified-clean instructions are in
[`TOOLCHAIN.md`](TOOLCHAIN.md) and [`BUILD_FIRMWARE.md`](BUILD_FIRMWARE.md). Two
toolchains exist on purpose:

| | nRF Connect SDK 2.9.0 | Zephyr 4.4.2 (upstream) |
|---|---|---|
| Location | `…/Nordic/ncs/v2.9.0` | `~/dev/zephyr/ws` |
| Builds today | **yes, unmodified** | not yet — needs source fixes |
| Binary blobs | ships nrfxlib (SoftDevice Controller) | none (the open-stack target) |

The **board target is `xiao_ble/nrf52840/sense`** (Zephyr hardware-model v2).

> **Corrected from earlier docs:** the board name `xiao_ble_sense` (used in the
> old README and in some conf-file comments) is the hwmodel-v1 name and now
> fails "board not found"; `seeed_xiao_nrf52840_sense` is the UF2 bootloader's
> `--board-id`, never a Zephyr board name. Use `xiao_ble/nrf52840/sense`. The
> current build also uses **`--no-sysbuild`** (the `devkit/` variant has no
> `sysbuild.conf`), not `--sysbuild`.

Build the Wearable variant from `firmware/devkit/` (NCS 2.9.0, environment set
per [`TOOLCHAIN.md`](TOOLCHAIN.md)):

```bash
cd firmware/devkit
west build -b xiao_ble/nrf52840/sense -d build_kelvinlee --no-sysbuild -p always -- \
  -DCONF_FILE="prj_xiao_ble_sense_devkitv2-adafruit.conf;prj_wearable.conf" \
  -DDTC_OVERLAY_FILE="overlay/xiao_ble_sense_devkitv2-adafruit.overlay;overlay/wearable-peripherals.overlay"
```

For the soldered MicroSD stack, append `;prj_wearable_phase3_sd.conf` to
`CONF_FILE`. Expected footprint (TOOLCHAIN.md): FLASH ~296 KB / 788 KB (37%),
RAM ~188 KB / 256 KB (72%). Artifacts land under `build_kelvinlee/zephyr/`:

- `zephyr.uf2` — UF2 drag-and-drop image for the XIAO bootloader
- `zephyr.hex` — full image (J-Link)
- `app_update.bin` — MCUboot OTA image

The Wearable delta over stock is the NeoPixel (`neopixel.c`), the agent-command
service (`agent_commands.c`), the habitat cues (`habitat.c`), and the A2 button
FSM (`button.c`); the Kconfig delta is [`prj_wearable.conf`](../firmware/devkit/prj_wearable.conf).

---

## Flashing

**USB UF2 (recommended for iteration).** Double-tap the XIAO reset button — the
`XIAO-SENSE` USB drive appears — then copy `build_kelvinlee/zephyr/zephyr.uf2`
onto it. The drive unmounts and the device reboots. `firmware/devkit/flash.sh`
automates the copy to `/Volumes/XIAO-SENSE`.

**J-Link** (when the UF2 bootloader is corrupted):

```bash
nrfjprog --program build_kelvinlee/zephyr/zephyr.hex --chiperase --verify --reset
```

**BLE DFU.** The trigger is intact (write `0x06` to the DFU characteristic →
MCUboot), but the host-side procedure is undocumented; use `app_update.bin`.

## Verifying without hardware

The `KelvinLeeSimulator` Xcode project and the Python BLE clients under
`firmware/scripts/devkit/` exercise the whole BLE surface. Recipes:
[`TEST_HARNESS.md`](TEST_HARNESS.md). A post-flash sanity checklist (button
notifications, agent-command writes, mic stream) is in
[`BUILD_FIRMWARE.md`](BUILD_FIRMWARE.md).
