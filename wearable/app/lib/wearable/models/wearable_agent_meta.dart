// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Centralised metadata for Wearable's five specialist agents. Every widget that
// renders a role (badge, chip, card, banner) pulls from this single source
// so icons / colours / titles stay in sync across screens.
//
// Order matches the server-side role enum in `src/harness/role-permissions.ts`
// and the charter (`src/harness/charter/v1/charter.md`).

import 'package:flutter/material.dart';

import '../wearable_theme.dart';

enum WearableRole { main, comms, content, ops, research }

class WearableAgentMeta {
  final WearableRole role;
  final String key;          // "main", "comms", etc. — wire value for URLs/params
  final String title;        // "Chief of Staff"
  final String shortTitle;   // "CoS" — for tight spaces
  final String description;
  final IconData icon;
  final Color color;         // stripe / badge accent

  const WearableAgentMeta({
    required this.role,
    required this.key,
    required this.title,
    required this.shortTitle,
    required this.description,
    required this.icon,
    required this.color,
  });
}

const wearableAgents = <WearableAgentMeta>[
  WearableAgentMeta(
    role: WearableRole.main,
    key: 'main',
    title: 'Chief of Staff',
    shortTitle: 'CoS',
    description: 'Default. Routes + orchestrates the other agents.',
    icon: Icons.stars_outlined,
    color: WearableColors.primary,
  ),
  WearableAgentMeta(
    role: WearableRole.comms,
    key: 'comms',
    title: 'Head of Comms',
    shortTitle: 'Comms',
    description: 'Drafts messages, replies, posts.',
    icon: Icons.mail_outline,
    color: WearableColors.info,
  ),
  WearableAgentMeta(
    role: WearableRole.content,
    key: 'content',
    title: 'Head of Content',
    shortTitle: 'Content',
    description: 'Long-form research + web content.',
    icon: Icons.article_outlined,
    color: WearableColors.warning,
  ),
  WearableAgentMeta(
    role: WearableRole.ops,
    key: 'ops',
    title: 'COO',
    shortTitle: 'Ops',
    description: 'Ops scripts + LAN tools (highest-privilege).',
    icon: Icons.settings_suggest_outlined,
    color: WearableColors.destructive,
  ),
  WearableAgentMeta(
    role: WearableRole.research,
    key: 'research',
    title: 'Head of Research',
    shortTitle: 'Research',
    description: 'Deep research + paper summaries.',
    icon: Icons.search_outlined,
    color: WearableColors.primary,
  ),
];

WearableAgentMeta? wearableAgentByKey(String? key) {
  if (key == null) return null;
  for (final a in wearableAgents) {
    if (a.key == key) return a;
  }
  return null;
}
