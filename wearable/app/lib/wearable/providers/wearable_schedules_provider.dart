// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableSchedulesProvider — ChangeNotifier backing the Schedules tab
// (plan §5.5 M-4). Mirrors WearableTasksProvider's patterns: generation-
// counter de-race on refresh, snapshot rollback on mutation failure,
// paired-vs-unpaired state, clear error surface.

import 'package:flutter/foundation.dart';

import '../models/wearable_schedule.dart';
import '../wearable_client.dart';

class WearableSchedulesProvider extends ChangeNotifier {
  WearableSchedulesProvider({WearableClient? client})
      : _client = client ?? WearableClient.instance;

  final WearableClient _client;

  List<WearableSchedule> _schedules = const [];
  bool _loading = false;
  String? _error;
  bool _paired = false;

  List<WearableSchedule> get schedules => _schedules;
  bool get isLoading => _loading;
  String? get error => _error;
  bool get paired => _paired;

  /// Monotonic generation counter so only the latest refresh writes back.
  int _refreshGeneration = 0;

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final paired = await _client.isPaired();
      if (generation != _refreshGeneration) return;
      _paired = paired;
      if (!_paired) {
        _schedules = const [];
        return;
      }
      final next = await _client.listSchedules();
      if (generation != _refreshGeneration) return;
      _schedules = next;
    } catch (e) {
      if (generation != _refreshGeneration) return;
      _error = 'Could not reach Wearable: $e';
      _schedules = const [];
    } finally {
      if (generation == _refreshGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<WearableSchedule> create({
    required String name,
    required String cron,
    required String message,
    required String chatId,
    required String channel,
  }) async {
    final created = await _client.createSchedule(
      name: name,
      cron: cron,
      message: message,
      chatId: chatId,
      channel: channel,
    );
    _schedules = [created, ..._schedules];
    notifyListeners();
    return created;
  }

  /// Toggle enabled flag. Optimistic flip with snapshot rollback on HTTP
  /// failure so the switch doesn't desync from the server.
  Future<void> setEnabled(int id, bool enabled) async {
    final snapshot = _schedules;
    _schedules = _schedules
        .map((s) => s.id == id
            ? WearableSchedule(
                id: s.id,
                name: s.name,
                cron: s.cron,
                message: s.message,
                chatId: s.chatId,
                channel: s.channel,
                enabled: enabled,
                createdAt: s.createdAt,
                nextRunAt: s.nextRunAt,
                lastRunAt: s.lastRunAt,
                lastOk: s.lastOk,
                lastError: s.lastError,
              )
            : s)
        .toList(growable: false);
    notifyListeners();
    try {
      final updated = await _client.updateSchedule(id, enabled: enabled);
      _schedules = _schedules.map((s) => s.id == id ? updated : s).toList(growable: false);
      notifyListeners();
    } catch (_) {
      _schedules = snapshot;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> update(
    int id, {
    String? name,
    String? cron,
    String? message,
  }) async {
    final snapshot = _schedules;
    try {
      final updated = await _client.updateSchedule(
        id,
        name: name,
        cron: cron,
        message: message,
      );
      _schedules = _schedules.map((s) => s.id == id ? updated : s).toList(growable: false);
      notifyListeners();
    } catch (_) {
      _schedules = snapshot;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> delete(int id) async {
    final snapshot = _schedules;
    _schedules = _schedules.where((s) => s.id != id).toList(growable: false);
    notifyListeners();
    try {
      await _client.deleteSchedule(id);
    } catch (_) {
      _schedules = snapshot;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> runNow(int id) => _client.runScheduleNow(id);
}
