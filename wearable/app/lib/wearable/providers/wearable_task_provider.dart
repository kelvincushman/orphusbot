// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableTaskProvider — tracks Wearable agent tasks the app dispatched and their
// in-flight status. Drives WearableInFlightBanner ("@ops is working...") and
// any UI that wants to show per-agent activity.
//
// Minimal v1: local-only tracking of tasks the user fires via the routing
// sheet. Server-side poll of /api/tasks/active comes in a follow-up once
// the endpoint lands; the shape is prepared so UI code won't need to
// change when the network path is wired.

import 'package:flutter/foundation.dart';

class WearableTask {
  final String id;           // ulid from server, or local UUID while pending
  final String role;         // main | comms | content | ops | research
  final String prompt;       // first 80 chars shown in banner
  final DateTime startedAt;
  final bool completed;

  const WearableTask({
    required this.id,
    required this.role,
    required this.prompt,
    required this.startedAt,
    this.completed = false,
  });

  WearableTask copyWith({bool? completed}) => WearableTask(
    id: id,
    role: role,
    prompt: prompt,
    startedAt: startedAt,
    completed: completed ?? this.completed,
  );
}

class WearableTaskProvider extends ChangeNotifier {
  final List<WearableTask> _tasks = [];

  List<WearableTask> get activeTasks =>
      _tasks.where((t) => !t.completed).toList(growable: false);
  List<WearableTask> get allTasks => List.unmodifiable(_tasks);

  /// True when at least one task is in flight — cheap check for the banner.
  bool get hasActive => _tasks.any((t) => !t.completed);

  /// The most recent active task, or null. Used by banner text.
  WearableTask? get currentActive {
    for (var i = _tasks.length - 1; i >= 0; i--) {
      if (!_tasks[i].completed) return _tasks[i];
    }
    return null;
  }

  void enqueue(WearableTask t) {
    _tasks.add(t);
    notifyListeners();
  }

  void markComplete(String id) {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _tasks[i] = _tasks[i].copyWith(completed: true);
    notifyListeners();
  }

  void clearCompleted() {
    _tasks.removeWhere((t) => t.completed);
    notifyListeners();
  }
}
