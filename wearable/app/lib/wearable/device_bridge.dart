// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDeviceBridge — subscribes to the BLE GATT streams the KelvinLee firmware
// already exposes and forwards them to Wearable's device channel:
//
//   Audio characteristic (19B10001-...) → Wearable WS /api/device/ws/audio
//   Button characteristic (23BA7924-...) → Wearable HTTP /api/device/event
//   Wearable command queue (/api/device/command/poll) → GATT 0xCAB1AB97 write
//
// Runs inside the app process (no foreground-service escalation here — the
// KelvinLee app already requests one; this bridge rides that existing permission).
// The bridge is started after a BLE connection is established AND Wearable
// credentials are present. It stops cleanly on either side disconnecting.
//
// Intentionally decoupled from the upstream KelvinLee providers — a thin adapter
// that can be attached without mutating device_provider.dart. Phase 3's
// final wiring layer will call `WearableDeviceBridge.attach(...)` from the
// existing BLE-connected callback site.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ui/wearable_snackbar.dart';

import 'capture_service.dart';
import 'command_codec.dart';
import 'wearable_client.dart';
import 'local_llm/audio_buffer.dart' show UtteranceBuffer, pcmRms;
import 'local_llm/capture_diagnostics.dart';
import 'local_llm/capture_mute.dart';
import 'local_llm/capture_state.dart';
import 'local_llm/diarization_engine.dart';
import 'local_llm/zipformer_transcriber.dart';
import 'local_llm/opus_pcm_decoder.dart';
import 'local_llm/owner_voice.dart';
import 'local_llm/sd_storage_codec.dart';
import 'local_llm/server_stt.dart';
import 'local_llm/speaker_registry.dart';
import 'local_llm/streaming_transcriber.dart';
import 'local_llm/tidy_runner.dart';
import 'local_llm/transcript_log.dart';
import 'local_llm/transcription_mode.dart';
import 'wearable_audio_session.dart';

/// Upstream KelvinLee GATT UUIDs (per devkit/src/transport.c).
class _Uuid {
  static final audioSvc = ble.Guid('19B10000-E8F2-537E-4F6C-D104768A1214');
  static final audioChar = ble.Guid('19B10001-E8F2-537E-4F6C-D104768A1214');

  /// Codec-id characteristic (transport.c:87, attr at 100-105). Read-only,
  /// returns a single byte: 1=pcm8, 20=opus (10ms), 21=opus_fs320 (20ms).
  static final audioCodecChar = ble.Guid('19B10002-E8F2-537E-4F6C-D104768A1214');
  // Firmware button SERVICE is 23BA7924, CHARACTERISTIC is 23BA7925, both on the
  // kelvinlee custom base 7450-346EAC492E92 (see devkit/src/button.c). The value here
  // must be the CHARACTERISTIC uuid, or the bridge never subscribes and button
  // taps never reach the app.
  static final buttonChar = ble.Guid('23BA7925-0000-1000-7450-346EAC492E92');
  static final agentCmdSvc = ble.Guid('CAB1AB90-0000-1000-8000-00805F9B34FB');
  static final agentCmd = ble.Guid('CAB1AB97-0000-1000-8000-00805F9B34FB');
  static final storageSvc = ble.Guid('30295780-4301-EABD-2904-2849ADFEAE43');
  static final storageDataChar = ble.Guid('30295781-4301-EABD-2904-2849ADFEAE43');
  static final storageReadChar = ble.Guid('30295782-4301-EABD-2904-2849ADFEAE43');
}

/// Codec-id byte values from firmware `config.h:39`.
class _CodecId {
  static const int pcm8 = 1;
  static const int opus10ms = 20;
  static const int opus20ms = 21;
}

/// Button event codes — mirror devkit/src/button.c.
///
/// Codes 6/7/8 keep their wire VALUES but changed MEANING in the A2 grammar
/// (spec §4): double tap is cancel, single tap toggles capture, triple tap
/// recovers the link. An app built against the old names talking to new
/// firmware mis-routes silently, so app and server-contract ship together.
class _ButtonCode {
  static const int singleTap = 1; // D5 — telemetry only, no product behaviour
  static const int doubleTap = 2; // D5 — telemetry only
  static const int longTap = 3; // D5 — telemetry only
  static const int buttonPress = 4;
  static const int buttonRelease = 5;
  static const int cancel = 6; // A2 double tap
  static const int captureToggle = 7; // A2 single tap
  static const int linkRecover = 8; // A2 triple tap
  static const int powerOffArmed = 9; // A2 hold reached the 1500 ms ramp
  static const int powerOffAborted = 10; // A2 hold released before 4000 ms
  static const int powerOffCommitted = 11; // A2 hold reached 4000 ms
}

/// Habitat cue ids for `AGENT_OP_HABITAT` (spec §7) — one 4-byte write per cue
/// instead of an led_color/led_pattern/haptic triple. Mirrors the firmware
/// table in agent_commands.c and `HABITAT_CUE` in server-contract.
class HabitatCue {
  HabitatCue._();
  static const int captureOpen = 0x01;
  static const int noteFiled = 0x02;
  static const int discarded = 0x03;
  static const int ack = 0x04;
  static const int nop = 0x05;
  static const int bleSearching = 0x06;
  static const int bleConnected = 0x07;
  static const int bleIdle = 0x08;
  static const int budgetWarn = 0x09;
  static const int error = 0x0A;
  static const int taskRunning = 0x0B;
  static const int awaitingInput = 0x0C;
}

/// The state an A2 tap resolves against (spec §5). Only the phone knows this —
/// the firmware reports a gesture and nothing more.
enum WearableAppState { idle, capturing, alertPending }

/// What a resolved A2 gesture asks the app to do (spec §3 rows C–K).
enum WearableGestureAction {
  none,
  startCapture, // row C
  stopAndFile, // row D
  ackAndCapture, // row E — acknowledge a question, then open the mic
  ackDismiss, // row F
  cancelCapture, // row G
  dismissAlert, // row H
  nop, // row I
  linkAlive, // row K
}

/// Wire code → name. Null means "not dispatch-worthy": press/release, or a
/// code this build does not know.
String? buttonCodeFor(int raw) {
  switch (raw) {
    case _ButtonCode.singleTap:
      return 'SINGLE';
    case _ButtonCode.doubleTap:
      return 'DOUBLE';
    case _ButtonCode.longTap:
      return 'LONG';
    case _ButtonCode.cancel:
      return 'CANCEL';
    case _ButtonCode.captureToggle:
      return 'CAPTURE_TOGGLE';
    case _ButtonCode.linkRecover:
      return 'LINK_RECOVER';
    case _ButtonCode.powerOffArmed:
      return 'POWER_OFF_ARMED';
    case _ButtonCode.powerOffAborted:
      return 'POWER_OFF_ABORTED';
    case _ButtonCode.powerOffCommitted:
      return 'POWER_OFF_COMMITTED';
    case _ButtonCode.buttonPress:
    case _ButtonCode.buttonRelease:
    default:
      return null;
  }
}

/// Spec §5: which state a tap received at [at] resolves against. An alert that
/// landed less than 300 ms ago could not have been reacted to, so the tap
/// resolves against the pre-alert state.
WearableAppState appStateAt({
  required bool capturing,
  required DateTime at,
  DateTime? alertPendingAt,
}) {
  if (capturing) return WearableAppState.capturing;
  if (alertPendingAt != null) {
    final age = at.difference(alertPendingAt);
    if (age >= _alertSettle && age < _alertMaxAge) {
      return WearableAppState.alertPending;
    }
  }
  return WearableAppState.idle;
}

const Duration _alertSettle = Duration(milliseconds: 300);

/// How long a push-to-talk press waits for the wearer to actually say
/// something. The press does not open a window — it marks the *next* utterance
/// as an instruction — so without an upper bound a press the wearer never
/// followed with words would promote whatever they said an hour later to a
/// server instruction. Thirty seconds is longer than the pause between
/// deciding to speak and speaking, and shorter than any other conversation.
const Duration instructionArmWindow = Duration(seconds: 30);

/// Is an utterance that closed at [at] covered by a push-to-talk press made at
/// [armedAt]? Null (no press) and an expired press both mean "ambient".
bool instructionArmIsLive(DateTime? armedAt, DateTime at) {
  if (armedAt == null) return false;
  final age = at.difference(armedAt);
  return !age.isNegative && age <= instructionArmWindow;
}

/// How long an armed alert keeps claiming the next tap.
///
/// Without an upper bound an informational alert the wearer never answers turns
/// single-tap-to-talk into single-tap-to-acknowledge for the rest of the BLE
/// session. On a device with no screen that reads as "the button stopped
/// recording" and there is no gesture to clear it. Two minutes is longer than
/// anyone deliberates and far shorter than a session.
const Duration _alertMaxAge = Duration(minutes: 2);

/// Spec §2: tap = yes, tap twice = no, and state supplies the fourth dimension.
WearableGestureAction resolveButtonGesture({
  required String code,
  required WearableAppState state,
  required bool alertIsQuestion,
}) {
  switch (code) {
    case 'CAPTURE_TOGGLE': // single tap — "yes"
      switch (state) {
        case WearableAppState.capturing:
          return WearableGestureAction.stopAndFile;
        case WearableAppState.alertPending:
          return alertIsQuestion ? WearableGestureAction.ackAndCapture : WearableGestureAction.ackDismiss;
        case WearableAppState.idle:
          return WearableGestureAction.startCapture;
      }
    case 'CANCEL': // double tap — "no"
      switch (state) {
        case WearableAppState.capturing:
          return WearableGestureAction.cancelCapture;
        case WearableAppState.alertPending:
          return WearableGestureAction.dismissAlert;
        case WearableAppState.idle:
          return WearableGestureAction.nop;
      }
    case 'LINK_RECOVER': // triple tap — row K. Row J is firmware-local.
      return WearableGestureAction.linkAlive;
    default:
      return WearableGestureAction.none;
  }
}

/// Which resolved actions actually answer a pending alert (spec §3 rows E, F,
/// H). Everything else leaves it standing: D5 telemetry and the power codes
/// resolve to [WearableGestureAction.none] (row Q, "no product behaviour"),
/// and the link-recovery hatch answers the link, not the alert.
bool consumesAlert(WearableGestureAction action) =>
    action == WearableGestureAction.ackAndCapture ||
    action == WearableGestureAction.ackDismiss ||
    action == WearableGestureAction.dismissAlert;

/// The cues the app plays for [action] (spec §3, "Cue" column). Row E is the
/// only two-cue phrase: a tick, then the capture ramp.
List<int> habitatCuesFor(WearableGestureAction action) {
  switch (action) {
    case WearableGestureAction.startCapture:
      return const <int>[HabitatCue.captureOpen];
    case WearableGestureAction.stopAndFile:
      return const <int>[HabitatCue.noteFiled];
    case WearableGestureAction.ackAndCapture:
      return const <int>[HabitatCue.ack, HabitatCue.captureOpen];
    case WearableGestureAction.ackDismiss:
      return const <int>[HabitatCue.ack];
    case WearableGestureAction.cancelCapture:
    case WearableGestureAction.dismissAlert:
      return const <int>[HabitatCue.discarded];
    case WearableGestureAction.nop:
      return const <int>[HabitatCue.nop];
    case WearableGestureAction.linkAlive:
      return const <int>[HabitatCue.bleConnected];
    case WearableGestureAction.none:
      return const <int>[];
  }
}

/// Does a habitat cue arriving from the server arm ALERT_PENDING, and is it a
/// question (row E) rather than informational (row F)? Null = not an alert.
bool? alertIsQuestionForCue(int cue) {
  switch (cue) {
    case HabitatCue.awaitingInput:
      return true;
    case HabitatCue.error:
      return false;
    default:
      return null;
  }
}

class _TranscribeResult {
  const _TranscribeResult({required this.ok, required this.posted});

  final bool ok;
  final bool posted;
}

class WearableDeviceBridge {
  WearableDeviceBridge._(this._device, this._client);

  final ble.BluetoothDevice _device;
  final WearableClient _client;

  StreamSubscription<List<int>>? _audioSub;
  WearableAudioSession? _audioSession;
  void Function(WearableAudioFrame frame)? _audioFrameSink;
  StreamSubscription<List<int>>? _buttonSub;
  Timer? _pollTimer;
  WebSocketChannel? _audioWs;
  ble.BluetoothCharacteristic? _agentCmdChar;
  ble.BluetoothCharacteristic? _audioChar;
  ble.BluetoothCharacteristic? _audioNotifyChar;
  ble.BluetoothCharacteristic? _storageDataChar;
  ble.BluetoothCharacteristic? _storageReadChar;
  StreamSubscription<List<int>>? _storageSub;
  Future<void> _audioReconfigureTail = Future<void>.value();
  Timer? _sdSyncTimer;
  bool _running = false;
  bool _sdSyncRunning = false;
  int? _lastButtonRaw;
  int? _lastButtonSeq;

  // --- on-device transcription (Gemma 4) state ---
  // When _mode == onDevice we DON'T open the audio WS; instead we decode frames
  // locally, segment them into utterances, transcribe with Gemma, and push the
  // cleaned text to Wearable via /api/device/text. Cloud mode is unchanged.
  TranscriptionMode _mode = TranscriptionMode.cloud;
  OnDeviceSegmentation _segmentation = OnDeviceSegmentation.button;
  String _audioEncoding = 'opus';
  int _audioFrameMs = 10;
  UtteranceBuffer? _utteranceBuffer;
  LocalOpusDecoder? _opusDecoder;
  Timer? _captureWindowTimer;
  Timer? _captureDrainTimer;
  String? _captureRecordingId;
  String? _captureAudioSessionId;
  String? _pendingCaptureStopId;
  Timer? _captureBudgetTimer;

  /// True only for the synchronous span of [_cancelCapture], so the utterance
  /// `closeWindow()` emits goes to [discards] rather than to Gemma.
  bool _discarding = false;

  /// True only for the synchronous span of [_rollCaptureSegment]. The segment
  /// it emits is transcribed while the wearer keeps talking, so the banner must
  /// stay on "Recording" rather than flipping to "Transcribing...".
  bool _rolling = false;

  /// When the wearer last pressed the button to mark the next utterance as an
  /// instruction (push-to-talk). Null = nothing armed. Privacy Mode does not
  /// use this: there the press opens a capture window and everything inside it
  /// is an instruction by construction.
  DateTime? _instructionArmedAt;

  /// Privacy Mode — see [TranscriptionSettings.privacyMode]. Derived from the
  /// stored segmentation rather than held separately so the two can never
  /// disagree.
  bool get _privacyMode => TranscriptionSettings.privacyModeFor(_segmentation);

  /// When the current ALERT_PENDING arrived, and whether it wants an answer
  /// (spec §3 rows E/F). Null = no alert outstanding.
  DateTime? _alertPendingAt;
  bool _alertIsQuestion = false;

  /// DIAGNOSTIC counter for on-device audio frames (see _startOnDeviceAudio).
  int _odFrameCount = 0;

  /// The most audio one segment holds before it is handed to transcription.
  ///
  /// This is a *segment* boundary, not the end of the capture: at the cap the
  /// window closes, the audio goes to the recogniser, and a fresh window opens
  /// in the same synchronous turn (see [_rollCaptureSegment]), so a wearer who
  /// talks for ten minutes gets five transcripts rather than two minutes of
  /// speech and then silence. Two minutes keeps one recogniser pass inside a
  /// few seconds on the measured 46x-realtime path.
  static const Duration _captureSegmentCap = Duration(seconds: 120);

  /// Amber breathing warning that the capture budget is nearly spent (spec §6).
  static const Duration _voiceNoteBudgetWarn = Duration(seconds: 90);

  /// Cancelled notes, newest first (spec §6: ten-minute recovery).
  ///
  /// ponytail: in-memory and capped at three, because 120 s of 16 kHz PCM is
  /// ~3.8 MB per entry and nothing here survives an app restart. No screen
  /// surfaces this yet — the recovery UI belongs to the transcripts-page lane.
  static final List<({DateTime at, Int16List samples})> discards = <({DateTime at, Int16List samples})>[];
  static const Duration discardRetention = Duration(minutes: 10);
  static const int _maxDiscards = 3;

  /// Decoded wearable PCM (16 kHz mono), every frame, as it arrives — for a
  /// screen that needs the WEARABLE channel rather than the phone mic, such as
  /// guided owner enrolment (P1): a voice enrolled from the phone mic does not
  /// match the same voice heard through the device. Observation only: the
  /// utterance buffer, preview and diagnostics see the same samples regardless,
  /// and a null tap costs one null check per frame. Set to null when done.
  static void Function(Int16List samples)? pcmTap;

  /// While a screen owns capture — the dictation page, which records from the
  /// phone mic — the bridge hands it the resolved gesture instead of opening a
  /// wearable capture window.
  ///
  /// Returns true if it acted. A surface that cannot act right now — still
  /// checking, model missing, already busy, or covered by another route —
  /// returns false and the gesture falls through to the wearable mic, which
  /// either records or plays a correcting cue. Swallowing it would leave the
  /// white capture tell-tale lit with nothing recording.
  ///
  /// ponytail: one slot, not a listener list. Two screens cannot both be the
  /// foreground capture surface; if that stops being true this becomes a stack.
  static bool Function(WearableGestureAction action)? captureOwner;

  /// Singleton handle — a second attach disposes the previous bridge first.
  /// UI widgets read this to reflect connection state without holding their
  /// own reference.
  static WearableDeviceBridge? _current;
  static WearableDeviceBridge? get current => _current;

  /// Exposed for UI — device name of the connected wearable.
  String get deviceName => _device.platformName.isEmpty ? _device.remoteId.str : _device.platformName;

  /// Attach to a connected BLE device and start forwarding. Returns null when
  /// Wearable is not paired yet — caller should surface a pairing prompt and
  /// retry once credentials are saved.
  /// Attach to a connected wearable.
  ///
  /// Deliberately does NOT require server credentials. This used to open with
  /// `if (!await client.isPaired()) return null;`, so pairing to the wearable
  /// over BLE failed unless the wearer had first stood up a Wearable server —
  /// the scan found the device, connected to it, and then refused with "Bridge
  /// attach failed". Audio, transcription and the button all work with no
  /// server at all; the server calls below are individually optional.
  ///
  /// Attaches run one at a time, and a bridge is [current] from before it
  /// starts: two overlapping attaches (an auto-reconnect and the scan page),
  /// or a start that failed half-way and was retried, used to leave a second
  /// bridge subscribed to the same notifications, so every frame, press and
  /// transcript was handled twice.
  static Future<WearableDeviceBridge?> attach(ble.BluetoothDevice device) {
    final next = _attaching.then((_) => _attachNow(device));
    _attaching = next.then((_) {}, onError: (_) {});
    return next;
  }

  static Future<void> _attaching = Future<void>.value();

  static Future<WearableDeviceBridge?> _attachNow(ble.BluetoothDevice device) async {
    await _current?.dispose();
    final bridge = WearableDeviceBridge._(device, WearableClient.instance);
    _current = bridge;
    try {
      await bridge._start();
    } catch (_) {
      await bridge.dispose();
      rethrow;
    }
    return bridge;
  }

  /// Convenience for callers that only hold a BLE device id. Looks the device
  /// up in `FlutterBluePlus.connectedDevices` and delegates to [attach].
  /// Returns null if the device isn't currently connected at the
  /// flutter_blue_plus layer or if Wearable isn't paired.
  ///
  /// Called by WearableDeviceProvider.reconnectPairedDevice()'s fast path,
  /// when the OS still holds the BLE link and only the bridge needs restarting.
  static Future<WearableDeviceBridge?> attachByDeviceId(String deviceId) async {
    for (final d in ble.FlutterBluePlus.connectedDevices) {
      if (d.remoteId.str == deviceId) {
        return attach(d);
      }
    }
    return null;
  }

  Future<void> _start() async {
    if (_running) return;
    _running = true;

    // Raise the process out of "cached" before a single frame arrives. Android
    // kills a cached process for "excessive binder traffic", and 100 BLE
    // notifications a second is exactly that — so the window to get this wrong
    // opens the moment audio starts, not later. Never throws.
    unawaited(CaptureService.instance.start());

    final services = await _device.discoverServices();

    // --- Audio: BLE → Wearable WebSocket ---
    ble.BluetoothCharacteristic? audioChar;
    ble.BluetoothCharacteristic? codecChar;
    for (final s in services) {
      if (s.uuid == _Uuid.audioSvc) {
        for (final c in s.characteristics) {
          if (c.uuid == _Uuid.audioChar) audioChar = c;
          if (c.uuid == _Uuid.audioCodecChar) codecChar = c;
        }
      }
    }
    // Read codec id before opening the WS so we tell the server what
    // packetization to expect. Fall back to opus@10ms if the char is
    // missing (older firmware) so existing devices keep working.
    String encoding = 'opus';
    int frameMs = 10;
    if (codecChar != null) {
      try {
        final bytes = await codecChar.read();
        final id = bytes.isEmpty ? _CodecId.opus10ms : bytes.first;
        switch (id) {
          case _CodecId.opus20ms:
            encoding = 'opus';
            frameMs = 20;
            break;
          case _CodecId.pcm8:
            encoding = 'linear16';
            frameMs = 10;
            break;
          case _CodecId.opus10ms:
          default:
            encoding = 'opus';
            frameMs = 10;
            break;
        }
        debugPrint('[WearableBridge] codec id=$id → encoding=$encoding frameMs=$frameMs');
      } catch (e) {
        debugPrint('[WearableBridge] codec char read failed: $e — defaulting to opus/10ms');
      }
    }
    _audioChar = audioChar;
    _audioEncoding = encoding;
    _audioFrameMs = frameMs;
    await _configureAudioPath();

    // --- Button: BLE notify → Wearable HTTP event ---
    ble.BluetoothCharacteristic? buttonChar;
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.uuid == _Uuid.buttonChar) buttonChar = c;
      }
    }
    if (buttonChar != null) {
      await buttonChar.setNotifyValue(true);
      _buttonSub = buttonChar.lastValueStream.listen((value) {
        if (value.isEmpty) return;
        final raw = value[0];
        final seq = _buttonSequenceFor(value);
        if (seq != null && seq > 0 && raw == _lastButtonRaw && seq == _lastButtonSeq) {
          debugPrint('[WearableBridge] duplicate button notify raw=$raw seq=$seq');
          return;
        }
        _lastButtonRaw = raw;
        _lastButtonSeq = seq;
        debugPrint('[WearableBridge] button notify raw=$raw seq=${seq ?? '-'} len=${value.length}');
        final code = buttonCodeFor(raw);
        if (code == null) return;
        _onButtonCode(code, DateTime.now());
      });
    }

    // --- Agent commands: Wearable HTTP poll → BLE 0xCAB1AB97 write ---
    for (final s in services) {
      if (s.uuid == _Uuid.agentCmdSvc) {
        for (final c in s.characteristics) {
          if (c.uuid == _Uuid.agentCmd) _agentCmdChar = c;
        }
      }
    }
    if (_agentCmdChar != null) {
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _drainCommandQueue());
    }

    // --- SD-card offline audio: firmware storage GATT → on-device STT ---
    for (final s in services) {
      if (s.uuid == _Uuid.storageSvc) {
        for (final c in s.characteristics) {
          if (c.uuid == _Uuid.storageDataChar) _storageDataChar = c;
          if (c.uuid == _Uuid.storageReadChar) _storageReadChar = c;
        }
      }
    }
    if (_storageDataChar != null && _storageReadChar != null) {
      CaptureDiagnostics.instance.event('SD offline sync ready');
      _scheduleOfflineSdSync();
    }

    // --- Heartbeat so Wearable's last_seen_at reflects reality ---
    _client
        .sendEvent(kind: 'heartbeat', at: DateTime.now().millisecondsSinceEpoch)
        .catchError((_) => <String, dynamic>{});
  }

  /// Reload transcription settings for the active BLE connection. Settings UI
  /// calls this after changing cloud/on-device mode or segmentation so the
  /// wearer does not need to manually disconnect/reconnect the wearable.
  Future<void> reconfigureTranscription() async {
    if (!_running) return;
    _audioReconfigureTail = _audioReconfigureTail.catchError((_) {}).then((_) async {
      if (!_running) return;
      try {
        await _configureAudioPath();
      } catch (e) {
        debugPrint('[WearableBridge] audio reconfigure failed: $e');
        CaptureDiagnostics.instance.event('Audio reconfigure failed');
      }
      _scheduleOfflineSdSync(delay: const Duration(milliseconds: 500));
    });
    await _audioReconfigureTail;
  }

  Future<void> _configureAudioPath() async {
    await _stopAudioPath();
    final audioChar = _audioChar;
    if (audioChar == null || !_running) {
      CaptureDiagnostics.instance.event('No wearable audio characteristic');
      return;
    }

    _mode = await TranscriptionSettings.mode();
    _segmentation = await TranscriptionSettings.segmentation();

    // Cloud transcription is the server's job, so with no server it is not a
    // choice the app can honour. On-device is the only path that can work;
    // take it rather than opening a WebSocket to nowhere. The stored
    // preference is left alone — it applies again the moment a server exists.
    if (_mode == TranscriptionMode.cloud && !await _client.isPaired()) {
      _mode = TranscriptionMode.onDevice;
      CaptureDiagnostics.instance.event('No server paired — transcribing on-device');
    }

    if (_mode == TranscriptionMode.onDevice) {
      // On-device transcription needs the ASR model, not Gemma — Gemma is the
    // optional text-polish stage and its absence must not stop capture.
    final ok = await ZipformerTranscriber.instance.isInstalled() && await platformSupportsOnDevice();
      if (!ok) {
        const message = 'On-device unavailable; install the model or switch to cloud';
        debugPrint('[WearableBridge] on-device requested but model/device unavailable; audio path stopped');
        CaptureDiagnostics.instance.updateMode(
          _mode,
          _segmentation,
          encoding: _audioEncoding,
          frameMs: _audioFrameMs,
          message: message,
        );
        _showCaptureError(message);
        return;
      }
    }
    if (!_running) return; // disposed during await

    CaptureDiagnostics.instance.updateMode(_mode, _segmentation, encoding: _audioEncoding, frameMs: _audioFrameMs);

    if (_mode == TranscriptionMode.onDevice) {
      await _startOnDeviceAudio(audioChar, _audioEncoding);
    } else {
      await _startCloudAudio(audioChar, _audioEncoding, _audioFrameMs);
    }
  }

  Future<void> _stopAudioPath() async {
    _captureWindowTimer?.cancel();
    _captureWindowTimer = null;
    _captureBudgetTimer?.cancel();
    _captureBudgetTimer = null;
    _captureDrainTimer?.cancel();
    _captureDrainTimer = null;
    _captureRecordingId = null;
    _captureAudioSessionId = null;
    _pendingCaptureStopId = null;
    // A press does not survive the audio path being rebuilt. Switching Privacy
    // Mode on runs through here, and an arm made before the switch must not
    // reappear as an instruction inside the first window after it.
    _instructionArmedAt = null;
    if (CaptureState.instance.isActive) CaptureState.instance.idle();

    final session = _audioSession;
    final frameSink = _audioFrameSink;
    if (session != null) session.requestStop(session.recordingId);

    await _audioSub?.cancel();
    _audioSub = null;
    if (session != null && identical(_audioSession, session)) {
      for (final frame in session.finish(session.recordingId)) {
        frameSink?.call(frame);
      }
      _audioSession = null;
      _audioFrameSink = null;
    }
    final notifyChar = _audioNotifyChar;
    _audioNotifyChar = null;
    if (notifyChar != null) {
      try {
        await notifyChar.setNotifyValue(false);
      } catch (e) {
        debugPrint('[WearableBridge] setNotifyValue(audio)=false failed: $e');
      }
    }
    try {
      await _audioWs?.sink.close();
    } catch (_) {
      // ignore
    }
    _audioWs = null;

    _utteranceBuffer?.reset();
    _utteranceBuffer = null;
    _opusDecoder?.dispose();
    _opusDecoder = null;
    // Whatever happened above, the banner must not be left saying "Recording"
    // on a bridge that no longer exists. Only transcription clears it otherwise,
    // and a dropped link never gets there.
    if (CaptureState.instance.isRecording) CaptureState.instance.idle();
    _odFrameCount = 0;
    CaptureDiagnostics.instance.resetFrames();
  }

  Future<void> _startCloudAudio(ble.BluetoothCharacteristic audioChar, String encoding, int frameMs) async {
    try {
      // WearableClient.openAudioStream already attaches the sole stream.listen
      // (WebSocketChannel is single-subscription). We hand it an onMessage
      // callback so server-pushed transcript JSON is routed here without a
      // duplicate listen that would throw StateError.
      _audioWs = await _client.openAudioStream(
        encoding: encoding,
        sampleRate: 16000,
        frameMs: frameMs,
        owner: 'ble',
        onMessage: _onServerMessage,
      );
      debugPrint('[WearableBridge] audio ws opened');
    } catch (e) {
      debugPrint('[WearableBridge] audio ws OPEN FAILED: $e');
      CaptureDiagnostics.instance.event('Cloud audio open failed: $e');
      _audioWs = null;
    }
    if (_audioWs == null || !_running) return;

    await audioChar.setNotifyValue(true);
    _audioNotifyChar = audioChar;
    debugPrint('[WearableBridge] setNotifyValue(audio)=true');
    if (!_running) return; // disposed during await

    var frameCount = 0;
    var byteCount = 0;
    final session = WearableAudioSession.create();
    _audioSession = session;
    _audioFrameSink = (frame) {
      final ws = _audioWs;
      if (ws == null || frame.bytes.isEmpty) return;
      try {
        ws.sink.add(frame.bytes);
        frameCount++;
        byteCount += frame.bytes.length;
        if (frameCount % 100 == 0) {
          debugPrint('[WearableBridge] audio frames sent=$frameCount bytes=$byteCount');
          CaptureDiagnostics.instance.event('Cloud audio frames=$frameCount bytes=$byteCount');
        }
      } catch (e) {
        debugPrint('[WearableBridge] audio ws send FAILED: $e (frames=$frameCount)');
        CaptureDiagnostics.instance.event('Cloud audio send failed: $e');
        _audioWs = null;
      }
    };
    _audioSub = audioChar.lastValueStream.listen((value) {
      // Re-check _running every invocation — the bridge could have been
      // torn down between BLE emits and this closure firing. Also
      // re-read _audioWs locally (it may be null after arbitration
      // superseded us from the phone-mic path).
      if (!_running || value.length <= 3 || !identical(_audioSession, session)) return;
      final frames = session.addPacket(session.recordingId, value);
      // Keep consuming packet ids while muted so resuming does not look like a
      // large packet gap, but do not deliver the completed audio.
      if (CaptureMute.instance.muted) return;
      for (final frame in frames) {
        _audioFrameSink?.call(frame);
      }
    });
  }

  /// On-device audio path: decode wearable frames locally and segment them into
  /// utterances for Gemma transcription. No audio WS is opened.
  Future<void> _startOnDeviceAudio(ble.BluetoothCharacteristic audioChar, String encoding) async {
    _opusDecoder = encoding == 'opus' ? LocalOpusDecoder() : null;
    // Stored at unity. This was captureGain 8.0 — a fixed multiply-and-clamp
    // applied to every sample before storage, added when Gemma took the audio
    // directly and needed it lifted. Gemma no longer sees audio, and the ASR
    // path peak-normalises at transcribe time (normalizeGain, which cannot
    // clip by construction). The fixed 8x survived that change and turned
    // anyone speaking at normal volume into hard-clipped distortion: raw
    // wearable peaks of 3-4k became 32767. Button captures never had the gain,
    // which is why they were legible while continuous windows were not.
    _utteranceBuffer = UtteranceBuffer(onUtterance: _transcribeAndSend);
    await audioChar.setNotifyValue(true);
    _audioNotifyChar = audioChar;
    if (!_running) return; // disposed during await
    debugPrint('[WearableBridge] on-device audio path active (seg=$_segmentation, enc=$encoding)');
    CaptureDiagnostics.instance.event('On-device audio subscribed');
    final session = WearableAudioSession.create();
    _audioSession = session;
    _audioFrameSink = (frame) {
      final payload = frame.bytes;
      Int16List samples;
      final decoder = _opusDecoder;
      if (decoder != null) {
        try {
          samples = decoder.decode(payload);
        } catch (e) {
          debugPrint('[WearableBridge] opus decode failed: $e');
          return;
        }
      } else {
        samples = pcm16BytesToSamples(payload);
      }
      pcmTap?.call(samples);
      // DIAGNOSTIC: distinguish a silent/dead mic (payloadSum≈const, rms 0) from a
      // decode bug (payload varies but rms 0) from working audio (rms > 0). Logs
      // ~twice/sec while audio streams — no tap needed.
      if (++_odFrameCount % 50 == 0) {
        var psum = 0;
        for (final b in payload) {
          psum += b;
        }
        final rms = pcmRms(samples);
        debugPrint(
          '[WearableBridge] OD frame#$_odFrameCount '
          'payloadLen=${payload.length} payloadSum=$psum '
          'decodedRms=${rms.toStringAsFixed(1)} n=${samples.length}',
        );
        CaptureDiagnostics.instance.updateFrame(
          frameCount: _odFrameCount,
          payloadLen: payload.length,
          payloadSum: psum,
          sampleCount: samples.length,
          decodedRms: rms,
        );
      }
      if (samples.isEmpty) return;
      final buffer = _utteranceBuffer;
      if (buffer == null) return;
      if (_privacyMode) {
        // Privacy Mode: nothing outside a button-armed window is kept. While the
        // window is closed addWindowed() feeds only UtteranceBuffer's pre-roll
        // ring (1.5 s, in memory, overwritten continuously) so the wearer's
        // first word survives the tap; it is never flushed to the recogniser.
        if (_captureAudioSessionId != null && _captureAudioSessionId != session.recordingId) return;
        buffer.addWindowed(samples);
        // Live preview, in parallel with the buffer rather than instead of it.
        // The buffer still holds the whole window for the offline pass, which
        // is what gets saved; this only puts text on screen while the wearer is
        // still talking. No-ops when the streaming model is not installed.
        if (_captureRecordingId != null) {
          StreamingTranscriber.instance.accept(samples);
        }
      } else {
        buffer.addContinuous(samples);
      }
      final pendingStopId = _pendingCaptureStopId;
      if (pendingStopId != null) _scheduleCaptureDrain(pendingStopId);
    };
    _audioSub = audioChar.lastValueStream.listen((value) {
      if (!_running || value.length <= 3 || !identical(_audioSession, session)) return;
      final frames = session.addPacket(session.recordingId, value);
      // Drop frames while muted without tearing down packet ordering.
      if (CaptureMute.instance.muted) return;
      for (final frame in frames) {
        _audioFrameSink?.call(frame);
      }
    });
  }

  void _scheduleOfflineSdSync({Duration delay = const Duration(seconds: 2)}) {
    if (!_running || _storageDataChar == null || _storageReadChar == null) return;
    _sdSyncTimer?.cancel();
    _sdSyncTimer = Timer(delay, () {
      unawaited(_syncOfflineSdAudio());
    });
  }

  Future<void> _syncOfflineSdAudio() async {
    if (_sdSyncRunning || !_running) return;
    final dataChar = _storageDataChar;
    final readChar = _storageReadChar;
    if (dataChar == null || readChar == null) return;

    _sdSyncRunning = true;
    LocalOpusDecoder? sdOpusDecoder;
    var packetsValid = true;
    var processedFrames = 0;
    var processedBytes = 0;
    var sdUtteranceCount = 0;
    var sdPostedCount = 0;
    Future<bool> transcribeTail = Future<bool>.value(true);

    try {
      final canTranscribe = await ZipformerTranscriber.instance.isInstalled() && await platformSupportsOnDevice();
      if (!canTranscribe) {
        CaptureDiagnostics.instance.event('SD backlog waiting for on-device model');
        return;
      }

      final statusBytes = await readChar.read();
      final status = SdStorageStatus.decode(statusBytes);
      if (status == null) {
        CaptureDiagnostics.instance.event('SD status unreadable');
        return;
      }
      if (status.pendingBytes <= 0) {
        CaptureDiagnostics.instance.event('SD backlog empty');
        return;
      }

      CaptureDiagnostics.instance.event('SD sync pending=${status.pendingBytes}B');
      sdOpusDecoder = _audioEncoding == 'opus' ? LocalOpusDecoder() : null;
      final offlineBuffer = UtteranceBuffer(
        // Unity, as the live path — see _startOnDeviceAudio for why the 8x went.
        onUtterance: (samples) {
          sdUtteranceCount++;
          transcribeTail = transcribeTail.then((priorOk) async {
            // Privacy contract: SD backlog is always ambient. The server treats
            // this client flag as sticky ambient, even near an intent button.
            final result = await _transcribeSamples(
              samples,
              overheard: true,
              defaultTalker: 'SD card',
              updateCaptureState: false,
              source: 'SD',
            );
            if (result.posted) sdPostedCount++;
            return priorOk && result.ok;
          });
        },
      );

      await _storageSub?.cancel();
      final done = Completer<bool>();
      _storageSub = dataChar.lastValueStream.listen((value) {
        if (!_running || value.isEmpty || done.isCompleted) return;
        final packet = SdStorageCodec.decodePacket(value);
        if (!packet.valid) {
          packetsValid = false;
          CaptureDiagnostics.instance.event('SD sync invalid packet');
          return;
        }
        if (packet.code != null) {
          if (packet.isAck || packet.isDeleteAck) return;
          if (packet.isComplete) {
            done.complete(true);
            return;
          }
          packetsValid = false;
          CaptureDiagnostics.instance.event('SD sync error code=${packet.code}');
          done.complete(false);
          return;
        }

        processedBytes += packet.consumedBytes;
        for (final frame in packet.frames) {
          if (!_running) return;
          Int16List samples;
          final decoder = sdOpusDecoder;
          if (decoder != null) {
            try {
              samples = decoder.decode(frame);
            } catch (e) {
              packetsValid = false;
              debugPrint('[WearableBridge] SD opus decode failed: $e');
              continue;
            }
          } else {
            samples = pcm16BytesToSamples(frame);
          }
          if (samples.isEmpty) continue;
          processedFrames++;
          offlineBuffer.addContinuous(samples);
          if (processedFrames % 100 == 0) {
            CaptureDiagnostics.instance.event('SD sync frames=$processedFrames bytes=$processedBytes');
          }
        }
      });

      await dataChar.setNotifyValue(true);
      if (!_running) return;
      await dataChar.write(
        SdStorageCommand.encode(command: SdStorageCommand.read, fileNum: 1, offset: status.offsetBytes),
        withoutResponse: false,
      );

      final completed = await done.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          packetsValid = false;
          CaptureDiagnostics.instance.event('SD sync timed out');
          return false;
        },
      );
      offlineBuffer.flushPending(enforceMin: true);
      final transcribedOk = await transcribeTail;

      if (shouldDeleteSdBacklog(
            completed: completed,
            packetsValid: packetsValid,
            transcriptionsOk: transcribedOk,
            processedFrames: processedFrames,
            emittedUtterances: sdUtteranceCount,
            postedTranscripts: sdPostedCount,
          ) &&
          _running) {
        await dataChar.write(
          SdStorageCommand.encode(command: SdStorageCommand.delete, fileNum: 1),
          withoutResponse: false,
        );
        final action = sdPostedCount > 0 ? 'processed' : 'discarded silence';
        CaptureDiagnostics.instance.event('SD backlog $action frames=$processedFrames');
      } else if (processedFrames > 0) {
        CaptureDiagnostics.instance.event('SD backlog retained for retry');
      }
    } catch (e) {
      debugPrint('[WearableBridge] SD sync failed: $e');
      CaptureDiagnostics.instance.event('SD sync failed');
    } finally {
      await _storageSub?.cancel();
      _storageSub = null;
      try {
        await dataChar.setNotifyValue(false);
      } catch (_) {
        // Best effort cleanup; reconnect/retry will re-enable notifications.
      }
      sdOpusDecoder?.dispose();
      _sdSyncRunning = false;
    }
  }

  /// Resolve one A2 gesture against the app's own state and act on it
  /// (spec §3 rows C–K, §5). [at] is the notify's receipt time: the state
  /// used is the state *then*, not after the work below.
  void _onButtonCode(String code, DateTime at) {
    final state = appStateAt(
      capturing: CaptureState.instance.isRecording,
      at: at,
      alertPendingAt: _alertPendingAt,
    );
    final action = resolveButtonGesture(code: code, state: state, alertIsQuestion: _alertIsQuestion);
    // Watchdog disarm (spec §5) — the firmware arms a 1500 ms timer on codes
    // 6/7/8 and any write to 0xCAB1AB97 clears it, so the cue write is the
    // first thing that happens. Codes 9/10/11 arm nothing and own no cue.
    for (final cue in habitatCuesFor(action)) {
      unawaited(_writeHabitat(cue));
    }
    // Keep button delivery quiet in the transcript UI; capture state and
    // eventual speech text are the user-facing confirmation.
    _signalButton(code);
    // Still notify the server (queues the task_queued LED in both modes).
    _client.sendEvent(kind: 'button', code: code).catchError((_) => <String, dynamic>{});
    if (state == WearableAppState.alertPending && consumesAlert(action)) _clearAlert();
    // Codes 9 and 11 resolve to no gesture, but they are the checkpoint that
    // spec §0 leans on to justify putting power-off on a bare hold: file the
    // in-flight note while there is still a device to stream it from.
    if (code == 'POWER_OFF_ARMED' || code == 'POWER_OFF_COMMITTED') {
      final recordingId = _captureRecordingId;
      if (recordingId != null) _requestCaptureStop(recordingId);
    }
    // A foreground capture surface (the dictation page) records from the phone
    // mic, so it takes the gesture instead of the wearable capture window.
    final owner = captureOwner;
    if (owner != null && owner(action)) return;
    _applyGestureLocally(action);
  }

  /// The wearable-mic half of a resolved gesture.
  void _applyGestureLocally(WearableGestureAction action) {
    switch (action) {
      case WearableGestureAction.startCapture:
      case WearableGestureAction.ackAndCapture:
        // Only on-device button segmentation opens a capture window. The wearer
        // has already seen the white tell-tale, so anything that cannot open a
        // capture has to correct the LED rather than leave it lying — and it
        // has to name the REAL reason. This used to say "install the model or
        // switch to cloud" for every cause, so a wearer whose model was
        // installed and whose link had dropped was told to install it again.
        if (_mode != TranscriptionMode.onDevice) {
          _refuseCapture('Cloud transcription is selected — switch to on-device in Settings › Voice');
          return;
        }
        if (_utteranceBuffer == null) {
          // Which of the two it is needs a disk check, and this path is sync.
          unawaited(_refuseMissingAudio());
          return;
        }
        if (!_privacyMode) {
          // Push-to-talk. Continuous capture is already running, so the press
          // is not a start/stop — it marks the next utterance as something said
          // TO the agent rather than near it. The boundary still comes from
          // UtteranceBuffer's VAD, so the wearer can talk straight through it.
          _armInstruction();
          return;
        }
        _beginCaptureWindow(_captureSegmentCap);
      case WearableGestureAction.stopAndFile:
        final recordingId = _captureRecordingId;
        if (recordingId != null) _requestCaptureStop(recordingId);
      case WearableGestureAction.cancelCapture:
        _cancelCapture();
      case WearableGestureAction.ackDismiss:
      case WearableGestureAction.dismissAlert:
      case WearableGestureAction.nop:
      case WearableGestureAction.linkAlive:
      case WearableGestureAction.none:
        break; // cue only — nothing to capture
    }
  }

  /// Push-to-talk: the next utterance is an instruction, not ambient speech.
  ///
  /// The capture_open cue has already gone out from [_onButtonCode], which is
  /// the right tell-tale: from the wearer's side the agent is now listening to
  /// them specifically. No window opens and none has to be closed.
  void _armInstruction() {
    _instructionArmedAt = DateTime.now();
    CaptureDiagnostics.instance.event('Listening — the next thing you say is for the agent');
    debugPrint('[WearableBridge] instruction armed for the next utterance');
  }

  /// Take the armed press, if one is still live. Always clears it: a press that
  /// timed out has been answered by the wearer saying nothing, and leaving it
  /// standing would attach it to an unrelated utterance later.
  bool _consumeArmedInstruction() {
    final armedAt = _instructionArmedAt;
    if (armedAt == null) return false;
    _instructionArmedAt = null;
    final live = instructionArmIsLive(armedAt, DateTime.now());
    if (!live) debugPrint('[WearableBridge] armed instruction expired unused');
    return live;
  }

  /// No audio path. Name the real cause: a dropped link and a missing model
  /// look identical from here, and telling someone to install a model they
  /// already have is worse than saying nothing.
  Future<void> _refuseMissingAudio() async {
    final installed = await ZipformerTranscriber.instance.isInstalled();
    if (!_running) return;
    _refuseCapture(installed
        ? 'Wearable audio is not running — reconnect the device'
        : 'Speech model is not installed — install it in Settings › Voice');
  }

  /// Refuse a capture the app cannot open: say why, tell the wearer, and correct
  /// the tell-tale the firmware has already lit.
  void _refuseCapture(String message) {
    CaptureDiagnostics.instance.event(message);
    _showCaptureError(message);
    unawaited(_writeHabitat(HabitatCue.error));
  }

  /// Row G — cancel the note. The window closes without transcribing and the
  /// audio lands in [discards] for ten minutes, which is what lets cancel sit
  /// on the second-cheapest gesture (spec §6).
  ///
  /// ponytail: only the tail slice is recoverable. `UtteranceBuffer` emits a
  /// 30 s slice mid-window when the wearer talks past its cap, and those are
  /// already transcribed and sent by the time cancel arrives. Holding them back
  /// means buffering inside `audio_buffer.dart`, which is another lane's file.
  void _cancelCapture() {
    final recordingId = _captureRecordingId;
    if (recordingId == null) return;
    _captureWindowTimer?.cancel();
    _captureWindowTimer = null;
    _captureBudgetTimer?.cancel();
    _captureBudgetTimer = null;
    _captureDrainTimer?.cancel();
    _captureDrainTimer = null;
    _pendingCaptureStopId = null;
    _captureRecordingId = null;
    _captureAudioSessionId = null;
    // closeWindow() emits synchronously into _transcribeAndSend, which routes
    // to the discards list while this flag is set.
    _discarding = true;
    _stopLivePreview();
    _utteranceBuffer?.closeWindow();
    _discarding = false;
    if (CaptureState.instance.isRecording) CaptureState.instance.idle();
  }

  void _rememberDiscard(Int16List samples) {
    final now = DateTime.now();
    discards.removeWhere((d) => now.difference(d.at) >= discardRetention);
    discards.insert(0, (at: now, samples: samples));
    if (discards.length > _maxDiscards) discards.removeRange(_maxDiscards, discards.length);
    CaptureDiagnostics.instance.event(
      'Note discarded (${(samples.length / 16000).toStringAsFixed(1)}s), recoverable for 10 min',
    );
  }

  /// Push a transcript onward, if a server is paired.
  ///
  /// Returns whether it went anywhere. With no server this is a no-op and a
  /// success: the transcript is already in OnDeviceTranscriptLog, which is what
  /// the Transcripts tab reads. Calling sendDeviceText unconditionally made
  /// every single transcript throw and log a failure on a serverless setup.
  Future<bool> _pushTranscript(String text, {required bool overheard, String? talker}) async {
    if (!await _client.isPaired()) return false;
    await _client.sendDeviceText(text: text, overheard: overheard, talker: talker);
    return true;
  }

  void _clearAlert() {
    _alertPendingAt = null;
    _alertIsQuestion = false;
  }

  /// Send one habitat cue over the agent-command characteristic (spec §7,
  /// `AGENT_OP_HABITAT`). Firmware owns the composition; this only names it.
  Future<void> _writeHabitat(int cue) async {
    final cmdChar = _agentCmdChar;
    if (cmdChar == null || !_running) return;
    final bytes = encodeCommandFromJson(<String, dynamic>{'kind': 'habitat', 'cue': cue});
    if (bytes == null) return;
    try {
      await cmdChar.write(bytes, withoutResponse: true);
    } catch (e) {
      debugPrint('[WearableBridge] habitat cue $cue write failed: $e');
    }
  }

  void _beginCaptureWindow(Duration maxDuration) {
    final audioSession = _audioSession;
    if (audioSession == null || audioSession.isClosed) {
      _showCaptureError('Wearable audio is reconnecting; try again in a moment');
      // The capture_open cue has already gone out. Correct it rather than
      // leave the white tell-tale lit on a device that is not recording.
      unawaited(_writeHabitat(HabitatCue.error));
      return;
    }
    final recordingId = WearableAudioSession.create().recordingId;
    _captureRecordingId = recordingId;
    _captureAudioSessionId = audioSession.recordingId;
    _pendingCaptureStopId = null;
    _captureDrainTimer?.cancel();
    CaptureState.instance.recording();
    _utteranceBuffer?.openWindow();
    unawaited(StreamingTranscriber.instance.start());
    _armSegmentTimers(recordingId, maxDuration);
  }

  /// Arm the two timers one segment owns: the cap that rolls it, and the amber
  /// pulse that warns the cap is coming. Re-armed on every roll, so a long
  /// capture pulses amber once per segment — on a screenless device that is the
  /// only signal that it is still recording.
  void _armSegmentTimers(String recordingId, Duration maxDuration) {
    _captureWindowTimer?.cancel();
    _captureWindowTimer = Timer(maxDuration, () => _rollCaptureSegment(recordingId, maxDuration));
    _captureBudgetTimer?.cancel();
    _captureBudgetTimer = maxDuration > _voiceNoteBudgetWarn
        ? Timer(_voiceNoteBudgetWarn, () => unawaited(_writeHabitat(HabitatCue.budgetWarn)))
        : null;
  }

  /// Segment-and-continue: at the cap, file what was captured and keep going.
  ///
  /// close/open run in one synchronous turn, and BLE frames only reach the
  /// buffer from the audio listener, so no frame can land between the two —
  /// the wearer's next word is the first sample of the new segment instead of
  /// falling into a gap. This replaces auto-stopping at the cap, which binned
  /// everything said after two minutes with no cue that it had.
  void _rollCaptureSegment(String recordingId, Duration maxDuration) {
    if (recordingId != _captureRecordingId || _captureAudioSessionId != _audioSession?.recordingId) return;
    if (_pendingCaptureStopId != null) return; // a stop is already draining
    CaptureDiagnostics.instance.event(
      'Capture passed ${maxDuration.inSeconds}s — filed so far, still recording',
    );
    _stopLivePreview();
    _rolling = true;
    _utteranceBuffer?.closeWindow();
    _utteranceBuffer?.openWindow();
    _rolling = false;
    unawaited(StreamingTranscriber.instance.start());
    _armSegmentTimers(recordingId, maxDuration);
  }

  void _requestCaptureStop(String recordingId) {
    if (recordingId != _captureRecordingId || _captureAudioSessionId != _audioSession?.recordingId) return;
    _captureWindowTimer?.cancel();
    _captureWindowTimer = null;
    _captureBudgetTimer?.cancel();
    _captureBudgetTimer = null;
    _pendingCaptureStopId = recordingId;
    _scheduleCaptureDrain(recordingId);
  }

  void _scheduleCaptureDrain(String recordingId) {
    if (recordingId != _captureRecordingId || recordingId != _pendingCaptureStopId) return;
    _captureDrainTimer?.cancel();
    // Audio and button notifications use different GATT characteristics. Give
    // Android a small quiet window so release/final cannot outrun audio.
    _captureDrainTimer = Timer(const Duration(milliseconds: 150), () {
      if (recordingId != _captureRecordingId || recordingId != _pendingCaptureStopId) return;
      _captureDrainTimer = null;
      _pendingCaptureStopId = null;
      _captureRecordingId = null;
      _captureAudioSessionId = null;
      _stopLivePreview();
    _utteranceBuffer?.closeWindow();
      if (CaptureState.instance.isRecording) CaptureState.instance.idle();
    });
  }

  /// Transcribe one live utterance on-device and push the cleaned text to Wearable.
  Future<void> _transcribeAndSend(Int16List samples) async {
    // The streaming preview belongs to the window that just closed, and this
    // runs synchronously inside that closeWindow() — every _stopLivePreview()
    // is immediately followed by one — so taking it here, before the first
    // await, binds it to this utterance. A continuous (VAD) flush finds the
    // latch already consumed, and the SD backlog never comes through here.
    // Taken before the discard check so a cancelled note drains it too. Not
    // keyed on `overheard`: since P3 that means "not an instruction", and an
    // ordinary button note is overheard yet did run the preview.
    final preview = StreamingTranscriber.instance.takeLastPreview();
    // Row G: a cancelled note is never transcribed and never uploaded.
    if (_discarding) {
      _rememberDiscard(samples);
      return;
    }
    // Privacy Mode windows are instructions by construction. Outside it, the
    // utterance is ambient unless a push-to-talk press claimed it.
    final instruction = _privacyMode || _consumeArmedInstruction();
    await _transcribeSamples(
      samples,
      overheard: !instruction,
      preview: preview,
      // Mid-capture segments transcribe while the wearer is still talking; the
      // banner must keep saying "Recording", not "Transcribing...".
      updateCaptureState: !_rolling,
      source: 'on-device',
    );
  }

  /// Final transcript for one completed utterance.
  ///
  /// When a transcription server is configured, POST the utterance for the more
  /// accurate FINAL transcript; on ANY server failure (disabled mid-call,
  /// network, 401, timeout, empty result) fall back to the on-device zipformer
  /// so a note is never lost. The live streaming preview is untouched — it keeps
  /// coming from the on-device streaming model. The caller runs the energy/VAD
  /// gate BEFORE this, so silence is never sent to the server.
  Future<String> _finalTranscribe(Int16List samples) =>
      transcribeUtterance(samples, sampleRate: 16000);

  Future<_TranscribeResult> _transcribeSamples(
    Int16List samples, {
    required bool overheard,
    String? defaultTalker,
    bool updateCaptureState = true,
    String source = 'on-device',
    // Streaming text for this same audio, when a button window produced it.
    // Null for the SD backlog and continuous segments; see TidyGate.decide.
    String? preview,
  }) async {
    // Recording window has closed; Gemma STT runs now. The try/finally guarantees
    // CaptureState returns to idle on every exit path (silence gate, diarization
    // branches, transcribe failure, or success) so the UI banner never sticks.
    if (updateCaptureState) CaptureState.instance.transcribing();
    // Set when transcription completes with no text. Without this the banner
    // goes from "Transcribing..." straight to idle with no row appended, which
    // to a user is indistinguishable from the app losing their recording.
    var nothingHeard = false;
    try {
      // Cheap energy pre-filter before the VAD, which is the real gate. All
      // buffers are now stored at unity, so the `overheard` thresholds are the
      // old post-8x values divided by eight: raw wearable speech RMS ~200-400,
      // room ~60-100. Button windows include the quiet before and after a
      // spoken command, so they keep a lower whole-window RMS gate plus a
      // frame-peak escape hatch for short explicit instructions.
      const int minSamples = 12800; // 0.8 s at 16 kHz (matches VAD minSpeechMs)
      final minRms = overheard ? 100.0 : 250.0;
      final minPeakRms = overheard ? 200.0 : 650.0;
      final durMs = (samples.length / 16000 * 1000).round();
      final rms = pcmRms(samples);
      final peakRms = _peakFrameRms(samples);
      // Clipping is invisible in a transcript and fatal to it. Report how much
      // of the window sits at the rails, and how much would have at the old
      // 8x, so the before/after is measured on real audio rather than argued.
      var clipped = 0, wouldClip8x = 0;
      for (final v in samples) {
        final a = v < 0 ? -v : v;
        if (a >= 32767) clipped++;
        if (a * 8 >= 32767) wouldClip8x++;
      }
      debugPrint('[WearableBridge] window ${durMs}ms rms=${rms.toStringAsFixed(0)} '
          'peak=${peakRms.toStringAsFixed(0)} '
          'clipped=${(100 * clipped / samples.length).toStringAsFixed(2)}% '
          '(at 8x: ${(100 * wouldClip8x / samples.length).toStringAsFixed(1)}%)');
      if (samples.length < minSamples || (rms < minRms && peakRms < minPeakRms)) {
        debugPrint(
          '[WearableBridge] skipped silent/short utterance '
          '(rms=${rms.toStringAsFixed(1)}, peak=${peakRms.toStringAsFixed(1)}, durMs=$durMs)',
        );
        CaptureDiagnostics.instance.event(
          'Skipped audio: rms=${rms.toStringAsFixed(1)}, peak=${peakRms.toStringAsFixed(1)}, dur=${durMs}ms',
        );
        return const _TranscribeResult(ok: true, posted: false);
      }

      // --- Diarization branch ---
      // Attempt speaker diarization when models are installed. On any error we
      // fall through to the existing single-utterance path so transcription is
      // never broken by a diarization failure.
      bool diarHandled = false;
      try {
        if (await DiarizationEngine.instance.isReady()) {
          await DiarizationEngine.instance.ensureLoaded();

          // Convert Int16 PCM → Float32 for diarization (normalise to [-1, 1]).
          final prep = Stopwatch()..start();
          final f32 = Float32List(samples.length);
          for (var i = 0; i < samples.length; i++) {
            f32[i] = samples[i] / 32768.0;
          }
          final prepMs = prep.elapsedMilliseconds;

          // The native pass runs in the speaker worker isolate. Both numbers
          // are logged because they are the ANR evidence: the busy time is
          // what this isolate could not yield during, the awaited time is
          // what it could.
          final wait = Stopwatch()..start();
          final segs = await DiarizationEngine.instance.diarize(f32);
          debugPrint('[WearableBridge] diarize ${(samples.length / 16000).toStringAsFixed(1)}s: '
              'main-isolate busy ${prepMs}ms, awaited worker ${wait.elapsedMilliseconds}ms');

          // Collect distinct speaker indices.
          final distinctSpeakers = segs.map((s) => s.speaker).toSet();

          if (distinctSpeakers.length >= 2) {
            // Multi-speaker: transcribe each segment individually.
            debugPrint('[WearableBridge] diarization found ${distinctSpeakers.length} speakers, ${segs.length} segments');
            diarHandled = true;
            var postedAny = false;

            // Identity is decided once per CLUSTER, not once per segment. The
            // diarizer already grouped segments by speaker; embedding each
            // segment separately cost N passes for one answer and, worse,
            // scored 1-second slices where every speaker model is least
            // reliable. Pool the cluster's speech, embed once, and let the
            // registry's evidence gate see the real duration.
            final clipId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
            final identities = <int, _ClusterIdentity>{};
            for (final spk in distinctSpeakers) {
              identities[spk] = await _identifyCluster(f32, segs, spk);
            }

            for (final seg in segs) {
              if (!_running) return const _TranscribeResult(ok: false, posted: false);
              final segDurS = seg.end - seg.start;
              if (segDurS < 1.0) continue; // skip sub-second segments
              final segSamplesStart = (seg.start * 16000).round().clamp(0, samples.length);
              final segSamplesEnd = (seg.end * 16000).round().clamp(segSamplesStart, samples.length);
              if (segSamplesEnd <= segSamplesStart) continue;
              final segSamples = Int16List.sublistView(samples, segSamplesStart, segSamplesEnd);
              try {
                final text = await ZipformerTranscriber.instance.transcribe(segSamples, sampleRate: 16000);
                if (text.trim().isEmpty) continue;
                if (!_running) return _TranscribeResult(ok: false, posted: postedAny);
                final id = identities[seg.speaker] ?? _ClusterIdentity.unknown(seg.speaker);
                final talker = id.label;
                final entryId = OnDeviceTranscriptLog.instance.add(
                  text,
                  overheard: overheard,
                  talker: talker,
                  clipId: clipId,
                  clusterIndex: seg.speaker,
                  embedding: id.embedding,
                  durationS: id.pooledS,
                  profileId: id.profileId,
                );
                // No preview: it covers the whole clip, this line is one
                // speaker's share of it. See TidyGate.decide.
                unawaited(maybeTidy(entryId));
                // The label travels as a field, never fused into the text: a
                // speaker renamed on the phone has to be able to propagate, and
                // it cannot once the name is baked into the server's copy.
                postedAny = await _pushTranscript(text, overheard: overheard, talker: talker) || postedAny;
                debugPrint('[WearableBridge] $source diarized transcript pushed [$talker] chars=${text.runes.length}');
              } catch (e) {
                debugPrint('[WearableBridge] $source diarized segment transcribe/send failed: $e');
                return _TranscribeResult(ok: false, posted: postedAny);
              }
            }
            return _TranscribeResult(ok: true, posted: postedAny);
          } else if (distinctSpeakers.length == 1) {
            // Single speaker detected — check if owner; label accordingly.
            debugPrint('[WearableBridge] diarization: single speaker detected');
            try {
              final text = await _finalTranscribe(samples);
              if (text.trim().isEmpty) {
                nothingHeard = true;
                return const _TranscribeResult(ok: true, posted: false);
              }
              if (!_running) return const _TranscribeResult(ok: false, posted: false);
              final clipId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
              final spk = segs.isEmpty ? 0 : segs.first.speaker;
              final id = await _identifyCluster(f32, segs, spk);
              final talker = id.label;
              final entryId = OnDeviceTranscriptLog.instance.add(
                text,
                overheard: overheard,
                talker: talker,
                clipId: clipId,
                clusterIndex: spk,
                embedding: id.embedding,
                durationS: id.pooledS,
                profileId: id.profileId,
              );
              unawaited(maybeTidy(entryId,
                  preview: preview,
                  clipSeconds: samples.length / 16000));
              final posted = await _pushTranscript(text, overheard: overheard, talker: talker);
              debugPrint(
                '[WearableBridge] $source transcript logged (single diarized speaker, label=$talker, chars=${text.runes.length}, pushed=$posted)',
              );
              return _TranscribeResult(ok: true, posted: posted);
            } catch (e) {
              debugPrint('[WearableBridge] $source transcribe/send failed: $e');
              return const _TranscribeResult(ok: false, posted: false);
            }
          }
          // 0 segments: fall through to the plain path (talker: null).
        }
      } catch (e) {
        // Diarization errors must never break transcription.
        debugPrint('[WearableBridge] diarization failed, falling back to plain transcription: $e');
      }

      // --- Plain transcription path (no diarization / fallback) ---
      if (diarHandled) return const _TranscribeResult(ok: true, posted: false);
      try {
        final text = await _finalTranscribe(samples);
        if (text.trim().isEmpty) {
          nothingHeard = true;
          return const _TranscribeResult(ok: true, posted: false);
        }
        if (!_running) return const _TranscribeResult(ok: false, posted: false);
        // Always log locally so the Wearable tab shows transcripts regardless of
        // network state or whether the Wearable push succeeds.
        final entryId = OnDeviceTranscriptLog.instance
            .add(text, overheard: overheard, talker: defaultTalker);
        unawaited(maybeTidy(entryId,
            preview: preview,
            clipSeconds: samples.length / 16000));
        final posted = await _pushTranscript(text, overheard: overheard);
        debugPrint('[WearableBridge] $source transcript logged chars=${text.runes.length} pushed=$posted');
        return _TranscribeResult(ok: true, posted: posted);
      } catch (e) {
        debugPrint('[WearableBridge] $source transcribe/send failed: $e');
        return const _TranscribeResult(ok: false, posted: false);
      }
    } finally {
      if (updateCaptureState) {
        if (nothingHeard) {
          CaptureState.instance.nothingHeard();
        } else {
          CaptureState.instance.idle();
        }
      }
    }
  }

  /// End the live preview and record what it produced.
  ///
  /// The preview text is deliberately NOT saved — the offline re-decode that
  /// follows closeWindow() is the artifact. Logging it is the only way to watch
  /// the two models diverge on real wearable audio instead of on a benchmark
  /// corpus, which is how the 11.19% vs 16.26% gap was measured in the first
  /// place.
  void _stopLivePreview() {
    if (!StreamingTranscriber.instance.isActive) return;
    final preview = StreamingTranscriber.instance.stop();
    if (preview.isNotEmpty) {
      debugPrint('[Streaming] preview (not saved): $preview');
    }
  }

  /// Who is cluster [spk]? Pools every segment the diarizer gave that index,
  /// embeds the pooled audio once, and asks the registry. Never throws: on any
  /// failure the cluster keeps its 'Talker N' label and carries no evidence.
  Future<_ClusterIdentity> _identifyCluster(
      Float32List f32, List<DiarSegment> segs, int spk) async {
    final sw = Stopwatch()..start();
    final parts = <Float32List>[];
    var pooledS = 0.0;
    for (final seg in segs) {
      if (seg.speaker != spk) continue;
      final a = (seg.start * 16000).round().clamp(0, f32.length);
      final b = (seg.end * 16000).round().clamp(a, f32.length);
      if (b <= a) continue;
      parts.add(Float32List.sublistView(f32, a, b));
      pooledS += (b - a) / 16000.0;
    }
    // A single-speaker clip may arrive with no segments at all; the whole clip
    // is then the cluster.
    if (parts.isEmpty) {
      parts.add(f32);
      pooledS = f32.length / 16000.0;
    }
    final total = parts.fold<int>(0, (n, p) => n + p.length);
    final joined = Float32List(total);
    var k = 0;
    for (final p in parts) {
      joined.setRange(k, k + p.length, p);
      k += p.length;
    }

    try {
      // The embedding passes run in the speaker worker isolate; this isolate
      // only pools the audio, awaits one reply, and scores it.
      final wait = Stopwatch()..start();
      final emb = await OwnerVoice.instance.extractRobustEmbedding(joined);
      final waitMs = wait.elapsedMilliseconds;
      if (emb == null || emb.isEmpty) return _ClusterIdentity.unknown(spk);
      final m = SpeakerRegistry.instance.match(emb, durationS: pooledS);
      debugPrint('[WearableBridge] cluster $spk: ${m.reason.name} '
          'score=${m.score.toStringAsFixed(3)} margin=${m.margin.toStringAsFixed(3)} '
          'pooled=${pooledS.toStringAsFixed(1)}s'
          '${m.isKnown ? ' -> ${m.profile!.name}' : ''}'
          ' | identity main-isolate busy ${sw.elapsedMilliseconds - waitMs}ms, '
          'awaited worker ${waitMs}ms');
      // Confident matches are deliberately NOT written back into the profile.
      // Auto-adapting a template from its own matches is a documented
      // poisoning loop: one wrong confident match makes the next one likelier.
      // Profiles grow only when a person names a voice explicitly.
      return _ClusterIdentity(
        label: m.isKnown ? m.profile!.name : 'Talker ${spk + 1}',
        profileId: m.profile?.id,
        embedding: emb,
        pooledS: pooledS,
      );
    } catch (e) {
      debugPrint('[WearableBridge] identity failed for cluster $spk, keeping default label: $e');
      return _ClusterIdentity.unknown(spk);
    }
  }

  Future<void> _drainCommandQueue() async {
    // Snapshot the handle once — `_agentCmdChar` can be nulled by `dispose()`
    // during any of the awaits below. `_running` is our abort signal.
    final cmdChar = _agentCmdChar;
    if (cmdChar == null || !_running) return;
    if (!await _client.isPaired()) return; // nothing to poll; not an error
    List<Map<String, dynamic>> cmds;
    try {
      cmds = await _client.pollCommands();
    } catch (_) {
      return;
    }
    if (!_running) return;
    for (final cmd in cmds) {
      if (!_running) break; // abort mid-drain if bridge was disposed
      final bytes = encodeCommandFromJson(cmd);
      if (bytes == null) continue;
      _armAlertFor(cmd);
      try {
        await cmdChar.write(bytes, withoutResponse: true);
      } catch (_) {
        // Next poll will retry; the command queue has already been drained
        // server-side so we lose at most one packet on transient BLE errors.
        if (!_running) break;
      }
    }
  }

  /// Spec §3 rows E/F: a server cue that asks the wearer something arms
  /// ALERT_PENDING, so the next tap acknowledges instead of starting a note.
  void _armAlertFor(Map<String, dynamic> cmd) {
    if (cmd['kind'] != 'habitat') return;
    final raw = cmd['cue'];
    // The server queues cues by name; the app's own writes pass an id.
    final cue = raw is int ? raw : kHabitatCueIds[raw];
    if (cue == null) return;
    final isQuestion = alertIsQuestionForCue(cue);
    if (isQuestion == null) return;
    _alertPendingAt = DateTime.now();
    _alertIsQuestion = isQuestion;
  }

  /// Handle a server-pushed text frame on the audio WS. Currently recognises
  /// `{"type":"transcript","utterance":{...}}` envelopes emitted by Wearable on
  /// every Deepgram utterance (interim + final). Non-JSON text or unknown
  /// `type` values are ignored — keeps the handler forward-compatible.
  void _onServerMessage(dynamic raw) {
    try {
      _handleServerMessage(raw);
    } catch (e) {
      // Swallow per-message parse/type errors so one malformed frame can't
      // permanently kill the subscription via an uncaught zone error.
      debugPrint('[WearableBridge] server msg handler threw: $e');
    }
  }

  void _handleServerMessage(dynamic raw) {
    if (raw is! String) return; // binary echoes ignored
    Map<String, dynamic> env;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      env = decoded;
    } catch (_) {
      return;
    }
    final kind = env['type'];
    if (kind != 'transcript') return;
    final u = env['utterance'];
    if (u is! Map<String, dynamic>) return;
    final text = (u['text'] is String) ? (u['text'] as String).trim() : '';
    if (text.isEmpty) return;
    // Server delivers speakerId as either a numeric index or a string like
    // "speaker_1" (Deepgram's labelled form), depending on whether the voice
    // profile resolver has matched. Accept both without throwing.
    int coerceInt(dynamic v, int fallback) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) {
        final digits = RegExp(r'-?\d+').firstMatch(v)?.group(0);
        if (digits != null) return int.tryParse(digits) ?? fallback;
      }
      return fallback;
    }

    final speakerId = coerceInt(u['speakerId'], 0);
    final isFinal = u['isFinal'] == true;
    final overheard = u['overheard'] is bool
        ? u['overheard'] as bool
        : env['overheard'] is bool
        ? env['overheard'] as bool
        : true;
    final speakerLabel = (u['speakerLabel'] is String) ? (u['speakerLabel'] as String) : 'SPEAKER_$speakerId';
    final isOwner = u['isOwner'] == true;
    if (isFinal) {
      OnDeviceTranscriptLog.instance.add(text, overheard: overheard, talker: isOwner ? 'You' : speakerLabel);
    }
    debugPrint('[WearableBridge] transcript ${isFinal ? "final" : "partial"} ($speakerLabel) chars=${text.runes.length}');
  }

  int? _buttonSequenceFor(List<int> value) {
    // Current firmware keeps the historical int[2] payload, so byte 4 is the
    // low byte of final_button_state[1]. Accept byte 1 too for future uint8[2]
    // firmware without needing another app update.
    if (value.length >= 5) return value[4];
    if (value.length >= 2) return value[1];
    return null;
  }

  double _peakFrameRms(Int16List samples) {
    const frameSamples = 160; // 10 ms at 16 kHz.
    var peak = 0.0;
    for (var offset = 0; offset < samples.length; offset += frameSamples) {
      final end = math.min(offset + frameSamples, samples.length);
      final len = end - offset;
      if (len <= 0) continue;
      var sumSquares = 0.0;
      for (var i = offset; i < end; i++) {
        final sample = samples[i].toDouble();
        sumSquares += sample * sample;
      }
      final rms = math.sqrt(sumSquares / len);
      if (rms > peak) peak = rms;
    }
    return peak;
  }

  /// Internal confirmation that a button tap reached the app. This stays out
  /// of the transcript feed so button chatter doesn't bury spoken instructions.
  void _signalButton(String code) {
    CaptureDiagnostics.instance.event('Button: $code');
  }

  void _showCaptureError(String message) {
    try {
      WearableSnackbar.showError(message);
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (identical(_current, this)) _current = null;
    if (!_running) return;
    // File an in-flight note before tearing anything down. The link dropping
    // mid-sentence used to reach _utteranceBuffer.reset() below and bin up to
    // two minutes of speech with no transcript, no discard entry and no error.
    // Do this while _running is still true so the transcribe/push path works.
    final pending = _captureRecordingId;
    if (pending != null) {
      _captureRecordingId = null;
      CaptureDiagnostics.instance.event('Link lost mid-note; filing what was captured');
      _stopLivePreview();
    _utteranceBuffer?.closeWindow();
    }
    _running = false;
    // Drop back to a normal background process. A disconnected wearable must
    // not leave a "Wearable connected" notification the wearer cannot explain.
    unawaited(CaptureService.instance.stop());
    _clearAlert();
    _pollTimer?.cancel();
    _captureWindowTimer?.cancel();
    _captureBudgetTimer?.cancel();
    _captureDrainTimer?.cancel();
    _sdSyncTimer?.cancel();
    await _audioSub?.cancel();
    await _buttonSub?.cancel();
    await _storageSub?.cancel();
    try {
      await _audioWs?.sink.close();
    } catch (_) {
      /* ignore */
    }
    _audioWs = null;
    _agentCmdChar = null;
    _storageDataChar = null;
    _storageReadChar = null;
    _storageSub = null;
    _utteranceBuffer?.reset();
    _utteranceBuffer = null;
    _opusDecoder?.dispose();
    _opusDecoder = null;
    try {
      await _device.disconnect();
    } catch (_) {
      /* ignore */
    }
  }
}

/// What the registry decided about one diarizer cluster, plus the evidence it
/// decided on — carried onto each transcript line so a tap can name it.
class _ClusterIdentity {
  const _ClusterIdentity({
    required this.label,
    required this.profileId,
    required this.embedding,
    required this.pooledS,
  });

  _ClusterIdentity.unknown(int spk)
      : label = 'Talker ${spk + 1}',
        profileId = null,
        embedding = null,
        pooledS = 0;

  final String label;
  final String? profileId;
  final Float32List? embedding;
  final double pooledS;
}
