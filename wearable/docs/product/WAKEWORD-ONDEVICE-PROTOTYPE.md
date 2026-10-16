<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# On-device "Hey Wearable" wake word — prototype plan

**Target:** Seeed XIAO nRF52840 Sense (Cortex-M4F @ 64 MHz, 256 KB RAM, 1 MB flash, PDM mic, Zephyr). **Engine:** TensorFlow Lite Micro (Apache-2.0, first-class Zephyr/nRF Connect SDK module — no per-device fee). **Goal:** detect "Hey Wearable" on-device so audio only streams over BLE *after* wake; on detection, fire the same wake event as the button double-tap (Ask Wearable).

This is an **R&D prototype with a go/no-go gate** — we measure accuracy + power on real hardware before committing to a full build.

## Hard constraints (design to these)
- **RAM:** Opus encode + BLE stack + audio buffers already dominate the 256 KB. KWS working set must fit in **<60 KB** (model + tensor arena + MFCC buffers). Budget: int8 model ≤40 KB flash, tensor arena ≤24 KB RAM.
- **CPU:** 64 MHz M4F. One inference per ~100–200 ms hop must complete in a few ms with CMSIS-NN.
- **Power:** always-on is the whole point — but continuous inference must not erode battery more than the streaming it replaces. Hence the two-stage gate below.

## Architecture — two-stage gate (the key idea)
```
PDM mic (16 kHz) → ring buffer
   └─ Stage 1: cheap energy/VAD gate (reuse existing silence-gate logic)
        └─ only if speech present:
             Stage 2: MFCC (CMSIS-DSP) → TFLM int8 DS-CNN → "hey wearable" score
                  └─ score > T for N consecutive windows → WAKE
```
Stage 1 keeps the NN asleep during silence (most of the time) → most of the power win. Stage 2 only runs on voice.

## Model (Phase 0 — offline, hardware-independent)
- **Frontend:** 16 kHz mono → 40 ms frames / 20 ms hop → 40 MFCC (or log-mel) features over a ~1 s window. Mirror the micro_speech feature pipeline so CMSIS-DSP can reproduce it on-device.
- **Model:** **DS-CNN (depthwise-separable CNN)**, small variant — the proven TFLM KWS topology. Output: 3 classes — `hey_wearable`, `unknown`, `silence`. int8 post-training quantization. Target ~20–40 KB.
- **Training data:**
  - **Positives:** synthetic "Hey Wearable" via multi-voice TTS (Piper, many speakers/accents/speeds) **+ real samples of Kelvin saying it** (record ~50–100 on the actual wearable mic for domain match).
  - **Negatives/unknown:** Google Speech Commands + ambient/TV/conversation clips (the same noise that caused the diarization false-positives — reuse those recordings).
  - **Silence:** room tone.
  - Augment: noise mixing, gain, time-shift, reverb.
- **Export:** TFLite int8 → C array (`xxd`/`convert`) for TFLM.
- **Deliverable:** a reproducible training pipeline (scripts/notebook) + `hey_wearable_model.cc` + an offline accuracy report (FA/FR on a held-out noisy set).

## Firmware (Phase 1 — Zephyr integration)
- Add **TFLM** as a Zephyr module (`CONFIG_TENSORFLOW_LITE_MICRO`), CMSIS-NN kernels enabled.
- New `firmware/devkit/src/wakeword.c`: ring buffer from the existing PDM path → Stage-1 energy gate → CMSIS-DSP MFCC → TFLM invoke → debounced detection (score>T for N windows + refractory period).
- **Detection → action:** emit the existing wake path — same as the A2 double-tap `AGENT_REQUEST` (so the phone's Ask-Wearable capture flow is reused, no new app/server contract). **On-device feedback the instant the word fires (firmware-local, no phone round-trip):** NeoPixel does a brief **green "heard you" blink → blue breathing "listening"** + a rising haptic. The green confirm distinguishes a *voice* wake from a silent button press.
- **Coexistence guard:** run KWS only when NOT already in an Ask-Wearable capture/stream (no point detecting while already listening); ensure thread priority doesn't starve BLE/Opus; respect the RAM budget.
- **Tunables exposed:** score threshold T, consecutive-window N, refractory ms — so we can sweep them during measurement.

## Measurement (Phase 2 — the go/no-go gate, needs hardware)
Kelvin runs these on the flashed Sense:
- **False accepts:** leave it running through TV / a podcast / normal conversation for several hours → count spurious wakes. **Target: < 1 false accept / hour** (ideally / several hours).
- **False rejects:** say "Hey Wearable" ×30 at arm's length in quiet + with background noise → count misses. **Target: > 90 % detection** in quiet, > 80 % in noise.
- **Power:** Nordic **Power Profiler Kit II** — average current with KWS always-on vs the current baseline; derive battery-life delta. **Target: the KWS-on average current is acceptable vs the battery (we define the number once we see the baseline).**
- **Latency:** wake-word-end → wake event < ~300 ms.

## Go/no-go criteria
Proceed to a full build only if: FA < ~1/hr **and** FR < ~15 % in realistic noise **and** the always-on current doesn't cut battery life below target. Otherwise: shrink/retune the model, tighten Stage-1 gating, or fall back to button-only + revisit a phone-side option.

## What I (assistant) build vs what needs hardware
- **I build:** the training pipeline + model export (Phase 0), the `wakeword.c` firmware module + TFLM/CMSIS wiring + detection→wake (Phase 1), and the tunable knobs + a measurement checklist.
- **Kelvin does (hardware-in-the-loop):** record the real "Hey Wearable" samples on the wearable mic, flash, and run the FA/FR/power measurements (Phase 2) — I can't measure physical audio/power.

## Risks / unknowns (ranked)
1. **RAM coexistence** with Opus+BLE — may force a smaller model or running KWS only when not streaming. *Mitigation:* measure the real free-RAM headroom first; budget hard.
2. **Accuracy on a 64 MHz core with a tiny model** — worse FA/FR than commercial engines. *Mitigation:* domain-matched training data (real wearable-mic samples) + the two-stage gate + threshold sweep.
3. **Always-on power** unmeasured on this board. *Mitigation:* Stage-1 VAD gating; measure early with PPK2.
4. **PDM mic feature parity** — on-device MFCC must match the training frontend. *Mitigation:* mirror micro_speech's CMSIS-DSP pipeline exactly; validate with a known clip.

## SD card (MicroSD BFF) — enables on-device buffering
The wearable will have the MicroSD BFF (SPI2: CS=A0/P0.02, SCK=D8, MISO=D9, MOSI=D10). Firmware support already exists (`firmware/devkit/src/sd_card.c` — mounts the card, writes audio files). This unlocks **on-device buffering**, which strengthens the device-first pipeline:
- **Offline capture:** when the phone is disconnected, the wearable records audio (or post-wake clips) to SD and syncs when the link returns — no lost capture.
- **Pre-wake ring buffer:** keep a few seconds of rolling audio on SD/RAM so a wake-word capture includes the moment *before* the trigger (no clipped first word).
- **Local note/clip store:** short voice notes can be buffered on the wearable, then drained to the phone.
- **Not for the model:** the KWS model lives in flash (compiled in); the SD is for audio/data only.

The wake word + SD together are the foundation of "process/buffer on the device, stream only what matters" — the wearable can wait for "Hey Wearable" (or a button) and only then push audio, buffering locally in the meantime.

## Sequencing
1. Confirm real free-RAM headroom on the current Wearable firmware (quick — instrument the build).
2. Phase 0 training pipeline + first model + offline accuracy.
3. Phase 1 firmware module (start behind a `CONFIG_WEARABLE_WAKEWORD` flag so it doesn't risk the working firmware).
4. Phase 2 measurement → go/no-go.
