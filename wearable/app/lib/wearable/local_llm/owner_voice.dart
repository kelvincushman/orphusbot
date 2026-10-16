// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// OwnerVoice — on-device owner voice enrollment and recognition.
//
// The embedding half of speaker identity: it turns audio into WeSpeaker
// ResNet34-LM embeddings. Storage and matching
// live in SpeakerRegistry, where the owner is simply the profile with
// isOwner: true — so "You" and "Sarah" are decided by the same rules, and the
// owner can hold several enrolment vectors instead of one averaged centroid.
//
// The public surface is unchanged (isEnrolled, ownerName, isOwner,
// enrollFromSamples, clear) so the enrolment and voice pages keep compiling.
// An owner enrolled under the old SharedPreferences keys is migrated into the
// registry on first load, once, and the old keys are removed.
//
// The extractor itself lives in the SpeakerWorker isolate (see
// sherpa_speaker_backend.dart): every embedding pass is synchronous native
// FFI, and the multi-scale path costs up to 7 of them per call. Run on the UI
// isolate they blocked it for seconds and, together with diarization, drew an
// ANR that killed the app. This file only awaits the worker — the UI isolate
// pays milliseconds per call, however long the audio.
//
// Embeddings are multi-scale: see extractRobustEmbedding. A whole-clip pass is
// blended with shorter windows so one transient cannot contaminate the whole
// statistics pool. The schedule and the weighting are pure functions in
// speaker_embedding_math.dart, shared with the worker.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'diarization_provisioner.dart';
import 'speaker_embedding_math.dart';
import 'speaker_registry.dart';
import 'speaker_worker.dart';

/// Singleton that manages the owner's enrolled voice embedding.
class OwnerVoice {
  OwnerVoice._();
  static final OwnerVoice instance = OwnerVoice._();

  // Legacy SharedPreferences keys — read once for migration, then removed.
  static const String _keyEnrolled = 'wearable.owner.enrolled';
  static const String _keyEmbedding = 'wearable.owner.embedding';
  static const String _keyName = 'wearable.owner.name';

  // Set once the "models not installed" case has been logged, so a session
  // without models does not log it on every segment.
  bool _missingModelsLogged = false;

  // ---------------------------------------------------------------------------
  // Enrollment state
  // ---------------------------------------------------------------------------

  SpeakerRegistry get _registry => SpeakerRegistry.instance;

  /// True when an owner profile exists and was made by the current model.
  bool get isEnrolled => _registry.owner?.isCompatible ?? false;

  /// The display name for the owner (default "You").
  String get ownerName {
    final n = _registry.owner?.name.trim();
    return (n == null || n.isEmpty) ? 'You' : n;
  }

  /// Load the registry and, once, migrate a legacy SharedPreferences owner.
  Future<void> _loadIfNeeded() async {
    if (_loaded) return;
    _loaded = true;
    await _registry.ensureLoaded();
    await _migrateLegacy();
  }

  bool _loaded = false;

  /// Move an owner stored under the old keys into the registry. Runs once;
  /// the keys are removed afterwards so a later clear() cannot resurrect a
  /// vector the user deleted. A dimension mismatch means the vector came from
  /// a different model and is dropped — "please re-enrol", never a silent
  /// RangeError in a comparison loop.
  Future<void> _migrateLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    final enrolled = prefs.getBool(_keyEnrolled) ?? false;
    final b64 = prefs.getString(_keyEmbedding);
    if (!enrolled || b64 == null || b64.isEmpty) return;
    try {
      if (_registry.owner == null) {
        final bytes = base64Decode(b64);
        final emb = Float32List.view(Uint8List.fromList(bytes).buffer);
        if (emb.length == kSpeakerDim) {
          await _registry.enrol(
            name: prefs.getString(_keyName) ?? 'You',
            vectors: [emb],
            isOwner: true,
          );
          debugPrint('[OwnerVoice] migrated legacy owner enrolment into the registry');
        } else {
          debugPrint('[OwnerVoice] legacy owner vector has dim ${emb.length}, '
              'expected $kSpeakerDim — dropped; please re-enrol');
        }
      }
    } catch (e) {
      debugPrint('[OwnerVoice] legacy migration failed: $e');
    } finally {
      await prefs.remove(_keyEmbedding);
      await prefs.remove(_keyName);
      await prefs.remove(_keyEnrolled);
    }
  }

  /// Eagerly load enrolment state. Idempotent — safe to call multiple times.
  Future<void> loadEnrollmentState() => _loadIfNeeded();

  // ---------------------------------------------------------------------------
  // Embedding extraction (in the worker isolate)
  // ---------------------------------------------------------------------------

  /// False, with one log line per session, when the models are not installed.
  Future<bool> _modelsInstalled() async {
    final installed = await DiarizationProvisioner.instance.isInstalled();
    if (!installed && !_missingModelsLogged) {
      _missingModelsLogged = true;
      debugPrint('[OwnerVoice] diarization models not installed — no embeddings');
    }
    return installed;
  }

  /// Extract a speaker embedding for [samples16kMono] (Float32, 16 kHz, mono).
  /// Returns null if models are not installed or extraction fails.
  Future<Float32List?> extractEmbedding(Float32List samples16kMono) async {
    if (!await _modelsInstalled()) return null;
    try {
      return await SpeakerWorker.instance.embed(samples16kMono);
    } catch (e) {
      debugPrint('[OwnerVoice] extractEmbedding failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Multi-scale chunked embedding
  // ---------------------------------------------------------------------------

  /// A speaker embedding for [samples16kMono] that is steadier on short or
  /// noisy turns than a single whole-clip pass.
  ///
  /// The schedule is [robustEmbedding]: the whole clip plus up to
  /// [kRobustMaxChunksPerScale] windows at each of [kRobustChunkSeconds],
  /// duration-weighted — at most 7 forward passes. Every one of them runs in
  /// the worker isolate; the UI isolate awaits a single reply. Returns null
  /// only when the whole-clip pass fails -- if every window is refused, the
  /// whole-clip embedding is used alone.
  Future<Float32List?> extractRobustEmbedding(Float32List samples16kMono) async {
    if (!await _modelsInstalled()) return null;
    final sw = Stopwatch()..start();
    try {
      final out = await SpeakerWorker.instance.embedRobust(samples16kMono);
      final seconds = samples16kMono.length / kSpeakerSampleRate;
      debugPrint('[OwnerVoice] embedding over ${seconds.toStringAsFixed(1)}s: '
          'awaited worker ${sw.elapsedMilliseconds}ms');
      return out;
    } catch (e) {
      debugPrint('[OwnerVoice] extractRobustEmbedding failed: $e');
      return null;
    }
  }

  /// Up to [kRobustMaxChunksPerScale] evenly spaced windows of [scale]
  /// seconds. See [embeddingWindows].
  @visibleForTesting
  List<Float32List> windows(Float32List samples, double scale) =>
      embeddingWindows(samples, scale);

  // ---------------------------------------------------------------------------
  // Enrollment
  // ---------------------------------------------------------------------------

  /// Enroll the owner from one or more audio clips.
  ///
  /// Each clip in [clips] must be a Float32 16 kHz mono buffer.  An embedding
  /// is extracted per clip, then all embeddings are L2-normalised and averaged
  /// (mean of unit vectors) to produce a single representative embedding that
  /// is then L2-normalised again before storage.
  ///
  /// [name] defaults to "You" — the label shown in transcripts.
  Future<void> enrollFromSamples(
    List<Float32List> clips, {
    String name = 'You',
  }) async {
    await _loadIfNeeded();

    final embeddings = <Float32List>[];
    for (final clip in clips) {
      final emb = await extractRobustEmbedding(clip);
      if (emb != null && emb.isNotEmpty) {
        embeddings.add(emb); // already L2-normalised
      }
    }

    if (embeddings.isEmpty) {
      debugPrint('[OwnerVoice] enrollment: no valid embeddings extracted from clips');
      return;
    }

    // One vector per clip, kept separately. The registry scores by the max
    // over a profile's vectors, so three clips from three sessions stay three
    // distinct references rather than one averaged centroid that sounds like
    // none of them. (VoxBlink2: 1 -> 3 enrolment utterances moves open-set
    // identification from 88.1% to 96.3%; the value is in the variety.)
    await _registry.enrol(name: name, vectors: embeddings, isOwner: true);
    debugPrint('[OwnerVoice] enrolled as "$name" from ${embeddings.length} clip(s)');
  }

  /// Enrol the owner from an embedding already computed — the tap-to-name
  /// path, where the vector came from wearable audio the registry just
  /// scored. Same channel as every future match, which is the point.
  Future<void> enrollFromEmbedding(Float32List embedding, {String name = 'You'}) async {
    await _loadIfNeeded();
    await _registry.enrol(name: name, vectors: [embedding], isOwner: true);
    debugPrint('[OwnerVoice] enrolled as "$name" from a wearable cluster');
  }

  // ---------------------------------------------------------------------------
  // Recognition
  // ---------------------------------------------------------------------------

  /// Returns true if [segmentSamples16k] matches the enrolled owner above
  /// [threshold] (cosine similarity).  Returns false if not enrolled or if
  /// extraction fails (safe fallback — never throws).
  ///
  /// Typical threshold range: 0.55–0.70.  Default 0.65 (raised from 0.55 to
  /// cut false positives — e.g. a TV/other voice being tagged as the owner).
  Future<bool> isOwner(
    Float32List segmentSamples16k, {
    double threshold = 0.65,
  }) async {
    try {
      await _loadIfNeeded();
      final owner = _registry.owner;
      if (owner == null || !owner.isCompatible) return false;

      final emb = await extractRobustEmbedding(segmentSamples16k);
      if (emb == null || emb.isEmpty) return false;

      // Max over the owner's vectors — the registry's rule, applied here so
      // this legacy entry point and match() cannot disagree about the owner.
      var sim = -1.0;
      for (final v in owner.vectors) {
        if (v.length != emb.length) continue;
        final c = cosineSimilarity(emb, v);
        if (c > sim) sim = c;
      }
      final durS = segmentSamples16k.length / 16000.0;
      debugPrint('[OwnerVoice] cosine similarity=${sim.toStringAsFixed(3)} '
          'threshold=$threshold dur=${durS.toStringAsFixed(1)}s');
      return sim >= threshold;
    } catch (e) {
      debugPrint('[OwnerVoice] isOwner failed (fallback to Talker N): $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence: clear
  // ---------------------------------------------------------------------------

  /// Remove the owner profile and any legacy keys.
  Future<void> clear() async {
    await _loadIfNeeded();
    final owner = _registry.owner;
    if (owner != null) await _registry.remove(owner.id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyEmbedding);
    await prefs.remove(_keyName);
    await prefs.remove(_keyEnrolled);
    debugPrint('[OwnerVoice] enrollment cleared');
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (unit-testable without native libs)
  // ---------------------------------------------------------------------------

  /// Cosine similarity in [-1, 1].  Returns 0 if either vector is zero.
  double cosineSimilarity(Float32List a, Float32List b) {
    assert(a.length == b.length, 'embedding dimension mismatch: ${a.length} vs ${b.length}');
    double dot = 0, normA = 0, normB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    normA = math.sqrt(normA);
    normB = math.sqrt(normB);
    if (normA == 0 || normB == 0) return 0;
    return dot / (normA * normB);
  }

  /// Duration-weighted mean of unit vectors, re-normalised. See
  /// [weightedMeanEmbedding].
  @visibleForTesting
  Float32List weightedMean(List<Float32List> parts, List<double> weights) =>
      weightedMeanEmbedding(parts, weights);

  // ---------------------------------------------------------------------------
  // Test-only: inject a stored embedding without going through sherpa.
  // ---------------------------------------------------------------------------

  /// Inject a pre-computed embedding directly (for unit tests that cannot
  /// load native sherpa libraries). Writes through the registry, so the test
  /// exercises the same storage the app uses.
  Future<void> injectEmbeddingForTest(Float32List embedding, {String name = 'You'}) async {
    _loaded = true; // skip legacy migration in tests
    await _registry.ensureLoaded();
    await _registry.enrol(name: name, vectors: [embedding], isOwner: true);
  }

  /// Forget the in-memory "loaded" flag so a test can re-run migration.
  @visibleForTesting
  void resetForTest() => _loaded = false;
}
