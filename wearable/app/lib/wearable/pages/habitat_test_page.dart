// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableHabitatTestPage — dev-only page that lets Kelvin trigger each of the
// six habitat alerts server-side. Useful for:
//   - verifying the BLE write path end-to-end after a firmware flash
//   - previewing LED colour / haptic pulse feel before wearing the device
//   - showing a visiting stakeholder what the vocabulary looks like
//
// Implementation shortcut: there is no /api/device/command/enqueue endpoint
// (plan §4.3 would add one); instead we invoke the equivalent by calling
// the existing `/api/plugins/sync` → false path. That doesn't work for
// this page. So we take the direct path: operator writes the 4-byte packet
// bytes over BLE themselves via the lib/wearable/command_codec.dart encoder.
//
// This page is therefore a direct-BLE writer — it bypasses the server queue.
// That keeps the server's normal delivery path (device-delivery.ts) the
// single owner of production alerts, while this dev tool lets Kelvin poke
// the firmware without needing a dispatched task.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;

import '../command_codec.dart';
import '../wearable_theme.dart';

class _AlertSpec {
  final String label;
  final String description;
  final Color accent;
  final List<Map<String, dynamic>> packets;
  const _AlertSpec(this.label, this.description, this.accent, this.packets);
}

// Vocabulary authority: devices/wearable-kelvinlee/docs/HABITAT_ALERTS.md
// Byte-for-byte identical to HABITAT_ALERTS in src/harness/device/commands.ts.
const _alerts = <_AlertSpec>[
  _AlertSpec('Task queued', 'blue pulse + single haptic', WearableColors.info, [
    {'kind': 'led_pattern', 'pattern': 0x03, 'durationMs': 1000},
    {'kind': 'led_color', 'r': 0, 'g': 80, 'b': 200},
    {'kind': 'haptic', 'pattern': 0x10, 'durationMs': 120},
  ]),
  _AlertSpec('Task running', 'blue breathing', WearableColors.info, [
    {'kind': 'led_pattern', 'pattern': 0x02, 'durationMs': 0},
    {'kind': 'led_color', 'r': 0, 'g': 80, 'b': 200},
  ]),
  _AlertSpec('Awaiting input', 'amber pulse + long haptic', WearableColors.warning, [
    {'kind': 'led_pattern', 'pattern': 0x03, 'durationMs': 0},
    {'kind': 'led_color', 'r': 220, 'g': 140, 'b': 0},
    {'kind': 'haptic', 'pattern': 0x13, 'durationMs': 500},
  ]),
  _AlertSpec('Task done', 'green flash + double haptic', WearableColors.primary, [
    {'kind': 'led_pattern', 'pattern': 0x05, 'durationMs': 2000},
    {'kind': 'led_color', 'r': 0, 'g': 200, 'b': 60},
    {'kind': 'haptic', 'pattern': 0x11, 'durationMs': 300},
  ]),
  _AlertSpec('Error', 'red flash + triple haptic', WearableColors.destructive, [
    {'kind': 'led_pattern', 'pattern': 0x05, 'durationMs': 3000},
    {'kind': 'led_color', 'r': 220, 'g': 20, 'b': 20},
    {'kind': 'haptic', 'pattern': 0x12, 'durationMs': 450},
  ]),
  _AlertSpec('Budget warn', 'amber breathing', WearableColors.warning, [
    {'kind': 'led_pattern', 'pattern': 0x02, 'durationMs': 0},
    {'kind': 'led_color', 'r': 220, 'g': 140, 'b': 0},
  ]),
];

class WearableHabitatTestPage extends StatefulWidget {
  const WearableHabitatTestPage({super.key, required this.agentCmdChar});
  final ble.BluetoothCharacteristic agentCmdChar;

  @override
  State<WearableHabitatTestPage> createState() => _WearableHabitatTestPageState();
}

class _WearableHabitatTestPageState extends State<WearableHabitatTestPage> {
  String? _lastFired;
  String? _error;
  bool _busy = false;

  Future<void> _fire(_AlertSpec spec) async {
    setState(() { _busy = true; _error = null; });
    try {
      for (final cmd in spec.packets) {
        final bytes = encodeCommandFromJson(cmd);
        if (bytes == null) continue;
        await widget.agentCmdChar.write(bytes, withoutResponse: true);
      }
      setState(() { _lastFired = spec.label; _busy = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Habitat alerts — dev')),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: _alerts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final a = _alerts[i];
            return Card(
              child: ListTile(
                leading: CircleAvatar(backgroundColor: a.accent.withValues(alpha: 0.15), child: Icon(Icons.bolt, color: a.accent)),
                title: Text(a.label),
                subtitle: Text(a.description),
                trailing: ElevatedButton(
                  onPressed: _busy ? null : () => _fire(a),
                  child: const Text('Fire'),
                ),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error != null
                ? 'error: $_error'
                : (_lastFired == null ? 'Tap an alert to fire it.' : 'Last fired: $_lastFired'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}
