// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The stall watchdog. flutter_gemma's install() was observed sitting at 0%
// forever — no progress, no throw, no return — leaving the page showing
// "Downloading… 0%" with nothing for the user to act on.
//
// The provisioner itself cannot be unit-tested (it calls into the plugin), so
// this pins the watchdog's logic on the same shape: a future that may never
// complete, raced against a stall timer that resets on each progress tick.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Mirror of the race in GemmaModelProvisioner.downloadFromNetwork.
Future<void> guarded(
  Future<void> work, {
  required Stream<int> progress,
  required Duration stallTimeout,
}) async {
  var lastTick = DateTime.now();
  final sub = progress.listen((_) => lastTick = DateTime.now());
  final stalled = Completer<void>();
  final watchdog = Timer.periodic(const Duration(milliseconds: 20), (_) {
    if (stalled.isCompleted) return;
    if (DateTime.now().difference(lastTick) >= stallTimeout) {
      stalled.completeError(TimeoutException('no download progress'));
    }
  });
  try {
    await Future.any(<Future<void>>[work, stalled.future]);
  } finally {
    watchdog.cancel();
    await sub.cancel();
  }
}

void main() {
  test('a download that never progresses fails instead of hanging', () async {
    final never = Completer<void>(); // install() that never returns
    await expectLater(
      guarded(never.future,
          progress: const Stream<int>.empty(),
          stallTimeout: const Duration(milliseconds: 120)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a slow but moving download is not interrupted', () async {
    final work = Completer<void>();
    // Ticks every 50 ms — well inside the 200 ms stall window — for 400 ms,
    // which is longer than the timeout would allow if it did not reset.
    final ticks = Stream<int>.periodic(const Duration(milliseconds: 50), (i) => i).take(8);
    Timer(const Duration(milliseconds: 400), work.complete);
    await guarded(work.future, progress: ticks, stallTimeout: const Duration(milliseconds: 200));
    expect(work.isCompleted, isTrue);
  });

  test('a download that finishes promptly is unaffected', () async {
    await guarded(Future<void>.value(),
        progress: const Stream<int>.empty(),
        stallTimeout: const Duration(milliseconds: 500));
  });
}
