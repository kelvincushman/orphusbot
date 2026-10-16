// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Layout regression: screens must not overflow on a small phone with the
// on-screen keyboard up. The dictionary page used to overflow by up to 198 px
// at 320x568 — a fixed header (blurb, tabs, add row, category row) over one
// Expanded list, in less height than the header alone needs.
//
// A layout overflow surfaces as an exception during pump, so the assertion is
// simply that nothing was thrown.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/pages/wearable_dictionary_page.dart';
import 'package:kelvinlee/wearable/services/vocabulary_store.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _size(WidgetTester t, double w, double h, {double keyboard = 0}) {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = Size(w, h);
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  t.view.padding = const FakeViewPadding(top: 44, bottom: 34);
  addTearDown(t.view.reset);
}

void main() {
  // 375x812 is the iPhone X class; 320x568 is the smallest phone still shipped
  // with a modern OS and the one the failure needed. 291 and 336 are the two
  // common Android keyboard heights.
  const sizes = <String, List<double>>{
    '375x812': [375, 812],
    '320x568': [320, 568],
  };

  group('dictionary page does not overflow', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    for (final entry in sizes.entries) {
      for (final keyboard in const <double>[0, 291, 336]) {
        testWidgets('${entry.key}, keyboard ${keyboard.toInt()}px', (t) async {
          _size(t, entry.value[0], entry.value[1], keyboard: keyboard);
          for (final w in <String>['LiteRT', 'MediaPipe', 'Gemma', 'Kelvin', 'Zephyr']) {
            await VocabularyStore.add(w);
          }
          await t.pumpWidget(MaterialApp(
            theme: WearableTheme.light(),
            home: const WearableDictionaryPage(),
          ));
          await t.pump(const Duration(milliseconds: 50));
          expect(t.takeException(), isNull);
        });
      }
    }
  });
}
