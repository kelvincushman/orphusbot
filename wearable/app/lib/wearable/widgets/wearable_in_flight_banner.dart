// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableInFlightBanner — slim banner shown immediately below the AppBar when
// any Wearable agent task is in flight. Auto-hides when the task queue empties.
// Listens to WearableTaskProvider; the parent is responsible for sliding it in
// and out (use SizedBox zero-height when _visible is false so the banner
// preserves layout without a jerk).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../wearable_theme.dart';
import '../providers/wearable_task_provider.dart';

class WearableInFlightBanner extends StatelessWidget {
  const WearableInFlightBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final task = context.watch<WearableTaskProvider>().currentActive;
    final visible = task != null;
    return AnimatedCrossFade(
      firstChild: const SizedBox(height: 0, width: double.infinity),
      secondChild: _banner(context, task),
      crossFadeState: visible ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 180),
    );
  }

  Widget _banner(BuildContext context, WearableTask? task) {
    final label = task == null
        ? 'Wearable working…'
        : '@${task.role} is working…';
    return Container(
      height: 30,
      width: double.infinity,
      color: WearableColors.card,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(WearableColors.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
