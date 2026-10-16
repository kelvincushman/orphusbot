<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Capture-device plan — parallel work packages

**Base:** the tip of `feat/on-device-gemma-stt` (wearable repo) — the commit that adds this file. The registry landed at `b0dcd20` just before it.
**Orchestrator:** integrates, builds, installs, tests on hardware. Does not write package code.
**Agents:** one per package, Opus, each in its own git worktree, each returning a structured report.

---

## 0. What we are building

The owner's words: *"we are building a capture device here."* The pipeline:

```
wearable (nRF52840, Opus/BLE)
   │  16 kHz audio, button events, LED/haptic cues
   ▼
phone app — CAPTURE + FAST STT + LIGHT TIDY, all on-device, audio never leaves
   │  zipformer-small (offline, 11.19% WER on our channel, 46× realtime)
   │  streaming zipformer for live preview (16.26% WER, preview only)
   │  speaker registry: who is talking, owner always tagged, others by name, capped
   │  Gemma 4 E2B tidies the TEXT (casing, punctuation, obvious mishearings) — or doesn't
   ▼
server (Nova / "omarchy") — THE THINKING
   │  bigger model makes sense of it, does tool calls for tasks
   ▼
Obsidian — memories
```

Everything phone-side is measured, not assumed. Everything phone-side is MIT-compatible
(the repo is going public). Nothing phone-side sends audio anywhere.

## 1. State at the base commit — what works and what is measured

| Piece | Status | Evidence |
|---|---|---|
| Offline ASR (zipformer-small-en, int8, 28 MB) | shipped | 30 s decoded in 642 ms = **46.7× realtime** on Exynos 2400; 11.19% WER on our channel sim |
| VAD gate (Silero v5) | shipped | gate-not-segmenter; a silent press logs `No speech found` instead of inventing a name |
| Live preview (streaming zipformer, 73 MB) | shipped, optional download | 16.26% WER — preview only; saved transcript is the offline pass |
| Foreground service | shipped | kill reason was `excessive binder traffic during cached`; oom_score_adj 850 → **200**, frames unbroken with Twitter in front |
| Multi-scale speaker embeddings | shipped | 15 tests; whole-clip always blended in |
| Speaker registry + tap-to-name | shipped (`b0dcd20`) | 19 + 12 tests; per-cluster identity; owner from wearable audio |
| Gemma polish model | E2B pinned, download tile restored | **not yet verified on device** — orchestrator owns this |
| Diarization (pyannote seg 3.0 + WeSpeaker ResNet34-LM) | shipped | `Talker 1 … Talker 2` observed in real captures, 37–61× realtime |

Known stale/incomplete, in scope below: `gemma_transcriber.dart` holds a dead class; personal
dictionary (hotwords) was lost in the ASR move; transcripts are ALL CAPS with no punctuation
(model's native output); `_pushTranscript` fuses `'$talker: $text'` so a rename can never
propagate; Privacy Mode / push-to-talk / segment-and-continue not built; SD offline recording
blocked on a Kconfig conflict; `app/lib/wearable/README.md` still describes Gemma E4B doing STT.

## 2. Rules for every package — non-negotiable

1. **Worktree per package.** Create it yourself; the session's cwd is a *different* repo.
   ```bash
   git -C ~/dev/Projects/dev/wearable worktree add \
       ~/dev/Projects/dev/wearable-wt/<pkg> -b agent/<pkg> feat/on-device-gemma-stt
   cd ~/dev/Projects/dev/wearable-wt/<pkg>/app && fvm flutter pub get
   ```
   Everything lives on the external dev disk. Never touch `~/dev/Projects/dev/wearable` directly.
2. **`fvm flutter`, never bare `flutter`.** The Homebrew Flutter cannot resolve `flutter_gemma`.
3. **Do not run `scripts/build-apk.sh` or `flutter build`.** Eight cores, several agents. Verify with
   `fvm flutter analyze <your files>` and `fvm flutter test test/wearable/`. The orchestrator builds once.
4. **Do not touch the phone or the wearable.** No `adb`, no flashing. Report what needs hardware.
5. **Licence gate.** Any new dependency or model must be MIT / BSD / Apache-2.0 / CC-BY. Verify
   (pub.dev page, HF `cardData.license`, or the repo LICENSE) and cite it in the report. If nothing
   qualifies, **stop and report** — do not substitute.
6. **Read before you rely.** Every API this plan names, verify in the file before calling it.
   Pinned versions: `sherpa_onnx` resolves to **1.13.2** (`pubspec.lock`), `flutter_gemma` **1.7.4**.
   Package sources are in `~/.pub-cache/hosted/pub.dev/`.
7. **Stay inside your file list.** The conflict map (§4) is the whole point of the split. If you must
   touch a file another package owns, stop and put it in `openQuestions`.
8. **Karpathy rules apply** (repo `CLAUDE.md`): surgical diffs, no speculative abstractions, match
   existing style, comments explain *why*. Tests first where the logic is pure.
9. **Commit on your branch** with a conventional message that explains the reasoning, ending
   `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. One package, one or a few commits.
10. **Report honestly.** The structured report asks for evidence, not claims. "Tests pass" means you
    ran them and paste the tail. Anything unverified is marked unverified.

## 3. Work packages

### P0 — Harden what just landed

**Goal.** Finish the registry slice properly: the two lints, the missing tests, and the privacy
escape hatch that the registry has in code but not in the UI.

**Files.** `app/lib/wearable/widgets/name_speaker_sheet.dart`,
new `app/lib/wearable/pages/settings/wearable_people_page.dart`, one link to it from
`wearable_voice_page.dart`, tests under `app/test/wearable/`.
**Do not touch:** `transcript_log.dart` (P2 owns it), `device_bridge.dart`.

**Work.**
- Fix `prefer_const_constructors` at `name_speaker_sheet.dart:184`. (The `unnecessary_import` in
  `transcript_log.dart:11` belongs to P2 — leave it.)
- Widget tests for `NameSpeakerSheet`: under 3 s of evidence no enrol actions render and the copy
  says why; at `maxNamed` the "someone new" field is replaced by the cap message; "This is me" calls
  `OwnerVoice.enrollFromEmbedding` and relabels the same clip/cluster.
- A unit test for `OnDeviceTranscriptLog.relabel` (same clip+cluster changes, others untouched,
  returns the count). Put it in a new test file — do not edit the log's source.
- **People page** (Settings): lists every registry profile (owner first) with name, enrolled/observed
  counts, created date; per-profile remove; a "Delete all voices" action with a confirmation that
  states plainly these are biometric vectors. Uses `SpeakerRegistry.remove` / `clearAll`. Match the
  visual language of `wearable_voice_page.dart`.

**Acceptance.** `fvm flutter analyze` clean on your files; full `test/wearable/` green; the people
page renders with 0, 1 and 10 profiles in a widget test.

### P1 — The training experience ("make it feel magic")

**Goal.** Enrolling your voice should be a moment, not a form — and it must enrol from the
**wearable's mic**, because that is the channel every future match runs on. The current page uses
the phone mic (`wearable_enroll_voice_page.dart`), which is the wrong channel and one 8-second
recording, which is the wrong quantity (VoxBlink2: 1 → 3 enrolment utterances moves open-set
identification 88.1% → 96.3%; 3 is the knee).

**Files.** Rewrite `app/lib/wearable/pages/settings/wearable_enroll_voice_page.dart`; new
`app/lib/wearable/local_llm/voice_training.dart` (controller, pure logic, testable);
`app/lib/wearable/pages/transcripts_page.dart` **only** to add the proposal card (§ below);
tests. **Do not touch:** `device_bridge.dart`, `owner_voice.dart`, `speaker_registry.dart`.

**How the page gets wearable audio.** `wearable_dictation_page.dart` claims the app's capture
surface while mounted via `WearableAudioSession` (`app/lib/wearable/wearable_audio_session.dart`).
Read both files and use the same mechanism. If the session only yields phone-mic PCM, stop and report
— do not silently fall back to the phone mic.

**The experience.**
- Three short guided prompts (a sentence each, ~4–6 s of speech), with a live level meter and a
  progress ring that fills as the VAD detects speech. Use Silero through `ZipformerTranscriber`'s
  existing VAD if reachable, else RMS.
- After each clip: extract with `OwnerVoice.instance.extractRobustEmbedding`, show the
  **self-similarity** to the previous clips (cosine). Below the registry floor, say so and offer a
  retake rather than accepting a bad enrolment.
- On completion: `OwnerVoice.instance.enrollFromSamples` with all three clips (it stores them as
  separate vectors — that is deliberate). A short celebratory state. Then the transcript list shows
  "You" from the next capture.
- Animation: Flutter's own `AnimationController`, implicit animations, `TweenSequence`. No new
  packages unless MIT and you can say why the framework cannot do it.
- **Proposal-based enrolment (the magic moment).** In `voice_training.dart`, a pure function that,
  given the last N `TranscriptEntry`s, finds an unnamed cluster that recurs across ≥ 3 clips with
  ≥ 5 s pooled speech each and high mutual similarity (cosine ≥ floor between their embeddings).
  When one exists, `transcripts_page.dart` shows a dismissible card: *"This voice is in most of your
  recordings — is it you?"* → one tap → `OwnerVoice.enrollFromEmbedding` for each of those clusters'
  vectors, and relabel via `OnDeviceTranscriptLog.relabel` for each. Dismiss remembers for the
  session. Never auto-enrol without the tap.

**Acceptance.** Controller logic unit-tested (prompt sequencing, self-similarity gating, proposal
detection with synthetic entries); page builds and animates in a widget test; full suite green.

### P2 — Gemma tidy on the wearable path, gated (LatentASR-derived)

**Goal.** Run the Gemma tidy pass over saved wearable transcripts — but only where a measurement
says the recogniser struggled. Rationale and design in
`docs/research/ASR_CANDIDATES.md` § "Revisit — LatentASR". Read it first.

**Files.** `app/lib/wearable/local_llm/polish.dart`, new
`app/lib/wearable/local_llm/tidy_gate.dart`, `app/lib/wearable/local_llm/transcript_log.dart`,
`app/lib/wearable/local_llm/streaming_transcriber.dart` (expose the clip's last preview text),
`device_bridge.dart` **hook only** (see below), a settings toggle on `wearable_voice_page.dart`
or the model page, tests. **Do not touch:** `gemma_transcriber.dart`, `vocabulary_store.dart` (P4).

**Work.**
- `PolishTone.tidy`: a strict prompt. Fix capitalisation, punctuation and obvious mis-hearings from
  context. **Never** add openings, closings, sentences or words that are not in the input; never
  summarise; output only the corrected text. The LatentASR paper's Table 13 shows an AR model
  systematically inventing "Thank you, Madame" openings — put the rule in the prompt, not the
  model's discretion. Keep `sanitizePolish`'s 2× expansion cap; add a **word-count** cap
  (output ≤ input words + 10%) for tidy specifically.
- `TidyGate.decide(...)` → `{run: bool, reason, score}`. Signal, in order of preference:
  (a) normalised edit distance between the streaming preview and the offline transcript for the same
  clip, when the live model produced one; (b) otherwise VAD kept-ratio and words-per-second from the
  existing logs. Thresholds are constants with a comment saying they are starting points to be tuned
  from the decision log. Pure function; unit-test it.
- `TranscriptEntry` gains an `id` (ULID-ish string); `OnDeviceTranscriptLog.replaceText(id, text)`
  and `isTidied` flag so the UI can mark tidied lines subtly. Remove the `unnecessary_import` lint.
- **The hook in `device_bridge.dart` is one function call**, `unawaited(_maybeTidy(entryId, …))`,
  placed immediately after each `OnDeviceTranscriptLog.instance.add(` in the three transcript paths
  (two diarization branches, one plain). Nothing else in that file. Tidy runs after the entry is
  visible, replaces the text when done, and never blocks capture. If Gemma is not installed or the
  toggle is off, the hook is a no-op.
- Log every decision: `[TidyGate] run=… reason=… score=… latencyMs=…`.

**Acceptance.** `TidyGate` and the tidy prompt sanitiser unit-tested (a rewrite that adds a sentence
is rejected; a rewrite that only recases/punctuates passes); full suite green; the device_bridge
diff is ≤ 15 lines.

### P3 — Capture semantics: Privacy Mode, push-to-talk, segment-and-continue, label field

**Goal.** Make capture behave the way the owner asked for months ago: continuous by default, the
button is an *instruction*, not a start/stop, and the label travels as data.

**Files.** `device_bridge.dart` (capture window / button handling / `_pushTranscript` — **not** the
diarization-and-transcribe branch, roughly L1200–1330, which P2 hooks into),
`app/lib/wearable/local_llm/transcription_mode.dart`, `app/lib/wearable/wearable_client.dart`,
the Wearable dashboard page and its Capture card, tests. **Do not touch:** `polish.dart`,
`transcript_log.dart`, `zipformer_transcriber.dart`.

**Work.**
- **Privacy Mode.** The current "Button" segmentation becomes *Privacy Mode*: a prominent toggle on
  the Wearable dashboard's Capture card, off by default. Off = continuous capture. On = only
  button-armed captures are transcribed (ambient audio is discarded, not stored). The setting name
  and copy say "Privacy Mode"; the old enum value is migrated, not renamed in storage.
- **Push-to-talk semantics.** A single press *arms the next utterance as an instruction*
  (`overheard: false`) while continuous transcription carries on. The press no longer opens a window
  that must be closed; the utterance boundary comes from the existing `UtteranceBuffer`. Keep the
  existing hold/double-tap grammar (docs in `firmware/`) unchanged.
- **Segment-and-continue.** At the capture cap (currently 120 s in `UtteranceBuffer` /
  `_captureBudgetTimer`), close the segment, hand it to transcription, and keep recording with the
  pre-roll intact — no gap, no lost audio. Add the cap as one named constant with a comment.
- **Label as a field.** `_pushTranscript` sends `talker` as a separate field (`talker: String?`)
  through `WearableClient.sendDeviceText`, and stops fusing `'$talker: $text'`. Backward-compatible
  on the wire: the field is optional. (Server side is P6.)
- Also remove the unreachable `diarHandled` dead code noted in SPEAKER_IDENTITY.md §Step 5, only if
  it is entirely within your region.

**Acceptance.** Mode migration unit-tested; `UtteranceBuffer` cap behaviour tested (segment closes at
the cap, audio after the cap is not lost); client encodes `talker` as a field in a test; full suite
green. State clearly in the report what could only be verified on hardware.

### P4 — Personal dictionary → recogniser hotwords; retire the dead Gemma transcriber

**Goal.** Restore the personal dictionary the ASR move lost, in the place it now belongs — the
recogniser — and delete the code that only the old path used.

**Files.** `app/lib/wearable/local_llm/zipformer_transcriber.dart` (config only),
`app/lib/wearable/local_llm/streaming_transcriber.dart` (stream creation only),
`app/lib/wearable/local_llm/gemma_transcriber.dart` (delete the class; move `sanitizeTranscript`
to a new `transcript_sanitizer.dart`), `app/lib/wearable/services/vocabulary_store.dart`, tests.
**Do not touch:** `polish.dart` (P2), `device_bridge.dart`.

**Work.**
- Read `~/.pub-cache/hosted/pub.dev/sherpa_onnx-1.13.2/lib/src/offline_recognizer.dart` and
  `online_recognizer.dart`. Confirm the exact hotwords API (`hotwordsFile`/`hotwordsScore` on the
  config; `createStream(hotwords:)` on the online recogniser) and, critically, the **required format**:
  sherpa needs hotwords as BPE pieces matching the model's `tokens.txt`, or a `modeling_unit` +
  `bpe_vocab` so it can tokenise words itself. Determine which the pinned zipformer models support
  (check their `tokens.txt` and whether a `bpe.model` ships). Report what you found before relying on it.
- Write the dictionary words to a hotwords file in Application Support in the required format on
  every change; wire `hotwordsFile` + a score constant (start 1.5, comment it) into both recognisers.
- Delete `GemmaTranscriber` and `buildTranscriptionPrompt`; move `sanitizeTranscript` (used by
  zipformer) into its own file; update `vocabulary_store.dart` and the tests that referenced the
  prompt builder. `VocabularyStore` keeps its public surface.
- If hotwords cannot be made to work with the pinned models without a `bpe.model` we do not ship,
  **report that** with what would be needed, and still do the dead-code removal.

**Acceptance.** Hotwords file format unit-tested against a tokens.txt fixture; full suite green;
`grep -rn GemmaTranscriber app/lib` returns nothing.

### P5 — Punctuation and casing, cheap and always-on

**Goal.** Transcripts read `JEST LOOKIN SEE IF I NEEDER HAD A DIARIN`. That is the model's native
output. Add the cheap fix that runs on every note, so Gemma (P2) is only ever the expensive one.

**Files.** New `app/lib/wearable/local_llm/punctuation_provisioner.dart` and
`app/lib/wearable/local_llm/punctuator.dart`; `zipformer_transcriber.dart` **return path only**
(one call before `sanitizeTranscript`); the model page tile; tests.
**Do not touch:** `zipformer_transcriber.dart`'s config block (P4), `polish.dart`.

**Work.**
- Find a sherpa-onnx **English** punctuation (+ casing if available) model. The Dart binding
  exposes `OfflinePunctuation` (`lib/src/offline_punctuation.dart`) and `OnlinePunctuation`. Candidates
  are published as GitHub release assets under `k2-fsa/sherpa-onnx` (tag `punctuation-models`) and
  as HF repos under `csukuangfj/`. **Verify the licence** from the model card / bundled LICENSE / the
  upstream model's licence (many are CT-Transformer from FunASR — check whether the weights carry
  the FunASR Model licence, which is *not* OSI; if so, reject). If nothing English + permissive
  exists, stop and report options.
- Provisioner: copy `streaming_provisioner.dart`'s pattern exactly — pinned immutable revision,
  byte count + SHA-256 per artifact verified from the HF API / release, a test that fails on a mutable
  ref, `sizeLabel` on the class.
- `Punctuator`: lazy-load, serialise calls, never throw (return the input on any failure), log RTF.
- Apply at the end of `ZipformerTranscriber._run`; if the model is absent, pass-through.
- Tile: "Punctuation (optional)" between ASR and Live preview on the model page.

**Acceptance.** Provisioner pin test; punctuator pass-through test; full suite green; licence cited.

### P6 — Server: accept `talker` as a field  *(nova-pai repo, TypeScript)*

**Goal.** The phone will stop fusing the label into the text (P3). The server must take it as data
and carry it to where it matters — the prompt and the Obsidian record.

**Repo.** the reference server repository — the session's cwd; `isolation: worktree` works
here. Read `CLAUDE.md` there first: two-reviewer gate, Bun, `bun run test`.
**Files.** `src/harness/device/` (event schema + handler), `src/harness/inngest/device-prompt.ts`,
`src/memory/obsidian-writer.ts` (the `speakers` frontmatter already exists — populate it), tests.

**Work.** Optional `talker?: string` on the device text event; validated (length ≤ 64, trimmed);
propagated on `nova/device.audio.final` and into the prompt assembly as `[<talker>] <text>`;
written to the Obsidian conversation frontmatter `speakers`. Absent talker → byte-identical
behaviour to today. Tests for present/absent/oversized.

**Acceptance.** `bun run typecheck` and `bun run test` green (the four boardroom failures without
LiveKit keys are expected — say so). Do not push; do not restart services.

### P7 — Documentation

**Goal.** The docs describe a system that no longer exists.

**Files.** `app/lib/wearable/README.md`; new `docs/ARCHITECTURE_CAPTURE_PIPELINE.md`.
**Do not touch** code.

**Work.** README: Gemma is E2B, CPU, text-only polish, ~2.6 GB, optional; ASR is zipformer via
sherpa; live preview; foreground service; speaker registry; the three model downloads. Architecture
doc: the pipeline in §0 above with the measured numbers from §1 and the research docs, the
privacy boundary (what never leaves the phone), the model inventory with sizes and licences, and
the open questions in §6. Link the research docs rather than restating them.

**Acceptance.** Every number cited traces to a research doc or a commit message; no claims about
unmeasured behaviour.

### P8 — SD offline recording: unblock the Kconfig conflict  *(firmware, investigate + build only)*

**Goal.** Both sides of SD offline recording are written; it is disabled because enabling
`CONFIG_DISK_DRIVER_SDMMC` / `CONFIG_SPI` in the current config disables battery and USB.
Find out whether that is a real hardware conflict or a config one.

**Files.** `firmware/devkit/` config and overlays (`prj_novapai.conf`, `overlay/*.overlay`,
`Kconfig`), plus a written finding. Zephyr 4.4.2 upstream at `~/dev/zephyr/ws`,
board `xiao_ble/nrf52840/sense`. Build command in the repo `CLAUDE.md`.

**Work.** Diff the enabling variant against the current config; trace which nodes the SD overlay
claims (SPI instance, pins) against what battery ADC and USB use; propose a config where all three
coexist if the pins allow it; build it; report `west build` output and flash size. **Do not flash.**
If it is a genuine pin conflict, say which pins and what the options are.

**Acceptance.** A build artifact (or a precise reason there cannot be one) and a finding the
orchestrator can act on with the device in hand.

## 4. Integration order and conflict map

| Package | Owns | Shared touch | Merge after |
|---|---|---|---|
| P0 | name_speaker_sheet, people page, tests | — | first |
| P4 | zipformer config, streaming stream, gemma_transcriber, vocabulary_store | `zipformer_transcriber.dart` (config) | P0 |
| P5 | punctuation files, model page tile | `zipformer_transcriber.dart` (return) | P4 |
| P3 | device_bridge capture/push, transcription_mode, wearable_client, dashboard | `device_bridge.dart` (L400–1100, `_pushTranscript`) | P5 |
| P2 | polish, tidy_gate, transcript_log, streaming preview text | `device_bridge.dart` (3 one-line hooks) | P3 |
| P1 | enrol page, voice_training, transcripts_page card | `transcripts_page.dart` | P2 |
| P7 | docs | — | any |
| P6 | nova-pai | — | independent repo |
| P8 | firmware config | — | independent tree |

The orchestrator merges branches in this order, runs the full suite after each, resolves any
conflict by hand, then builds one APK.

## 5. Kept by the orchestrator — needs hardware

- Install the `01ec71c` build; **download Gemma E2B in-app; force-stop; relaunch; confirm
  `[ModelManager] restored active inference model`** in logcat. This is the "vanished on restart"
  verification. Then the first tidy on a real note.
- Install the integrated build; enrol via P1's flow on the wearable; confirm "You" on the next capture
  and a `[WearableBridge] cluster 0: matched … -> You` log line.
- Battery and thermal over an hour of continuous capture — the number that gates continuous live
  transcription. Not built until measured.
- Flash P8's firmware if its finding says it is safe.

## 6. Open decisions for the owner

1. **Retain enrolment audio, or vectors only?** The registry keeps vectors. Keeping the clips would
   allow re-enrolment after a model swap without asking again; it is also more to protect.
2. **Consent for naming third parties.** The registry can name anyone the wearer chooses to. That is
   a product and legal position, not a code one.
3. **Auto-tidy default.** P2 ships the toggle off. Decide whether it defaults on once the decision
   log shows how often the gate fires.
4. **Continuous live transcription** waits on the battery measurement in §5.
