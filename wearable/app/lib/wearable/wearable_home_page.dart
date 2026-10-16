// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableHomePage — the app shell behind the pairing gate. Four tabs in an
// IndexedStack, a centre Chat FAB that pushes full-screen, the drawer on the
// left and the status pill on the right.
//
//   0 Transcripts — on-device live feed
//   1 Tasks       — server task ledger
//   2 Home        — server health
//   3 Wearable    — device status
//
// Entry passes through AppLockGate, which is a transparent pass-through unless
// the user has turned the local lock on.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/device_status_page.dart';
import 'pages/full_screen_chat_page.dart';
import 'pages/home_status_page.dart';
import 'pages/tasks_ledger_page.dart';
import 'pages/transcripts_page.dart';
import 'providers/wearable_shell_provider.dart';
import 'security/app_lock.dart';
import 'wearable_theme.dart';
import 'widgets/wearable_bottom_bar.dart';
import 'widgets/wearable_drawer.dart';
import 'widgets/wearable_in_flight_banner.dart';
import 'widgets/wearable_status_pill.dart';

class WearableHomePage extends StatelessWidget {
  const WearableHomePage({super.key});

  @override
  Widget build(BuildContext context) => const AppLockGate(child: _HomeScaffold());
}

class _HomeScaffold extends StatelessWidget {
  const _HomeScaffold();

  static const List<Widget> _pages = [TranscriptsPage(), TasksLedgerPage(), HomeStatusPage(), DeviceStatusPage()];

  static const List<String> _tabNames = ['Transcripts', 'Tasks', 'Home', 'Wearable'];

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<WearableShellProvider>();
    final index = shell.selectedIndex;

    return PopScope(
      // Back walks the tab history first; only an empty stack falls through to
      // the platform default.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!shell.popTabHistory() && context.mounted) {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        backgroundColor: WearableColors.background,
        appBar: _appBar(context, index),
        drawer: const WearableDrawer(),
        body: GestureDetector(
          onTap: () => primaryFocus?.unfocus(),
          child: Stack(
            children: [
              Column(
                children: [
                  const WearableInFlightBanner(),
                  Expanded(
                    child: IndexedStack(index: index, children: _pages),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: WearableBottomBar(
                  currentIndex: index,
                  onSelect: (i) {
                    primaryFocus?.unfocus();
                    shell.setIndex(i);
                  },
                  onChat: () {
                    primaryFocus?.unfocus();
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FullScreenChatPage()));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context, int index) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: WearableColors.card,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      leading: Builder(
        builder: (ctx) => IconButton(
          icon: const Icon(Icons.menu_rounded),
          iconSize: 22,
          tooltip: 'Menu',
          color: WearableColors.mutedFg,
          splashRadius: 20,
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        ),
      ),
      title: Text(
        _tabNames[index],
        // ponytail: 'Montserrat' is carried over verbatim from the page this
        // replaces and is not declared in pubspec.yaml, so it resolves to the
        // platform default exactly as before. Left alone deliberately — the
        // theme pass owns typography and should route this through WearableType.
        style: const TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w700,
          fontSize: 16,
          letterSpacing: 0.5,
          color: WearableColors.foreground,
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: WearableStatusPill(onTap: () => context.read<WearableShellProvider>().setIndex(3)),
        ),
      ],
    );
  }
}
