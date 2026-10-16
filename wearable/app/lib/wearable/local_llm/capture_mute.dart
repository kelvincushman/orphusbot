// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// CaptureMute — session-level mute gate for on-device audio capture.
//
// Both WearableDeviceBridge and PhoneMicStreamer read `CaptureMute.instance.muted`
// before forwarding audio frames. Setting `muted = true` drops frames on
// both paths without stopping the recorder or BLE subscription.
//
// Persisting across sessions is intentionally NOT implemented — mute state
// resets to un-muted on each app launch so the user never wonders why
// capture stopped working.

import 'package:flutter/foundation.dart';

class CaptureMute extends ChangeNotifier {
  CaptureMute._();

  static final CaptureMute instance = CaptureMute._();

  bool _muted = false;

  bool get muted => _muted;

  /// Toggle mute on or off and notify listeners.
  set muted(bool value) {
    if (_muted == value) return;
    _muted = value;
    notifyListeners();
  }

  void toggle() => muted = !_muted;
}
