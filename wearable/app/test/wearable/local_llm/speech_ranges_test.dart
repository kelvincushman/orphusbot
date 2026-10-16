// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for ZipformerTranscriber.joinSpeechRanges — the function that decides
// which audio the recogniser sees. A wrong range here decodes the wrong audio
// silently: no crash, no log, just a worse transcript.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/zipformer_transcriber.dart';

/// A ramp: value == index, so output content identifies the source offsets.
Int16List _ramp(int n) => Int16List.fromList(List<int>.generate(n, (i) => i));

void main() {
  const join = ZipformerTranscriber.joinSpeechRanges;

  test('empty ranges or empty source give an empty result', () {
    expect(join(_ramp(100), const [], pad: 5).length, 0);
    expect(join(Int16List(0), const [(0, 10)], pad: 5).length, 0);
  });

  test('a single range is padded on both sides', () {
    final out = join(_ramp(100), const [(40, 50)], pad: 5);
    expect(out.length, 20);
    expect(out.first, 35);
    expect(out.last, 54);
  });

  test('padding is clamped at the clip edges', () {
    final out = join(_ramp(100), const [(2, 10), (90, 99)], pad: 5);
    // [0,15) and [85,100)
    expect(out.length, 15 + 15);
    expect(out.first, 0);
    expect(out[14], 14);
    expect(out[15], 85);
    expect(out.last, 99);
  });

  test('touching or overlapping padded ranges merge without duplicating audio', () {
    // [10,20) and [25,35) with pad 5 -> [5,25) and [20,40) overlap -> [5,40)
    final out = join(_ramp(100), const [(10, 20), (25, 35)], pad: 5);
    expect(out.length, 35);
    for (var i = 0; i < out.length; i++) {
      expect(out[i], 5 + i, reason: 'sample $i duplicated or skipped');
    }
  });

  test('disjoint ranges stay disjoint and keep order', () {
    final out = join(_ramp(200), const [(100, 110), (20, 30)], pad: 2);
    // sorted: [18,32) then [98,112)
    expect(out.length, 14 + 14);
    expect(out.first, 18);
    expect(out[13], 31);
    expect(out[14], 98);
    expect(out.last, 111);
  });

  test('zero pad returns exactly the ranges', () {
    final out = join(_ramp(50), const [(5, 8)], pad: 0);
    expect(out, orderedEquals([5, 6, 7]));
  });

  test('the whole-window noise is excluded: 4 s of speech in 20 s decodes ~4.6 s', () {
    const rate = 16000;
    final src = _ramp(20 * rate);
    // Three segments totalling 4.2 s, 300 ms pad each side.
    // 1 s + 2 s + 1.2 s = 4.2 s of speech.
    final out = join(src, const [(2 * rate, 3 * rate), (8 * rate, 10 * rate), (15 * rate, (16.2 * rate) ~/ 1)], pad: 4800);
    final decodedS = out.length / rate;
    expect(decodedS, closeTo(4.2 + 3 * 0.6, 0.01));
    expect(decodedS, lessThan(6.5), reason: 'most of the window must be excluded');
  });
}
