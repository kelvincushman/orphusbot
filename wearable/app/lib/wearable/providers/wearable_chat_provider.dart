// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableChatProvider — owns the Boardroom chat thread.
//
// Responsibilities:
//   - Holds the per-install chatId (lazy-minted, persisted to
//     SharedPreferences) so Karpathy memory threads correctly across app
//     launches.
//   - Subscribes to WearableClient.chatStream() and aggregates events into
//     two indexed views the UI consumes:
//       * messages   — ordered chat bubbles (user + assistant)
//       * delegations — parentTaskId → DelegationSnapshot, used by the
//         in-thread TaskChip widget (M-2.4)
//   - Reconnects with linear backoff on disconnect, resuming via `sinceId`
//     so events that fired during the gap are not missed (server keeps a
//     50-event ring per chatId).
//   - sendMessage(text) appends a local user bubble immediately, then fires
//     POST /api/chat?stream=1 fire-and-forget. The assistant reply (and any
//     delegation/child events) flow back through the SSE subscription.
//
// Karpathy guideline 2 — simplicity. This provider deliberately does NOT
// expose connection-status enums or retry counts to the UI. The status
// surface is just: "are we connected" boolean + last error string.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/wearable_chat_event.dart';
import '../models/wearable_chat_thread.dart';
import '../models/wearable_task.dart';
import '../wearable_client.dart';

/// One bubble in the chat list.
@immutable
class WearableChatMessage {
  /// Stable per-bubble id. For user bubbles this is a local uuid; for
  /// assistant bubbles this is the server-assigned taskId. Used as the
  /// Flutter list key — when an assistant bubble updates (e.g. synthesis
  /// follow-up) we replace by id rather than appending a duplicate.
  final String id;
  final WearableChatSender sender;
  final String text;
  final DateTime ts;

  /// Set on assistant bubbles that are the synthesis follow-up to a
  /// delegating turn. The UI uses this to thread under the original ask
  /// (visually subordinate, smaller margin) rather than as a fresh reply.
  final String? parentTaskId;
  final bool isSynthesisReentry;

  /// True when this bubble represents an `asked_user` pause rather than a
  /// completed assistant response.
  final bool requiresReply;

  const WearableChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.ts,
    this.parentTaskId,
    this.isSynthesisReentry = false,
    this.requiresReply = false,
  });
}

enum WearableChatSender { user, assistant }

/// State of one CoS auto-delegation fan-out, attached to its parent message
/// for TaskChip rendering.
@immutable
class WearableDelegationSnapshot {
  final String parentTaskId;
  final List<WearableDelegationChild> children;

  /// role → completion record. Absent means still in-flight.
  final Map<String, WearableChildCompletion> completedByRole;
  final DateTime startedAt;

  const WearableDelegationSnapshot({
    required this.parentTaskId,
    required this.children,
    required this.completedByRole,
    required this.startedAt,
  });

  bool get allDone => completedByRole.length >= children.length;

  WearableDelegationSnapshot withChildDone(String role, WearableChildCompletion comp) {
    final next = Map<String, WearableChildCompletion>.from(completedByRole);
    next[role] = comp;
    return WearableDelegationSnapshot(
      parentTaskId: parentTaskId,
      children: children,
      // Map.unmodifiable enforces the @immutable contract at runtime so a
      // consumer that gets the snapshot via delegationFor() can't mutate
      // the source state by reaching into completedByRole.
      completedByRole: Map.unmodifiable(next),
      startedAt: startedAt,
    );
  }
}

@immutable
class WearableChildCompletion {
  final String childTaskId;
  final bool ok;
  final DateTime ts;
  const WearableChildCompletion({required this.childTaskId, required this.ok, required this.ts});
}

class WearableChatProvider extends ChangeNotifier {
  WearableChatProvider({
    WearableChatApi? client,
    @visibleForTesting String? chatIdOverride,
    @visibleForTesting List<Duration>? taskRecoveryDelays,
  }) : _client = client ?? WearableClient.instance,
       _chatIdOverride = chatIdOverride,
       _taskRecoveryDelays = List.unmodifiable(taskRecoveryDelays ?? _defaultTaskRecoveryDelays);

  final WearableChatApi _client;
  final String? _chatIdOverride;
  final List<Duration> _taskRecoveryDelays;

  /// Single-flight gate for ensureChatId — without this two concurrent
  /// callers (e.g. connect() racing with sendMessage()) could each read
  /// SharedPreferences as null and mint two different ids; the second
  /// write to prefs wins, and the first caller holds a stale id in memory.
  Completer<String>? _chatIdInflight;

  static const _prefsKey = 'wearable.chatId';
  static const _initialBackoff = Duration(seconds: 2);
  static const _maxBackoff = Duration(seconds: 30);

  /// After this many consecutive reconnect attempts without a single
  /// successful frame OR keepalive, stop auto-retrying. Prevents a
  /// permanently-offline device from waking on the 30s cadence forever
  /// (a measured battery cost on iOS over a long airplane-mode window).
  /// resumeReconnect() — bound to the page's app-lifecycle observer —
  /// clears the latch when the user foregrounds the app.
  static const _maxConsecutiveReconnects = 10;

  /// Hard cap on in-memory chat bubbles. The server keeps full history;
  /// trimming the oldest preserves the recent conversation surface
  /// without an unbounded leak across long-lived threads. Picked above
  /// the 200-row server page so a freshly-loaded thread never trims.
  static const _maxMessages = 500;

  /// Five-minute bounded fallback for replies lost from the in-memory SSE
  /// replay ring. Task detail is durable, so this is a recovery path rather
  /// than a second primary transport.
  static const _defaultTaskRecoveryDelays = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];

  String? _chatId;
  String? get chatId => _chatId;

  bool _connected = false;
  bool get connected => _connected;

  String? _lastError;
  String? get lastError => _lastError;

  bool _disposed = false;

  // Append-only list of bubbles. Flutter list views key on .id so updates
  // (synthesis follow-up replacing a delegation bubble) are reordered
  // cheaply.
  final List<WearableChatMessage> _messages = [];
  List<WearableChatMessage> get messages => List.unmodifiable(_messages);

  final Map<String, WearableDelegationSnapshot> _delegations = {};
  final Set<String> _knownHistoryIds = {};

  Future<void>? _historyHydration;
  String? _hydratingChatId;

  final Set<String> _pendingTaskIds = {};
  final Map<String, Timer> _taskRecoveryTimers = {};

  /// Lookup for the in-thread TaskChip widget. Returns null if this message
  /// did not produce a delegation fan-out.
  WearableDelegationSnapshot? delegationFor(String parentTaskId) => _delegations[parentTaskId];

  // Reconnect bookkeeping.
  StreamSubscription<WearableChatFrame>? _streamSub;
  int _lastSeenId = 0;
  Duration _backoff = _initialBackoff;
  Timer? _reconnectTimer;

  /// Increments on every disconnect; resets on the first frame OR
  /// keepalive after a (re)connect. When this hits
  /// _maxConsecutiveReconnects we stop the auto-retry loop and set
  /// _circuitOpen — caller (UI) calls resumeReconnect() on a
  /// foreground-lifecycle event to clear the latch.
  int _reconnectAttempts = 0;
  bool _circuitOpen = false;
  bool get circuitOpen => _circuitOpen;

  /// Mints (if absent) and returns the persisted chatId. Stable across
  /// app launches — see _prefsKey. Format mirrors the server's chatId
  /// regex (`web:<uuid>` shape).
  ///
  /// Single-flight: concurrent callers share a single Completer so the
  /// mint+persist sequence runs once. Without this, connect() and the
  /// first sendMessage() can both read prefs as null in parallel, mint
  /// two UUIDs, and one write loses — the loser ends up holding a chatId
  /// that doesn't match the persisted one.
  Future<String> ensureChatId() async {
    final override = _chatIdOverride;
    if (override != null && override.isNotEmpty) {
      _chatId = override;
      return override;
    }
    if (_chatId != null) return _chatId!;
    final inflight = _chatIdInflight;
    if (inflight != null) return inflight.future;
    final completer = Completer<String>();
    _chatIdInflight = completer;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_prefsKey);
      if (id == null || id.isEmpty) {
        id = 'web:${const Uuid().v4()}';
        await prefs.setString(_prefsKey, id);
      }
      _chatId = id;
      completer.complete(id);
      return id;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _chatIdInflight = null;
    }
  }

  /// Subscribe to the chat event stream. Idempotent — a second call while
  /// already connected is a no-op. Caller normally invokes this from
  /// initState or via a Provider that auto-attaches.
  Future<void> connect() async {
    if (_disposed) return;
    if (_streamSub != null) return;
    final id = await ensureChatId();
    _attach(id);
    await _hydrateCurrentThread(id);
  }

  void _attach(String chatId) {
    if (_disposed) return;
    if (_circuitOpen) return; // breaker tripped — wait for resumeReconnect
    _streamSub?.cancel();
    _streamSub = null;
    final stream = _client.chatStream(chatId, sinceId: _lastSeenId > 0 ? _lastSeenId : null);
    _streamSub = stream.listen(
      _handleFrame,
      onError: _handleStreamError,
      onDone: _handleStreamDone,
      cancelOnError: false,
    );
    // Stream is "live" once we've subscribed — we don't get a synthetic
    // "open" frame so flip the flag here. Keepalive frames will keep it
    // truthful until the next disconnect.
    _connected = true;
    _lastError = null;
    notifyListeners();
  }

  /// Manual breaker reset. Call from the page's app-lifecycle observer
  /// when the user foregrounds the app — clears the latch and tries one
  /// fresh connect immediately, with attempt counter reset so a real
  /// outage doesn't wedge the breaker on the next round.
  void resumeReconnect() {
    if (_disposed) return;
    if (!_circuitOpen) return;
    _circuitOpen = false;
    _reconnectAttempts = 0;
    _backoff = _initialBackoff;
    _lastError = null;
    notifyListeners();
    if (_chatId != null) {
      _attach(_chatId!);
      unawaited(_hydrateCurrentThread(_chatId!));
    }
  }

  void _handleFrame(WearableChatFrame frame) {
    // Dispose race guard: a frame buffered inside the StreamSubscription's
    // internal queue can still arrive after dispose() cancels the sub.
    // Calling notifyListeners() on a disposed ChangeNotifier asserts in
    // debug mode and silently leaks state in release.
    if (_disposed) return;
    if (frame.keepalive) {
      // Heartbeat — server is alive. Reset backoff so the next disconnect
      // reconnects fast, and reset the reconnect-attempt counter so the
      // circuit-breaker doesn't trip after a series of brief network
      // hiccups punctuated by successful keepalives.
      _backoff = _initialBackoff;
      _reconnectAttempts = 0;
      return;
    }
    final ev = frame.event;
    if (ev == null) return;
    // Any real frame is also a healthy-connection signal — reset the
    // breaker counter on first delivery after a (re)connect.
    _reconnectAttempts = 0;
    if (frame.id != null && frame.id! > _lastSeenId) {
      _lastSeenId = frame.id!;
    }
    switch (ev) {
      case WearableAssistantMessageEvent e:
        _ingestAssistant(e);
        break;
      case WearableDelegationStartedEvent e:
        _delegations[e.parentTaskId] = WearableDelegationSnapshot(
          parentTaskId: e.parentTaskId,
          children: e.children,
          completedByRole: const {},
          startedAt: DateTime.fromMillisecondsSinceEpoch(e.ts),
        );
        notifyListeners();
        break;
      case WearableChildDoneEvent e:
        final snap = _delegations[e.parentTaskId];
        if (snap != null) {
          _delegations[e.parentTaskId] = snap.withChildDone(
            e.role,
            WearableChildCompletion(childTaskId: e.childTaskId, ok: e.ok, ts: DateTime.fromMillisecondsSinceEpoch(e.ts)),
          );
          notifyListeners();
        }
        break;
      case WearableAskedUserEvent e:
        _ingestAskedUser(e);
        break;
      case WearableDispatchFailedEvent e:
        _ingestDispatchFailure(e);
        break;
      case WearableErrorEvent e:
        // Belt-and-suspenders: cap server-supplied error text. Server is
        // supposed to emit only sanitised strings, but if a misconfigured
        // error path leaks bearer/file path info we don't pin the entire
        // string to UI state where it could reach a screenshot or share.
        final raw = e.message;
        _lastError = raw.length > 200 ? raw.substring(0, 200) : raw;
        notifyListeners();
        break;
    }
  }

  /// Dismiss any error banner currently displayed. Bound to the banner's
  /// close affordance so the user can clear stale errors.
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  void _ingestAssistant(WearableAssistantMessageEvent e) {
    _stopTaskRecovery(e.taskId);
    final id = e.taskId.isNotEmpty ? e.taskId : const Uuid().v4();
    final bubble = WearableChatMessage(
      id: id,
      sender: WearableChatSender.assistant,
      text: e.text,
      ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
      parentTaskId: e.parentTaskId,
      isSynthesisReentry: e.isSynthesisReentry,
    );
    // Replace by id when the same taskId arrives again (e.g. server retries).
    final existing = _messages.indexWhere((m) => m.id == id);
    if (existing >= 0) {
      _messages[existing] = bubble;
    } else {
      _messages.add(bubble);
      _trimMessagesIfNeeded();
    }
    notifyListeners();
  }

  void _ingestAskedUser(WearableAskedUserEvent e) {
    _stopTaskRecovery(e.taskId);
    final id = e.taskId.isNotEmpty ? e.taskId : const Uuid().v4();
    final bubble = WearableChatMessage(
      id: id,
      sender: WearableChatSender.assistant,
      text: e.question,
      ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
      parentTaskId: e.parentTaskId,
      requiresReply: true,
    );
    final existing = _messages.indexWhere((m) => m.id == id);
    if (existing >= 0) {
      _messages[existing] = bubble;
    } else {
      _messages.add(bubble);
      _trimMessagesIfNeeded();
    }
    notifyListeners();
  }

  void _ingestDispatchFailure(WearableDispatchFailedEvent e) {
    _stopTaskRecovery(e.taskId);
    final detail = e.detail?.trim();
    final raw = detail == null || detail.isEmpty
        ? 'Task failed (${e.failureSignal}).'
        : 'Task failed (${e.failureSignal}): $detail';
    _lastError = raw.length > 200 ? raw.substring(0, 200) : raw;
    notifyListeners();
  }

  /// Cap in-memory bubble count at _maxMessages. Server retains full
  /// history; this only constrains the live working set so a long-lived
  /// thread can't grow unbounded after weeks of daily use. Trims oldest
  /// first — newest content is what the user is actively engaged with.
  void _trimMessagesIfNeeded() {
    final overflow = _messages.length - _maxMessages;
    if (overflow > 0) _messages.removeRange(0, overflow);
  }

  Future<void> _hydrateCurrentThread(String chatId) async {
    final inflight = _historyHydration;
    if (inflight != null && _hydratingChatId == chatId) {
      await inflight;
      return;
    }

    final hydration = _fetchAndMergeHistory(chatId);
    _hydratingChatId = chatId;
    _historyHydration = hydration;
    try {
      await hydration;
    } finally {
      if (identical(_historyHydration, hydration)) {
        _historyHydration = null;
        _hydratingChatId = null;
      }
    }
  }

  Future<void> _fetchAndMergeHistory(String chatId) async {
    try {
      final history = await _client.getThreadMessages(chatId);
      if (_disposed || _chatId != chatId) return;
      _mergeHistory(history);
    } catch (_) {
      // The live stream can still succeed. A later reconnect retries this
      // durable history read, so do not replace a useful stream error with a
      // second transient banner.
    }
  }

  void _mergeHistory(List<WearableChatHistoryMessage> history, {bool replace = false}) {
    if (replace) {
      _messages.clear();
      _knownHistoryIds.clear();
    }

    final matchedMessageIndexes = <int>{};
    var changed = false;
    for (final turn in history) {
      if (turn.role != 'user' && turn.role != 'assistant') continue;
      if (_knownHistoryIds.contains(turn.id)) continue;

      final sender = turn.role == 'user' ? WearableChatSender.user : WearableChatSender.assistant;
      var existing = _messages.indexWhere((m) => m.id == turn.id);
      if (existing < 0) {
        // Optimistic user bubbles and pre-correlation server versions can use
        // a different id for the same durable turn. Reconcile one-to-one by
        // sender/content and a tight timestamp window, then remember the
        // durable id so later reconnects remain idempotent.
        existing = _messages.indexWhere((m) {
          if (matchedMessageIndexes.contains(_messages.indexOf(m))) return false;
          final delta = m.ts.millisecondsSinceEpoch - turn.createdAt.millisecondsSinceEpoch;
          return m.sender == sender &&
              m.text == turn.content &&
              delta.abs() <= const Duration(minutes: 2).inMilliseconds;
        });
      }

      _knownHistoryIds.add(turn.id);
      if (existing >= 0) {
        matchedMessageIndexes.add(existing);
        continue;
      }

      _messages.add(WearableChatMessage(id: turn.id, sender: sender, text: turn.content, ts: turn.createdAt));
      changed = true;
    }

    if (!changed) return;
    _messages.sort((a, b) => a.ts.compareTo(b.ts));
    _trimMessagesIfNeeded();
    notifyListeners();
  }

  /// Retain the task correlation returned by the streaming POST and start a
  /// bounded durable fallback. Safe to call for attachment sends as well as
  /// the provider's normal text path.
  void trackSendReceipt(WearableChatSendReceipt receipt) {
    final taskId = receipt.taskId;
    if (_disposed || taskId == null || taskId.isEmpty) return;
    if (_chatId != null && receipt.chatId != _chatId) return;
    if (!_pendingTaskIds.add(taskId)) return;
    _scheduleTaskRecovery(taskId, 0);
  }

  void _scheduleTaskRecovery(String taskId, int attempt) {
    if (_disposed || !_pendingTaskIds.contains(taskId)) return;
    if (attempt >= _taskRecoveryDelays.length) {
      _taskRecoveryTimers.remove(taskId)?.cancel();
      _pendingTaskIds.remove(taskId);
      return;
    }
    _taskRecoveryTimers.remove(taskId)?.cancel();
    _taskRecoveryTimers[taskId] = Timer(_taskRecoveryDelays[attempt], () => unawaited(_recoverTask(taskId, attempt)));
  }

  Future<void> _recoverTask(String taskId, int attempt) async {
    if (_disposed || !_pendingTaskIds.contains(taskId)) return;
    _taskRecoveryTimers.remove(taskId);
    try {
      final detail = await _client.getTaskDetail(taskId);
      if (_disposed || !_pendingTaskIds.contains(taskId)) return;
      switch (detail.status) {
        case WearableTaskStatus.completed:
          final response = detail.response?.trim();
          if (response != null && response.isNotEmpty) {
            _ingestAssistant(
              WearableAssistantMessageEvent(
                taskId: taskId,
                text: response,
                isSynthesisReentry: false,
                ts: DateTime.now().millisecondsSinceEpoch,
              ),
            );
            return;
          }
          break;
        case WearableTaskStatus.pendingInput:
          final pending = detail.pendingInput;
          if (pending != null) {
            _ingestAskedUser(
              WearableAskedUserEvent(
                taskId: taskId,
                question: pending.question,
                ts: pending.askedAt ?? DateTime.now().millisecondsSinceEpoch,
              ),
            );
            return;
          }
          break;
        case WearableTaskStatus.failed:
          _ingestDispatchFailure(
            WearableDispatchFailedEvent(
              taskId: taskId,
              failureSignal: 'unknown',
              detail: 'The task ended before its live reply arrived.',
              ts: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          return;
        case WearableTaskStatus.active:
        case WearableTaskStatus.awaitingChildren:
        case WearableTaskStatus.unknown:
          break;
      }
    } catch (_) {
      // A task can briefly 404 between the accepted POST and creation of its
      // run directory. Treat transport and early-read failures as retryable.
    }
    _scheduleTaskRecovery(taskId, attempt + 1);
  }

  void _stopTaskRecovery(String taskId) {
    if (taskId.isEmpty) return;
    _pendingTaskIds.remove(taskId);
    _taskRecoveryTimers.remove(taskId)?.cancel();
  }

  void _cancelAllTaskRecovery() {
    for (final timer in _taskRecoveryTimers.values) {
      timer.cancel();
    }
    _taskRecoveryTimers.clear();
    _pendingTaskIds.clear();
  }

  void _handleStreamError(Object err, [StackTrace? st]) {
    _connected = false;
    // Status-only: never echo `err.toString()` directly into UI. SocketException
    // and similar can carry the host:port; fine for debug, but we want a clean
    // surface for users.
    if (err is SocketException) {
      _lastError = 'Connection lost — reconnecting…';
    } else if (chatStreamMissing(err)) {
      // A server without chat (OrphusBot keeps its chats in its own app):
      // say so once, and don't retry something that isn't there.
      _circuitOpen = true;
      _lastError = noChatHere;
      notifyListeners();
      return;
    } else {
      _lastError = 'Chat stream error — reconnecting…';
    }
    notifyListeners();
    _scheduleReconnect();
  }

  void _handleStreamDone() {
    _connected = false;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_chatId == null) return;
    // Circuit breaker: after enough consecutive failed reconnects with
    // no healthy frame in between, latch open and stop retrying. The UI
    // surfaces a tap-to-retry banner; resumeReconnect() (driven by the
    // page's app-lifecycle observer when the user foregrounds) clears
    // the latch. Prevents a permanently-offline device from waking on
    // the 30s cadence indefinitely.
    _reconnectAttempts++;
    if (_reconnectAttempts >= _maxConsecutiveReconnects) {
      _circuitOpen = true;
      _lastError = 'Server unreachable — pull to retry.';
      notifyListeners();
      return;
    }
    _reconnectTimer?.cancel();
    final delay = _backoff;
    _reconnectTimer = Timer(delay, () {
      if (_disposed || _chatId == null) return;
      _attach(_chatId!);
      unawaited(_hydrateCurrentThread(_chatId!));
    });
    final nextSeconds = (_backoff.inSeconds * 2).clamp(_initialBackoff.inSeconds, _maxBackoff.inSeconds);
    _backoff = Duration(seconds: nextSeconds);
  }

  /// Append a local user bubble without posting to the server. Use this when
  /// another path (e.g. [WearableClient.sendChatMessageWithAttachments]) is
  /// responsible for the server POST so the message is not sent twice.
  ///
  /// [attachmentCount] is informational — the bubble text is used as-is;
  /// callers may append an attachment indicator to [text] before calling.
  Future<void> addLocalUserBubble(String text, {int attachmentCount = 0}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachmentCount == 0) return;
    // Ensure chatId is minted before appending so the thread is consistent
    // with whatever the server will echo back on the next SSE frame.
    await ensureChatId();
    _messages.add(
      WearableChatMessage(id: const Uuid().v4(), sender: WearableChatSender.user, text: trimmed, ts: DateTime.now()),
    );
    _trimMessagesIfNeeded();
    notifyListeners();
  }

  /// Append a user bubble locally and fire the message at the server. The
  /// assistant reply arrives asynchronously via the chat stream.
  Future<void> sendMessage(String text, {String? businessId}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final id = await ensureChatId();
    final pendingQuestionIndex = _messages.lastIndexWhere(
      (message) => message.sender == WearableChatSender.assistant && message.requiresReply,
    );
    final pendingTaskId = pendingQuestionIndex >= 0 ? _messages[pendingQuestionIndex].id : null;
    _messages.add(
      WearableChatMessage(id: const Uuid().v4(), sender: WearableChatSender.user, text: trimmed, ts: DateTime.now()),
    );
    _trimMessagesIfNeeded();
    notifyListeners();
    try {
      if (pendingTaskId != null) {
        await _client.replyToTask(pendingTaskId, trimmed);
        final currentQuestionIndex = _messages.indexWhere(
          (message) => message.id == pendingTaskId && message.requiresReply,
        );
        if (currentQuestionIndex >= 0) {
          final question = _messages[currentQuestionIndex];
          _messages[currentQuestionIndex] = WearableChatMessage(
            id: question.id,
            sender: question.sender,
            text: question.text,
            ts: question.ts,
            parentTaskId: question.parentTaskId,
            isSynthesisReentry: question.isSynthesisReentry,
          );
          notifyListeners();
        }
        if (_pendingTaskIds.add(pendingTaskId)) {
          _scheduleTaskRecovery(pendingTaskId, 0);
        }
        return;
      }

      final receipt = await _client.sendChatMessageStreaming(message: trimmed, chatId: id, businessId: businessId);
      trackSendReceipt(receipt);
    } catch (e) {
      // Surface a generic error bubble — user can retry. Don't tear down
      // the SSE stream; assistant reply may still arrive if the post
      // partially succeeded server-side.
      _lastError = 'Send failed — please retry.';
      notifyListeners();
    }
  }

  /// Switch the active boardroom thread to [chatId]. Loads server-side
  /// history, replaces the in-memory message list, and reconnects the
  /// SSE stream against the new chatId. Persists the new id in prefs so
  /// the choice survives app restart.
  ///
  /// Used by the M-2.3 side-sheet — tapping a past thread switches the
  /// chat surface in place. Subsequent sends post to the new chatId; the
  /// reply arrives via the new SSE subscription.
  ///
  /// Failure modes preserved: if the prefs write throws, we re-attach
  /// the OLD subscription rather than leaving the chat surface dead.
  Future<void> loadThread(String chatId) async {
    if (_disposed) return;
    if (_chatId == chatId) return; // already on this thread

    // Snapshot the previous chatId before any teardown so we can roll
    // back if the prefs write fails downstream.
    final previousChatId = _chatId;

    // Tear down the existing subscription + reconnect timer. AWAIT the
    // cancel so the old StreamSubscription has fully drained — without
    // the await, a frame already in the controller's internal queue
    // can still fire and contaminate the new thread's bubble list.
    await _streamSub?.cancel();
    if (_disposed) return;
    _streamSub = null;
    _reconnectTimer?.cancel();
    _connected = false;

    // Persist the new chatId so a cold restart resumes here. If this
    // throws (low-memory platform-channel failure, unlikely but real)
    // we restore the old subscription rather than leaving the user on
    // a dead chat surface.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, chatId);
    } catch (_) {
      if (_disposed) return;
      _lastError = 'Could not switch thread — please try again.';
      notifyListeners();
      if (previousChatId != null) _attach(previousChatId);
      return;
    }
    if (_disposed) return;
    _chatId = chatId;

    // Replace the bubble list with the server's history. System/tool
    // turns are filtered out — only user/assistant render in the UI.
    _messages.clear();
    _delegations.clear();
    _knownHistoryIds.clear();
    _cancelAllTaskRecovery();
    _lastSeenId = 0;
    _lastError = null;
    notifyListeners();

    try {
      final history = await _client.getThreadMessages(chatId);
      if (_disposed) return;
      _mergeHistory(history, replace: true);
    } catch (_) {
      if (_disposed) return;
      _lastError = 'Could not load thread history.';
      notifyListeners();
    }

    // Re-attach SSE so any new server activity flows in. We pass
    // sinceId:0 so the server's ring-buffer replay is bounded to
    // anything published after this connect.
    if (_disposed) return;
    _attach(chatId);
  }

  /// Mint a fresh chatId and switch to it. Used by the "+" affordance
  /// in the side-sheet header.
  Future<String> newThread() async {
    if (_disposed) {
      throw StateError('Provider disposed');
    }
    final id = 'web:${const Uuid().v4()}';
    await loadThread(id);
    return id;
  }

  /// List recent threads for the side-sheet. Read-through to WearableClient;
  /// the provider doesn't cache here because the side-sheet rebuilds on
  /// open and we want fresh data each time.
  Future<List<WearableChatThread>> fetchThreads({int limit = 50}) {
    return _client.listThreads(limit: limit);
  }

  /// Drop the persisted chatId and clear in-memory state. Used by "start
  /// new conversation" affordance — the next connect() mints a fresh id.
  Future<void> resetThread() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    _chatId = null;
    _lastSeenId = 0;
    _messages.clear();
    _delegations.clear();
    _knownHistoryIds.clear();
    _cancelAllTaskRecovery();
    _lastError = null;
    notifyListeners();
    // Mirror loadThread: await the cancel so the old subscription's
    // queued frames can't bleed into a fresh connect that follows.
    await _streamSub?.cancel();
    if (_disposed) return;
    _streamSub = null;
    _reconnectTimer?.cancel();
    _connected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _streamSub?.cancel();
    _reconnectTimer?.cancel();
    _cancelAllTaskRecovery();
    super.dispose();
  }
}

/// Shown when the paired server has no chat stream.
const noChatHere =
    'This server has no chat here. Chat with your bots in the OrphusBot app; '
    'the button and your voice still work.';

/// Whether a chat stream error means the server has no chat at all (404/405).
bool chatStreamMissing(Object err) {
  final m = RegExp(r'chatStream failed \((\d+)\)').firstMatch('$err');
  return m != null && (m[1] == '404' || m[1] == '405');
}
