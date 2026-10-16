// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// CaptureDiagnostics had twenty writers and no listeners: every message the
// capture path deliberately raised for the user rendered nowhere. This pins the
// one screen that shows them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/capture_diagnostics.dart';
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

  testWidgets('a capture event reaches the screen', (t) async {
    CaptureDiagnostics.instance.updateMode(
      TranscriptionMode.onDevice, OnDeviceSegmentation.button,
      encoding: 'opus', frameMs: 10);
    CaptureDiagnostics.instance.event('Note discarded (12.4s), recoverable for 10 min');

    await t.pumpWidget(_app());
    await t.pump();

    expect(find.text('Capture'), findsOneWidget);
    expect(find.text('Note discarded (12.4s), recoverable for 10 min'), findsOneWidget);
    expect(find.text('opus · 10 ms frames'), findsOneWidget);
  });

  testWidgets('a later event replaces the earlier one without a rebuild call', (t) async {
    CaptureDiagnostics.instance.event('SD sync failed');
    await t.pumpWidget(_app());
    await t.pump();
    expect(find.text('SD sync failed'), findsOneWidget);

    // The card listens, so this must appear with no setState from the page.
    CaptureDiagnostics.instance.event('On-device audio unavailable');
    await t.pump();
    expect(find.text('On-device audio unavailable'), findsOneWidget);
    expect(find.text('SD sync failed'), findsNothing);
  });
}
