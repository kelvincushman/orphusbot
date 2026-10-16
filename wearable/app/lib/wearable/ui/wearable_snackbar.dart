// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// App-wide snackbars for code that has no BuildContext of its own — the device
// bridge reports BLE/transport failures from stream callbacks.
//
// The navigator key lives here rather than in main.dart so lib/wearable/ never
// has to import the app entrypoint. main.dart passes it to MaterialApp.

import 'package:flutter/material.dart';

/// Root navigator key. Wired into MaterialApp by main.dart.
final GlobalKey<NavigatorState> wearableNavigatorKey = GlobalKey<NavigatorState>();

class WearableSnackbar {
  WearableSnackbar._();

  static void show(String message, {Color? background, Duration? duration}) {
    final context = wearableNavigatorKey.currentContext;
    // Fired before the first frame or after teardown — drop it rather than throw.
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: background, duration: duration ?? const Duration(seconds: 2)),
    );
  }

  static void showError(String message, {Duration? duration}) =>
      show(message, background: Colors.red.shade700, duration: duration);
}
