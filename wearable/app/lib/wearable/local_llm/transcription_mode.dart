// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Transcription mode + segmentation preferences for the on-device STT path.
//
// The app can transcribe wearable/mic audio one of two ways:
//   - cloud    : stream raw audio to Wearable's WS; Deepgram transcribes server-side
//                (the original, default path — see device_bridge / phone_mic).
//   - onDevice : transcribe locally with Gemma 4 (lib/wearable/local_llm/) and push
//                only the cleaned text to Wearable via POST /api/device/text.
//
// On-device is strictly opt-in. If selected but the model isn't installed or the
// platform can't run it, callers fall back to cloud (see [platformSupportsOnDevice]).

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TranscriptionMode { cloud, onDevice }

/// How an "utterance" is delimited when running on-device.
///   - button     : capture between AGENT_REQUEST press and release/timeout.
///                  Clear intent, low compute.
///   - continuous : always listening; split on silence (VAD) or the 30 s cap.
///                  Heavier on battery/thermals. Default.
///
/// This enum is now the *storage* form of a setting the wearer meets as
/// "Privacy Mode" (see [TranscriptionSettings.privacyMode]). It is deliberately
/// not renamed: an install that already chose `button` keeps that choice with
/// no migration step, and `CaptureDiagnostics` keeps reporting the same names.
enum OnDeviceSegmentation { button, continuous }

class TranscriptionSettings {
  TranscriptionSettings._();

  static const String modeKey = 'wearable.transcriptionMode';
  static const String segmentationKey = 'wearable.onDeviceSegmentation';

  static const TranscriptionMode defaultMode = TranscriptionMode.cloud;

  /// Continuous, i.e. Privacy Mode off — this is a capture device and the
  /// wearer asked for it to capture. Was `button` until Privacy Mode landed;
  /// an install that had explicitly chosen `button` still reads back `button`,
  /// so only installs that never touched the setting change behaviour.
  static const OnDeviceSegmentation defaultSegmentation = OnDeviceSegmentation.continuous;

  static Future<TranscriptionMode> mode() async {
    final prefs = await SharedPreferences.getInstance();
    return _parseMode(prefs.getString(modeKey));
  }

  static Future<void> setMode(TranscriptionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(modeKey, mode.name);
  }

  static Future<OnDeviceSegmentation> segmentation() async {
    final prefs = await SharedPreferences.getInstance();
    return _parseSegmentation(prefs.getString(segmentationKey));
  }

  static Future<void> setSegmentation(OnDeviceSegmentation segmentation) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(segmentationKey, segmentation.name);
  }

  static TranscriptionMode _parseMode(String? raw) {
    return TranscriptionMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => defaultMode,
    );
  }

  /// Privacy Mode — the wearer-facing name for the old `button` segmentation.
  ///
  /// On  : only button-armed captures are transcribed; ambient audio is decoded
  ///       for the pre-roll ring and then dropped, never stored or sent.
  /// Off : continuous capture (the default), and the button arms the next
  ///       utterance as an instruction instead of opening a window.
  ///
  /// Reads and writes [segmentationKey], so the two are always one setting:
  /// button ⇒ on, continuous ⇒ off.
  static Future<bool> privacyMode() async => privacyModeFor(await segmentation());

  static Future<void> setPrivacyMode(bool on) => setSegmentation(
        on ? OnDeviceSegmentation.button : OnDeviceSegmentation.continuous,
      );

  /// The stored-enum → Privacy Mode mapping, pure so callers holding a
  /// segmentation (the bridge, the Capture card) do not re-read prefs.
  static bool privacyModeFor(OnDeviceSegmentation segmentation) =>
      segmentation == OnDeviceSegmentation.button;

  static OnDeviceSegmentation _parseSegmentation(String? raw) {
    return OnDeviceSegmentation.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => defaultSegmentation,
    );
  }
}

/// Returns false on platforms that cannot run the LiteRT-LM model: the iOS
/// simulator (no Metal — flutter_gemma's 256 MB allocation cap) and any
/// non-mobile target. Real Android/iOS devices return true. The model-installed
/// check lives in [GemmaEngine.isInstalled]; combine both before enabling the
/// on-device path so a user can't select it on an unsupported device.
Future<bool> platformSupportsOnDevice({DeviceInfoPlugin? deviceInfo}) async {
  final info = deviceInfo ?? DeviceInfoPlugin();
  if (Platform.isAndroid) {
    final android = await info.androidInfo;
    return android.isPhysicalDevice;
  }
  if (Platform.isIOS) {
    final ios = await info.iosInfo;
    return ios.isPhysicalDevice; // simulator lacks Metal — unsupported
  }
  return false;
}
