// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// DiarizationProvisioner — downloads and manages the two ONNX model files
// needed by the sherpa-onnx offline speaker-diarization pipeline:
//
//   • Segmentation: pyannote/speaker-segmentation-3.0 → model.onnx (~6.6 MB)
//     Release tag: speaker-segmentation-models
//   • Embedding:   wespeaker ResNet34-LM → wespeaker_en_voxceleb_resnet34_LM.onnx (~25.3 MB)
//     Release tag: speaker-recongition-models  (sic — the tag on k2-fsa/sherpa-onnx)
//
// Models are stored under getApplicationSupportDirectory()/diarization/ — the
// same directory family used by flutter_gemma, which is durable across app
// upgrades and never evicted by the OS (unlike the cache dir).
//
// Extraction: the segmentation model is distributed as a .tar.bz2 archive.
// The `archive` package (^3.6.1) ships both BZip2Decoder and TarDecoder so
// we decode entirely in Dart without a native subprocess.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class DiarizationProvisioner {
  DiarizationProvisioner._();
  static final DiarizationProvisioner instance = DiarizationProvisioner._();

  // ---------------------------------------------------------------------------
  // Pinned release URLs — k2-fsa/sherpa-onnx GitHub release assets.
  // ---------------------------------------------------------------------------

  static const String _segTarUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-segmentation-models/'
      'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2';

  static const String _embUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-recongition-models/'
      'wespeaker_en_voxceleb_resnet34_LM.onnx';

  // ---------------------------------------------------------------------------
  // Resolved paths (populated lazily by _dir()).
  // ---------------------------------------------------------------------------

  /// Absolute path to the pyannote segmentation model.
  String get segmentationModelPath => '${_cachedDirPath!}/segmentation/model.onnx';

  /// Absolute path to the wespeaker embedding model.
  String get embeddingModelPath => '${_cachedDirPath!}/wespeaker_en_voxceleb_resnet34_LM.onnx';

  String? _cachedDirPath;

  Future<String> _dirPath() async {
    if (_cachedDirPath != null) return _cachedDirPath!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/diarization');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cachedDirPath = dir.path;
    return dir.path;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// True when both model files are present and non-empty on disk.
  Future<bool> isInstalled() async {
    await _dirPath();
    final seg = File(segmentationModelPath);
    final emb = File(embeddingModelPath);
    return seg.existsSync() && seg.lengthSync() > 0 &&
           emb.existsSync() && emb.lengthSync() > 0;
  }

  /// Download both models. [onProgress] is called with 0–100 (combined).
  /// Extraction of the .tar.bz2 happens entirely in Dart (archive package).
  Future<void> download({void Function(int pct)? onProgress}) async {
    final dir = await _dirPath();

    // Download segmentation archive (~6.6 MB), extract model.onnx → 30% of
    // the combined progress budget (it's much smaller than the embedding).
    onProgress?.call(0);
    final segBytes = await _downloadBytes(
      _segTarUrl,
      onProgress: (p) => onProgress?.call((p * 0.3).round()),
    );
    await _extractSegmentationModel(Uint8List.fromList(segBytes), dir);

    // Download embedding model (~25.3 MB) → remaining 30–100% of progress.
    final embBytes = await _downloadBytes(
      _embUrl,
      onProgress: (p) => onProgress?.call(30 + (p * 0.7).round()),
    );
    final embFile = File(embeddingModelPath);
    embFile.parent.createSync(recursive: true);
    await embFile.writeAsBytes(embBytes, flush: true);
    _verifyNonEmpty(embFile, 'wespeaker embedding');

    onProgress?.call(100);
  }

  /// Remove all downloaded model files.
  Future<void> remove() async {
    await _dirPath();
    final segDir = Directory('${_cachedDirPath!}/segmentation');
    if (segDir.existsSync()) segDir.deleteSync(recursive: true);
    final emb = File(embeddingModelPath);
    if (emb.existsSync()) emb.deleteSync();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Stream-download [url] to memory and report 0–100 progress via [onProgress].
  Future<List<int>> _downloadBytes(
    String url, {
    void Function(int pct)? onProgress,
  }) async {
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
      if (total > 0) {
        onProgress?.call(((received / total) * 100).clamp(0, 100).round());
      }
    }
    return buf;
  }

  /// Decompress a .tar.bz2 byte blob and write the pyannote model.onnx.
  /// Uses archive's BZip2Decoder + TarDecoder — pure Dart, no subprocess.
  Future<void> _extractSegmentationModel(Uint8List tarBz2Bytes, String baseDir) async {
    // Step 1: bzip2-decompress to raw tar bytes.
    final tarBytes = BZip2Decoder().decodeBytes(tarBz2Bytes);

    // Step 2: decode the tar archive.
    final archive = TarDecoder().decodeBytes(tarBytes);

    // Step 3: find any file named model.onnx inside the archive.
    ArchiveFile? modelFile;
    for (final entry in archive) {
      if (entry.isFile && entry.name.endsWith('model.onnx')) {
        modelFile = entry;
        break;
      }
    }
    if (modelFile == null) {
      throw StateError(
          'model.onnx not found inside segmentation archive. '
          'Archive entries: ${archive.map((e) => e.name).toList()}');
    }

    // Step 4: write to diarization/segmentation/model.onnx.
    final outFile = File(segmentationModelPath);
    outFile.parent.createSync(recursive: true);
    await outFile.writeAsBytes(modelFile.content as List<int>, flush: true);
    _verifyNonEmpty(outFile, 'pyannote segmentation model');
  }

  void _verifyNonEmpty(File f, String label) {
    if (!f.existsSync() || f.lengthSync() == 0) {
      throw StateError('$label: file is empty or missing after download (${f.path})');
    }
  }
}
