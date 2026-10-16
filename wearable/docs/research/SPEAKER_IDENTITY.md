<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Persistent speaker identity on-device — implementation recommendation

---

## 1. What Omi actually does, and is "Deepgram does this" right?

**Half-right, and the half that's wrong is the important half.** Deepgram is (was) in Omi's pipeline, but only as a *diarizer*: Omi opens the socket with `diarize=True` and gets back numeric `SPEAKER_00/01/02` labels scoped to one connection — the same within-clip-only limitation sherpa has. A Deepgram collaborator states it plainly: "Our diarization only provides numeric speaker labels. You'll need to do your own additional processing to associate speaker numbers with names" ([deepgram discussions #475](https://github.com/orgs/deepgram/discussions/475)). Deepgram publishes no enrolment, voiceprint, or known-speaker endpoint. Omi's own docs now say hosted Deepgram is **disabled** — the default providers are Modulate Velma-2 and Parakeet, with a self-hosted Deepgram retained for one GKE workload ([docs.omi.me/doc/developer/backend/transcription](https://docs.omi.me/doc/developer/backend/transcription)).

Persistent identity in Omi is Omi's own code, and it is **not** a single owner profile — correct that too. Omi runs `pyannote/wespeaker-voxceleb-resnet34-LM` (the same checkpoint lineage you already ship) behind an HTTP embedding microservice, has a multi-person registry (`Person` records with `speech_samples`, transcript segments carrying `person_id`), sends `speaker_label_suggestion` to the client, and accepts `speaker_assigned` with a `segment_ids` array. The decision policy is ~130 lines of numpy in `backend/utils/stt/speaker_match.py`: **cosine distance < 0.65**, runner-up must be **≥ 0.10 farther**, **≥ 5 s** of accumulated audio, centroid of the last **3** clips. Their comment records the tuning run (2026-09-07): the old 0.45 threshold "taken from a clean-studio VoxCeleb figure" *rejected 40–70% of cross-session owner audio*, because the same user across sessions sits at median distance 0.40–0.53 while strangers sit at 0.93.

Two things Omi does **not** do, verified from source, and these are your differentiators: (a) all of it runs on their servers — a repo-wide search finds zero speaker-embedding code in their Flutter or macOS clients; (b) `PATCH /v1/conversations/{id}/assign-speaker/{speaker_id}` relabels segments **in that one conversation only** — the `expand_speech_profile` call that would turn a named segment into a voiceprint is commented out ("not used for now", `backend/routers/conversations.py:1568-1584`), and no history back-fill job exists anywhere in the repo.

So: don't tell anyone "Omi only has one enrollable voice" — that's checkable and false. Say "Omi does this in the cloud, per-conversation; we do it on the phone, across your whole history."

---

## 2. The recommendation

**Keep the WeSpeaker ResNet34-LM you already ship. Add zero models and zero dependencies. Build a persistent speaker registry in Dart on top of the embeddings you are already computing and throwing away.**

That is the recommendation in full. Concretely:

| Piece | What | Size / licence | Where it runs |
|---|---|---|---|
| Segmentation | `sherpa-onnx-pyannote-segmentation-3-0` — unchanged | ~6 MB, **MIT** (HF page is gated, but you pull k2-fsa's redistribution, which MIT permits) | inside `OfflineSpeakerDiarization`, native |
| Embedding | `wespeaker_en_voxceleb_resnet34_LM.onnx` — **unchanged**, 26,530,550 B, **dim 256** | 25.30 MB, WeSpeaker toolkit Apache-2.0, weights **CC-BY-4.0** (needs a NOTICE entry) | one long-lived background isolate |
| Matcher | ~150 lines of Dart. Cosine + floor + runner-up margin + evidence gate | 0 MB | Dart, background isolate |
| Registry | JSON metadata + packed Float32 sidecar under `getApplicationSupportDirectory()/speakers/` | 0 MB, ~1 KB per stored vector | app-private storage, never leaves device |

**Additional model budget spent: 0 MB.** The gap the owner describes is a bookkeeping gap, not an accuracy gap. `device_bridge.dart:1216-1219` already computes a speaker embedding for every segment — via `OwnerVoice.isOwner()` — and keeps only a boolean. The embedding, the clip-local `seg.speaker` index, and the segment time bounds are all discarded. Adding N known people costs N cosine dot products over 256 floats, which is free.

**Do not use `sherpa.SpeakerEmbeddingManager`.** It exists in your pinned version (`pubspec.lock` resolves `sherpa_onnx: 1.13.2`, and `~/.pub-cache/.../1.13.2/lib/src/speaker_identification.dart` has `add/addMulti/search/verify/remove/numSpeakers/allSpeakerNames`), but it is the wrong layer: it is in-memory only with **no persistence and no save/load**, embeddings are **write-only** (no getter, and `Score()` isn't exported in the C API), `add()` **returns false on a duplicate name** so "add another sample for Dad" is impossible in place, `search()` is a bare argmax-with-floor with no runner-up check, and `addMulti()` sums *raw* embeddings before normalising — a worse centroid than `owner_voice.dart:182-190` already computes (it normalises each vector first, which is correct). You have to keep your own copy of every vector regardless, at which point the manager adds nothing.

**On CAM++_LM: not now, but make the swap cheap.** `wespeaker_en_voxceleb_CAM++_LM.onnx` is genuinely better — EER 0.707% vs 0.797% on VoxCeleb1-O (LM, plain cosine, no AS-Norm; [WeSpeaker voxceleb/v2 README](https://github.com/wenet-e2e/wespeaker/blob/master/examples/voxceleb/v2/README.md)) at 1.15 vs 4.55 GFLOPs, for +2.6 MB. The CAM++ paper's own Table 3 reports RTF 0.013 vs 0.032 for ResNet34 — a 2.46x speedup, single-thread, hardware unnamed ([arXiv 2303.00332](https://arxiv.org/pdf/2303.00332)). But it changes the embedding dim 256 → 512, which silently and permanently breaks every enrolled voice: `cosineSimilarity` guards with `assert`, Dart strips asserts in release, the loop then reads `b[256]` out of range, `isOwner`'s `catch` swallows the `RangeError`, and the owner is never recognised again with only a `debugPrint` to show for it. Ship the registry first **with a `modelId` stamped on every stored vector**, then swap behind that versioning after measuring on the S24 FE. Do not couple a user-visible feature to a migration.

---

## 3. Why not the alternatives

**A bigger/better embedding model (ResNet293-LM, TitaNet-L, SimAM_ResNet34).** ResNet293-LM buys EER 0.532% for 109 MB and **41.5 GMACs per 3-second segment** (counted directly from the ONNX graph) — roughly 6.1x the incumbent, and measured at ~1.86 s per 3 s segment on an Apple M2 at 2 threads. On an all-day worn Exynos 2400 that is disqualifying regardless of the exact millisecond figure. TitaNet-L is 96.7 MB for 0.66%. You are not accuracy-limited.

**ReDimNet / ReDimNet2 (MIT, best accuracy-per-FLOP: B2 at 0.57% Vox1-O for 0.95 GMACs).** No ONNX is published for any variant, and more decisively it takes **raw waveform** input while sherpa's `SpeakerEmbeddingExtractor` computes fbank in C++ and selects its front-end from a `framework` metadata key of `wespeaker`/`3d-speaker`/`nemo`. Adopting it means exporting your own ONNX *and* standing up a second runtime alongside sherpa's — multi-week, new native surface — to buy ~0.14 EER points in a regime where 2-second segments already cost you 2.4x (ERes2NetV2 measures 0.61% full-duration → 0.98% @3s → 1.48% @2s on Vox1-O, [arXiv 2406.02167](https://arxiv.org/pdf/2406.02167)).

**A cloud identification service (Deepgram, pyannoteAI, Omi's own).** Kills the product premise. Also unnecessary — see §2.

**Just lowering the threshold.** Tempting, because 0.65 *similarity* is distance 0.35 — stricter than the 0.45 Omi measured as rejecting 40–70% of legitimate cross-session audio. But your code comment records that 0.55 was raised to 0.65 precisely because a TV voice got tagged as the owner, and a runner-up margin does not defend against a stranger (a stranger is in nobody's registry). The right fix is upstream: enrol from the **wearable** mic instead of the phone mic, and pool evidence across a whole speaker cluster instead of deciding per 1-second segment. Both raise same-speaker similarity so the floor stops rejecting, without re-opening the false-accept hole. Measure, then move the number.

---

## 4. The build

Ordered. Each step is independently shippable and independently verifiable.

### Step 0 — Instrument before you change anything (half a day)

Log, don't decide. In `owner_voice.dart:isOwner`, the `debugPrint('[OwnerVoice] cosine similarity=$sim ...')` already exists; route it into `CaptureDiagnostics.instance.event()` along with segment duration, and add a `Stopwatch` around `DiarizationEngine.diarize()` and `extractEmbedding()`.

**How you know it works:** after a day of real wear you have a scatter of (similarity, duration) for owner-vs-not, plus per-clip diarization latency on the actual S24 FE. Every threshold decision below is calibrated from this, not from Omi's numbers and not from VoxCeleb. Omi's constants come from a *pyannote* wrapper of the same checkpoint with different fbank/windowing — directionally instructive, numerically non-transferable.

### Step 1 — `speaker_registry.dart` (new file, ~150 lines)

```
SpeakerProfile {
  String id;              // ULID
  String name;
  bool   isOwner;
  String modelId;         // 'wespeaker_resnet34_LM'
  int    dim;             // 256
  List<Float32List> enrolled;   // explicit, immutable, never evicted
  List<Float32List> observed;   // implicit, FIFO-capped at 20
  DateTime createdAt, updatedAt;
}
```

Storage: `getApplicationSupportDirectory()/speakers/profiles.json` for metadata + `speakers/<id>.f32` for the packed vectors. **Not SharedPreferences** — Android parses the whole backing XML into memory on first access and rewrites the entire file on every commit, and there is no sqflite/drift/hive in `pubspec.yaml` (the `sqlite3` in `pubspec.lock` is transitive from flutter_gemma with no plugin registration — do not build on it).

Match, in Dart, reusing `_l2Normalize`/`cosineSimilarity` from `owner_voice.dart` verbatim:

```
match(Float32List e, {required double durationS}) →
  if (durationS < minEvidence) return Unknown
  score(profile) = max over that profile's vectors (Apple's rule, not a single centroid)
  best, second = top-2 across NAMED profiles only
  if (best.score >= floor && best.score - second.score >= margin) return best
  return Unknown
```

**Starting constants: `floor = 0.65` similarity, `margin = 0.07`, `minEvidence = 3.0 s`.** Keep the floor where it is until Step 0's data says otherwise; the margin and evidence gate are pure additions that can only reduce wrong names. Tune the floor from your own impostor distribution — for each enrollee, score against every other registry member and set the floor above the observed max impostor score. Do **not** sit at EER: EER prices a wrong name exactly as costly as an "unknown", the opposite of what you want, and on an all-day wearable non-registry speech vastly outnumbers registry speech so equal *rates* still means far more false names than false unknowns.

**How you know it works:** unit tests with injected synthetic vectors (the pattern already exists — `injectEmbeddingForTest`, `owner_voice_test.dart`). Assert: identical vector matches; a vector 0.02 from two profiles returns Unknown, not the argmax; a 1-second segment returns Unknown regardless of score. Also fix the stale test at `owner_voice_test.dart:147-161` — it is named for threshold 0.55 and asserts `cosine(a,a) >= 0.55`, a tautology; the shipped 0.65 is untested.

### Step 2 — Fold `OwnerVoice` into the registry, with migration

Keep every public signature (`isEnrolled`, `ownerName`, `isOwner`, `enrollFromSamples` — five call sites in `wearable_enroll_voice_page.dart` and `wearable_voice_page.dart` must keep compiling). The owner becomes the profile with `isOwner: true`. On first load, migrate the three existing keys (`wearable.owner.enrolled/.embedding/.name`) into a profile stamped `modelId` + `dim`; a dim mismatch means "not enrolled, please re-enrol", never a silent RangeError.

**How you know it works:** an existing install with an enrolled owner still says "You" after upgrade, with no re-enrolment.

### Step 3 — Move embedding off the UI isolate; embed per *cluster*, not per segment

Two changes, and the second matters more than the first.

`sherpa` embeds internally once per **(chunk, speaker)** pair with a hardcoded 1-second window shift over 10-second windows — a 60-second clip is ~51 chunk-embeddings *inside* `diarize()`. That cost exists today. The naming pass does **not** need one embedding per segment: `seg.speaker` is already a per-clip cluster label, so you need **one embedding per distinct cluster** (take the longest segment for each). For a 60-second two-person clip that is 2 embeddings, not 20 — a ~10x reduction versus today's per-segment `isOwner()` call.

Then spawn one long-lived isolate that constructs *its own* diarizer and extractor from `DiarizationProvisioner.instance.embeddingModelPath` (a plain `String`, SendPort-safe), takes `Float32List` in and plain `{start, end, speaker, profileId, score}` records out. This sidesteps the "`Pointer<T>` is not SendPort-safe" blocker documented at `diarization_engine.dart:15-22` and `owner_voice.dart:13-16`.

**Risk, spike it first:** whether `sherpa.initBindings()` behaves in a secondary isolate is **NOT VERIFIED**. If it doesn't, ship the per-cluster change alone — that alone removes most of the jank. Also note the isolate holds a second 26 MB native copy of the model, and `DiarizationEngine.dispose()` is currently never called from anywhere in `lib/`.

**How you know it works:** the Step 0 Stopwatch numbers drop ~10x on the naming pass; the UI does not drop frames during a 60-second utterance; a 10-minute continuous-wear run does not thermally throttle.

### Step 4 — Persist transcripts with their evidence

`transcript_log.dart` is the deepest blocker: RAM-only, capped at 50, and `TranscriptEntry` is a `const`-constructible record of four fields with no id and no embedding. Widen it with `id`, `clipId`, `clusterIndex`, `profileId`, `Float32List embedding`, `double durationS`; keep the 50-entry RAM window for the UI and append every entry to `speakers/../transcripts.jsonl` (embeddings as base64, ~1.37 KB each; ~2 MB/day at 2000 segments). Add `OnDeviceTranscriptLog.relabel()`. The `ValueNotifier` already replaces its whole list value, so the UI repaints with zero widget changes.

This is the step with a real privacy review attached — transcripts *and* biometric vectors now sit on disk. Put them behind the existing `security/app_lock.dart`, and ship a delete-everything path in the same PR.

**How you know it works:** kill the app, reopen it, past transcripts are still there with their labels.

### Step 5 — Fix the label fusion, then add tap-to-name

`device_bridge.dart:1225` pushes `'$talker: $text'` to the server while the single-speaker branch at :1250 pushes bare `text`. As long as the label is fused into the payload, nothing you rename locally can ever propagate. Send the label as a separate field. (While you're there: `diarHandled` at :1268 is unreachable dead code — the branch that sets it always returns at :1232.)

Then wrap the talker chip at `transcripts_page.dart:209-229` in a `GestureDetector` → bottom sheet listing known profiles plus "New person…". The page has **zero** tap handlers today (`grep onTap|GestureDetector|InkWell|onLongPress` returns nothing), so this is purely additive.

**What naming does — the back-fill rule, in three tiers:**

1. **Same clip, same cluster index — exact, silent, immediate.** These segments are the *same* cluster by construction, not by similarity. Relabel all of them, no threshold involved.
2. **Past history — re-score, propose, never silent.** Score the new profile's vectors against every stored transcript embedding. Anything clearing `floor + margin` is offered as "Found 14 more from Sarah in the last 30 days — apply?" with a preview list. The user confirms. **Never** rewrite history without asking: a confidently-wrong retroactive relabel across weeks of transcripts is the worst possible failure of this feature.
3. **Future clips — automatic, above threshold, once per cluster per clip.**

Back-fill depth: bound it at **30 days**, for two reasons — the vectors are biometric data you should not hoard, and older audio is further from the enrolled channel so the match is weaker exactly where you can least verify it.

**How you know it works:** record a two-person clip, tap "Talker 2", name her Sarah. Every Talker-2 line in that clip becomes Sarah instantly. Record a second clip the next day with the same person; she is labelled Sarah automatically. Name a third person from a clip recorded before Sarah was enrolled and confirm the back-fill preview lists the right lines and nothing else.

### Step 6 — Fix enrolment (do not skip this)

Three changes to `wearable_enroll_voice_page.dart`: enrol from the **wearable mic**, not the phone mic (today's 8 s of phone PCM16 bakes in a channel mismatch on the one voice you care most about — a chest-worn MEMS mic at 20-30 cm with chest resonance is a materially different channel from a hand-held phone at 1-3 m); capture **three separate clips across three sessions**, not three slices of one 8-second recording; and show the user their own self-similarity score so a bad enrolment is visible at enrolment time.

The evidence for multi-utterance: on VoxBlink2's open-set identification benchmark at a 60-speaker gallery — the realistic size for a personal registry — going 1 → 3 enrolment utterances moves DIR@FAR=0.001 from **88.10% to 96.32%**; 3 → 5 adds only 0.65 more ([arXiv 2407.11510](https://arxiv.org/html/2407.11510v1), Table 5). Three is the knee. Caveat honestly: that table varies only enrolment count on a single ResNet50 backbone, so "enrolment matters more than model choice" is an inference, not a measured result — but it's the only axis anyone has measured on this task.

For non-owner people, enrol the way Omi does: cut clips from real conversations already captured by the wearable, so enrolment and matching share a channel. Bonus, free: Omi ships per-language regexes over the transcript catching self-introductions (`\b(I am|I'm|My name is)\s+([A-Z][a-zA-Z]*)\b`). Treat a hit as a *proposal* — "Is this Sarah?" — never an auto-label; "I'm sorry" will fire it.

---

## 5. What will go wrong

**A wrong name, confidently applied.** This is the worst failure and it is the one the design must be tuned against, because a wrong attribution in a transcript of a real conversation is not a cosmetic bug — it puts words in someone's mouth. Three defences, all in the plan: the runner-up margin (two similar-sounding registry members otherwise produce a confident wrong argmax — Omi measured owner-vs-own-family distances as low as 0.43, which is why their margin exists); the evidence gate (Omi's bench: 2-second clips had 17% EER against 10% at five seconds); and never back-filling history without confirmation. Make **Unknown a first-class UI state** — an unnamed segment is correct behaviour, not a bug.

**Channel mismatch.** Your enrolled owner vector currently comes from the phone mic and every match comes from the wearable. That is a different acoustic channel, and far-field enrolment/test mismatch is a well-known degradation. It is very likely a bigger contributor to "it doesn't recognise me" than the threshold value. Fix at Step 6. There is no published EER for WeSpeaker ResNet34-LM on chest-worn Opus-over-BLE audio; **NOT VERIFIED**, and only your own bench closes it.

**One bad enrolment poisons the profile.** If you auto-add runtime samples to a profile, you have built a template self-update system, and its failure mode is documented as an attack ([Biggio et al., "Poisoning Adaptive Biometric Systems"](https://link.springer.com/content/pdf/10.1007/978-3-642-34166-3_46.pdf); Lovisotto et al., "Biometric Backdoors", EuroS&P 2020). Apple states the benign version: "if enough of these get included early on, the resulting profile will be corrupted" ([Personalized Hey Siri](https://machinelearning.apple.com/research/personalized-hey-siri)). Defences: only admit samples that cleared floor *and* margin *and* the duration gate; keep the explicit `enrolled` vectors immutable and un-evictable so you can always roll back; FIFO-cap the `observed` pool at 20; never admit a forced or low-confidence assignment.

**Registry growth.** Open-set false alarms scale badly: VoxWatch measures FAR@FRR=5% going from 2.4% to 16.1% as the gallery grows 50 → 500 speakers ([arXiv 2307.00169](https://arxiv.org/abs/2307.00169)), and on VoxBlink2's 6,000-speaker gallery DIR@FAR=0.001 collapses to 24.94%. A device worn all day will accumulate hundreds of one-off unknown clusters. So: **search only the named set**. Unknown clusters get their own ids for grouping and back-fill but are excluded from identification, and are TTL'd out after 30 days without a re-hit. Counter-intuitive and worth heeding: VoxWatch found AS-Norm *not* guaranteed to help on this task, so don't reach for score normalisation as the fix — it would also mean shipping an impostor cohort on-device.

**Short segments.** `minDurationOn: 0.2` admits 200 ms segments; the transcription branch already drops anything under 1.0 s (silently losing short interjections from the transcript entirely, which is its own small bug). Identity needs ≥3 s pooled. Segments below that should inherit the label from adjacent same-cluster segments, never get their own match.

---

## 6. Open questions — only the ones that change the build

1. **Is on-device transcription the default, or is cloud?** `transcription_mode.dart:34` sets `defaultMode = TranscriptionMode.cloud`, which streams raw audio to the server. If the privacy property is the point of the project, that one line contradicts it — and it also decides whether the registry is the *only* identity layer or has to reconcile with server-side Deepgram labels arriving via `device_bridge.dart:1383`. **Answer this first; it changes Step 5's precedence rules.**

2. **Do we retain enrolment audio?** Omi keeps enrolment WAVs precisely so a model upgrade can regenerate embeddings (`speech_samples_version` v1→v2→v3 migration). Without retained audio, a CAM++ swap means every user re-enrols every person from scratch. Keeping it means storing raw voice recordings of third parties on the phone. There is no published treatment of embedding-registry migration without retained audio — the honest answer is probably "re-enrolment required", but decide it explicitly now because it determines whether Step 1's schema has an `audioPath` field.

3. **How many people, realistically — 5, 20, or 200?** At 5 the margin rule is near-decorative and a fixed floor is fine. At 200 you need per-person calibration and aggressive unknown-cluster GC, and the VoxWatch curve starts to bite.

4. **What does the server do with a name?** Step 5 changes the wire format to unfuse the label from the text. Does the server store `speakerLabel` per utterance, and does a later rename need to propagate to already-pushed transcripts? Note `server-contract/src/device/voice-profiles.ts` already has the registry shape *and* an unused `embedding` BLOB column reserved for exactly this ("the `embedding` blob column is reserved in the schema; reads of it are no-ops here until the matcher is wired") — so there is a settled data model to mirror, but only if the answer is "yes, server-side too".

5. **Consent.** Identifying and persistently naming third parties from a body-worn recorder has a legal surface that varies by jurisdiction. Does a person need a "do not identify me" state, and does that state delete their vectors or merely suppress the label? This changes the `SpeakerProfile` schema and the delete path in Step 4.
---

## 7. Paper review — "Balancing ASR and diarization in end-to-end LLMs" (arXiv 2606.13095)

Zheng et al., Huawei Technologies, 11 Jun 2026. Reviewed 2026-09-10 at the
owner's request: does joint ASR+diarization in one LLM beat our cascade?

**Verdict: not adoptable. Three transferable ideas, and one useful confirmation.**

### What it is

A single 0.7B model that emits speaker-attributed transcript directly. Dual
encoder — SenseVoice-small for semantics, CAM++/Campplus for speaker — feeding
Qwen2.5-0.5B-Instruct through LoRA. A `<SC>` token marks each speaker change
and is immediately followed by a speaker-ID digit, so diarization becomes token
prediction rather than a clustering stage. Best config (temporal interleave +
adaptive ASR mask) scores **cpCER 27.16% on AliMeeting Test, 19.98% on Aishell4
Eval** — 18%/24% relative over their own cascaded baselines.

### Why it cannot ship here

1. **Mandarin only.** WenetSpeech pretraining, a private 4,000 h Mandarin
   conversation corpus, then AliMeeting + Aishell4. No English model exists.
   Ours is English-only zipformer.
2. **Nothing released.** No code, no checkpoints — checked the paper body and
   the arXiv listing. Stages 2 and 3 depend on that internal 4,000 h corpus, so
   the recipe is not reproducible even with effort.
3. **~0.7B parameters, autoregressive.** Roughly 1 GB with both encoders,
   against the 30 MB we ship, and LLM decode instead of transducer decode. This
   is precisely the trade we rejected when we left Gemma and then Moonshine.
4. **The accuracy is still not a usable transcript.** 20–27% cpCER is meeting
   audio in a room. A chest mic adds clothing rustle, body noise, and the
   wearer's own voice tens of dB above everyone else's.

Fair to the paper: it uses **only the first far-field channel**, so the task
framing is single-channel and does transfer. And its numbers are far better
than the 57.81% tcpCER that full-size VibeVoice-ASR scores on multi-party
egocentric capture (a published figure — see ASR_CANDIDATES.md §multi-party —
not one of our own measurements). The gap is the corpus, not the method:
meeting-room audio is an easier problem than a chest mic.

### The confirmation worth keeping

Section 2.3 documents our own bug from the other side. In overlapped regions
the model "can detect the presence of overlaps but cannot reliably infer their
content", so it "repeatedly generates backchannel words to fill the uncertain
regions, thereby triggering hallucinations." That is the same disease as the
silent capture that produced a person's name: **a generative decoder asked to
transcribe low-information audio invents plausible tokens.** Their fix is
training-side (mask high-CE tokens); ours is inference-side (VAD gate before
the recogniser). Both work because both stop the decoder seeing that audio.
It is an argument for the transducer we now run, not against it.

### Three things we can actually take

- **Multi-scale chunked speaker embeddings.** They pool CAM++ statistics inside
  400/200/100 ms chunks and concatenate, rather than one embedding per segment.
  Pure inference-side; would make our WeSpeaker embeddings steadier on short
  turns. Cheapest of the three to try.
- **Downsample the speaker stream 4x.** Fig. 3: at a 1:0.25 speech-to-speaker
  frame ratio, cpCER stays acceptable while input length drops 75%; CER is flat
  throughout. If we ever run embeddings alongside ASR, run them at a quarter
  rate.
- **Change-point first, identity second.** Predicting "the speaker changed
  here" is a strictly easier problem than "this is Alice", and they use it as
  the bridge. Our registry should segment on change points and attach identity
  afterwards, which is also the shape that lets a user tap a turn and name it.

### Still unsolved, here as well as there

Their conclusion lists speaker **registration** as future work. Nobody has
shipped the "tap that speaker, name them, remember it" flow at this scale — it
remains our own build (§4), not something to adopt.
