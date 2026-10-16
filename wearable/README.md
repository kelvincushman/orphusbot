<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# OmarchyWearable

**An open, self-hosted AI wearable.** A body-worn device that captures ambient
audio and transcribes it — on your own phone, or on your own server. No cloud
account, no vendor lock-in, no sign-in. The phone is the filtering boundary:
with on-device transcription enabled, **raw audio never leaves your hardware.**

Three parts, each in its own subdirectory with a BLE or HTTP boundary between
them:

- **Firmware** — a Zephyr RTOS fork for the Seeed **XIAO nRF52840 Sense**. Opus
  audio over BLE, a single-button grammar, a NeoPixel + haptic feedback
  vocabulary, and MicroSD offline capture.
- **App** — a **Flutter** companion (Android + iOS) that pairs to the device
  over BLE and transcribes speech **on-device** (zipformer ASR + speaker
  diarization), with an optional server path.
- **Server (optional)** — a self-hosted device channel and a self-hosted STT
  service. The device works fully standalone without it.

Licensed **MIT**. Built as a fork of an MIT-licensed upstream (Based Hardware
DK2 baseline v2.0.10) with an OmarchyWearable integration layer on top; see
[Licensing](#licensing).

---

> **This folder is part of [OrphusBot](../README.md).** It was a standalone
> repository and moved here as a cleaned snapshot (personal hostnames, raw
> recordings and machine-generated files removed; history not carried over).
> OrphusBot's server implements the device channel described below; see
> OrphusBot [DESIGN §9](../docs/DESIGN.md) for how the wearable drives bots.

## What it is

A wearable that listens so you don't have to remember. It streams what it hears
to your phone, which turns it into text and (optionally) hands it to an agent you
run yourself. It talks back to you without a screen — colour and vibration only,
a deliberately tiny vocabulary of six task signals and eight button cues.

- **On-device transcription.** The phone runs a streaming zipformer for a live
  preview and an offline zipformer for the accurate saved transcript, with
  Silero VAD and sherpa punctuation — measured at **11.19% WER** on the wearable
  audio channel. Nothing is uploaded in on-device mode.
- **Persistent speaker identity.** Enrol your own voice and name others;
  voiceprints are matched across your whole history and stored only on the
  phone. Diarization and embedding run on-device (sherpa-onnx / WeSpeaker).
- **A one-button device you can use blind.** *Tap = yes. Tap twice = no. Hold is
  power.* A steady-white LED is a non-suppressible **capture-consent** signal for
  people around you.
- **Works with no server.** BLE + on-device STT is a complete product. Point it
  at a self-hosted server only if you want cloud-grade final transcripts
  (Qwen3-ASR, **6.24% WER**) or an agent loop.
- **No proprietary dependencies by design.** No third-party account, no
  telemetry, no crash reporter. The open-stack firmware target uses a blob-free
  Zephyr.

---

## Architecture

```
   Wearable (nRF52840 Sense)         Phone — Flutter app                Optional server (self-hosted)
   ─────────────────────────         ───────────────────                ─────────────────────────────
   PDM mic ─► Opus 16 kHz mono
        │
        │  audio  (GATT 19B10001)
        └────────────────────────►  device_bridge.dart ──┬── on-device STT  ← default privacy path
   A2 button                                              │   zipformer + Gemma tidy + diarization
        │  events (GATT 23BA7925)                         │   (audio stays on the phone)
        └────────────────────────►  device_bridge.dart    │
        ▲                                                  └── cloud mode ──WS──►  /api/device/ws/audio
        │                                                                            │  Opus → PCM16
        │  cues   (GATT 0xCAB1AB97)                                                  ▼
   NeoPixel + haptic  ◄──────────── command poll  ◄───HTTP─── /api/device/command/poll   Qwen3-ASR-0.6B
                                                                                    (accurate batch final)
```

BLE binds the wearable to the phone; WS + HTTP (optionally) bind the phone to a
server. The 4-byte command wire format is defined once (server `commands.ts`) and
mirrored verbatim in firmware (`agent_commands.h`) and app (`command_codec.dart`).

---

## Quickstart

### Firmware

Target: XIAO nRF52840 Sense with the MicroSD BFF and IoT Button + NeoPixel BFF
stacked. Board target **`xiao_ble/nrf52840/sense`**; build from `firmware/devkit/`
with the toolchain set up per [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md):

```bash
cd firmware/devkit
west build -b xiao_ble/nrf52840/sense -d build_kelvinlee --no-sysbuild -p always -- \
  -DCONF_FILE="prj_xiao_ble_sense_devkitv2-adafruit.conf;prj_wearable.conf" \
  -DDTC_OVERLAY_FILE="overlay/xiao_ble_sense_devkitv2-adafruit.overlay;overlay/wearable-peripherals.overlay"
```

Flash by double-tapping reset and dragging `build_kelvinlee/zephyr/zephyr.uf2`
onto the `XIAO-SENSE` USB drive. Full guide: [`docs/HARDWARE.md`](docs/HARDWARE.md)
· [`docs/BUILD_FIRMWARE.md`](docs/BUILD_FIRMWARE.md).

### App

Pinned to **Flutter 3.44.1 / Dart 3.10.7** via fvm:

```bash
cd app
fvm flutter pub get
fvm flutter build apk --debug
```

On-device STT needs a real arm64 Android or iOS 16+ device (~8 GB RAM) and the
models installed from **Settings → On-device model**. Full guide:
[`docs/APP.md`](docs/APP.md).

### Server (optional)

The device works standalone; skip this unless you want server transcription or
agents. The server is [OrphusBot](../README.md), which this folder is part of. The device-channel protocol has an in-repo reference copy under
[`server-contract/`](server-contract); the live services run in a separate
self-hosted server. Details, endpoints, the Qwen3-ASR service, and the
Cloudflare exposure model: [`docs/SERVER.md`](docs/SERVER.md).

---

## Hardware summary

| Layer | Part |
|---|---|
| MCU | Seeed XIAO nRF52840 Sense (BLE 5, onboard PDM mic + IMU) |
| Storage | Adafruit MicroSD BFF (offline capture) |
| I/O | Adafruit IoT Button + NeoPixel BFF (A2 button, A3 WS2812) |
| Haptic | Vibration motor (P1.11), optional PWM motor (A1) |

The build **drops the speaker** from the upstream *triangle v2* reference (no
on-device TTS in v1), freeing A1–A3 for the button, NeoPixel, and motor.
Authoritative pin table: [`docs/PIN_MAP.md`](docs/PIN_MAP.md). Enclosures and
board datasheets live under [`hardware/`](hardware).

---

## Repository layout

```
firmware/       Zephyr RTOS firmware (C) — devkit/ is the Wearable variant
app/            Flutter companion app (Dart) — everything under lib/wearable/
hardware/       CAD (enclosures), schematics, board datasheets
server-contract/  Reference copy of the server device channel (TypeScript)
docs/           Documentation (see below)
tools/          macOS simulator + Python BLE test clients
scripts/        ADB end-to-end scenarios + copyright-header injector
feature-research/  ASR benchmark harness + notes
```

## Documentation

| Doc | What it covers |
|---|---|
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | Board, peripherals, BLE GATT map, build + flash |
| [`docs/APP.md`](docs/APP.md) | App architecture, on-device STT, speaker identity, capture modes, privacy |
| [`docs/SERVER.md`](docs/SERVER.md) | Optional server: device channel, Qwen3-ASR, Cloudflare exposure |
| [`docs/PIN_MAP.md`](docs/PIN_MAP.md) | **Authoritative** nRF52840 pin assignments |
| [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md) | Firmware toolchains (NCS 2.9.0 / upstream Zephyr) and the traps |
| [`docs/BUILD_FIRMWARE.md`](docs/BUILD_FIRMWARE.md) | Firmware build, flash, upstream fallback |
| [`docs/HABITAT_ALERTS.md`](docs/HABITAT_ALERTS.md) | LED + haptic vocabulary and the packet authority |
| [`docs/product/BUTTON_FEEDBACK_SPEC.md`](docs/product/BUTTON_FEEDBACK_SPEC.md) | Button gestures, byte protocol, power state machine |
| [`docs/ARCHITECTURE_CAPTURE_PIPELINE.md`](docs/ARCHITECTURE_CAPTURE_PIPELINE.md) | End-to-end capture pipeline + privacy boundary |
| [`docs/research/ASR_CANDIDATES.md`](docs/research/ASR_CANDIDATES.md) | ASR model selection with measured WER |
| [`docs/research/SPEAKER_IDENTITY.md`](docs/research/SPEAKER_IDENTITY.md) | On-device persistent speaker identity |
| [`docs/research/ON_DEVICE_STT.md`](docs/research/ON_DEVICE_STT.md) | Why the on-device STT design changed |
| [`docs/product/`](docs/product), [`docs/design/`](docs/design) | PRDs, navigation, design system, screenshots |

**A note on paths in older docs.** Several docs predate this repo's extraction
from a monorepo and reference the old layout. Translate: `devices/wearable-*/…`
→ repo root; `src/harness/device/…` → `server-contract/src/device/…`;
`tests/device.test.ts` → `server-contract/tests/device.test.ts`. The
`server-contract/` tree is a reference copy; the running server lives elsewhere.

---

## Licensing

OmarchyWearable code is **MIT** — Copyright (c) 2025-2026 Kelvin Lee
([`LICENSE`](LICENSE)). Portions of the firmware and app remain © 2024 Based
Hardware Contributors under the MIT licence in
[`LICENSE-UPSTREAM`](LICENSE-UPSTREAM); MIT requires that notice to ship with the
code, so that file must not be removed.

Downloaded models keep their own licences (installed by the app; not vendored in
this repo):

| Model | Role | Licence |
|---|---|---|
| zipformer-small-en / streaming zipformer | On-device ASR | Apache-2.0 |
| Silero VAD v5 | Voice-activity detection | MIT |
| pyannote segmentation 3.0 | Diarization segmentation | MIT |
| WeSpeaker ResNet34-LM | Speaker embeddings | Toolkit Apache-2.0 / weights CC-BY-4.0 |
| Gemma 4 E2B | On-device text tidy | Google Gemma Terms of Use |
| Qwen3-ASR-0.6B | Self-hosted server STT | Apache-2.0 |

### Security notes

- **MCUboot keys** (`firmware/bootloader/mcuboot/*.pem`) are the upstream
  **sample** keys — public demo keys. **Regenerate them before signing any
  production OTA image.**
- **MCUboot sample keys** are byte-identical to the ones published in
  `mcu-tools/mcuboot`; they are listed in the repository's `.gitleaksignore`
  for that reason.
- **Firebase** has been removed from the app; no Firebase config files are
  tracked. Older history (not published) contained client config keys.
- **`app/setup/prebuilt/debug.keystore`** is a throwaway Android *debug*
  keystore with the standard debug passwords, so anyone can build a debug APK.
  Never use it for release builds.
- Real secrets (`.env`, release keystores, `local.properties`) are gitignored and
  were never tracked.

---

## Provenance

This repository was extracted from a larger monorepo as a standalone project
with its git history preserved. The firmware and Flutter app began as a fork of
an MIT-licensed upstream (Based Hardware) and have been rebranded throughout;
firmware baseline **DK2 v2.0.10**. Alongside the code it collects the project's
PRDs, design system, hardware guides, and app screenshots so the project is
self-contained.
