// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for the enrolment logic. Both halves are about refusing: the guided
// session refuses a clip that does not sound like the others, and the proposal
// refuses to ask unless the same voice has turned up repeatedly with real
// speech behind it. A wrong enrolment is worse than no enrolment — it is a
// biometric vector that will silently mislabel someone for as long as it sits
// in the registry.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_registry.dart';
import 'package:kelvinlee/wearable/local_llm/transcript_log.dart';
import 'package:kelvinlee/wearable/local_llm/voice_training.dart';

/// A unit vector with a 1 at [axis] — orthogonal to every other axis.
Float32List _axis(int axis) {
  final v = Float32List(kSpeakerDim);
  v[axis] = 1;
  return v;
}

/// A unit vector at cosine [cos] from `_axis(a)`, rotated toward `_axis(b)`.
Float32List _between(int a, int b, double cos) {
  final v = Float32List(kSpeakerDim);
  v[a] = cos;
  v[b] = math.sqrt(1 - cos * cos);
  return v;
}

/// [seconds] of silence — the controller only measures length, never content.
Float32List _clip(double seconds) => Float32List((seconds * 16000).round());

TranscriptEntry _entry({
  required String clipId,
  required int clusterIndex,
  required Float32List embedding,
  double durationS = 8,
  String? profileId,
  String talker = 'Talker 1',
}) =>
    TranscriptEntry(
      id: '$clipId-$clusterIndex',
      text: 'something was said',
      at: DateTime(2026, 1, 1),
      overheard: true,
      talker: talker,
      clipId: clipId,
      clusterIndex: clusterIndex,
      embedding: embedding,
      durationS: durationS,
      profileId: profileId,
    );

void main() {
  group('VoiceTrainingController — prompt sequencing', () {
    test('walks the prompts one accepted clip at a time', () async {
      final enrolled = <List<Float32List>>[];
      final c = VoiceTrainingController(
        extract: (_) async => _axis(0),
        enrolClips: (clips) async => enrolled.add(clips),
      );

      expect(c.stepIndex, 0);
      expect(c.currentPrompt, kTrainingPrompts.first);
      expect(c.isComplete, isFalse);

      for (var i = 0; i < kTrainingPrompts.length; i++) {
        expect(c.currentPrompt, kTrainingPrompts[i]);
        expect((await c.submit(_clip(5))).accepted, isTrue);
      }

      expect(c.isComplete, isTrue);
      expect(c.currentPrompt, isNull);
      expect(c.acceptedCount, kTrainingPrompts.length);

      await c.enrol();
      expect(enrolled.single, hasLength(kTrainingPrompts.length));
    });

    test('a rejected clip does not advance the prompt', () async {
      final c = VoiceTrainingController(
        extract: (_) async => _axis(0),
        enrolClips: (_) async {},
      );

      final short = await c.submit(_clip(1));
      expect(short.verdict, ClipVerdict.tooShort);
      expect(c.stepIndex, 0);
      expect(c.currentPrompt, kTrainingPrompts.first);
    });

    test('an embedder that refuses the clip reports noVoice, not a crash', () async {
      final c = VoiceTrainingController(
        extract: (_) async => null,
        enrolClips: (_) async {},
      );
      expect((await c.submit(_clip(6))).verdict, ClipVerdict.noVoice);
      expect(c.acceptedCount, 0);
    });

    test('enrol() before the last clip throws rather than storing one vector', () async {
      final c = VoiceTrainingController(
        extract: (_) async => _axis(0),
        enrolClips: (_) async {},
      );
      await c.submit(_clip(5));
      expect(c.enrol, throwsStateError);
    });

    test('reset() puts the session back to the first prompt', () async {
      final c = VoiceTrainingController(
        extract: (_) async => _axis(0),
        enrolClips: (_) async {},
      );
      await c.submit(_clip(5));
      await c.submit(_clip(5));
      c.reset();
      expect(c.acceptedCount, 0);
      expect(c.currentPrompt, kTrainingPrompts.first);
      expect(c.similarities, isEmpty);
    });
  });

  group('VoiceTrainingController — self-similarity gating', () {
    test('the first clip has nothing to compare to and is taken', () async {
      final c = VoiceTrainingController(
        extract: (_) async => _axis(0),
        enrolClips: (_) async {},
      );
      final out = await c.submit(_clip(5));
      expect(out.accepted, isTrue);
      expect(out.similarity, isNull);
      expect(c.similarities, [1.0]); // a full ring, not a gap
    });

    test('a second voice is refused and the similarity is reported', () async {
      final vectors = <Float32List>[_axis(0), _axis(1)]; // orthogonal: cos 0
      var i = 0;
      final c = VoiceTrainingController(
        extract: (_) async => vectors[i++],
        enrolClips: (_) async {},
      );

      expect((await c.submit(_clip(5))).accepted, isTrue);
      final out = await c.submit(_clip(5));
      expect(out.verdict, ClipVerdict.differentVoice);
      expect(out.similarity, closeTo(0, 1e-6));
      expect(c.acceptedCount, 1, reason: 'the bad take must not be stored');
    });

    test('the same voice at a different distance still clears the floor', () async {
      final vectors = <Float32List>[
        _axis(0),
        _between(0, 5, 0.80), // tired, further from the mic — still you
      ];
      var i = 0;
      final c = VoiceTrainingController(
        extract: (_) async => vectors[i++],
        enrolClips: (_) async {},
      );
      await c.submit(_clip(5));
      final out = await c.submit(_clip(5));
      expect(out.accepted, isTrue);
      expect(out.similarity, closeTo(0.80, 1e-3));
      expect(c.similarities.last, closeTo(0.80, 1e-3));
    });

    test('similarity is the MAX over previous clips, not the last one', () async {
      // Clip 3 is far from clip 2 but close to clip 1. The registry scores a
      // profile by the max over its vectors; the gate must agree with it, or
      // it refuses takes the matcher would later accept.
      final vectors = <Float32List>[
        _axis(0),
        _between(0, 5, 0.90),
        _between(0, 9, 0.88),
      ];
      var i = 0;
      final c = VoiceTrainingController(
        extract: (_) async => vectors[i++],
        enrolClips: (_) async {},
      );
      await c.submit(_clip(5));
      await c.submit(_clip(5));
      final out = await c.submit(_clip(5));
      expect(out.accepted, isTrue);
      expect(out.similarity, closeTo(0.88, 1e-3));
    });
  });

  group('findOwnerProposal', () {
    /// Three captures of one voice, each with plenty of speech.
    List<TranscriptEntry> recurring() => [
          _entry(clipId: 'a', clusterIndex: 0, embedding: _axis(0)),
          _entry(clipId: 'b', clusterIndex: 0, embedding: _between(0, 5, 0.92)),
          _entry(clipId: 'c', clusterIndex: 1, embedding: _between(0, 7, 0.88)),
        ];

    test('finds a voice that recurs across three captures', () {
      final p = findOwnerProposal(recurring());
      expect(p, isNotNull);
      expect(p!.clipCount, 3);
      expect(p.clusters, hasLength(3));
      expect(p.totalSeconds, closeTo(24, 1e-6));
    });

    test('several lines of one turn are one piece of evidence, not three', () {
      final entries = [
        ...recurring(),
        // Same clip and cluster as 'a' — the diarizer grouped them.
        _entry(clipId: 'a', clusterIndex: 0, embedding: _axis(0)),
        _entry(clipId: 'a', clusterIndex: 0, embedding: _axis(0)),
      ];
      expect(findOwnerProposal(entries)!.clusters, hasLength(3));
    });

    test('two captures are not enough', () {
      final p = findOwnerProposal(recurring().take(2).toList());
      expect(p, isNull);
    });

    test('a cluster under the pooled-speech gate does not count', () {
      final entries = recurring();
      entries[2] = _entry(
        clipId: 'c',
        clusterIndex: 1,
        embedding: _between(0, 7, 0.88),
        durationS: kProposalMinPooledSeconds - 0.1,
      );
      expect(findOwnerProposal(entries), isNull);
    });

    test('an already-named voice is never proposed', () {
      final entries = recurring()
          .map((e) => e.copyWith(profileId: 'someone'))
          .toList();
      expect(findOwnerProposal(entries), isNull);
    });

    test('three different people in three captures are not one voice', () {
      final entries = [
        _entry(clipId: 'a', clusterIndex: 0, embedding: _axis(0)),
        _entry(clipId: 'b', clusterIndex: 0, embedding: _axis(1)),
        _entry(clipId: 'c', clusterIndex: 0, embedding: _axis(2)),
      ];
      expect(findOwnerProposal(entries), isNull);
    });

    test('a chain of near-neighbours does not drift into one group', () {
      // A–B and B–C clear the floor; A–C does not. Single linkage would call
      // these one person; complete linkage refuses, which is the point.
      const floor = SpeakerRegistry.floor;
      expect(SpeakerRegistry.cosineSimilarity(_axis(0), _between(0, 5, 0.70)),
          greaterThanOrEqualTo(floor));
      final entries = [
        _entry(clipId: 'a', clusterIndex: 0, embedding: _axis(0)),
        _entry(clipId: 'b', clusterIndex: 0, embedding: _between(0, 5, 0.70)),
        _entry(clipId: 'c', clusterIndex: 0, embedding: _axis(5)),
      ];
      expect(findOwnerProposal(entries), isNull);
    });

    test('the wearer is picked out of a room with other people in it', () {
      final entries = [
        ...recurring(),
        _entry(clipId: 'a', clusterIndex: 1, embedding: _axis(20)),
        _entry(clipId: 'b', clusterIndex: 1, embedding: _axis(21)),
      ];
      final p = findOwnerProposal(entries);
      expect(p, isNotNull);
      expect(p!.clipCount, 3);
      expect(p.clusters.every((c) => c.clusterIndex != 1 || c.clipId == 'c'), isTrue);
    });

    test('entries with no embedding are skipped, not crashed on', () {
      final entries = [
        ...recurring(),
        TranscriptEntry(
          id: 'no-embedding',
          text: 'no diarization on this one',
          at: DateTime(2026, 1, 1),
          overheard: false,
        ),
      ];
      expect(findOwnerProposal(entries)!.clipCount, 3);
    });

    test('an empty log proposes nothing', () {
      expect(findOwnerProposal(const []), isNull);
    });
  });
}
