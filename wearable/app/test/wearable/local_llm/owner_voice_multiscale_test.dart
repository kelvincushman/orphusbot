// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for the multi-scale chunked embedding helpers in OwnerVoice.
//
// Both are pure and both are load-bearing: a stride bug in windows() silently
// embeds the wrong audio (no crash, no log, just a worse speaker match), and a
// weighting bug in weightedMean() quietly biases every identity decision. They
// need native sherpa for nothing, so they are cheap to cover properly.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/owner_voice.dart';

/// A ramp, so a window's content identifies the offset it was cut from.
Float32List _ramp(int n) =>
    Float32List.fromList(List<double>.generate(n, (i) => i.toDouble()));

void main() {
  final ov = OwnerVoice.instance;
  const rate = 16000;

  group('windows()', () {
    test('empty when the clip cannot hold two windows', () {
      // 3 s clip, 2 s scale -> one window would just be the clip again.
      expect(ov.windows(_ramp(3 * rate), 2.0), isEmpty);
      expect(ov.windows(_ramp(rate), 2.0), isEmpty);
      expect(ov.windows(Float32List(0), 1.0), isEmpty);
    });

    test('rejects a non-positive scale rather than dividing by zero', () {
      expect(ov.windows(_ramp(5 * rate), 0.0), isEmpty);
      expect(ov.windows(_ramp(5 * rate), -1.0), isEmpty);
    });

    test('every window has exactly the requested length', () {
      for (final scale in [1.0, 2.0]) {
        for (final w in ov.windows(_ramp(10 * rate), scale)) {
          expect(w.length, (scale * rate).round());
        }
      }
    });

    test('caps at _maxChunksPerScale however long the clip is', () {
      // 600 s at 1 s would be 600 windows without the cap.
      expect(ov.windows(_ramp(600 * rate), 1.0).length, lessThanOrEqualTo(3));
      expect(ov.windows(_ramp(600 * rate), 2.0).length, lessThanOrEqualTo(3));
    });

    test('stays inside the clip — last window ends exactly at the end', () {
      final samples = _ramp(10 * rate);
      final ws = ov.windows(samples, 2.0);
      expect(ws, isNotEmpty);
      // The ramp means value == absolute sample index.
      for (final w in ws) {
        expect(w.first, greaterThanOrEqualTo(0));
        expect(w.last, lessThanOrEqualTo(samples.length - 1));
      }
      // Evenly spaced across the whole clip: the last one reaches the end.
      expect(ws.last.last, samples.length - 1);
      expect(ws.first.first, 0);
    });

    test('windows are distinct and ordered — not the same audio N times', () {
      final ws = ov.windows(_ramp(9 * rate), 1.0);
      expect(ws.length, 3);
      final starts = ws.map((w) => w.first).toList();
      expect(starts, orderedEquals([...starts]..sort()));
      expect(starts.toSet().length, starts.length, reason: 'duplicate windows');
    });

    test('a view reads the source audio, not the whole backing buffer', () {
      // Guards the sublistView contract: length is the view length and the
      // content is offset correctly.
      final ws = ov.windows(_ramp(4 * rate), 1.0); // 4 available, capped to 3
      expect(ws.length, 3);
      expect(ws[0].first, 0);
      // Each window starts strictly after the previous one.
      expect(ws[1].first, greaterThan(ws[0].first));
      expect(ws[2].first, greaterThan(ws[1].first));
      // Content is contiguous within a window — the ramp increments by one.
      expect(ws[1][100] - ws[1][0], 100);
      expect(ws[2].last - ws[2].first, rate - 1);
    });
  });

  group('weightedMean()', () {
    Float32List v(List<double> xs) => Float32List.fromList(xs);
    double norm(Float32List a) =>
        math.sqrt(a.fold<double>(0, (s, x) => s + x * x));

    test('empty input gives an empty vector', () {
      expect(ov.weightedMean(const [], const []).length, 0);
    });

    test('a single part passes through unchanged', () {
      final only = v([0.6, 0.8]);
      expect(ov.weightedMean([only], [3.0]), same(only));
    });

    test('result is a unit vector', () {
      final out = ov.weightedMean(
          [v([1, 0, 0]), v([0, 1, 0]), v([0, 0, 1])], [1.0, 1.0, 1.0]);
      expect(norm(out), closeTo(1.0, 1e-6));
    });

    test('equal weights on orthogonal units give the bisector', () {
      final out = ov.weightedMean([v([1, 0]), v([0, 1])], [1.0, 1.0]);
      final r = math.sqrt(0.5);
      expect(out[0], closeTo(r, 1e-6));
      expect(out[1], closeTo(r, 1e-6));
    });

    test('a heavier weight pulls the mean toward that vector', () {
      final out = ov.weightedMean([v([1, 0]), v([0, 1])], [3.0, 1.0]);
      expect(out[0], greaterThan(out[1]));
      // 3:1 before normalising -> atan(1/3).
      expect(math.atan2(out[1], out[0]), closeTo(math.atan2(1, 3), 1e-6));
      expect(norm(out), closeTo(1.0, 1e-6));
    });

    test('zero weight contributes nothing', () {
      final out = ov.weightedMean([v([1, 0]), v([0, 1])], [1.0, 0.0]);
      expect(out[0], closeTo(1.0, 1e-6));
      expect(out[1], closeTo(0.0, 1e-6));
    });

    test('a wrong-dimension part is skipped, not mixed in', () {
      final out = ov.weightedMean(
          [v([1, 0]), v([0, 1, 0]), v([1, 0])], [1.0, 99.0, 1.0]);
      expect(out.length, 2);
      expect(out[0], closeTo(1.0, 1e-6));
      expect(out[1], closeTo(0.0, 1e-6));
    });

    test('opposing unit vectors cancel to zero without throwing', () {
      final out = ov.weightedMean([v([1, 0]), v([-1, 0])], [1.0, 1.0]);
      expect(out.length, 2);
      expect(out[0], closeTo(0.0, 1e-6));
      expect(out[1], closeTo(0.0, 1e-6));
    });

    test('blending toward the whole clip cannot invert an identity', () {
      // The whole-clip term is always included, so a contaminated window can
      // move the result but must not flip it past a clean opposite.
      final clean = v([1, 0]);
      final contaminated = v([0, 1]);
      final out = ov.weightedMean([clean, contaminated], [10.0, 1.0]);
      expect(ov.cosineSimilarity(out, clean),
          greaterThan(ov.cosineSimilarity(out, contaminated)));
    });
  });
}
