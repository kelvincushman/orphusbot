<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Capture pipeline — architecture, measurements, privacy boundary

State of the tree at `c4ee225` (the commit that added
`docs/PLAN_CAPTURE_DEVICE.md`). This document describes what is built and
what has been measured; it does not describe what the plan intends to add.
Where a number appears, the source is named next to it — a research doc under
`docs/research/` or a commit hash — so it can be re-checked rather than
trusted. The research docs are linked, not restated.

Owner's framing, verbatim: *"we are building a capture device here."*

---

## 1. The pipeline

```
wearable  (nRF52840 Sense, Zephyr)
   │  PDM mic → Opus 16 kHz mono, 32 kbps VBR, complexity 3,
   │  RESTRICTED_LOWDELAY            (firmware/devkit/src/config.h)
   │  BLE GATT notifications ~100/s; button gestures; LED/haptic cues back
   ▼
phone app  (Flutter, lib/wearable/)          ── everything below is on-device
   │  1. reassemble frames, decode Opus → PCM16       (wearable_audio_session, opus_pcm_decoder)
   │  2. capture window / segmentation                 (UtteranceBuffer)
   │  3. energy gate, then Silero VAD as a yes/no gate (device_bridge, zipformer_transcriber)
   │  4. live preview — streaming zipformer            (streaming_transcriber, optional)
   │  5. diarise → clusters; embed once per cluster;
   │     match against the named registry             (diarization_engine, owner_voice, speaker_registry)
   │  6. offline pass — zipformer-small-en             (zipformer_transcriber)  ← the saved transcript
   │  7. log to the Transcripts feed                    (transcript_log)
   │  8. Gemma 4 E2B tone rewrite, on request only     (polish.dart — dictation page chips)
   ▼
server  (optional; paired in Settings)
   │  POST /api/device/text  — text only, on this path
   ▼
Obsidian — memories  (server side; out of scope here)
```

Two things the diagram hides, both important:

- **The default transcription mode is `cloud`, not `onDevice`**
  (`local_llm/transcription_mode.dart`, `defaultMode = TranscriptionMode.cloud`).
  In cloud mode the bridge opens `/api/device/ws/audio` and streams raw
  wearable audio to the paired server for server-side STT. The on-device path
  above is opt-in under *Settings → Voice & Hands-Free → On-device
  transcription*. See §5 and §7.
- **Gemma does not run on wearable transcripts.** `polish.dart` is reached only
  from the dictation page's tone chips. Saved transcripts are the recogniser's
  native output — upper-case, unpunctuated.

---

## 2. Stage by stage — what is built, what was measured

### 2.1 Wearable → phone

Opus settings are read from the firmware, not assumed:
`firmware/devkit/src/config.h` — 16 kHz mono, `OPUS_SET_BITRATE(32000)`, VBR,
complexity 3, `OPUS_APPLICATION_RESTRICTED_LOWDELAY`. The ASR benchmark's
channel simulation was built from these exact settings (`ced69e5`), and Opus
itself is not the problem: the codec round-trip moved clean WER only
2.90% → 2.94% — "the room is the entire problem" (`ced69e5`).

The button grammar (single/double/triple tap, hold-to-power-off) is decoded in
`device_bridge.dart` and documented under `firmware/`. Habitat LED/haptic cues
go back over `0xCAB1AB97` via `command_codec.dart`.

### 2.2 Keeping the process alive — foreground service

Android was killing the backgrounded app, with the system's own reason:
`Killing 3713:... (adj 850): excessive binder traffic during cached`
(`2cb1589`). The BLE notification stream is itself binder traffic, so a cached
process dies faster the harder the wearable works.

`CaptureService` + `WearableCaptureService.kt` start an Android foreground
service while the bridge is attached. Measured on an S24 with Twitter in front
(`2cb1589`):

| | before | after |
|---|---|---|
| `oom_score_adj` | 850 | **200** |
| cpuset | `/background` | `/moderate` |
| frames over 2 min | process died | #7250 → #17600, 103 fps, no gaps |

What it is *not*: the Dart isolate already survived backgrounding — 11 minutes
backgrounded and 8 minutes in Doze with frames unbroken (`2cb1589`). The
service changes process importance only; nothing runs in a background isolate.
`POST_NOTIFICATIONS` is requested at first capture so the recording indicator
is visible.

### 2.3 Capture window and segmentation

- A single tap opens a voice-note window; a second tap (or the cap) closes it.
  Cap: `_voiceNoteMaxWindow = 120 s`, amber budget warning at 90 s
  (`device_bridge.dart`). Inside the window `UtteranceBuffer` emits ≤ 30 s
  slices (`maxSeconds = 30`, `audio_buffer.dart`), each transcribed separately.
- Pre-roll of 1.5 s is kept from before the tap, because the firmware waits out
  a 750 ms multi-tap window before reporting a tap (`audio_buffer.dart`).
- Continuous mode (`OnDeviceSegmentation.continuous`) splits on RMS silence;
  it is available but the default segmentation is `button`.

### 2.4 Don't transcribe silence — the VAD gate

A silent button press produced a person's name from audio whose decoded level
was 56 (`20aeab5`). A blocklist cannot enumerate the names a model might
invent, so the fix is not calling the model: **Silero VAD v5** gates every
capture.

Two follow-up corrections matter for anyone touching this:

- **Normalise first, then gate.** The chest mic delivers speech around
  −50 dBFS, below what Silero was trained on; gating raw audio returned a
  constant 322 ms of "speech" from 17 s and 30 s captures alike (`7b5185b`,
  `5d0c653`). Threshold is back at the 0.5 default; `minSpeechDuration 0.25 s`
  keeps the ~30 ms button click out (`zipformer_transcriber.dart`).
- **Gate, not segmenter.** The VAD is driven window by window as the streaming
  component it is, and its answer is yes/no: no speech anywhere → skip the
  capture and show *"No speech found"*; any speech → decode the whole clip
  untouched. Trimming was abandoned because a mis-trim is unrecoverable and
  the transducer can already emit blank over silence (`5d0c653`).

The energy gate in `_transcribeSamples` (RMS 800/250, peak 1600/650, 0.8 s)
still runs first. ASR_CANDIDATES.md §6 is explicit that there is no
published number to calibrate those thresholds against.

### 2.5 Offline ASR — zipformer-small-en on sherpa-onnx

The recogniser is a **transducer**, not an autoregressive decoder. That is the
architectural reason it can say "nothing here" over low-information audio
where every generative model surveyed invents something plausible
(ASR_CANDIDATES.md, LatentASR review; SPEAKER_IDENTITY.md §7).

Chosen on a channel simulation built from this firmware's Opus settings plus
reverb and 10 dB babble, 12 models, 120 LibriSpeech utterances, Apple M2
(`ced69e5`):

| model (sub-9 s clips, wearable channel) | WER | peak RSS | RTF | disk |
|---|---|---|---|---|
| **zipformer-small-en int8** | **12.1%** | 358 MB | 0.019 | 28 MB |
| parakeet-tdt-ctc-110m int8 | 14.3% | 587 MB | 0.023 | 132 MB |
| moonshine-tiny-en int8 (previous incumbent) | 29.5% | 478 MB | 0.025 | 52 MB |

Full-set figures from the 2026-09-10 sweep (ASR_CANDIDATES.md, "Streaming
models — measured"): clean 2.42%, **wearable channel 11.19%**, test-other on
the wearable channel 24.15%, RTF 0.092.

On the phone (Exynos 2400, S24 FE): the offline pass decodes at **46.73×
realtime** (`e3f29b4`; ASR_CANDIDATES.md). An earlier, shorter clip measured
21.47× (322 ms of audio in 15 ms, `7b5185b`); the transcriber logs RTF on
every utterance, so the number keeps updating from real captures.

The lesson recorded with the choice: clean-speech WER and parameter count do
not predict far-field robustness. Moonshine is excellent clean (5.15%) and
collapses with reverb; a 670 MB Parakeet scored worse than this 28 MB model
(`ced69e5`).

### 2.6 Live preview — streaming zipformer

Text appears while the wearer is still speaking. Same sweep, same channel
(ASR_CANDIDATES.md; `e3f29b4`):

| model | clean | wearable | test-other (wearable) | RTF | int8 size |
|---|---|---|---|---|---|
| zipformer-small-en (offline) | 2.42% | **11.19%** | 24.15% | 0.092 | 28 MB |
| zipformer-en-2023-06-26 streaming | 3.62% | **16.26%** | 35.01% | 0.094 | 73 MB |
| kroko-en-2025-08-06 streaming | 8.53% | 15.90% | 32.91% | 0.310 | — |
| zipformer-en-20M streaming | 22.46% | 40.18% | 63.25% | 0.276 | 44 MB |

Streaming costs about five points of WER — roughly 45% more errors — so it is
**preview only**; the offline pass re-decodes the finished utterance and that
is what is saved. Kroko's 0.36 pp edge is inside the noise of a 120-utterance
run and costs 3.3× the compute. The 20M model was nearly adopted on size and
measured at 40% (`e3f29b4`). The preview runs only inside button-capture
windows; continuous preview waits on the battery measurement (§7).

### 2.7 Speaker identity — diarisation, embeddings, registry

Models: pyannote segmentation 3.0 + WeSpeaker ResNet34-LM (dim 256), both
through `sherpa_onnx`. Diarisation runs per clip and labels `Talker N`;
`numClusters: -1` (auto), clustering threshold 0.5, `minDurationOn 0.2 s`,
`minDurationOff 0.5 s` (`diarization_engine.dart`).

Identity is decided **once per cluster** — the diariser already grouped
segments by speaker, so the bridge pools a cluster's speech, embeds once, and
the registry sees the real duration (`b0dcd20`). Embeddings are multi-scale:
whole-clip pass blended with 2.0 s and 1.0 s windows as a duration-weighted
mean of unit vectors, ≤ 7 passes, logged per call (`e79ff1e`; the idea is
from arXiv 2606.13095 §2.1, reviewed in SPEAKER_IDENTITY.md §7).

`SpeakerRegistry` (`b0dcd20`; design in SPEAKER_IDENTITY.md §2, §4):

| rule | value | why |
|---|---|---|
| score per profile | max over stored vectors | one centroid averages a tired voice and a phone voice into nobody |
| similarity floor | 0.65 | the value `owner_voice.dart` had already raised to after a TV was tagged as the owner |
| runner-up margin | 0.07 | two similar family voices otherwise give a confident wrong argmax |
| evidence gate | ≥ 3 s pooled | short clips are where every speaker model is least reliable |
| search set | named profiles only, ≤ 10 | open-set false alarms scale with gallery size (SPEAKER_IDENTITY.md §5) |
| enrolled vectors | immutable, never evicted | rollback from a bad automatic observation |
| observed vectors | FIFO ≤ 20 | bounded growth |
| model stamp | `wespeaker_resnet34_LM`, dim 256 | a model swap becomes "re-enrol", not a swallowed RangeError |

Confident matches are **not** written back into profiles — adaptive templates
are a documented poisoning target (SPEAKER_IDENTITY.md §5). Profiles grow only
when a person names a voice, via the tap-to-name sheet, which enrols the exact
vector just scored from wearable audio. Renaming relabels that clip and
cluster only; history is never rewritten without confirmation, and that
confirmation flow is not built.

Why three enrolment clips are the target (not yet built — the owner page still
records one 8 s phone-mic clip): VoxBlink2's open-set benchmark at a
60-speaker gallery moves DIR@FAR=0.001 from 88.10% → 96.32% going 1 → 3
enrolment utterances; 3 → 5 adds 0.65 (SPEAKER_IDENTITY.md §4 step 6).

### 2.8 Gemma 4 E2B — the text stage

Gemma **never sees audio**. `ON_DEVICE_STT.md` records why the previous
design (Gemma 4 E4B transcribing audio) was abandoned: 1.15 s to prefill 2 s
of audio on faster silicon than ours; CPU-only audio encoder; a 30 s cap; and
GPU numeric corruption on Mali/Xclipse (one 13-document corpus: **CPU 13/13
clean, GPU 2/13**, byte-identical across runs). E4B (3.66 GB) is a documented
OOM on 8 GB Samsung devices (flutter_gemma #351) and loading it inside a
foreground service got the app killed ~60 s in (LiteRT-LM #1860).

So: **E2B, CPU, text only** (`51fc7f3`; `gemma_engine.dart`:
`PreferredBackend.cpu`, `supportAudio: false`). The file is
`gemma-4-E2B-it.litertlm`, 2,588,147,712 bytes, pinned to an immutable HF
commit with SHA-256 (`model_provisioner.dart`). The download tile had been
tree-shaken out of the APK entirely for a period — restored in `01ec71c`.

`polish.dart` treats the model as untrusted: refusals, prompt echoes and
rewrites longer than 2× the input are rejected and the original text is
returned. It is reached only from the dictation page's tone chips.

Not yet verified on hardware: that an installed E2B survives an app restart
(`51fc7f3` says so explicitly; `PLAN_CAPTURE_DEVICE.md` §5 keeps it with the
orchestrator).

---

## 3. Privacy boundary — what never leaves the phone

On the **on-device path** (opt-in, §1):

| stays on the phone | leaves the phone | where it lives |
|---|---|---|
| raw audio (Opus frames, decoded PCM) | — | RAM only; ≤ 3 cancelled notes kept 10 min for recovery (`device_bridge.dart`) |
| speaker embeddings (biometric vectors) | — | Application Support `/speakers/` — JSON index + packed Float32 per profile |
| enrolment audio | — | **not retained** — vectors only (§7 Q1) |
| ASR / VAD / diarisation / Gemma models | — | Application Support; fetched at runtime, never vendored |
| transcript text | **text**, `POST /api/device/text` — only if a server is paired | in-memory feed (50 entries) on the phone; server stores its copy |

Today's wire format fuses the speaker label into the text
(`'$talker: $text'`, `device_bridge.dart`), so a rename on the phone cannot
propagate; the plan's P3/P6 change that to a separate field.

On the **cloud path** (the default): raw audio is streamed to the paired
server over `/api/device/ws/audio`. Nothing about the on-device components
above applies until the toggle is switched. SPEAKER_IDENTITY.md §6 Q1 flags
this as the first decision to make; it is restated in §7.

Deletion: the registry exposes `remove` / `clearAll`; a Settings page that
surfaces them, with copy stating these are biometric vectors, is P0 in the
plan and not in this tree.

---

## 4. Model inventory

Every model is downloaded at runtime from a pinned source and verified by byte
count (and SHA-256 where the host publishes one). None is vendored, so the MIT
repo redistributes no weights. Licences below were checked on 2026-09-11
against the HF model API (`cardData.license`) or the upstream LICENSE file.

| model | files / size | source, pin | licence | verified at |
|---|---|---|---|---|
| zipformer-small-en (offline ASR, int8) | encoder 26,015,366 + decoder 1,307,236 + joiner 259,335 + tokens 5,048 B | HF `csukuangfj/sherpa-onnx-zipformer-small-en-2023-06-26` @ `e8add537…` | Apache-2.0 | HF API `license: apache-2.0`; also `e79ff1e` |
| Silero VAD v5 | 2,313,101 B | k2-fsa `asr-models` release asset | MIT | `snakers4/silero-vad` LICENSE |
| streaming zipformer (live preview, int8) | 73,440,167 B total (UI: ~70 MB) | HF `csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26` @ `672fbf1b…` | Apache-2.0 | HF API `license: apache-2.0` |
| pyannote segmentation 3.0 | ~6.6 MB | k2-fsa `speaker-segmentation-models` release (`.tar.bz2`) — no digest pinned | MIT | HF API `pyannote/segmentation-3.0` `license: mit` (gated: auto; k2-fsa's redistribution is what we fetch) |
| WeSpeaker ResNet34-LM (embedding, dim 256) | ~25.3 MB | k2-fsa `speaker-recongition-models` release (sic) — no digest pinned | toolkit Apache-2.0; VoxCeleb-trained weights **CC-BY-4.0** | `wenet-e2e/wespeaker` LICENSE; `docs/pretrained.md` "Model License" |
| Gemma 4 E2B (`.litertlm`, text polish) | 2,588,147,712 B | HF `litert-community/gemma-4-E2B-it-litert-lm` @ `b3ca0d2f…` | Apache-2.0 | HF API and README front-matter `license: apache-2.0` |

Runtime packages (pub.dev, `pubspec.lock`): `sherpa_onnx` 1.13.2
(Apache-2.0), `flutter_gemma` 1.7.4 (MIT), `opus_dart` 3.0.1 (BSD-style),
`flutter_blue_plus` 1.33.6 (BSD-style) — licences read from `~/.pub-cache/.../LICENSE`.

Two gaps worth knowing: the diarisation provisioner checks "non-empty", not a
digest, and CC-BY-4.0 on the WeSpeaker weights wants a NOTICE entry
(SPEAKER_IDENTITY.md §2) that does not exist yet.

---

## 5. What is measured vs. what is assumed

| claim | status | evidence |
|---|---|---|
| Offline ASR WER on our channel | measured (simulation, M2) | 11.19% — ASR_CANDIDATES.md; `e3f29b4` |
| Offline ASR speed on the phone | measured | 46.73× realtime — `e3f29b4`; 21.47× on a short clip — `7b5185b` |
| Streaming WER on our channel | measured (simulation, M2) | 16.26% — ASR_CANDIDATES.md |
| Foreground service effect | measured | `oom_score_adj` 850 → 200, 103 fps over 2 min — `2cb1589` |
| VAD gate stops silent-press hallucination | code-verified, fixed twice | `20aeab5` → `7b5185b` → `5d0c653`; hardware confirmation still listed as needed in `20aeab5` |
| Diarisation labels `Talker N` on real captures | observed | `b0dcd20` ("came back labelled 'Talker 1' all day"); no per-clip diarisation latency figure is recorded in a research doc or commit |
| Speaker registry thresholds | **starting points**, not calibrated | `b0dcd20`; SPEAKER_IDENTITY.md §4 step 0 says to instrument first |
| Owner recognition end-to-end on the wearable | **not verified** | no enrolment existed on the test install (`b0dcd20`) |
| Gemma E2B installed state survives restart | **not verified** | `51fc7f3`, PLAN §5 |
| Gemma tidy quality on our transcripts | **not measured** | ASR_CANDIDATES.md §3 warns to test abstention rate before WER |
| Battery / thermal under continuous capture | **not measured, by anyone** | ON_DEVICE_STT.md "Sustained load"; ASR_CANDIDATES.md §6 |
| WER on real body-worn audio (not simulated) | **not measured** | ASR_CANDIDATES.md §6: no body-worn benchmark exists; +40–50% relative WER off close-talk is an estimate |
| Exynos 2400 figures for anything but the offline pass | **not measured** | ASR_CANDIDATES.md §6 |

---

## 6. Research docs — read these, do not restate them

- [`docs/research/ASR_CANDIDATES.md`](research/ASR_CANDIDATES.md) — the
  five-cluster candidate review; the channel-simulation sweep; the streaming
  table; why a transducer; the LatentASR review and its revisit (gating the
  Gemma tidy pass on streaming/offline disagreement).
- [`docs/research/ON_DEVICE_STT.md`](research/ON_DEVICE_STT.md) — why Gemma
  4 E4B was the wrong STT tool; flutter_gemma download/persistence bugs; the
  GPU corruption evidence; the Eloquent addendum ("raw ASR, then a separate
  LLM pass over the text").
- [`docs/research/SPEAKER_IDENTITY.md`](research/SPEAKER_IDENTITY.md) — what
  Omi actually does; the registry design and constants; the six-step build;
  the failure modes; the review of arXiv 2606.13095.
- [`docs/PLAN_CAPTURE_DEVICE.md`](PLAN_CAPTURE_DEVICE.md) — the work packages
  that change what this document describes.

---

## 7. Open questions

From `PLAN_CAPTURE_DEVICE.md` §6, for the owner:

1. **Retain enrolment audio, or vectors only?** The registry keeps vectors.
   Keeping clips would allow re-enrolment after an embedding-model swap
   without asking again; it is also raw voice recordings of third parties to
   protect. Without retained audio a model swap means everyone re-enrols
   (SPEAKER_IDENTITY.md §6 Q2).
2. **Consent for naming third parties.** The registry can name anyone the
   wearer chooses. Whether a person needs a "do not identify me" state, and
   whether that deletes vectors or only suppresses the label, is a product and
   legal position (SPEAKER_IDENTITY.md §6 Q5).
3. **Auto-tidy default.** The plan's P2 ships the Gemma tidy gate off. Whether
   it defaults on waits for the decision log to show how often the gate fires.
4. **Continuous live transcription** waits on the battery and thermal
   measurement nobody has published (§5).

And one this document surfaces because the code and the framing disagree:

5. **Cloud is still the default mode.** §0 of the plan says nothing phone-side
   sends audio anywhere; `transcription_mode.dart` defaults to streaming raw
   audio to the server. SPEAKER_IDENTITY.md §6 Q1 asked this first. If the
   privacy property is the product, that default is the line to change — and
   it also decides whether the registry is the only identity layer or has to
   reconcile with server-side labels.
