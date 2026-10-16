// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Contextual "Ask Wearable" mini FAB shown on list screens once the user has
// scrolled past a threshold. Taps open the WearableRoutingSheet, optionally
// pre-seeded with a role and a snippet of context (e.g. the current
// conversation's title so follow-ups land on the right agent).
//
// The parent screen is responsible for sliding the FAB in/out with an
// animation — this widget only renders the button.

import 'package:flutter/material.dart';

import '../models/wearable_agent_meta.dart';
import '../wearable_theme.dart';
import 'wearable_routing_sheet.dart';

class WearableAskFab extends StatelessWidget {
  const WearableAskFab({
    super.key,
    this.preSeededText,
    this.initialRole,
    this.label = 'Ask Wearable',
  });

  final String? preSeededText;
  final WearableAgentMeta? initialRole;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showWearableRoutingSheet(
          context,
          preSeededText: preSeededText,
          initialRole: initialRole,
        ),
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: WearableColors.primary,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [WearableShadows.button],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_bubble_outline, size: 16, color: WearableColors.onPrimary),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: WearableColors.onPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
