// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Entry point. Six init steps, nine providers, one route: the pairing gate in
// WearableRoot decides between the pairing page and the home shell.
//
// There is no sign-in, no cloud account and no crash reporter — the app talks
// only to the self-hosted server the user pairs it to.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_gemma/flutter_gemma.dart' show FlutterGemma;
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:provider/provider.dart';

import 'wearable/local_llm/gemma_engine.dart';
import 'wearable/providers/wearable_chat_provider.dart';
import 'wearable/providers/wearable_connection_provider.dart';
import 'wearable/providers/wearable_device_provider.dart';
import 'wearable/providers/wearable_mission_control_provider.dart';
import 'wearable/providers/wearable_schedules_provider.dart';
import 'wearable/providers/wearable_shell_provider.dart';
import 'wearable/providers/wearable_task_provider.dart';
import 'wearable/providers/wearable_tasks_provider.dart';
import 'wearable/services/wearable_subscription_service.dart';
import 'wearable/ui/wearable_snackbar.dart';
import 'wearable/wearable_client.dart';
import 'wearable/wearable_root.dart';
import 'wearable/wearable_theme.dart';

Future<void> _init() async {
  // Opus: the wearable streams Opus frames; opus_dart needs its native library
  // loaded before LocalOpusDecoder can be constructed.
  initOpus(await opus_flutter.load());

  // flutter_gemma: sets up the service registry. Idempotent, Dart-only.
  // No STT backend is registered — ASR runs through sherpa_onnx now, not
  // LiteRT. Gemma is the text-polish stage only and never sees audio.
  await FlutterGemma.initialize();
  // initialize() does not restore a previously installed model, so rehydrate it
  // or on-device transcription silently falls back to cloud after a restart.
  await GemmaEngine.instance.warmInstalledState();

  // RevenueCat is keyed to the server-issued devId (one device, one user). When
  // not paired yet, configure anonymously; the pairing page identifies later.
  try {
    final creds = await WearableClient.instance.loadCredentials();
    await WearableSubscriptionService.instance.configure(appUserId: creds?.devId);
  } catch (e) {
    // Non-fatal — the app runs without subscriptions and the service exposes
    // lastError for the Plan page to surface.
    debugPrint('Wearable subscription init failed: $e');
  }

  // Lets the OS hand back BLE connections after the app is killed and relaunched.
  ble.FlutterBluePlus.setOptions(restoreState: true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _init();
  runApp(const WearableApp());
}

class WearableApp extends StatelessWidget {
  const WearableApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Subscription state — drives paywall visibility and pro gates.
        ChangeNotifierProvider.value(value: WearableSubscriptionService.instance),
        // Server reachability — drives the status pill and drawer footer.
        ChangeNotifierProvider(create: (_) => WearableConnectionProvider()),
        // BLE wearable state — connection, battery.
        ChangeNotifierProvider(create: (_) => WearableDeviceProvider()),
        // Which bottom-nav tab is showing.
        ChangeNotifierProvider(create: (_) => WearableShellProvider()),
        // In-flight agent work — drives the banner.
        ChangeNotifierProvider(create: (_) => WearableTaskProvider()),
        ChangeNotifierProvider(create: (_) => WearableTasksProvider()),
        ChangeNotifierProvider(create: (_) => WearableMissionControlProvider()),
        ChangeNotifierProvider(create: (_) => WearableSchedulesProvider()),
        // Boardroom chat — connects lazily when the chat page mounts.
        ChangeNotifierProvider(create: (_) => WearableChatProvider()),
      ],
      child: MaterialApp(
        title: 'Wearable',
        debugShowCheckedModeBanner: false,
        navigatorKey: wearableNavigatorKey,
        theme: WearableTheme.light(),
        themeMode: ThemeMode.light,
        home: const WearableRoot(),
      ),
    );
  }
}
