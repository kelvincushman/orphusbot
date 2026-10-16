<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# On-device STT: Gemma 4 E4B is the wrong tool

Field research across GitHub issues, Hugging Face discussions, arXiv and
vendor benchmarks, plus what we measured on our own hardware. The conclusion
is a change of direction, so the evidence is recorded in full.

## What we measured here

- **The model does not survive an app restart.** Install reports success and
  the page shows "Installed ✓", but on relaunch flutter_gemma logs
  `active model restore: file .../app_flutter/gemma-4-E4B-it.litertlm missing`.
  Reproduced twice, on a fresh install each time. Every "Installed ✓" we have
  seen was true only for the life of that process.
- **The in-app download hangs at 0% forever** — no progress, no throw, no
  return — on a phone that pings huggingface.co in 31 ms, while the same
  pinned URL downloads at 27 MB/s on the desktop.
- We are on **flutter_gemma 0.16.4**. Latest is **1.7.4**.

## Why both of those are known, fixed bugs

Our download hang matches three separate root causes in flutter_gemma's
`SmartDownloader`, all fixed upstream:

| Issue | Cause | Fixed in |
|---|---|---|
| #355 | `_handleFailedDownload` re-issues `resume()` with no attempt counter and no watchdog; a task that dies quietly emits no terminal event, so the stream is orphaned — "indistinguishable from a live download to the app layer" | 1.2.1 |
| #356 | `foreground: true` set the flag but never registered a running notification, so `WorkManager.setForeground()` was never called and the **9-minute timeout still applied** | 1.2.1 |
| #445/#450 | The package claimed the **global** `FileDownloader().updates` stream — "a fan-out that looked healthy and delivered nothing, for the rest of the process, with no error anywhere" | 1.6.3 |

And the reason it works on desktop but not the phone, from the maintainer:
HuggingFace's CDN serves model files through redirects **without
`Content-Length`**, so the downloader cannot tell the file is large, never
enables the foreground service, and WorkManager kills the task.

## Why Gemma 4 E4B is the wrong tool for continuous STT

**Latency.** LiteRT-LM #1575 (open): Gemma 3n E4B on a Snapdragon 8 Elite —
faster silicon than our Exynos 2400 — takes **1.15 s to prefill 2 seconds of
audio**. That is 0.57x realtime before any decode. Moonshine v2 does
50–258 ms. Not the same category of tool.

**The audio encoder is CPU-only.** `--audio_backend=gpu` returns "Model
requires one of [cpu]". Our `PreferredBackend.gpu` applies to the text decoder
only; the 1.15 s is unavoidable.

**Quality.** Two independent hands-on comparisons put Gemma audio well behind
dedicated ASR: looping output, dropped words and outright non-response on
sub-47-second clips; 83.4% WER on German out of the box, 35.3% after
fine-tuning on 11,500 samples. Whisper large-v3 is ~2.7% on LibriSpeech
test-clean. Google's own docs concede weak multilingual transcription.

**The 30-second cap is real and unfixed.** Maintainer-confirmed on the AI Edge
Gallery; the long-form request has been open since August 2025.

**GPU numeric corruption on Mali/Xclipse.** LiteRT-LM #2202 plus four
independent reporters: `1029.3` → `1.0,293`, `2026` → `202026`, `Elara` →
`Elaraaraara`, words silently dropped. One reporter's 13-document corpus
scored **CPU 13/13 clean, GPU 2/13**. Byte-identical across runs, so
deterministic rather than sampling noise. Exactly the failure mode that
destroys a transcript.

**E4B on an 8 GB Samsung is a documented OOM.** flutter_gemma #351, the
maintainer, on a Galaxy S24: lmkd reaping processes and finally taking the
foreground app. "Recommendation: switch to Gemma 4 E2B."

**The closest field report to our exact plan is a failure.** LiteRT-LM #1860:
E4B, audio mode, inside a Hilt-injected foreground service — app killed ~60 s
after recording starts, because the multi-GB engine load blocks on the
`startForeground()` path and AOSP's watchdog wins.

## What the ecosystem did instead

flutter_gemma shipped **`flutter_gemma_speech`** (1.4.0+, now 0.4.3 as its own
package) running **Moonshine-tiny, Whisper-tiny/base and Parakeet-CTC-0.6b** on
the **raw LiteRT interpreter**, bypassing LiteRT-LM entirely. The maintainer's
reason: the ASR models "use a different runtime than what flutter_gemma
currently supports ... **not LiteRT-LM Engine API**".

Moonshine takes **raw 16 kHz mono PCM** — exactly what our Opus decoder already
produces — and has no 30-second cap.

Google is doing the same upstream: LiteRT-LM `main` has an `omni/asr` pipeline
(#2952, #3504, #3517, #3131) building a dedicated streaming ASR path with a
dedicated small model. They are not blessing Gemma-4-as-transcriber.

## Sustained load, which nobody has published

Searched `thermal`, `throttling`, `overheat`, `battery`, `all day`, `24/7`
across the whole google-ai-edge org: `throttling` returns **zero**. No hour-scale
run by anyone, on any runtime, is public. We would be the first data point.

What measurement does exist:
- arXiv 2603.23640: Galaxy S24 Ultra, sustained load — the Android thermal
  governor floored the GPU to 231 MHz from iteration 6; the run had to be
  redone with the **display off** and a reduced prefill chunk to complete 20
  iterations. "Always-on agents querying more frequently than several minutes
  apart would face the plateau."
- TecAce, Galaxy S25 Ultra: a **single 24–38 s generation raises device
  temperature 6–15 °C**.
- Android 15+ caps `dataSync` and `mediaProcessing` foreground services at
  **6 hours per 24**, then calls `onTimeout()`.
- Android 17 will enforce per-app memory limits and kill the process with no
  stack trace.

## Recommendation

1. **Move STT to `flutter_gemma_speech` + Moonshine-tiny.** Raw 16 kHz PCM in,
   no 30-second cap, orders of magnitude smaller, and it removes our exposure
   to the GPU corruption, the audio-prefill latency and most of the memory
   pressure at once.
2. **Upgrade flutter_gemma 0.16.4 → 1.7.x** regardless. It fixes the download
   hang and the model-persistence path we are currently fighting.
3. **Keep Gemma only if we want reasoning over the transcript**, loaded on
   demand rather than held resident — and then prefer E2B on an 8 GB device.
4. Before committing to continuous capture, **run a soak on the real S24 FE**:
   log `VmRSS` from `/proc/<pid>/status` (not dumpsys PSS, which reports 0 on
   Android 14+), and grep logcat for `GPU sampler unavailable`, `LITERT_WEBGPU`
   and `CL_INVALID_COMMAND_QUEUE`.

## What is NOT known

No public WER benchmark of Gemma audio on Android. No report of Exynos 2400 /
Xclipse 940 under LiteRT-LM either succeeding or failing — our device is
untested territory in the public record. No sustained multi-hour run anywhere.

---

# Addendum: what Google AI Edge Eloquent actually uses

Researched because the app's design was copied from Eloquent and the owner
asked whether we could use the same fine-tuned model. Three corrections.

**Eloquent is not a developer artifact.** It is a closed-source consumer
dictation app on **iOS and macOS only** — no Android build, no SDK, no sample,
no repo (`eloquent org:google-ai-edge` returns 0). The developers.google.com
page is marketing: its body is an iframe naming zero models, runtimes or sample
rates, and every docs subpath 404s. Product shape is push-to-talk dictation —
speak, stop, polished text on the clipboard — plus batch file transcription on
macOS. **No always-on capture, no wake word, no VAD, no diarization.**

**Google never names its ASR model, and "Gemma ASR" does not exist.** The App
Store copy says only "Gemma architecture ... open-weight, on-device models"
(plural, unnamed). A Hugging Face query for Google's ASR models returns exactly
one — `google/medasr`, medical and gated. The "Gemma ASR runs on the NPU"
claim comes from AI-generated review sites, and the NPU part is contradicted by
a user crash log showing `llm_metal_runner.mm` — a Metal runner, not the Neural
Engine. The only model Google names for Eloquent is **Gemma 4 12B, on macOS,
for the text-rewrite feature** — explicitly not for transcription.

**`litert-community/TinyGemma-ASR` is gated (HTTP 401).** A small multilingual
Gemma-architecture ASR in `.litertlm`, actively worked on as of 2026-09-08. It
is the natural multilingual upgrade path if it opens. `moonshine-tiny` and
`Speaker-Diarization-LiteRT` are both public (HTTP 200) — the latter being the
same pyannote-segmentation + WeSpeaker-embedding pair we already run through
sherpa-onnx.

## What we take from Eloquent

Not a model — a **shape**. Eloquent runs raw ASR, then a *separate* LLM pass
over the **text**. Our `gemma_transcriber.dart` fuses both into one prompt to
one audio-capable model. Splitting them removes the audio-encoder prefill, the
30-second cap and the 1.15 s-per-2 s cost in one move, and leaves Gemma doing
what Google actually uses it for.

## Qualifications carried into the build

1. **Moonshine-tiny is English-only.** The real cost of this decision, and
   precisely why Google reached for a Gemma-family model. TinyGemma-ASR is the
   watch item.
2. **No Exynos NPU artifact exists.** AOT builds target MediaTek, Qualcomm,
   Google Tensor and Intel — never Samsung. On the S24 FE that leaves CPU or
   GPU-FP32, and GPU-FP32 is the same numeric territory as the documented
   Mali/Xclipse corruption. **Ship CPU-first; GPU only behind a measurement.**
3. **Moonshine-tiny has no KV cache** — the decoder re-scores the full buffer
   each step, so decode cost grows with tokens emitted per window. Dense
   continuous speech is the latency risk, not the encoder.
4. **Use E2B, not E4B, for the polish pass.** E4B is the 3.66 GB file that
   OOMs on 8 GB Samsung devices. E2B is 2.59 GB — and now only ever sees text.

## Measured on this repo

`flutter_gemma` **0.16.4 → 1.7.4** plus `flutter_gemma_speech` 0.4.3:
19 dependencies changed, **zero analyzer errors, 251 tests passing**. Six major
versions with no source changes, because every call was confined to
`gemma_engine.dart`, `model_provisioner.dart` and `gemma_transcriber.dart`.

**Still unmeasured, and the one that matters:** Moonshine-tiny latency and WER
on Exynos 2400. Nobody has published it. It closes only by measuring, and it
should be step one of the build rather than step ten.
