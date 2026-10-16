// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// TidyGate — decide whether a saved transcript is worth spending Gemma on.
//
// Derived from LatentASR (arXiv 2607.05051) and the re-read of it in
// docs/research/ASR_CANDIDATES.md § "Revisit — LatentASR". The paper's Value
// Head predicts, per utterance, whether its expensive refinement loop will
// help, and skips it when the answer is no: 60.2% of VoxPopuli and 47.0% of
// FLEURS are skipped at the entry gate, and Table 12 checks counterfactually
// that forcing the loop on the skipped set buys +0.01 pp. The gate is
// discarding exactly the cases where compute would not have helped.
//
// Our expensive stage is a ~2.6 GB language model that takes seconds per note.
// The signal costs us nothing: the hybrid recogniser already produces two
// transcripts of the same clip — the streaming preview and the offline
// re-decode. Two decoders of the same family disagree most where the audio was
// hardest; where they agree, the audio was easy and what is left is casing and
// punctuation, which does not need an LLM.
//
// Pure: no I/O, no plugins, no singletons. Every threshold below is a starting
// point to be tuned from the decision log, not a measured optimum.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Normalised word-level edit distance at or above which the two decoders are
/// considered to disagree enough to be worth an LLM pass.
///
/// Starting point, not measured. The two models are siblings (both zipformer,
/// both 2023-06-26) measured at 11.19% and 16.26% WER on our channel, so a
/// quarter of the words differing is well outside their routine disagreement.
/// Tune from the `[TidyGate]` log lines once real wear has accumulated.
const double kDisagreementFloor = 0.25;

/// Below this many words per second of speech, assume the recogniser struggled.
///
/// Starting point, not measured. Conversational English runs ~2.5–3 words per
/// second; a clip that yielded far less text than its speech duration implies
/// either dropped content or a channel the model could not follow. Used only
/// when no streaming preview exists for the clip.
const double kLowWordsPerSecond = 1.8;

/// Below this many words there is nothing for a tidy pass to repair from
/// context, and the downside (an LLM inventing an opening) dominates.
const int kMinWordsForTidy = 4;

/// Why the gate decided what it decided. The `reason` is a short stable token
/// so the log lines can be grepped and counted.
@immutable
class TidyDecision {
  const TidyDecision(this.run, this.reason, this.score);

  /// True when the tidy pass should run.
  final bool run;

  /// Which signal decided, e.g. `disagreement`, `words-per-second`.
  final String reason;

  /// The signal's value — the normalised edit distance, or the words per
  /// second. 0 when no signal was available.
  final double score;

  @override
  String toString() => 'run=$run reason=$reason score=${score.toStringAsFixed(3)}';
}

class TidyGate {
  const TidyGate._();

  /// Decide whether [text] — the saved offline transcript — is worth tidying.
  ///
  /// [preview] is the streaming model's text for the SAME audio, when the live
  /// model is installed and the preview covers the whole clip. Callers must
  /// pass null when the preview covers more audio than [text] does (a
  /// multi-speaker clip, where each speaker's segment is logged separately) —
  /// comparing a whole-clip preview against one segment measures the split,
  /// not the difficulty.
  ///
  /// [speechSeconds] is the duration of speech behind [text]; 0 when unknown.
  static TidyDecision decide({
    required String text,
    String? preview,
    double speechSeconds = 0,
  }) {
    final words = _words(text);
    if (words.length < kMinWordsForTidy) {
      return TidyDecision(false, 'too-short', words.length.toDouble());
    }

    // (a) Preferred signal: the two decoders disagreeing.
    final p = preview?.trim() ?? '';
    if (p.isNotEmpty) {
      final d = normalizedEditDistance(p, text);
      return TidyDecision(d >= kDisagreementFloor, 'disagreement', d);
    }

    // (b) Fallback: how much text the clip yielded per second of speech.
    if (speechSeconds > 0) {
      final wps = words.length / speechSeconds;
      return TidyDecision(wps < kLowWordsPerSecond, 'words-per-second', wps);
    }

    // Neither signal available. Skip rather than spend seconds on a guess.
    return const TidyDecision(false, 'no-signal', 0);
  }

  /// Word-level Levenshtein distance between [a] and [b], divided by the
  /// longer word count. 0 means identical, 1 means nothing in common.
  ///
  /// Word level, not character level, because a character-level distance is
  /// dominated by the very thing a tidy pass is supposed to fix: the offline
  /// transcript is ALL CAPS with no punctuation. Both sides are flattened to
  /// lowercase alphanumerics first for the same reason — casing and
  /// punctuation differences are not decoder disagreement.
  static double normalizedEditDistance(String a, String b) {
    final x = _words(a);
    final y = _words(b);
    if (x.isEmpty && y.isEmpty) return 0;
    final longest = math.max(x.length, y.length);
    if (longest == 0) return 0;
    return _levenshtein(x, y) / longest;
  }

  static List<String> _words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);

  /// Two-row Levenshtein — O(min) memory, which matters because this runs on
  /// the capture path for clips that can be a couple of hundred words.
  static int _levenshtein(List<String> a, List<String> b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i, growable: false);
    var cur = List<int>.filled(b.length + 1, 0, growable: false);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final swap = prev;
      prev = cur;
      cur = swap;
    }
    return prev[b.length];
  }
}
