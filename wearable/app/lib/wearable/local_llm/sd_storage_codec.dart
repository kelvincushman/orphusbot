// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Helpers for the Wearable/KelvinLee SD-card audio GATT protocol exposed by
// firmware/devkit/src/storage.c. The firmware stores offline audio as 440-byte
// pages containing repeated [frameLength][frameBytes] entries.

import 'dart:math' as math;
import 'dart:typed_data';

class SdStorageCommand {
  static const int read = 0;
  static const int delete = 1;
  static const int stop = 3;
  static const int heartbeat = 50;

  static Uint8List encode({required int command, required int fileNum, int offset = 0}) {
    return Uint8List.fromList(<int>[
      command & 0xff,
      fileNum & 0xff,
      (offset >> 24) & 0xff,
      (offset >> 16) & 0xff,
      (offset >> 8) & 0xff,
      offset & 0xff,
    ]);
  }
}

class SdStorageStatus {
  const SdStorageStatus({required this.totalBytes, required this.offsetBytes});

  final int totalBytes;
  final int offsetBytes;

  int get pendingBytes => math.max(0, totalBytes - offsetBytes);

  static SdStorageStatus? decode(List<int> bytes) {
    if (bytes.length < 8) return null;
    return SdStorageStatus(totalBytes: _uint32le(bytes, 0), offsetBytes: _uint32le(bytes, 4));
  }
}

class SdStoragePacket {
  const SdStoragePacket({required this.frames, required this.consumedBytes, this.code, this.valid = true});

  final List<Uint8List> frames;
  final int consumedBytes;
  final int? code;
  final bool valid;

  bool get isAck => code == 0;
  bool get isComplete => code == 4 || code == 100;
  bool get isDeleteAck => code == 200;
  bool get isError => !valid || (code != null && !isAck && !isComplete && !isDeleteAck);
}

class SdStorageCodec {
  static const int pageBytes = 440;
  static const int legacyPageBytes = 80;

  static SdStoragePacket decodePacket(List<int> bytes) {
    if (bytes.length == 1) {
      return SdStoragePacket(frames: const <Uint8List>[], consumedBytes: 0, code: bytes.first);
    }

    if (bytes.length == 83) {
      final amount = bytes[3];
      final end = 4 + amount;
      final frames = <Uint8List>[];
      if (amount > 0 && end <= bytes.length) {
        frames.add(Uint8List.fromList(bytes.sublist(4, end)));
      }
      return SdStoragePacket(frames: frames, consumedBytes: legacyPageBytes, valid: end <= bytes.length);
    }

    final frames = <Uint8List>[];
    var cursor = 0;
    while (cursor < bytes.length) {
      final amount = bytes[cursor];
      cursor += 1;
      if (amount == 0) continue;
      final end = cursor + amount;
      if (end > bytes.length) {
        return SdStoragePacket(frames: frames, consumedBytes: bytes.length, valid: false);
      }
      frames.add(Uint8List.fromList(bytes.sublist(cursor, end)));
      cursor = end;
    }

    return SdStoragePacket(frames: frames, consumedBytes: bytes.length);
  }
}

bool shouldDeleteSdBacklog({
  required bool completed,
  required bool packetsValid,
  required bool transcriptionsOk,
  required int processedFrames,
  required int emittedUtterances,
  required int postedTranscripts,
}) {
  if (!completed || !packetsValid || !transcriptionsOk || processedFrames <= 0) return false;
  if (postedTranscripts > 0) return true;
  return emittedUtterances == 0;
}

int _uint32le(List<int> bytes, int offset) {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) &
      0xffffffff;
}
