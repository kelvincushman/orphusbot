/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */
//
// buildTranscriptionPrompt() — the personal dictionary's only contact with the
// transcription path. The empty case is pinned byte-for-byte against the prompt
// that shipped before the dictionary existed, so a future edit to the base
// instruction has to be deliberate.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/gemma_transcriber.dart'
    show buildTranscriptionPrompt;
import 'package:kelvinlee/wearable/services/vocabulary_store.dart';

const String _basePrompt =
    'You are a verbatim speech transcriber. Transcribe the attached audio to '
    'text in the original spoken language. Lightly clean the result: fix '
    'obvious disfluencies (um, uh, false starts, repeated words) and add '
    'natural punctuation and capitalization. Do NOT summarize, translate, '
    'answer questions, add commentary, or invent words that were not spoken. '
    'If the audio contains no intelligible speech, output exactly: [no speech]. '
    'Output only the transcript text and nothing else.';

void main() {
  group('empty dictionary', () {
    test('is a strict no-op — byte-identical to the pre-dictionary prompt', () {
      expect(buildTranscriptionPrompt(const []), _basePrompt);
    });

    test('mentions no vocabulary at all', () {
      expect(buildTranscriptionPrompt(const []), isNot(contains('names and terms')));
    });
  });

  group('short dictionary', () {
    final prompt = buildTranscriptionPrompt(const ['AI Edge', 'LiteRT', 'Jianing']);

    test('lists every word, comma separated', () {
      expect(prompt, contains('The speaker often uses these names and terms: '
          'AI Edge, LiteRT, Jianing.'));
    });

    test('frames the list as spelling, not as words to produce', () {
      expect(prompt, contains('spell it exactly as written here'));
      expect(prompt, contains('spelling guide only'));
    });

    test('keeps both no-invention rules — the original and the list-specific one', () {
      expect(prompt, contains('invent words that were not spoken'));
      expect(prompt, contains('never output a word from it that you did not hear'));
    });

    test('keeps the base instruction and the output-format rules intact', () {
      expect(prompt, startsWith('You are a verbatim speech transcriber.'));
      expect(prompt, contains('output exactly: [no speech]'));
      expect(prompt, endsWith('Output only the transcript text and nothing else.'));
    });

    test('the list sits between the constraints and the output-format rules', () {
      expect(
        prompt.indexOf('names and terms'),
        greaterThan(prompt.indexOf('invent words that were not spoken')),
      );
      expect(
        prompt.indexOf('names and terms'),
        lessThan(prompt.indexOf('[no speech]')),
      );
    });
  });

  group('over-cap dictionary', () {
    // 100 words, oldest first — the order promptWords() returns.
    final many = List<String>.generate(100, (i) => 'w$i');
    final prompt = buildTranscriptionPrompt(many);

    test('sends exactly promptCap words', () {
      final list = RegExp(r'names and terms: (.+?)\. When you hear')
          .firstMatch(prompt)!
          .group(1)!;
      expect(list.split(', ').length, VocabularyStore.promptCap);
    });

    test('keeps the newest words and drops the oldest', () {
      expect(prompt, contains('w99'));
      expect(prompt, contains('w${100 - VocabularyStore.promptCap}'));
      expect(prompt, isNot(contains('w0,')));
      expect(prompt, isNot(contains('w${100 - VocabularyStore.promptCap - 1},')));
    });

    test('a dictionary exactly at the cap is untouched', () {
      final exact = List<String>.generate(VocabularyStore.promptCap, (i) => 'x$i');
      final p = buildTranscriptionPrompt(exact);
      expect(p, contains('x0, x1,'));
      expect(p, contains('x${VocabularyStore.promptCap - 1}.'));
    });
  });
}
