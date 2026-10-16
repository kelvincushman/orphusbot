// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// What runs INSIDE the speaker worker isolate: the contract for whatever does
// the native work ([SpeakerBackend]) and the request loop that serves the
// main-isolate client in speaker_worker.dart. Kept apart from both the client
// and the sherpa backend so neither has to import the other, and so a host
// test can run the loop with a fake backend and no native library at all.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'speaker_embedding_math.dart';

/// Everything the worker needs to build its native objects. Strings only —
/// the whole point is that nothing here is a native pointer.
class SpeakerWorkerConfig {
  const SpeakerWorkerConfig({
    required this.segmentationModelPath,
    required this.embeddingModelPath,
  });

  final String segmentationModelPath;
  final String embeddingModelPath;
}

/// The native half of the worker, constructed INSIDE the worker isolate.
abstract class SpeakerBackend {
  /// Speaker-labelled segments as a flat `[start, end, speaker]` triple list.
  Float64List diarize(Float32List samples16k);

  /// One whole-clip embedding, or null when the clip is too short to yield one.
  Float32List? embed(Float32List samples16k);

  void dispose();
}

/// Builds the backend inside the worker isolate.
typedef SpeakerBackendFactory = SpeakerBackend Function(SpeakerWorkerConfig config);

/// The worker isolate's request loop. An entry point calls this with the
/// boot message it was spawned with and the factory for its backend; the
/// backend is built here, inside the worker, then requests are served until
/// 'dispose'.
///
/// Boot: `[SendPort reply, SpeakerWorkerConfig]`.
/// Requests: `[op, id, TransferableTypedData audio]` or `['dispose']`.
/// Replies: `['ready', SendPort]`, `['boot-error', error, stack]`,
/// `['ok', id, result, elapsedMs]`, `['err', id, error, stack]`.
void runSpeakerWorker(List<Object?> boot, SpeakerBackendFactory makeBackend) {
  final reply = boot[0] as SendPort;
  final cfg = boot[1] as SpeakerWorkerConfig;

  final SpeakerBackend backend;
  final sw = Stopwatch()..start();
  try {
    backend = makeBackend(cfg);
  } catch (e, st) {
    reply.send(<Object?>['boot-error', '$e', '$st']);
    return;
  }
  debugPrint('[SpeakerWorker] models loaded in ${sw.elapsedMilliseconds}ms');

  final rx = ReceivePort('speaker-worker/requests');
  rx.listen((Object? msg) {
    if (msg is! List || msg.isEmpty) return;
    final op = msg[0];
    if (op == 'dispose') {
      backend.dispose();
      rx.close();
      return;
    }
    final id = msg[1] as int;
    try {
      final audio =
          (msg[2] as TransferableTypedData).materialize().asFloat32List();
      final t = Stopwatch()..start();
      final Object? result = switch (op) {
        'diarize' => backend.diarize(audio),
        'embed' => backend.embed(audio),
        'embedRobust' => _robust(backend, audio),
        _ => throw ArgumentError('unknown op: $op'),
      };
      final ms = t.elapsedMilliseconds;
      debugPrint('[SpeakerWorker] $op: ${(audio.length / kSpeakerSampleRate).toStringAsFixed(1)}s '
          'in ${ms}ms');
      reply.send(<Object?>['ok', id, result, ms]);
    } catch (e, st) {
      reply.send(<Object?>['err', id, '$e', '$st']);
    }
  });
  reply.send(<Object?>['ready', rx.sendPort]);
}

Float32List? _robust(SpeakerBackend backend, Float32List audio) {
  final r = robustEmbedding(audio, backend.embed);
  debugPrint('[SpeakerWorker] embedRobust: ${r.passes} pass(es)');
  return r.embedding;
}
