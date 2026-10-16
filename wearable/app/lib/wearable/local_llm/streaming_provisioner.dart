// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// StreamingProvisioner — installs the on-device model that drives LIVE text.
//
// This sits alongside ZipformerProvisioner rather than replacing it, because
// the two do different jobs and the measurements say to keep both. On the
// channel built from this firmware's own Opus settings plus reverb and babble:
//
//     model                          clean    wearable   RTF
//     zipformer-small-en (offline)   2.42%     11.19%    0.092
//     zipformer-en streaming         3.62%     16.26%    0.094
//     kroko-en streaming             8.53%     15.90%    0.310
//     zipformer-en-20M streaming    22.46%     40.18%    0.276
//
// Two things follow. Streaming costs about five points of WER — roughly 45%
// more errors — so it drives the live preview only; the offline model
// re-decodes the finished utterance and that is what gets saved. And among
// streaming models this one wins: kroko is 0.36pp better, which is noise, while
// being 3.3x slower, which is not. The 20M model is the cheap option that was
// nearly adopted on size alone before it was measured at 40% WER.
//
// Same family and date as the offline checkpoint (2023-06-26), so the live text
// and the saved text come from siblings rather than strangers.
//
// See docs/research/ASR_CANDIDATES.md.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// One downloadable artifact, pinned by size and digest.
class _Artifact {
  const _Artifact(this.name, this.bytes, this.sha256Hex);
  final String name;
  final int bytes;
  final String sha256Hex;
}

class StreamingProvisioner {
  StreamingProvisioner._();
  static final StreamingProvisioner instance = StreamingProvisioner._();

  // Pinned to an immutable commit rather than `main`. Weights are Apache-2.0
  // and fetched at runtime, not vendored, so this MIT repo redistributes none
  // of them.
  static const String repo =
      'csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26';
  static const String revision = '672fbf1b30579d6585301139bb363f42a0ad4a24';

  // chunk-16-left-128: the wider left-context build. The left-64 variant is
  // byte-for-byte the same size, so there is nothing to save by taking less
  // context.
  static const _encoder = _Artifact(
      'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx', 71083163,
      '563fde436d16cf7607cf408cd6b30909819d03162652ef389c2450ced3f45ac1');
  static const _decoder = _Artifact(
      'decoder-epoch-99-avg-1-chunk-16-left-128.onnx', 2092621,
      '7bf787f90b194b307e5a4ad6a34fadb4e748304c35f78a8d66358a05b13ee6ef');
  static const _joiner = _Artifact(
      'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx', 259335,
      'd944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297');
  static const _tokens = _Artifact('tokens.txt', 5048,
      '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb');

  static const List<_Artifact> _all = [_encoder, _decoder, _joiner, _tokens];

  /// Total download, for UI copy. Kept next to the artifacts so it cannot drift.
  static String get sizeLabel {
    final mb = _all.fold<int>(0, (n, a) => n + a.bytes) / (1024 * 1024);
    return '~${mb.round()} MB';
  }

  String? _dirPath;

  Future<String> _dir() async {
    final cached = _dirPath;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/asr-streaming');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dirPath = dir.path;
  }

  Future<String> encoderPath() async => '${await _dir()}/${_encoder.name}';
  Future<String> decoderPath() async => '${await _dir()}/${_decoder.name}';
  Future<String> joinerPath() async => '${await _dir()}/${_joiner.name}';
  Future<String> tokensPath() async => '${await _dir()}/${_tokens.name}';

  /// True when all four files are present at the right size.
  ///
  /// Size rather than digest: this runs on every capture-path setup and hashing
  /// 71 MB each time would be absurd. [download] verifies the digest once, at
  /// install, which is where a corrupt file actually enters.
  Future<bool> isInstalled() async {
    final dir = await _dir();
    for (final a in _all) {
      final f = File('$dir/${a.name}');
      if (!f.existsSync() || await f.length() != a.bytes) return false;
    }
    return true;
  }

  /// Download and verify all four files, reporting 0-100 weighted by size so
  /// the 71 MB encoder dominates the bar honestly.
  Future<void> download({void Function(int percent)? onProgress}) async {
    final dir = await _dir();
    final total = _all.fold<int>(0, (n, a) => n + a.bytes);
    var done = 0;

    for (final a in _all) {
      final url = 'https://huggingface.co/$repo/resolve/$revision/${a.name}';
      final bytes = await _downloadBytes(url, onProgress: (pct) {
        onProgress?.call((((done + a.bytes * pct / 100) / total) * 100).round());
      });

      if (bytes.length != a.bytes) {
        throw StateError('${a.name}: got ${bytes.length} bytes, expected ${a.bytes}');
      }
      final digest = sha256.convert(bytes).toString();
      if (digest != a.sha256Hex) {
        throw StateError('${a.name}: SHA-256 mismatch — corrupt or wrong file');
      }
      // Write only after verifying, so a failed download never leaves a
      // half-file for isInstalled() to reason about later.
      await File('$dir/${a.name}').writeAsBytes(bytes, flush: true);
      done += a.bytes;
      onProgress?.call(((done / total) * 100).round());
    }
  }

  /// Delete the installed files. Live preview falls back to off; the offline
  /// model is untouched, so transcription keeps working.
  Future<void> remove() async {
    final dir = await _dir();
    for (final a in _all) {
      final f = File('$dir/${a.name}');
      if (f.existsSync()) await f.delete();
    }
  }

  Future<List<int>> _downloadBytes(String url,
      {void Function(int percent)? onProgress}) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode} for $url');
      }
      final total = res.contentLength ?? 0;
      final out = <int>[];
      var seen = 0;
      var lastPct = -1;
      await for (final chunk in res.stream) {
        out.addAll(chunk);
        seen += chunk.length;
        if (total > 0) {
          final pct = ((seen / total) * 100).round();
          if (pct != lastPct) {
            lastPct = pct;
            onProgress?.call(pct);
          }
        }
      }
      return out;
    } finally {
      client.close();
    }
  }
}
