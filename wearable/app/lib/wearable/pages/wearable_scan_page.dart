// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableScanPage — BLE scan + connect flow. Finds KelvinLee wearables advertising the
// audio service (19B10000-...), connects on tap, and hands the connected
// device to WearableDeviceBridge.attach(). Returns to the home screen on success.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:provider/provider.dart';

import '../device_bridge.dart';
import '../wearable_theme.dart';
import '../providers/wearable_device_provider.dart';

const String _kKelvinLeeAudioServiceShort = '19b10000';

class WearableScanPage extends StatefulWidget {
  const WearableScanPage({super.key});

  @override
  State<WearableScanPage> createState() => _WearableScanPageState();
}

class _WearableScanPageState extends State<WearableScanPage> {
  final Map<String, ble.ScanResult> _seen = {};
  StreamSubscription<List<ble.ScanResult>>? _scanSub;
  bool _scanning = false;
  bool _connecting = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    ble.FlutterBluePlus.stopScan();
    super.dispose();
  }

  bool _looksLikeKelvinLee(ble.ScanResult r) {
    final name = r.device.platformName.toLowerCase();
    if (name.contains('kelvinlee') || name.contains('wearable')) return true;
    for (final uuid in r.advertisementData.serviceUuids) {
      if (uuid.toString().toLowerCase().contains(_kKelvinLeeAudioServiceShort)) return true;
    }
    return false;
  }

  Future<void> _startScan() async {
    setState(() {
      _seen.clear();
      _scanning = true;
      _status = 'Scanning for Wearable wearables…';
    });

    try {
      _scanSub?.cancel();
      _scanSub = ble.FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          if (_looksLikeKelvinLee(r)) {
            _seen[r.device.remoteId.str] = r;
          }
        }
        if (mounted) setState(() {});
      });
      await ble.FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _status = 'Scan failed: $e';
        });
      }
      return;
    }

    await Future.delayed(const Duration(seconds: 10));
    await ble.FlutterBluePlus.stopScan();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _status = _seen.isEmpty
          ? 'No Wearable wearable found. Make sure the Xiao is on and in range.'
          : 'Found ${_seen.length}. Tap to connect.';
    });
  }

  Future<void> _connect(ble.BluetoothDevice device) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting to ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}…';
    });
    try {
      // Android keeps the GATT link when the app is killed, so the next launch
      // finds a connection the app knows nothing about: connect() returns
      // immediately, discoverServices() then fails with "device is not
      // connected", and the wearable — believing it still has a central —
      // stops advertising, so nothing else can reach it either. Observed on
      // every restart until the app was force-stopped.
      //
      // Dropping a stale link first costs one round trip and makes reconnect
      // deterministic. A device we are genuinely not connected to skips it.
      if (device.isConnected) {
        setState(() => _status = 'Clearing a stale connection…');
        try {
          await device.disconnect();
        } catch (_) {
          // Already gone, or the platform disagrees — connect() below decides.
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
      }
      await device.connect(timeout: const Duration(seconds: 10));

      // connect() returning is not the same as the link being usable. On
      // Android it resolves as soon as the GATT client is created, and
      // discoverServices() then fails with "device is not connected" — the
      // failure seen on every attempt this morning while a raw-HCI dongle
      // completed a full GATT session against the same firmware seconds
      // earlier. Wait for the platform to actually report connected.
      if (!device.isConnected) {
        setState(() => _status = 'Waiting for the link to settle…');
        await device.connectionState
            .firstWhere((s) => s == ble.BluetoothConnectionState.connected)
            .timeout(const Duration(seconds: 10));
      }
      if (!mounted) return;
      setState(() => _status = 'Connected. Attaching Wearable bridge…');

      // Even settled, the first discovery can lose a race with Android's
      // service cache — and it THROWS rather than returning null, so it has to
      // be caught to be retried. One retry costs a second and turns a dead end
      // into a connection; more than one would just be hiding a real fault.
      WearableDeviceBridge? bridge;
      try {
        bridge = await WearableDeviceBridge.attach(device);
      } catch (e) {
        if (!mounted) rethrow;
        setState(() => _status = 'Retrying service discovery…');
        await Future<void>.delayed(const Duration(seconds: 1));
        bridge = await WearableDeviceBridge.attach(device);
      }
      if (!mounted) return;
      if (bridge == null) {
        setState(() {
          _connecting = false;
          _status = 'Bridge attach failed — could not read the wearable\'s services.';
        });
        return;
      }
      await context.read<WearableDeviceProvider>().adopt(device);
      if (!mounted) return;
      Navigator.pop(context, bridge);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _status = 'Connect failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _seen.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan for wearable'),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh),
            onPressed: (_scanning || _connecting) ? null : _startScan,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_scanning) const LinearProgressIndicator(),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_status!, style: Theme.of(context).textTheme.bodySmall),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: results.length,
                itemBuilder: (ctx, i) {
                  final r = results[i];
                  final name = r.device.platformName.isEmpty ? '(unnamed)' : r.device.platformName;
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: ListTile(
                      leading: const Icon(Icons.bluetooth, color: WearableColors.primary),
                      title: Text(name),
                      subtitle: Text('${r.device.remoteId.str} · RSSI ${r.rssi} dBm'),
                      trailing: _connecting ? null : const Icon(Icons.chevron_right),
                      onTap: _connecting ? null : () => _connect(r.device),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
