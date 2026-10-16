// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDrawer — side drawer for the sections that don't sit in the bottom
// nav: Hive Mind, Device Status, Dashboard, Settings.
//
// Profile is gone: it was an account page for a cloud identity this app no
// longer has. Device identity now lives on the Device Status page and the
// server pairing on Settings → Session Server.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../wearable_theme.dart';
import '../pages/device_status_page.dart';
import '../pages/hive_mind_page.dart';
import '../pages/wearable_dashboard_page.dart';
import '../pages/wearable_dictation_page.dart';
import '../pages/wearable_dictionary_page.dart';
import '../pages/wearable_settings_page.dart';
import '../providers/wearable_connection_provider.dart';
import 'wearable_ground.dart';

typedef _NavCallback = void Function(BuildContext);

class _WearableDrawerItem {
  final IconData icon;
  final String label;
  final _NavCallback onTap;
  const _WearableDrawerItem(this.icon, this.label, this.onTap);
}

class WearableDrawer extends StatelessWidget {
  const WearableDrawer({
    super.key,
    this.userName,
    this.userEmail,
  });

  final String? userName;
  final String? userEmail;

  @override
  Widget build(BuildContext context) {
    final items = <_WearableDrawerItem>[
      _WearableDrawerItem(Icons.hub_outlined, 'Hive Mind', _pushPage((_) => const HiveMindPage())),
      _WearableDrawerItem(Icons.memory_outlined, 'Device Status', _pushPage((_) => const DeviceStatusPage())),
      _WearableDrawerItem(Icons.dashboard_outlined, 'Dashboard', _pushPage((_) => const WearableDashboardPage())),
      _WearableDrawerItem(Icons.mic_none_outlined, 'Dictation', _pushPage((_) => const WearableDictationPage())),
      _WearableDrawerItem(Icons.menu_book_outlined, 'Dictionary', _pushPage((_) => const WearableDictionaryPage())),
      _WearableDrawerItem(Icons.settings_outlined, 'Settings', _pushPage((_) => const WearableSettingsPage())),
    ];
    return Drawer(
      backgroundColor: WearableColors.background,
      // The drawer is a ground surface, so it gets the ground treatment.
      child: WearableGround(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              const Divider(color: WearableColors.border, height: 1),
              ...items.map((it) => _tile(context, it)),
              const Spacer(),
              _statusFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: WearableColors.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: const Text(
              'N',
              style: TextStyle(
                color: WearableColors.onPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userName ?? 'Wearable',
                  style: const TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (userEmail != null && userEmail!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    userEmail!,
                    style: const TextStyle(
                      color: WearableColors.mutedFg,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, _WearableDrawerItem item) {
    return ListTile(
      leading: Icon(item.icon, color: WearableColors.foreground, size: 22),
      title: Text(
        item.label,
        style: const TextStyle(
          color: WearableColors.foreground,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: () => item.onTap(context),
    );
  }

  Widget _statusFooter(BuildContext context) {
    final status = context.watch<WearableConnectionProvider>().status;
    final label = switch (status) {
      // Server, not wearable. WearableConnectionProvider probes /api/health on
      // the paired server and nothing else — its own header says "the BLE
      // wearable is a separate concern". These read "Wearable unpaired" while a
      // wearable sat connected at 100% battery.
      WearableConnectionStatus.connected => 'Server connected',
      WearableConnectionStatus.syncing => 'Server syncing…',
      WearableConnectionStatus.disconnected => 'Server unreachable',
      WearableConnectionStatus.error => 'Server error',
      WearableConnectionStatus.unpaired => 'No server paired (optional)',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Text(
        label,
        style: const TextStyle(
          color: WearableColors.mutedFg,
          fontSize: 12,
        ),
      ),
    );
  }

  static _NavCallback _pushPage(WidgetBuilder builder) => (ctx) {
    Navigator.of(ctx).pop();
    Navigator.of(ctx).push(MaterialPageRoute(builder: builder));
  };
}
