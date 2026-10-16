// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The dictation page's half of the A2 grammar: while it is mounted it is the
// app's capture surface, so it claims WearableDeviceBridge.captureOwner and
// gives it back on dispose.
//
// Recording itself needs the phone mic and an installed Gemma model, so the
// page renders its "not installed" state here and _start/_stop/_cancel are not
// exercised. What is covered is the handover — the part that decides whether a
// wearable tap reaches this page at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/device_bridge.dart';
import 'package:kelvinlee/wearable/pages/wearable_dictation_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => WearableDeviceBridge.captureOwner = null);

  testWidgets('claims capture while mounted and releases it on dispose', (tester) async {
    expect(WearableDeviceBridge.captureOwner, isNull);

    await tester.pumpWidget(const MaterialApp(home: WearableDictationPage()));
    expect(WearableDeviceBridge.captureOwner, isNotNull);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(WearableDeviceBridge.captureOwner, isNull);
  });

  testWidgets('leaves the slot alone when another surface has taken it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WearableDictationPage()));

    bool other(WearableGestureAction _) => true;
    WearableDeviceBridge.captureOwner = other;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(WearableDeviceBridge.captureOwner, same(other));
  });

  testWidgets('declines every gesture while the model is unavailable', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WearableDictationPage()));
    final owner = WearableDeviceBridge.captureOwner!;

    // Declining is what lets the bridge correct the capture tell-tale instead
    // of leaving it lit on a page that cannot record.
    for (final action in WearableGestureAction.values) {
      expect(owner(action), isFalse, reason: '\$action should fall through');
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('declines while covered by another route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: const WearableDictationPage(),
    ));
    final owner = WearableDeviceBridge.captureOwner!;

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('on top'))),
    );
    await tester.pumpAndSettle();

    expect(owner(WearableGestureAction.startCapture), isFalse);
  });
}
