// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'app_lock_prefs.dart';

/// Optional entry gate. When the lock pref is off (default), it's a transparent
/// pass-through. When on, it requires biometric / device-credential auth before
/// revealing [child]. Auth errors fail closed to an explicit Unlock button.
class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  bool _unlocked = false;
  @override
  void initState() {
    super.initState();
    _maybeLock();
  }

  Future<void> _maybeLock() async {
    if (!await AppLockPrefs.isEnabled()) {
      if (mounted) setState(() => _unlocked = true);
      return;
    }
    bool ok = false;
    try {
      ok = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock Wearable',
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _unlocked = ok);
  }

  @override
  Widget build(BuildContext context) => _unlocked
      ? widget.child
      : Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: _maybeLock,
              child: const Text('Unlock Wearable'),
            ),
          ),
        );
}
