// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/opus_pcm_decoder.dart';

void main() {
  group('pcm16BytesToSamples', () {
    test('decodes little-endian PCM16 into signed samples', () {
      // 0x0001 = 1, 0xFFFF = -1, 0x0080.. use a known value: 0x00 0x10 = 0x1000 = 4096
      final bytes = Uint8List.fromList([0x01, 0x00, 0xFF, 0xFF, 0x00, 0x10]);
      final samples = pcm16BytesToSamples(bytes);
      expect(samples, [1, -1, 4096]);
    });

    test('drops a trailing odd byte instead of throwing', () {
      final bytes = Uint8List.fromList([0x01, 0x00, 0x7F]); // 3 bytes
      final samples = pcm16BytesToSamples(bytes);
      expect(samples, [1]);
    });

    test('empty input yields empty output', () {
      expect(pcm16BytesToSamples(Uint8List(0)), isEmpty);
    });
  });
}
