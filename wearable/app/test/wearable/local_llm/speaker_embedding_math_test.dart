// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// robustEmbedding() is the multi-scale pass schedule the worker isolate runs.
// It is pure over an embedOne callback, so its pass count and its fallbacks
// are asserted here without native sherpa. windows()/weightedMean() keep
// their own coverage in owner_voice_multiscale_test.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_embedding_math.dart';

Float32List _clip(double seconds) => Float32List((seconds * 16000).round());

void main() {
  test('a 6 s clip costs 1 + 3 + 3 = 7 passes, all with their window lengths', () {
    final seen = <int>[];
    final r = robustEmbedding(_clip(6), (c) {
      seen.add(c.length);
      return Float32List.fromList([1, 0]);
    });
    expect(r.passes, 7);
    expect(seen.first, 6 * 16000);
    expect(seen.where((n) => n == 2 * 16000).length, 3);
    expect(seen.where((n) => n == 16000).length, 3);
    expect(r.embedding, isNotNull);
    expect(r.embedding!.length, 2);
  });

  test('a 3 s clip cannot hold two 2 s windows: 1 + 0 + 3 = 4 passes', () {
    final r = robustEmbedding(_clip(3), (c) => Float32List.fromList([0, 1]));
    expect(r.passes, 4);
  });

  test('a clip too short for any window is a single whole-clip pass', () {
    var calls = 0;
    final r = robustEmbedding(_clip(1.5), (c) {
      calls++;
      return Float32List.fromList([0.6, 0.8]);
    });
    expect(calls, 1);
    expect(r.passes, 1);
    expect(r.embedding, [0.6, 0.8].map((x) => closeTo(x, 1e-6)));
  });

  test('null on the whole clip is null overall, with zero passes', () {
    var calls = 0;
    final r = robustEmbedding(_clip(6), (c) {
      calls++;
      return null;
    });
    expect(r.embedding, isNull);
    expect(r.passes, 0);
    expect(calls, 1, reason: 'no point windowing a clip that failed whole');
  });

  test('refused windows are skipped; the whole-clip vector stands alone', () {
    final r = robustEmbedding(_clip(6), (c) {
      if (c.length < 6 * 16000) return null; // every window refused
      return Float32List.fromList([0, 1]);
    });
    expect(r.passes, 1);
    expect(r.embedding![1], closeTo(1.0, 1e-6));
  });

  test('windows are duration-weighted: the whole clip dominates', () {
    // Whole clip says [1,0] with weight 6 s; six windows say [0,1] with
    // weights 2,2,2,1,1,1 = 9 s. Mean before normalising: [6, 9].
    final r = robustEmbedding(_clip(6), (c) {
      return c.length == 6 * 16000
          ? Float32List.fromList([1, 0])
          : Float32List.fromList([0, 1]);
    });
    final e = r.embedding!;
    expect(e[1] / e[0], closeTo(9 / 6, 1e-5));
  });
}
