// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableChatEvent — Dart mirror of the server's `ChatEvent` discriminated union
// (src/harness/chat-bus.ts). Consumed by WearableClient.chatStream() and the
// WearableChatProvider. Each variant carries the same field shape the server
// emits as the SSE `data:` JSON payload.
//
// Wire-format note: the SSE `event:` field carries the same string as the
// JSON payload's `type` field — we read the JSON because it's
// self-describing, but the SSE event name is a convenient pre-parse hint
// the dispatcher can use to skip unknown variants without parsing.
//
// Adding a new variant: add a subclass below + a parser branch in
// `WearableChatEvent.fromJson`. The server-side union in chat-bus.ts is the
// source of truth — keep field names exactly aligned (snake_case is NOT
// used; the wire is camelCase by JSON.stringify default behaviour).

import 'dart:convert';

sealed class WearableChatEvent {
  /// Wall-clock millis from the server. Use for ordering, not for
  /// duration arithmetic — drift between client/server is unbounded.
  final int ts;
  const WearableChatEvent({required this.ts});

  /// Parse a single SSE `data:` JSON payload. Returns null for unknown
  /// `type` values so the caller can ignore future variants without
  /// crashing — defensive against server-side schema additions during a
  /// staged rollout.
  static WearableChatEvent? fromJson(Map<String, dynamic> j) {
    final type = j['type'];
    if (type is! String) return null;
    switch (type) {
      case 'assistant_message':
        return WearableAssistantMessageEvent(
          taskId: j['taskId'] as String? ?? '',
          parentTaskId: j['parentTaskId'] as String?,
          text: j['text'] as String? ?? '',
          isSynthesisReentry: j['isSynthesisReentry'] as bool? ?? false,
          ts: (j['ts'] as num?)?.toInt() ?? 0,
        );
      case 'delegation_started':
        final raw = (j['children'] as List<dynamic>? ?? const []).cast<dynamic>();
        final children = raw
            .whereType<Map<dynamic, dynamic>>()
            .map((c) => WearableDelegationChild(role: c['role'] as String? ?? '', subtask: c['subtask'] as String? ?? ''))
            .toList(growable: false);
        return WearableDelegationStartedEvent(
          parentTaskId: j['parentTaskId'] as String? ?? '',
          children: children,
          ts: (j['ts'] as num?)?.toInt() ?? 0,
        );
      case 'child_done':
        return WearableChildDoneEvent(
          parentTaskId: j['parentTaskId'] as String? ?? '',
          childTaskId: j['childTaskId'] as String? ?? '',
          role: j['role'] as String? ?? '',
          ok: j['ok'] as bool? ?? false,
          ts: (j['ts'] as num?)?.toInt() ?? 0,
        );
      case 'asked_user':
        return WearableAskedUserEvent(
          taskId: j['taskId'] as String? ?? '',
          parentTaskId: j['parentTaskId'] as String?,
          question: j['question'] as String? ?? '',
          ts: (j['ts'] as num?)?.toInt() ?? 0,
        );
      case 'dispatch_failed':
        return WearableDispatchFailedEvent(
          taskId: j['taskId'] as String? ?? '',
          failureSignal: j['failureSignal'] as String? ?? 'unknown',
          detail: j['detail'] as String?,
          ts: (j['ts'] as num?)?.toInt() ?? 0,
        );
      case 'error':
        return WearableErrorEvent(message: j['message'] as String? ?? 'unknown error', ts: (j['ts'] as num?)?.toInt() ?? 0);
      default:
        return null;
    }
  }

  /// Convenience wrapper that decodes JSON and dispatches to fromJson.
  static WearableChatEvent? tryDecode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      return WearableChatEvent.fromJson(j);
    } catch (_) {
      return null;
    }
  }
}

class WearableAssistantMessageEvent extends WearableChatEvent {
  final String taskId;
  final String? parentTaskId;
  final String text;

  /// True when this message is the synthesised follow-up to an auto-delegating
  /// turn. The chat UI uses this to thread the bubble under the original ask
  /// (rather than as a fresh top-level message).
  final bool isSynthesisReentry;

  const WearableAssistantMessageEvent({
    required this.taskId,
    this.parentTaskId,
    required this.text,
    required this.isSynthesisReentry,
    required super.ts,
  });
}

class WearableDelegationChild {
  final String role;
  final String subtask;
  const WearableDelegationChild({required this.role, required this.subtask});
}

class WearableDelegationStartedEvent extends WearableChatEvent {
  final String parentTaskId;
  final List<WearableDelegationChild> children;

  const WearableDelegationStartedEvent({required this.parentTaskId, required this.children, required super.ts});
}

class WearableChildDoneEvent extends WearableChatEvent {
  final String parentTaskId;
  final String childTaskId;
  final String role;
  final bool ok;

  const WearableChildDoneEvent({
    required this.parentTaskId,
    required this.childTaskId,
    required this.role,
    required this.ok,
    required super.ts,
  });
}

class WearableAskedUserEvent extends WearableChatEvent {
  final String taskId;
  final String? parentTaskId;
  final String question;

  const WearableAskedUserEvent({required this.taskId, this.parentTaskId, required this.question, required super.ts});
}

class WearableDispatchFailedEvent extends WearableChatEvent {
  final String taskId;
  final String failureSignal;
  final String? detail;

  const WearableDispatchFailedEvent({required this.taskId, required this.failureSignal, this.detail, required super.ts});
}

class WearableErrorEvent extends WearableChatEvent {
  final String message;
  const WearableErrorEvent({required this.message, required super.ts});
}

/// One frame the SSE parser yields. Only one of [event] or [keepalive] is set
/// per frame — keepalives let the provider reset its connection-stale timer
/// without needing to wait for a real event.
class WearableChatFrame {
  /// Server-assigned monotone id for use with `since=` on reconnect. Null
  /// only for keepalives.
  final int? id;
  final WearableChatEvent? event;
  final bool keepalive;

  const WearableChatFrame({this.id, this.event, this.keepalive = false});

  factory WearableChatFrame.heartbeat() => const WearableChatFrame(keepalive: true);
}
