// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableStatusPill — compact AppBar indicator consolidating BLE wearable state
// (battery %) and Wearable server health into one tidy chip.
//
// Layout (when connected):
//   [● 82%  |  ◉ Wearable]
//   status dot + battery %  •  vertical rule  •  status dot + "Wearable"
//
// States:
//   wearable connected + Wearable connected → both sections use `success`
//   wearable disconnected               → wearable section muted / crossed
//   Wearable disconnected / error           → Wearable section uses warning / red
//   wearable unpaired                   → wearable section hidden; only Wearable dot
//
// Tapping the pill navigates to DeviceStatusPage (the Wearable tab).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:kelvinlee/wearable/providers/wearable_connection_provider.dart';
import 'package:kelvinlee/wearable/providers/wearable_device_provider.dart';

class WearableStatusPill extends StatelessWidget {
  /// Called when the pill is tapped — typically opens the Wearable tab or
  /// DeviceStatusPage. Pass null to disable tap.
  final VoidCallback? onTap;

  const WearableStatusPill({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Consumer2<WearableDeviceProvider, WearableConnectionProvider>(
      builder: (context, device, wearableConn, _) {
        final bool wearablePaired = device.hasPairedDevice;
        final bool wearableConnected = device.connectedDevice != null;
        final int? battery = device.batteryLevel;
        final WearableConnectionStatus wearableStatus = wearableConn.status;

        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: WearableColors.card,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: WearableColors.border, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Wearable segment ──────────────────────────────────────
                if (wearablePaired) ...[
                  _WearableDot(connected: wearableConnected),
                  const SizedBox(width: 5),
                  if (wearableConnected && battery != null)
                    Text(
                      '$battery%',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _batteryColor(battery),
                      ),
                    )
                  else
                    Text(
                      wearableConnected ? 'BLE' : 'Off',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: WearableColors.mutedFg,
                      ),
                    ),
                  // Divider
                  if (wearableStatus != WearableConnectionStatus.unpaired)
                    Container(
                      width: 1,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      color: WearableColors.border,
                    ),
                ],
                // ── Server segment ────────────────────────────────────────────
                if (wearableStatus != WearableConnectionStatus.unpaired) ...[
                  _ServerDot(status: wearableStatus),
                  const SizedBox(width: 5),
                  Text(
                    'Server',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _wearableTextColor(wearableStatus),
                    ),
                  ),
                ],
                // ── Fallback: nothing paired at all ───────────────────────
                if (!wearablePaired && wearableStatus == WearableConnectionStatus.unpaired)
                  const Text(
                    'Setup',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: WearableColors.mutedFg,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _batteryColor(int level) {
    if (level > 75) return WearableColors.primary;
    if (level > 20) return WearableColors.warning;
    return WearableColors.destructive;
  }

  Color _wearableTextColor(WearableConnectionStatus s) {
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
        return WearableColors.mutedFg;
    }
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

class _WearableDot extends StatelessWidget {
  final bool connected;
  const _WearableDot({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? WearableColors.primary : WearableColors.mutedFg;
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _ServerDot extends StatelessWidget {
  final WearableConnectionStatus status;
  const _ServerDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _color(status);
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  Color _color(WearableConnectionStatus s) {
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
}
