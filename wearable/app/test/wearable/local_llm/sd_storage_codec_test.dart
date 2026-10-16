// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/sd_storage_codec.dart';

void main() {
  group('SdStorageCommand', () {
    test('encodes firmware command bytes with a big-endian offset', () {
      final cmd = SdStorageCommand.encode(command: SdStorageCommand.read, fileNum: 1, offset: 0x01020304);
      expect(cmd, <int>[0, 1, 1, 2, 3, 4]);
    });
  });

  group('SdStorageStatus', () {
    test('decodes total bytes and saved offset as little-endian uint32s', () {
      final status = SdStorageStatus.decode(<int>[0x78, 0x56, 0x34, 0x12, 0x10, 0x00, 0x00, 0x00]);

      expect(status, isNotNull);
      expect(status!.totalBytes, 0x12345678);
      expect(status.offsetBytes, 16);
      expect(status.pendingBytes, 0x12345668);
    });
  });

  group('SdStorageCodec', () {
    test('decodes packed 440-byte pages into raw audio frames', () {
      final page = Uint8List(SdStorageCodec.pageBytes);
      var cursor = 0;
      for (final frame in <List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5],
        <int>[6, 7, 8, 9],
      ]) {
        page[cursor++] = frame.length;
        page.setRange(cursor, cursor + frame.length, frame);
        cursor += frame.length;
      }

      final packet = SdStorageCodec.decodePacket(page);

      expect(packet.code, isNull);
      expect(packet.consumedBytes, SdStorageCodec.pageBytes);
      expect(packet.frames.map((f) => f.toList()), <List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5],
        <int>[6, 7, 8, 9],
      ]);
    });

    test('keeps frames that end exactly on the 440-byte boundary', () {
      final page = Uint8List(SdStorageCodec.pageBytes);
      var cursor = 0;
      for (var frameIndex = 0; frameIndex < 2; frameIndex++) {
        page[cursor++] = 219;
        for (var i = 0; i < 219; i++) {
          page[cursor++] = (frameIndex * 219 + i) & 0xff;
        }
      }

      final packet = SdStorageCodec.decodePacket(page);

      expect(packet.frames, hasLength(2));
      expect(packet.frames.every((frame) => frame.length == 219), isTrue);
      expect(packet.frames.first.first, 0);
      expect(packet.frames.last.last, 437 & 0xff);
    });

    test('decodes the legacy 83-byte storage packet format', () {
      final packetBytes = Uint8List(83);
      packetBytes[3] = 3;
      packetBytes.setRange(4, 7, <int>[9, 8, 7]);

      final packet = SdStorageCodec.decodePacket(packetBytes);

      expect(packet.consumedBytes, SdStorageCodec.legacyPageBytes);
      expect(packet.frames.single, <int>[9, 8, 7]);
    });

    test('classifies one-byte result packets', () {
      expect(SdStorageCodec.decodePacket(<int>[0]).isAck, isTrue);
      expect(SdStorageCodec.decodePacket(<int>[100]).isComplete, isTrue);
      expect(SdStorageCodec.decodePacket(<int>[4]).isComplete, isTrue);
      expect(SdStorageCodec.decodePacket(<int>[3]).isError, isTrue);
      expect(SdStorageCodec.decodePacket(<int>[200]).isDeleteAck, isTrue);
    });

    test('marks truncated packed frames invalid', () {
      final packet = SdStorageCodec.decodePacket(<int>[10, 1, 2, 3]);

      expect(packet.valid, isFalse);
      expect(packet.isError, isTrue);
      expect(packet.frames, isEmpty);
    });
  });

  group('shouldDeleteSdBacklog', () {
    test('allows delete after valid read with at least one posted transcript', () {
      expect(
        shouldDeleteSdBacklog(
          completed: true,
          packetsValid: true,
          transcriptionsOk: true,
          processedFrames: 10,
          emittedUtterances: 1,
          postedTranscripts: 1,
        ),
        isTrue,
      );
    });

    test('allows explicit silence-only discard when no utterances were emitted', () {
      expect(
        shouldDeleteSdBacklog(
          completed: true,
          packetsValid: true,
          transcriptionsOk: true,
          processedFrames: 10,
          emittedUtterances: 0,
          postedTranscripts: 0,
        ),
        isTrue,
      );
    });

    test('retains backlog when STT emitted no accepted transcript for an utterance', () {
      expect(
        shouldDeleteSdBacklog(
          completed: true,
          packetsValid: true,
          transcriptionsOk: true,
          processedFrames: 10,
          emittedUtterances: 1,
          postedTranscripts: 0,
        ),
        isFalse,
      );
    });

    test('retains backlog on invalid packets or failed transcriptions', () {
      expect(
        shouldDeleteSdBacklog(
          completed: true,
          packetsValid: false,
          transcriptionsOk: true,
          processedFrames: 10,
          emittedUtterances: 1,
          postedTranscripts: 1,
        ),
        isFalse,
      );
      expect(
        shouldDeleteSdBacklog(
          completed: true,
          packetsValid: true,
          transcriptionsOk: false,
          processedFrames: 10,
          emittedUtterances: 1,
          postedTranscripts: 1,
        ),
        isFalse,
      );
    });
  });
}
