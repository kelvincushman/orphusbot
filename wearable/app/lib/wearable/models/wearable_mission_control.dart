// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Mission Control DTOs — mirror of the server-side `MissionControl*`
// shapes in `src/mission-control.ts`. Drives the front-page asynchronous-PM
// view and the in-app Mission Control page.

import 'wearable_task.dart';

class WearableTaskCompletion {
  const WearableTaskCompletion({
    required this.pct,
    required this.method,
    required this.detail,
  });

  /// 0..1 — drives the per-task progress bar.
  final double pct;

  /// `"children"`, `"attempts"`, or `"elapsed"` — see `MissionTaskMethod` on
  /// the server. Surfaced so the UI can label *how* the % was derived.
  final String method;

  /// Human-readable detail (`"2/3 children resolved"`).
  final String detail;

  factory WearableTaskCompletion.fromJson(Map<String, dynamic> json) {
    return WearableTaskCompletion(
      pct: (json['pct'] as num?)?.toDouble() ?? 0,
      method: (json['method'] ?? 'elapsed') as String,
      detail: (json['detail'] ?? '') as String,
    );
  }
}

class WearableTaskBurn {
  const WearableTaskBurn({
    required this.tokensIn,
    required this.tokensInBudget,
    required this.tokensOut,
    required this.tokensOutBudget,
    required this.usdCents,
    required this.usdCentsBudget,
    required this.wallClockMs,
    required this.wallClockMsBudget,
    required this.pctMax,
  });

  final int tokensIn;
  final int tokensInBudget;
  final int tokensOut;
  final int tokensOutBudget;
  final int usdCents;

  /// `null` when the contract has no USD ceiling.
  final int? usdCentsBudget;
  final int wallClockMs;
  final int wallClockMsBudget;

  /// 0..1 — the worst of the four ratios; drives alert color.
  final double pctMax;

  factory WearableTaskBurn.fromJson(Map<String, dynamic> json) {
    return WearableTaskBurn(
      tokensIn: (json['tokensIn'] as num?)?.toInt() ?? 0,
      tokensInBudget: (json['tokensInBudget'] as num?)?.toInt() ?? 0,
      tokensOut: (json['tokensOut'] as num?)?.toInt() ?? 0,
      tokensOutBudget: (json['tokensOutBudget'] as num?)?.toInt() ?? 0,
      usdCents: (json['usdCents'] as num?)?.toInt() ?? 0,
      usdCentsBudget: (json['usdCentsBudget'] as num?)?.toInt(),
      wallClockMs: (json['wallClockMs'] as num?)?.toInt() ?? 0,
      wallClockMsBudget: (json['wallClockMsBudget'] as num?)?.toInt() ?? 0,
      pctMax: (json['pctMax'] as num?)?.toDouble() ?? 0,
    );
  }
}

class WearableTaskDoing {
  const WearableTaskDoing({
    required this.kind,
    required this.label,
    required this.sinceMs,
  });

  /// `"tool_call"` or `"model_call"`.
  final String kind;

  /// `"Bash: npm test"` / `"claude-sonnet-4-6 (req 1.4k)"`.
  final String label;

  /// Age of the underlying trace event in ms.
  final int sinceMs;

  static WearableTaskDoing? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final kind = json['kind'];
    final label = json['label'];
    if (kind is! String || label is! String) return null;
    return WearableTaskDoing(
      kind: kind,
      label: label,
      sinceMs: (json['sinceMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class WearableCourseCorrection {
  const WearableCourseCorrection({
    required this.taskId,
    required this.t,
    required this.kind,
    required this.trigger,
    required this.summary,
  });

  final String taskId;
  final int t;

  /// `"attempt_boundary"`, `"worker_failover"`, `"completion_check"`.
  final String kind;

  /// Why it fired (`"missing_required_output"`, `"transport_error"`, …).
  final String trigger;
  final String summary;

  factory WearableCourseCorrection.fromJson(Map<String, dynamic> json) {
    return WearableCourseCorrection(
      taskId: (json['taskId'] ?? '') as String,
      t: (json['t'] as num?)?.toInt() ?? 0,
      kind: (json['kind'] ?? '') as String,
      trigger: (json['trigger'] ?? '') as String,
      summary: (json['summary'] ?? '') as String,
    );
  }
}

class WearableMissionControlTaskRow {
  const WearableMissionControlTaskRow({
    required this.taskId,
    required this.role,
    required this.businessId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.completion,
    required this.burn,
    this.prompt,
    this.workerKind,
    this.workerName,
    this.doing,
    this.lastCorrection,
    this.lastHandoff,
  });

  final String taskId;
  final String? prompt;
  final String role;
  final String businessId;
  final WearableTaskStatus status;
  final String? workerKind;
  final String? workerName;
  final int createdAt;
  final int updatedAt;
  final WearableTaskCompletion completion;
  final WearableTaskBurn burn;
  final WearableTaskDoing? doing;
  final WearableCourseCorrection? lastCorrection;

  /// Most recent handoff (attempt_boundary / worker_failover / child_dispatch
  /// / child_result), or null. Used by the expanded card to surface
  /// "what just happened on this task" alongside `lastCorrection`.
  final WearableMissionHandoff? lastHandoff;

  factory WearableMissionControlTaskRow.fromJson(Map<String, dynamic> json) {
    return WearableMissionControlTaskRow(
      taskId: (json['taskId'] ?? '') as String,
      prompt: json['prompt'] as String?,
      role: (json['role'] ?? 'main') as String,
      businessId: (json['businessId'] ?? 'default') as String,
      status: WearableTaskStatus.fromWire(json['status']),
      workerKind: json['workerKind'] as String?,
      workerName: json['workerName'] as String?,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      completion: WearableTaskCompletion.fromJson(
        (json['completion'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      burn: WearableTaskBurn.fromJson(
        (json['burn'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      doing: WearableTaskDoing.fromJson(
        (json['doing'] as Map?)?.cast<String, dynamic>(),
      ),
      lastCorrection: (json['lastCorrection'] as Map?) == null
          ? null
          : WearableCourseCorrection.fromJson(
              (json['lastCorrection'] as Map).cast<String, dynamic>(),
            ),
      lastHandoff: (json['lastHandoff'] as Map?) == null
          ? null
          : WearableMissionHandoff.fromJson(
              (json['lastHandoff'] as Map).cast<String, dynamic>(),
            ),
    );
  }
}

class WearableMissionHandoff {
  const WearableMissionHandoff({
    required this.t,
    required this.kind,
    required this.summary,
    this.fromKind,
    this.fromName,
    this.toKind,
    this.toName,
    this.childTaskId,
  });

  final int t;

  /// `"attempt_boundary"`, `"worker_failover"`, `"child_dispatch"`,
  /// `"child_result"`.
  final String kind;
  final String summary;
  final String? fromKind;
  final String? fromName;
  final String? toKind;
  final String? toName;
  final String? childTaskId;

  factory WearableMissionHandoff.fromJson(Map<String, dynamic> json) {
    final from = (json['fromWorker'] as Map?)?.cast<String, dynamic>();
    final to = (json['toWorker'] as Map?)?.cast<String, dynamic>();
    return WearableMissionHandoff(
      t: (json['t'] as num?)?.toInt() ?? 0,
      kind: (json['kind'] ?? '') as String,
      summary: (json['summary'] ?? '') as String,
      fromKind: from?['kind'] as String?,
      fromName: from?['name'] as String?,
      toKind: to?['kind'] as String?,
      toName: to?['name'] as String?,
      childTaskId: json['childTaskId'] as String?,
    );
  }
}

class WearableMissionControlTaskDetail {
  const WearableMissionControlTaskDetail({
    required this.row,
    required this.handoffs,
    required this.recentEvents,
  });

  final WearableMissionControlTaskRow row;
  final List<WearableMissionHandoff> handoffs;

  /// Last ≤50 trace events as raw JSON maps. Pages that need typed events
  /// can filter by `kind` and re-shape; most UIs only need a kind+timestamp.
  final List<Map<String, dynamic>> recentEvents;

  factory WearableMissionControlTaskDetail.fromJson(Map<String, dynamic> json) {
    return WearableMissionControlTaskDetail(
      row: WearableMissionControlTaskRow.fromJson(json),
      handoffs: ((json['handoffs'] as List?) ?? const [])
          .cast<Map<dynamic, dynamic>>()
          .map((e) => WearableMissionHandoff.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
      recentEvents: ((json['recentEvents'] as List?) ?? const [])
          .cast<Map<dynamic, dynamic>>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false),
    );
  }
}

class WearableMissionBudgetWindow {
  const WearableMissionBudgetWindow({
    required this.tokens,
    required this.usdCents,
    required this.wallClockMs,
    required this.dispatches,
  });

  final int tokens;
  final int usdCents;
  final int wallClockMs;
  final int dispatches;

  factory WearableMissionBudgetWindow.fromJson(Map<String, dynamic> json) {
    return WearableMissionBudgetWindow(
      tokens: (json['tokens'] as num?)?.toInt() ?? 0,
      usdCents: (json['usdCents'] as num?)?.toInt() ?? 0,
      wallClockMs: (json['wallClockMs'] as num?)?.toInt() ?? 0,
      dispatches: (json['dispatches'] as num?)?.toInt() ?? 0,
    );
  }
}

class WearableMissionBudgetCaps {
  const WearableMissionBudgetCaps({this.tokensDay, this.usdCentsDay});

  final int? tokensDay;
  final int? usdCentsDay;

  static WearableMissionBudgetCaps? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return WearableMissionBudgetCaps(
      tokensDay: (json['tokensDay'] as num?)?.toInt(),
      usdCentsDay: (json['usdCentsDay'] as num?)?.toInt(),
    );
  }
}

class WearableMissionBudget {
  const WearableMissionBudget({
    required this.today,
    required this.thisWeek,
    this.caps,
  });

  final WearableMissionBudgetWindow today;
  final WearableMissionBudgetWindow thisWeek;
  final WearableMissionBudgetCaps? caps;

  factory WearableMissionBudget.fromJson(Map<String, dynamic> json) {
    return WearableMissionBudget(
      today: WearableMissionBudgetWindow.fromJson(
        (json['today'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      thisWeek: WearableMissionBudgetWindow.fromJson(
        (json['thisWeek'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      caps: WearableMissionBudgetCaps.fromJson(
        (json['caps'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

class WearableMissionControl {
  const WearableMissionControl({
    required this.generatedAt,
    required this.budget,
    required this.active,
    required this.recentCourseCorrections,
    this.businessId,
  });

  final int generatedAt;
  final String? businessId;
  final WearableMissionBudget budget;
  final List<WearableMissionControlTaskRow> active;
  final List<WearableCourseCorrection> recentCourseCorrections;

  factory WearableMissionControl.fromJson(Map<String, dynamic> json) {
    return WearableMissionControl(
      generatedAt: (json['generatedAt'] as num?)?.toInt() ?? 0,
      businessId: json['businessId'] as String?,
      budget: WearableMissionBudget.fromJson(
        (json['budget'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      active: ((json['active'] as List?) ?? const [])
          .cast<Map<dynamic, dynamic>>()
          .map((e) => WearableMissionControlTaskRow.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
      recentCourseCorrections: ((json['recentCourseCorrections'] as List?) ?? const [])
          .cast<Map<dynamic, dynamic>>()
          .map((e) => WearableCourseCorrection.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

class WearableMissionActiveSlot {
  const WearableMissionActiveSlot({
    required this.role,
    this.activeTaskId,
    this.doing,
  });

  final String role;
  final String? activeTaskId;
  final WearableTaskDoing? doing;

  factory WearableMissionActiveSlot.fromJson(Map<String, dynamic> json) {
    return WearableMissionActiveSlot(
      role: (json['role'] ?? '') as String,
      activeTaskId: json['activeTaskId'] as String?,
      doing: WearableTaskDoing.fromJson(
        (json['doing'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

class WearableMissionActive {
  const WearableMissionActive({required this.generatedAt, required this.perRole});

  final int generatedAt;
  final List<WearableMissionActiveSlot> perRole;

  factory WearableMissionActive.fromJson(Map<String, dynamic> json) {
    return WearableMissionActive(
      generatedAt: (json['generatedAt'] as num?)?.toInt() ?? 0,
      perRole: ((json['perRole'] as List?) ?? const [])
          .cast<Map<dynamic, dynamic>>()
          .map((e) => WearableMissionActiveSlot.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}
