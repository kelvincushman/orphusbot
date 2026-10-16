// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// FullScreenChatPage — thin full-screen wrapper pushed when the center Chat
// FAB is tapped. Presents the existing BoardroomPage directly; the
// WearableChatProvider is registered at app root so the pushed route inherits it
// from the widget tree with no additional wrapping needed.
//
// The BoardroomPage already owns an AppBar with a back-compatible leading icon
// (opens the parent Scaffold's WearableDrawer), so Navigator.pop() is wired via
// the standard back-button affordance that Flutter adds automatically when a
// route is pushed onto the navigator stack.

import 'package:flutter/material.dart';

import 'boardroom_page.dart';

class FullScreenChatPage extends StatelessWidget {
  const FullScreenChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BoardroomPage();
  }
}
