// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// DiarizationEngine — assigns speaker labels to time segments in a 16 kHz
// mono Float32 audio clip.
//
// The native diarizer (sherpa_onnx OfflineSpeakerDiarization) lives in the
// SpeakerWorker isolate, not here: process() is a synchronous FFI call that
// took 8–13 s on a 30 s window and, run on the UI isolate, produced an ANR
// ("Input dispatching timed out ... FocusEvent") that killed the app. This
// facade keeps the public surface the bridge and the tests were written
// against; the awaits below cost the UI isolate milliseconds, not seconds.
//
// Usage:
//   if (await DiarizationEngine.instance.isReady()) {
//     await DiarizationEngine.instance.ensureLoaded();
//     final segs = await DiarizationEngine.instance.diarize(samples16k);
//   }

import 'dart:async';
import 'dart:typed_data';

import 'diarization_provisioner.dart';
import 'speaker_worker.dart';

/// An immutable speaker-labeled time segment returned by [DiarizationEngine.diarize].
class DiarSegment {
  const DiarSegment({
    required this.start,
    required this.end,
    required this.speaker,
  });

  /// Start time in seconds (relative to the beginning of the audio clip).
  final double start;

  /// End time in seconds.
  final double end;

  /// Zero-based speaker index assigned by the clustering step.
  final int speaker;

  @override
  String toString() =>
      'DiarSegment(speaker: $speaker, ${start.toStringAsFixed(2)}s–${end.toStringAsFixed(2)}s)';
}

class DiarizationEngine {
  DiarizationEngine._();
  static final DiarizationEngine instance = DiarizationEngine._();

  /// True when model files are installed and ready to load.
  Future<bool> isReady() => DiarizationProvisioner.instance.isInstalled();

  /// Start the worker and load the models inside it (lazy, shared, idempotent).
  /// Throws if models are not installed — call [isReady] first — or if the
  /// worker has failed open ([SpeakerWorkerUnavailable]).
  Future<void> ensureLoaded() => SpeakerWorker.instance.ensureStarted();

  /// Run speaker diarization on [samples16k] (Float32, 16 kHz, mono).
  /// Returns a list of [DiarSegment] sorted by start time.
  ///
  /// The native pass runs in the worker isolate; this isolate only copies the
  /// audio out and the (tiny) segment list back in.
  Future<List<DiarSegment>> diarize(Float32List samples16k) async {
    final flat = await SpeakerWorker.instance.diarize(samples16k);
    return [
      for (var i = 0; i + 2 < flat.length; i += 3)
        DiarSegment(start: flat[i], end: flat[i + 1], speaker: flat[i + 2].toInt()),
    ];
  }

  /// Free native model memory (and the extractor OwnerVoice shares with it).
  void dispose() {
    unawaited(SpeakerWorker.instance.dispose());
  }
}
