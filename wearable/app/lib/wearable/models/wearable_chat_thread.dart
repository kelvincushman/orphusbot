// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableChatThread + WearableChatHistoryMessage — Dart mirrors of the M-2.3
// thread-list and thread-history server payloads. Used by the boardroom
// side-sheet to surface past CoS conversations and switch the active
// thread.
//
// Wire format mirrors `database.listThreads` and `database.threadMessages`
// in src/db.ts. Both are read-only views of the SQLite sessions/turns
// tables — keep field names exactly aligned.

import 'package:flutter/foundation.dart';

/// Acknowledgement returned by `POST /api/chat?stream=1`.
///
/// The reply text still arrives asynchronously, but retaining [taskId] lets
/// the mobile client recover through task detail when the SSE envelope is
/// missed or evicted from the replay ring.
@immutable
class WearableChatSendReceipt {
  final String chatId;
  final String? taskId;

  const WearableChatSendReceipt({required this.chatId, this.taskId});

  factory WearableChatSendReceipt.fromJson(Map<String, dynamic> json, {required String fallbackChatId}) {
    final rawTaskId = json['taskId'];
    return WearableChatSendReceipt(
      chatId: json['chatId'] as String? ?? fallbackChatId,
      taskId: rawTaskId is String && rawTaskId.isNotEmpty ? rawTaskId : null,
    );
  }
}

/// One row in the boardroom thread list.
@immutable
class WearableChatThread {
  /// Stable per-chat id (`web:<uuid>` shape). Used for both routing the
  /// SSE stream and PUTting / GETting per-thread state.
  final String chatId;
  final String channel;
  final String? businessId;

  /// Wall-clock ms of the last turn in this thread.
  final DateTime lastActivity;
  final int turnCount;

  /// First line of the most recent turn — already truncated server-side
  /// in the SQL projection. Null only when the row is malformed.
  final String? lastContent;

  /// 'user' | 'assistant' | 'system' | 'tool'. The side-sheet uses this
  /// to prefix the preview with "You: …" vs the assistant's reply.
  final String? lastRole;

  const WearableChatThread({
    required this.chatId,
    required this.channel,
    required this.lastActivity,
    required this.turnCount,
    this.businessId,
    this.lastContent,
    this.lastRole,
  });

  static WearableChatThread fromJson(Map<String, dynamic> j) {
    return WearableChatThread(
      chatId: j['chatId'] as String? ?? '',
      channel: j['channel'] as String? ?? '',
      businessId: j['businessId'] as String?,
      lastActivity: DateTime.fromMillisecondsSinceEpoch((j['lastActivity'] as num?)?.toInt() ?? 0),
      turnCount: (j['turnCount'] as num?)?.toInt() ?? 0,
      lastContent: j['lastContent'] as String?,
      lastRole: j['lastRole'] as String?,
    );
  }
}

/// One historical turn returned by GET /api/chat/threads/:id/messages.
@immutable
class WearableChatHistoryMessage {
  final String id;

  /// Server roles: 'user' | 'assistant' | 'system' | 'tool'. The chat
  /// provider only renders user/assistant; system/tool are filtered out.
  final String role;
  final String content;
  final DateTime createdAt;

  const WearableChatHistoryMessage({required this.id, required this.role, required this.content, required this.createdAt});

  static WearableChatHistoryMessage fromJson(Map<String, dynamic> j) {
    return WearableChatHistoryMessage(
      id: j['id'] as String? ?? '',
      role: j['role'] as String? ?? '',
      content: j['content'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num?)?.toInt() ?? 0),
    );
  }
}
