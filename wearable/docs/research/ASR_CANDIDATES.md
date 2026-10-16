<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# ASR candidate review — Jun–Sep 2026 literature vs. what we ship

Five clusters, ~25 candidates, each gated on deployability BEFORE accuracy:
released weights, a licence we can ship in an MIT project, an existing
ONNX/TFLite/LiteRT export or small enough to convert, and no server.

## 1. THE ANSWER IN THREE SENTENCES

Moonshine stays. Across five clusters and ~25 candidates, nothing that clears the deployability gate beats a 27M MIT English model at 52 MB — every model that does more (VibeVoice-ASR-Streaming, BitNet, Qwen3-ASR) costs 20–40x the parameters and 1.5–3.2 GB of peak RSS on an 8 GB phone that already holds Gemma 4 and sherpa, and the two that ship speaker attribution either fail at the shippable size (1.5B labels every turn "Speaker 0" in the only third-party test) or lose it in distillation. The real value in this literature is three techniques and one runtime swap, none of which is a model change.

## 2. ADOPT NOW

**(a) Swap the Moonshine runtime to sherpa-onnx with the KV-cached merged decoder.** Replaces: the `flutter_gemma_speech` LiteRT ASR path *and* the hand-rolled 5-second windowing in `app/lib/wearable/local_llm/moonshine_transcriber.dart`.
- Artifact: `sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2` — encoder_model.ort 13.3 MB + decoder_model_merged.ort 30.4 MB = **43.7 MB, smaller than the 52 MB incumbent**, MIT.
- `sherpa_onnx ^1.13.2` is already pinned at `app/pubspec.yaml:50` with the arm64 native lib linked for diarization; `OfflineMoonshineModelConfig` exposes `mergedDecoder` as a first-class field. No new dependency, no new native work.
- What it buys: priority (d). Current LiteRT decode signature is a fixed `[1,64] → [1,64,32768]` — every step pays full 64-token cost and discards 63 of 64 logit rows. Not quadratic; **flat at maximum**, which is worse than the O(n²) framing suggests. Also deletes the boundary-clipping bug that file documents against itself (sherpa's OfflineRecognizer has no 5 s cap).
- What it costs, honestly: **WER must be re-benchmarked.** This changes the quantizer (LiteRT int8 → ONNX int8, different calibration) and the checkpoint (v2 tiny-en ≠ v1). "Algebraically identical caching, no accuracy risk" is false for the swap as specified. Second cost: it removes the one place we could implement the abstain margin — see §3.
- Do NOT use the v1 four-file bundle (preprocess + encode + uncached_decode + cached_decode = 123 MB, both decoder graphs with duplicated weights).

**(b) Adopt HALAS as a hallucination regression fixture.** CC BY 4.0, `github.com/DSP-AGH/HALAS`. Costs nothing, ships nothing to the device. It independently vindicates our ghost-token list — across 7 unrelated models the top hallucinated phrases are "you, thank you, okay, good, and, thank, thanks, yeah, yes", top 10 = 55% of all marked hallucinations. That list is a cross-model attractor, not a Gemma artifact. Keep it. Also kills WER-as-proxy: hallucination occurs at WER as low as 6.25%, so any Moonshine successor benchmarked on WER alone will not surface this failure mode.

## 3. TECHNIQUES WORTH STEALING

**Windowing/commit — steal LocalAgreement-n (arXiv 2307.14743), but know what you're buying.**
The honest version: this is a *port* of a published policy, ~1 day, not a wrap of the MIT reference. Timestamps are load-bearing inside `HypothesisBuffer.insert()` and `flush()`, not just in buffer trimming, and `flutter_gemma_speech`/sherpa hand us bare text. Only the longest-common-prefix core is timestamp-free.
- **Do the VAD half unconditionally.** Anchor window boundaries on Silero VAD silence instead of `offset += 80000`. Silero is inside `sherpa_onnx 1.13.4` (`lib/src/vad.dart`, `VoiceActivityDetector`, `CircularBuffer`) — but note it needs a **new ~2 MB `silero_vad.onnx` asset** and a `DiarizationProvisioner` path for it; nothing in `app/lib` references it today. This is cheap, subtractive, testable, and attacks hallucination at the source: near-silent windows never reach the model at all.
- **Gate the overlap half on measurement.** LocalAgreement-2 at 2.5 s hop gets you 2x decode for 2.5 s commit granularity — no better than today. Real partials at ~0.5 s hop means each second decoded ~10x, at full-window encoder cost, because Moonshine pads short input to 5 s. Sequence this *after* the KV-cache swap and after actually measuring Moonshine latency on the Exynos 2400 — which `docs/research/ON_DEVICE_STT.md` says has never been done.

**Hallucination gate — the abstain margin is the right idea and we are about to lose access to it. Take VAD instead.**
"The Null Token Knows" (2608.15940) is real, verified, and its signal — `logit(EOS) − max logit(content)` at decode step 0 — is two reads off a tensor we already compute. Better than reported: `flutter_gemma_speech`'s `applySuppression` (`stt_core.dart:173-192`) already mutates that logit row every step *and already branches on step == 0*. Two lines.
But: (i) it lives in a pub.dev package, so it needs an upstream PR or a fork override, not an edit to our repo; (ii) **adopting sherpa-onnx removes the hook entirely** — sherpa's `OfflineRecognizer` returns a String and exposes no logits. These two moves are mutually exclusive in practice.
**Call: take the KV cache and VAD gating; drop the abstain margin; keep `sanitizeTranscript`.** The paper's own cost curve is why this is not a loss — at settings that meaningfully suppress fabrication it deletes more real words than fabricated ones (32.5→4.3 fabricated/min costs 1.6→33.0 deleted/min), with **42.7% false-silence at low SNR**, and a body-worn mic is a low-SNR device by definition. Its stated limitation — "avoid small-model use on degraded or spontaneous speech, long-form audio, or when false silence is costlier than fabrication" — describes our deployment exactly. Revisit only if we ever fork the decode loop for other reasons.
One free structural win regardless: `moonshine_transcriber.dart:115` applies `sanitizeTranscript` to the *joined* multi-window transcript, so a whole-transcript ghost token only fires if the entire clip reduces to one. Move sanitization per-window.

**Hotword biasing — the personal dictionary is not recoverable on Moonshine. Restore it in the text stage.**
TurboBias 2.0 is CUDA server infrastructure — FAILS GATE. sherpa-onnx's Aho-Corasick hotwords are real and exposed in Dart (`hotwordsFile`, `decodingMethod`, `maxActivePaths`) but are **transducer-only under `modified_beam_search`**. Moonshine is an AED with greedy decode: no beam, no biasing, on either runtime. So:
- Short term: steal Voice Memory's shape (2607.26410) into the Gemma polish stage — a per-wearer plain-text rules file (their deployed WSJ memory is 776 bytes) conditioning text-only n-best correction. This is the *only* adaptation channel Moonshine leaves open, since it takes no prompt. Two caveats: every number in that paper comes from a 30B–428B corrector, so **test abstention rate before WER** — a phone-sized Gemma that over-edits replaces an imperfect blocklist with a confident fabricator; and the memory *optimizer* is score-gated against held-out labels we don't have, so you can hand-author the file but you cannot learn it until a transcript-correction capture loop exists (a product feature, not a model integration). Hard ceiling: text-only correction never recovers a word the acoustic model never emitted.
- Long term: decode-time biasing arrives only if we move to a transducer — which is the same move as §4. That is the real argument for Canary/Parakeet beyond multilingual.

## 4. THE MULTILINGUAL ANSWER

**If it's Spanish, German or French: `sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8`. Ship that.**
- 182M params, **CC-BY-4.0, ungated, commercial use fine**. encoder.int8 127 MB + decoder.int8 71 MB ≈ **198 MB** (the docs page's ~428 MB archive figure contradicts its own component sizes — verify on download).
- Loads through the `sherpa_onnx` Dart API already in the APK. Same integration as §2(a) — if we do the KV-cache swap, this is a config object and a model download, not a second architecture.
- Accuracy: MLS de 4.81 / es 3.17 / fr 4.75 WER; LibriSpeech-clean 1.87 vs Moonshine Tiny's 4.52. **We probably gain on English too.** Bonus: punctuation, capitalisation, and X→en translation for free; real decoder KV cache; Granary training pipeline includes explicit hallucination filtering (plausible, unmeasured for us).
- Cost: **~4x disk (52 MB → 198 MB)**. Speed unmeasured for canary-180m on ARM — the S10/Exynos-9820 sherpa run has Moonshine Tiny at RTF 0.05, SenseVoice 0.06, Whisper Tiny 0.07, Parakeet-TDT-v3 0.09, so expect roughly 2x RTF loss and still far inside realtime. **That RTF is the one number we must measure ourselves.**

Wider European (25 languages, auto language ID): `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`, ~640 MB, CC-BY-4.0, FLEURS avg 11.97% / MLS avg 7.83%, S10-measured RTF 0.09. CJK/Cantonese: SenseVoice Small, ~240 MB, RTF 0.06, non-autoregressive so zero decode growth — but weights are under the FunASR Model Open Source License, not OSI, so make that a deliberate call in an MIT repo.

**Do not reach for Moonshine v2's multilingual models. FAILS GATE:** the v2 LICENSE splits — English MIT, "Models for other languages are released under the Moonshine Community License, which is a non-commercial license." That blocks ar/es/ja/ko/uk/vi/zh redistribution in an MIT project. Community fine-tunes (`onnx-community/moonshine-tiny-fr-ONNX`) are the cheapest path and the worst transcript — ~21.8% WER French vs Canary's 4.75.

**Nothing here closes priority (c).** The sherpa `OfflineSpeakerDiarization` stage stays under every option. And streaming multilingual does not exist in shippable form — sherpa's `OnlineRecognizer` has English, zh-en, Chinese and Korean only.

## 5. WATCH LIST

1. **Moonshine v2 Tiny Streaming (26M, MIT, English).** Trigger: a sherpa-onnx `OnlineRecognizer` prebuilt for `moonshine-streaming` appears, **or** our LocalAgreement port measures a re-decode multiple above ~2x. This is priority (b) at incumbent size and incumbent licence — by far the cheapest route to streaming we have, and it makes the LocalAgreement port unnecessary.
2. **VibeVoice-ASR-Streaming-1.5B (2609.02812, MIT).** The only released model offering (a)+(b)+(c) at once. Trigger requires *three* things, not one: a validated ARM/Android edge export of the **streaming** checkpoint (VibeASR.cpp has zero streaming support; Microsoft said in issue #4 they'd train a streaming version — this is it, and no commit since supports it), a third-party demonstration that speaker attribution actually works at 1.5B (the ONNX exporter's own card: "on the test clip it labelled every turn Speaker 0"), and the 8-minute context cap lifted. Also note real size: **2.81B params / 5.65 GB**, not 1.5B — the tokenizers are 1.03B of it.
3. **`litert-community/TinyGemma-ASR`.** Trigger: it ungates under a permissive licence. Currently HTTP 401. Multilingual, Gemma-architecture, `.litertlm` — the one format our existing LiteRT path already loads. Re-check monthly; if it opens it jumps to the top.

## 6. WHAT THIS LITERATURE DOES NOT ANSWER

- **Our acoustic channel.** There is no body-worn/chest-mounted ASR benchmark anywhere in this corpus. The nearest thing, the SLT 2026 SmartGlasses set, is registration-gated, non-commercial, no-redistribution — we could not train on it. The only clean same-corpus, same-model close-talk-vs-distant comparison (AMI-IHM vs AMI-SDM inside 2609.02812) suggests **+40–50% relative WER and +10–12 absolute cpWER** moving off close-talk; body-worn sits between those conditions. That is an estimate, not a measurement.
- **Energy and sustained thermal cost.** Every RTF number in this corpus is a server GPU, a desktop CPU, or a single cold-start phone run. Nobody reports a continuous, battery-powered, thermally-throttled always-on figure — which is the actual budget for an ambient wearable.
- **Our own silicon.** Every Android number is a Galaxy S10 (Exynos 9820) or a Galaxy S26. **Exynos 2400 / Xclipse 940 is untested for every candidate including the incumbent**, and the LiteRT VibeVoice card already documents an Adreno fp16 delegate returning an empty transcript — GPU delegation is not portable.
- **A principled acoustic gate.** Neither HALAS nor "Anatomy of an ASR Hallucination" characterises onset in terms of SNR, energy, or duration. There is **no published number** to replace the 800/250 RMS and 0.8 s thresholds in `device_bridge.dart:1172-1176`. VAD is the substitute; it is not a calibration.
- **Persistent named speaker identity.** Every speaker-attributed system here labels within a clip. Nobody does enrollment or cross-session identity — the thing we designed and did not build. That remains our own problem to solve.
- **Multi-party ambient at wearable range, at any size.** The one data point is damning: off-the-shelf full-size VibeVoice-ASR scores 18.67% tcpCER dyadic and **57.81% multi-party** on egocentric capture, and the challenge winner needed Whisper-large-v3 + Qwen3-8B to reach 27.95%. Nothing at phone scale is within sight of that. If the product depends on transcribing a group conversation from a chest mic, no model in this literature delivers it.
---

## Paper review — "Listen, Think, Transcribe: Continuous Latent Test-Time Scaling for ASR" (arXiv 2607.05051)

Chung et al., NTU Taiwan / ASUS / NUS, 6 Jul 2026. Reviewed 2026-09-10.

**Verdict: architecturally inapplicable to us. Read it for the failure mode it
documents, and for one idea we can apply to our own compute budget.**

### What it is

Two small trainable modules bolted onto a **frozen** Qwen3-ASR-0.6B: a *Latent
Adapter* that inserts N=4 non-text latent positions into the decoder prefix and
refines them through bounded recurrent updates, and a *Value Head* that
predicts per utterance whether running that loop will help and skips it if not.
~4.0M trainable params, 0.67% overhead. Notably, under the same 500-utterance
budget full fine-tuning (+13.4%), LoRA (+32.0%) and prompt tuning (+79.3%) all
make WER *worse* — LatentASR is the only method that improves it.

Headline results: FLEURS en_us 4.900 → 4.776% WER (−2.54% rel), VoxPopuli
9.038 → 8.995% (−0.47% rel), ASCEND accented/code-switched CER 57.81 → 48.55%
(−16.02% rel), 30-language FLEURS 32.65 → 32.57%.

### Why it cannot be applied here

1. **It needs an autoregressive decoder with a text prefix.** The whole method
   is "insert latent positions into the decoder's input prefix and iterate on
   the decoder hidden state." Our zipformer is a **transducer**. There is no
   text prefix, no decoder hidden state of that kind, and nowhere to put a
   latent position. This is not a tuning gap — the method has no attachment
   point on our architecture.
2. **0.6B frozen backbone**, so ~600 MB+ before the adapter. We ship 28 MB.
3. **Nothing released** — no code, no weights, checked the paper body and the
   arXiv listing.
4. **The clean-English gain is 0.124 pp** (4.900 → 4.776). The relative
   framing (−2.54%) makes it sound larger than it is.
5. Training needs the backbone plus a GPU (RTX 5090, 10 epochs). Not reachable
   for us even in principle without the released model.

### The failure mode — second independent sighting

Table 13 is the part worth keeping. The frozen Qwen3-ASR baseline **prepends
discourse openings that were never spoken**: reference "Madame President, the
directive on services…", baseline "*Thank you, Madame* President, the directive
on services…". Another: baseline invents "*Thank you, Commissioner, Madame*
President". The authors are explicit that their fix is not acoustic — "LatentASR
is not re-decoding the audio, but correcting systematic opening-phrase
hallucinations and vocative conventions."

That is the same disease as arXiv:2606.13095 §2.3 (backchannel words generated
to fill overlapped regions) and the same disease as the silent capture on our
own hardware that produced a person's name at decoded level 56. Three
sightings, three different models, one mechanism: **an autoregressive decoder
asked to produce text over audio that does not determine it will emit whatever
is fluent and contextually expected.** Both papers work around it. Neither
removes it, because it is inherent to generating text token-by-token from a
language prior.

This is the clearest retrospective justification we have for the transducer.
A transducer emits per-frame with a blank symbol available; it has an
architectural way to say "nothing here" that a generative decoder does not.

### The one transferable idea: gate expensive compute on predicted benefit

The Value Head skips the refinement loop entirely on 60.2% of VoxPopuli and
47.0% of FLEURS utterances, while spending the full budget on 34.1% of ASCEND
— "input-dependent compute where it is most needed." Their Table 12 checks it
counterfactually: forcing the loop on the skipped utterances yields +0.01 pp,
i.e. the gate is discarding exactly the cases where compute would not have
helped.

We already do a crude version of this twice (RMS gate, then Silero VAD, before
the recogniser). The generalisation applies directly to a cost we just took on:

> **Multi-scale embeddings currently pay up to 7 forward passes on every
> segment.** But when a single whole-clip pass returns cosine similarity of
> 0.95 or 0.15 against the enrolled owner, six more passes cannot change the
> decision. Only similarities near the threshold are worth refining. Gating
> the extra windows on `(sim - threshold).abs() < margin` would keep the
> robustness exactly where it decides anything and skip it everywhere else.

That should wait until the per-call pass-count and timing logs added alongside
the multi-scale change give us a real distribution of similarities to pick the
margin from — choosing it now would be the guess this paper's Value Head
exists specifically to avoid.

---

## Streaming models — measured 2026-09-10, for live transcription

Run on the same channel as the original sweep (this firmware's Opus settings +
reverb + 10 dB babble), 120 utterances, `NT=3`.

| model | clean | **wear10** | test-other wear10 | RTF (wear10) | int8 size |
|---|---|---|---|---|---|
| `zipformer-small-en` (offline, incumbent) | 2.42% | **11.19%** | 24.15% | 0.092 | 28 MB |
| `zipformer-en-2023-06-26` streaming | 3.62% | **16.26%** | 35.01% | 0.094 | 73 MB |
| `kroko-en-2025-08-06` streaming | 8.53% | 15.90% | 32.91% | 0.310 | — |
| `zipformer-en-20M-2023-02-17` streaming | 22.46% | **40.18%** | 63.25% | 0.276 | 44 MB |

### What this decided

**Live transcription costs about five points of WER — roughly 45% more errors.**
11.19% to 16.26% on the channel that matters. That is the whole reason the
design is hybrid rather than a straight swap: streaming drives the preview, the
offline model re-decodes the finished utterance, and the offline transcript is
what gets saved.

**`zipformer-en-2023-06-26` over kroko.** Kroko is 0.36pp better, which is
inside the noise of a 120-utterance run. It is also 3.3x slower (RTF 0.310 vs
0.094). At 0.094 the streaming model costs the same as the offline one we
already run, so the hybrid is affordable — confirmed on-device at 46.73x
realtime for the offline pass.

**The 20M model is a trap.** At 44 MB it is the obvious choice on size, and it
was nearly adopted on that basis before being measured: 40.18% WER on our
channel, 63.25% on test-other. Same lesson as Moonshine — parameter count and
clean-speech scores do not predict far-field robustness, and the only way to
know is to run the channel.

### Still unmeasured

Battery and thermal cost of running the streaming model continuously. The
current build only runs it inside button-capture windows, so this does not
block anything yet; it must be measured before continuous live transcription.

---

## Revisit — LatentASR (arXiv 2607.05051), now that the pipeline has a second stage

Re-read 2026-09-11 at the owner's request. The first review (above) filed it
as "architecturally inapplicable". Half of that holds; the other half was a
mistake in framing, and the difference matters now.

### What still holds

The **Latent Adapter** — inserting refinable latent positions into the
decoder's text prefix — needs an autoregressive decoder with a prefix. A
transducer has neither. Nothing about that changed, and nothing should:
2606.13095 §2.3 and this paper's own Table 13 are the two best reasons on
record for keeping the recogniser a transducer.

### What was wrong

The review treated the paper as a proposal for a *recogniser* and rejected it
on those grounds. But it is also a paper about **when to spend expensive
compute** — the Value Head — and that question did not exist for us until
Gemma became a second stage. It exists now: a ~2.6 GB language model that
takes seconds per note, and the question of which notes deserve it.

The Value Head's contract is exactly ours. It predicts *latent-vs-baseline
accuracy gain* per utterance and skips the loop when the prediction is
negative; 60.2% of VoxPopuli and 47.0% of FLEURS are skipped at the entry gate
while 34.1% of ASCEND's hard accented speech gets the full budget. Table 12 is
the part to take seriously: forcing the full path on the utterances the gate
skipped yields **+0.01 pp** — i.e. the gate correctly identified the set where
extra compute would not have helped. That is a measured, not asserted,
property of a difficulty gate.

### The transfer — and it costs no training

We already compute a difficulty signal, for free, on every capture where the
live model is installed: **the disagreement between the streaming and offline
transcripts.** Two decoders of the same family disagree most where the audio
is hardest; where they agree closely, the audio was easy and any remaining
work is casing and punctuation. That is a direct analogue of the paper's
regression target, produced as a by-product of the hybrid we shipped for other
reasons.

So the tidy pass should be gated, not blanket:

- **Agreement high** (normalised edit distance below a floor): run the cheap
  path only — casing and punctuation, no LLM. This will be most notes.
- **Agreement low**: run Gemma. Its context-based repair is worth seconds
  here and not elsewhere.
- **No live model installed**: fall back to a cheaper proxy — VAD kept-ratio
  and words-per-second are both already logged and both correlate with
  trouble — and log the decision so the floor can be tuned from real wear.

This replaces "process every capture with Gemma" (tier 3 in the earlier
review, rejected on battery and silent-rewrite grounds) with "process the
captures a measurement says need it". The paper's Fig. 2 shows why the gate
is the right place to spend a tuning effort: the deployed θ=0 setting captures
66–90% of the available gain at 3–6× below full-budget cost, and a static
budget cannot reach that point on both datasets at once.

### The warning that transfers with it

Table 13 shows the paper's own AR baseline inventing polite openings —
"*Thank you, Madame* President" for "Madame President" — and the authors
state that the fix is discourse-level, not acoustic. A Gemma tidy pass is an
AR language model over text; this is precisely the failure it can produce.
polish.dart already caps expansion at 2× and rejects refusals; it should also
be instructed, explicitly, never to add openings, closings, or sentences that
are not in the input. The paper's finding is that this class of hallucination
is *systematic*, so a rule against it belongs in the prompt, not left to the
model's discretion.

### Not transferred

The multilingual results (30 FLEURS languages) and the accented/code-switched
gain (−16% CER on ASCEND) describe the frozen backbone, not the gate. Our
recogniser is English-only by a measured choice; nothing here changes that.

---

## Moonshine v2 measured on our channel (2026-09-11)

Prompted by arXiv:2602.12241 (Moonshine v2, ergodic streaming encoder). The
earlier wearable-channel Moonshine numbers were for **v1**; v2 had been
downloaded and wired into the harness but never run on the channel. Same
settings as every other row (LIMIT=120, NT=3). This measures the OFFLINE v2
models through sherpa — the paper's streaming-encoder variant is not what
sherpa ships, so streaming TTFT is not measured here. v2 English weights are MIT.

| model | clean | **wear10** | other-wear10 | RTF (wear10) |
|---|---|---|---|---|
| `zipformer-small-en` offline (incumbent) | 2.42% | **11.19%** | 24.15% | 0.092 |
| `zipformer-en` streaming (live preview) | 3.62% | **16.26%** | 35.01% | 0.094 |
| `moonshine-base-en` **v2** | 3.58% | **19.89%** | 41.68% | 0.043 |
| `moonshine-tiny-en` **v2** | 5.43% | **31.96%** | 56.17% | 0.026 |
| `moonshine-tiny-en` v1 | 5.15% | 28.14% | 57.01% | 0.277 |

**It changes neither choice.** The paper's clean-benchmark claim holds — base
v2 at 3.58% clean is within 1.2pp of our offline model — and the far-field
collapse is the same story as v1: base v2 is 8.7pp worse than the offline
incumbent and 3.6pp worse than the streaming model it would replace for the
preview; tiny v2 is worse than tiny v1. What v2 did fix is speed: RTF 0.026–0.043
against v1's 0.277, the KV-cached decoder doing what it was built for. That is
the one thing to remember if a future Moonshine closes the robustness gap —
the runtime cost objection is gone. The accuracy one is not.

## New server-class models measured on our channel (2026-09-11)

The open question left by the rows above: is 9.0% (SenseVoice-2024) the *model*
ceiling on the wear10 far-field channel, or just the ceiling of the small
on-device models we had tried? Three newer permissive models were measured on a
GPU server (NVIDIA Blackwell-class, driver 610.43.02). torch **2.11.0+cu128**
was the working wheel — the driver is new enough that cu128 was the right first
try; it passed the op test (`cuda.is_available()` True and a real `torch.ones(8,
device="cuda").sum()==8.0` plus a matmul), so cu126/nightly were never needed.
(Aside: `get_device_capability()` reports `(8,0)` with a generic device name, but
kernels execute correctly, so the numbers are valid.) Same subset and scoring as
every row above — the deterministic every-Nth LibriSpeech subset (n=200,
LIMIT=120), the identical `norm()`, corpus-level `jiwer.wer`. The `audio_s` came
back identical to the recorded baselines (908.915 / 699.900), which proves the
120-clip selection is byte-for-byte the same, so these numbers are directly
comparable. `whisper-large-v3-turbo` is included only as a calibration anchor.

| model | license | params | **wear10 WER** | test-other-wear10 | RTF (Blackwell GPU) | VRAM |
|---|---|---|---|---|---|---|
| **Qwen3-ASR-0.6B** | Apache-2.0 | 0.6B | **6.24%** | 17.48% | 0.33 | 2.3 GB |
| Voxtral-Mini-4B-Realtime-2602 | Apache-2.0 | 4B | **13.45%** | 34.33% | 2.12 | 9.0 GB |
| `whisper-large-v3-turbo` (anchor) | Apache-2.0 | 809M | **6.44%** | 16.96% | 0.10 | 2.3 GB |
| — recorded baselines (CPU int8, sherpa-onnx; see above) — | | | | | | |
| SenseVoice-2024 (prev. best on-channel) | — | ~234M | 9.0% | 23.1% | — | — |
| zipformer-gigaspeech | — | — | 9.7% | 21.9% | — | — |
| zipformer-small (incumbent) | — | — | 11.2% | 24.1% | — | — |
| parakeet-tdt-0.6b-v3 | — | 0.6B | 14.8% | 37.2% | — | — |
| whisper-base.en | — | 74M | 19.2% | 41.9% | — | — |

**Yes — Qwen3-ASR-0.6B beats the channel, and it is the smallest model in the
table.** At 6.24% on wear10 it is 2.8pp below SenseVoice-2024 (9.0%) and ~5pp
below the zipformer-small incumbent (11.2%), and it repeats the win on
test-other-wear10 (17.48% vs 23.1%) — all from a 0.6B model that used 2.3 GB of
VRAM at RTF 0.33. Voxtral-Mini-4B-Realtime does **not** beat 9.0% (13.45%), and
at RTF 2.12 (one clip at a time) it is ~6x slower than realtime — its
streaming/realtime design trades away both accuracy and speed here. The
whisper-large-v3-turbo anchor behaves sanely — 6.44%/16.96%, demolishing
whisper-base.en (19.2%/41.9%) as a large model should and landing within 0.2pp of
Qwen — which is what makes the Qwen number trustworthy (it came in a touch under
the "probably won't reach 9%" prior, but anchor and candidate agree, so the
harness is sound). The plain conclusion: **the wear10 channel is not the accuracy
ceiling — model capacity was.** Going server-side is worth it, and cheaply: the
winner is a 0.6B model small enough that an edge-server or eventual on-device port
is plausible, not a 4B giant. Recommend trialing Qwen3-ASR-0.6B as the
server-side STT path and deprioritizing Voxtral-Realtime on both accuracy and
latency.
