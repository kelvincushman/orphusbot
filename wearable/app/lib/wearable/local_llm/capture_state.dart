// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// CaptureState — session status of a button-triggered voice-note capture.
//
// WearableDeviceBridge advances this as a single-tap capture window opens
// (recording), runs Gemma STT (transcribing), and finishes (idle).
// TranscriptsPage listens and shows a live recording/transcribing banner so
// the wearer gets immediate feedback that a voice note is being captured and
// transcribed — the visible counterpart to the button toast.
//
// Mirrors the CaptureMute singleton pattern. Not persisted — resets to idle on
// each app launch.

import 'dart:async';

import 'package:flutter/foundation.dart';

enum CaptureStatus { idle, recording, transcribing, nothingHeard }

class CaptureState extends ChangeNotifier {
  CaptureState._();

  static final CaptureState instance = CaptureState._();

  CaptureStatus _status = CaptureStatus.idle;

  CaptureStatus get status => _status;
  bool get isRecording => _status == CaptureStatus.recording;
  bool get isTranscribing => _status == CaptureStatus.transcribing;
  bool get isNothingHeard => _status == CaptureStatus.nothingHeard;
  bool get isActive => _status != CaptureStatus.idle;

  /// How long [nothingHeard] stays on screen before falling back to idle.
  /// Long enough to read, short enough not to sit over the next capture.
  static const Duration nothingHeardLinger = Duration(seconds: 4);

  Timer? _lingerTimer;

  void _set(CaptureStatus value) {
    // Any new state supersedes a lingering result — starting a capture must
    // never leave a stale "nothing heard" banner counting down over it.
    _lingerTimer?.cancel();
    _lingerTimer = null;
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  void recording() => _set(CaptureStatus.recording);
  void transcribing() => _set(CaptureStatus.transcribing);
  void idle() => _set(CaptureStatus.idle);

  /// The capture completed but produced no text.
  ///
  /// This existed as a silent path: the banner went from "Transcribing…"
  /// straight back to idle and no row appeared, which reads as the app losing
  /// a recording. Saying so is the difference between a bug and a result.
  void nothingHeard() {
    _set(CaptureStatus.nothingHeard);
    _lingerTimer = Timer(nothingHeardLinger, () {
      _lingerTimer = null;
      if (_status == CaptureStatus.nothingHeard) {
        _status = CaptureStatus.idle;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _lingerTimer?.cancel();
    super.dispose();
  }
}
