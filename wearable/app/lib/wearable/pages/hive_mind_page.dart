// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// HiveMindPage — timeline of cross-agent activity, pulled from Wearable's
// `hive_mind` SQLite table on the server. Per design spec v1.0 §Screen 7.
//
// This is the initial drawer target: lays out the visual structure and
// role-colour stripes. The live data fetch (`GET /api/hive-mind?limit=30`)
// + SSE stream (`/api/hive-mind/stream`) wire up in a follow-up chunk;
// this chunk ships the shell so the drawer navigates somewhere real.

import 'package:flutter/material.dart';

import '../models/wearable_agent_meta.dart';
import '../wearable_theme.dart';
import '../widgets/wearable_agent_badge.dart';

class HiveMindPage extends StatelessWidget {
  const HiveMindPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Hive Mind'),
        backgroundColor: WearableColors.background,
      ),
      body: _EmptyState(),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cross-agent activity',
            style: TextStyle(
              color: WearableColors.foreground,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'When one agent finishes a task, the summary lands here so the '
            'other four can see it. Wire-up to live server data is coming in '
            'the next chunk — this view is placeholder-styled for now.',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: wearableAgents
                .map((a) => WearableAgentBadge(role: a.key))
                .toList(growable: false),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: WearableColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: WearableColors.border),
            ),
            child: const Row(
              children: [
                Icon(Icons.hub_outlined, color: WearableColors.primary, size: 22),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No entries yet. The hive mind populates once the first '
                    'agent task completes via the routing sheet or device '
                    'button-press capture.',
                    style: TextStyle(color: WearableColors.foreground, fontSize: 13, height: 1.4),
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
