<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->
<!-- Source: https://learn.adafruit.com/adafruit-microsd-card-bff -->
<!-- Fetched: 2026-04-18. Partial mirror — Adafruit's guide is multi-page and nav-gated; see source for full walkthrough. -->

# Adafruit microSD Card BFF for QT Py and Xiao

## Part number
- **5683** — Adafruit microSD Card BFF Add-On for QT Py and Xiao

## Form factor
Fits onto the back of any QT Py or Xiao board. Can be soldered directly or mounted with removable pin headers ("backs of the boards facing each other"). Shares the hardware SPI pins on the Xiao.

## Pin mapping on Xiao

| Function | Xiao Pin (Silk) | nRF52840 GPIO | Notes |
|---|---|---|---|
| SPI SCK | D8 | P1.13 | Hardware SPI clock |
| SPI MISO | D9 | P1.14 | Hardware SPI data in |
| SPI MOSI | D10 | P1.15 | Hardware SPI data out |
| CS (default) | D6 / TX | **P1.11** | ⚠ See conflict note below |
| CS (alt 1) | D7 / RX | P1.12 | Solder-jumper |
| CS (alt 2) | D0 / A0 | P0.02 | Solder-jumper |
| CS (alt 3) | D1 / A1 | P0.03 | Solder-jumper |

> Adafruit quote: *"The default chip select pin (CS) is TX. However, this can be changed to RX, A0, or A1 via solder jumpers."*

## ⚠ Pin conflict with Wearable kelvinlee devkit firmware

The stock BFF CS routes to **D6 / TX / P1.11**. The existing kelvinlee devkit firmware uses **P1.11 as the haptic motor enable line** (`devkit/src/speaker.c::play_haptic_milli()`). These cannot coexist unless one is moved.

**Resolution for this build:** solder-bridge the CS jumper to **A0 (P0.02)** on the BFF. The devkit overlay (`xiao_ble_sense_devkitv2-adafruit.overlay`) is already wired for SD CS on P0.02 — this matches.

Verify during the Phase 2.1 pin-map audit that the physical BFF jumper matches the overlay.

## Arduino setup

- Library: **"SDFat - Adafruit Fork"** (search "Adafruit SDFat" in Arduino Library Manager)
- Baud: 115200 for Serial Monitor
- Example sketch: https://github.com/adafruit/Adafruit_Learning_System_Guides/blob/main/microSD_BFF_Examples/ReadWriteQT/ReadWriteQT.ino

## What this doc does NOT cover

Adafruit's learn-guide is multi-page and partially rendered under JS navigation. The fetched content did not include:

- Card-detect line wiring (likely absent on this BFF but not confirmed)
- Bypass cap / pullup specifications
- Power draw under heavy write load

For those details, consult the source URL in the header and the product page at https://www.adafruit.com/product/5683.
