<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable wearable — nRF52840 pin map

Hardware stack:
- **Seeed Xiao nRF52840 Sense** (primary)
- **Adafruit MicroSD BFF** (stacked — SPI card storage)
- **Adafruit IoT Button + NeoPixel BFF** (stacked — A2 button, A3 NeoPixel)
- **Vibration motor** (hand-wired — PWM on a free pin)

Note: this stack **diverges** from the kelvinlee triangle v2 reference under `../hardware/cad/triangle v2 w memory/`. Triangle v2 uses the Adafruit 5769 Audio BFF (speaker + button combo) which owns A1/A2/A3 for I2S. Kelvin's build drops the speaker (no on-device TTS in v1) and repurposes A1–A3 for the IoT Button + NeoPixel BFF + vibration motor.

---

## Pin assignments (Kelvin's build)

| Xiao pin | nRF52840 GPIO | Role | Source | Notes |
|---|---|---|---|---|
| D0 / A0 | P0.02 | SPI2 CS (SD card) | MicroSD BFF | Already wired in upstream devkit overlay |
| D1 / A1 | P0.03 | **PWM0 → vibration motor** | Kelvin's addition | Reclaimed from I2S_SDOUT when speaker is dropped |
| D2 / A2 | P0.28 | **GPIO input → IoT Button** | IoT Button+NeoPixel BFF | Active-low, internal pull-up. Reclaimed from I2S_LRCK. |
| D3 / A3 | P0.29 | **SPI1 MOSI → NeoPixel data** | IoT Button+NeoPixel BFF | WS2812-family, bit-banged over SPI at 4 MHz. Reclaimed from I2S_SCK. |
| D4 / SDA | P0.04 | I2C SDA | Onboard IMU (LSM6DS3TR-C) | Shared I2C bus |
| D5 / SCL | P0.05 | I2C SCL + existing button | KelvinLee devkit button.c | Primary button FSM (SINGLE/DOUBLE/LONG). Keep. |
| D6 / TX | P1.11 | **Haptic motor (existing)** | devkit speaker.c::play_haptic_milli | Reused for second/alternate haptic channel — see below |
| D7 / RX | P1.12 | UART RX / free | — | Unused in v1 |
| D8 / SCK | P1.13 | SPI2 SCK (SD card) | MicroSD BFF | |
| D9 / MISO | P1.14 | SPI2 MISO (SD card) | MicroSD BFF | |
| D10 / MOSI | P1.15 | SPI2 MOSI (SD card) | MicroSD BFF | |

## Internal (not on header pins — do not reassign)

| nRF52840 GPIO | Role |
|---|---|
| P0.16 | PDM microphone DATA |
| P1.00 | PDM microphone CLK |
| P0.11 | LSM6DS3TR-C INT1 |
| P1.08 | LSM6DS3TR-C PWR |
| P0.26 | Onboard RGB LED — Red |
| P0.06 | Onboard RGB LED — Blue |
| P0.30 | Onboard RGB LED — Green |
| P0.17 | Charge LED |
| P0.14 | Battery voltage read enable |
| P0.31 | Battery voltage ADC |
| P0.13 | Charge current select (50 mA / 100 mA) |

## Vibration motor — two options

Kelvin's spec calls for a "vibration motor" but the existing devkit firmware already wires a haptic on **P1.11** (`speaker.c::play_haptic_milli`). Choices:

1. **Reuse P1.11** (recommended) — one haptic channel. `agent_commands.c::HAPTIC` op calls the existing `play_haptic_milli`. Simpler. No second motor needed.
2. **Add a second motor on A1 (P0.03) via PWM** — two independent haptic channels. More patterns, richer feedback vocabulary at the cost of a second motor module.

**Current plan uses option 1**: the overlay reclaims A1 for PWM but does not route it to a motor yet. If Kelvin solders a second motor on A1, the PWM hook is already there; otherwise P1.11 is the sole haptic.

## Pin-conflict checks (verified safe)

- **PDM mic is internal** — does NOT use A0–A3 on the Sense variant; the IoT Button + NeoPixel BFF drops cleanly onto A2/A3.
- **I2S is for speaker only, not mic** — disabling `&i2s0` in `wearable-peripherals.overlay` frees A1/A2/A3 without affecting audio capture.
- **SD card (MicroSD BFF)** defaults to CS=TX (P1.11). The upstream devkit overlay already reroutes CS to A0 (P0.02) — Kelvin's BFF must have the solder-jumper at A0 to match. **Verify visually on the physical BFF before first flash.**
- **Onboard RGB LED pins** (P0.06, P0.26, P0.30) are internal and available for status indication if Kelvin wants a backup signal when NeoPixel fails.

---

## Power budget (estimate)

Under always-on audio capture + BLE advertising:
- nRF52840 core: ~8–15 mA
- PDM mic: ~3 mA
- BLE (100 ms adv interval): ~2–5 mA
- NeoPixel (one LED at full white): ~60 mA peak; idle off = 0 mA
- Vibration motor (P1.11 or A1): ~50–80 mA during pulse, 0 mA idle
- SD card (writes only): ~30 mA during write, ~1 mA idle

Target: <20 mA average → ~12 h on a 250 mAh LiPo, ~30 h on 500 mAh (Kelvin's dual-cell if matched to the triangle v2 reference).

---

## Source material

- Xiao nRF52840 Sense datasheet: `../hardware/docs/xiao-ble-nrf52840-sense.md`
- Adafruit MicroSD BFF: `../hardware/docs/adafruit-microsd-bff.md`
- Adafruit IoT Button + NeoPixel BFF: `../hardware/docs/adafruit-iot-button-neopixel-bff.md`
- Triangle v2 reference (speaker-based): `../hardware/cad/triangle v2 w memory/` — CAD, schematics and assembly photos; the upstream assembly write-up was removed as it described a speaker build this project does not make
- Upstream devkit v2 overlay: `../firmware/devkit/overlay/xiao_ble_sense_devkitv2-adafruit.overlay`
