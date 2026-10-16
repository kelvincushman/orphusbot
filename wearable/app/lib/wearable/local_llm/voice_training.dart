// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// VoiceTraining — the logic behind owner enrolment, with no Flutter, no
// sherpa and no audio source in it.
//
// Two halves, because there are two ways to learn a voice:
//
//  1. [VoiceTrainingController] — the guided session. Three short prompts
//     instead of one long recording, because the enrolment gain is in the
//     VARIETY, not the seconds: VoxBlink2 moves open-set identification from
//     88.1% to 96.3% going from one enrolment utterance to three, and flattens
//     after that. Three slices of one continuous recording are not three
//     utterances — they share a breath, a distance and a room — which is why
//     this sequences three separate takes and gates each one.
//
//  2. [findOwnerProposal] — the moment that needs no session at all. A voice
//     that keeps appearing across separate wearable captures, always unnamed,
//     always itself, is almost certainly the person wearing the thing. Ask
//     once, enrol on one tap. The vectors it enrols were computed from
//     WEARABLE audio by the diarization path, so enrolment and every future
//     match share an acoustic channel by construction — the same reason
//     name_speaker_sheet.dart exists.
//
// Everything here is pure and synchronous apart from the two injected
// callbacks, so the rules can be tested without native libraries.

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import 'owner_voice.dart';
import 'speaker_registry.dart';
import 'transcript_log.dart';

// ---------------------------------------------------------------------------
// Guided session
// ---------------------------------------------------------------------------

/// One guided prompt. Sentences, not word lists: reading a list produces list
/// prosody, and the wearer will never speak to the device in list prosody.
const List<String> kTrainingPrompts = <String>[
  'Say hello, and tell me your name the way you would introduce yourself.',
  'Describe what you can see right now, in a sentence or two.',
  'Say what you want the day to have in it by the time it ends.',
];

/// Shortest clip worth embedding. Below [SpeakerRegistry.minEvidenceS] the
/// registry refuses to identify at all, so accepting a shorter enrolment would
/// store a vector that can never be reached by a match. One second of headroom
/// on top of that floor.
const double kTrainingMinClipSeconds = 4.0;

/// Why a submitted clip was or was not taken.
enum ClipVerdict {
  accepted,

  /// Under [VoiceTrainingController.minClipSeconds] of audio.
  tooShort,

  /// The embedder refused the clip — no speech, or too little of it.
  noVoice,

  /// It embedded, but it does not sound like the clips already accepted.
  /// Almost always someone else in the room answering the prompt; occasionally
  /// a clip that is mostly noise. Either way, a retake beats storing it.
  differentVoice,
}

/// What [VoiceTrainingController.submit] decided, and the evidence for it.
@immutable
class ClipOutcome {
  const ClipOutcome(this.verdict, {this.similarity});

  final ClipVerdict verdict;

  /// Best cosine against the clips already accepted, for the UI to show.
  /// Null on the first clip (nothing to compare to) and when no embedding
  /// was produced.
  final double? similarity;

  bool get accepted => verdict == ClipVerdict.accepted;
}

/// Sequences the guided enrolment takes and decides which ones count.
///
/// Audio is the caller's problem: this takes finished 16 kHz mono Float32
/// clips. That is deliberate — the clips must come from the wearable's mic,
/// which is a different acoustic channel from the phone's, and the controller
/// should not be the thing that knows which one it got.
class VoiceTrainingController {
  VoiceTrainingController({
    required this.extract,
    required this.enrolClips,
    this.prompts = kTrainingPrompts,
    this.minClipSeconds = kTrainingMinClipSeconds,
    this.similarityFloor = SpeakerRegistry.floor,
    this.sampleRate = 16000,
  }) : assert(prompts.isNotEmpty, 'a session with no prompts enrols nothing');

  /// Production wiring. Extraction is multi-scale on purpose — a single
  /// whole-clip pass lets one cough decide the vector.
  factory VoiceTrainingController.live() => VoiceTrainingController(
        extract: OwnerVoice.instance.extractRobustEmbedding,
        enrolClips: (clips) => OwnerVoice.instance.enrollFromSamples(clips),
      );

  /// Turns one clip into a speaker embedding, or null if it cannot.
  final Future<Float32List?> Function(Float32List clip) extract;

  /// Stores the finished session. One vector per clip, kept separately —
  /// see [OwnerVoice.enrollFromSamples].
  final Future<void> Function(List<Float32List> clips) enrolClips;

  final List<String> prompts;
  final double minClipSeconds;
  final double similarityFloor;
  final int sampleRate;

  final List<Float32List> _clips = <Float32List>[];
  final List<Float32List> _embeddings = <Float32List>[];
  final List<double> _similarities = <double>[];

  /// How many takes are in the bag.
  int get acceptedCount => _clips.length;

  /// Index of the prompt being asked, or [prompts].length when done.
  int get stepIndex => _clips.length;

  /// The prompt to show, or null when the session is complete.
  String? get currentPrompt => isComplete ? null : prompts[stepIndex];

  bool get isComplete => _clips.length >= prompts.length;

  /// Self-similarity of each accepted clip to the ones before it. The first
  /// entry is always 1.0 — a clip is identical to itself, and the UI needs a
  /// full ring rather than a gap.
  List<double> get similarities => List<double>.unmodifiable(_similarities);

  /// Offer one recorded take. Accepted clips advance the session; rejected
  /// ones leave it exactly where it was, so the same prompt is asked again.
  Future<ClipOutcome> submit(Float32List clip) async {
    if (isComplete) return const ClipOutcome(ClipVerdict.accepted);
    if (clip.length < minClipSeconds * sampleRate) {
      return const ClipOutcome(ClipVerdict.tooShort);
    }

    final embedding = await extract(clip);
    if (embedding == null || embedding.isEmpty) {
      return const ClipOutcome(ClipVerdict.noVoice);
    }

    double? best;
    if (_embeddings.isNotEmpty) {
      best = -1.0;
      for (final previous in _embeddings) {
        final c = SpeakerRegistry.cosineSimilarity(embedding, previous);
        if (c > best!) best = c;
      }
      if (best! < similarityFloor) {
        return ClipOutcome(ClipVerdict.differentVoice, similarity: best);
      }
    }

    _clips.add(clip);
    _embeddings.add(embedding);
    _similarities.add(best ?? 1.0);
    return ClipOutcome(ClipVerdict.accepted, similarity: best);
  }

  /// Throw away the whole session — the "start again" affordance.
  void reset() {
    _clips.clear();
    _embeddings.clear();
    _similarities.clear();
  }

  /// Store the session. Only valid once every prompt has a clip; a partial
  /// enrolment is the single-utterance case the three prompts exist to avoid.
  Future<void> enrol() {
    if (!isComplete) {
      throw StateError('enrol() before the session is complete '
          '(${_clips.length}/${prompts.length} clips)');
    }
    return enrolClips(List<Float32List>.unmodifiable(_clips));
  }
}

// ---------------------------------------------------------------------------
// Proposal-based enrolment
// ---------------------------------------------------------------------------

/// Distinct captures the same voice must appear in before it is worth asking
/// about. Three, matching the enrolment quantity — a proposal accepted is an
/// enrolment of three vectors from three separate recordings.
const int kProposalMinClips = 3;

/// Pooled speech each of those appearances must carry. Above the registry's
/// own 3 s evidence gate because this enrols without the wearer having
/// confirmed a single word of it: Omi's bench puts 2 s clips at 17% EER and
/// 5 s at 10%, and this is the side to be expensive on.
const double kProposalMinPooledSeconds = 5.0;

/// One diarized cluster in one capture: the unit a proposal is made of.
@immutable
class ProposalCluster {
  const ProposalCluster({
    required this.clipId,
    required this.clusterIndex,
    required this.embedding,
    required this.durationS,
    this.talker,
  });

  final String clipId;
  final int clusterIndex;
  final Float32List embedding;
  final double durationS;
  final String? talker;
}

/// A recurring unnamed voice, and the evidence for asking about it.
@immutable
class OwnerProposal {
  const OwnerProposal(this.clusters);

  /// The appearances, longest first. Every pair is at or above the similarity
  /// floor, and they span at least [kProposalMinClips] distinct captures.
  final List<ProposalCluster> clusters;

  int get clipCount => clusters.map((c) => c.clipId).toSet().length;

  double get totalSeconds =>
      clusters.fold<double>(0, (sum, c) => sum + c.durationS);
}

/// Find a voice that keeps coming back, unnamed, across separate captures.
///
/// Returns null when the evidence is thin — which is most of the time, and is
/// the correct answer. The caller must only offer this when no owner is
/// enrolled yet: once "You" exists, the owner's own turns carry a profileId
/// and are filtered out here, so a recurring UNNAMED voice after enrolment is
/// far more likely a colleague than the wearer, and "is it you?" would put
/// someone else's vector in the owner profile.
///
/// Rules, all of them refusals:
///   - only clusters the registry has not already named ([TranscriptEntry.profileId] null),
///   - each carrying at least [minPooledSeconds] of pooled speech,
///   - every pair at or above [floor] cosine — complete linkage, not a chain,
///     so a group cannot drift from one speaker to another one link at a time,
///   - spanning at least [minClips] distinct captures.
OwnerProposal? findOwnerProposal(
  List<TranscriptEntry> entries, {
  double floor = SpeakerRegistry.floor,
  int minClips = kProposalMinClips,
  double minPooledSeconds = kProposalMinPooledSeconds,
}) {
  // Entries from the same clip and cluster share one pooled embedding by
  // construction (device_bridge identifies once per cluster), so several lines
  // of the same turn are one piece of evidence, not several.
  final byCluster = <String, ProposalCluster>{};
  for (final e in entries) {
    final clipId = e.clipId;
    final clusterIndex = e.clusterIndex;
    final embedding = e.embedding;
    if (clipId == null || clusterIndex == null || embedding == null) continue;
    if (e.profileId != null) continue; // already named
    if (e.durationS < minPooledSeconds) continue;
    byCluster.putIfAbsent(
      '$clipId/$clusterIndex',
      () => ProposalCluster(
        clipId: clipId,
        clusterIndex: clusterIndex,
        embedding: embedding,
        durationS: e.durationS,
        talker: e.talker,
      ),
    );
  }

  final candidates = byCluster.values.toList()
    ..sort((a, b) => b.durationS.compareTo(a.durationS));
  if (candidates.length < minClips) return null;

  OwnerProposal? best;
  for (final seed in candidates) {
    final group = <ProposalCluster>[seed];
    for (final other in candidates) {
      if (identical(other, seed)) continue;
      final similarToAll = group.every((member) =>
          SpeakerRegistry.cosineSimilarity(member.embedding, other.embedding) >= floor);
      if (similarToAll) group.add(other);
    }
    final proposal = OwnerProposal(group);
    if (proposal.clipCount < minClips) continue;
    if (best == null ||
        proposal.clipCount > best.clipCount ||
        (proposal.clipCount == best.clipCount &&
            proposal.totalSeconds > best.totalSeconds)) {
      best = proposal;
    }
  }
  return best;
}
