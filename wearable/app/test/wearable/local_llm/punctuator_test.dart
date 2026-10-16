// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for Punctuator's guard and its pass-through behaviour.
//
// The model itself is not exercised here — it is a 7 MB download that no test
// may depend on. What is exercised is everything that decides whether the
// model's output is allowed to replace a saved transcript, plus the rule that
// matters most: when the model is absent or broken, the transcript survives.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/punctuator.dart';

void main() {
  group('preservesWords', () {
    test('accepts a rewrite that only recases and punctuates', () {
      // The real measured output of the pinned model for this input.
      expect(
        preservesWords(
          'HELLO WORLD HOW ARE YOU TODAY I AM FINE THANK YOU',
          'Hello World, how are you today? I am fine. Thank you.',
        ),
        isTrue,
      );
    });

    test('accepts the recogniser mishearings passing through unchanged', () {
      // Punctuation is not spelling repair — `needer` and `diarin` must survive
      // untouched. Fixing those is Gemma's job, and Gemma is gated.
      expect(
        preservesWords(
          'JEST LOOKIN SEE IF I NEEDER HAD A DIARIN',
          'Jest lookin, see if I needer had a diarin',
        ),
        isTrue,
      );
    });

    test('rejects an added word', () {
      expect(
        preservesWords('CALL SARAH ON MONDAY', 'Call Sarah on Monday, please.'),
        isFalse,
      );
    });

    test('rejects a dropped word', () {
      expect(preservesWords('CALL SARAH ON MONDAY', 'Call Sarah Monday.'), isFalse);
    });

    test('rejects a changed word', () {
      expect(preservesWords('CALL SARAH ON MONDAY', 'Call Sarah on Tuesday.'), isFalse);
    });

    test('is indifferent to whitespace and hyphenation runs', () {
      expect(preservesWords('TWENTY  FIVE', 'Twenty-five'), isTrue);
    });

    test('keeps digits significant', () {
      expect(preservesWords('CALL AT 5', 'Call at 6.'), isFalse);
      expect(preservesWords('CALL AT 5', 'Call at 5.'), isTrue);
    });
  });

  group('restore', () {
    test('returns empty and whitespace-only input untouched', () async {
      expect(await Punctuator.instance.restore(''), '');
      expect(await Punctuator.instance.restore('   '), '   ');
    });

    test('returns the input unchanged when the model cannot be reached',
        () async {
      // No path_provider platform channel in a unit test, so isInstalled()
      // throws MissingPluginException. That is the same shape as a missing
      // model, a corrupt file, or a native load failure on a real device, and
      // the required behaviour is identical in all four: hand back the
      // transcript. A note that reads badly beats a note that is gone.
      const raw = 'JEST LOOKIN SEE IF I NEEDER HAD A DIARIN';
      expect(await Punctuator.instance.restore(raw, audioMs: 3000), raw);
    });

    test('serialises overlapping calls without losing any of them', () async {
      final results = await Future.wait([
        Punctuator.instance.restore('ONE'),
        Punctuator.instance.restore('TWO'),
        Punctuator.instance.restore('THREE'),
      ]);
      expect(results, ['ONE', 'TWO', 'THREE']);
    });
  });
}
