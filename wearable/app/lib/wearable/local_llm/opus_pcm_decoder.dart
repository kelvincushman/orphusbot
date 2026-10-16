// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// LocalOpusDecoder — decodes the wearable's Opus frames to PCM16 on-device so
// they can be transcribed locally (Gemma 4) instead of streamed to the server.
//
// The KelvinLee firmware emits either Opus (codec id 20/21) or linear16 PCM (codec
// id 1). For Opus we decode here with the same opus_dart primitive WavBytesUtil
// already uses (lib/utils/audio/wav_bytes.dart:92). For linear16 the bytes are
// already PCM16 — see [pcm16BytesToSamples].
//
// REQUIRES initOpus(...) to have run. main.dart:151 already calls it once for
// mobile, so do NOT re-init here.

import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';

class LocalOpusDecoder {
  LocalOpusDecoder({int sampleRate = 16000})
      : _decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: 1);

  final SimpleOpusDecoder _decoder;

  /// Decode a single Opus frame (BLE header already stripped) into PCM16 samples.
  Int16List decode(Uint8List opusFrame) => _decoder.decode(input: opusFrame);

  void dispose() => _decoder.destroy();
}

/// Reinterpret a little-endian PCM16 byte buffer (linear16 wearable frames, or
/// the phone mic's `record` output) as Int16 samples. Drops a trailing odd byte
/// defensively rather than throwing.
Int16List pcm16BytesToSamples(Uint8List bytes) {
  final usableLength = bytes.length - (bytes.length % 2);
  final view = ByteData.sublistView(bytes, 0, usableLength);
  final samples = Int16List(usableLength ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little);
  }
  return samples;
}
