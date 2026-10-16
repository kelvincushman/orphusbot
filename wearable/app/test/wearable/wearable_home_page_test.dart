// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Structural test for the app shell — verifies the pair-only entry decision:
// WearableHomePage.build returns the lock gate directly, with no sign-in or
// onboarding step in between.
//
// We do NOT pumpWidget(WearableHomePage()) because the tab pages need the full
// provider tree and native plugins. Calling build directly is enough to confirm
// the bypass without that harness.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/security/app_lock.dart';
import 'package:kelvinlee/wearable/wearable_home_page.dart';

void main() {
  testWidgets('WearableHomePage.build returns AppLockGate unconditionally', (WidgetTester tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      Builder(
        builder: (ctx) {
          capturedContext = ctx;
          return const SizedBox.shrink();
        },
      ),
    );

    final widget = const WearableHomePage().build(capturedContext);

    expect(widget, isA<AppLockGate>());
  });
}
