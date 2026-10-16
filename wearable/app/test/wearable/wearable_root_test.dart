// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The app must not gate itself on a server. It pairs to the wearable over BLE
// and transcribes on-device with Gemma; a server is optional enrichment that
// lives in Settings. WearableRoot used to demand a base URL and a bearer token
// before it would render anything, which put the BLE scan flow — the actual
// wearable pairing — behind a server the wearer may not run.
//
// Structural, like wearable_home_page_test.dart: build() is called directly
// because mounting the shell needs the full provider tree, native plugins, and
// leaves pollers running past the test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/wearable_home_page.dart';
import 'package:kelvinlee/wearable/wearable_root.dart';

void main() {
  testWidgets('WearableRoot.build returns the app shell unconditionally', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (c) {
      ctx = c;
      return const SizedBox.shrink();
    }));

    expect(const WearableRoot().build(ctx), isA<WearableHomePage>());
  });

  test('WearableRoot is stateless — nothing to await before the first frame', () {
    // The old root was a StatefulWidget that showed a spinner until an async
    // isPaired() resolved. A shell with no gate has nothing to wait for.
    expect(const WearableRoot(), isA<StatelessWidget>());
  });
}
