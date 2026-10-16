/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kelvinlee/wearable/security/app_lock_prefs.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('lock disabled by default', () async {
    expect(await AppLockPrefs.isEnabled(), isFalse);
  });
  test('enabling persists', () async {
    await AppLockPrefs.setEnabled(true);
    expect(await AppLockPrefs.isEnabled(), isTrue);
  });
}
