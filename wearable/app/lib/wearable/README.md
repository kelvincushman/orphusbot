<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# `lib/wearable/` — the capture app

This directory *is* the app. `lib/main.dart` boots it; there is no upstream
KelvinLee/Omi app, no Firebase and no cloud account left in the tree. The app
pairs to the wearable over BLE, transcribes on the phone, and — optionally —
pushes the resulting text to a self-hosted Wearable server.

The pipeline and the measurements behind it are in
[`docs/ARCHITECTURE_CAPTURE_PIPELINE.md`](../../../docs/ARCHITECTURE_CAPTURE_PIPELINE.md).
This file is the map of the code.

## Boot (`lib/main.dart`)

1. `initOpus(...)` — the wearable streams Opus; `opus_dart` needs its native
   library before `LocalOpusDecoder` can be built.
2. `FlutterGemma.initialize()` — service registry only. **No STT backend is
   registered**; ASR runs through `sherpa_onnx`, not LiteRT.
3. `GemmaEngine.instance.warmInstalledState()` — rehydrates flutter_gemma's
   active-model record, because `initialize()` does not, and without it the
   polish model reads as "not installed" after every restart.
4. RevenueCat (non-fatal), `FlutterBluePlus.setOptions(restoreState: true)`.

`WearableRoot` has **no gate**: pairing to a server is optional and lives in
Settings. Pairing to the wearable is the first-run flow.

## The capture path, file by file

| File | Responsibility |
|---|---|
| `device_bridge.dart` | `WearableDeviceBridge.attach(device)` — subscribes to the firmware's GATT audio + button characteristics, reassembles frames (`wearable_audio_session.dart`), decodes Opus → PCM16, runs the button grammar, and owns the capture window. In on-device mode it feeds `UtteranceBuffer`, then diarises, identifies the speaker, transcribes, logs to `OnDeviceTranscriptLog`, and pushes text via `WearableClient`. In cloud mode it streams raw audio to the server WS instead. Starts/stops `CaptureService`. |
| `capture_service.dart` + `android/.../WearableCaptureService.kt` | Android foreground service that keeps the process out of the *cached* state while the wearable streams. Changes process importance only; runs no background work. |
| `wearable_audio_session.dart` | BLE packet → codec frame reassembly for one recording. |
| `phone_mic.dart` | `PhoneMicStreamer` — the phone-microphone path (16 kHz PCM via `record`). Used by the dictation page and when the wearable is absent. Same `UtteranceBuffer` → `ZipformerTranscriber` chain. |
| `wearable_client.dart` | HTTP + WebSocket client for the optional server: `POST /api/device/text` (on-device transcripts), `/api/device/event`, `/api/device/ws/audio` (cloud mode only), command polling. mDNS discovery; credentials in `flutter_secure_storage`. |
| `command_codec.dart` | Encodes JSON command packets into the 4-byte GATT payload for `0xCAB1AB97` (habitat LED/haptic cues). |
| `local_llm/audio_buffer.dart` | `UtteranceBuffer` — PCM16 accumulation, button-window / continuous segmentation, pre-roll, gain. Pure Dart, unit-tested. |
| `local_llm/opus_pcm_decoder.dart` | Opus (codec id 20/21) → PCM16; linear16 pass-through. |
| `local_llm/transcription_mode.dart` | `cloud` / `onDevice` preference and `button` / `continuous` segmentation. **Default is `cloud`** — on-device is opt-in under *Settings → Voice & Hands-Free → On-device transcription*. |
| `local_llm/capture_state.dart`, `capture_diagnostics.dart`, `capture_mute.dart` | Recording/transcribing banner state, in-memory telemetry for the Transcripts page, session mute. |
| `local_llm/sd_storage_codec.dart` | Decoder for the firmware's SD-card offline audio pages (the firmware side is currently disabled — see the architecture doc). |

## Speech recognition — `sherpa_onnx`, three models

Everything below runs on the phone. Audio never leaves it on this path; only
text does, and only if a server is paired.

| File | Responsibility |
|---|---|
| `local_llm/zipformer_provisioner.dart` | Downloads **zipformer-small-en** (int8 transducer: encoder + decoder + joiner + `tokens.txt`) plus **Silero VAD v5**. Five files, ~30 MB, each pinned to an immutable HF revision with byte count + SHA-256. Stored under Application Support `/asr`. |
| `local_llm/zipformer_transcriber.dart` | The **offline pass** — the transcript that gets saved. Silero VAD runs first as a *gate* (no speech anywhere → skip, never decode silence); any speech → normalise gain and decode the whole clip. No windowing: the transducer takes an utterance of any length. Logs realtime factor per utterance. |
| `local_llm/streaming_provisioner.dart` | Downloads the **streaming zipformer** (`chunk-16-left-128`, int8) — four files, 73,440,167 bytes (shown as ~70 MB), pinned the same way. Optional. |
| `local_llm/streaming_transcriber.dart` | The **live preview** — text while the wearer is still speaking. Preview only: when the window closes the offline pass re-decodes the whole utterance and that is the artifact. Absent model → no preview, capture unchanged. |
| `local_llm/gemma_transcriber.dart` | **Dead.** `GemmaTranscriber` is unreachable since Gemma stopped seeing audio; only `sanitizeTranscript` (used by the zipformer path) and the dictionary prompt builder are still referenced. Scheduled for removal. |
| `services/vocabulary_store.dart` | The personal dictionary. Today it only feeds the (dead) Gemma transcription prompt; wiring it into sherpa hotwords is pending. |

## Speaker identity — diarisation + registry

| File | Responsibility |
|---|---|
| `local_llm/diarization_provisioner.dart` | Downloads **pyannote segmentation 3.0** (~6.6 MB) and **WeSpeaker ResNet34-LM** (~25.3 MB) from k2-fsa release assets. Stored under Application Support `/diarization`. |
| `local_llm/diarization_engine.dart` | `OfflineSpeakerDiarization` wrapper → `Talker N` segments per clip. |
| `local_llm/owner_voice.dart` | Owns the WeSpeaker extractor. `extractRobustEmbedding` blends a whole-clip pass with 2.0 s / 1.0 s windows (≤ 7 passes, logged). The owner is the registry profile with `isOwner: true`; legacy SharedPreferences enrolments are migrated once. |
| `local_llm/speaker_registry.dart` | Persistent, named voices. Pure Dart. Scores a profile by the max over its vectors; refuses three ways — similarity floor 0.65, runner-up margin 0.07, ≥ 3 s pooled evidence. Searches **named profiles only**, capped at 10. Enrolled vectors are immutable; observed vectors FIFO-capped at 20. Every profile is stamped with model id + dim so a model swap means "re-enrol", not a RangeError. Storage: JSON index + one packed Float32 file per profile under Application Support `/speakers`. |
| `local_llm/transcript_log.dart` | `OnDeviceTranscriptLog` — in-memory feed, capped at 50 entries, for the Transcripts page. Each entry carries its cluster embedding, pooled duration and clip id so a label can be renamed without re-running anything. `relabel()` rewrites one clip + cluster. |
| `widgets/name_speaker_sheet.dart` | Tap a talker label → "This is me" / a known name / "someone new". Enrols the exact vector the registry just scored from **wearable** audio, so enrolment and matching share a channel. Relabels that clip only; never rewrites history silently. |
| `pages/settings/wearable_enroll_voice_page.dart` | Owner enrolment from the **phone** mic (~8 s). Known to be the wrong channel — the tap-to-name sheet is the path that matters; a wearable-mic enrolment flow is planned. |

Identity is decided once per **cluster**, not per segment: the diariser
already grouped segments by speaker, so the bridge pools each cluster's
speech, embeds once, and lets the registry see the real duration. Confident
matches are *not* written back into profiles (template self-update is a
documented poisoning loop); profiles grow only when a person names a voice.

## Gemma — text polish only, optional

| File | Responsibility |
|---|---|
| `local_llm/model_provisioner.dart` | `GemmaModelProvisioner` — download / sideload / remove **Gemma 4 E2B** (`gemma-4-E2B-it.litertlm`, 2,588,147,712 bytes ≈ 2.6 GB, universal CPU+GPU build) pinned to an immutable HF commit with byte count + SHA-256. 90 s stall watchdog on the download. |
| `local_llm/gemma_engine.dart` | Loads the active model. **CPU backend, deliberately**; `supportAudio: false`. Gemma never sees audio. |
| `local_llm/polish.dart` | Text → text in a chosen tone (Polish / Key points / Formal / Short). Treats the model as untrusted: `sanitizePolish` rejects refusals, preambles and rewrites that expand beyond 2×; on any failure the original transcript is returned. Serialised, one rewrite at a time. |

Why E2B and CPU, in one line each (full reasoning in
`docs/research/ON_DEVICE_STT.md`): E4B (3.66 GB) is a documented OOM on 8 GB
Samsung devices, and the GPU path on Mali/Xclipse produced deterministic
numeric corruption (2/13 clean outputs vs 13/13 on CPU). Polish is used from
the dictation page's tone chips; it does not run automatically on wearable
transcripts today.

## Model downloads — where they are in the UI

*Settings → Voice & Hands-Free → On-device model* (`pages/settings/wearable_on_device_model_page.dart`):

| Tile | Model | Size | Required? |
|---|---|---|---|
| Download model | zipformer-small-en + Silero VAD | ~30 MB | Yes, for on-device transcription |
| Live preview (optional) | streaming zipformer | ~70 MB | No — preview only |
| Polish (optional) | Gemma 4 E2B | ~2.6 GB | No — tone chips on the dictation page |

*Settings → Diarization models* (`pages/settings/wearable_diarization_page.dart`):
pyannote segmentation + WeSpeaker embedding, ~32 MB, needed for `Talker N`
labels and the speaker registry.

All sizes shown in the UI are read from the provisioners' own `sizeLabel`, so
the label and the file cannot drift apart (they did, once).

## Requirements

Real Android (arm64) device; the on-device toggle refuses emulators
(`platformSupportsOnDevice`). 8 GB RAM is the target class — the polish model
was sized for it. **Flutter 3.44.x / Dart ≥ 3.10.7** (`.fvmrc`, driven by
`flutter_gemma`); use `fvm flutter`, the Homebrew Flutter cannot resolve
`flutter_gemma`.

Pinned: `sherpa_onnx` **1.13.2**, `flutter_gemma` **1.7.4**, `opus_dart`
**3.0.1**, `flutter_blue_plus` **1.33.6** (`pubspec.lock`).

## Everything else in this directory

`pages/`, `providers/`, `widgets/`, `models/`, `chat/` are the app shell —
dashboard, transcripts feed, dictation page, tasks/hive/schedules views backed
by the optional server, settings, pairing and scan pages, and the developer
habitat-alert test page. `security/` is the app lock. `wearable_theme.dart` /
`wearable_tokens.dart` transcribe `docs/design/design-tokens.md`.

## Known non-issues

- `wearable_client.dart` uses `IOWebSocketChannel`; there is no web target.
- `multicast_dns` does not work on iOS simulators on M-series Macs (Apple's
  mDNS sandboxing). Pairing there must use the manual URL path.
- Transcripts are the recogniser's native output: upper-case, no punctuation.
  That is the model, not a bug; a cheap punctuation/casing stage is planned.
