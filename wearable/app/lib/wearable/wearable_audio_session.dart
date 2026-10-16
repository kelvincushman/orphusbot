// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// One complete codec frame reconstructed from one or more BLE notifications.
class WearableAudioFrame {
  const WearableAudioFrame({required this.bytes, required this.sourcePackets});

  final Uint8List bytes;

  /// Original packets, including the three-byte firmware header. Keeping these
  /// lets callers mark exactly the packets that were successfully delivered.
  final List<List<int>> sourcePackets;
}

class _WearablePacket {
  const _WearablePacket({required this.packetId, required this.chunkIndex, required this.payload, required this.raw});

  final int packetId;
  final int chunkIndex;
  final List<int> payload;
  final List<int> raw;
}

class _FrameBuilder {
  _FrameBuilder(_WearablePacket packet) : bytes = List<int>.from(packet.payload), packets = [packet.raw];

  final List<int> bytes;
  final List<List<int>> packets;
  int nextChunkIndex = 1;

  WearableAudioFrame build() =>
      WearableAudioFrame(bytes: Uint8List.fromList(bytes), sourcePackets: List<List<int>>.unmodifiable(packets));
}

/// Reassembles the KelvinLee/Wearable BLE audio protocol for one app-side recording.
///
/// Firmware notifications are `[u16 packet id, u8 chunk index, payload...]`.
/// Packet ids order notifications and wrap at 65535; chunk index zero starts a
/// codec frame. A stop signal deliberately does not close the session, because
/// Android can deliver the button/stop characteristic before the final audio
/// notifications. The owner closes it after its drain window expires.
class WearableAudioSession {
  WearableAudioSession({required this.recordingId});

  factory WearableAudioSession.create() => WearableAudioSession(recordingId: const Uuid().v4());

  static const int _packetIdMask = 0xffff;
  static const int _maxQueuedPackets = 32;

  final String recordingId;
  final Map<int, _WearablePacket> _queued = <int, _WearablePacket>{};

  int? _nextPacketId;
  _FrameBuilder? _frame;
  bool _stopRequested = false;
  bool _closed = false;

  bool get stopRequested => _stopRequested;
  bool get isClosed => _closed;

  /// Marks stop/final without discarding late packets already in flight.
  bool requestStop(String candidateRecordingId) {
    if (!_accepts(candidateRecordingId)) return false;
    _stopRequested = true;
    return true;
  }

  /// Adds a BLE notification and returns any newly completed codec frames.
  /// Notifications from an old recording are rejected.
  List<WearableAudioFrame> addPacket(String candidateRecordingId, List<int> value) {
    if (!_accepts(candidateRecordingId) || value.length <= 3) return const [];

    final packet = _WearablePacket(
      packetId: value[0] | (value[1] << 8),
      chunkIndex: value[2],
      payload: List<int>.from(value.sublist(3)),
      raw: List<int>.from(value),
    );

    final expected = _nextPacketId;
    if (expected != null && _distance(expected, packet.packetId) >= 0x8000) {
      // This id is behind the receive cursor, normally lastValueStream replay
      // after Android reconnect. Do not let it linger until the uint16 wrap.
      return const [];
    }

    // lastValueStream can replay its most recent value after a reconnect.
    // Keeping the first copy makes that replay harmless.
    _queued.putIfAbsent(packet.packetId, () => packet);

    if (_nextPacketId == null && packet.chunkIndex == 0) {
      _nextPacketId = packet.packetId;
    }

    final completed = <WearableAudioFrame>[];
    _drain(completed);
    _recoverAtFrameBoundary(completed, force: false);
    return completed;
  }

  /// Closes this recording and flushes the last complete-or-best-effort frame.
  /// A mismatched id is stale and cannot close the active recording.
  List<WearableAudioFrame> finish(String candidateRecordingId) {
    if (!_accepts(candidateRecordingId)) return const [];

    final completed = <WearableAudioFrame>[];
    _drain(completed);
    while (_recoverAtFrameBoundary(completed, force: true)) {
      _drain(completed);
    }
    final frame = _frame;
    if (frame != null && frame.bytes.isNotEmpty) completed.add(frame.build());

    _frame = null;
    _queued.clear();
    _closed = true;
    return completed;
  }

  bool _accepts(String candidateRecordingId) => !_closed && candidateRecordingId == recordingId;

  void _drain(List<WearableAudioFrame> completed) {
    var expected = _nextPacketId;
    while (expected != null) {
      final packet = _queued.remove(expected);
      if (packet == null) break;
      _consume(packet, completed);
      expected = (expected + 1) & _packetIdMask;
      _nextPacketId = expected;
    }
  }

  void _consume(_WearablePacket packet, List<WearableAudioFrame> completed) {
    if (packet.chunkIndex == 0) {
      final previous = _frame;
      if (previous != null && previous.bytes.isNotEmpty) completed.add(previous.build());
      _frame = _FrameBuilder(packet);
      return;
    }

    final frame = _frame;
    if (frame == null || packet.chunkIndex != frame.nextChunkIndex) {
      // The frame is incomplete/corrupt. Wait for the next index-zero packet;
      // sending partial Opus data is worse than dropping one frame.
      _frame = null;
      return;
    }

    frame.bytes.addAll(packet.payload);
    frame.packets.add(packet.raw);
    frame.nextChunkIndex++;
  }

  bool _recoverAtFrameBoundary(List<WearableAudioFrame> completed, {required bool force}) {
    final expected = _nextPacketId;
    if (expected == null || _queued.containsKey(expected)) return false;

    final starts = _queued.values.where((packet) => packet.chunkIndex == 0).toList();
    if (starts.isEmpty) return false;
    if (!force && starts.length < 2 && _queued.length < _maxQueuedPackets) return false;

    starts.sort((a, b) => _distance(expected, a.packetId).compareTo(_distance(expected, b.packetId)));
    final nextStart = starts.first.packetId;
    final skippedDistance = _distance(expected, nextStart);
    if (skippedDistance == 0) return false;

    // A packet gap means the in-progress frame cannot be trusted. Drop queued
    // continuations before the next clean frame boundary and resume there.
    _frame = null;
    _queued.removeWhere((id, _) {
      final distance = _distance(expected, id);
      return distance < skippedDistance;
    });
    _nextPacketId = nextStart;
    _drain(completed);
    return true;
  }

  int _distance(int from, int to) => (to - from) & _packetIdMask;
}
