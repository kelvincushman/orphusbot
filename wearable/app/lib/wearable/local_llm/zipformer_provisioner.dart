// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// ZipformerProvisioner — installs the on-device ASR model.
//
// Zipformer-small-en (transducer: encoder + decoder + joiner, int8) replaces
// Moonshine Tiny. The reason is measured, not assumed: on a channel simulation
// built from THIS firmware's own Opus settings plus reverb and 10 dB babble,
// Moonshine came last of twelve models at 29.5% WER on sub-9-second clips
// while zipformer-small scored 12.1% — and did it in less memory (358 MB peak
// vs 478 MB), less disk (28 MB vs 52 MB) and less time (RTF 0.019 vs 0.025).
// See docs/research/ASR_CANDIDATES.md.
//
// The lesson worth keeping: clean-speech WER does not predict far-field
// robustness. Moonshine is excellent on clean audio (5.15%) and collapses with
// reverb; zipformer-small goes 2.42% -> 11.19% and degrades gracefully.
// Parameter count does not predict it either — a 670 MB parakeet scored worse
// on this channel than this 28 MB model.
//
// Runs through sherpa_onnx, which is ALREADY a pinned dependency with its
// arm64 native libraries in the APK for diarization. Adding this model costs
// only the model bytes — no new dependency, no new native surface.

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

class ZipformerProvisioner {
  ZipformerProvisioner._();
  static final ZipformerProvisioner instance = ZipformerProvisioner._();

  // Pinned to an immutable commit, not `main`, so a repo change cannot swap the
  // model under us. Weights are Apache-2.0 (verified against the HF model API,
  // not just the model card) and are fetched at runtime rather than vendored,
  // so this MIT repo redistributes none of them.
  static const String repo = 'csukuangfj/sherpa-onnx-zipformer-small-en-2023-06-26';
  static const String revision = 'e8add5377a6cb7b629b5a0e08d6afe7a73442814';

  // int8 — the variant the benchmark measured. The fp32 encoder is 91 MB for
  // no measured accuracy gain on this channel.
  static const _encoder = _Artifact('encoder-epoch-99-avg-1.int8.onnx', 26015366,
      '3a6ac78a31cc2c60ca8c1e2e2f43c878fbbcaf051ada4900e0a42ef8ba53d375');
  static const _decoder = _Artifact('decoder-epoch-99-avg-1.int8.onnx', 1307236,
      'f462ab9189ba6f9b2658774e6bf3d651913de54a3833655dc5e093e2f5e4c2b6');
  static const _joiner = _Artifact('joiner-epoch-99-avg-1.int8.onnx', 259335,
      '6b183b6ec656e4d3ca6b86d0aeca992dac14df80aae6b416d7c068d0ff2bd4d7');
  // tokens.txt is not stored in LFS, so the API exposes no digest for it. Size
  // is still checked; a truncated token table would fail loudly at load.
  static const _tokens = _Artifact('tokens.txt', 5048, '');

  // Silero VAD v5 (MIT). Not an optional extra — it is what stops the ASR
  // being asked to transcribe silence, which is where hallucinated names come
  // from. Shipped from the sherpa-onnx release rather than the HF repo above,
  // so it has its own URL.
  static const _vad = _Artifact('silero_vad_v5.onnx', 2313101,
      '6b99cbfd39246b6706f98ec13c7c50c6b299181f2474fa05cbc8046acc274396');
  static const String _vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad_v5.onnx';

  static const List<_Artifact> _all = [_encoder, _decoder, _joiner, _tokens, _vad];

  /// Combined on-disk size, for UI copy.
  static const String sizeLabel = '~30 MB';

  String? _dirPath;

  Future<String> _dir() async {
    final cached = _dirPath;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/asr');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dirPath = dir.path;
  }

  Future<String> encoderPath() async => '${await _dir()}/${_encoder.name}';
  Future<String> decoderPath() async => '${await _dir()}/${_decoder.name}';
  Future<String> joinerPath() async => '${await _dir()}/${_joiner.name}';
  Future<String> tokensPath() async => '${await _dir()}/${_tokens.name}';
  Future<String> vadPath() async => '${await _dir()}/${_vad.name}';

  /// True when all five files are present and the right size.
  ///
  /// Size rather than digest: this is called on every capture-path setup and
  /// hashing 28 MB each time would be absurd. [download] verifies the digest
  /// once, at install, which is where a corrupt file actually enters.
  Future<bool> isInstalled() async {
    final dir = await _dir();
    for (final a in _all) {
      final f = File('$dir/${a.name}');
      if (!f.existsSync() || await f.length() != a.bytes) return false;
    }
    return true;
  }

  /// Download and verify all five files. [onProgress] reports 0-100 across the
  /// set, weighted by size so the 26 MB encoder dominates the bar honestly.
  Future<void> download({void Function(int percent)? onProgress}) async {
    final dir = await _dir();
    final total = _all.fold<int>(0, (n, a) => n + a.bytes);
    var done = 0;

    for (final a in _all) {
      final url = identical(a, _vad)
          ? _vadUrl
          : 'https://huggingface.co/$repo/resolve/$revision/${a.name}';
      final bytes = await _downloadBytes(url, onProgress: (pct) {
        onProgress?.call((((done + a.bytes * pct / 100) / total) * 100).round());
      });

      if (bytes.length != a.bytes) {
        throw StateError('${a.name}: got ${bytes.length} bytes, expected ${a.bytes}');
      }
      if (a.sha256Hex.isNotEmpty) {
        final digest = sha256.convert(bytes).toString();
        if (digest != a.sha256Hex) {
          throw StateError('${a.name}: SHA-256 mismatch — corrupt or wrong file');
        }
      }
      // Write only after verifying, so a failed download never leaves a
      // half-file that isInstalled() would later have to reason about.
      await File('$dir/${a.name}').writeAsBytes(bytes, flush: true);
      done += a.bytes;
      onProgress?.call(((done / total) * 100).round());
    }
  }

  Future<void> remove() async {
    final dir = await _dir();
    for (final a in _all) {
      final f = File('$dir/${a.name}');
      if (f.existsSync()) f.deleteSync();
    }
  }

  Future<List<int>> _downloadBytes(String url, {void Function(int pct)? onProgress}) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await req.send();
    if (resp.statusCode != 200) {
      throw StateError('Download failed ($url): HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength ?? 0;
    var received = 0;
    final buf = <int>[];
    await for (final chunk in resp.stream) {
      buf.addAll(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(((received / total) * 100).clamp(0, 100).round());
    }
    return buf;
  }
}
