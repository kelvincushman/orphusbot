// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/audio_buffer.dart';

Int16List _tone(int samples, {int amplitude = 8000}) {
  final out = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = (i.isEven ? amplitude : -amplitude);
  }
  return out;
}

/// Simulates quiet wearable speech: raw RMS ~300 (well below old threshold of
/// 600 but real speech). After 8× pre-gain this becomes ~2400, above the VAD
/// speech threshold of 1000.
Int16List _quietTone(int samples, {int amplitude = 300}) =>
    _tone(samples, amplitude: amplitude);

Int16List _silence(int samples) => Int16List(samples);

void main() {
  group('UtteranceBuffer button-window mode', () {
    test('emits once on close, and only on close', () {
      final emitted = <Int16List>[];
      // preRollMs: 0 isolates the windowing contract; the pre-roll that the
      // default buffer keeps is covered in its own group below.
      final buf = UtteranceBuffer(onUtterance: emitted.add, preRollMs: 0);

      buf.addWindowed(_tone(1000)); // dropped — window closed, no pre-roll
      expect(emitted, isEmpty);
      expect(buf.bufferedSamples, 0);

      buf.openWindow();
      buf.addWindowed(_tone(1600));
      buf.addWindowed(_tone(1600));
      expect(emitted, isEmpty); // nothing until close
      buf.closeWindow();

      expect(emitted, hasLength(1));
      expect(emitted.first.length, 3200);
    });

    test('button window emits even very short captures (no min gate)', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add);
      buf.openWindow();
      buf.addWindowed(_tone(100)); // < minUtteranceMs
      buf.closeWindow();
      expect(emitted, hasLength(1));
    });
  });

  group('UtteranceBuffer continuous/VAD mode', () {
    test('flushes after a run of trailing silence', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(
        onUtterance: emitted.add,
        sampleRate: 16000,
        silenceMs: 700,
      );
      // 1 s of speech, then >700 ms of silence → one utterance.
      buf.addContinuous(_tone(16000));
      expect(emitted, isEmpty);
      buf.addContinuous(_silence(8000)); // 500 ms silence
      expect(emitted, isEmpty);
      buf.addContinuous(_silence(4000)); // total 750 ms ≥ 700 ms → flush
      expect(emitted, hasLength(1));
      expect(emitted.first.length, 16000 + 8000 + 4000);
    });

    test('drops sub-minimum utterances as noise', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(
        onUtterance: emitted.add,
        silenceMs: 200, // 3200 samples @16k triggers a flush
        minUtteranceMs: 300, // 4800 samples @16k minimum to emit
      );
      // 400 speech + 3200 silence = 3600 total (< 4800 min) → flush but dropped.
      buf.addContinuous(_tone(400));
      buf.addContinuous(_silence(3200));
      expect(emitted, isEmpty);
    });
  });

  group('UtteranceBuffer quiet-audio VAD (wearable fix)', () {
    // These tests use the default constructor values (vadPreGain=8, silenceMs=1000,
    // silenceRmsThreshold=1000, minSpeechMs=800) that match real wearable audio.

    test('accumulates full phrase across brief intra-word gaps; flushes ONE utterance', () {
      // Simulates: 0.5s quiet speech → 300ms low-energy gap → 0.5s quiet speech
      // → 1s trailing silence. The VAD should NOT flush after the 300ms gap
      // (only 300ms < 1000ms silenceMs), and should emit exactly one utterance
      // containing both speech spans.
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add);

      // Speech span 1: 0.5 s of quiet speech (amplitude=300 → post-gain RMS ~2400)
      buf.addContinuous(_quietTone(8000));
      expect(emitted, isEmpty, reason: 'no flush during speech');

      // 300 ms low-energy gap (amplitude=50, post-gain RMS ~400 < 1000 = silence)
      buf.addContinuous(_tone(4800, amplitude: 50));
      expect(emitted, isEmpty, reason: '300ms gap < 1000ms silenceMs — no flush yet');

      // Speech span 2: 0.5 s of quiet speech
      buf.addContinuous(_quietTone(8000));
      expect(emitted, isEmpty, reason: 'speech resets silence counter; no flush');

      // 1 s trailing silence → triggers flush (1s >= silenceMs=1000ms)
      buf.addContinuous(_silence(16000));
      expect(emitted, hasLength(1), reason: 'exactly one utterance emitted');
      // The utterance contains all four spans (8000+4800+8000+16000 = 36800 samples)
      expect(emitted.first.length, 8000 + 4800 + 8000 + 16000);
    });

    test('pure-silence stream never flushes an utterance', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add);

      // Feed 2 s of silence in 320-sample chunks (20ms frames — typical Opus cadence)
      for (var i = 0; i < 100; i++) {
        buf.addContinuous(_silence(320));
      }
      expect(emitted, isEmpty, reason: 'silence-only buffer must not emit');
    });

    test('does not fragment a sentence into sub-1s slivers', () {
      // Regression: the old VAD (silenceThreshold=600, silenceMs=700) would
      // classify quiet speech (RMS~300) as silence immediately and flush 700ms
      // fragments. With the new VAD the same quiet speech must accumulate into
      // a single utterance.
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add);

      // 3 s of continuous quiet speech then 1.1 s silence.
      buf.addContinuous(_quietTone(48000)); // 3 s speech
      expect(emitted, isEmpty);
      buf.addContinuous(_silence(17600)); // 1.1 s silence → flush
      expect(emitted, hasLength(1), reason: 'one complete utterance, not fragments');
      expect(emitted.first.length, greaterThanOrEqualTo(48000));
    });
  });

  group('UtteranceBuffer 30 s hard cap', () {
    test('emits in 30 s slices when over the cap', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add, sampleRate: 16000, maxSeconds: 30);
      buf.openWindow();
      // 65 s of audio in one shot → two full 30 s slices, 5 s remains buffered.
      buf.addWindowed(_tone(16000 * 65));
      expect(emitted, hasLength(2));
      expect(emitted.every((u) => u.length == 16000 * 30), isTrue);
      expect(buf.bufferedSamples, 16000 * 5);
      buf.closeWindow();
      expect(emitted, hasLength(3));
      expect(emitted.last.length, 16000 * 5);
    });
  });

  group('capture pre-roll', () {
    // The firmware waits out a 750 ms multi-tap window before reporting a tap,
    // so without pre-roll the wearer loses whatever they said in the run-up and
    // learns "tap, wait, then talk".
    test('openWindow keeps the audio from just before the tap', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add, preRollMs: 1500);

      buf.addWindowed(Int16List.fromList(List<int>.filled(16000, 500))); // 1 s
      expect(buf.bufferedSamples, 0, reason: 'window is closed');
      expect(buf.preRollSamples, 16000);

      buf.openWindow();
      expect(buf.bufferedSamples, 16000, reason: 'seeded from the pre-roll');
      expect(buf.preRollSamples, 0, reason: 'ring handed over, not copied');

      buf.addWindowed(Int16List.fromList(List<int>.filled(8000, 500)));
      buf.closeWindow();
      expect(emitted.single.length, 24000);
    });

    test('the ring is bounded to preRollMs', () {
      final buf = UtteranceBuffer(onUtterance: (_) {}, preRollMs: 1500);
      for (var i = 0; i < 10; i++) {
        buf.addWindowed(Int16List.fromList(List<int>.filled(16000, 100)));
      }
      expect(buf.preRollSamples, 24000, reason: '1500 ms at 16 kHz');
    });

    test('preRollMs: 0 keeps nothing', () {
      final buf = UtteranceBuffer(onUtterance: (_) {}, preRollMs: 0);
      buf.addWindowed(Int16List.fromList(List<int>.filled(16000, 100)));
      expect(buf.preRollSamples, 0);
      buf.openWindow();
      expect(buf.bufferedSamples, 0);
    });

    test('reset drops the pre-roll', () {
      final buf = UtteranceBuffer(onUtterance: (_) {});
      buf.addWindowed(Int16List.fromList(List<int>.filled(16000, 100)));
      buf.reset();
      expect(buf.preRollSamples, 0);
    });
  });
}
