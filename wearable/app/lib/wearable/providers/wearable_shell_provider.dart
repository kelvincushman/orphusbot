// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableShellProvider — which bottom-nav tab is showing, plus a small back
// stack so the system back gesture returns to the previous tab instead of
// leaving the app.
//
// Tabs: 0=Transcripts, 1=Tasks, 2=Home, 3=Wearable. Chat is the centre FAB and
// pushes a route, so it is not a tab index.

import 'package:flutter/foundation.dart';

class WearableShellProvider extends ChangeNotifier {
  static const int maxTabIndex = 3;
  static const int _maxHistory = 16;

  int _selectedIndex = 0;
  int get selectedIndex => _selectedIndex;

  final List<int> _history = [];

  void setIndex(int index) {
    final clamped = index.clamp(0, maxTabIndex);
    if (clamped == _selectedIndex) return;
    if (_history.isEmpty || _history.last != _selectedIndex) {
      _history.add(_selectedIndex);
      if (_history.length > _maxHistory) _history.removeAt(0);
    }
    _selectedIndex = clamped;
    notifyListeners();
  }

  /// Returns to the previous tab. True when handled, false when the stack is
  /// empty and the caller should let the platform handle the back gesture.
  bool popTabHistory() {
    if (_history.isEmpty) return false;
    _selectedIndex = _history.removeLast().clamp(0, maxTabIndex);
    notifyListeners();
    return true;
  }
}
