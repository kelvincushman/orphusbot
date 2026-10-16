// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for CaptureState, focused on the nothingHeard result.
//
// This state exists because the silent path was a real defect: a capture that
// transcribed to nothing sent the banner from "Transcribing..." straight to
// idle with no row appended, which a user reads as the app losing their
// recording. The linger timer is the part worth testing — it must expire on
// its own, and it must never outlive the start of the next capture.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/capture_state.dart';

void main() {
  final s = CaptureState.instance;

  setUp(() => s.idle());
  tearDown(() => s.idle());

  test('starts idle and is not active', () {
    expect(s.status, CaptureStatus.idle);
    expect(s.isActive, isFalse);
  });

  test('recording and transcribing are active states', () {
    s.recording();
    expect(s.isRecording, isTrue);
    expect(s.isActive, isTrue);
    s.transcribing();
    expect(s.isTranscribing, isTrue);
    expect(s.isRecording, isFalse);
  });

  test('nothingHeard is active so the banner stays on screen', () {
    s.transcribing();
    s.nothingHeard();
    expect(s.isNothingHeard, isTrue);
    expect(s.isActive, isTrue, reason: 'an inactive state renders no banner');
  });

  testWidgets('nothingHeard returns to idle on its own', (tester) async {
    s.transcribing();
    s.nothingHeard();
    expect(s.isNothingHeard, isTrue);

    await tester.pump(CaptureState.nothingHeardLinger - const Duration(milliseconds: 1));
    expect(s.isNothingHeard, isTrue, reason: 'expired early');

    await tester.pump(const Duration(milliseconds: 2));
    expect(s.status, CaptureStatus.idle);
  });

  testWidgets('a new capture supersedes a lingering nothingHeard', (tester) async {
    s.nothingHeard();
    expect(s.isNothingHeard, isTrue);

    // The wearer presses again before the banner has timed out.
    s.recording();
    expect(s.isRecording, isTrue);

    // The old timer must not fire and drag us back to idle mid-recording.
    await tester.pump(CaptureState.nothingHeardLinger + const Duration(seconds: 1));
    expect(s.isRecording, isTrue,
        reason: 'a stale linger timer clobbered the new capture');
  });

  testWidgets('back-to-back nothingHeard restarts the linger', (tester) async {
    s.nothingHeard();
    await tester.pump(CaptureState.nothingHeardLinger - const Duration(milliseconds: 100));
    // Second empty capture while the first banner is still up.
    s.transcribing();
    s.nothingHeard();
    await tester.pump(CaptureState.nothingHeardLinger - const Duration(milliseconds: 100));
    expect(s.isNothingHeard, isTrue, reason: 'linger did not restart');
    await tester.pump(const Duration(milliseconds: 200));
    expect(s.status, CaptureStatus.idle);
  });

  test('notifies listeners on each distinct transition', () {
    var n = 0;
    void listener() => n++;
    s.addListener(listener);
    addTearDown(() => s.removeListener(listener));

    s.recording();
    s.transcribing();
    s.transcribing(); // same state — no notification
    s.idle();
    expect(n, 3);
  });

  testWidgets('idle() cancels a pending linger', (tester) async {
    s.nothingHeard();
    s.idle();
    expect(s.status, CaptureStatus.idle);
    var notified = false;
    void listener() => notified = true;
    s.addListener(listener);
    addTearDown(() => s.removeListener(listener));
    await tester.pump(CaptureState.nothingHeardLinger + const Duration(seconds: 1));
    expect(notified, isFalse, reason: 'a cancelled timer still fired');
  });
}
