// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableRoutingSheet — the shared "Ask Wearable" bottom sheet.
//
// Post-M-6 (plan §5.7): the role-chip row is gone. Server-side S-1 (commit
// 2935907) made the Chief of Staff agent auto-delegate to specialists via
// `@role:` tokens at the end of its RESPONSE.md, so the user never picks a
// role manually. The sheet collapses to title + text input + record button
// + send. The `initialRole` parameter is retained as a no-op for API
// stability with existing callers (wearable_ask_fab, contextual FABs on the
// legacy pages still in the codebase but no longer reachable from the
// bottom nav after M-1).
//
// Internal role is always `main`; CoS handles delegation downstream.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/wearable_agent_meta.dart';
import '../wearable_theme.dart';
import '../providers/wearable_task_provider.dart';

const _uuid = Uuid();

/// Helper — the canonical entry point. Returns null when dismissed.
///
/// `initialRole` is accepted for API back-compat with pre-M-6 callers but
/// is no longer honoured: every dispatch flows through the `main` role and
/// CoS auto-delegation picks the specialist server-side.
Future<void> showWearableRoutingSheet(
  BuildContext context, {
  String? preSeededText,
  @Deprecated('Role-picking moved server-side in M-6; ignored.') WearableAgentMeta? initialRole,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => WearableRoutingSheet(preSeededText: preSeededText),
  );
}

class WearableRoutingSheet extends StatefulWidget {
  const WearableRoutingSheet({
    super.key,
    this.preSeededText,
  });

  final String? preSeededText;

  @override
  State<WearableRoutingSheet> createState() => _WearableRoutingSheetState();
}

class _WearableRoutingSheetState extends State<WearableRoutingSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.preSeededText ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.mediumImpact();
    // role is always 'main' — CoS auto-delegates server-side via S-1.
    context.read<WearableTaskProvider>().enqueue(WearableTask(
          id: _uuid.v4(),
          role: 'main',
          prompt: text.length > 80 ? '${text.substring(0, 80)}…' : text,
          startedAt: DateTime.now(),
        ));
    Navigator.of(context).maybePop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sent to Wearable — live dispatch wires in the next chunk')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _dragHandle(),
            const SizedBox(height: 8),
            const Text(
              'Ask Wearable',
              style: TextStyle(
                color: WearableColors.foreground,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            _textInput(),
            const SizedBox(height: 14),
            _bottomRow(),
          ],
        ),
      ),
    );
  }

  Widget _dragHandle() => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: WearableColors.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _textInput() {
    return TextField(
      controller: _ctrl,
      autofocus: true,
      minLines: 1,
      maxLines: 5,
      style: const TextStyle(color: WearableColors.foreground, fontSize: 15),
      decoration: InputDecoration(
        hintText: 'What do you need?',
        hintStyle: const TextStyle(color: WearableColors.mutedFg),
        filled: true,
        fillColor: WearableColors.cardAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WearableColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WearableColors.primary, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WearableColors.border),
        ),
      ),
    );
  }

  Widget _bottomRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _RecordButton(onTap: () {
          HapticFeedback.mediumImpact();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Voice capture wires up in a later chunk')),
          );
        }),
        const SizedBox(width: 12),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _send,
              icon: const Icon(Icons.send_outlined, size: 18),
              label: const Text('Send'),
              style: FilledButton.styleFrom(
                backgroundColor: WearableColors.primary,
                foregroundColor: WearableColors.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(36),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: WearableColors.primary,
          shape: BoxShape.circle,
          boxShadow: [WearableShadows.button],
        ),
        child: const Icon(Icons.mic_none_outlined, color: WearableColors.onPrimary, size: 26),
      ),
    );
  }
}
