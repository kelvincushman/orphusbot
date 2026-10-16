<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# The companion app

A Flutter app (Android + iOS) that pairs to the wearable over **BLE** and,
optionally, to a server over **WebSocket + HTTP**. Its defining feature is a
fully **on-device** speech-to-text pipeline: with on-device transcription
selected, raw audio never leaves the phone.

The whole integration lives under `app/lib/wearable/`; `app/lib/main.dart` is a
thin entrypoint (a handful of init steps, the providers, one route). The app is
a fork of a larger upstream app and coexists with the upstream stack until it is
stripped, but everything documented here is the OmarchyWearable layer.

Related reading:

- ASR model selection + measured WER: [`research/ASR_CANDIDATES.md`](research/ASR_CANDIDATES.md)
- Why Gemma stopped doing ASR: [`research/ON_DEVICE_STT.md`](research/ON_DEVICE_STT.md)
- Speaker-identity design: [`research/SPEAKER_IDENTITY.md`](research/SPEAKER_IDENTITY.md)
- End-to-end pipeline + privacy boundary: [`ARCHITECTURE_CAPTURE_PIPELINE.md`](ARCHITECTURE_CAPTURE_PIPELINE.md)
- The optional server it talks to: [`SERVER.md`](SERVER.md)

---

## Layout

| Path | What lives there |
|---|---|
| `wearable_client.dart` | Server transport — HTTP + WS, mDNS discovery, bearer/pairing token in `flutter_secure_storage` |
| `device_bridge.dart` | BLE ↔ server bridge: forwards audio + button events, drains the LED/haptic command queue |
| `capture_service.dart` | Starts/stops the Android foreground service that keeps the BLE link alive off-screen |
| `local_llm/` | On-device STT (zipformer ASR + Gemma text-tidy) and sherpa-onnx diarization / speaker ID |
| `command_codec.dart` | Byte-for-byte mirror of the server's `commands.ts` wire format |
| `pages/`, `widgets/` | UI — `wearable_home_page.dart` is the shell; pairing, dictation, settings, habitat test |
| `providers/` | `ChangeNotifier`s for connection, device, tasks, chat, schedules |
| `wearable_theme.dart` | The single light theme (no dark variant) |

---

## The on-device STT pipeline

> **Important correction.** Earlier docs (including the app README) say the app
> "transcribes speech on-device with Gemma". That is no longer how it works.
> **Zipformer (sherpa-onnx) does the transcription; Gemma only tidies the text**
> that zipformer produced and never sees audio. The change is recorded in
> [`research/ON_DEVICE_STT.md`](research/ON_DEVICE_STT.md) and
> [`research/ASR_CANDIDATES.md`](research/ASR_CANDIDATES.md), and is stated in
> `local_llm/model_provisioner.dart`.

The pipeline is a deliberate two-model design plus a text stage. All numbers
below are measured on the *wearable channel* (this firmware's Opus settings +
reverb + 10 dB babble, 120 utterances) and are recorded in
[`research/ASR_CANDIDATES.md`](research/ASR_CANDIDATES.md) — none are invented.

```
BLE Opus ─► decode ─► ┌─ StreamingTranscriber ─► live preview text (scrolls as you speak)
                      │      streaming zipformer, 16.26% WER, optional
                      └─ ZipformerTranscriber ──► saved transcript (the record)
                             offline zipformer-small + Silero VAD, 11.19% WER
                                     │
                                     ▼
                              Punctuator (sherpa) ─► punctuation + casing
                                     │
                                     ▼
                              Gemma tidy (agreement-gated) ─► final note
```

**1. Live preview — `streaming_transcriber.dart`.** A sherpa-onnx
`OnlineRecognizer` (`sherpa-onnx-streaming-zipformer-en-2023-06-26`) decodes as
audio arrives, so text appears within a chunk of being spoken. It scores 16.26%
WER on the channel — about 45% more errors than the offline model — which is
fine for text you watch scroll and correct. It is **optional**: if the streaming
model is not installed the preview simply does not appear and capture behaves
exactly as before.

**2. Saved transcript — `zipformer_transcriber.dart`.** When the capture window
closes, a sherpa-onnx `OfflineRecognizer`
(`sherpa-onnx-zipformer-small-en-2023-06-26`, int8, ~28 MB) re-decodes the whole
utterance. This transcript is the artifact that gets kept (11.19% WER, RTF 0.092
— ~46× realtime on the phone). Being a transducer, it takes an utterance of any
length, so the old fixed-window splitting (and its boundary-clipping bug) is
gone. It uses **Silero VAD v5** (`silero_vad_v5.onnx`, MIT) to feed the
recogniser padded speech segments rather than whole windows — near-silent audio
never reaches the model, which attacks hallucination at the source.

**3. Punctuation & casing — `punctuator.dart`.** Zipformer emits bare lowercase
tokens; a sherpa punctuation model restores punctuation and capitalization.

**4. Text tidy — `polish.dart` / `gemma_transcriber.dart` / `gemma_engine.dart`.**
Gemma 4 E2B (`litert-community/gemma-4-E2B-it-litert-lm`, ~2.6 GB, via
`flutter_gemma`) repairs the transcript **as text only**. The tidy pass is
*agreement-gated* (`tidy_gate.dart`, `tidy_runner.dart`): when the streaming and
offline transcripts agree closely the audio was easy, so only the cheap
punctuation/casing path runs; Gemma is spent only where the two decoders
disagree. The prompt is constrained (cap expansion, never invent openings /
closings) because an autoregressive text model can hallucinate polite
boilerplate — a failure mode documented at length in `research/ASR_CANDIDATES.md`.

Model download / sideload / removal is handled by the `*_provisioner.dart`
files (Gemma, zipformer, streaming, punctuation, diarization), each pinning
exact release URLs and SHA-256 hashes. Models are fetched from
**Settings → On-device model**.

---

## Speaker identity

Design and rationale: [`research/SPEAKER_IDENTITY.md`](research/SPEAKER_IDENTITY.md).
It runs **entirely on the phone** — Omi does this in the cloud, per-conversation;
this does it on-device, across your whole history.

| Piece | Model / code | Size / licence |
|---|---|---|
| Segmentation | `sherpa-onnx-pyannote-segmentation-3-0` | ~6.6 MB, MIT |
| Embedding | `wespeaker_en_voxceleb_resnet34_LM.onnx` (dim 256) | ~25 MB, WeSpeaker Apache-2.0 / weights CC-BY-4.0 |
| Registry + matcher | `speaker_registry.dart` (Dart) | 0 MB — reuses embeddings already computed |

- **`diarization_engine.dart`** wraps sherpa `OfflineSpeakerDiarization`
  (segmentation + embedding) to split a clip into speakers.
- **`owner_voice.dart`** turns audio into WeSpeaker embeddings and handles owner
  enrolment; the owner is simply the registry profile with `isOwner: true`, so
  "You" and "Sarah" are decided by identical rules.
- **`speaker_registry.dart`** keeps named voiceprints on disk under app-private
  storage (never leaves the device). It scores a profile by the **max** over its
  stored vectors (not a single centroid), searches **only named profiles**, and
  applies **three refusals** before assigning a name: a similarity floor, a
  runner-up margin, and an evidence gate on pooled speech duration. *Unknown* is
  a correct answer. Enrolled vectors are immutable; observed vectors are
  FIFO-capped; every vector is stamped with its model id + dimension so swapping
  the embedding model becomes "please re-enrol", not a silent break.
- **Worker isolate** (`speaker_worker*.dart`, `sherpa_speaker_backend.dart`):
  embedding extraction is synchronous native FFI (the multi-scale path is up to
  7 passes per call). It runs in a long-lived **background isolate** so it can
  never block the UI isolate into an ANR.
- **Tap-to-name** (`widgets/name_speaker_sheet.dart`): name an unknown speaker
  from a captured segment; the vector is enrolled into the registry.

---

## Capture modes

Settings live in `local_llm/transcription_mode.dart`.

- **`TranscriptionMode { cloud, onDevice }`** — where transcription happens.
  The **default is `cloud`** (the server does it); on-device is an explicit
  opt-in. In on-device mode the audio never leaves the phone.
- **`OnDeviceSegmentation { button, continuous }`** — how utterances are cut
  when on-device is active:
  - **`button`** — push-to-talk: capture between a button press and its
    release/timeout.
  - **`continuous`** — always listening; split on silence (VAD) or the hard
    cap. This is surfaced to the wearer as **"Privacy Mode"** and is the
    **default segmentation** (`defaultSegmentation = continuous`).

`capture_state.dart` tracks `CaptureStatus { idle, recording, transcribing,
nothingHeard }`; `audio_buffer.dart` holds the pre-roll ring and RMS/VAD gating.
The button grammar that toggles capture is owned by the firmware + the app's
three-state resolver — see
[`product/BUTTON_FEEDBACK_SPEC.md`](product/BUTTON_FEEDBACK_SPEC.md).

---

## BLE bridge and server transport

- **`WearableDeviceBridge` (`device_bridge.dart`)** subscribes to the firmware's
  GATT streams and forwards them to the server device channel: audio
  (`19B10001`) → WS `/api/device/ws/audio`; button events (`23BA7925`) → HTTP
  `/api/device/event`; and the reverse path drains the server's command queue
  (`GET /api/device/command/poll`) into GATT writes on `0xCAB1AB97`.
- **`WearableClient` (`wearable_client.dart`)** is the transport: mDNS discovery
  of `_wearable._tcp.local` on the LAN, one-time pairing (paste the dashboard
  bearer + the pairing token from `/api/device/register`), credentials in
  `flutter_secure_storage`, and an audio-WebSocket factory. The WS URL is
  derived from the paired `baseUrl` (`https` → `wss`), so pairing to a remote
  HTTPS host works with no code change.
- **`phone_mic.dart`** is a 16 kHz PCM secondary capture path (dictate from the
  phone with no wearable attached).

The bridge is only relevant when a server is configured. In on-device mode the
`local_llm/` pipeline handles transcription and nothing is sent. See
[`SERVER.md`](SERVER.md).

---

## Android foreground service

`capture_service.dart` starts/stops an Android **foreground service** so the BLE
link and capture survive the screen going off. `AndroidManifest.xml` declares
`FOREGROUND_SERVICE` with the `connectedDevice` type (plus `DATA_SYNC`,
`MICROPHONE`, `LOCATION`) and `WAKE_LOCK`. The `WearableDeviceBridge` rides this
existing service rather than escalating its own.

---

## Build & install

Flutter is pinned to **3.44.1 / Dart 3.10.7** via `.fvmrc` — required by
`flutter_gemma`. Key packages: `sherpa_onnx` (ASR + diarization),
`flutter_gemma` (text tidy), `flutter_blue_plus` (BLE), `opus_dart` /
`opus_flutter` (decode), `flutter_secure_storage`, `multicast_dns`,
`web_socket_channel`.

```bash
cd app
fvm flutter pub get
fvm flutter analyze          # expect 0 errors
fvm flutter test test/wearable/
fvm flutter build apk --debug
```

Flavors are `dev` and `prod` (`fvm flutter run --flavor dev`); application ids
`com.kelvinlee.wearable` and `com.kelvinlee.wearable.dev`. `app/release.sh`
drives release builds. On-device STT needs a real arm64 Android or iOS 16+
device (not a simulator), ~8 GB RAM, and the models installed from
**Settings → On-device model** — the ~2.6 GB Gemma model plus the sherpa
zipformer / VAD / punctuation / diarization assets.

---

## Privacy model

The phone is the filtering boundary.

- **On-device transcription mode:** audio is decoded, transcribed, punctuated,
  tidied, and diarized on the phone. Voiceprints live in app-private storage.
  Nothing — no audio, no transcript, no embedding — is sent anywhere.
- **Cloud transcription mode (default):** decoded audio is streamed to the
  server you configured, over your LAN or your own tunnel; see
  [`SERVER.md`](SERVER.md). There is no third-party account, no sign-in, and no
  crash reporter — the app talks only to the server you point it at.
