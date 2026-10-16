// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/polish.dart';
import 'package:kelvinlee/wearable/services/vocabulary_store.dart';

/// Stand-in for the on-device model. Records the prompt it was handed and
/// returns whatever the test wants Gemma to have said.
class _FakeEngine {
  _FakeEngine(this.reply);

  /// Raw model output, or null to make generation throw.
  final String? reply;
  String? seenPrompt;
  int calls = 0;

  Future<String> generate(String prompt) async {
    calls++;
    seenPrompt = prompt;
    final r = reply;
    if (r == null) throw StateError('model unavailable');
    return r;
  }
}

const _transcript =
    'So um I mapped out the the proposed steps for the new vendor onboarding '
    'process, but uh I am worried it is a bit too heavy on the administrative '
    'side for the team to actually follow.';

void main() {
  group('polishPrompt', () {
    test('every tone carries the shared rules and the transcript', () {
      for (final tone in PolishTone.values) {
        final prompt = polishPrompt(tone, _transcript);
        expect(prompt, contains(kPolishRules), reason: '${tone.name} lost the rules');
        expect(prompt, contains('Transcript:\n$_transcript'));
      }
    });

    test('shared rules forbid answering, adding, and preambles', () {
      expect(kPolishRules, contains('never answer a question'));
      expect(kPolishRules, contains('never add information'));
      expect(kPolishRules, contains('title, preamble or explanation'));
      expect(kPolishRules, contains('same language as the transcript'));
    });

    test('each tone asks for something different', () {
      final instructions = {
        for (final tone in PolishTone.values)
          tone: polishPrompt(tone, '').replaceAll(kPolishRules, ''),
      };
      expect(instructions[PolishTone.polish], contains('clean written prose'));
      expect(instructions[PolishTone.polish], contains('false starts'));
      expect(instructions[PolishTone.keyPoints], contains('bullet list'));
      expect(instructions[PolishTone.formal], contains('formal, professional register'));
      expect(instructions[PolishTone.short], contains('as few words as possible'));
      expect(instructions[PolishTone.tidy], contains('speech-recognition transcript'));
      expect(instructions.values.toSet(), hasLength(PolishTone.values.length));
    });

    test('the chip row is the four hand-picked tones, in order', () {
      // tidy is in the enum but not in kPolishChips: it is the automatic pass,
      // and PolishTone.values driving the UI would have put it on screen as a
      // fifth chip the moment it was added.
      expect(kPolishChips.map((t) => t.label).toList(),
          ['Polish', 'Key points', 'Formal', 'Short']);
      expect(kPolishChips, isNot(contains(PolishTone.tidy)));
    });
  });

  group('sanitizePolish', () {
    // Regression: the refusal blocklist matched its phrases anywhere in the
    // rewritten text, so an ordinary dictated sentence containing "I can't" or
    // "Sorry, I" was treated as the model refusing. Polish silently fell back
    // and told the user the model had misbehaved. A refusal is only a refusal
    // when the MODEL introduced the phrase.
    test('keeps a rewrite whose refusal-shaped wording came from the wearer', () {
      const spoken = "sorry i cant make tuesday can we move it";
      const rewritten = "Sorry, I can't make Tuesday. Can we move it?";
      expect(sanitizePolish(rewritten, original: spoken), rewritten);
    });

    test('keeps other everyday phrasings the blocklist used to eat', () {
      for (final pair in <List<String>>[
        ['i cannot attend the review', 'I cannot attend the review.'],
        ["im unable to join the call", "I'm unable to join the call."],
        ['i am not able to get there by six', 'I am not able to get there by six.'],
      ]) {
        expect(sanitizePolish(pair[1], original: pair[0]), pair[1],
            reason: 'the wearer said it, so the rewrite may keep it: ${pair[0]}');
      }
    });

    test('still rejects a refusal the model introduced', () {
      // Nothing refusal-shaped in the transcript, so this is the model declining.
      expect(
        sanitizePolish("I'm sorry, I cannot help with that request.",
            original: 'remind me to order more coffee filters'),
        isNull,
      );
    });

    test('passes an ordinary rewrite through, trimmed', () {
      expect(
        sanitizePolish('  A clean sentence.  ', original: _transcript),
        'A clean sentence.',
      );
    });

    test('rejects empty and whitespace-only output', () {
      expect(sanitizePolish('', original: _transcript), isNull);
      expect(sanitizePolish('   \n  ', original: _transcript), isNull);
    });

    test('rejects a refusal', () {
      expect(sanitizePolish('I cannot rewrite that for you.', original: _transcript), isNull);
      expect(sanitizePolish('As an AI, I do not have opinions.', original: _transcript), isNull);
      expect(sanitizePolish("Sorry, I can't help with this.", original: _transcript), isNull);
    });

    test('rejects a prompt echo', () {
      expect(
        sanitizePolish(polishPrompt(PolishTone.polish, _transcript), original: _transcript),
        isNull,
      );
      expect(
        sanitizePolish('Output only the rewritten text and nothing else.', original: _transcript),
        isNull,
      );
    });

    test('rejects runaway expansion — the model answered instead of rewriting', () {
      final essay = List.filled(40, 'Here is some advice about vendor onboarding.').join(' ');
      expect(sanitizePolish(essay, original: _transcript), isNull);
    });

    test('allows expansion on a very short dictation (ratio floor)', () {
      final out = 'A' * 200;
      expect(sanitizePolish(out, original: 'call bob'), out);
    });

    test('strips a single meta preamble line', () {
      expect(
        sanitizePolish('Sure, here is the polished version:\nCall Bob at noon.',
            original: _transcript),
        'Call Bob at noon.',
      );
      expect(
        sanitizePolish("Here's the text:\nCall Bob at noon.", original: _transcript),
        'Call Bob at noon.',
      );
    });

    test('keeps a heading that is real content', () {
      expect(
        sanitizePolish('Agenda:\n- ship the build', original: _transcript),
        'Agenda:\n- ship the build',
      );
    });

    test('does not strip a preamble when nothing follows it', () {
      expect(sanitizePolish('Here is the result:', original: _transcript), 'Here is the result:');
    });

    test('strips a markdown code fence', () {
      expect(
        sanitizePolish('```\nCall Bob at noon.\n```', original: _transcript),
        'Call Bob at noon.',
      );
    });
  });

  group('polishTranscript', () {
    test('returns the rewrite and marks it polished', () async {
      final engine = _FakeEngine('I mapped out the proposed steps for vendor onboarding.');
      final result = await polishTranscript(_transcript, PolishTone.polish,
          generate: engine.generate);

      expect(result.polished, isTrue);
      expect(result.text, 'I mapped out the proposed steps for vendor onboarding.');
      expect(result.note, isNull);
      expect(engine.seenPrompt, polishPrompt(PolishTone.polish, _transcript));
    });

    test('sends the tone-specific prompt', () async {
      final engine = _FakeEngine('- too heavy on admin');
      await polishTranscript(_transcript, PolishTone.keyPoints, generate: engine.generate);
      expect(engine.seenPrompt, contains('bullet list'));
    });

    test('falls back to the original when the model throws', () async {
      final engine = _FakeEngine(null);
      final result = await polishTranscript(_transcript, PolishTone.formal,
          generate: engine.generate);

      expect(result.polished, isFalse);
      expect(result.text, _transcript);
      expect(result.note, contains('failed'));
    });

    test('falls back to the original when the model refuses', () async {
      final engine = _FakeEngine('I cannot help with that request.');
      final result = await polishTranscript(_transcript, PolishTone.short,
          generate: engine.generate);

      expect(result.polished, isFalse);
      expect(result.text, _transcript);
      expect(result.note, contains('looked wrong'));
    });

    test('falls back to the original when the model returns nothing', () async {
      final result = await polishTranscript(_transcript, PolishTone.polish,
          generate: _FakeEngine('').generate);

      expect(result.polished, isFalse);
      expect(result.text, _transcript);
    });

    test('does not call the model on a blank transcript', () async {
      final engine = _FakeEngine('anything');
      final result = await polishTranscript('   ', PolishTone.polish, generate: engine.generate);

      expect(engine.calls, 0);
      expect(result.polished, isFalse);
      expect(result.text, '   ');
    });

    test('serialises: a throwing call does not poison the lane', () async {
      final bad = await polishTranscript(_transcript, PolishTone.polish,
          generate: _FakeEngine(null).generate);
      final good = await polishTranscript(_transcript, PolishTone.polish,
          generate: _FakeEngine('Clean text.').generate);

      expect(bad.polished, isFalse);
      expect(good.polished, isTrue);
      expect(good.text, 'Clean text.');
    });

    test('serialises: concurrent calls run one at a time', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      Future<String> slow(String prompt) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return 'Clean text.';
      }

      await Future.wait([
        polishTranscript(_transcript, PolishTone.polish, generate: slow),
        polishTranscript(_transcript, PolishTone.short, generate: slow),
        polishTranscript(_transcript, PolishTone.formal, generate: slow),
      ]);

      expect(maxInFlight, 1);
    });
  });

  group('the personal dictionary survives the rewrite', () {
    // Transcription spells these the wearer's way; polish then rewrote the text
    // knowing nothing about them and re-spelled them on the last hop.
    test('the words reach the prompt', () {
      final prompt = polishPrompt(PolishTone.polish, 'we shipped litert today',
          vocabulary: const <String>['LiteRT', 'MediaPipe']);
      expect(prompt, contains('LiteRT, MediaPipe'));
      expect(prompt, contains('exactly as they appear'));
    });

    test('no clause at all when the dictionary is empty', () {
      expect(vocabularyClause(const <String>[]), isEmpty);
      expect(
        polishPrompt(PolishTone.polish, 'hello'),
        polishPrompt(PolishTone.polish, 'hello', vocabulary: const <String>[]),
      );
    });

    test('the clause is capped like the transcription prompt', () {
      final many = List<String>.generate(VocabularyStore.promptCap + 20, (i) => 'w$i');
      final clause = vocabularyClause(many);
      expect(clause, contains('w${many.length - 1}'), reason: 'keeps the newest');
      expect(clause, isNot(contains('w0, ')), reason: 'drops the oldest');
    });

    test('polishTranscript passes it through to the model', () async {
      String? seen;
      await polishTranscript('we shipped litert', PolishTone.polish,
          vocabulary: const <String>['LiteRT'],
          generate: (p) async {
            seen = p;
            return 'We shipped LiteRT.';
          });
      expect(seen, contains('LiteRT'));
    });
  });

  // -------------------------------------------------------------------------
  // The tidy tone — the only one that runs unattended, over text a wearer has
  // already read. LatentASR Table 13 is the specific failure being guarded
  // against: an AR model prepending "Thank you, Madame" to "Madame President".
  // -------------------------------------------------------------------------
  group('tidy tone', () {
    const heard = 'JEST LOOKIN SEE IF I NEEDER HAD A DIARIN FOR THE TEAM MEETING';

    test('the prompt forbids additions explicitly, not by implication', () {
      final prompt = polishPrompt(PolishTone.tidy, heard);
      expect(prompt, contains(kPolishRules));
      expect(prompt, contains(kTidyRules));
      expect(kTidyRules, contains('opening'));
      expect(kTidyRules, contains('greeting'));
      expect(kTidyRules, contains('Do not summarise'));
      expect(kTidyRules, contains('output the transcript unchanged'));
    });

    test('no other tone carries the tidy rules', () {
      for (final tone in kPolishChips) {
        expect(polishPrompt(tone, heard), isNot(contains(kTidyRules)),
            reason: '${tone.name} should not be constrained like tidy');
      }
    });

    test('tidyWordCeiling allows a split mishearing but not a sentence', () {
      // 10 words in: +10% is one word, which would reject "A DIARIN" ->
      // "a diary in". The floor of two extra words is what makes the repair
      // the pass exists for survive its own cap.
      expect(tidyWordCeiling(10), 12);
      expect(tidyWordCeiling(100), 110);
      expect(tidyWordCeiling(0), 2);
    });

    test('countWords ignores punctuation and case', () {
      expect(countWords('Just looking, to see if I need a diary.'), 9);
      expect(countWords('JUST LOOKING TO SEE IF I NEED A DIARY'), 9);
      expect(countWords('   '), 0);
    });

    test('a recase-and-punctuate rewrite passes the word cap', () {
      // 13 words in, 13 out. A tidy that needed to *restore* three dropped
      // function words would be rejected by the ceiling and the line would
      // stay as heard — deliberate: a pass nobody is watching gets the
      // conservative half of that trade.
      const rewrite = 'Just looking, see if I needed a diary in for the team meeting.';
      expect(
        sanitizePolish(rewrite,
            original: heard, maxWords: tidyWordCeiling(countWords(heard))),
        rewrite,
      );
    });

    test('a rewrite that invents an opening sentence is rejected', () {
      const invented =
          'Thank you, Madame President. Just looking to see if I need to have '
          'a diary in for the team meeting.';
      expect(
        sanitizePolish(invented,
            original: heard, maxWords: tidyWordCeiling(countWords(heard))),
        isNull,
      );
      // And the same text is fine for the tones a human is watching — the cap
      // is what makes tidy different, not the sanitiser.
      expect(sanitizePolish(invented, original: heard), isNotNull);
    });

    test('polishTranscript applies the cap only for the tidy tone', () async {
      const invented = 'Thank you very much indeed. Just looking to see if I '
          'need to have a diary in for the team meeting today.';
      final tidied = await polishTranscript(heard, PolishTone.tidy,
          generate: (_) async => invented);
      expect(tidied.polished, isFalse, reason: 'the added opening must be rejected');
      expect(tidied.text, heard);

      final polished = await polishTranscript(heard, PolishTone.polish,
          generate: (_) async => invented);
      expect(polished.polished, isTrue);
    });

    test('tidy accepts a clean recase end to end', () async {
      const clean = 'Just looking, see if I needed a diary in for the team meeting.';
      final r = await polishTranscript(heard, PolishTone.tidy, generate: (_) async => clean);
      expect(r.polished, isTrue);
      expect(r.text, clean);
    });
  });
}
