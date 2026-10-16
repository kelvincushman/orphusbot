<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Building the Wearable firmware (nRF52840)

Target: **Seeed Xiao nRF52840 Sense** with MicroSD BFF + IoT Button+NeoPixel BFF stacked.
Upstream firmware: `devkit/` variant of the KelvinLee Zephyr tree — currently at **DK2 v2.0.10** (tag `KelvinLee_DK2_v2.0.10`, released 2026-04-26 by `@beastoin`). Plus Wearable additions (`neopixel.c`, `agent_commands.c`, IoT button on A2).


## Upstream compatibility

| Upstream DK2 release | Date | Key fixes | Our status |
|---|---|---|---|
| v2.0.10 | Apr 2026 | KConfig cleanup, battery-drain-in-sleep fix, button function cleanup | **Current baseline** |
| v2.0.8  | Dec 2025 | Battery level reports, BLE adv name, boot fix | Subsumed by v2.0.10 |
| v2.0.7  | Dec 2025 | Device startup post-OTA | Subsumed by v2.0.10 |
| v2.0.6  | Dec 2025 | Connectivity after activation | Subsumed by v2.0.10 |
| v2.0.5  | Dec 2025 | BLE button logic | Subsumed by v2.0.10 |

The Wearable build identifies as `wearable-0.1.0+dk2-2.0.10` in the BLE Device Information Service (`prj_wearable.conf::CONFIG_BT_DIS_FW_REV_STR`). On nRF Connect, a paired device will show `Wearable KelvinLee DK2` as its model — that's the operator-visible "am I running the right fork?" signal.

## Fallback to upstream stock

If Kelvin needs to return to a known-good stock build (for instance while debugging whether a bug is from Wearable's additions or upstream):

1. Obtain the stock `DK2_v2.0.10.uf2` image from your own archive of the upstream release
2. Double-tap the XIAO reset button to enter bootloader (USB drive `XIAO-SENSE` appears)
3. Drag the `.uf2` onto it. Device reboots into upstream stock.
4. To return to Wearable: re-drag `build_wearable/zephyr/zephyr.uf2`.

No state loss on the wearable itself (SD card contents persist across firmware swaps); conversations that were mid-stream to Wearable will be lost — normal.

## Prerequisites (one-time)

1. Install the toolchain per [`TOOLCHAIN.md`](TOOLCHAIN.md) — both the blob-free upstream Zephyr 4.4.2 target and the NCS 2.9.0 baseline are documented there, with the exact `west build` line and the traps that cost time.
2. Flash MCUboot once via J-Link (steps in the same guide).

## Build — Wearable variant

From `devices/wearable-kelvinlee/firmware/devkit/`:

```bash
west build -b xiao_ble_sense -d build_wearable \
  --sysbuild \
  -- \
  -DCONF_FILE="prj_xiao_ble_sense_devkitv2-adafruit.conf;prj_wearable.conf" \
  -DDTC_OVERLAY_FILE="overlay/xiao_ble_sense_devkitv2-adafruit.overlay;overlay/wearable-peripherals.overlay"
```

Artifacts land under `build_wearable/zephyr/`:
- `zephyr.hex` — full image (J-Link programming)
- `zephyr.uf2` — UF2 drag-and-drop image for the XIAO bootloader
- `app_update.bin` — MCUboot over-the-air update image

## Flash

### USB UF2 (recommended for iteration)
1. Double-tap the XIAO reset button — the USB drive `XIAO-SENSE` appears.
2. Copy `build_wearable/zephyr/zephyr.uf2` onto it.
3. The drive unmounts and the device reboots into the new firmware.

### J-Link (when UF2 bootloader is corrupted)
```bash
nrfjprog --program build_wearable/zephyr/zephyr.hex --chiperase --verify --reset
```

### OTA via nRF Connect mobile app
OTA over BLE is not yet documented for this project. The upstream procedure was removed with the rest of the nRF5340-specific docs it lived in; the DFU trigger itself (a write of `0x06` to the DFU characteristic sets `GPREGRET = 0xA8` and resets into MCUboot) is intact in `transport.c`. Writing the host-side steps is open work. Use `app_update.bin` from the build.

## What this build changes vs stock KelvinLee

| Area | Stock devkit v2 | Wearable build |
|---|---|---|
| I2S speaker | A1/A2/A3 wired to Adafruit 5769 Audio BFF | **Disabled**; pins freed |
| IoT Button | — | **A2 (P0.28)** — emits `AGENT_REQUEST` event over the existing button GATT char 0x23BA7924 |
| NeoPixel | — | **A3 (P0.29)** — SPI1 bit-bang WS2812, one LED, habitat-alert patterns |
| Vibration motor (alt) | Existing haptic on P1.11 | Existing haptic + optional PWM on A1 (P0.03) |
| GATT service | Photo/audio/button only | **+ Wearable command service (0xCAB1AB90…)** with one characteristic 0xCAB1AB97 for LED/haptic control |

Full pin map: `./PIN_MAP.md`.

## Verifying the build without real hardware

The `KelvinLeeSimulator` (Xcode project at `../firmware/scripts/devkit/KelvinLeeSimulator/`) and the Python test clients (`../firmware/scripts/devkit/{client,local_client,discover_devices,play_sound_on_friend}.py`) can exercise the BLE surface end-to-end. See `./TEST_HARNESS.md` for recipes.

## Quick post-flash sanity

With the device paired to your Mac via nRF Connect:

1. **Button GATT** — subscribe to UUID `23BA7924-...` notifications; press A2 → expect a notification with first byte `0x06` (AGENT_REQUEST). Tap D5 → first byte `0x01` (SINGLE_TAP), `0x02` (DOUBLE), `0x03` (LONG).
2. **Agent commands** — write a 4-byte packet to `CAB1AB97-0000-1000-8000-00805F9B34FB`:
   - `01 00 C8 3C` → LED_COLOR green (R=0 G=200 B=60) → NeoPixel lights green
   - `02 03 07 D0` → LED_PATTERN PULSE for 2000 ms → NeoPixel pulses 2 s
   - `03 10 00 78` → HAPTIC SINGLE for 120 ms → P1.11 motor buzzes
   - `01 00 00 00` → LED off
3. **PDM mic + BLE audio** — open a Deepgram `listen.py` client (`../firmware/scripts/devkit/client.py`) and speak — transcript should stream.
