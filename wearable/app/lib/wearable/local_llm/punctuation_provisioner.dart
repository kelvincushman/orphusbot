// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// PunctuationProvisioner — installs the cheap always-on text fixer.
//
// zipformer-small-en emits its native output: no punctuation, no casing. A
// saved note reads `JEST LOOKIN SEE IF I NEEDER HAD A DIARIN`. Gemma (polish)
// can repair that, but Gemma is 2.6 GB and seconds per note, so it is the
// expensive pass that only runs when something says it is needed. This is the
// cheap one that runs on every note: 7 MB, ~25 ms per utterance, measured.
//
// Model: sherpa-onnx-online-punct-en-2024-08-06 — a CNN-BiLSTM over unigram
// BPE that restores BOTH punctuation and casing, which is exactly the pair of
// defects the recogniser leaves behind. English only, which is what we ship.
//
// Provenance and licence, verified 2026-09-11:
//
//   • Weights originate from github.com/frankyoujian/Edge-Punct-Casing —
//     Apache-2.0 (GitHub API `license.spdx_id`), mirrored at
//     huggingface.co/frankyoujian/Edge-Punct-Casing whose card declares
//     `license: apache-2.0`.
//   • k2-fsa/sherpa-onnx redistributes them as the release asset
//     `punctuation-models/sherpa-onnx-online-punct-en-2024-08-06.tar.bz2`
//     (SHA-256 9f5e5a72c7d2829635bd074fce92b6bbd5b78da8a52e7ad8ed1be933f366b99d,
//     matching that release's own checksum.txt). Its README names
//     Edge-Punct-Casing as the source.
//   • The two files pinned below were extracted from that official tarball and
//     hashed; they are byte-identical to the files in the HF repo pinned here.
//     So the digests in this file identify the official bytes regardless of
//     which host serves them.
//
// Why the HF mirror and not the release asset: the tarball is 30.7 MB because
// it also carries the fp32 model we never load, and unpacking it means holding
// the compressed blob and ~37 MB of output in memory on a phone. The two files
// we actually need are 7.3 MB served individually. The digests make the hosts
// interchangeable; only availability differs, and an unavailable download here
// degrades to pass-through, which is the designed failure mode anyway.
//
// Two caveats about that mirror, so nobody re-derives them: it is a personal
// account, not k2-fsa, and can vanish at any time (the pinned digests then
// fail the download and punctuation stays off — nothing wrong is ever loaded);
// and its model card declares `license: mit`, which is a mislabel. The bytes
// are the Apache-2.0 Edge-Punct-Casing weights above, digest for digest, and
// Apache-2.0 is the licence we rely on and cite. If the mirror goes away,
// repoint at the k2-fsa release asset and keep the same digests.
//
// The CT-Transformer punctuation model sherpa also publishes was rejected: it
// is Chinese-English mixed, does no casing, and neither its HF repo nor the
// release declares a licence for the weights.

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

class PunctuationProvisioner {
  PunctuationProvisioner._();
  static final PunctuationProvisioner instance = PunctuationProvisioner._();

  // Pinned to an immutable commit rather than `main`, so the model cannot
  // change under a shipped app.
  static const String repo = 'brady-pplx/sherpa-onnx-online-punct-en-2024-08-06';
  static const String revision = '29a49a07620ef067e6fa40580da620c11db07b83';

  // int8 rather than the fp32 sibling: 7.3 MB against 29.7 MB for a model whose
  // job is inserting commas. The fp32 weights are not downloaded at all.
  static const _model = _Artifact('model.int8.onnx', 7490500,
      '9d611f445fe4a46186080fe161be6059d87d72eb88d3a8cb00c1a06e83a6067e');
  static const _bpeVocab = _Artifact('bpe.vocab', 149430,
      'e118b7ad88c54db562517df49e1cffd4836d166c34fb190fd311d7f34eb238f5');

  static const List<_Artifact> _all = [_model, _bpeVocab];

  /// The digests a download is verified against, in artifact order.
  ///
  /// Exposed so a test can assert these are the bytes whose licence and
  /// behaviour were actually checked, rather than whatever the host now serves.
  static List<String> get pinnedDigests =>
      _all.map((a) => a.sha256Hex).toList(growable: false);

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
    final dir = Directory('${support.path}/asr-punct');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dirPath = dir.path;
  }

  Future<String> modelPath() async => '${await _dir()}/${_model.name}';
  Future<String> bpeVocabPath() async => '${await _dir()}/${_bpeVocab.name}';

  /// True when both files are present at the right size.
  ///
  /// Size rather than digest, for the same reason StreamingProvisioner gives:
  /// this is consulted on the transcription path and hashing on every note
  /// would cost more than the model it is guarding. [download] verifies the
  /// digest once, at install, which is where a corrupt file actually enters.
  Future<bool> isInstalled() async {
    final dir = await _dir();
    for (final a in _all) {
      final f = File('$dir/${a.name}');
      if (!f.existsSync() || await f.length() != a.bytes) return false;
    }
    return true;
  }

  /// Download and verify both files, reporting 0-100 weighted by size.
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

  /// Delete the installed files. Transcription keeps working; notes simply stay
  /// as the recogniser wrote them.
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
