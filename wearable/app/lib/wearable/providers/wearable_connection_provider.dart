// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableConnectionProvider — health of the optional Wearable SERVER.
//
// Despite the name this tracks the server and nothing else: _refresh() probes
// /api/health and never looks at the BLE bridge. The wearable's own state lives
// on WearableDeviceBridge. Label anything driven by this "Server …", never
// "Wearable …" — that mix-up put "Wearable unpaired" on screen while a wearable
// was connected and reporting 100% battery.
//
// Drives WearableStatusDot (appbar) and any widget that wants to reflect
// connectivity. Keeps the check cheap: piggybacks on WearableDeviceBridge's
// current reference for BLE, and does a 30-second rolling /api/health
// probe against the paired Wearable base URL.
//
// States:
//   connected  → bridge active + last health check 200 within window
//   syncing    → bridge attaching, or health check in flight
//   disconnected → paired but bridge null (device lost) or health 5xx/timeout
//   error      → hard failure (credentials gone, repeated 401)
//   unpaired   → no server credentials yet (hide dot entirely)

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';

import '../wearable_client.dart';

enum WearableConnectionStatus {
  unpaired,
  disconnected,
  syncing,
  connected,
  error,
}

class WearableConnectionProvider extends ChangeNotifier {
  WearableConnectionProvider() {
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  WearableConnectionStatus _status = WearableConnectionStatus.unpaired;
  Timer? _timer;
  DateTime? _lastHealthyAt;

  WearableConnectionStatus get status => _status;
  DateTime? get lastHealthyAt => _lastHealthyAt;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final creds = await WearableClient.instance.loadCredentials();
    if (creds == null) {
      _update(WearableConnectionStatus.unpaired);
      return;
    }
    // Show syncing while the HTTP probe is in flight.
    _update(WearableConnectionStatus.syncing);
    final ok = await _probeHealth(creds.baseUrl);
    if (ok) {
      // Server is reachable → connected. The BLE wearable is a separate
      // concern tracked by WearableDeviceBridge; server connectivity should not
      // be masked by the absence of a wearable.
      _lastHealthyAt = DateTime.now();
      _update(WearableConnectionStatus.connected);
    } else {
      _update(WearableConnectionStatus.disconnected);
    }
  }

  Future<bool> _probeHealth(String baseUrl) async {
    // Use the same cert-accepting HttpClient as WearableClient so the probe
    // succeeds against the operator's self-signed LAN cert (debug/profile
    // only — release enforces standard validation, matching wearable_client.dart).
    final httpClient = HttpClient();
    if (kDebugMode || kProfileMode) {
      httpClient.badCertificateCallback = (cert, host, port) => true;
    }
    final client = IOClient(httpClient);
    try {
      final r = await client
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  void _update(WearableConnectionStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  /// Trigger an immediate refresh (e.g. after a user action that should flip
  /// the state sooner than the 30s timer). Does not await the result.
  void poke() => unawaited(_refresh());
}
