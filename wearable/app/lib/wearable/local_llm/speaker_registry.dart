// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// SpeakerRegistry — who is speaking, remembered across clips.
//
// Everything the embedding model already computes was being thrown away:
// device_bridge extracted a speaker embedding per segment, compared it to one
// stored owner vector, kept a boolean, and dropped the vector. This file keeps
// the vectors, under names, on disk, and answers "which known person is this?"
// with a refusal built in.
//
// Design, from docs/research/SPEAKER_IDENTITY.md:
//
//  - Score a profile by the MAX over its stored vectors (Apple's rule), not by
//    a single centroid — a person sounds different tired, on the phone, across
//    a room, and one centroid averages those into nobody.
//  - Search ONLY named profiles. Open-set false alarms scale badly with gallery
//    size (VoxWatch: FAR 2.4% -> 16.1% going 50 -> 500 speakers), and an
//    all-day wearable meets hundreds of one-off strangers. Hence [maxNamed].
//  - Three refusals before a name is applied: a similarity floor, a runner-up
//    margin (two similar family voices otherwise produce a confident wrong
//    argmax — Omi measured owner-vs-family as close as 0.43), and an evidence
//    gate on pooled duration (2 s clips: 17% EER; 5 s: 10%, Omi's bench).
//    Unknown is a correct answer, not a failure.
//  - Enrolled vectors are immutable and never evicted, so a bad automatic
//    observation can always be rolled back. Observed vectors are FIFO-capped.
//    Auto-adapting templates are a documented poisoning target (Biggio et al.;
//    Lovisotto et al. "Biometric Backdoors"); the enrolled floor is the defence.
//  - Every profile is stamped with the model id and dimension. Swapping the
//    embedding model silently breaks every stored voice; the stamp turns that
//    into "please re-enrol" instead of a RangeError swallowed by a catch.
//
// Storage is app-private and never leaves the device: a small JSON index plus
// one packed Float32 file per profile under Application Support. Not
// SharedPreferences — Android reads the whole XML into memory and rewrites it
// on every commit, and these are biometric vectors, not a flag.
//
// This file is pure Dart. Embeddings come in from OwnerVoice.extractEmbedding;
// nothing here touches sherpa, which keeps every rule below unit-testable.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// Identity of the embedding model whose vectors a profile holds.
///
/// Changes if and only if the model that produced the vectors changes. A
/// profile carrying a different id is unusable, not comparable.
const String kSpeakerModelId = 'wespeaker_resnet34_LM';
const int kSpeakerDim = 256;

/// One known person.
class SpeakerProfile {
  const SpeakerProfile({
    required this.id,
    required this.name,
    required this.isOwner,
    required this.modelId,
    required this.dim,
    required this.enrolled,
    required this.observed,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final bool isOwner;
  final String modelId;
  final int dim;

  /// Explicit enrolments. Immutable and never evicted — the rollback floor.
  final List<Float32List> enrolled;

  /// Confident automatic matches, FIFO-capped at [SpeakerRegistry.maxObserved].
  final List<Float32List> observed;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// True when this profile's vectors were produced by the current model.
  bool get isCompatible => modelId == kSpeakerModelId && dim == kSpeakerDim;

  Iterable<Float32List> get vectors => enrolled.followedBy(observed);

  SpeakerProfile copyWith({
    String? name,
    List<Float32List>? enrolled,
    List<Float32List>? observed,
    DateTime? updatedAt,
  }) =>
      SpeakerProfile(
        id: id,
        name: name ?? this.name,
        isOwner: isOwner,
        modelId: modelId,
        dim: dim,
        enrolled: enrolled ?? this.enrolled,
        observed: observed ?? this.observed,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// Result of [SpeakerRegistry.match].
///
/// [profile] is null for Unknown. [score] is the best similarity seen even
/// when refused, and [reason] says which refusal fired — so the UI and the
/// logs can tell "nobody close" from "two people too close" from "too short".
class SpeakerMatch {
  const SpeakerMatch._(this.profile, this.score, this.margin, this.reason);

  const SpeakerMatch.unknown(MatchReason reason, {double score = 0, double margin = 0})
      : this._(null, score, margin, reason);

  const SpeakerMatch.named(SpeakerProfile profile, double score, double margin)
      : this._(profile, score, margin, MatchReason.matched);

  final SpeakerProfile? profile;
  final double score;
  final double margin;
  final MatchReason reason;

  bool get isKnown => profile != null;
}

enum MatchReason {
  matched,
  tooShort,
  noNamedProfiles,
  belowFloor,
  ambiguous,
}

class SpeakerRegistry {
  SpeakerRegistry._();
  static final SpeakerRegistry instance = SpeakerRegistry._();

  // --- Tuning. Starting points from the research; recalibrate from the
  // --- similarity/duration log once a day of real wear has been collected.

  /// Minimum cosine similarity to consider a name at all. 0.65 is the value
  /// owner_voice.dart raised to after a TV voice was tagged as the owner.
  static const double floor = 0.65;

  /// Best must beat runner-up by this much, or the answer is Unknown.
  static const double margin = 0.07;

  /// Pooled speech (seconds) below which no identity is attempted.
  static const double minEvidenceS = 3.0;

  /// Cap on NAMED profiles — the search set. The research is unambiguous that
  /// identification degrades with gallery size; a personal registry is family
  /// and a few colleagues, not an address book.
  static const int maxNamed = 10;

  /// Cap on automatically observed vectors per profile.
  static const int maxObserved = 20;

  List<SpeakerProfile> _profiles = const [];
  bool _loaded = false;
  Future<void>? _loading;
  Directory? _dir;

  /// Every profile, owner first.
  List<SpeakerProfile> get profiles => List.unmodifiable(_profiles);

  SpeakerProfile? get owner {
    for (final p in _profiles) {
      if (p.isOwner) return p;
    }
    return null;
  }

  /// Profiles eligible for identification: named, compatible with the model.
  Iterable<SpeakerProfile> get _searchable =>
      _profiles.where((p) => p.isCompatible && p.name.trim().isNotEmpty);

  /// Named people other than the owner — the set [maxNamed] caps. The owner is
  /// searched like anyone else but there is exactly one, so counting them here
  /// would silently shrink the cap to nine once "Me" was enrolled first.
  int get namedCount => _searchable.where((p) => !p.isOwner).length;
  bool get canAddNamed => namedCount < maxNamed;

  // ---------------------------------------------------------------------------
  // Loading / persistence
  // ---------------------------------------------------------------------------

  /// Override the storage directory in tests so nothing touches the real one.
  @visibleForTesting
  void useDirectoryForTest(Directory dir) {
    _dir = dir;
    _profiles = const [];
    _loaded = false;
    _loading = null;
  }

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/speakers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final dir = await _directory();
      final index = File('${dir.path}/profiles.json');
      if (!index.existsSync()) {
        _profiles = const [];
        return;
      }
      final raw = jsonDecode(await index.readAsString());
      final list = (raw is Map && raw['profiles'] is List) ? raw['profiles'] as List : const [];
      final loaded = <SpeakerProfile>[];
      for (final item in list) {
        final p = _fromJson(item as Map<String, dynamic>, dir);
        if (p != null) loaded.add(p);
      }
      loaded.sort((a, b) => a.isOwner == b.isOwner ? 0 : (a.isOwner ? -1 : 1));
      _profiles = loaded;
    } catch (e) {
      // A corrupt index must not take the app down or, worse, quietly drop
      // every profile on the next save. Log, start empty, keep the file.
      debugPrint('[SpeakerRegistry] load failed: $e');
      _profiles = const [];
    } finally {
      _loaded = true;
      _loading = null;
    }
  }

  SpeakerProfile? _fromJson(Map<String, dynamic> j, Directory dir) {
    final id = j['id'] as String?;
    if (id == null) return null;
    final dim = (j['dim'] as num?)?.toInt() ?? kSpeakerDim;
    final enrolledN = (j['enrolled'] as num?)?.toInt() ?? 0;
    final observedN = (j['observed'] as num?)?.toInt() ?? 0;
    final vecs = _readVectors(File('${dir.path}/$id.f32'), dim, enrolledN + observedN);
    return SpeakerProfile(
      id: id,
      name: (j['name'] as String?) ?? '',
      isOwner: (j['isOwner'] as bool?) ?? false,
      modelId: (j['modelId'] as String?) ?? '',
      dim: dim,
      enrolled: vecs.take(enrolledN).toList(),
      observed: vecs.skip(enrolledN).take(observedN).toList(),
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  List<Float32List> _readVectors(File f, int dim, int count) {
    if (!f.existsSync() || count == 0) return const [];
    final bytes = f.readAsBytesSync();
    final all = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    final out = <Float32List>[];
    for (var i = 0; i < count && (i + 1) * dim <= all.length; i++) {
      out.add(Float32List.fromList(all.sublist(i * dim, (i + 1) * dim)));
    }
    return out;
  }

  Future<void> _save() async {
    final dir = await _directory();
    for (final p in _profiles) {
      final packed = Float32List(p.dim * (p.enrolled.length + p.observed.length));
      var k = 0;
      for (final v in p.vectors) {
        packed.setRange(k, k + p.dim, v);
        k += p.dim;
      }
      await File('${dir.path}/${p.id}.f32')
          .writeAsBytes(packed.buffer.asUint8List(), flush: true);
    }
    final index = {
      'version': 1,
      'profiles': [
        for (final p in _profiles)
          {
            'id': p.id,
            'name': p.name,
            'isOwner': p.isOwner,
            'modelId': p.modelId,
            'dim': p.dim,
            'enrolled': p.enrolled.length,
            'observed': p.observed.length,
            'createdAt': p.createdAt.toIso8601String(),
            'updatedAt': p.updatedAt.toIso8601String(),
          },
      ],
    };
    // Write-then-rename so a crash mid-write leaves the old index intact.
    final tmp = File('${dir.path}/profiles.json.tmp');
    await tmp.writeAsString(jsonEncode(index), flush: true);
    await tmp.rename('${dir.path}/profiles.json');
  }

  // ---------------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------------

  static String _newId() {
    final r = math.Random.secure();
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final n = List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return '$t$n';
  }

  /// Create a named profile from explicit enrolment vectors.
  ///
  /// Throws [StateError] at the named cap. The owner does not count toward
  /// it and is exempt from it: there is exactly one.
  Future<SpeakerProfile> enrol({
    required String name,
    required List<Float32List> vectors,
    bool isOwner = false,
  }) async {
    await ensureLoaded();
    if (vectors.isEmpty) throw ArgumentError('enrol: no vectors');
    for (final v in vectors) {
      if (v.length != kSpeakerDim) {
        throw ArgumentError('enrol: dim ${v.length} != $kSpeakerDim');
      }
    }
    if (isOwner) {
      final existing = owner;
      if (existing != null) {
        return _replace(existing.copyWith(
          name: name,
          enrolled: [...existing.enrolled, ...vectors.map(l2Normalize)],
          updatedAt: DateTime.now(),
        ));
      }
    } else if (!canAddNamed) {
      throw StateError('speaker registry is full ($maxNamed named people)');
    }
    final now = DateTime.now();
    final p = SpeakerProfile(
      id: _newId(),
      name: name,
      isOwner: isOwner,
      modelId: kSpeakerModelId,
      dim: kSpeakerDim,
      enrolled: vectors.map(l2Normalize).toList(),
      observed: const [],
      createdAt: now,
      updatedAt: now,
    );
    _profiles = [if (isOwner) p, ..._profiles, if (!isOwner) p];
    await _save();
    return p;
  }

  /// Add an explicit enrolment vector to an existing profile.
  Future<void> addEnrolled(String id, Float32List vector) async {
    await ensureLoaded();
    final p = _byId(id);
    if (p == null) return;
    await _replace(p.copyWith(
      enrolled: [...p.enrolled, l2Normalize(vector)],
      updatedAt: DateTime.now(),
    ));
  }

  /// Record a confident automatic match. Only call after [match] returned this
  /// profile — never for a forced or low-confidence assignment. FIFO at
  /// [maxObserved]; enrolled vectors are untouched.
  Future<void> observe(String id, Float32List vector) async {
    await ensureLoaded();
    final p = _byId(id);
    if (p == null) return;
    final next = [...p.observed, l2Normalize(vector)];
    while (next.length > maxObserved) {
      next.removeAt(0);
    }
    await _replace(p.copyWith(observed: next, updatedAt: DateTime.now()));
  }

  Future<void> rename(String id, String name) async {
    await ensureLoaded();
    final p = _byId(id);
    if (p == null) return;
    await _replace(p.copyWith(name: name, updatedAt: DateTime.now()));
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    if (_byId(id) == null) return;
    _profiles = _profiles.where((p) => p.id != id).toList();
    final dir = await _directory();
    final f = File('${dir.path}/$id.f32');
    if (f.existsSync()) await f.delete();
    await _save();
  }

  /// Delete every profile and vector. The privacy escape hatch.
  Future<void> clearAll() async {
    await ensureLoaded();
    final dir = await _directory();
    for (final p in _profiles) {
      final f = File('${dir.path}/${p.id}.f32');
      if (f.existsSync()) await f.delete();
    }
    _profiles = const [];
    final index = File('${dir.path}/profiles.json');
    if (index.existsSync()) await index.delete();
  }

  SpeakerProfile? _byId(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<SpeakerProfile> _replace(SpeakerProfile updated) async {
    _profiles = [for (final p in _profiles) p.id == updated.id ? updated : p];
    await _save();
    return updated;
  }

  // ---------------------------------------------------------------------------
  // Identification
  // ---------------------------------------------------------------------------

  /// Which named person, if any, does [embedding] belong to?
  ///
  /// [durationS] is the pooled speech duration the embedding was computed
  /// over. Below [minEvidenceS] the answer is Unknown regardless of score:
  /// short clips are where every speaker model is least reliable, and an
  /// unnamed segment is a better outcome than a wrong name.
  SpeakerMatch match(Float32List embedding, {required double durationS}) {
    if (durationS < minEvidenceS) return const SpeakerMatch.unknown(MatchReason.tooShort);
    final candidates = _searchable.toList();
    if (candidates.isEmpty) return const SpeakerMatch.unknown(MatchReason.noNamedProfiles);

    final e = l2Normalize(embedding);
    SpeakerProfile? best;
    var bestScore = -1.0;
    var second = -1.0;
    for (final p in candidates) {
      var s = -1.0;
      for (final v in p.vectors) {
        if (v.length != e.length) continue; // defensive: never mix dims
        final c = cosineSimilarity(e, v);
        if (c > s) s = c;
      }
      if (s > bestScore) {
        second = bestScore;
        bestScore = s;
        best = p;
      } else if (s > second) {
        second = s;
      }
    }
    final gap = second < 0 ? bestScore + 1 : bestScore - second;
    if (best == null || bestScore < floor) {
      return SpeakerMatch.unknown(MatchReason.belowFloor, score: bestScore, margin: gap);
    }
    if (gap < margin) {
      return SpeakerMatch.unknown(MatchReason.ambiguous, score: bestScore, margin: gap);
    }
    return SpeakerMatch.named(best, bestScore, gap);
  }

  // ---------------------------------------------------------------------------
  // Pure helpers — identical to owner_voice.dart's, kept here so this file has
  // no dependency on the sherpa-backed one.
  // ---------------------------------------------------------------------------

  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) return 0;
    double dot = 0, na = 0, nb = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  static Float32List l2Normalize(Float32List v) {
    double n = 0;
    for (final x in v) {
      n += x * x;
    }
    n = math.sqrt(n);
    if (n == 0) return Float32List.fromList(v);
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / n;
    }
    return out;
  }
}
