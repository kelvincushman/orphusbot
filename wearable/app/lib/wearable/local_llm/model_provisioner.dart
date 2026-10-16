// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// GemmaModelProvisioner — download / sideload / remove the on-device Gemma 4
// E2B .litertlm model that polishes transcript text. Mirrors the descriptor
// shape GoType uses on macOS so the integrity check is consistent across both.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

class GemmaModelProvisioner {
  GemmaModelProvisioner._();
  static final GemmaModelProvisioner instance = GemmaModelProvisioner._();

  // Descriptor for gemma-4-E2B-it.litertlm — the universal (CPU + GPU) build.
  //
  // This was E4B (3.66 GB), chosen back when Gemma did the transcription and
  // accuracy on audio was the point. Gemma no longer sees audio: it tidies text
  // that zipformer already produced, and docs/research/ON_DEVICE_STT.md
  // concluded "use E2B, not E4B, for the polish pass" for two documented
  // reasons that were recorded and then never applied here:
  //
  //  - E4B on an 8 GB Samsung is a documented OOM (flutter_gemma #351, the
  //    maintainer, on a Galaxy S24 — lmkd reaping processes and finally the
  //    foreground app). The S24 FE this ships on is that device.
  //  - E4B loading inside a foreground service gets the app killed ~60 s in
  //    (LiteRT-LM #1860): the multi-GB engine load blocks the
  //    startForeground() path and the AOSP watchdog wins. We now run a
  //    foreground service whenever the wearable is attached.
  //
  // A model that vanishes on restart and a process that lmkd takes mid-load
  // present identically to the wearer; this is the fix for the second, which
  // was very likely the first.
  //
  // Not the `-gpu` build (2.0 GB): it drops the CPU weights, and GemmaEngine
  // asks for CPU (see the backend note there). Not a vendor build: none exists
  // for Exynos.
  static const String repository = 'litert-community/gemma-4-E2B-it-litert-lm';
  static const String fileName = 'gemma-4-E2B-it.litertlm';
  // Pinned to an immutable commit SHA (not the mutable `main` ref) so a
  // repo/branch-pointer change can't silently swap the model we fetch. The
  // byte count and digest below were read from the HF API and then confirmed
  // against the resolve URL's x-linked-size / x-linked-etag at this revision.
  static const String modelRevision = 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1';
  static const String downloadUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/$modelRevision/gemma-4-E2B-it.litertlm';
  static const int byteCount = 2588147712;

  /// What the UI shows. Derived from [byteCount] so the label and the file
  /// cannot disagree — the other two provisioners drifted apart once.
  static const String sizeLabel = '~2.6 GB';
  static const String sha256Hex =
      '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c';

  bool get isInstalled => FlutterGemma.hasActiveModel();

  /// Download from Hugging Face and set active. [onProgress] reports 0–100.
  /// flutter_gemma streams to its managed location and retries transient
  /// errors; integrity of the network download is handled by the package.
  ///
  /// Guarded by a stall watchdog. `install()` has been observed sitting at 0%
  /// indefinitely without progressing, throwing, or returning — on a phone with
  /// 31 ms latency to huggingface.co and a URL that downloads fine elsewhere.
  /// A download that cannot report failure is worse than one that fails: the
  /// page shows "Downloading… 0%" forever and the wearer has nothing to act on.
  /// [stallTimeout] is measured from the last progress tick, not from the
  /// start, so a slow-but-moving download is never interrupted.
  Future<void> downloadFromNetwork({
    String? hfToken,
    void Function(int progress)? onProgress,
    Duration stallTimeout = const Duration(seconds: 90),
  }) async {
    var lastTick = DateTime.now();
    final builder = FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(downloadUrl, token: hfToken).withProgress((p) {
      lastTick = DateTime.now();
      onProgress?.call(p);
    });

    final stalled = Completer<void>();
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (stalled.isCompleted) return;
      final idle = DateTime.now().difference(lastTick);
      if (idle >= stallTimeout) {
        stalled.completeError(TimeoutException(
          'no download progress for ${idle.inSeconds}s — check the network, '
          'or sideload the .litertlm file instead',
        ));
      }
    });

    try {
      await Future.any(<Future<void>>[builder.install(), stalled.future]);
    } finally {
      watchdog.cancel();
    }
  }

  /// Install from a local .litertlm file (sideload). When [verify] is true the
  /// file must match the known E2B byte-count + SHA-256 before install — pass
  /// false to install a different build (e.g. the macOS Eloquent copy).
  Future<void> installFromFile(String path, {bool verify = true}) async {
    if (verify) await _verify(File(path));
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(path).install();
  }

  Future<void> remove() async {
    // ignore: deprecated_member_use
    await FlutterGemmaPlugin.instance.modelManager.deleteCurrentModel();
  }

  /// True when [path] is byte-for-byte the model this build pins.
  ///
  /// Lets the sideload flow skip its "unverified model" warning for a file that
  /// is provably the real thing — the common case, since the in-app download
  /// can stall and hand-fetching the pinned URL is the workaround.
  Future<bool> matchesPinnedBuild(String path) async {
    try {
      await _verify(File(path));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _verify(File file) async {
    final length = await file.length();
    if (length != byteCount) {
      throw StateError('model size mismatch: $length != $byteCount bytes');
    }
    final digest = await sha256.bind(file.openRead()).last;
    if (digest.toString() != sha256Hex) {
      throw StateError('model SHA-256 mismatch — file may be corrupt or wrong');
    }
  }
}
