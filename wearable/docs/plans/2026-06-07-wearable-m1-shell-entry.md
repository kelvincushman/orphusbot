<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable M1 — Shell & Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Wearable boot as a personal app — pair to Wearable once, optional device lock, no Google sign-in or onboarding — with a center-hero-Chat 4-tab shell, and remove the dead KelvinLee screens.

**Architecture:** In-place strip & rebrand of the existing KelvinLee/Wearable Flutter app. Entry chain stays `WearableRoot` (pairing gate) → `AppShell` → `MobileApp`, but `MobileApp` is simplified to **bypass** the Firebase sign-in + onboarding gate (boot straight to the home shell after pairing) wrapped in an optional local-lock gate. Firebase internals are left dormant (NOT ripped out) to avoid destabilizing the deeply Firebase-coupled app — full decoupling is a later milestone. The bottom nav is rebuilt as a center raised round Chat button flanked by Tasks / Knowledge / Wearable / Menu. Dead KelvinLee screens (per `docs/APP-NAVIGATION.md` §8) are deleted with reference cleanup.

**Tech Stack:** Flutter 3.44.1 (fvm), Dart 3.10.7, provider, flutter_secure_storage, local_auth (new, for biometric), existing `WearableClient` pairing. Verify with `fvm flutter analyze` + `fvm flutter test` + build/install on device.

**Refs:** spec `docs/PRD-wearable-app.md`; screen map + triage `docs/APP-NAVIGATION.md`.

**Key decision — Firebase:** do NOT remove Firebase/AuthenticationProvider in M1. Bypass the *gate* only. Anything that reads a Firebase uid keeps working if a session exists; for the no-sign-in path, guard uid reads (Task 2). Full Firebase removal = later milestone.

---

## File structure

- `lib/mobile/mobile_app.dart` — MODIFY: drop auth/onboarding/persona/device-selection branches → lock gate → home.
- `lib/wearable/security/app_lock.dart` — CREATE: `AppLockGate` widget + `AppLockPrefs` (enabled, mode) using `local_auth` + a PIN fallback in `flutter_secure_storage`.
- `lib/wearable/security/app_lock_prefs.dart` — CREATE: pure prefs accessor (unit-testable).
- `lib/pages/home/page.dart` — MODIFY: bottom nav → center hero Chat + Tasks/Knowledge/Wearable/Menu; tab pages list.
- `lib/wearable/pages/knowledge_page.dart` — CREATE: Knowledge tab placeholder (real wiring is M3).
- `lib/wearable/widgets/wearable_bottom_bar.dart` — CREATE: the center-raised round-button bottom bar widget.
- Rebrand: `lib/wearable/pages/pairing_page.dart`, `lib/pages/settings/profile.dart`, `lib/pages/settings/device_settings.dart`, `lib/pages/onboarding/auth.dart` strings, app label in `android/app/src/main/AndroidManifest.xml` / iOS plist.
- DELETE (Task 6, per §8): `lib/pages/apps/**`, `lib/pages/settings/usage_page.dart`, `lib/pages/conversations/sync_page.dart` + sync subpages, `lib/pages/payments/**`, `lib/pages/persona/**`, plus dead screens — each with grep-driven reference cleanup.

---

## Task 1: Pair-only entry (bypass sign-in + onboarding)

**Files:**
- Modify: `lib/mobile/mobile_app.dart` (whole file)
- Test: `test/mobile/mobile_app_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// test/mobile/mobile_app_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/mobile/mobile_app.dart';

void main() {
  testWidgets('MobileApp boots to home without a signed-in user', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MobileApp()));
    await tester.pump();
    // HomePageWrapper is the only child; no AuthComponent / onboarding.
    expect(find.byType(MobileApp), findsOneWidget);
    expect(find.textContaining('Sign in', findRichText: true), findsNothing);
  });
}
```

- [ ] **Step 2: Run it — expect FAIL** (MobileApp still renders the auth gate / needs providers)

Run: `cd devices/wearable-kelvinlee/app && fvm flutter test test/mobile/mobile_app_test.dart`
Expected: FAIL.

- [ ] **Step 3: Rewrite `mobile_app.dart` to pair-only**

```dart
/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

import 'package:flutter/material.dart';
import 'package:kelvinlee/pages/home/page.dart';
import 'package:kelvinlee/wearable/security/app_lock.dart';

/// After WearableRoot's pairing gate, the personal app boots straight to the home
/// shell — no Firebase sign-in, no onboarding. An optional local lock (PIN /
/// biometric) gates entry when enabled. Firebase remains available internally
/// but is not required to use the app.
class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppLockGate(child: HomePageWrapper());
  }
}
```

- [ ] **Step 4: Run the test — expect PASS** (after Task 2 provides `AppLockGate`; if running Task 1 alone, temporarily `child: HomePageWrapper()` without the gate and add the gate in Task 2).

Run: `cd devices/wearable-kelvinlee/app && fvm flutter test test/mobile/mobile_app_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd devices/wearable-kelvinlee/app && fvm flutter analyze lib/mobile/mobile_app.dart
git add lib/mobile/mobile_app.dart test/mobile/mobile_app_test.dart
git commit -m "feat(app): pair-only entry — bypass sign-in + onboarding gate"
```

---

## Task 2: Optional local lock (PIN / biometric)

**Files:**
- Create: `lib/wearable/security/app_lock_prefs.dart`, `lib/wearable/security/app_lock.dart`
- Modify: `pubspec.yaml` (add `local_auth`)
- Test: `test/wearable/security/app_lock_prefs_test.dart`

- [ ] **Step 1: Failing prefs test**

```dart
// test/wearable/security/app_lock_prefs_test.dart
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
```

- [ ] **Step 2: Run — expect FAIL** (`app_lock_prefs.dart` absent)

Run: `cd devices/wearable-kelvinlee/app && fvm flutter test test/wearable/security/app_lock_prefs_test.dart` → FAIL.

- [ ] **Step 3: Implement `app_lock_prefs.dart`**

```dart
// lib/wearable/security/app_lock_prefs.dart
import 'package:shared_preferences/shared_preferences.dart';

class AppLockPrefs {
  static const _enabledKey = 'wearable.lock.enabled';
  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;
  static Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_enabledKey, v);
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Implement `AppLockGate`** (biometric via `local_auth`, falls through when disabled or unsupported)

```dart
// lib/wearable/security/app_lock.dart
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'app_lock_prefs.dart';

class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  bool _unlocked = false;
  @override
  void initState() { super.initState(); _maybeLock(); }
  Future<void> _maybeLock() async {
    if (!await AppLockPrefs.isEnabled()) { setState(() => _unlocked = true); return; }
    final auth = LocalAuthentication();
    bool ok = false;
    try {
      ok = await auth.authenticate(
        localizedReason: 'Unlock Wearable',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
    } catch (_) { ok = false; }
    if (mounted) setState(() => _unlocked = ok);
  }
  @override
  Widget build(BuildContext context) => _unlocked
      ? widget.child
      : Scaffold(body: Center(child: ElevatedButton(onPressed: _maybeLock, child: const Text('Unlock Wearable'))));
}
```

- [ ] **Step 6: Add dep + analyze + commit**

```bash
cd devices/wearable-kelvinlee/app && fvm flutter pub add local_auth && fvm flutter analyze lib/wearable/security/
git add lib/wearable/security/ test/wearable/security/ pubspec.yaml pubspec.lock
git commit -m "feat(app): optional local lock (biometric/PIN) gate"
```

---

## Task 3: Orphan onboarding from entry (defer deletion)

**Files:** Modify `lib/mobile/mobile_app.dart` (done in T1 — no longer imports onboarding). Verify nothing else routes into `OnboardingWrapper`/`DeviceSelectionPage` for the boot path.

- [ ] **Step 1:** `grep -rn "OnboardingWrapper\|DeviceSelectionPage" lib/ | grep -v onboarding/` — confirm no remaining entry references (deep-link/notification routes may remain; leave for M1d deletion).
- [ ] **Step 2:** `fvm flutter analyze lib/` — expect no new errors from the orphan (files still compile; just unreferenced from entry).
- [ ] **Step 3: Commit** `git commit -am "chore(app): remove onboarding from boot path"` (no-op if T1 covered it).

---

## Task 4: Wearable rebrand (entry + visible strings + app label)

**Files:** Modify app label (`AndroidManifest.xml` `android:label`, iOS `CFBundleDisplayName`), `pairing_page.dart`, `profile.dart`, `device_settings.dart`, auth landing strings.

- [ ] **Step 1:** Set Android `android:label="Wearable"` and iOS `CFBundleDisplayName` = `Wearable`.
- [ ] **Step 2:** Replace visible "KelvinLee" copy on KEEP screens with "Wearable"/"Wearable": Profile ("Manage your KelvinLee persona"→remove persona row; "Teach KelvinLee your voice"→"Teach Wearable your voice"; "Tell KelvinLee who said it"→"Tell Wearable who said it"), Speech Profile ("KelvinLee needs to learn your voice"→"Wearable…"), Device Settings ("KelvinLee DevK"/"Wearable KelvinLee DK2" display→"Wearable Wearable"). Leave brand assets for a design pass.
- [ ] **Step 3:** `grep -rn "Share KelvinLee\|KelvinLee for Android\|KelvinLee for Mac" lib/pages/settings/settings_drawer.dart` → remove those tiles.
- [ ] **Step 4: Analyze + commit** `fvm flutter analyze lib/` ; `git commit -am "feat(app): Wearable rebrand — app label + visible KelvinLee strings"`.

---

## Task 5: Center-hero-Chat bottom nav shell

**Files:**
- Create: `lib/wearable/widgets/wearable_bottom_bar.dart` (center raised round Chat button + 4 destinations + menu)
- Create: `lib/wearable/pages/knowledge_page.dart` (placeholder: "Knowledge — coming in M3", scaffold)
- Modify: `lib/pages/home/page.dart` (tab list → [Tasks(merged later), Knowledge, Chat(center), Wearable, Menu]; for M1 map: index0 Boardroom/Chat, index1 Tasks ledger, index2 Knowledge, index3 Wearable=DeviceStatus; Menu opens SettingsDrawer)

- [ ] **Step 1:** Create `knowledge_page.dart` — a `Scaffold` with AppBar "Knowledge" + centered "Coming soon (M3)" empty state. `fvm flutter analyze` it.
- [ ] **Step 2:** Create `wearable_bottom_bar.dart` — a `Stack`/`BottomAppBar` with a raised circular `FloatingActionButton` (center) for Chat (onTap → select chat index; onLongPress callback for voice), and four `IconButton`s (Tasks, Knowledge, Wearable, Menu). Expose `currentIndex`, `onSelect(int)`, `onChatLongPress`.
- [ ] **Step 3:** Wire into `home/page.dart`: replace the existing `BottomNavigationBar` with `WearableBottomBar`; set the `IndexedStack` children to `[BoardroomPage, TasksLedgerPage, KnowledgePage, DeviceStatusPage]`; Menu → `SettingsDrawer.show(context)`. Keep existing AppBar/drawer for now.
- [ ] **Step 4:** `fvm flutter analyze lib/pages/home/page.dart lib/wearable/widgets/wearable_bottom_bar.dart` → clean.
- [ ] **Step 5: Build + install + visually verify** the center Chat button + tabs.

```bash
cd devices/wearable-kelvinlee/app && fvm flutter build apk --flavor dev --debug
adb install -r build/app/outputs/flutter-apk/app-dev-debug.apk
```
Verify: center round Chat button raised; Tasks/Knowledge/Wearable/Menu reachable; **on-device model shows "Installed"** (validates the Task-0 durability fix already shipped).

- [ ] **Step 6: Commit** `git commit -am "feat(app): center-hero-Chat bottom nav (Chat/Tasks/Knowledge/Wearable/Menu)"`.

---

## Task 6: Delete dead KelvinLee screens (§8) — incremental

For EACH group below: delete files → `grep -rn "<ClassName>" lib/` → remove now-dead imports/refs → `fvm flutter analyze lib/` clean → commit. Do one group per commit so a break is easy to bisect.

- [ ] **6a Apps marketplace:** `rm -r lib/pages/apps/` ; clean refs (deep-link `apps` handler in `home/page.dart`, AppsPage entry in chat header). Analyze. Commit.
- [ ] **6b Usage Insights:** `rm lib/pages/settings/usage_page.dart` ; remove SettingsDrawer tile + upgrade-prompt refs. Analyze. Commit.
- [ ] **6c Storage/WAL + SD card:** `rm lib/pages/conversations/sync_page.dart lib/pages/conversations/wal_item_detail/* lib/pages/conversations/private_cloud_sync_page.dart lib/pages/conversations/synced_conversations_page.dart lib/pages/sdcard/*` ; clean SettingsDrawer + DeviceSettings refs. Analyze. Commit.
- [ ] **6d Payments + Persona + Twitter:** `rm -r lib/pages/payments/ lib/pages/persona/` ; clean Profile refs (Persona/Payment rows). Analyze. Commit.
- [ ] **6e Dead conversation/memory pages:** remove ConversationCapturing/Processing/CompareTranscripts/CategoryMemories/MemoriesReview/ActionItems if unreferenced (`grep` first). Analyze. Commit.

> Leave Conversations/ConversationDetail/Memories until M3 (Knowledge) decides what's reused.

---

## Self-review notes
- **Spec coverage:** R3 entry (T1–T4), nav §4 (T5), removals §6 (T6). Knowledge/Tasks/Chat *content* (R1–R3) are later milestones — M1 only stands up the shell + placeholders.
- **Firebase risk:** T1 bypasses the gate but keeps Firebase; if a KEEP screen crashes on a null uid in the no-sign-in path, guard that read in the same commit (note in T1 review).
- **Order:** T1→T2 (lock gate referenced by T1), then T3–T6. T6 after T5 so deletions don't break the nav mid-flight.
