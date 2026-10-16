// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableTaskCard — fixed-width card for the Tasks carousel layout.
// Shown in horizontal strips grouped by status; tapping navigates to
// TaskDetailPage. Design: role-colour top-bar accent, dark card surface,
// title + worker meta, status badge, role chip, relative timestamp.

import 'package:flutter/material.dart';

import '../models/wearable_task.dart';
import '../wearable_theme.dart';

class WearableTaskCard extends StatelessWidget {
  const WearableTaskCard({
    super.key,
    required this.task,
    required this.onTap,
  });

  /// Nominal card width — wide enough for 2 lines of title, narrow enough
  /// to show the next card peeking in at the carousel edge.
  static const double cardWidth = 236.0;

  final WearableTaskSummary task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = _roleColor(task.role);
    final statusAccent = _statusAccent(task.status);
    final title = _title(task.prompt);
    final meta = _meta(task);

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: cardWidth,
        child: Container(
          decoration: BoxDecoration(
            color: WearableColors.card,
            borderRadius: BorderRadius.circular(WearableRadii.lg),
            border: Border.all(
              color: statusAccent.withValues(alpha: 0.25),
              width: 1,
            ),
            boxShadow: [WearableShadows.card],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Role-colour top accent bar
              Container(
                height: 3,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(WearableRadii.lg),
                    topRight: Radius.circular(WearableRadii.lg),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: WearableColors.foreground,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Meta line (worker + attempts + cost)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: WearableColors.mutedFg,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                      const Spacer(),
                      // Bottom row: status badge + role chip + timestamp
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _StatusBadge(status: task.status),
                          const SizedBox(width: 6),
                          _RoleChip(role: task.role, color: accent),
                          const Spacer(),
                          Text(
                            _relativeTime(task.updatedAt),
                            style: const TextStyle(
                              color: WearableColors.mutedFg,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _title(String? prompt) {
    if (prompt == null || prompt.isEmpty) return '(no prompt)';
    final first = prompt.split('\n').firstWhere(
      (l) => l.trim().isNotEmpty,
      orElse: () => '',
    );
    return first.isEmpty ? '(no prompt)' : first.trim();
  }

  static String _meta(WearableTaskSummary t) {
    final worker = t.workerName ?? t.workerKind ?? 'worker';
    final attemptsStr = t.attempts > 1 ? ' · ${t.attempts} attempts' : '';
    final costStr = t.usdCents > 0 ? ' · ${_usd(t.usdCents)}' : '';
    return '$worker$attemptsStr$costStr';
  }

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
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  static Color _roleColor(String role) => switch (role) {
        'comms' => const Color(0xFF3B82F6),
        'content' => const Color(0xFFF59E0B),
        'ops' => const Color(0xFFEF4444),
        'research' => const Color(0xFFB57AF0),
        _ => WearableColors.primary,
      };

  static Color _statusAccent(WearableTaskStatus s) => switch (s) {
        WearableTaskStatus.active => const Color(0xFF3B82F6),
        WearableTaskStatus.pendingInput => WearableColors.warning,
        WearableTaskStatus.completed => WearableColors.primary,
        WearableTaskStatus.failed => WearableColors.destructive,
        WearableTaskStatus.awaitingChildren => const Color(0xFF8B5CF6),
        WearableTaskStatus.unknown => WearableColors.mutedFg,
      };
}

// ---------------------------------------------------------------------------
// Internal widgets
// ---------------------------------------------------------------------------

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final WearableTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      WearableTaskStatus.active => ('Working', const Color(0xFF3B82F6)),
      WearableTaskStatus.pendingInput => ('Needs input', WearableColors.warning),
      WearableTaskStatus.completed => ('Done', WearableColors.primary),
      WearableTaskStatus.failed => ('Failed', WearableColors.destructive),
      WearableTaskStatus.awaitingChildren => ('Waiting', const Color(0xFF8B5CF6)),
      WearableTaskStatus.unknown => ('Unknown', WearableColors.mutedFg),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        role,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
