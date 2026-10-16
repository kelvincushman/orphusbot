// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// BoardroomPage — primary tab of the Wearable app (plan §5.3).
//
// Single-thread chat with the Chief of Staff agent. Messages stream over
// SSE from `/api/chat/stream`; user sends fire-and-forget through
// `/api/chat?stream=1`. CoS auto-delegation surfaces inline as a
// TaskChip strip below the parent message.
//
// Mic button (M-2.2): when a Wearable wearable is paired and reachable
// (WearableConnectionProvider reports `connected`), tapping the mic POSTs an
// `AGENT_REQUEST` button event. The wearable handles capture; the final
// transcript flows back via the device → intake() → SSE pipeline as a
// normal user turn. When no wearable is paired/reachable the mic is
// disabled with a tooltip — phone-mic-into-chat needs a chatId-scoped
// audio endpoint that doesn't exist yet, so it's deferred.
//
// Thread side-sheet (M-2.3): edge-swipe from the left OR tap the menu
// icon in the app bar → Drawer with the recent thread list. Tap a row
// → loadThread switches the chat surface in place. "+" header button
// mints a fresh chatId and clears the thread.
//
// The page intentionally does NOT use the upstream KelvinLee ChatPage. That page
// routes to KelvinLee cloud (Env.apiBaseUrl) which never sees Wearable's CoS turns;
// the M-1 wrapper that delegated to it has been removed in favour of this
// Wearable-native surface.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../chat/attachment_limits.dart';
import '../chat/slash_commands.dart';
import '../models/wearable_chat_event.dart';
import '../models/wearable_chat_thread.dart';
import '../wearable_client.dart';
import '../wearable_theme.dart';
import '../providers/wearable_chat_provider.dart';
import '../providers/wearable_connection_provider.dart';

/// Messages longer than this are sent as a .txt attachment instead of
/// inline text, to stay well under the server's 8 000-character body limit.
const int kInlineChatCharCap = 7000;

class BoardroomPage extends StatefulWidget {
  const BoardroomPage({super.key});

  @override
  State<BoardroomPage> createState() => _BoardroomPageState();
}

class _BoardroomPageState extends State<BoardroomPage> with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Drives the drawer programmatically — the leading menu icon + the
  /// edge-swipe both target this scaffold.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Bumped each time the drawer opens. The Drawer uses this as a
  /// FutureBuilder key so a fresh fetch fires on every open instead of
  /// once per Scaffold construction. Lazy: we don't hit the network at
  /// all until the user actually opens the side-sheet.
  int _drawerOpenCount = 0;

  /// Whether the user is currently parked near the bottom of the list. We
  /// only auto-scroll on new messages while this is true so a user scrolling
  /// up to read older content isn't yanked back down on every new SSE event.
  /// Threshold: within 80px of maxScrollExtent counts as "at bottom".
  bool _stickToBottom = true;

  /// Tracks the last message count we observed; the post-frame callback
  /// only nudges the scroll position when the count changed since last
  /// build, which prevents the unbounded auto-scroll loop the Consumer
  /// builder used to trigger on every notifyListeners().
  int _lastMessageCount = 0;

  /// Monotonic counter used to generate unique temp-file names for
  /// long-message attachments — avoids DateTime.now() which can collide
  /// on rapid sends and may be disallowed in some lint configurations.
  int _tmpCounter = 0;
  WearableChatProvider? _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    // Lazy-connect on first mount. Provider is registered at app root so
    // the connection survives tab switches inside the home shell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _provider = context.read<WearableChatProvider>();
      _provider!.connect();
      _provider!.addListener(_onProviderChange);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App foregrounded — clear the chat-stream circuit breaker (if
    // tripped during background) and let the provider try one fresh
    // connect. resumeReconnect is a no-op when the breaker isn't open.
    if (state == AppLifecycleState.resumed) {
      _provider?.resumeReconnect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _provider?.removeListener(_onProviderChange);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = (pos.maxScrollExtent - pos.pixels) < 80;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
    }
  }

  void _onProviderChange() {
    final p = _provider;
    if (p == null) return;
    final count = p.messages.length;
    if (count == _lastMessageCount) return;
    _lastMessageCount = count;
    if (!_stickToBottom) return;
    // Only schedule one post-frame nudge per actual message count change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _onSend({List<File> attachments = const []}) async {
    final text = _input.text.trim();
    if (text.isEmpty && attachments.isEmpty) return;
    _input.clear();
    // Sending implies the user is engaged with the latest content — opt
    // back into stick-to-bottom even if they scrolled up earlier.
    setState(() => _stickToBottom = true);
    final provider = _provider ?? context.read<WearableChatProvider>();

    // Long-message fallback: if the text exceeds the inline cap AND no
    // attachments were chosen by the user, wrap the full text in a .txt
    // file and route through the attachment path. This keeps the payload
    // under the server's 8 000-character / 16 KB body limit.
    if (attachments.isEmpty && text.length > kInlineChatCharCap) {
      await _sendAsTextAttachment(text, provider);
      return;
    }

    // If the user has real attachments AND the text is also over the cap,
    // add a text-file attachment alongside the existing files.
    var effectiveAttachments = attachments;
    if (attachments.isNotEmpty && text.length > kInlineChatCharCap) {
      final tmpFile = await _writeTempTextFile(text);
      if (tmpFile != null) {
        effectiveAttachments = [...attachments, tmpFile];
      }
    }

    // Slash-command check (text-only path — attachments bypass this).
    if (attachments.isEmpty) {
      final result = expandSlashCommand(text);
      if (result != null) {
        if (result.localAction == 'clear') {
          await provider.resetThread();
          return;
        }
        if (result.localAction == 'help') {
          _showHelpDialog();
          return;
        }
        // Prompt shortcut — expand then send.
        if (result.prompt != null) {
          await provider.sendMessage(result.prompt!);
          return;
        }
      }
      await provider.sendMessage(text);
      return;
    }

    // Attachment path — two-step upload then send. The local user bubble is
    // added ONCE here before the server call; the reply arrives via the
    // existing SSE subscription. We never call provider.sendMessage() for the
    // attachment branch to avoid double-posting.
    final messenger = ScaffoldMessenger.of(context);
    final bubbleText = text.isNotEmpty
        ? '$text [${effectiveAttachments.length} file${effectiveAttachments.length == 1 ? '' : 's'}]'
        : '[${effectiveAttachments.length} file${effectiveAttachments.length == 1 ? '' : 's'}]';
    await provider.addLocalUserBubble(bubbleText, attachmentCount: effectiveAttachments.length);
    try {
      final receipt = await WearableClient.instance.sendChatMessageWithAttachments(
        message: text,
        chatId: await provider.ensureChatId(),
        files: effectiveAttachments,
      );
      provider.trackSendReceipt(receipt);
      // Server post succeeded — SSE reply will arrive on the existing
      // subscription; nothing more needed here.
    } on ChatAttachmentServerException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't upload attachment(s): ${e.message}"),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't send with attachments: $e"),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Writes [text] to a uniquely-named temp file and returns it.
  /// Returns null if the write fails (caller should silently skip the
  /// attachment rather than crashing — the inline send will still fail
  /// with a 413 which the user can then see).
  Future<File?> _writeTempTextFile(String text) async {
    try {
      final dir = await getTemporaryDirectory();
      final name = 'wearable-message-${_tmpCounter++}.txt';
      final file = File('${dir.path}/$name');
      await file.writeAsString(text);
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Sends [text] as a .txt attachment when the message is too long to send
  /// inline. Shows the full text in the user bubble so they see exactly what
  /// was sent, then routes through [WearableClient.sendChatMessageWithAttachments].
  Future<void> _sendAsTextAttachment(String text, WearableChatProvider provider) async {
    final messenger = ScaffoldMessenger.of(context);
    final tmpFile = await _writeTempTextFile(text);
    if (tmpFile == null) {
      // Temp write failed — fall back to a graceful error.
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Message too long and couldn't be saved as attachment"),
          duration: Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Show the FULL text in the user bubble so they see exactly what they sent.
    await provider.addLocalUserBubble(text, attachmentCount: 1);
    try {
      final receipt = await WearableClient.instance.sendChatMessageWithAttachments(
        message: 'My full request is in the attached text file — please read the attachment in full before responding.',
        chatId: await provider.ensureChatId(),
        files: [tmpFile],
      );
      provider.trackSendReceipt(receipt);
      // Temp file no longer needed — delete in background; ignore errors.
      tmpFile.delete().ignore();
    } on ChatAttachmentServerException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't send message as attachment: ${e.message}"),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't send message as attachment: $e"),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WearableColors.card,
        title: const Text(
          'Available commands',
          style: TextStyle(color: WearableColors.foreground, fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: kSlashCommands.map((cmd) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '/${cmd.name}',
                        style: const TextStyle(
                          color: WearableColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                      ),
                      TextSpan(
                        text: '  ${cmd.description}',
                        style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close', style: TextStyle(color: WearableColors.primary)),
          ),
        ],
      ),
    );
  }

  String _micTooltipFor(WearableConnectionStatus status) {
    switch (status) {
      case WearableConnectionStatus.connected:
        return 'Tap to ask Wearable by voice';
      case WearableConnectionStatus.syncing:
        return 'Reconnecting to Wearable…';
      case WearableConnectionStatus.disconnected:
        return 'Wearable device unreachable';
      case WearableConnectionStatus.error:
        return 'Wearable connection error';
      case WearableConnectionStatus.unpaired:
        return 'Pair a Wearable device to use voice';
    }
  }

  /// Triggers an AGENT_REQUEST button event on the paired wearable. The
  /// firmware opens its capture window; the final transcript flows back
  /// via the SSE stream as a normal user turn. UX: a brief snackbar is
  /// the only local feedback — the mic does not block other interaction
  /// while the wearable is listening.
  Future<void> _onMicTap() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WearableClient.instance.requestAgentCapture();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Speak now — Wearable is listening'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Couldn't reach Wearable — tap again to retry"),
          duration: Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: WearableColors.background,
      // Edge-swipe from the left opens the side-sheet for free via the
      // Drawer; the leading icon is the discoverable affordance.
      // openCount → Drawer's FutureBuilder key so each open re-fetches.
      drawer: _ThreadDrawer(openCount: _drawerOpenCount),
      onDrawerChanged: (open) {
        if (open) setState(() => _drawerOpenCount++);
      },
      appBar: AppBar(
        title: const Text('Chat'),
        backgroundColor: WearableColors.background,
        elevation: 0,
        // Leading: Menu & Settings (gear) — opens the parent Scaffold's
        // WearableDrawer. The home AppBar is hidden on this tab to avoid the
        // double-bar mess, so the gear lives here when Boardroom is
        // active. forceMaterialTransparency keeps the icon flush with
        // the background colour we set above.
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.settings_outlined, color: WearableColors.foreground, size: 22),
            tooltip: 'Menu & Settings',
            onPressed: () {
              // Walk up past the local (threads) Scaffold to the home
              // shell's Scaffold — that's the one with the WearableDrawer.
              // The local _scaffoldKey would open the threads drawer
              // instead.
              final root = ctx.findRootAncestorStateOfType<ScaffoldState>();
              root?.openDrawer();
            },
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.forum_outlined, color: WearableColors.foreground, size: 22),
            tooltip: 'Conversations',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Consumer<WearableChatProvider>(
            builder: (_, p, __) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _ConnectionDot(connected: p.connected),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Consumer<WearableChatProvider>(
              builder: (context, p, _) {
                if (p.messages.isEmpty) {
                  return const _EmptyState();
                }
                // Width of the bubble row is computed once per build using
                // sizeOf — that subscribes only to size changes, not to
                // every MediaQuery field (keyboard height, text scale).
                final maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.78;
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                  itemCount: p.messages.length,
                  itemBuilder: (_, i) {
                    final m = p.messages[i];
                    return _MessageRow(
                      key: ValueKey(m.id),
                      message: m,
                      maxBubbleWidth: maxBubbleWidth,
                      delegation: m.sender == WearableChatSender.assistant ? p.delegationFor(m.id) : null,
                    );
                  },
                );
              },
            ),
          ),
          // Error banner: surfaces send failures, stream errors, and
          // server-published `error` events. Auto-clears on user dismiss.
          Consumer<WearableChatProvider>(
            builder: (_, p, __) {
              final err = p.lastError;
              if (err == null) return const SizedBox.shrink();
              // When the circuit breaker is tripped the dismiss action
              // doubles as a manual retry — clearing the error and
              // resuming the SSE attach loop. Otherwise it's just a
              // banner dismiss.
              return _ErrorBanner(message: err, onDismiss: p.circuitOpen ? p.resumeReconnect : p.clearError);
            },
          ),
          // Mic state is owned by WearableConnectionProvider — only enable the
          // mic button when the wearable is reachable AND the bridge is
          // attached. Anything else (syncing, disconnected, error,
          // unpaired) renders the mic disabled with a tooltip.
          Consumer<WearableConnectionProvider>(
            builder: (_, conn, __) => _AskWearableBar(
              controller: _input,
              onSend: _onSend,
              onMic: conn.status == WearableConnectionStatus.connected ? _onMicTap : null,
              micTooltip: _micTooltipFor(conn.status),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message row
// ---------------------------------------------------------------------------

class _MessageRow extends StatelessWidget {
  const _MessageRow({super.key, required this.message, required this.maxBubbleWidth, this.delegation});
  final WearableChatMessage message;
  final double maxBubbleWidth;
  final WearableDelegationSnapshot? delegation;

  @override
  Widget build(BuildContext context) {
    final isUser = message.sender == WearableChatSender.user;
    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = isUser ? WearableColors.primary : WearableColors.card;
    final fgColor = isUser ? WearableColors.onPrimary : WearableColors.foreground;
    final indent = message.isSynthesisReentry ? 16.0 : 0.0;

    return Padding(
      padding: EdgeInsets.only(left: indent, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Align(
            alignment: align,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxBubbleWidth),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(WearableRadii.lg),
                  border: isUser ? null : Border.all(color: WearableColors.border, width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      message.text,
                      cursorColor: WearableColors.primary,
                      style: TextStyle(color: fgColor, fontSize: 15, height: 1.35),
                    ),
                    if (message.requiresReply) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Reply required',
                        style: TextStyle(color: WearableColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (delegation != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _DelegationStrip(snapshot: delegation!),
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: WearableColors.destructive.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: WearableColors.destructive, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(color: WearableColors.foreground, fontSize: 13, height: 1.3)),
          ),
          InkWell(
            onTap: onDismiss,
            // 44×44 hit area, 18px visual icon — meets Material a11y minimum.
            child: const SizedBox(width: 44, height: 44, child: Icon(Icons.close, color: WearableColors.mutedFg, size: 18)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delegation strip — renders one TaskChip per child the CoS dispatched.
// (M-2.4)
// ---------------------------------------------------------------------------

class _DelegationStrip extends StatelessWidget {
  const _DelegationStrip({required this.snapshot});
  final WearableDelegationSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final child in snapshot.children)
          _TaskChip(child: child, completion: snapshot.completedByRole[child.role]),
      ],
    );
  }
}

class _TaskChip extends StatelessWidget {
  const _TaskChip({required this.child, this.completion});
  final WearableDelegationChild child;
  final WearableChildCompletion? completion;

  Color get _statusColor {
    if (completion == null) return WearableColors.warning; // running
    return completion!.ok ? WearableColors.primary : WearableColors.destructive;
  }

  String get _statusLabel {
    if (completion == null) return 'running';
    return completion!.ok ? 'done' : 'failed';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: WearableColors.cardAlt,
        borderRadius: BorderRadius.circular(WearableRadii.sm),
        border: Border.all(color: WearableColors.border, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: 'Status: $_statusLabel',
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '@${child.role}',
            style: const TextStyle(color: WearableColors.foreground, fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              child.subtask,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _statusLabel,
            style: TextStyle(color: _statusColor, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Persistent Ask-Wearable input bar (M-2.2).
// Now a StatefulWidget to manage:
//   - Slash-command overlay menu (filtered as the user types "/…")
//   - Attachment picks (images / video) with preview chips above the field
// ---------------------------------------------------------------------------

class _AskWearableBar extends StatefulWidget {
  const _AskWearableBar({required this.controller, required this.onSend, required this.onMic, required this.micTooltip});
  final TextEditingController controller;

  /// Called with the typed text and any selected attachment [File]s.
  final Future<void> Function({List<File> attachments}) onSend;

  /// Null when the wearable is not reachable — renders the mic disabled.
  final VoidCallback? onMic;
  final String micTooltip;

  @override
  State<_AskWearableBar> createState() => _AskWearableBarState();
}

class _AskWearableBarState extends State<_AskWearableBar> {
  /// Pending attachment files, matching the server upload cap.
  final List<File> _attachments = [];

  /// Slash-command menu visibility.
  bool _showSlashMenu = false;
  List<SlashCommand> _filteredCommands = kSlashCommands;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    if (text.startsWith('/')) {
      final query = text.substring(1).split(' ').first.toLowerCase();
      setState(() {
        _filteredCommands = filterCommands(query);
        _showSlashMenu = _filteredCommands.isNotEmpty;
      });
    } else {
      if (_showSlashMenu) setState(() => _showSlashMenu = false);
    }
  }

  void _applyCommand(SlashCommand cmd) {
    // Insert "/" + name + space so the user can add args, except for
    // local commands which are fully self-contained.
    if (cmd.isLocal) {
      widget.controller.text = '/${cmd.name}';
    } else {
      widget.controller.text = '/${cmd.name} ';
      widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
    }
    setState(() => _showSlashMenu = false);
    // Focus already on the field; local commands will be executed on send.
  }

  Future<void> _pickAttachments() async {
    if (_attachments.length >= kWearableMaxAttachments) {
      _showAttachmentError('Maximum $kWearableMaxAttachments attachments');
      return;
    }
    final remaining = kWearableMaxAttachments - _attachments.length;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WearableColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(WearableRadii.lg))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: WearableColors.foreground),
              title: const Text('Photo library', style: TextStyle(color: WearableColors.foreground)),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickFromGallery(remaining);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: WearableColors.foreground),
              title: const Text('Camera', style: TextStyle(color: WearableColors.foreground)),
              onTap: () {
                Navigator.of(ctx).pop();
                _captureFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: WearableColors.foreground),
              title: const Text('Video', style: TextStyle(color: WearableColors.foreground)),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickVideo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined, color: WearableColors.foreground),
              title: const Text('Files & documents', style: TextStyle(color: WearableColors.foreground)),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickFiles();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery(int limit) async {
    try {
      final results = await ImagePicker().pickMultiImage(limit: limit);
      if (results.isNotEmpty) await _addAttachments(results.map((r) => File(r.path)));
    } catch (e) {
      _showAttachmentError("Couldn't open the photo library: $e");
    }
  }

  Future<void> _captureFromCamera() async {
    try {
      final result = await ImagePicker().pickImage(source: ImageSource.camera);
      if (result != null) {
        await _addAttachments([File(result.path)]);
      }
    } catch (e) {
      _showAttachmentError("Couldn't open the camera: $e");
    }
  }

  Future<void> _pickVideo() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: false);
      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        if (path != null) await _addAttachments([File(path)]);
      }
    } catch (e) {
      _showAttachmentError("Couldn't open the video picker: $e");
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: true);
      if (result == null) return;
      final inaccessible = result.files.where((f) => f.path == null).length;
      final files = result.files.where((f) => f.path != null).map((f) => File(f.path!));
      await _addAttachments(files);
      if (inaccessible > 0) {
        _showAttachmentError("Couldn't access $inaccessible selected file${inaccessible == 1 ? '' : 's'}.");
      }
    } catch (e) {
      _showAttachmentError("Couldn't open the file picker: $e");
    }
  }

  Future<void> _addAttachments(Iterable<File> candidates) async {
    final accepted = <File>[];
    final errors = <String>[];
    var available = kWearableMaxAttachments - _attachments.length;

    for (final file in candidates) {
      if (available <= 0) {
        errors.add('Only $kWearableMaxAttachments attachments can be sent at once.');
        break;
      }
      try {
        final bytes = await file.length();
        final error = wearableAttachmentSizeError(name: file.uri.pathSegments.last, bytes: bytes);
        if (error != null) {
          errors.add(error);
          continue;
        }
        accepted.add(file);
        available--;
      } catch (_) {
        errors.add("Couldn't read ${file.uri.pathSegments.last}.");
      }
    }

    if (!mounted) return;
    if (accepted.isNotEmpty) setState(() => _attachments.addAll(accepted));
    if (errors.isNotEmpty) _showAttachmentError(errors.join('\n'));
  }

  void _showAttachmentError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5), behavior: SnackBarBehavior.floating),
    );
  }

  void _removeAttachment(int index) {
    setState(() => _attachments.removeAt(index));
  }

  Future<void> _onSendTap() async {
    final files = List<File>.from(_attachments);
    setState(() => _attachments.clear());
    await widget.onSend(attachments: files);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // --- Slash-command menu -----------------------------------------------
          if (_showSlashMenu)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: const BoxDecoration(
                color: WearableColors.card,
                border: Border(top: BorderSide(color: WearableColors.border, width: 0.5)),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _filteredCommands.length,
                itemBuilder: (_, i) {
                  final cmd = _filteredCommands[i];
                  return InkWell(
                    onTap: () => _applyCommand(cmd),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Text(
                            '/${cmd.name}',
                            style: const TextStyle(
                              color: WearableColors.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              cmd.description,
                              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          // --- Attachment preview row -------------------------------------------
          if (_attachments.isNotEmpty)
            Container(
              height: 72,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: WearableColors.background,
                border: Border(top: BorderSide(color: WearableColors.border, width: 0.5)),
              ),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _AttachmentChip(file: _attachments[i], onRemove: () => _removeAttachment(i)),
              ),
            ),

          // --- Input row -------------------------------------------------------
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: const BoxDecoration(
              color: WearableColors.background,
              border: Border(top: BorderSide(color: WearableColors.border, width: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Attach button.
                Tooltip(
                  message: 'Attach image or video',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(WearableRadii.lg),
                      onTap: _pickAttachments,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          Icons.add_photo_alternate_outlined,
                          color: _attachments.isNotEmpty ? WearableColors.primary : WearableColors.mutedFg,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: WearableColors.card,
                      borderRadius: BorderRadius.circular(WearableRadii.lg),
                      border: Border.all(color: WearableColors.border, width: 0.5),
                    ),
                    child: TextField(
                      controller: widget.controller,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _onSendTap(),
                      style: const TextStyle(color: WearableColors.foreground, fontSize: 15),
                      decoration: const InputDecoration(
                        hintText: 'Ask Wearable… or type / for commands',
                        hintStyle: TextStyle(color: WearableColors.mutedFg),
                        border: InputBorder.none,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Mic — optional. Visible always; tappable only when wearable
                // is reachable.
                Tooltip(
                  message: widget.micTooltip,
                  child: Semantics(
                    button: true,
                    enabled: widget.onMic != null,
                    label: widget.micTooltip,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(WearableRadii.lg),
                        onTap: widget.onMic,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Icon(
                            Icons.mic_rounded,
                            color: widget.onMic != null ? WearableColors.foreground : WearableColors.mutedFg,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Material(
                  color: WearableColors.primary,
                  borderRadius: BorderRadius.circular(WearableRadii.lg),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(WearableRadii.lg),
                    onTap: _onSendTap,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.send_rounded, color: WearableColors.onPrimary, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Attachment preview chip — thumbnail for image, generic icon for video/other.
// ---------------------------------------------------------------------------

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.file, required this.onRemove});
  final File file;
  final VoidCallback onRemove;

  bool get _isImage {
    final ext = file.path.split('.').last.toLowerCase();
    return const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(ext);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: WearableColors.cardAlt,
            borderRadius: BorderRadius.circular(WearableRadii.sm),
            border: Border.all(color: WearableColors.border, width: 0.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WearableRadii.sm - 1),
            child: _isImage
                ? Image.file(file, fit: BoxFit.cover)
                : const Center(child: Icon(Icons.videocam_outlined, color: WearableColors.mutedFg, size: 24)),
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(color: WearableColors.destructive, shape: BoxShape.circle),
              child: const Icon(Icons.close, color: Colors.white, size: 13),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final label = connected ? 'Connected' : 'Reconnecting…';
    return Semantics(
      label: 'Chat connection — $label',
      child: Tooltip(
        message: label,
        // 44×44 hit area satisfies iOS HIG / Material accessibility
        // minimum even though the visible dot stays small.
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: connected ? WearableColors.primary : WearableColors.warning,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, color: WearableColors.mutedFg, size: 40),
            SizedBox(height: 16),
            Text(
              'Your chat is quiet',
              textAlign: TextAlign.center,
              style: TextStyle(color: WearableColors.foreground, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              'Ask Wearable anything — your Chief of Staff will route it to the '
              'right specialist and report back.',
              textAlign: TextAlign.center,
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Thread side-sheet (M-2.3)
// ---------------------------------------------------------------------------

class _ThreadDrawer extends StatefulWidget {
  /// Bumped by the parent Scaffold's `onDrawerChanged(open: true)`. The
  /// state's `didUpdateWidget` reacts to changes here, NOT to widget
  /// construction — that way we don't hit the network on every Scaffold
  /// rebuild while the drawer is closed.
  final int openCount;
  const _ThreadDrawer({required this.openCount});

  @override
  State<_ThreadDrawer> createState() => _ThreadDrawerState();
}

class _ThreadDrawerState extends State<_ThreadDrawer> {
  /// Null until the drawer is opened for the first time. The build
  /// method renders a placeholder while null instead of issuing a
  /// pre-emptive fetch that the user may never see.
  Future<List<WearableChatThread>>? _future;

  @override
  void didUpdateWidget(covariant _ThreadDrawer old) {
    super.didUpdateWidget(old);
    if (widget.openCount != old.openCount) {
      _future = context.read<WearableChatProvider>().fetchThreads();
    }
  }

  Future<void> _refresh() async {
    final f = context.read<WearableChatProvider>().fetchThreads();
    setState(() => _future = f);
    await f;
  }

  Future<void> _onNewThread() async {
    final navigator = Navigator.of(context);
    await context.read<WearableChatProvider>().newThread();
    if (!mounted) return;
    navigator.pop(); // close the drawer
  }

  Future<void> _onPickThread(WearableChatThread t) async {
    final navigator = Navigator.of(context);
    await context.read<WearableChatProvider>().loadThread(t.chatId);
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // Narrow the rebuild trigger: only re-render when the active chatId
    // changes. Without this, the drawer rebuilds on every assistant
    // message frame because `context.watch<WearableChatProvider>()` would
    // subscribe the entire build to all notifyListeners() calls.
    final activeChatId = context.select<WearableChatProvider, String?>((p) => p.chatId);
    return Drawer(
      backgroundColor: WearableColors.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Conversations',
                      style: TextStyle(color: WearableColors.foreground, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Start new conversation',
                    icon: const Icon(Icons.add, color: WearableColors.primary),
                    onPressed: _onNewThread,
                  ),
                ],
              ),
            ),
            const Divider(color: WearableColors.border, height: 1),
            Expanded(
              child: RefreshIndicator(
                color: WearableColors.primary,
                onRefresh: _refresh,
                child: FutureBuilder<List<WearableChatThread>>(
                  future: _future,
                  builder: (_, snap) {
                    // Null future = drawer hasn't opened yet (or
                    // _refresh hasn't fired). Show the spinner so the
                    // user sees activity in the rare case they tap
                    // before didUpdateWidget runs.
                    if (_future == null || snap.connectionState != ConnectionState.done) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(color: WearableColors.primary, strokeWidth: 2),
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return ListView(
                        children: const [
                          Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              "Couldn't load conversations.\nPull down to retry.",
                              style: TextStyle(color: WearableColors.mutedFg, fontSize: 14),
                            ),
                          ),
                        ],
                      );
                    }
                    final threads = snap.data ?? const <WearableChatThread>[];
                    if (threads.isEmpty) {
                      return ListView(
                        children: const [
                          Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No past conversations yet — your chat history will appear here.',
                              style: TextStyle(color: WearableColors.mutedFg, fontSize: 14),
                            ),
                          ),
                        ],
                      );
                    }
                    return ListView.separated(
                      itemCount: threads.length,
                      separatorBuilder: (_, __) => const Divider(color: WearableColors.border, height: 1),
                      itemBuilder: (_, i) {
                        final t = threads[i];
                        return _ThreadRow(thread: t, isActive: t.chatId == activeChatId, onTap: () => _onPickThread(t));
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({required this.thread, required this.isActive, required this.onTap});
  final WearableChatThread thread;
  final bool isActive;
  final VoidCallback onTap;

  String _preview() {
    final raw = thread.lastContent ?? '';
    // First line only — strip newlines/tabs so multi-line CoS responses
    // collapse cleanly. Hard cap at 120 chars to keep rows compact even
    // when the SQL projection would have allowed more.
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final capped = flat.length > 120 ? '${flat.substring(0, 120)}…' : flat;
    if (thread.lastRole == 'user') return 'You: $capped';
    return capped;
  }

  String _timeAgo() {
    final delta = DateTime.now().difference(thread.lastActivity);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m';
    if (delta.inHours < 24) return '${delta.inHours}h';
    if (delta.inDays < 7) return '${delta.inDays}d';
    return '${(delta.inDays / 7).floor()}w';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? WearableColors.cardAlt : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _preview(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isActive ? WearableColors.primary : WearableColors.foreground,
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${thread.turnCount} turn${thread.turnCount == 1 ? '' : 's'} · ${_timeAgo()}',
                      style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (isActive)
                const Padding(
                  padding: EdgeInsets.only(left: 8, top: 2),
                  child: Icon(Icons.check, color: WearableColors.primary, size: 16),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
