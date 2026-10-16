// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Unit tests for normalizeGain() and sanitizeTranscript() pure helpers.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/audio_buffer.dart'
    show UtteranceBuffer, normalizeGain, pcmRms;
import 'package:kelvinlee/wearable/local_llm/gemma_transcriber.dart' show sanitizeTranscript;

void main() {
  // -------------------------------------------------------------------------
  // normalizeGain
  // -------------------------------------------------------------------------
  group('normalizeGain', () {
    test('quiet buffer is boosted toward target peak (gain < maxGain)', () {
      // Peak = 15000 — quiet but not extreme, gain ≈ 21299/15000 ≈ 1.42 (< 20 clamp).
      // After normalization the peak should be at or near targetPeak ≈ 21299.
      final samples = Int16List.fromList([15000, -15000, 10000, -8000]);
      final out = normalizeGain(samples);

      var peak = 0;
      for (final s in out) {
        final abs = s < 0 ? -s : s;
        if (abs > peak) peak = abs;
      }
      // With gain ≈ 1.42, output peak ≈ 21300, within ±100 of targetPeak.
      expect(peak, greaterThanOrEqualTo(21000));
      expect(peak, lessThanOrEqualTo(32767));
    });

    test('very quiet buffer (peak=200) is amplified by clamped maxGain', () {
      // Peak = 200 → raw gain = 21299/200 ≈ 106, clamped to maxGain=20.
      // Output peak = 200 × 20 = 4000.
      final samples = Int16List.fromList([0, 100, -200, 150, -50]);
      final out = normalizeGain(samples, maxGain: 20.0);

      var peak = 0;
      for (final s in out) {
        final abs = s < 0 ? -s : s;
        if (abs > peak) peak = abs;
      }
      // Peak is boosted by maxGain (20×) from the original peak of 200.
      expect(peak, closeTo(200 * 20, 2)); // ≈ 4000
    });

    test('gain is clamped to maxGain so pure-noise is not over-amplified', () {
      // Peak = 1 → raw gain = 21299/1 = 21299×, but clamped to maxGain=20.
      // Expected peak ≈ 1 × 20 = 20 (not 21299).
      final samples = Int16List.fromList([0, 1, -1, 0]);
      final out = normalizeGain(samples, maxGain: 20.0);

      var peak = 0;
      for (final s in out) {
        final abs = s < 0 ? -s : s;
        if (abs > peak) peak = abs;
      }
      // With gain=20 and input peak=1, output peak ≤ 20.
      expect(peak, lessThanOrEqualTo(20));
    });

    test('samples are clipped to int16 range after gain — no overflow', () {
      // Input peak = 16384, target = 0.65×32767 ≈ 21299.
      // Gain ≈ 1.3 → 16384 × 1.3 ≈ 21299; should not exceed 32767.
      final samples = Int16List.fromList([16384, -16384]);
      final out = normalizeGain(samples);
      for (final s in out) {
        expect(s, greaterThanOrEqualTo(-32768));
        expect(s, lessThanOrEqualTo(32767));
      }
    });

    test('returns new list — does not mutate input', () {
      final input = Int16List.fromList([100, 200, -100]);
      final original = Int16List.fromList(input);
      normalizeGain(input);
      for (var i = 0; i < input.length; i++) {
        expect(input[i], original[i]);
      }
    });

    test('loud buffer (already at target) has gain ≈ 1 and is returned as-is copy', () {
      // Peak = 21300 ≥ targetPeak ≈ 21299 → gain = 1.0 → no-op copy.
      final samples = Int16List.fromList([21300, -21300, 10000]);
      final out = normalizeGain(samples);
      // Values should be unchanged (gain clamped at 1.0 minimum).
      expect(out[0], 21300);
      expect(out[1], -21300);
    });

    test('empty input returns same empty list', () {
      final out = normalizeGain(Int16List(0));
      expect(out.isEmpty, isTrue);
    });

    test('all-zero (pure silence) returns unchanged samples', () {
      final samples = Int16List.fromList([0, 0, 0]);
      final out = normalizeGain(samples);
      expect(out.every((s) => s == 0), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // sanitizeTranscript
  // -------------------------------------------------------------------------
  group('sanitizeTranscript', () {
    test('real transcript passes through unchanged', () {
      expect(sanitizeTranscript('Hello, how are you?'), 'Hello, how are you?');
    });

    test('trims whitespace around real text', () {
      expect(sanitizeTranscript('  Good morning.  '), 'Good morning.');
    });

    test('empty string returns empty', () {
      expect(sanitizeTranscript(''), '');
    });

    test('whitespace-only returns empty', () {
      expect(sanitizeTranscript('   '), '');
    });

    test('[no speech] (exact) returns empty', () {
      expect(sanitizeTranscript('[no speech]'), '');
    });

    test('[no speech] with surrounding whitespace returns empty', () {
      expect(sanitizeTranscript('  [no speech]  '), '');
    });

    test('prompt-echo "verbatim speech transcriber" → empty', () {
      expect(
        sanitizeTranscript(
          'You are a verbatim speech transcriber. Transcribe the attached...',
        ),
        '',
      );
    });

    test('chatbot phrase "you have not attached" → empty', () {
      expect(
        sanitizeTranscript(
          "I'm sorry, you have not attached an audio file. Please provide...",
        ),
        '',
      );
    });

    test('chatbot phrase "please provide the audio" → empty', () {
      expect(sanitizeTranscript('Please provide the audio file.'), '');
    });

    test('chatbot phrase "i\'m able to help" → empty', () {
      expect(sanitizeTranscript("I'm able to help with many tasks."), '');
    });

    test('chatbot phrase "i cannot transcribe" → empty', () {
      expect(sanitizeTranscript('I cannot transcribe this audio.'), '');
    });

    test('chatbot phrase "no audio file" → empty', () {
      expect(sanitizeTranscript('There is no audio file attached.'), '');
    });

    test('chatbot phrase "attached audio to text" → empty', () {
      expect(
        sanitizeTranscript('I will transcribe the attached audio to text for you.'),
        '',
      );
    });

    test('detection is case-insensitive', () {
      expect(sanitizeTranscript('YOU HAVE NOT ATTACHED AN AUDIO FILE.'), '');
      expect(sanitizeTranscript('I CANNOT TRANSCRIBE'), '');
    });

    test('ghost token "OK" as the whole transcript → empty', () {
      // 'ok'/'okay' are in _kGhostTokens: a lone "OK" from the wearable mic
      // is a Gemma silence/ambient hallucination, not the wearer speaking.
      expect(sanitizeTranscript('OK'), '');
    });

    test('short real word not matching any phrase passes through', () {
      expect(sanitizeTranscript('Stop'), 'Stop');
    });
  });

  // -------------------------------------------------------------------------
  // pcmRms
  // -------------------------------------------------------------------------
  group('pcmRms', () {
    test('empty returns 0', () {
      expect(pcmRms(Int16List(0)), 0.0);
    });

    test('constant amplitude yields that amplitude', () {
      // All samples = 1000 → RMS = 1000.
      final s = Int16List.fromList(List.filled(100, 1000));
      expect(pcmRms(s), closeTo(1000.0, 0.01));
    });
  });

  group('captureGain vs vadPreGain', () {
    // Phone-mic audio arrives at conversational level. It used to share the 8x
    // VAD lift, which railed a large fraction of every dictation and handed
    // Gemma a square wave.
    Int16List speech(int n, int amp) {
      final out = Int16List(n);
      for (var i = 0; i < n; i++) {
        out[i] = (amp * math.sin(2 * math.pi * 220 * i / 16000)).round();
      }
      return out;
    }

    int railed(Int16List s) =>
        s.where((v) => v >= 32767 || v <= -32768).length;

    test('default keeps conversational phone-mic audio undistorted', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add);
      buf.addContinuous(speech(16000, 9000)); // ordinary speaking level
      buf.flushPending();
      expect(emitted, hasLength(1));
      expect(railed(emitted.single), 0, reason: 'nothing may clip at captureGain 1.0');
      expect(emitted.single.reduce(math.max), closeTo(9000, 50));
    });

    test('the old shared-gain behaviour would have railed a quarter of it', () {
      final emitted = <Int16List>[];
      // captureGain 8.0 reproduces what every phone dictation used to get.
      final buf = UtteranceBuffer(onUtterance: emitted.add, captureGain: 8.0);
      buf.addContinuous(speech(16000, 9000));
      buf.flushPending();
      expect(railed(emitted.single) / emitted.single.length, greaterThan(0.2));
    });

    test('quiet wearable audio still gets its lift when asked for', () {
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add, captureGain: 8.0);
      buf.addContinuous(speech(16000, 300)); // raw RMS ~200, wearable level
      buf.flushPending();
      expect(emitted.single.reduce(math.max), closeTo(2400, 50));
      expect(railed(emitted.single), 0);
    });

    test('the VAD still decides on the lifted signal, not the stored one', () {
      // Quiet speech must not read as silence just because captureGain is 1.0.
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add);
      buf.addContinuous(speech(16000, 300));
      buf.addContinuous(Int16List(16000 * 2)); // two seconds of true silence
      expect(emitted, hasLength(1), reason: 'quiet speech then silence = one utterance');
      expect(emitted.single.reduce(math.max), closeTo(300, 5),
          reason: 'stored at unity gain');
    });

    test('button windows stay raw even when captureGain is set', () {
      // _transcribeSamples' silence gate is tuned for raw button-window PCM.
      // Lifting the window would put room silence above the threshold and send
      // it to Gemma, which then answers instead of transcribing.
      final emitted = <Int16List>[];
      final buf = UtteranceBuffer(onUtterance: emitted.add, captureGain: 8.0, preRollMs: 0);
      buf.openWindow();
      buf.addWindowed(speech(8000, 300));
      buf.closeWindow();
      expect(emitted.single.reduce(math.max), closeTo(300, 5));
    });
  });
}
