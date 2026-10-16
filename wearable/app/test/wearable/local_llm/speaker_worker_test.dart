// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Protocol tests for SpeakerWorker with a fake backend — a REAL second
// isolate, no sherpa. What is under test is the plumbing the ANR fix depends
// on: the ready handshake, audio crossing as TransferableTypedData, FIFO
// serialisation, and the failure policy (a failed request fails alone; a
// dead worker is rebuilt once, then the worker fails open).

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_worker.dart';

/// Audio "commands": the first sample tells the fake what to do.
const double kThrowMarker = -7.0;
const double kKillMarker = -9.0;
const int kFakeDim = 4;

class _FakeBackend implements SpeakerBackend {
  @override
  Float64List diarize(Float32List s) {
    _obey(s);
    // One segment per whole second, alternating speakers; carries the input
    // length so a caller can tell which request a reply belongs to.
    final secs = s.length ~/ 16000;
    final out = Float64List(secs * 3);
    for (var i = 0; i < secs; i++) {
      out[i * 3] = i.toDouble();
      out[i * 3 + 1] = i + 1.0;
      out[i * 3 + 2] = (i % 2).toDouble();
    }
    return out;
  }

  @override
  Float32List? embed(Float32List s) {
    _obey(s);
    if (s.length < 8000) return null; // "clip too short", like isReady()==false
    return Float32List.fromList([s.length.toDouble(), 1, 0, 0]);
  }

  void _obey(Float32List s) {
    if (s.isEmpty) return;
    if (s[0] == kThrowMarker) throw StateError('fake backend asked to throw');
    if (s[0] == kKillMarker) Isolate.current.kill(priority: Isolate.immediate);
  }

  @override
  void dispose() {}
}

/// Top-level: it is what Isolate.spawn runs.
void fakeWorkerMain(List<Object?> boot) => runSpeakerWorker(boot, (cfg) {
      if (cfg.segmentationModelPath == 'boot-fail') {
        throw StateError('fake boot failure');
      }
      return _FakeBackend();
    });

SpeakerWorker _worker({String seg = 'seg.onnx'}) => SpeakerWorker(
      resolveConfig: () async =>
          SpeakerWorkerConfig(segmentationModelPath: seg, embeddingModelPath: 'emb.onnx'),
      entry: fakeWorkerMain,
      startTimeout: const Duration(seconds: 20),
    );

Float32List _audio(double seconds, {double first = 0}) {
  final a = Float32List((seconds * 16000).round());
  if (a.isNotEmpty) a[0] = first;
  return a;
}

void main() {
  test('ready handshake, then diarize returns flat [start, end, speaker] triples', () async {
    final w = _worker();
    expect(w.isRunning, isFalse);
    await w.ensureStarted();
    expect(w.isRunning, isTrue);
    expect(w.spawnCount, 1);

    final flat = await w.diarize(_audio(3));
    expect(flat, isA<Float64List>());
    expect(flat.length, 9);
    expect(flat.sublist(0, 3), [0.0, 1.0, 0.0]);
    expect(flat.sublist(3, 6), [1.0, 2.0, 1.0]);
    await w.dispose();
  });

  test('embed round-trips the vector; a too-short clip is null, not an error', () async {
    final w = _worker();
    final emb = await w.embed(_audio(2));
    expect(emb, isNotNull);
    expect(emb!.length, kFakeDim);
    expect(emb[0], 2 * 16000.0);
    expect(await w.embed(_audio(0.25)), isNull);
    await w.dispose();
  });

  test('embedRobust runs inside the worker and returns a unit vector', () async {
    final w = _worker();
    final emb = await w.embedRobust(_audio(6));
    expect(emb, isNotNull);
    expect(emb!.length, kFakeDim);
    var norm = 0.0;
    for (final x in emb) {
      norm += x * x;
    }
    expect(norm, closeTo(1.0, 1e-5));
    await w.dispose();
  });

  test('audio arrives intact (TransferableTypedData round trip)', () async {
    // The fake's diarize is keyed on sample count; embed echoes it back.
    final w = _worker();
    final emb = await w.embed(_audio(1.5));
    expect(emb![0], 24000.0);
    await w.dispose();
  });

  test('requests are serialised FIFO — replies match their requests in order', () async {
    final w = _worker();
    final futures = [
      w.embed(_audio(3)),
      w.embed(_audio(1)),
      w.embed(_audio(2)),
    ];
    final results = await Future.wait(futures);
    expect(results.map((e) => e![0]).toList(), [48000.0, 16000.0, 32000.0]);
    expect(w.spawnCount, 1);
    await w.dispose();
  });

  test('a request that throws in the worker fails alone; the worker stays up', () async {
    final w = _worker();
    await expectLater(
      w.embed(_audio(2, first: kThrowMarker)),
      throwsA(isA<SpeakerWorkerRequestFailed>()),
    );
    expect(w.isRunning, isTrue);
    expect(await w.embed(_audio(2)), isNotNull);
    expect(w.spawnCount, 1);
    expect(w.failedOpen, isFalse);
    await w.dispose();
  });

  test('a dead worker is rebuilt once; a second death fails open', () async {
    final w = _worker();
    await expectLater(
      w.embed(_audio(2, first: kKillMarker)),
      throwsA(isA<SpeakerWorkerUnavailable>()),
    );
    expect(w.isRunning, isFalse);
    expect(w.failedOpen, isFalse);

    // Rebuilt transparently on the next request.
    expect(await w.embed(_audio(2)), isNotNull);
    expect(w.spawnCount, 2);

    await expectLater(
      w.diarize(_audio(2, first: kKillMarker)),
      throwsA(isA<SpeakerWorkerUnavailable>()),
    );
    expect(w.failedOpen, isTrue);

    // Failed open: no third spawn, every call throws the same way.
    await expectLater(w.embed(_audio(2)), throwsA(isA<SpeakerWorkerUnavailable>()));
    await expectLater(w.diarize(_audio(2)), throwsA(isA<SpeakerWorkerUnavailable>()));
    await expectLater(w.embedRobust(_audio(2)), throwsA(isA<SpeakerWorkerUnavailable>()));
    await expectLater(w.ensureStarted(), throwsA(isA<SpeakerWorkerUnavailable>()));
    expect(w.spawnCount, 2);
  });

  test('a boot failure counts toward failing open', () async {
    final w = _worker(seg: 'boot-fail');
    await expectLater(w.ensureStarted(), throwsA(isA<SpeakerWorkerUnavailable>()));
    expect(w.failedOpen, isFalse);
    await expectLater(w.diarize(_audio(1)), throwsA(isA<SpeakerWorkerUnavailable>()));
    expect(w.failedOpen, isTrue);
    expect(w.spawnCount, 2);
    await expectLater(w.embed(_audio(1)), throwsA(isA<SpeakerWorkerUnavailable>()));
    expect(w.spawnCount, 2, reason: 'failed open: must not spawn again');
  });

  test('concurrent first calls share one spawn', () async {
    final w = _worker();
    final results = await Future.wait([w.embed(_audio(1)), w.diarize(_audio(2))]);
    expect(results[0], isNotNull);
    expect(results[1], isNotNull);
    expect(w.spawnCount, 1);
    await w.dispose();
  });

  test('dispose is not a death: the next request starts a fresh worker', () async {
    final w = _worker();
    expect(await w.embed(_audio(1)), isNotNull);
    await w.dispose();
    expect(w.isRunning, isFalse);
    expect(w.failedOpen, isFalse);
    expect(await w.embed(_audio(1)), isNotNull);
    expect(w.spawnCount, 2);
    expect(w.failedOpen, isFalse);
    await w.dispose();
  });

  test('dispose on a never-started worker is a no-op', () async {
    final w = _worker();
    await w.dispose();
    expect(w.spawnCount, 0);
  });
}
