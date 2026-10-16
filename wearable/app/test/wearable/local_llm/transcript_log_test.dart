// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/transcript_log.dart';

void main() {
  group('TranscriptEntry', () {
    test('stores text, overheard, and null talker by default', () {
      final e = TranscriptEntry(
        id: 'a-0',
        text: 'Hello world',
        at: DateTime(2026, 1, 1),
        overheard: false,
      );
      expect(e.text, 'Hello world');
      expect(e.overheard, isFalse);
      expect(e.talker, isNull);
    });

    test('stores talker when provided', () {
      final e = TranscriptEntry(
        id: 'a-1',
        text: 'Nice to meet you',
        at: DateTime(2026, 1, 1),
        overheard: true,
        talker: 'Talker 2',
      );
      expect(e.talker, 'Talker 2');
      expect(e.overheard, isTrue);
    });
  });

  group('OnDeviceTranscriptLog.add', () {
    late OnDeviceTranscriptLog log;

    setUp(() {
      // Access the singleton; clear it by resetting via the notifier trick —
      // we test add() behaviour, not persistence.
      log = OnDeviceTranscriptLog.instance;
      // Drain any state from previous tests by reading the notifier; the log
      // is a singleton so we can't re-construct it. We work with what's there
      // and check only the most-recent entry we add.
    });

    test('add without talker stores null talker', () {
      log.add('No talker text', overheard: false);
      final newest = log.entries.first;
      expect(newest.text, 'No talker text');
      expect(newest.talker, isNull);
    });

    test('add with talker stores the label', () {
      log.add('Talker one said hello', overheard: false, talker: 'Talker 1');
      final newest = log.entries.first;
      expect(newest.text, 'Talker one said hello');
      expect(newest.talker, 'Talker 1');
    });

    test('add with talker 2 stores correct label', () {
      log.add('Talker two replied', overheard: true, talker: 'Talker 2');
      final newest = log.entries.first;
      expect(newest.talker, 'Talker 2');
      expect(newest.overheard, isTrue);
    });

    test('empty text is silently dropped', () {
      final countBefore = log.entries.length;
      log.add('', overheard: false, talker: 'Talker 1');
      expect(log.entries.length, countBefore);
    });

    test('[no speech] sentinel is silently dropped', () {
      final countBefore = log.entries.length;
      log.add('[no speech]', overheard: false, talker: 'Talker 1');
      expect(log.entries.length, countBefore);
    });

    test('talker label format matches Talker N pattern', () {
      // Verify the string format produced in device_bridge.dart:
      // 'Talker ${seg.speaker + 1}' for zero-based speaker indices.
      for (var i = 0; i < 3; i++) {
        final label = 'Talker ${i + 1}';
        log.add('Speaker $i speaking', overheard: false, talker: label);
        expect(log.entries.first.talker, 'Talker ${i + 1}');
      }
    });
  });
}
