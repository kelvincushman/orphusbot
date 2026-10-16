<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable App — Navigation Map (mobile)

**Status:** COMPLETE — code map + 26 screenshots + onboarding + KelvinLee triage · **Date:** 2026-06-07 · App: `devices/wearable-kelvinlee/app` (package `com.wearable.app.dev`)
Scope: **mobile** build only (lib/, excluding lib/desktop). §0 = master map (start here); §1–§3 navigation; §4–§5 screen catalog; §7 screenshots+findings; §8 KelvinLee triage. Screenshots in `docs/screens/`.

> The app is the upstream **KelvinLee** app with a **Wearable** layer added on top. Today the signed-in shell is the **Wearable** UI (Boardroom + Mission/Tasks/Schedules), but most upstream KelvinLee screens are still present and reachable. The "Wearable vs KelvinLee" column matters for the rebuild (Step 3).

---

## 0. MASTER MAP (complete)

Legend — branding: **[N]** Wearable · **[O]** KelvinLee (rebrand) · **[~]** neutral. Shot: `#NN` = `docs/screens/NN-*.png`, `(code)` = mapped from source only. Verdict: **KEEP** / **FIX** / **REBRAND** / **REMOVE**.

```
LAUNCH  main.dart → WearableRoot
├─ NOT paired → WearablePairingPage ................. (code) [N] KEEP
└─ paired → AppShell → MobileApp
   ├─ SIGNED-OUT (auth flow)
   │  ├─ Wearable auth landing "Listen.Think.Act." onboarding [N] FIX typo "Wearable"
   │  ├─ KelvinLee "Get Started" intro ............... onboarding [O] REBRAND/REMOVE
   │  └─ Data&Privacy consent → Google ......... onboarding [O cloud copy] REWORK
   ├─ ONBOARDING post-auth: name→language→permissions→review→welcome→find-device→speech-profile→(5 device slides)  (code) [O/~] KEEP+audit
   └─ HOME SHELL  HomePage  (AppBar: gear→drawer · battery · status-dot · Ask→WearableRoutingSheet(code))
      ├─ Tab0 Boardroom (CoS chat) ............. #01 [N] KEEP
      ├─ Tab1 Mission Control .................. #02 [N] KEEP · FIX KPI overflow
      ├─ Tab2 Tasks ledger .................... #03 [N] KEEP  (→ TaskDetail (code/needs-data) KEEP)
      ├─ Tab3 Schedules ....................... #04 #19 [N] KEEP · FIX missing "+" FAB  (→ ScheduleEditSheet (code))
      └─ Drawer WearableDrawer .................... #05 [N]  (footer shows "Wearable error")
         ├─ Hive Mind ........................ #06 [N] KEEP
         ├─ Device Status .................... #07 [N] KEEP · FIX connection=error
         ├─ Dashboard (WebView) ............. #08 [N] KEEP
         ├─ Profile ......................... #09 #21 [O strings] KEEP+REBRAND
         │  ├─ Set Name · Primary Language → dialog #23 [~] KEEP
         │  ├─ Persona ..................... (code) [O] REMOVE (personal ed.)
         │  ├─ Speech Profile .............. #22 [O] KEEP+REBRAND
         │  ├─ Identifying Others (People) . #24 [N] KEEP
         │  ├─ Conversation Timeout ........ (code) [~] KEEP
         │  ├─ Payment Methods ............. (code) [~] REMOVE (personal ed.)
         │  └─ Delete Account .............. (code) [~] KEEP
         └─ Settings sheet (SettingsDrawer) . #10 #11
            ├─ [KelvinLee section]
            │  ├─ Profile (→ above)
            │  ├─ Usage Insights ........... #25 [O "Your KelvinLee Insights", broken] REMOVE
            │  ├─ Storage (audio WAL/cloud-sync) #26 [~] REMOVE/rework (superseded by on-device STT)
            │  ├─ Device Settings .......... #27 [O "KelvinLee DevK"/"Wearable KelvinLee DK2"] KEEP+REBRAND  (→ FW Update/OTA (code); SD Card Sync REMOVE)
            │  ├─ Share KelvinLee for Android/Mac  #10 [O] REMOVE
            │  └─ Send Feedback · Report a bug · Help Center [O] REBRAND/REMOVE
            └─ [Wearable section] #11
               ├─ Data & Privacy ........... (code) [~] KEEP
               ├─ Developer Mode ........... (code) [~] KEEP (dev)
               ├─ About Wearable .............. #18 [N] KEEP
               ├─ Wearable Session Server ..... #15 [N] KEEP
               ├─ Custom Webhooks ......... #16 [N] KEEP (UI-only; needs /api/webhooks)
               ├─ Safety Rules ............ #17 [N] KEEP (read-only)
               ├─ Voice & Hands-Free ...... #12 #13 [N] KEEP · FIX stale subtitle  (→ On-device model #14 [N] KEEP · FIX model-not-durable)
               └─ Sign Out

ORPHANED / DEAD upstream-KelvinLee (NOT reachable from Wearable shell — see §8)  → mostly REMOVE
  Conversations · ConversationDetail · ConversationCapturing · ProcessingConversation · CompareTranscripts
  Memories (+Category, +Review) · ActionItems (→ superseded by Tasks tab)
  Apps · ExploreInstall · AppDetail · AddApp · UpdateApp · ManageCreate · Reviews · AppHomeWeb · MarkdownViewer
  Sync/WAL detail · PrivateCloudSync · SyncedConversations · SD-card pages · FirmwareUpdate(legacy)
  Payments stub · Paypal/Stripe setup · Persona/Twitter clone flow · Chat(KelvinLee cloud) · RecordingsStoragePermission
```

### Findings (prioritized) — detail in §7
✅ **F1 [FIXED] model "Not installed" after restart** — model IS durable on disk (`app_flutter/gemma-4-E2B-it.litertlm`, metadata intact). Root cause: nothing rehydrated flutter_gemma's in-memory active-model state on launch (`FlutterGemma.initialize()` only inits ServiceRegistry, not the model manager). Fix: `GemmaEngine.warmInstalledState()` (calls `MobileModelManager.initialize()` rehydrate) awaited in `main.dart` after `FlutterGemma.initialize()`. · 🔴 **F2 Wearable connection=error** (health/hands-free probe)
🟠 F3 stale on-device subtitle · F4 Mission KPI overflow · F5 Schedules no "+" FAB · F6 app ANR under load · F7 Webhooks UI-only (no backend)
🟠 F8 **branding inconsistent** (Profile/Speech/Usage/Device say "KelvinLee"; rebrand all → Wearable) · ~~F9 "Wearable" typo~~ → **"Wearable" is the intended name** (Wearable → Wearable) · F10 onboarding KelvinLee "Get Started" + cloud-privacy copy → **onboarding removed entirely** (see PRD-wearable-app §3) · F11 mandatory Google auth → **removed** (pair-only entry) · F12 Usage Insights broken (cloud) · F13 Storage = KelvinLee cloud-STT WAL (superseded)
ℹ️ Wearable = **Seeed Xiao BLE Sense**, FW **`dk2-2.0.10`** (KelvinLee DevKit2 stock), in-app **OTA** path (firmware-flash track) · pairing healthy (`<device token>` device token; `<dashboard bearer>` dashboard bearer)

### Rebuild plan (derived from verdicts)
1. **FIX bugs** — F1 model durability (critical), F2 connection=error (critical), F3/F4/F5 UI, F6 jank.
2. **REBRAND** — one consistent pass: "Wearable"→Wearable, Profile/Speech "KelvinLee"→Wearable, Device "KelvinLee DevK"/"Wearable KelvinLee DK2"→Wearable, onboarding "Get Started"+privacy copy, About/Feedback/Help.
3. **REMOVE** — Usage Insights, Storage (KelvinLee WAL), Share-KelvinLee entries, Payments/Persona/Twitter, ActionItems, Apps marketplace tree, all DEAD/ORPHAN KelvinLee pages (§8). Reconcile Memories vs Wearable memory.
4. **BUILD (PRD UX)** — confirmation-answer capture (R7), habitat rendering (needs firmware), ambient classify→notes/tasks/ideas (server R2–R5).

---

## 1. Launch & auth gating (the entry chain)

```
main.dart (MyApp)                         lib/main.dart:229
 └─ WearableRoot                              lib/wearable/wearable_root.dart:23
     ├─ NOT paired to Wearable → WearablePairingPage        (enter Wearable URL + dashboard token)
     └─ paired → AppShell                 lib/core/app_shell.dart:22
         └─ MobileApp (width <1100)       lib/mobile/mobile_app.dart:12
             ├─ NOT signed in →
             │     ├─ persona created, no device → PersonaProfilePage
             │     └─ else → DeviceSelectionPage   (pre-auth landing)
             ├─ signed in + onboarding INCOMPLETE → OnboardingWrapper  (see §2)
             └─ signed in + onboarding COMPLETE → HomePage  (see §3)
```

- **Two independent gates:** (1) Wearable pairing (`WearableClient.isPaired()`), (2) Firebase/Google auth + `onboardingCompleted`.
- Auth is **Firebase (Google/Apple sign-in)** — still required (not yet stripped). Force-stopping the app logs you out.

**Navigation mechanisms:** bottom-tab `HomeProvider.setIndex()` (IndexedStack); `Navigator.push` / `routeToPage()` (`lib/utils/other/temp.dart`, supports `replace:`); `MaterialPageRoute`; drawers + modal bottom sheets. No central named-routes table. Deep links via `navigateToRoute` (`/mission`,`/tasks`,`/schedules`,`/chat`,`/apps`,`/settings`,`/facts`).

---

## 2. Onboarding flow (in order) — `lib/pages/onboarding/wrapper.dart:31`

| # | Screen | File | Does |
|---|---|---|---|
| 0 | Auth / sign-in | `onboarding/auth.dart` (AuthComponent) | Google/Apple sign-in |
| 1 | Name | `onboarding/name/name_widget.dart` | enter given name |
| 2 | Primary language | `onboarding/primary_language/primary_language_widget.dart` | language picker |
| 3 | Permissions | `onboarding/permissions/permissions_widget.dart` | location/notifications/(Android bg) |
| 4 | App-store review | `onboarding/user_review_page.dart` | review prompt |
| 5 | Welcome / pairing intro | `onboarding/welcome/page.dart` | intro; "Continue" or "Skip device setup" |
| 6 | Find device (BLE) | `onboarding/find_device/page.dart` (FindDevicesPage) | BLE scan + pick wearable; "Skip" |
| 7 | Speech profile | `onboarding/speech_profile_widget.dart` | record voice samples |
| → | Device setup slides (×5) | `onboarding/device_onboarding/device_onboarding_wrapper.dart` | post-pick slides → sets `onboardingCompleted`, → HomePage |
| (extra) | Apple Watch permission | `onboarding/apple_watch_permission_page.dart` | iOS watch prompt |

---

## 3. Signed-in home shell — `lib/pages/home/page.dart:84` (HomePage)

- **Bottom nav (4 tabs)** → IndexedStack:
  | Tab | Screen | File | Purpose |
  |---|---|---|---|
  | 0 Boardroom | BoardroomPage | `wearable/pages/boardroom_page.dart` | SSE chat with Chief-of-Staff; mic button; thread side-sheet |
  | 1 Mission | WearableMissionControlPage | `wearable/pages/wearable_mission_control_page.dart` | KPI strip + in-flight task cards (polls `/api/mission-control`) |
  | 2 Tasks | TasksLedgerPage | `wearable/pages/tasks_ledger_page.dart` | unified task ledger (`/api/tasks`) → TaskDetailPage |
  | 3 Schedules | SchedulesPage | `wearable/pages/schedules_page.dart` | cron ledger; FAB → ScheduleEditSheet |
- **AppBar:** leading gear → opens drawer; title = battery %; right = WearableStatusDot + "Ask" FAB (tab 0 only → WearableRoutingSheet).
- **Drawer (WearableDrawer)** `wearable/widgets/wearable_drawer.dart:32`:
  | Item | Opens | File |
  |---|---|---|
  | Hive Mind | HiveMindPage | `wearable/pages/hive_mind_page.dart` |
  | Device Status | DeviceStatusPage | `wearable/pages/device_status_page.dart` |
  | Dashboard | WearableDashboardPage (WebView) | `wearable/pages/wearable_dashboard_page.dart` |
  | Settings | SettingsDrawer (bottom sheet) | `pages/settings/settings_drawer.dart` |
  | Profile | ProfilePage | `pages/settings/profile.dart` |

---

## 4. Wearable screens (the keep/extend set)

| Screen | File | Purpose | Reached from |
|---|---|---|---|
| BoardroomPage | wearable/pages/boardroom_page.dart | CoS chat (SSE) + mic | tab 0 |
| WearableMissionControlPage | wearable/pages/wearable_mission_control_page.dart | async PM dashboard | tab 1 |
| TasksLedgerPage | wearable/pages/tasks_ledger_page.dart | task ledger | tab 2 |
| TaskDetailPage | wearable/pages/task_detail_page.dart | task detail + inline pending-input reply | tap a task |
| SchedulesPage | wearable/pages/schedules_page.dart | cron ledger | tab 3 |
| ScheduleEditSheet | wearable/pages/schedule_edit_sheet.dart | create/edit cron (sheet) | Schedules FAB |
| HiveMindPage | wearable/pages/hive_mind_page.dart | cross-agent activity (shell) | drawer |
| DeviceStatusPage | wearable/pages/device_status_page.dart | BLE + Wearable health | drawer |
| WearableDashboardPage | wearable/pages/wearable_dashboard_page.dart | dashboard WebView | drawer |
| WearablePairingPage | wearable/pages/pairing_page.dart | pair to Wearable (URL + token) | pre-shell when unpaired |
| WearableScanPage | wearable/pages/wearable_scan_page.dart | BLE scan/connect wearable | pairing/reconnect |
| WearableSubscriptionPage | wearable/pages/wearable_subscription_page.dart | plan/subscription | settings |
| WearableRoutingSheet | wearable/widgets/wearable_routing_sheet.dart | "Ask Wearable" dispatch (text+mic) | Ask FAB |
| **Settings:** WearableVoicePage | wearable/pages/settings/wearable_voice_page.dart | speech profile, hands-free, **on-device transcription toggle** | SettingsDrawer |
| WearableOnDeviceModelPage | wearable/pages/settings/wearable_on_device_model_page.dart | Gemma 4 model download/sideload/remove | from WearableVoicePage |
| WearableSessionServerPage | wearable/pages/settings/wearable_session_server_page.dart | server URL / change pairing | SettingsDrawer |
| WearableSafetyRulesPage | wearable/pages/settings/wearable_safety_rules_page.dart | read-only safety rules | SettingsDrawer |
| WearableWebhooksPage | wearable/pages/settings/wearable_webhooks_page.dart | webhooks (UI only) | SettingsDrawer |
| WearableHabitatTestPage | wearable/pages/habitat_test_page.dart | **dev-only** habitat alert tester | not in normal nav |

---

## 5. Upstream KelvinLee screens still present (rebuild: keep / repurpose / remove)

Chat/conversations: ChatPage* (KelvinLee cloud — likely remove), ConversationsPage, ConversationDetailPage, ConversationCapturingPage, ProcessingConversationPage, CompareTranscriptsPage, SelectTextScreen, CloneChatPage.
Memories: MemoriesPage, CategoryMemoriesPage, MemoriesReviewPage.
Apps/integrations: AppsPage, ExploreInstallPage, CategoryAppsPage, AppDetailPage, ReviewsListPage, AppHomeWebPage, AddAppPage, UpdateAppPage, ManageCreatePage, MarkdownViewer.
Action items: ActionItemsPage.
Settings: SettingsDrawer, ProfilePage, UserPeoplePage, AboutKelvinLeePage, DeveloperSettingsPage, DeviceSettings, DataPrivacyPage, PrivacyInfoPage, UsagePage, DeleteAccount, RecordingsStoragePermission, PaymentWebViewPage, PageWebView.
Speech/voice: SpeechProfilePage, UserSpeechSamples.
Payments/personas: PaymentsPage(stub), PaypalSetupPage, StripeConnectSetupPage(stub), PersonaProfilePage, SocialHandleScreen, VerifyIdentityScreen, CloneSuccessScreen.
Sync/SD: SyncPage, WalItemDetailPage, PrivateCloudSyncPage, SyncedConversationsPage, AboutSdCardSync, SdCardTransferProgress.
Device/firmware: ConnectDevicePage, FindDevicesPage (reused), FirmwareUpdate, FirmwareUpdateDialog.

\* **Flagged dead/stub/dev-only:** ChatPage (KelvinLee cloud, unreachable from nav), StripeConnectSetupPage (empty), PaymentsPage (stub), PrivacyInfoPage (maybe deprecated), WearableHabitatTestPage (dev-only).

---

## 6. Screenshot checklist for Step 2 (reachable screens + how to reach)

Onboarding (needs signed-out / fresh state): 0 Auth → 1 Name → 2 Language → 3 Permissions → 4 Review → 5 Welcome → 6 Find device → 7 Speech profile → device-setup slides.
Wearable pairing: WearablePairingPage (unpaired state).
Home tabs: Boardroom, Mission, Tasks (+ TaskDetail), Schedules (+ ScheduleEditSheet).
Drawer: Hive Mind, Device Status, Dashboard, Profile, Settings (SettingsDrawer) → WearableVoicePage → WearableOnDeviceModelPage, WearableSessionServerPage, WearableSafetyRulesPage, WearableWebhooksPage, WearableSubscriptionPage.
Ask: WearableRoutingSheet (Ask FAB).
KelvinLee (decide keep/remove): Conversations, ConversationDetail, Memories, Apps/Explore, AppDetail, ActionItems, Profile/About/Developer/DeviceSettings/DataPrivacy/Usage/Sync, SpeechProfile.

> Step 2 method: reconnect ADB → navigate (taps or guided) → `adb exec-out screencap` per screen → save to `docs/screens/<area>-<screen>.png` → append a behavior note + "keep/repurpose/remove (Wearable)" verdict under each in this doc.

---

## 7. Step 2 — captured screens & findings (in progress)

Screenshots in `docs/screens/`. (ADB tap-navigation drifts on rotation — **lock portrait** with `settings put system user_rotation 0` before capturing.)

| # | File | Screen | Observed | Verdict |
|---|---|---|---|---|
| 01 | 01-boardroom.png | Boardroom (tab0) | "Your Boardroom is quiet — Ask Wearable anything…"; gear, battery, status dot, Ask | KEEP (core) |
| 02 | 02-mission.png | Mission Control (tab1) | KPI cards (Active/Burned/Avg/Course-corrections=18) + "No tasks running" + corrections feed. **BUG: KPI cards RenderFlex overflow ("BOTTOM OVERFLOWED BY 32/48 px")** | KEEP — fix overflow |
| 03 | 03-tasks.png | Tasks ledger (tab2) | segmented Active/Needs input/Done; "Nothing active right now" | KEEP |
| 04 | 04-schedules.png | Schedules (tab3) | "No schedules yet — Tap + to create" (FAB not visible in shot) | KEEP — verify FAB |
| 05 | 05-drawer.png | WearableDrawer | Hive Mind, Device Status, Dashboard, Settings, Profile; footer **"Wearable error"** | KEEP |
| 06 | 06-hivemind.png | Hive Mind | (captured) | KEEP |
| 07 | 07-devicestatus.png | Device Status | Connection **Status: error** / Last healthy —; Wearable BLE **active**, Device <BLE MAC>; Wearable creds Paired **yes**, Device ID <device id>, Server https://<server>…, Active audio owner — | KEEP — **investigate connection=error** |
| 08 | 08-dashboard.png | Dashboard (WebView) | (captured) | KEEP |
| 09 | 09-profile.png | Profile | (captured) | review |
| 10 | 10-settings.png | Settings sheet (KelvinLee) | Profile, Usage Insights, Storage, Device Settings, **Share KelvinLee for Android/Mac**, Send Feedback, Report a bug, Help Center | **REBRAND/trim — still KelvinLee-branded**; Wearable settings are below (scroll) |
| 11 | 11-settings-scrolled.png | Settings sheet (Wearable section) | Data & Privacy, Developer Mode, **About Wearable**, Wearable Session Server, Custom Webhooks, Safety Rules, Voice & Hands-Free, Sign Out (v1.0.74 (436)) | KEEP |
| 12 | 12-wearable-voice.png | Voice & Hands-Free | Enroll voice; "Hands-free capture: **Disabled by operator policy**"; **"Transcribe on-device" toggle ON but subtitle "Install the model below to enable" (stale)**; Capture trigger Button/Continuous (Continuous) | KEEP — fix stale subtitle |
| 13 | 13-wearable-voice-scrolled.png | Voice & Hands-Free (lower) | Capture-trigger explainer; "Install on-device model (~2.6 GB)" tile; on-device explainer | KEEP |
| 14 | 14-wearable-ondevice-model.png | On-device model | **"Not installed"** + Download (~2.6 GB, Hugging Face, Wi-Fi) + Sideload .litertlm | KEEP — **model gone/undetected** |
| 15 | 15-wearable-session-server.png | Session Server | Base URL https://wearable-server.local:3141, Device ID <device id>, **Pairing token <device token>** (real device token), Forget Server | KEEP |
| 16 | 16-wearable-webhooks.png | Custom Webhooks | "POST with every final agent response"; "No webhooks yet"; **"Local-only preview: entries reset on app relaunch… when /api/webhooks is implemented"** | KEEP — UI-only (no backend yet) |
| 17 | 17-wearable-safety.png | Safety Rules | (captured — read-only safety rules view) | KEEP |
| 18 | 18-about-wearable.png | About Wearable | "local-first personal AI… data stays on the Wearable server"; Privacy, Source (kelvincushman/Wearable-MissionControl), Report issue, **License: MIT — derived from BasedHardware/kelvinlee** | KEEP — properly Wearable-branded |
| 19 | 19-schedules-no-fab.png | Schedules (FAB check) | "No schedules yet — Tap + to create" but **no visible "+" FAB / create button** | KEEP — **missing create-schedule button** |

### Key findings so far
**🔴 Critical (block the core on-device feature):**
1. ~~On-device model reads "Not installed" and the file is gone~~ **[FIXED — diagnosis corrected]**: the model is **durable on disk** (`app_flutter/gemma-4-E2B-it.litertlm` present, SharedPreferences metadata intact — my earlier "file gone" check looked at the wrong dir). True root cause: `FlutterGemma.hasActiveModel()` reads an **in-memory** field (`modelManager.activeInferenceModel`) that's only rehydrated by `MobileModelManager.initialize()`; nothing called that on launch (`FlutterGemma.initialize()` only inits ServiceRegistry), so after every restart it was null → "Not installed" → device_bridge fell back to cloud. **Fix shipped:** `GemmaEngine.warmInstalledState()` (→ `MobileModelManager.initialize()` rehydrate) awaited in `main.dart` right after `FlutterGemma.initialize()`. `flutter analyze` clean. Needs rebuild+install to verify on device.
2. **Wearable connection health = `error`** (Device Status "Status: error" + drawer "Wearable error") despite Paired=yes & BLE active. Likely the failing health/hands-free probe (earlier `handsFreeStatus 401`). **Diagnose the health/hands-free check.**

**🟠 Minor:**
3. **Stale subtitle** on Voice page (toggle ON but "Install the model below").
4. **Mission Control KPI cards overflow** (RenderFlex bottom overflow).
5. **Settings still partly KelvinLee-branded** ("Share KelvinLee for Android/Mac", KelvinLee help) — rebrand/trim.
6. **Schedules has no visible "+" / create-schedule button** (says "Tap +" but none shown).
7. **App ANR under rapid navigation** — fast back-to-back taps/`am start` triggered an Android "isn't responding" dialog (recovered via Wait). Capture/automation must pace itself; may also indicate a main-thread jank issue to check.
8. Webhooks is **UI-only** (no `/api/webhooks` backend); pairing token confirmed healthy (`<dashboard bearer>` = dashboard bearer, `<device token>` = device token).
9. **Onboarding mixes Wearable + KelvinLee branding** (captured signed-out): an **"KelvinLee — Your AI Companion / Never take notes again"** Get-Started intro screen remains, and the Google-sign-in **Data & Privacy** sheet says *"all data… stored on **our servers**"* — cloud framing that contradicts Wearable's local-first positioning. **Rebrand/rework.**
10. **Typo on the Wearable auth landing**: *"Wearable"* (should be Wearable / Wearable). Copy is otherwise good: "Listen. Think. Act. — your personal AI, five specialist agents in one wearable."
11. **Auth is mandatory Firebase Google sign-in** (no skip) before any use — reconsider for a personal/local-first edition.

### Step 2 status
**Done — full Wearable keep/extend set captured (19 shots):** all 4 tabs, drawer + 5 pages, Device Status, all 6 Wearable settings pages (Voice, On-device model, Session Server, Webhooks, Safety, About) + the Settings sheet (KelvinLee + Wearable sections).

**Not captured (lower value / blocked):**
- **Orphaned upstream-KelvinLee pages** (Conversations, Memories, Apps/Explore, Action Items, Sync, SpeechProfile, ConversationDetail): **no longer reachable from the Wearable shell** (the Wearable 4-tab nav replaced the KelvinLee home) — effectively already cut from navigation. Verify in code before deleting.
- KelvinLee settings sub-pages (Usage Insights, Storage, Device Settings, Data & Privacy, Developer Mode): reachable via Settings sheet; triage for keep/rebrand.
- TaskDetail (needs an active/done task), Subscription (pro-gated), ScheduleEditSheet (FAB missing), WearableRoutingSheet/Ask (Boardroom is the primary chat).
- **Onboarding — pre-auth screens captured** (signed-out): (1) Wearable auth landing "Listen. Think. Act." [Wearable-branded, typo "Wearable"]; (2) **KelvinLee "Get Started" intro** [KelvinLee-branded — rebrand/remove]; (3) **Data & Privacy** consent sheet before Google [cloud "our servers" copy — rework]. Post-auth steps (name → language → permissions → review → welcome → find-device → speech-profile, §2) documented from code; not shot to avoid re-login.

### Keep-set sweep (user-driven, shots 21–27)
| # | File | Screen | Observed | Verdict |
|---|---|---|---|---|
| 21 | 21-profile.png | Profile | Set Your Name (Not set), Primary Language (Not set), Persona, Speech Profile, Identifying Others, Conversation Timeout, Payment Methods. **3 "KelvinLee" strings: "Manage your KelvinLee persona", "Teach KelvinLee your voice", "Tell KelvinLee who said it"** | KEEP — rebrand copy |
| 22 | 22-speech-profile.png | Speech Profile | Voice-enroll dot animation; **"KelvinLee needs to learn your voice…"**; Get Started; "Recognizing others 👀" | KEEP — rebrand copy |
| 23 | 23-language-picker.png | Primary Language dialog | "Tell us your primary language"; search + English/Spanish/Chinese…; Confirm | KEEP (clean) |
| 24 | 24-people.png | People | "Create a new person and train **Wearable** to recognize their speech too!"; + to add | KEEP — already Wearable-branded |
| 25 | 25-usage-insights.png | Usage Insights | Title **"Your KelvinLee Insights"**; Today/Month/Year; **"Failed to load available plans"** (cloud/billing-dependent, broken) | **REMOVE** (KelvinLee cloud billing analytics) |
| 26 | 26-storage.png | Storage (SyncPage) | Complete Archive, **Private Cloud Sync** (Off), **85 audio recordings (47.5 MB, 1h43m) ready to convert**, "Process Audio" | **REMOVE/rework** — KelvinLee cloud-STT WAL, superseded by on-device STT + server pipeline |
| 27 | 27-device-settings.png | Device Settings | **Name "KelvinLee DevK", Model "Wearable KelvinLee DK2", HW "Seeed Xiao BLE Sense", FW `wearable-0.1.0+dk2-2.0.10`** (= KelvinLee DevKit2 stock 2.0.10), **OTA "Update Latest Version" path**, SD Card Sync, Disconnect | KEEP — rebrand; **OTA may flash Wearable firmware** |

**Sweep findings:**
12. **Branding is inconsistent** across the app: People & auth landing say "Wearable"; Profile, Speech Profile, Usage ("Your KelvinLee Insights"), Device ("KelvinLee DevK") still say "KelvinLee". Needs a consistent rebrand pass.
13. **Usage Insights is broken** ("Failed to load available plans") — cloud/billing-dependent → REMOVE.
14. **Storage = KelvinLee cloud-STT WAL** (85 recordings queued for "Process Audio" → KelvinLee cloud) → superseded by Wearable on-device STT; REMOVE/rework.
15. **Wearable firmware = KelvinLee DevKit2 stock `dk2-2.0.10`** on Seeed Xiao BLE Sense, with an in-app **OTA update path** — relevant to the firmware-flash track (OTA may be an option vs nrfjprog).

| 28 | 28-developer-settings.png | Developer Settings | Debug logs (Share/delete, auto-del 3d) · Export Conversations (JSON) · **Developer API Keys errors "Failed to load API keys: Not authenticated"** (KelvinLee cloud) | KEEP debug-logs; REMOVE/rework KelvinLee Developer-API |

16. **Developer API Keys broken** ("Not authenticated") — KelvinLee cloud Developer-API, errors offline → REMOVE/rework (keep local Debug-logs).

### Still un-shot (keep-set): Data & Privacy, Payment Methods, Conversation Timeout, firmware Update page; TaskDetail (needs data), Ask sheet, Subscription (gated).

---

## 8. Upstream-KelvinLee page triage (code-derived reachability + rebuild verdict)

Reachability assessed from the **current Wearable shell** (HomePage 4-tab nav + WearableDrawer + Settings sheet). Classes: **REACHABLE-UI** (normal tap path), **DEEPLINK-ONLY** (only via `navigateToRoute` URI/notification), **ORPHAN-CHAIN** (only from an orphaned page), **DEAD/STUB** (no inbound refs / empty).

### KEEP — reachable & wired (integrate as-is, rebrand KelvinLee→Wearable copy where needed)
Settings chain (Drawer → Settings sheet → …): **ProfilePage, UsagePage, SyncPage (→PrivateCloudSyncPage, SyncedConversationsPage), DeviceSettings, DataPrivacyPage, DeveloperSettingsPage, AboutKelvinLeePage** (rename→About Wearable), **PageWebView**.
Profile chain: **SpeechProfilePage, UserPeoplePage, PaymentsPage, PrivacyInfoPage, DeleteAccount, PersonaProfilePage**.
Other reachable: **ConnectDevicePage** (battery widget → Connect Device), **ChatPage** (deeplink + App Detail), **SelectTextScreen, CloneChatPage, AppsPage** (via ChatPage header), **AddAppPage, ExploreInstallPage** (inside AppsPage).

### DEEPLINK-ONLY — reachable only via URI/notification (decide: surface or drop)
- **MemoriesPage** (`/facts`) — REPURPOSE: wire a "Memories" drawer item or fold into Boardroom; this is the upstream "facts" store (overlaps Wearable memory/Obsidian — reconcile).
- **AppDetailPage** (`/apps/{id}`) — REPURPOSE only if the apps marketplace stays.

### ORPHAN-CHAIN — unreachable from Wearable shell (intentionally cut in M-1)
- **ConversationsPage, ConversationDetailPage** — REMOVE or restore a Wearable "Conversations" view (note: conversation capture/notes now belong to the server-side ambient pipeline + Obsidian per the PRD).
- **ActionItemsPage** — REMOVE; superseded by **TasksLedgerPage** (Wearable tab).
- **CategoryMemoriesPage, MemoriesReviewPage** — REMOVE unless MemoriesPage is restored.

### DEAD/STUB — no inbound nav / empty (safe to REMOVE)
ConversationCapturingPage, ProcessingConversationPage, CompareTranscriptsPage, CategoryAppsPage, ReviewsListPage, AppHomeWebPage, UpdateAppPage, MarkdownViewer, WalItemDetailPage, AboutSdCardSync, SdCardTransferProgress, FirmwareUpdate, RecordingsStoragePermission, PaymentWebViewPage, PaypalSetupPage, StripeConnectSetupPage, ManageCreatePage (un-wired). *(Verify no provider/state refs before deleting.)*

### Rebuild notes
1. **Conversations/ActionItems already cut from nav** — the Wearable shell deliberately replaced the KelvinLee home; conversation→notes/tasks now flow through the **server-side ambient pipeline + Obsidian** (PRD R2–R5), not these screens.
2. **Memories vs Wearable memory** — upstream `MemoriesPage`/facts overlaps Wearable's memory (`main.md`/`overheard.md`) + Obsidian; pick one model.
3. **Apps marketplace** (AppsPage/AddApp/AppDetail) is KelvinLee-specific — decide if Wearable keeps a marketplace or removes the whole `pages/apps/**` tree.
4. **Payments/Persona/Twitter** are KelvinLee monetization/clone features — likely REMOVE for the personal Wearable edition (PaymentsPage is already a stub).

> Inventory complete: §4–5 (Wearable + KelvinLee screens), §7 (Wearable screenshots + findings), §8 (KelvinLee triage). Onboarding screenshots remain the only un-captured set (needs signed-out pass).
