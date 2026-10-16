// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// KnowledgePage — placeholder for the Knowledge tab (M-1 shell).
// Notes, meeting notes & ideas will be surfaced here in a later milestone.

import 'package:flutter/material.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';

class KnowledgePage extends StatelessWidget {
  const KnowledgePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 64,
              color: WearableColors.mutedFg,
            ),
            SizedBox(height: 16),
            Text(
              'Knowledge',
              style: TextStyle(
                color: WearableColors.foreground,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Notes, meeting notes & ideas — coming soon.',
              style: TextStyle(
                color: WearableColors.mutedFg,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
