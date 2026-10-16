// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableMissionControlProvider — ChangeNotifier backing the Mission Control
// page. Polls /api/mission-control on a fixed cadence while the page is in
// view, with a generation-based race guard mirroring WearableTasksProvider.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;

import '../models/wearable_mission_control.dart';
import '../wearable_client.dart';

class WearableMissionControlProvider extends ChangeNotifier with WidgetsBindingObserver {
  WearableMissionControlProvider({
    WearableClient? client,
    Duration pollInterval = const Duration(seconds: 8),
  })  : _client = client ?? WearableClient.instance,
        _pollInterval = pollInterval {
    WidgetsBinding.instance.addObserver(this);
  }

  final WearableClient _client;
  final Duration _pollInterval;

  WearableMissionControl? _data;
  bool _loading = false;
  String? _error;
  bool _paired = false;
  Timer? _timer;
  /// True iff a page has called `start()` and not since called `stop()`.
  /// The lifecycle observer pauses the timer on `paused`/`inactive` only when
  /// `_active` is true so a backgrounded app on a non-MC tab stays quiet.
  bool _active = false;

  /// Monotonically increasing counter stamped onto each outbound refresh.
  /// Only the most-recently-issued request is allowed to write its result;
  /// earlier responses that arrive later are silently discarded.
  int _refreshGeneration = 0;

  WearableMissionControl? get data => _data;
  bool get isLoading => _loading;
  String? get error => _error;
  bool get paired => _paired;

  /// Begin polling. Idempotent — calling start() while a timer is already
  /// armed is a no-op. Fires one immediate fetch.
  void start() {
    _active = true;
    if (_timer != null) return;
    refresh();
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  /// Stop polling. Safe to call from page dispose; the next listener-attached
  /// page can call start() to resume.
  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_active) return;
    if (state == AppLifecycleState.resumed) {
      // Re-arm if backgrounding cancelled our timer; do one immediate fetch.
      if (_timer == null) {
        refresh();
        _timer = Timer.periodic(_pollInterval, (_) => refresh());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    if (_data == null) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    try {
      final paired = await _client.isPaired();
      if (generation != _refreshGeneration) return;
      _paired = paired;
      if (!_paired) {
        _data = null;
        _error = 'Pair to Wearable to see Mission Control.';
        return;
      }
      final next = await _client.getMissionControl();
      if (generation != _refreshGeneration) return;
      _data = next;
      _error = null;
    } on FormatException {
      if (generation != _refreshGeneration) return;
      _error = 'Could not reach Wearable: bad response from server.';
    } catch (e) {
      if (generation != _refreshGeneration) return;
      // Keep `_data` so the page can keep showing last-good values.
      // Suppress the raw exception body — a rogue LAN proxy could plant
      // attacker-controlled text here. Status/transport class is enough.
      _error = e is Exception
          ? 'Could not reach Wearable.'
          : 'Could not reach Wearable: $e';
    } finally {
      if (generation == _refreshGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stop();
    super.dispose();
  }
}
