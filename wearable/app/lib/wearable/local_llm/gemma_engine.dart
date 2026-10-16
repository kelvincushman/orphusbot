// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// GemmaEngine — owns the lifecycle of the on-device Gemma 4 model
// (flutter_gemma). All flutter_gemma model/inference calls live here and in
// gemma_transcriber.dart so the rest of the app stays API-stable.
//
// The model (Gemma 4 E2B, ~2.6 GB) is installed/activated via
// GemmaModelProvisioner; this class only loads the already-active model. It is
// text-only: Gemma tidies transcripts that zipformer produced and never sees
// audio.

import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';
// MobileModelManager isn't exported from the package root; it carries the
// active-model rehydrate (`initialize()`) used by [warmInstalledState].
import 'package:flutter_gemma/mobile/flutter_gemma_mobile.dart'
    show MobileModelManager;

class GemmaEngine {
  GemmaEngine._();
  static final GemmaEngine instance = GemmaEngine._();

  InferenceModel? _model;
  Future<InferenceModel>? _loading;

  /// True once a model has been installed + set active (download/sideload done).
  bool isInstalled() => FlutterGemma.hasActiveModel();

  /// Rehydrate flutter_gemma's active-model state from persisted prefs after an
  /// app restart. `FlutterGemma.initialize()` only inits the service registry —
  /// it does NOT restore the active inference model, so without this
  /// [isInstalled]/`hasActiveModel()` returns false on every launch even when
  /// the model is installed on disk, and the on-device path silently falls back
  /// to cloud. The model manager's `initialize()` performs the one-time
  /// rehydrate (idempotent, guarded by its own `_isInitialized`). Call once at
  /// startup, after `FlutterGemma.initialize()`.
  Future<void> warmInstalledState() async {
    final manager = FlutterGemmaPlugin.instance.modelManager;
    if (manager is MobileModelManager) {
      await manager.initialize();
    }
  }

  /// Lazily create the inference model. Guards against concurrent double-load.
  Future<InferenceModel> ensureLoaded() {
    final existing = _model;
    if (existing != null) return Future.value(existing);
    return _loading ??= _load();
  }

  Future<InferenceModel> _load() async {
    try {
      final model = await FlutterGemma.getActiveModel(
        maxTokens: 1024,
        // CPU, deliberately. docs/research/ON_DEVICE_STT.md measured the GPU
        // path on this class of device at 2/13 clean outputs against 13/13 on
        // CPU — byte-identical across runs, so deterministic corruption on
        // Mali/Xclipse rather than sampling noise, and exactly the failure that
        // silently wrecks a transcript. Its conclusion was "ship CPU-first;
        // GPU only behind a measurement", and the code was never changed to
        // match. For a text-only tidy pass the CPU cost is acceptable.
        preferredBackend: PreferredBackend.cpu,
        // No audio encoder. Gemma stopped seeing audio when ASR moved to
        // sherpa; loading the encoder anyway costs memory on a device where
        // memory is the documented failure mode.
        supportAudio: false,
      );
      _model = model;
      return model;
    } catch (_) {
      _loading = null; // allow a retry on next call
      rethrow;
    }
  }

  /// Free native model memory. Call when leaving on-device mode.
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    _loading = null;
    await model?.close();
  }
}
