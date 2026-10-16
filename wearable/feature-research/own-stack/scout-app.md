# Scout: `app/` dependency map — can we delete the 298 upstream Dart files?

**Verdict up front: YES. Feasible, and easier than expected.**

`app/lib/wearable/` has exactly **11 outbound import edges** into upstream code,
spread over **7 of its 75 files**. None of them touch Firebase, generated code,
platform channels, or assets. Every one is either a one-line call or a
sub-100-line reimplementation. The real work is not untangling `lib/wearable/` —
it is writing the ~700–900 line app shell that upstream currently provides.

Method: exhaustive `grep` of every `import` / `export` / `part` directive in
all 75 files under `app/lib/wearable/`, normalized and de-duplicated, then each
external edge traced to its call sites. No sampling. No source modified.

Measured baseline (`app/lib`):

| | files | lines |
|---|---:|---:|
| `lib/wearable/**` (ours) | 75 | 18,732 |
| everything else (upstream-derived) | 298 | 62,995 |

---

## 1. Outbound: every `lib/wearable/**` import that escapes `lib/wearable/`

There are **11 unique external targets**, appearing on 11 import lines in 7 files.
There are **zero relative imports that escape** `lib/wearable/` (all 100+ relative
imports resolve inside the subtree), **zero** conditional/deferred imports,
**zero** `part` directives, and **zero** `export` re-exports.

| # | Importing file | Imports | Symbol(s) actually used | Call sites |
|---|---|---|---|---|
| 1 | `lib/wearable/device_bridge.dart:29` | `backend/schema/transcript_segment.dart` | `TranscriptSegment(...)` ctor | 2 (`:943`, `:1037`) |
| 2 | `lib/wearable/device_bridge.dart:30` | `providers/capture_provider.dart` | `CaptureProvider` type; `.onLocalTranscriptSegmentReceived()` | 1 field, 1 optional ctor arg, 2 calls |
| 3 | `lib/wearable/device_bridge.dart:31` | `utils/alerts/app_snackbar.dart` | `AppSnackbar.showSnackbarError()` | 1 (`:1114`) |
| 4 | `lib/wearable/local_llm/gemma_transcriber.dart:15` | `utils/audio/wav_bytes.dart` | `WavBytesUtil.getUInt8ListBytes()` (static) | 1 (`:52`) |
| 5 | `lib/wearable/wearable_root.dart:18` | `core/app_shell.dart` | `const AppShell()` | 1 (`:56`) |
| 6 | `lib/wearable/pages/wearable_mission_control_page.dart:13` | `providers/home_provider.dart` | `context.read<HomeProvider>().setIndex(0)` | 1 (`:816`) |
| 7 | `lib/wearable/pages/settings/wearable_voice_page.dart:15` | `backend/http/api/speech_profile.dart` | `userHasSpeakerProfile()` | 1 (`:92`) |
| 8 | `lib/wearable/widgets/wearable_drawer.dart:13` | `pages/settings/profile.dart` | `const ProfilePage()` | 1 (`:49`) |
| 9 | `lib/wearable/widgets/wearable_drawer.dart:14` | `pages/settings/settings_drawer.dart` | `SettingsDrawer.show(ctx)` | 1 (`:171`) |
| 10 | `lib/wearable/widgets/wearable_status_pill.dart:21` | `backend/preferences.dart` | `SharedPreferencesUtil().btDevice.id` | 1 (`:37`) |
| 11 | `lib/wearable/widgets/wearable_status_pill.dart:24` | `providers/device_provider.dart` | `DeviceProvider` in `Consumer2`; `.connectedDevice`, `.batteryLevel` | 1 widget |

The other **68 of 75** wearable files import nothing outside `lib/wearable/` except
`dart:`, `package:flutter/`, and 25 pub packages.

### Third-party packages `lib/wearable/**` actually uses

`provider`, `shared_preferences`, `http`, `web_socket_channel`, `flutter_gemma`,
`uuid`, `purchases_flutter`, `purchases_ui_flutter`, `flutter_blue_plus`,
`sherpa_onnx`, `record`, `path_provider`, `file_picker`, `webview_flutter`,
`url_launcher`, `opus_dart`, `multicast_dns`, `local_auth`, `image_picker`,
`flutter_secure_storage`, `device_info_plus`, `crypto`, `archive`.

That is 23 of the ~90 entries in `pubspec.yaml`. The rest (Firebase ×4,
`google_sign_in`, `sign_in_with_apple`, `awesome_notifications`, `upgrader`,
`geolocator`, `mixpanel`/GrowthBook, `frame_sdk`, `nordic_dfu`, `mcumgr_flutter`,
`just_audio`, `video_player`, `flutter_sound`, `pdf`, `fl_chart`, `lottie`,
`cached_network_image`, `window_manager`, …) exist only for upstream code.
`opus_flutter` is the one exception: wearable needs it indirectly, because
`opus_dart` requires `initOpus()` which `main.dart:151` calls.

---

## 2. Classification of the 11 edges

### (a) Trivially replaceable — 6 edges, ~1 line each

| Edge | Fix |
|---|---|
| `#5 AppShell` | `wearable_root.dart:56` returns the new Wearable home page instead. One token. |
| `#6 HomeProvider.setIndex(0)` | New `WearableShellProvider` (~25 lines) owning the bottom-nav index. Also needed by the new home page. |
| `#7 userHasSpeakerProfile()` | In Wearable mode the upstream function body *is* `WearableClient.instance.hasSpeechProfile()` (`speech_profile.dart:35`). Call `WearableClient` directly. |
| `#3 AppSnackbar.showSnackbarError` | 32-line upstream file whose only content is `ScaffoldMessenger.of(MyApp.navigatorKey…)`. Copy ~15 lines into `lib/wearable/`, or pass a callback. |
| `#10 SharedPreferencesUtil().btDevice.id` | Used solely to answer "has a wearable ever been paired". Replace with a wearable-owned `SharedPreferences` key (wearable already uses `shared_preferences` in 6 files). |
| `#4 WavBytesUtil.getUInt8ListBytes` | One pure static: WAV header + little-endian PCM16. ~25 lines lifted into `lib/wearable/local_llm/wav.dart`. Note it is not upstream-original logic (standard RIFF header), but rewrite it anyway for the licence goal. |

### (b) Moderate — 4 edges

| Edge | Size of replacement | Notes |
|---|---:|---|
| `#11 DeviceProvider` (639 lines) | **~150 lines** | Only `connectedDevice != null` and `batteryLevel` are read. Wearable already owns BLE scan + connect (`wearable_scan_page.dart`, 167 lines, drives `FlutterBluePlus.startScan` / `device.connect` / `WearableDeviceBridge.attach`). What is genuinely missing is (i) a GATT battery read (0x180F/0x2A19 — wearable never reads battery today) and (ii) auto-reconnect on app resume. Everything else in `DeviceProvider` is firmware-OTA, Mixpanel, and upstream notifications. |
| `#9 SettingsDrawer.show()` (569 lines) | **~150 lines** | The upstream settings sheet already routes to 4 wearable pages (`WearableSessionServerPage`, `WearableVoicePage`, `WearableWebhooksPage`, `WearableSafetyRulesPage`). New sheet lists those four plus About/version. The rest of the upstream sheet is auth/sign-out/developer/data-privacy. |
| `#8 ProfilePage` (323 lines) | **~80 lines, or delete** | Upstream profile is Firebase-account-shaped (delete account, people, speech profile, language) and pulls in `gen/assets.gen.dart`. Wearable has no account model. Either drop the drawer item or ship a thin "device identity" page (devId, pairing URL, app lock toggle). |
| `#1 TranscriptSegment` (220 lines) | **~40 lines, or delete** | Plain data class; the fields wearable sets are `id/text/speaker/isUser/personId/start/end/translations/speechProfileProcessed`. Note it transitively imports `backend/preferences.dart` for two fields wearable never touches. |

### (c) Hard — **0 edges**

Nothing in `lib/wearable/**` touches:

- **Firebase** — zero references (`Firebase`, `firebase_*`) outside three comment lines.
- **Auth / user identity** — no `AuthenticationProvider`, no `google_sign_in`, no `AuthService`. `WearableClient` authenticates with its own bearer token in `flutter_secure_storage`.
- **Generated code** — zero references to `lib/gen/assets.gen.dart`, `fonts.gen.dart`, `flutter_communicator.g.dart`, `env/*.g.dart`, `firebase_options_*.dart`, `flavors.dart` (`F.env`), or `Env.*`.
- **Platform channels** — zero `MethodChannel` / `EventChannel`. The 7 custom channels in the repo (`com.kelvinlee/ask_ai`, `screenCapturePlatform`, `com.kelvinlee/floating_control_bar`, `com.kelvinlee.apple_reminders`, `com.friend.ios/notifyOnKill`) are all upstream-only.
- **Assets** — zero `Image.asset` / `Lottie.` / `AssetImage` / `rootBundle` / `assets/` references. `wearable_theme.dart` asks for `fontFamily: 'Montserrat'`, which is **not declared in `pubspec.yaml`** (only "SF Pro Display" is), so wearable already renders on the platform default font. No asset dependency exists to break.
- **Provider tree** — the only upstream provider types wearable consumes are `DeviceProvider` (edge #11) and `HomeProvider` (edge #6). Wearable's own 6 providers plus `WearableSubscriptionService` are self-contained.

### The three import cycles

Three of the 11 edges are bidirectional, which looks alarming and is not:

| Cycle | Upstream side |
|---|---|
| `device_bridge` ↔ `capture_provider` | `capture_provider.dart:20-21` imports wearable's `transcription_mode.dart` + `wearable_audio_session.dart` to *stand down* when Wearable owns the audio (5 guard sites). |
| `wearable_status_pill` ↔ `device_provider` | `device_provider.dart:10` imports `WearableDeviceBridge` to attach/dispose on BLE connect/disconnect (2 sites). |
| `wearable_voice_page` ↔ `speech_profile` | `speech_profile.dart:9` imports `WearableClient` to route every call to Wearable when paired. |

Deleting upstream deletes both halves of each cycle at once. No untangling step.

---

## 3. Inbound: what breaks in upstream if we keep wearable and delete the rest

38 import lines across **13 upstream files** reach into `lib/wearable/`. All 13 are
in the delete set, so this is a map of what the new shell must re-provide, not
a blocker.

| Upstream file | Consumes from wearable | Meaning |
|---|---|---|
| `lib/main.dart` (13 imports) | `WearableRoot`, `WearableTheme`, `WearableSubscriptionService`, 6 wearable providers, `WearableClient`, `GemmaEngine` | **The boot chain. Must be rewritten, not deleted.** |
| `lib/pages/home/page.dart` (8) | `TranscriptsPage`, `TasksLedgerPage`, `HomeStatusPage`, `DeviceStatusPage`, `FullScreenChatPage`, `WearableBottomBar`, `WearableInFlightBanner`, `WearableDrawer`, `WearableStatusPill` | **The app shell. Must be rewritten.** |
| `lib/pages/settings/settings_drawer.dart` (4) | the 4 wearable settings pages | Must be rewritten (see edge #9). |
| `lib/mobile/mobile_app.dart` (1) | `AppLockGate` | 16-line file; fold into the new shell. |
| `lib/providers/capture_provider.dart` (2) | `transcription_mode`, `wearable_audio_session` | Deleted with upstream. |
| `lib/providers/device_provider.dart` (1) | `WearableDeviceBridge` | Deleted; attach/dispose moves to the new connection provider. |
| `lib/providers/speech_profile_provider.dart` (1) | `owner_voice` | Deleted; wearable's enrol flow (`wearable_enroll_voice_page.dart`) already owns this. |
| `lib/backend/http/api/speech_profile.dart` (1) | `WearableClient` | Deleted. |
| `lib/pages/action_items/…`, `conversation_detail/page.dart`, `conversations_page.dart`, `memories/page.dart` (7) | `WearableTheme`, `WearableRoutingSheet`, `WearableAskFab`, `WearableAgentMeta` | Pure upstream feature pages. Deleted, nothing to replace. |

**Tests:** `test/wearable/**` (12 files) import only `lib/wearable/**` — they survive
untouched. `test/mobile/mobile_app_test.dart` imports `mobile/mobile_app.dart`
and `pages/home/page.dart`; it must be rewritten against the new shell.

---

## 4. Entry chain: what booting actually requires

`main()` → `runZonedGuarded` → `_init()` → `runApp(MyApp)` → `MultiProvider`
(26 providers) → `MaterialApp(theme: WearableTheme.dark())` → `TalkerWrapper` →
`WearableRoot` → `AppShell` → `MobileApp` → `AppLockGate` → `HomePageWrapper` →
`HomePage` (4 wearable tabs).

`_init()` performs 17 steps. Classified:

**Wearable genuinely needs (keep, ~6 calls):**
- `WidgetsFlutterBinding.ensureInitialized()`
- `initOpus(await opus_flutter.load())` — required by `lib/wearable/local_llm/opus_pcm_decoder.dart`
- `await FlutterGemma.initialize()` — required by `lib/wearable/local_llm/gemma_engine.dart`
- `await GemmaEngine.instance.warmInstalledState()` — wearable-owned, rehydrates on-device STT across restarts
- `WearableClient.instance.loadCredentials()` + `WearableSubscriptionService.instance.configure(appUserId: devId)`
- `ble.FlutterBluePlus.setOptions(restoreState: true)` — wearable's own BLE reconnect wants this

**Upstream-only (drop, ~11 calls):** `Env.init`, `F.env` flavor branch,
`FlutterForegroundTask.initCommunicationPort()`, `ServiceManager.init()/start()`,
`Firebase.initializeApp` (+ the dev auth-emulator hook at `wearable-server.local:9099`),
`PlatformManager.initializeServices()`, `NotificationService.initialize()`,
`FirebaseMessaging.onBackgroundMessage`, `SharedPreferencesUtil.init()`,
`AuthService.getIdToken()`, `mixpanel.identify()`, `GrowthBookUtil.init()`,
`CrashlyticsManager.init()`, `FlutterError.onError`/`PlatformDispatcher.onError`
→ Crashlytics, `windowManager` desktop sizing.

**Provider tree:** of 26 providers registered in `main.dart`, **19 are upstream**
(`Connectivity`, `Authentication`, `Conversation`, `App`, `People`, `Usage`,
`Message`, `Capture`, `Device`, `Onboarding`, `Home`, `SpeechProfile`,
`ConversationDetail`, `DeveloperMode`, `Mcp`, `Memories`, `User`, `ActionItems`,
`Sync`) and **7 are wearable** (`WearableSubscriptionService`, `WearableConnection`,
`WearableTask`, `WearableTasks`, `WearableMissionControl`, `WearableSchedules`, `WearableChat`).
Of the 19, only `HomeProvider` (tab index) and `DeviceProvider` (BLE state)
need a wearable-owned replacement.

**Shell (`lib/pages/home/page.dart`, 515 lines):** already Wearable-shaped —
`_pages = const [TranscriptsPage(), TasksLedgerPage(), HomeStatusPage(),
DeviceStatusPage()]`, `WearableBottomBar`, `WearableDrawer`, `WearableInFlightBanner`,
`WearableStatusPill` in the AppBar, chat as a centre FAB pushing
`FullScreenChatPage`. The upstream residue is geolocation reporting via
foreground task, `NotificationService.register()`, `MyUpgrader`, Mixpanel
lifecycle events, `ConversationProvider.refreshConversations()`, and
deep-link route parsing. Roughly 150 lines of that file are load-bearing for
Wearable; the other ~365 are upstream plumbing.

---

## 5. Generated + config coupling

| Artifact | Wearable references | Verdict |
|---|---|---|
| `lib/gen/assets.gen.dart` (453 lines) | **0** (64 refs, all upstream) | Delete with assets. |
| `lib/gen/fonts.gen.dart` (15) | 0 | Delete. |
| `lib/gen/flutter_communicator.g.dart` (673, pigeon) | 0 | Delete with `ios/Runner/FlutterCommunicator.g.swift` + `RecorderHostApiImpl.swift`. |
| `lib/firebase_options_dev.dart` / `_prod.dart` (68 each) | 0 | Delete. |
| `lib/flavors.dart` (34, `F.env`) | 0 | Delete or replace with a 2-line const. |
| `lib/env/**` (5 files, 277 lines, envied-generated) | 0 | Delete. Wearable's config is a runtime-entered base URL + bearer token in `flutter_secure_storage`. |
| `lib/watch_interface.dart` (58) + `ios/kelvinleeWatchApp/**` | 0 | Delete. |
| `pubspec.yaml` assets block | 0 wearable refs | `assets/images/*`, `assets/fonts/SFPRODISPLAY*`, `assets/device_assets/frame_lib.lua`, `shorebird.yaml` — all upstream. Wearable ships no assets. |
| `pubspec.yaml` fonts block | declares only "SF Pro Display"; wearable asks for "Montserrat" | Wearable's font is currently a silent no-op. Add a real Montserrat (or `google_fonts`) when building the new shell — this is a **bug fix opportunity, not a coupling**. |
| `pubspec.yaml` dependencies | 23 of ~90 used by wearable (+`opus_flutter`) | ~66 entries prunable, including the local path package `packages/awesome_notifications_stub`. |
| `android/app/build.gradle` | plugins `com.google.gms.google-services` + `com.google.firebase.crashlytics` | Removable once Firebase Dart is gone. |
| `google-services.json` ×3, `GoogleService-Info.plist` ×3 | — | Deletable. |
| Native sources | `MyApp.kt`, `MainActivity.kt` (package `com.example.my_project`), `NotificationOnKillService.kt`, `AppleRemindersService.swift`, `NotificationService.swift`, watch app | All serve upstream channels. Deletable; the `com.friend.ios` / `com.example.my_project` package names are upstream residue worth renaming for the licence goal. |

---

## 6. Verdict

**"Delete 298, keep 75" is feasible.** The coupling is 11 thin edges, not an
entanglement. No Firebase, no auth, no generated code, no platform channels, no
assets reach into `lib/wearable/`. The three import cycles resolve themselves
because both halves are deleted in the same commit.

The cost is not *removal* — it is *replacement of the shell upstream was
providing*. Minimum set to write:

| # | New file | Replaces | Est. lines |
|---|---|---|---:|
| 1 | `lib/main.dart` (rewrite) | 448-line `main.dart` | ~120 |
| 2 | `lib/wearable/wearable_home_page.dart` | `pages/home/page.dart` (515) + `mobile/mobile_app.dart` (16) | ~160 |
| 3 | `lib/wearable/providers/wearable_shell_provider.dart` | `HomeProvider` (230) | ~25 |
| 4 | `lib/wearable/providers/wearable_wearable_provider.dart` | `DeviceProvider` (639) + `services/devices.dart` (275) + `bt_device.dart` (452) | ~150 |
| 5 | `lib/wearable/pages/wearable_settings_page.dart` | `SettingsDrawer` (569) | ~150 |
| 6 | `lib/wearable/pages/wearable_profile_page.dart` *(optional)* | `ProfilePage` (323) | ~80 or 0 |
| 7 | `lib/wearable/ui/wearable_snackbar.dart` | `AppSnackbar` (32) | ~20 |
| 8 | `lib/wearable/local_llm/wav.dart` | `WavBytesUtil.getUInt8ListBytes` | ~25 |
| 9 | `lib/wearable/models/wearable_transcript_segment.dart` *(optional)* | `TranscriptSegment` (220) | ~40 or 0 |
| | **plus in-place edits** | `wearable_root.dart` (1 line), `wearable_voice_page.dart` (1 line), `wearable_mission_control_page.dart` (1 line), `wearable_status_pill.dart` (2 lines), `device_bridge.dart` (~25 lines of CaptureProvider fan-out), `gemma_transcriber.dart` (1 line) | ~30 |
| | **Total new/changed** | | **~800** |

Plus non-Dart work: prune ~66 pubspec deps and the whole assets block, delete
6 Firebase config files and 2 gradle plugins, delete the upstream native
sources and the iOS watch app, rewrite `test/mobile/mobile_app_test.dart`.

**Effort: 2–4 focused days**, dominated by items 2, 4 and 5. Not weeks.

### Things that get *lost* (decide before deleting, not after)

1. **Wearable battery %.** `WearableStatusPill` shows it, but wearable never reads the
   GATT battery service — the number comes entirely from `DeviceProvider`.
   The new connection provider must add a 0x180F/0x2A19 read (~30 lines) or
   the pill loses a segment.
2. **BLE auto-reconnect on resume.** `DeviceProvider.periodicConnect(…)` is what
   re-attaches the bridge today. `wearable_scan_page.dart` only handles first
   connect. Reconnect logic must be ported (~60 lines).
3. **Firmware OTA.** `pages/home/firmware_update.dart` + `nordic_dfu` /
   `mcumgr_flutter` are upstream. Wearable has no OTA path. If OTA matters, that
   is a separate work item, not part of this deletion.
4. **The `CaptureProvider` transcript mirror.** `device_bridge` fans transcripts
   into the upstream conversation UI as a *secondary* sink. `TranscriptsPage`
   reads `OnDeviceTranscriptLog` (wearable-owned) directly, and `wearable_scan_page.dart`
   already calls `WearableDeviceBridge.attach(device)` with no `captureProvider`.
   So this sink is already optional. Recommend deleting it outright, which
   removes edges #1 and #2 for free.
5. **Foreground-service audio + geolocation reporting.** Upstream-only. Dropping
   them changes background-capture behaviour on Android — verify against the
   product intent before deleting.

### Free win discovered en route

Eight wearable files have **no importer anywhere in `app/lib`** and are already dead:
`wearable_tokens.dart`, `pages/knowledge_page.dart`, `pages/habitat_test_page.dart`,
`pages/wearable_mission_control_page.dart`, `pages/wearable_subscription_page.dart`,
`pages/schedules_page.dart`, `widgets/wearable_status_dot.dart`,
`widgets/wearable_task_row.dart`.

Notably **Mission Control, Schedules and Subscription are unreachable UI** —
`WearableDrawer` links only Hive Mind / Device Status / Dashboard / Settings /
Profile, and the bottom bar has 4 tabs plus a chat FAB. Deleting edge #6
(`HomeProvider`) is therefore free: its only call site is in a page nothing
can currently open. Either wire these three pages into the new shell or drop
them — but decide deliberately, because right now they are 2,339 lines of
unreferenced code inside the subtree we are calling "ours".
