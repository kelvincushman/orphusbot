// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableBottomBar — center-hero-Chat bottom navigation bar (M-1 shell §5.3).
//
// Layout (left → right):
//   Transcripts | Tasks | [Chat FAB] | Knowledge | Wearable
//
// The center Chat button is a raised circular FAB-style button (~64dp,
// black) that protrudes above the bar. Flanking items are plain
// icon+label tap targets. Menu lives on the top-left AppBar gear — not here.
//
// This is a hand-rolled bar rather than a NavigationBar because of that centre
// FAB — NavigationBar has no notch or protruding-destination slot. It still
// reads every value it renders out of `Theme.navigationBarTheme`, so the black
// active pill, the ground-coloured bar and the label/icon states stay in one
// place with the rest of the theme.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:kelvinlee/wearable/wearable_theme.dart';

class WearableBottomBar extends StatelessWidget {
  const WearableBottomBar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    required this.onChat,
    this.onChatLongPress,
  });

  /// Currently selected page index (0=Transcripts, 1=Tasks, 2=Home,
  /// 3=Wearable). Chat is the center FAB and is not a tab index.
  final int currentIndex;

  /// Called with the tapped index (0–3) when a flanking item is tapped.
  final ValueChanged<int> onSelect;

  /// Called when the center Chat FAB is tapped — opens the full-screen chat.
  final VoidCallback onChat;

  /// Optional long-press on the center Chat button — reserved for voice ask
  /// (later milestone). Currently wired to a no-op.
  final VoidCallback? onChatLongPress;

  static const double _fabSize = 64.0;
  static const double _fabRise = 20.0; // how many dp the FAB protrudes above the bar

  @override
  Widget build(BuildContext context) {
    final nav = Theme.of(context).navigationBarTheme;
    final barHeight = nav.height ?? 72.0;

    return SizedBox(
      // Total height = bar + rise so the FAB doesn't clip outside the Stack
      height: barHeight + _fabRise,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          // Bar background — the ground, so the nav reads as sitting on the
          // page rather than as a separate slab.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: barHeight,
              color: nav.backgroundColor ?? WearableColors.background,
              child: Row(
                children: [
                  // Transcripts (index 0)
                  _NavItem(
                    icon: Icons.subtitles_outlined,
                    label: 'Transcripts',
                    selected: currentIndex == 0,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onSelect(0);
                    },
                  ),
                  // Tasks (index 1)
                  _NavItem(
                    icon: Icons.checklist_outlined,
                    label: 'Tasks',
                    selected: currentIndex == 1,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onSelect(1);
                    },
                  ),
                  // Spacer for the raised center FAB
                  const SizedBox(width: _fabSize + 16),
                  // Home / Server Status (index 2)
                  _NavItem(
                    icon: Icons.insights_outlined,
                    label: 'Home',
                    selected: currentIndex == 2,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onSelect(2);
                    },
                  ),
                  // Wearable (index 3)
                  _NavItem(
                    icon: Icons.watch_outlined,
                    label: 'Wearable',
                    selected: currentIndex == 3,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onSelect(3);
                    },
                  ),
                ],
              ),
            ),
          ),

          // Center raised Chat FAB — opens full-screen chat (not a tab index)
          Positioned(
            bottom: barHeight - _fabSize / 2 - _fabRise / 2,
            child: GestureDetector(
              onLongPress: onChatLongPress,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  onChat();
                },
                child: Container(
                  width: _fabSize,
                  height: _fabSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: WearableColors.primary,
                    boxShadow: [WearableShadows.button],
                  ),
                  child: const Icon(
                    Icons.forum_outlined,
                    color: WearableColors.onPrimary,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One flanking destination: black pill behind the icon when active, label
/// underneath. Mirrors what NavigationBar renders for a destination, drawn by
/// hand so the centre FAB can share the row.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  /// M3 navigation-bar indicator geometry — NavigationBar's own default.
  static const double _pillWidth = 56.0;
  static const double _pillHeight = 32.0;

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nav = Theme.of(context).navigationBarTheme;
    final states = <WidgetState>{if (selected) WidgetState.selected};
    final iconColor = nav.iconTheme?.resolve(states)?.color ??
        (selected ? WearableColors.onPrimary : WearableColors.mutedFg);
    final labelStyle = nav.labelTextStyle?.resolve(states);

    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: nav.height ?? 72.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: _pillWidth,
                height: _pillHeight,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: selected
                      ? (nav.indicatorColor ?? WearableColors.primary)
                      : Colors.transparent,
                  shape: nav.indicatorShape ?? const StadiumBorder(),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(height: 4),
              Text(label, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}
