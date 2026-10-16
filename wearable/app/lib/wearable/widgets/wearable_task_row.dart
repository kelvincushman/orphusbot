// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableTaskRow — single entry in the Tasks ledger ListView (plan §5.4 M-3.2).
// Row shape: 4dp role-colour stripe on the left, title (first line of
// prompt), one-line summary derived from the server fields, and a meta
// row with status dot + role chip + relative timestamp.

import 'package:flutter/material.dart';

import '../models/wearable_task.dart';
import '../wearable_theme.dart';

class WearableTaskRow extends StatelessWidget {
  const WearableTaskRow({
    super.key,
    required this.task,
    required this.onTap,
  });

  final WearableTaskSummary task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final stripe = _roleColor(task.role);
    final title = _title(task.prompt);
    final summary = _summary(task);
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: stripe),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: WearableColors.foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.3),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _StatusDot(status: task.status),
                        const SizedBox(width: 6),
                        Text(
                          _statusLabel(task.status),
                          style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                        ),
                        const SizedBox(width: 10),
                        _RoleChip(role: task.role, color: stripe),
                        const Spacer(),
                        Text(
                          _relativeTime(task.updatedAt),
                          style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: WearableColors.mutedFg, size: 18),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  static String _title(String? prompt) {
    if (prompt == null || prompt.isEmpty) return '(no prompt)';
    final firstLine = prompt.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return firstLine.isEmpty ? '(no prompt)' : firstLine.trim();
  }

  static String _summary(WearableTaskSummary t) {
    // Server gives us a truncated prompt, not RESPONSE.md, so the summary
    // is metadata-ish for now — worker + attempts + cost. TaskDetailPage
    // fetches the actual response on demand.
    final worker = t.workerName ?? t.workerKind ?? 'worker';
    final attemptsStr = t.attempts > 1 ? ' · ${t.attempts} attempts' : '';
    final costStr = t.usdCents > 0 ? ' · ${_usd(t.usdCents)}' : '';
    return '$worker$attemptsStr$costStr';
  }

  static String _statusLabel(WearableTaskStatus s) => switch (s) {
        WearableTaskStatus.active => 'Working',
        WearableTaskStatus.pendingInput => 'Needs input',
        WearableTaskStatus.completed => 'Done',
        WearableTaskStatus.failed => 'Failed',
        WearableTaskStatus.awaitingChildren => 'Waiting on children',
        WearableTaskStatus.unknown => 'Unknown',
      };

  static String _usd(int cents) {
    if (cents <= 0) return '\$0';
    if (cents < 100) return '\$0.${cents.toString().padLeft(2, '0')}';
    return '\$${(cents / 100).toStringAsFixed(2)}';
  }

  static String _relativeTime(int epochMs) {
    if (epochMs <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  static Color _roleColor(String role) => switch (role) {
        'comms' => const Color(0xFF3B82F6),
        'content' => const Color(0xFFF59E0B),
        'ops' => const Color(0xFFEF4444),
        'research' => const Color(0xFFA855F7),
        _ => WearableColors.primary,   // main + unknown
      };
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final WearableTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      WearableTaskStatus.active => const Color(0xFF3B82F6),
      WearableTaskStatus.pendingInput => const Color(0xFFF59E0B),
      WearableTaskStatus.completed => WearableColors.primary,
      WearableTaskStatus.failed => const Color(0xFFEF4444),
      WearableTaskStatus.awaitingChildren => const Color(0xFF8B5CF6),
      WearableTaskStatus.unknown => WearableColors.mutedFg,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role, required this.color});
  final String role;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        role,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }
}
