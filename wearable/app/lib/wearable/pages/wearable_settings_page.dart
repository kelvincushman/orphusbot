// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableSettingsPage — the settings index. Four destinations plus the build
// identifier, which is what support asks for first.
//
// The on-device model page hangs off Voice, and diarization off the device
// page, so neither is listed twice here.

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../wearable_theme.dart';
import 'settings/wearable_safety_rules_page.dart';
import 'settings/wearable_session_server_page.dart';
import 'settings/wearable_voice_page.dart';
import 'settings/wearable_webhooks_page.dart';

class WearableSettingsPage extends StatelessWidget {
  const WearableSettingsPage({super.key});

  static void show(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WearableSettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _tile(
            context,
            icon: Icons.dns_outlined,
            title: 'Session Server',
            subtitle: 'Pairing, base URL, credentials',
            page: const WearableSessionServerPage(),
          ),
          _tile(
            context,
            icon: Icons.record_voice_over_outlined,
            title: 'Voice',
            subtitle: 'Transcription mode, speaker enrolment',
            page: const WearableVoicePage(),
          ),
          _tile(
            context,
            icon: Icons.webhook_outlined,
            title: 'Webhooks',
            subtitle: 'Outbound event delivery',
            page: const WearableWebhooksPage(),
          ),
          _tile(
            context,
            icon: Icons.policy_outlined,
            title: 'Safety Rules',
            subtitle: 'Agent guardrails',
            page: const WearableSafetyRulesPage(),
          ),
          const Divider(color: WearableColors.border, height: 1),
          const _AboutRow(),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget page,
  }) {
    return ListTile(
      leading: Icon(icon, color: WearableColors.foreground, size: 22),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, color: WearableColors.mutedFg),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final version = info == null ? '…' : '${info.version} (${info.buildNumber})';
        return ListTile(
          leading: const Icon(Icons.info_outline, color: WearableColors.mutedFg, size: 22),
          title: const Text('About'),
          subtitle: Text('Version $version', style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
        );
      },
    );
  }
}
