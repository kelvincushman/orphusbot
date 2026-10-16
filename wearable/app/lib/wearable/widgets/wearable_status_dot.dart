// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableStatusDot — 8dp coloured dot reflecting BLE + Wearable server health.
// Placed in the app bar next to the Wearable wordmark per the v1.0 design spec.
// Reads WearableConnectionProvider from the widget tree — no direct subscription
// plumbing required.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../wearable_theme.dart';
import '../providers/wearable_connection_provider.dart';

class WearableStatusDot extends StatelessWidget {
  const WearableStatusDot({super.key, this.size = 8});

  final double size;

  @override
  Widget build(BuildContext context) {
    final status = context.watch<WearableConnectionProvider>().status;
    if (status == WearableConnectionStatus.unpaired) {
      return const SizedBox.shrink();
    }
    final color = _colorFor(status);
    final tooltip = _labelFor(status);
    return Tooltip(
      message: tooltip,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Color _colorFor(WearableConnectionStatus s) {
    switch (s) {
      case WearableConnectionStatus.connected:
        return WearableColors.primary;
      case WearableConnectionStatus.syncing:
        return WearableColors.warning;
      case WearableConnectionStatus.disconnected:
        return WearableColors.mutedFg;
      case WearableConnectionStatus.error:
        return WearableColors.destructive;
      case WearableConnectionStatus.unpaired:
        return Colors.transparent;
    }
  }

  String _labelFor(WearableConnectionStatus s) {
    switch (s) {
      case WearableConnectionStatus.connected: return 'Server connected';
      case WearableConnectionStatus.syncing: return 'Server syncing…';
      case WearableConnectionStatus.disconnected: return 'Server unreachable';
      case WearableConnectionStatus.error: return 'Server error — check logs';
      case WearableConnectionStatus.unpaired: return '';
    }
  }
}
