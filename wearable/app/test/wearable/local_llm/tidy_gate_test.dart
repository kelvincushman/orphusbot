// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// TidyGate is the whole reason the tidy pass is affordable, and it is pure,
// so it is tested directly rather than through a capture.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/tidy_gate.dart';

void main() {
  group('normalizedEditDistance', () {
    test('identical text is 0', () {
      expect(TidyGate.normalizedEditDistance('one two three', 'one two three'), 0);
    });

    test('casing and punctuation are not disagreement', () {
      // The offline transcript is ALL CAPS with no punctuation and the preview
      // is the same model family, so any difference of case or punctuation is
      // formatting, not two decoders disagreeing. If this ever counted, the
      // gate would fire on every single capture.
      expect(
        TidyGate.normalizedEditDistance(
            'JUST LOOKING TO SEE IF I NEED A DIARY', "Just looking, to see if I need a diary."),
        0,
      );
    });

    test('one substituted word in four is 0.25', () {
      expect(TidyGate.normalizedEditDistance('one two three four', 'one two tree four'), 0.25);
    });

    test('nothing in common is 1', () {
      expect(TidyGate.normalizedEditDistance('alpha bravo', 'charlie delta'), 1.0);
    });

    test('length difference counts — a dropped half is 0.5', () {
      expect(TidyGate.normalizedEditDistance('one two three four', 'one two'), 0.5);
    });

    test('two empties are 0, not a division by zero', () {
      expect(TidyGate.normalizedEditDistance('', '   ...  '), 0);
    });
  });

  group('decide — too short', () {
    test('fewer than kMinWordsForTidy words never runs', () {
      final d = TidyGate.decide(text: 'YES OKAY THANKS', preview: 'completely different words here');
      expect(d.run, isFalse);
      expect(d.reason, 'too-short');
    });
  });

  group('decide — disagreement (preferred signal)', () {
    const offline = 'JUST LOOKING TO SEE IF I NEED TO HAVE A DIARY ENTRY FOR THIS';

    test('close agreement skips the LLM', () {
      final d = TidyGate.decide(
        text: offline,
        preview: 'just looking to see if I need to have a diary entry for this',
      );
      expect(d.reason, 'disagreement');
      expect(d.score, lessThan(kDisagreementFloor));
      expect(d.run, isFalse);
    });

    test('wide disagreement runs the LLM', () {
      final d = TidyGate.decide(
        text: offline,
        preview: 'jest lookin see if i needer had a diarin for miss',
      );
      expect(d.reason, 'disagreement');
      expect(d.score, greaterThanOrEqualTo(kDisagreementFloor));
      expect(d.run, isTrue);
    });

    test('the floor is inclusive', () {
      // Four words, one substituted -> exactly 0.25.
      final d = TidyGate.decide(text: 'one two three four', preview: 'one two tree four');
      expect(d.score, kDisagreementFloor);
      expect(d.run, isTrue);
    });

    test('an empty preview is not a signal — falls through to the fallback', () {
      final d = TidyGate.decide(text: 'one two three four five', preview: '   ', speechSeconds: 10);
      expect(d.reason, 'words-per-second');
    });
  });

  group('decide — words per second (fallback)', () {
    test('a normal talking rate skips', () {
      // 10 words in 4 s = 2.5 wps, ordinary conversational English.
      final d = TidyGate.decide(
        text: 'one two three four five six seven eight nine ten',
        speechSeconds: 4,
      );
      expect(d.reason, 'words-per-second');
      expect(d.score, closeTo(2.5, 1e-9));
      expect(d.run, isFalse);
    });

    test('little text for a lot of speech runs', () {
      // 10 words in 20 s = 0.5 wps: the recogniser dropped most of the clip.
      final d = TidyGate.decide(
        text: 'one two three four five six seven eight nine ten',
        speechSeconds: 20,
      );
      expect(d.run, isTrue);
      expect(d.score, closeTo(0.5, 1e-9));
    });

    test('the preview wins when both signals are available', () {
      final d = TidyGate.decide(
        text: 'one two three four five six seven eight nine ten',
        preview: 'one two three four five six seven eight nine ten',
        speechSeconds: 20, // would have fired on its own
      );
      expect(d.reason, 'disagreement');
      expect(d.run, isFalse);
    });
  });

  group('decide — no signal', () {
    test('skips rather than guessing', () {
      final d = TidyGate.decide(text: 'one two three four five six');
      expect(d.run, isFalse);
      expect(d.reason, 'no-signal');
      expect(d.score, 0);
    });
  });

  test('toString is the shape the log line expects', () {
    expect(const TidyDecision(true, 'disagreement', 0.5).toString(),
        'run=true reason=disagreement score=0.500');
  });
}
