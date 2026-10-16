/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/services/vocabulary_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('normalize', () {
    test('trims and collapses all whitespace, newlines included', () {
      expect(VocabularyStore.normalize('  LiteRT  '), 'LiteRT');
      expect(VocabularyStore.normalize('AI\n\tEdge'), 'AI Edge');
      expect(VocabularyStore.normalize('AI   Edge'), 'AI Edge');
    });

    test('blank input normalizes to empty', () {
      expect(VocabularyStore.normalize('   \n '), '');
      expect(VocabularyStore.normalize(''), '');
    });

    test('clamps to maxWordLength', () {
      final long = 'x' * (VocabularyStore.maxWordLength + 40);
      expect(VocabularyStore.normalize(long).length, VocabularyStore.maxWordLength);
    });
  });

  group('decode', () {
    test('null / empty / garbage yield an empty dictionary', () {
      expect(VocabularyStore.decode(null), isEmpty);
      expect(VocabularyStore.decode(''), isEmpty);
      expect(VocabularyStore.decode('not json at all'), isEmpty);
      expect(VocabularyStore.decode('{"w":"solo"}'), isEmpty); // object, not list
    });

    test('drops malformed members but keeps the good ones', () {
      final entries = VocabularyStore.decode(
        '[{"w":"LiteRT","c":"Projects"},42,{"w":"   "},{"nope":1},{"w":"Jianing"}]',
      );
      expect(entries.map((e) => e.word), ['LiteRT', 'Jianing']);
      expect(entries.first.category, 'Projects');
      expect(entries.last.category, isNull);
    });

    test('unknown categories are dropped, not persisted as-is', () {
      final entries = VocabularyStore.decode('[{"w":"LiteRT","c":"Nonsense"}]');
      expect(entries.single.category, isNull);
    });
  });

  group('CRUD', () {
    test('starts empty', () async {
      expect(await VocabularyStore.entries(), isEmpty);
      expect(await VocabularyStore.promptWords(), isEmpty);
    });

    test('add persists word and category, in insertion order', () async {
      expect(await VocabularyStore.add('LiteRT', category: 'Projects'), isTrue);
      expect(await VocabularyStore.add('Jianing', category: 'Coworkers'), isTrue);
      expect(await VocabularyStore.promptWords(), ['LiteRT', 'Jianing']);
      final entries = await VocabularyStore.entries();
      expect(entries.first, const VocabularyEntry(word: 'LiteRT', category: 'Projects'));
      expect(entries.last, const VocabularyEntry(word: 'Jianing', category: 'Coworkers'));
    });

    test('add rejects blanks and case-insensitive duplicates', () async {
      expect(await VocabularyStore.add('   '), isFalse);
      expect(await VocabularyStore.add('MediaPipe'), isTrue);
      expect(await VocabularyStore.add('mediapipe'), isFalse);
      expect(await VocabularyStore.add(' MediaPipe '), isFalse);
      expect(await VocabularyStore.promptWords(), ['MediaPipe']);
    });

    test('add ignores an unknown category rather than storing it', () async {
      await VocabularyStore.add('LoRA', category: 'Nonsense');
      expect((await VocabularyStore.entries()).single.category, isNull);
    });

    test('remove is case-insensitive and leaves the rest alone', () async {
      await VocabularyStore.add('AI Edge', category: 'Projects');
      await VocabularyStore.add('LiteRT');
      await VocabularyStore.remove('ai edge');
      expect(await VocabularyStore.promptWords(), ['LiteRT']);
    });

    test('removing an absent word is a no-op', () async {
      await VocabularyStore.add('LiteRT');
      await VocabularyStore.remove('Gemma');
      expect(await VocabularyStore.promptWords(), ['LiteRT']);
    });

    test('survives a round trip through storage', () async {
      await VocabularyStore.add('Jingtao', category: 'Coworkers');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(VocabularyStore.storageKey);
      expect(VocabularyStore.decode(raw), [
        const VocabularyEntry(word: 'Jingtao', category: 'Coworkers'),
      ]);
    });
  });
}
