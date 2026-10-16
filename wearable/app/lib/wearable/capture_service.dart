// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// CaptureService — starts and stops the Android foreground service that keeps
// this process out of the "cached" state while the wearable is streaming.
//
// The bug it fixes, with the system's own words:
//
//     Killing 3713:com.kelvinlee.wearable.dev (adj 850):
//     excessive binder traffic during cached
//
// The wearable delivers BLE notifications at 100/sec, all of it binder traffic
// from the Bluetooth stack. Cached (oom_score_adj 850) plus that firehose is a
// self-destruct: the harder the device works the sooner Android kills it. The
// wearer sees the firmware's amber/blue searching flash and a link that only
// comes back when they reopen the app.
//
// Note what this is NOT for. The Dart isolate already survives backgrounding —
// measured at 11 minutes backgrounded and 8 minutes in Doze with frames
// unbroken at 102 fps. Nothing here runs work in the background; it only
// changes the process's importance so the kill policy stops applying.
//
// Android only. Every method is a no-op elsewhere.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';

class CaptureService {
  CaptureService._();
  static final CaptureService instance = CaptureService._();

  static const MethodChannel _channel = MethodChannel('wearable/capture_service');

  /// Bypasses the Android-only guard so the idempotence and error-tolerance
  /// rules can be exercised in host tests, where Platform.isAndroid is false
  /// and every method would otherwise return before doing anything.
  @visibleForTesting
  static bool debugBypassPlatformCheck = false;

  static bool get _enabled => Platform.isAndroid || debugBypassPlatformCheck;

  bool _running = false;

  /// True while the foreground service is believed to be running.
  bool get isRunning => _running;

  /// Raise the process out of "cached". Idempotent.
  ///
  /// Never throws: a phone that refuses the service is worse off than one that
  /// accepts it, but it still works foregrounded, and taking the BLE bridge
  /// down over it would turn a degraded case into a broken one.
  Future<void> start() async {
    if (!_enabled || _running) return;
    try {
      await _channel.invokeMethod<bool>('start');
      _running = true;
      debugPrint('[CaptureService] foreground service started');
    } on PlatformException catch (e) {
      debugPrint('[CaptureService] start failed (${e.code}): ${e.message}');
    } on MissingPluginException {
      // Older install without the native side — nothing to do.
      debugPrint('[CaptureService] channel unavailable; skipping');
    }
  }

  /// Drop back to a normal background process. Idempotent.
  ///
  /// Called when the bridge detaches, so a disconnected wearable does not leave
  /// a notification the wearer cannot explain.
  Future<void> stop() async {
    if (!_enabled || !_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<bool>('stop');
      debugPrint('[CaptureService] foreground service stopped');
    } on PlatformException catch (e) {
      debugPrint('[CaptureService] stop failed (${e.code}): ${e.message}');
    } on MissingPluginException {
      // Nothing was started; nothing to stop.
    }
  }
}
