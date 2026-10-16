// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Privacy Mode sits on the Capture card because it is the one capture setting
// with a consequence the wearer has to be able to reach in one gesture. These
// pin that it renders the stored state, says what it does in both positions,
// and writes back to the same key the rest of the app reads.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/transcription_mode.dart';
import 'package:kelvinlee/wearable/pages/device_status_page.dart';
import 'package:kelvinlee/wearable/providers/wearable_connection_provider.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app() => MaterialApp(
      theme: WearableTheme.light(),
      home: ChangeNotifierProvider<WearableConnectionProvider>(
        create: (_) => WearableConnectionProvider(),
        child: const DeviceStatusPage(),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('off by default, and says the room is being captured', (t) async {
    await t.pumpWidget(_app());
    await t.pumpAndSettle();

    expect(find.text('Privacy Mode'), findsOneWidget);
    expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(
      find.textContaining('Capturing continuously'),
      findsOneWidget,
      reason: 'the copy has to say what off means, not just name the setting',
    );
  });

  testWidgets('an install that had chosen Button comes up with it on', (t) async {
    // Written as the raw legacy enum value, not via setPrivacyMode — the point
    // is that an install predating Privacy Mode is read correctly.
    (await SharedPreferences.getInstance())
        .setString(TranscriptionSettings.segmentationKey, 'button');

    await t.pumpWidget(_app());
    await t.pumpAndSettle();

    expect(t.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('Everything else is discarded'), findsOneWidget);
  });

  testWidgets('toggling it on persists and updates the copy', (t) async {
    await t.pumpWidget(_app());
    await t.pumpAndSettle();

    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();

    expect(t.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('Only what you capture with the button'), findsOneWidget);
    expect(await TranscriptionSettings.privacyMode(), isTrue);
  });
}
