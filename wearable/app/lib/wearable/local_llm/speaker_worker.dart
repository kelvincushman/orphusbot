// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// SpeakerWorker — a long-lived worker isolate that owns the speaker diarizer
// and the speaker-embedding extractor, so their synchronous native passes
// never run on the UI isolate.
//
// Why: a 30 s continuous window with 25 s of speech blocked the main isolate
// for 13–20 s (diarize the window, then up to 7 embedding passes on the pooled
// cluster — all synchronous FFI). A focus event landed during the block and
// Android killed the app:
//   ANR in com.kelvinlee.wearable.dev — Input dispatching timed out.
//   Waited 10000ms for FocusEvent(hasFocus=false)
//
// How: the worker is spawned once with the two model PATHS (plain Strings)
// and builds its own native objects — sherpa's bindings are per-isolate
// statics, so initBindings() is called again inside the worker (verified on
// device before this was written; see the commit). Audio crosses as
// TransferableTypedData, which the worker materialises without a copy;
// results come back as small typed lists. Requests are serialised — one in
// flight, FIFO — which also keeps the worker's native objects single-threaded.
//
// Failure policy: a request that fails inside the worker fails only that
// request. A worker that dies is rebuilt once on the next request; if it dies
// again the worker fails open and every later call throws
// [SpeakerWorkerUnavailable]. The callers already treat speaker identity as
// best-effort — a naming failure must never break transcription.
//
// This file is the main-isolate client. What runs inside the isolate — the
// [SpeakerBackend] contract and the request loop — is speaker_worker_isolate.dart.
// The isolate entry point is injected (a top-level function, the one thing
// Isolate.spawn always accepts) and hands [runSpeakerWorker] a backend factory,
// so the protocol is host-testable with a fake backend and no native library.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'diarization_provisioner.dart';
import 'sherpa_speaker_backend.dart';
import 'speaker_worker_isolate.dart';

export 'speaker_worker_isolate.dart';

/// The worker is gone for good (or could not be started) — fail open.
class SpeakerWorkerUnavailable implements Exception {
  const SpeakerWorkerUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'SpeakerWorkerUnavailable: $reason';
}

/// One request failed inside the worker; the worker itself is still up.
class SpeakerWorkerRequestFailed implements Exception {
  const SpeakerWorkerRequestFailed(this.error, this.stack);
  final String error;
  final String stack;
  @override
  String toString() => 'SpeakerWorkerRequestFailed: $error';
}

/// An isolate entry point that calls [runSpeakerWorker] with its backend.
/// Must be a top-level or static function — it is what Isolate.spawn runs.
typedef SpeakerWorkerEntry = void Function(List<Object?> boot);

class SpeakerWorker {
  SpeakerWorker({
    required Future<SpeakerWorkerConfig> Function() resolveConfig,
    required SpeakerWorkerEntry entry,
    this.maxRebuilds = 1,
    this.startTimeout = const Duration(seconds: 90),
  })  : _resolveConfig = resolveConfig,
        _entry = entry;

  /// The app's worker: model paths from the provisioner, sherpa inside.
  static final SpeakerWorker instance = SpeakerWorker(
    resolveConfig: _productionConfig,
    entry: sherpaSpeakerWorkerMain,
  );

  static Future<SpeakerWorkerConfig> _productionConfig() async {
    final prov = DiarizationProvisioner.instance;
    // Populates the path cache (platform channel — main isolate only).
    await prov.isInstalled();
    return SpeakerWorkerConfig(
      segmentationModelPath: prov.segmentationModelPath,
      embeddingModelPath: prov.embeddingModelPath,
    );
  }

  final Future<SpeakerWorkerConfig> Function() _resolveConfig;
  final SpeakerWorkerEntry _entry;

  /// How many times a dead worker is rebuilt before failing open.
  final int maxRebuilds;

  /// Model load happens inside the worker; this bounds the wait for 'ready'.
  final Duration startTimeout;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  ReceivePort? _onExit;
  ReceivePort? _onError;
  Completer<void>? _ready;
  Future<void>? _starting;

  int _deaths = 0;
  int _seq = 0;
  final Map<int, _Pending> _pending = <int, _Pending>{};
  Future<void> _tail = Future<void>.value();

  /// Spawns so far — the rebuild-once contract is asserted through this.
  @visibleForTesting
  int spawnCount = 0;

  bool get isRunning => _toWorker != null;

  /// True once the worker has died (or failed to boot) more than
  /// [maxRebuilds] times. Nothing restarts it after that.
  bool get failedOpen => _deaths > maxRebuilds;

  /// Spawn the worker and wait until its models are loaded. Idempotent;
  /// concurrent callers share one spawn.
  Future<void> ensureStarted() {
    if (_toWorker != null) return Future<void>.value();
    if (failedOpen) {
      return Future<void>.error(SpeakerWorkerUnavailable(
          'worker died $_deaths time(s); not rebuilding'));
    }
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  /// Speaker segments for [samples16k] as flat `[start, end, speaker]` triples.
  Future<Float64List> diarize(Float32List samples16k) async =>
      (await _request('diarize', samples16k)) as Float64List;

  /// One whole-clip embedding, or null when the clip is too short.
  Future<Float32List?> embed(Float32List samples16k) async =>
      (await _request('embed', samples16k)) as Float32List?;

  /// The multi-scale embedding ([robustEmbedding]) computed entirely inside
  /// the worker: up to 7 forward passes, none of them on the caller's isolate.
  Future<Float32List?> embedRobust(Float32List samples16k) async =>
      (await _request('embedRobust', samples16k)) as Float32List?;

  /// Free the worker's native models and let the isolate exit. Not a death:
  /// the next request starts a fresh worker.
  Future<void> dispose() async {
    await _tail;
    final port = _toWorker;
    if (port == null) return;
    port.send(const <Object>['dispose']);
    _teardown('disposed');
  }

  // ---------------------------------------------------------------------------

  Future<void> _start() async {
    final cfg = await _resolveConfig();
    final from = ReceivePort('speaker-worker/from');
    final exit = ReceivePort('speaker-worker/exit');
    final err = ReceivePort('speaker-worker/error');
    final ready = Completer<void>();
    _fromWorker = from;
    _onExit = exit;
    _onError = err;
    _ready = ready;
    from.listen(_onMessage);
    exit.listen((_) => _onDeath('exited'));
    err.listen((e) => _onDeath('uncaught error: $e'));

    spawnCount++;
    final sw = Stopwatch()..start();
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _entry,
        <Object?>[from.sendPort, cfg],
        onExit: exit.sendPort,
        onError: err.sendPort,
        debugName: 'speaker-worker',
      );
    } catch (e) {
      _onDeath('spawn failed: $e');
      rethrow;
    }
    try {
      await ready.future.timeout(startTimeout);
    } on TimeoutException {
      _isolate?.kill(priority: Isolate.immediate);
      _onDeath('no ready within ${startTimeout.inSeconds}s');
      rethrow;
    }
    debugPrint('[SpeakerWorker] ready in ${sw.elapsedMilliseconds}ms '
        '(spawn #$spawnCount)');
  }

  void _onMessage(Object? msg) {
    if (msg is! List || msg.isEmpty) return;
    switch (msg[0]) {
      case 'ready':
        _toWorker = msg[1] as SendPort;
        _ready?.complete();
      case 'boot-error':
        _onDeath('boot failed: ${msg[1]}\n${msg[2]}');
      case 'ok':
        final p = _pending.remove(msg[1] as int);
        if (p == null) return;
        // Logged here, on the main isolate: the worker's own elapsed time
        // next to the round trip, so the two can be compared in one line.
        debugPrint('[SpeakerWorker] ${p.op}: worker ${msg[3]}ms, '
            'round trip ${p.since.elapsedMilliseconds}ms');
        p.completer.complete(msg[2]);
      case 'err':
        final p = _pending.remove(msg[1] as int);
        p?.completer.completeError(
            SpeakerWorkerRequestFailed('${msg[2]}', '${msg[3]}'));
    }
  }

  void _onDeath(String why) {
    _deaths++;
    _teardown(why);
    debugPrint('[SpeakerWorker] died ($why); deaths=$_deaths'
        '${failedOpen ? ' — failing open' : ' — will rebuild on next request'}');
  }

  void _teardown(String why) {
    _fromWorker?.close();
    _onExit?.close();
    _onError?.close();
    _fromWorker = null;
    _onExit = null;
    _onError = null;
    _toWorker = null;
    _isolate = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(SpeakerWorkerUnavailable(why));
    }
    final pending = List<_Pending>.of(_pending.values);
    _pending.clear();
    for (final p in pending) {
      p.completer.completeError(SpeakerWorkerUnavailable(why));
    }
  }

  /// FIFO, one in flight. A failed request does not poison the chain.
  Future<Object?> _request(String op, Float32List samples) {
    final run = _tail.then((_) => _send(op, samples));
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<Object?> _send(String op, Float32List samples) async {
    await ensureStarted();
    final port = _toWorker;
    if (port == null) throw const SpeakerWorkerUnavailable('not running');
    final id = ++_seq;
    final p = _Pending(op);
    _pending[id] = p;
    final bytes = TransferableTypedData.fromList(<TypedData>[
      Uint8List.sublistView(samples),
    ]);
    port.send(<Object?>[op, id, bytes]);
    return p.completer.future;
  }
}

class _Pending {
  _Pending(this.op);
  final String op;
  final Completer<Object?> completer = Completer<Object?>();
  final Stopwatch since = Stopwatch()..start();
}
