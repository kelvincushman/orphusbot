/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */
//
// Widget tests for the dictionary page. The page owns no plugins beyond
// SharedPreferences, so it pumps standalone — no provider tree needed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/pages/wearable_dictionary_page.dart';
import 'package:kelvinlee/wearable/services/vocabulary_store.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: WearableTheme.light(),
    home: const WearableDictionaryPage(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('empty dictionary shows the prompt to add words', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('No words yet'), findsOneWidget);
  });

  testWidgets('renders stored words with their collection chip', (tester) async {
    await VocabularyStore.add('LiteRT', category: 'Projects');
    await VocabularyStore.add('Jianing', category: 'Coworkers');
    await pumpPage(tester);

    expect(find.text('LiteRT'), findsOneWidget);
    expect(find.text('Jianing'), findsOneWidget);
    // 'Projects' also appears as a picker chip, so both tabs of it are expected.
    expect(find.text('Projects'), findsNWidgets(2));
  });

  testWidgets('typing a word and tapping + persists and lists it', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'MediaPipe');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('MediaPipe'), findsOneWidget);
    expect(await VocabularyStore.promptWords(), ['MediaPipe']);
  });

  testWidgets('selected collection is applied to the next added word', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Coworkers'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Mogan');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect((await VocabularyStore.entries()).single.category, 'Coworkers');
  });

  testWidgets('a duplicate is refused with a snackbar and not added twice', (tester) async {
    await VocabularyStore.add('LoRA');
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'lora');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.textContaining('already in your dictionary'), findsOneWidget);
    expect(await VocabularyStore.promptWords(), ['LoRA']);
  });

  testWidgets('the trash affordance removes the entry', (tester) async {
    await VocabularyStore.add('AI Edge');
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('AI Edge'), findsNothing);
    expect(await VocabularyStore.promptWords(), isEmpty);
  });

  testWidgets('words are listed alphabetically, not in insertion order', (tester) async {
    await VocabularyStore.add('Zephyr');
    await VocabularyStore.add('audio');
    await VocabularyStore.add('Gemma');
    await pumpPage(tester);

    final words = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d == 'Zephyr' || d == 'audio' || d == 'Gemma')
        .toList();
    expect(words, ['audio', 'Gemma', 'Zephyr']);
  });

  testWidgets('over-cap dictionary warns that only the newest words are sent', (tester) async {
    for (var i = 0; i <= VocabularyStore.promptCap; i++) {
      await VocabularyStore.add('word$i');
    }
    await pumpPage(tester);
    expect(find.textContaining('most recently added words are sent'), findsOneWidget);
  });

  testWidgets('an at-cap dictionary shows no warning', (tester) async {
    for (var i = 0; i < VocabularyStore.promptCap; i++) {
      await VocabularyStore.add('word$i');
    }
    await pumpPage(tester);
    expect(find.textContaining('most recently added words are sent'), findsNothing);
  });

  testWidgets('Collections tab groups entries under their collection', (tester) async {
    await VocabularyStore.add('LiteRT', category: 'Projects');
    await VocabularyStore.add('Jingtao', category: 'Coworkers');
    await VocabularyStore.add('LoRA');
    await pumpPage(tester);

    await tester.tap(find.text('Collections'));
    await tester.pumpAndSettle();

    expect(find.text('Coworkers  ·  1'), findsOneWidget);
    expect(find.text('No collection  ·  1'), findsOneWidget);
    expect(find.text('Projects  ·  1'), findsOneWidget);
  });
}
