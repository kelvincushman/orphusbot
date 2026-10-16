// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// CaptureDiagnostics — live, in-memory telemetry for the wearable capture path.
// This gives the Transcripts page enough signal to distinguish "button reached
// the app" from "audio frames are arriving" from "audio is silent".

import 'package:flutter/foundation.dart';

import 'transcription_mode.dart';

class CaptureDiagnostics extends ChangeNotifier {
  CaptureDiagnostics._();

  static final CaptureDiagnostics instance = CaptureDiagnostics._();

  TranscriptionMode? _mode;
  OnDeviceSegmentation? _segmentation;
  String _encoding = 'unknown';
  int _frameMs = 0;
  int _frameCount = 0;
  int _payloadLen = 0;
  int _payloadSum = 0;
  int _sampleCount = 0;
  double? _decodedRms;
  String? _message;
  DateTime? _updatedAt;

  TranscriptionMode? get mode => _mode;
  OnDeviceSegmentation? get segmentation => _segmentation;
  String get encoding => _encoding;
  int get frameMs => _frameMs;
  int get frameCount => _frameCount;
  int get payloadLen => _payloadLen;
  int get payloadSum => _payloadSum;
  int get sampleCount => _sampleCount;
  double? get decodedRms => _decodedRms;
  String? get message => _message;
  DateTime? get updatedAt => _updatedAt;

  bool get hasFrames => _frameCount > 0;
  bool get looksSilent => hasFrames && (_decodedRms ?? 0) < 1.0;

  String get modeLabel {
    final mode = _mode;
    if (mode == null) return 'audio pending';
    final seg = _segmentation == null ? '' : '/${_segmentation!.name}';
    return '${mode.name}$seg';
  }

  void updateMode(
    TranscriptionMode mode,
    OnDeviceSegmentation segmentation, {
    required String encoding,
    required int frameMs,
    String? message,
  }) {
    _mode = mode;
    _segmentation = segmentation;
    _encoding = encoding;
    _frameMs = frameMs;
    _message = message;
    _updatedAt = DateTime.now();
    notifyListeners();
  }

  void updateFrame({
    required int frameCount,
    required int payloadLen,
    required int payloadSum,
    required int sampleCount,
    required double decodedRms,
  }) {
    _frameCount = frameCount;
    _payloadLen = payloadLen;
    _payloadSum = payloadSum;
    _sampleCount = sampleCount;
    _decodedRms = decodedRms;
    _message = null;
    _updatedAt = DateTime.now();
    notifyListeners();
  }

  void event(String message) {
    _message = message;
    _updatedAt = DateTime.now();
    notifyListeners();
  }

  void resetFrames() {
    _frameCount = 0;
    _payloadLen = 0;
    _payloadSum = 0;
    _sampleCount = 0;
    _decodedRms = null;
    _updatedAt = DateTime.now();
    notifyListeners();
  }
}
