// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The sherpa_onnx half of the speaker worker. Constructed INSIDE the worker
// isolate by [sherpaSpeakerWorkerMain]; nothing here is ever touched from the
// UI isolate. All speaker-identity sherpa calls live in this one file.
//
// initBindings() is called here, in the worker, on purpose: sherpa's function
// pointers are static fields, and Dart statics are per-isolate. A worker that
// skipped it would find every binding null and throw "Please initialize
// sherpa-onnx first". DynamicLibrary.open() on the same .so from a second
// isolate is a dlopen() refcount bump, not a second copy of the library.

import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'speaker_worker_isolate.dart';

/// The app's worker isolate entry point: Isolate.spawn runs this, and it
/// serves requests with a [SherpaSpeakerBackend] built in the worker.
void sherpaSpeakerWorkerMain(List<Object?> boot) =>
    runSpeakerWorker(boot, SherpaSpeakerBackend.new);

class SherpaSpeakerBackend implements SpeakerBackend {
  SherpaSpeakerBackend(SpeakerWorkerConfig config) {
    sherpa.initBindings();
    _diarizer = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: config.segmentationModelPath,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: config.embeddingModelPath,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        clustering: const sherpa.FastClusteringConfig(
          numClusters: -1, // auto-detect speaker count
          threshold: 0.5,
        ),
        minDurationOn: 0.2,
        minDurationOff: 0.5,
      ),
    );
    _extractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: config.embeddingModelPath,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
      ),
    );
  }

  late final sherpa.OfflineSpeakerDiarization _diarizer;
  late final sherpa.SpeakerEmbeddingExtractor _extractor;

  @override
  Float64List diarize(Float32List samples16k) {
    final raw = _diarizer.process(samples: samples16k);
    final out = Float64List(raw.length * 3);
    for (var i = 0; i < raw.length; i++) {
      out[i * 3] = raw[i].start;
      out[i * 3 + 1] = raw[i].end;
      out[i * 3 + 2] = raw[i].speaker.toDouble();
    }
    return out;
  }

  @override
  Float32List? embed(Float32List samples16k) {
    final stream = _extractor.createStream();
    try {
      stream.acceptWaveform(samples: samples16k, sampleRate: 16000);
      // Signal end-of-input so the extractor finalizes the stream. REQUIRED:
      // without it, isReady() never returns true and compute() runs on an
      // unfinalized stream -> native segfault (crashes the whole app). The
      // sherpa_onnx Dart doc-comment example omits this, but it is mandatory.
      stream.inputFinished();
      if (!_extractor.isReady(stream)) return null; // clip too short
      final embedding = _extractor.compute(stream);
      return embedding.isEmpty ? null : embedding;
    } finally {
      stream.free();
    }
  }

  @override
  void dispose() {
    _diarizer.free();
    _extractor.free();
  }
}
