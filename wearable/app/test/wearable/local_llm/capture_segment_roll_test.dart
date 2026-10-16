// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Segment-and-continue. At the capture cap the bridge closes the window, hands
// the segment to transcription, and reopens in the same synchronous turn
// (WearableDeviceBridge._rollCaptureSegment). The claim that matters is that
// nothing is lost across that boundary — before this, hitting the cap stopped
// the capture and everything said afterwards was binned with no cue.
//
// The roll itself needs a radio; UtteranceBuffer is the half that decides
// whether audio survives it, so that is what is pinned here.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/audio_buffer.dart';

/// A chunk of constant-amplitude samples — content is irrelevant to windowed
/// segmentation, only the count is.
Int16List _chunk(int samples, {int value = 5000}) =>
    Int16List.fromList(List<int>.filled(samples, value));

void main() {
  test('a rolled segment is emitted and the audio after it is kept', () {
    final emitted = <Int16List>[];
    // maxSeconds well above what this test feeds, so the only boundary in play
    // is the roll itself and not UtteranceBuffer's own 30 s slicing.
    final buf = UtteranceBuffer(onUtterance: emitted.add, maxSeconds: 300);

    buf.openWindow();
    buf.addWindowed(_chunk(16000)); // 1 s before the cap

    // The roll: close (emits) then reopen, with nothing in between — exactly
    // what _rollCaptureSegment does on one turn of the event loop.
    buf.closeWindow();
    buf.openWindow();

    expect(emitted, hasLength(1));
    expect(emitted.first.length, 16000);
    expect(buf.isWindowOpen, isTrue, reason: 'still recording after the cap');

    buf.addWindowed(_chunk(8000)); // 0.5 s said after the cap
    buf.closeWindow();

    expect(emitted, hasLength(2));
    expect(emitted[1].length, 8000, reason: 'audio after the cap must not be lost');
  });

  test('a roll does not drop the pre-roll into the new segment twice', () {
    // openWindow() seeds from the pre-roll ring, which is only filled while the
    // window is CLOSED. Rolling reopens immediately, so the new segment starts
    // empty rather than replaying the tail of the one just filed.
    final emitted = <Int16List>[];
    final buf = UtteranceBuffer(onUtterance: emitted.add, maxSeconds: 300);

    buf.addWindowed(_chunk(16000)); // ambient, fills the pre-roll ring
    buf.openWindow();
    buf.addWindowed(_chunk(16000));
    buf.closeWindow();
    buf.openWindow();

    expect(buf.bufferedSamples, 0, reason: 'no duplicated pre-roll after a roll');
    buf.addWindowed(_chunk(4000));
    buf.closeWindow();
    expect(emitted[1].length, 4000);
  });

  test('the buffer still slices its own cap inside one segment', () {
    // Belt and braces: the bridge caps at 120 s, UtteranceBuffer at maxSeconds.
    // The inner cap keeps emitting and keeps the remainder.
    final emitted = <Int16List>[];
    final buf = UtteranceBuffer(onUtterance: emitted.add, maxSeconds: 1);

    buf.openWindow();
    buf.addWindowed(_chunk(16000 + 4000));
    expect(emitted, hasLength(1));
    expect(emitted.first.length, 16000);
    expect(buf.bufferedSamples, 4000, reason: 'the overflow stays buffered');

    buf.closeWindow();
    expect(emitted, hasLength(2));
    expect(emitted[1].length, 4000);
  });
}
