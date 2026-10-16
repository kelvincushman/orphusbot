// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Minimal WAV (RIFF) writer for the on-device transcriber. flutter_gemma's
// audio Message API wants a self-describing container, not bare PCM, so we
// wrap the 16-bit mono samples the capture path produces in a 44-byte header.
//
// Standard RIFF/WAVE layout — see the format spec, not borrowed code.

import 'dart:typed_data';

/// Wraps signed 16-bit mono PCM [samples] in a WAV container at [sampleRate].
///
/// Sample values are written little-endian and truncated to 16 bits, matching
/// what the Opus decoder and phone mic both hand us.
Uint8List pcm16ToWav(List<int> samples, int sampleRate) {
  const int channels = 1;
  const int bitsPerSample = 16;
  final int dataBytes = samples.length * 2;
  final int byteRate = sampleRate * channels * bitsPerSample ~/ 8;

  final out = ByteData(44 + dataBytes);
  // RIFF chunk descriptor
  _ascii(out, 0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little); // chunk size after this field
  _ascii(out, 8, 'WAVE');
  // "fmt " sub-chunk
  _ascii(out, 12, 'fmt ');
  out.setUint32(16, 16, Endian.little); // PCM fmt chunk is 16 bytes
  out.setUint16(20, 1, Endian.little); // 1 = uncompressed PCM
  out.setUint16(22, channels, Endian.little);
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, byteRate, Endian.little);
  out.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little); // block align
  out.setUint16(34, bitsPerSample, Endian.little);
  // "data" sub-chunk
  _ascii(out, 36, 'data');
  out.setUint32(40, dataBytes, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    out.setInt16(44 + i * 2, samples[i].toSigned(16), Endian.little);
  }
  return out.buffer.asUint8List();
}

void _ascii(ByteData d, int offset, String tag) {
  for (var i = 0; i < tag.length; i++) {
    d.setUint8(offset + i, tag.codeUnitAt(i));
  }
}
