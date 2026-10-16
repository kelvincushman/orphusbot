// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Wearable task models — mirror of the server-side `TaskSummary` / task-detail
// shapes shipped in S-2 (commit 70a0b71, `src/dashboard.ts:GET /api/tasks`).
// Keep wire-level parsing here so pages/widgets consume typed Dart objects.

/// Derived status for a Wearable task. The server computes this by inspecting
/// the task's `run/` directory — presence of RESPONSE.md, pending_input.json,
/// cancelled.json, children.json — rather than a column.
enum WearableTaskStatus {
  active,
  pendingInput,
  completed,
  failed,
  awaitingChildren,
  unknown;

  /// Wire form sent by the server (matches `src/dashboard.ts:STATUS_VALUES`).
  String get wire => switch (this) {
    WearableTaskStatus.active => 'active',
    WearableTaskStatus.pendingInput => 'pending_input',
    WearableTaskStatus.completed => 'completed',
    WearableTaskStatus.failed => 'failed',
    WearableTaskStatus.awaitingChildren => 'awaiting_children',
    WearableTaskStatus.unknown => 'unknown',
  };

  static WearableTaskStatus fromWire(Object? raw) {
    final s = raw is String ? raw : '';
    switch (s) {
      case 'active':
        return WearableTaskStatus.active;
      case 'pending_input':
        return WearableTaskStatus.pendingInput;
      case 'completed':
        return WearableTaskStatus.completed;
      case 'failed':
        return WearableTaskStatus.failed;
      case 'awaiting_children':
        return WearableTaskStatus.awaitingChildren;
      default:
        return WearableTaskStatus.unknown;
    }
  }
}

class WearableTaskSummary {
  const WearableTaskSummary({
    required this.taskId,
    required this.role,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.attempts,
    required this.ok,
    this.prompt,
    this.workerKind,
    this.workerName,
    this.usdCents = 0,
  });

  final String taskId;
  final String role;
  final WearableTaskStatus status;
  final int createdAt;
  final int updatedAt;
  final int attempts;
  final bool ok;
  final String? prompt;
  final String? workerKind;
  final String? workerName;
  final int usdCents;

  factory WearableTaskSummary.fromJson(Map<String, dynamic> json) {
    return WearableTaskSummary(
      taskId: (json['taskId'] ?? '') as String,
      role: (json['role'] ?? 'main') as String,
      status: WearableTaskStatus.fromWire(json['status']),
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      attempts: (json['attempts'] as num?)?.toInt() ?? 1,
      ok: json['ok'] == true,
      prompt: json['prompt'] as String?,
      workerKind: json['workerKind'] as String?,
      workerName: json['workerName'] as String?,
      usdCents: (json['usdCents'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Pending-input question attached to a `pending_input` task.
class WearablePendingInput {
  const WearablePendingInput({required this.question, this.kind, this.choices = const [], this.askedAt});

  final String question;
  final String? kind;
  final List<String> choices;
  final int? askedAt;

  static WearablePendingInput? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final q = json['question'];
    if (q is! String || q.isEmpty) return null;
    return WearablePendingInput(
      question: q,
      kind: json['kind'] as String?,
      choices: (json['choices'] as List?)?.cast<String>() ?? const [],
      askedAt: (json['askedAt'] as num?)?.toInt(),
    );
  }
}

class WearableChildTask {
  const WearableChildTask({required this.id, required this.status});
  final String id;
  final WearableTaskStatus status;

  factory WearableChildTask.fromJson(Map<String, dynamic> json) {
    return WearableChildTask(id: (json['id'] ?? '') as String, status: WearableTaskStatus.fromWire(json['status']));
  }
}

class WearableTaskArtifact {
  const WearableTaskArtifact({required this.path, required this.size, required this.modifiedAt});

  final String path;
  final int size;
  final int modifiedAt;

  factory WearableTaskArtifact.fromJson(Map<String, dynamic> json) {
    return WearableTaskArtifact(
      path: json['path'] is String ? json['path'] as String : '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: (json['mtime'] as num?)?.toInt() ?? 0,
    );
  }
}

class WearableTaskDetail {
  const WearableTaskDetail({
    required this.taskId,
    required this.role,
    required this.status,
    required this.createdAt,
    this.response,
    this.prompt,
    this.pendingInput,
    this.children = const [],
    this.artifacts = const [],
    this.driveLinks = const [],
  });

  final String taskId;
  final String role;
  final WearableTaskStatus status;
  final int createdAt;
  final String? response;
  final String? prompt;
  final WearablePendingInput? pendingInput;
  final List<WearableChildTask> children;
  final List<WearableTaskArtifact> artifacts;
  final List<String> driveLinks;

  factory WearableTaskDetail.fromJson(Map<String, dynamic> json) {
    final contract = (json['contract'] as Map?)?.cast<String, dynamic>() ?? const {};
    return WearableTaskDetail(
      taskId: (contract['taskId'] ?? '') as String,
      role: (contract['role'] ?? 'main') as String,
      status: WearableTaskStatus.fromWire(json['status']),
      createdAt: (contract['createdAt'] as num?)?.toInt() ?? 0,
      response: json['response'] as String?,
      prompt: contract['prompt'] as String?,
      pendingInput: WearablePendingInput.fromJson((json['pendingInput'] as Map?)?.cast<String, dynamic>()),
      children: ((json['children'] as List?) ?? const [])
          .cast<Map<dynamic, dynamic>>()
          .map((e) => WearableChildTask.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
      artifacts: ((json['artifacts'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => WearableTaskArtifact.fromJson(e.cast<String, dynamic>()))
          .where((artifact) => artifact.path.isNotEmpty)
          .toList(growable: false),
      driveLinks: ((json['driveLinks'] as List?) ?? const [])
          .whereType<String>()
          .where((link) {
            final uri = Uri.tryParse(link);
            return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
          })
          .toList(growable: false),
    );
  }
}
