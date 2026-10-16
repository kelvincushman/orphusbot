// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted state for the optional app lock. Disabled by default (no enable UI
/// exists yet — added in a later milestone).
class AppLockPrefs {
  static const _enabledKey = 'wearable.lock.enabled';
  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;
  static Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_enabledKey, v);
}
