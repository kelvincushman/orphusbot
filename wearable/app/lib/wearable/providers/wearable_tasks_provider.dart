// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableTasksProvider — ChangeNotifier backing the Tasks ledger tab (plan
// §5.4 M-3). Holds the currently-selected segment (Active / Needs input /
// Done), the last-fetched list, loading + error state, and exposes
// refresh/reply/cancel methods that forward to WearableClient.

import 'package:flutter/foundation.dart';

import '../models/wearable_task.dart';
import '../wearable_client.dart';

enum WearableTasksSegment {
  active,
  pendingInput,
  done;

  WearableTaskStatus get serverStatus => switch (this) {
        WearableTasksSegment.active => WearableTaskStatus.active,
        WearableTasksSegment.pendingInput => WearableTaskStatus.pendingInput,
        WearableTasksSegment.done => WearableTaskStatus.completed,
      };

  String get label => switch (this) {
        WearableTasksSegment.active => 'Active',
        WearableTasksSegment.pendingInput => 'Needs input',
        WearableTasksSegment.done => 'Done',
      };
}

class WearableTasksProvider extends ChangeNotifier {
  WearableTasksProvider({WearableClient? client}) : _client = client ?? WearableClient.instance;

  final WearableClient _client;

  WearableTasksSegment _segment = WearableTasksSegment.active;
  List<WearableTaskSummary> _tasks = const [];
  bool _loading = false;
  String? _error;
  bool _paired = false;

  /// Monotonically increasing counter stamped onto each outbound refresh.
  /// Only the most-recently-issued request is allowed to write its result
  /// back into `_tasks`; any earlier call whose response arrives second is
  /// discarded. Prevents the triple-refresh race where initState +
  /// setSegment + a return-from-detail all fire in rapid succession.
  int _refreshGeneration = 0;

  WearableTasksSegment get segment => _segment;
  List<WearableTaskSummary> get tasks => _tasks;
  bool get isLoading => _loading;
  String? get error => _error;
  bool get paired => _paired;

  /// Flip the segmented control. Always fires a refresh — cheap call and
  /// avoids confused "stale data for previous filter" UX.
  void setSegment(WearableTasksSegment next) {
    if (_segment == next) return;
    _segment = next;
    notifyListeners();
    // Fire-and-forget refresh; _loading toggles inside so UI reacts.
    refresh();
  }

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final paired = await _client.isPaired();
      if (generation != _refreshGeneration) return;   // superseded
      _paired = paired;
      if (!_paired) {
        _tasks = const [];
        return;
      }
      final next = await _client.listTasks(status: _segment.serverStatus, limit: 50);
      if (generation != _refreshGeneration) return;   // superseded
      _tasks = next;
    } catch (e) {
      if (generation != _refreshGeneration) return;   // superseded, drop stale error too
      _error = 'Could not reach Wearable: $e';
      _tasks = const [];
    } finally {
      if (generation == _refreshGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Reply to a pending-input task. We optimistically strip the task from
  /// the current list so the user sees instant feedback; if the HTTP call
  /// throws, we restore the pre-call snapshot and re-throw so the page can
  /// surface a SnackBar. Next refresh reconciles with server state.
  Future<void> replyToTask(String taskId, String answer) async {
    final snapshot = _tasks;
    _tasks = _tasks.where((t) => t.taskId != taskId).toList(growable: false);
    notifyListeners();
    try {
      await _client.replyToTask(taskId, answer);
    } catch (_) {
      _tasks = snapshot;
      notifyListeners();
      rethrow;
    }
  }

  /// Cancel an active task. Server advisory-writes cancelled.json; the
  /// task flips to `failed` on next refresh. Optimistic strip from the
  /// Active segment with rollback on HTTP failure.
  Future<void> cancelTask(String taskId, {String? reason}) async {
    final snapshot = _tasks;
    final shouldStrip = _segment == WearableTasksSegment.active;
    if (shouldStrip) {
      _tasks = _tasks.where((t) => t.taskId != taskId).toList(growable: false);
      notifyListeners();
    }
    try {
      await _client.cancelTask(taskId, reason: reason);
    } catch (_) {
      if (shouldStrip) {
        _tasks = snapshot;
        notifyListeners();
      }
      rethrow;
    }
  }
}
