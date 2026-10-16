// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Compact "@role" pill used on conversation list items, task tiles, memory
// cards, and transcript messages. Renders nothing when [role] is null so
// callers can drop it into layouts unconditionally without branching.

import 'package:flutter/material.dart';

import '../models/wearable_agent_meta.dart';
import '../wearable_theme.dart';

class WearableAgentBadge extends StatelessWidget {
  const WearableAgentBadge({
    super.key,
    required this.role,
    this.showIcon = true,
    this.compact = false,
  });

  /// Agent key (e.g. "main") or null to hide the badge entirely.
  final String? role;
  final bool showIcon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final meta = wearableAgentByKey(role);
    if (meta == null) return const SizedBox.shrink();
    final padH = compact ? 6.0 : 8.0;
    final padV = compact ? 2.0 : 4.0;
    final fontSize = compact ? 10.0 : 11.0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: meta.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: meta.color.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(meta.icon, size: fontSize + 2, color: meta.color),
            const SizedBox(width: 4),
          ],
          Text(
            '@${meta.key}',
            style: TextStyle(
              color: WearableColors.foreground,
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
