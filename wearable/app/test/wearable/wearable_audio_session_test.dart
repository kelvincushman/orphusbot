/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/wearable_audio_session.dart';

List<int> packet(int id, int chunk, List<int> payload) => [id & 0xff, (id >> 8) & 0xff, chunk, ...payload];

void main() {
  test('assembles out-of-order BLE chunks into ordered codec frames', () {
    final session = WearableAudioSession(recordingId: 'recording-a');

    expect(session.addPacket('recording-a', packet(11, 1, [3, 4])), isEmpty);
    expect(session.addPacket('recording-a', packet(10, 0, [1, 2])), isEmpty);
    final frames = session.addPacket('recording-a', packet(12, 0, [5]));

    expect(frames, hasLength(1));
    expect(frames.single.bytes, [1, 2, 3, 4]);
    expect(frames.single.sourcePackets, [
      packet(10, 0, [1, 2]),
      packet(11, 1, [3, 4]),
    ]);
  });

  test('stop can arrive before final audio chunks', () {
    final session = WearableAudioSession(recordingId: 'recording-b');

    session.addPacket('recording-b', packet(20, 0, [1]));
    expect(session.requestStop('recording-b'), isTrue);
    expect(session.stopRequested, isTrue);

    session.addPacket('recording-b', packet(21, 1, [2]));
    final completed = session.addPacket('recording-b', packet(22, 0, [3]));
    expect(completed.single.bytes, [1, 2]);

    final finalFrames = session.finish('recording-b');
    expect(finalFrames.single.bytes, [3]);
  });

  test('stale recording ids cannot add packets or stop the active session', () {
    final session = WearableAudioSession(recordingId: 'current');

    expect(session.addPacket('old', packet(1, 0, [9])), isEmpty);
    expect(session.requestStop('old'), isFalse);
    expect(session.finish('old'), isEmpty);
    expect(session.isClosed, isFalse);

    session.addPacket('current', packet(1, 0, [7]));
    expect(session.finish('current').single.bytes, [7]);
    expect(session.isClosed, isTrue);
  });

  test('packet ordering survives the uint16 id wrap', () {
    final session = WearableAudioSession(recordingId: 'wrap');

    session.addPacket('wrap', packet(0xffff, 0, [1]));
    session.addPacket('wrap', packet(0, 1, [2]));
    final completed = session.addPacket('wrap', packet(1, 0, [3]));

    expect(completed.single.bytes, [1, 2]);
    expect(session.finish('wrap').single.bytes, [3]);
  });

  test('duplicate replay after reconnect is ignored', () {
    final session = WearableAudioSession(recordingId: 'reconnect');
    final first = packet(100, 0, [1]);

    session.addPacket('reconnect', first);
    session.addPacket('reconnect', first);
    final completed = session.addPacket('reconnect', packet(101, 0, [2]));

    expect(completed.single.bytes, [1]);
    expect(session.finish('reconnect').single.bytes, [2]);
  });
}
