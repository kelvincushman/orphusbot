// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for SpeakerRegistry. The match rules are the point: each refusal
// (floor, margin, evidence) exists to stop a wrong name being applied, and a
// wrong name in a transcript of a real conversation puts words in someone's
// mouth. So the tests are mostly about when the registry says Unknown.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_registry.dart';

/// A unit vector with a 1 at [axis] — orthogonal to every other axis.
Float32List _axis(int axis) {
  final v = Float32List(kSpeakerDim);
  v[axis] = 1;
  return v;
}

/// A unit vector at cosine [cos] from [_axis(a)], rotated toward [_axis(b)].
Float32List _between(int a, int b, double cos) {
  final v = Float32List(kSpeakerDim);
  v[a] = cos;
  v[b] = math.sqrt(1 - cos * cos);
  return v;
}

void main() {
  late Directory tmp;
  final reg = SpeakerRegistry.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('speakers_');
    reg.useDirectoryForTest(tmp);
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('match refusals', () {
    test('no named profiles → Unknown(noNamedProfiles)', () async {
      final m = reg.match(_axis(0), durationS: 10);
      expect(m.isKnown, isFalse);
      expect(m.reason, MatchReason.noNamedProfiles);
    });

    test('too short → Unknown even for a perfect score', () async {
      await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      final m = reg.match(_axis(0), durationS: SpeakerRegistry.minEvidenceS - 0.1);
      expect(m.isKnown, isFalse);
      expect(m.reason, MatchReason.tooShort);
    });

    test('identical vector with enough evidence → named', () async {
      final p = await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      final m = reg.match(_axis(0), durationS: 10);
      expect(m.isKnown, isTrue);
      expect(m.profile!.id, p.id);
      expect(m.score, closeTo(1.0, 1e-6));
    });

    test('below floor → Unknown(belowFloor), score reported', () async {
      await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      final m = reg.match(_between(0, 1, SpeakerRegistry.floor - 0.05), durationS: 10);
      expect(m.isKnown, isFalse);
      expect(m.reason, MatchReason.belowFloor);
      expect(m.score, closeTo(SpeakerRegistry.floor - 0.05, 1e-6));
    });

    test('two profiles inside the margin → Unknown(ambiguous), not the argmax', () async {
      await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      await reg.enrol(name: 'Ben', vectors: [_axis(1)]);
      // Query sits 0.80 from Ana and 0.76 from Ben: both over the floor,
      // gap 0.04 < margin 0.07. The argmax would say Ana. It must not.
      final q = Float32List(kSpeakerDim)
        ..[0] = 0.80
        ..[1] = 0.76;
      final m = reg.match(q, durationS: 10);
      expect(m.isKnown, isFalse, reason: 'argmax applied despite a close runner-up');
      expect(m.reason, MatchReason.ambiguous);
      expect(m.margin, lessThan(SpeakerRegistry.margin));
    });

    test('clear winner over the margin → named', () async {
      final ana = await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      await reg.enrol(name: 'Ben', vectors: [_axis(1)]);
      final q = Float32List(kSpeakerDim)
        ..[0] = 0.90
        ..[1] = 0.40;
      final m = reg.match(q, durationS: 10);
      expect(m.profile?.id, ana.id);
    });

    test('scores by MAX over a profile\'s vectors, not a centroid', () async {
      // Ana has one vector far from the query and one identical to it. A
      // centroid would land between them and might miss the floor; max must
      // match.
      final ana = await reg.enrol(name: 'Ana', vectors: [_axis(5), _axis(0)]);
      final m = reg.match(_axis(0), durationS: 10);
      expect(m.profile?.id, ana.id);
      expect(m.score, closeTo(1.0, 1e-6));
    });

    test('an unnamed profile is never searched', () async {
      await reg.enrol(name: '', vectors: [_axis(0)]);
      final m = reg.match(_axis(0), durationS: 10);
      expect(m.isKnown, isFalse);
      expect(m.reason, MatchReason.noNamedProfiles);
    });
  });

  group('caps', () {
    test('an owner enrolled first does not use up one of the named slots', () async {
      await reg.enrol(name: 'Me', vectors: [_axis(60)], isOwner: true);
      expect(reg.namedCount, 0);
      for (var i = 0; i < SpeakerRegistry.maxNamed; i++) {
        await reg.enrol(name: 'P$i', vectors: [_axis(i)]);
      }
      expect(reg.namedCount, SpeakerRegistry.maxNamed);
      expect(reg.canAddNamed, isFalse);
      expect(reg.profiles.length, SpeakerRegistry.maxNamed + 1);
    });

    test('named cap is enforced; the owner is exempt', () async {
      for (var i = 0; i < SpeakerRegistry.maxNamed; i++) {
        await reg.enrol(name: 'P$i', vectors: [_axis(i)]);
      }
      expect(reg.canAddNamed, isFalse);
      expect(() => reg.enrol(name: 'One too many', vectors: [_axis(50)]),
          throwsStateError);
      // Owner still allowed at the cap.
      final me = await reg.enrol(name: 'Me', vectors: [_axis(60)], isOwner: true);
      expect(me.isOwner, isTrue);
      expect(reg.owner?.id, me.id);
    });

    test('observe FIFO-caps and never touches enrolled', () async {
      final p = await reg.enrol(name: 'Ana', vectors: [_axis(0), _axis(1)]);
      for (var i = 0; i < SpeakerRegistry.maxObserved + 5; i++) {
        await reg.observe(p.id, _axis(10 + i));
      }
      final after = reg.profiles.firstWhere((x) => x.id == p.id);
      expect(after.observed.length, SpeakerRegistry.maxObserved);
      expect(after.enrolled.length, 2, reason: 'enrolled must be immutable');
      // Oldest observed was evicted: axis 10 is gone, the last one is present.
      expect(after.observed.any((v) => v[10] == 1), isFalse);
      expect(after.observed.any((v) => v[10 + SpeakerRegistry.maxObserved + 4] == 1), isTrue);
    });

    test('enrolling the owner twice appends to the same profile', () async {
      final a = await reg.enrol(name: 'Me', vectors: [_axis(0)], isOwner: true);
      final b = await reg.enrol(name: 'Me', vectors: [_axis(1)], isOwner: true);
      expect(b.id, a.id);
      expect(b.enrolled.length, 2);
      expect(reg.profiles.where((p) => p.isOwner).length, 1);
    });
  });

  group('persistence', () {
    test('round-trips vectors through disk', () async {
      final v = Float32List.fromList(List.generate(kSpeakerDim, (i) => (i % 7) / 7.0));
      final p = await reg.enrol(name: 'Ana', vectors: [v]);
      await reg.observe(p.id, _axis(3));

      // Fresh instance state, same directory.
      reg.useDirectoryForTest(tmp);
      await reg.ensureLoaded();

      final back = reg.profiles.firstWhere((x) => x.id == p.id);
      expect(back.name, 'Ana');
      expect(back.enrolled.length, 1);
      expect(back.observed.length, 1);
      expect(back.modelId, kSpeakerModelId);
      final want = SpeakerRegistry.l2Normalize(v);
      for (var i = 0; i < kSpeakerDim; i++) {
        expect(back.enrolled[0][i], closeTo(want[i], 1e-6));
      }
      // And it still matches after the round-trip.
      expect(reg.match(v, durationS: 10).profile?.id, p.id);
    });

    test('owner is listed first after reload', () async {
      await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      await reg.enrol(name: 'Me', vectors: [_axis(1)], isOwner: true);
      reg.useDirectoryForTest(tmp);
      await reg.ensureLoaded();
      expect(reg.profiles.first.isOwner, isTrue);
    });

    test('a profile from a different model is loaded but not searched', () async {
      await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      // Tamper the index to claim a different model.
      final idx = File('${tmp.path}/profiles.json');
      idx.writeAsStringSync(idx.readAsStringSync().replaceAll(kSpeakerModelId, 'some_other_model'));
      reg.useDirectoryForTest(tmp);
      await reg.ensureLoaded();
      expect(reg.profiles.length, 1);
      expect(reg.profiles.first.isCompatible, isFalse);
      expect(reg.match(_axis(0), durationS: 10).reason, MatchReason.noNamedProfiles);
    });

    test('a corrupt index starts empty without throwing', () async {
      File('${tmp.path}/profiles.json').writeAsStringSync('{not json');
      reg.useDirectoryForTest(tmp);
      await expectLater(reg.ensureLoaded(), completes);
      expect(reg.profiles, isEmpty);
    });

    test('remove deletes the vector file', () async {
      final p = await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      final f = File('${tmp.path}/${p.id}.f32');
      expect(f.existsSync(), isTrue);
      await reg.remove(p.id);
      expect(f.existsSync(), isFalse);
      expect(reg.profiles, isEmpty);
    });

    test('clearAll removes everything', () async {
      await reg.enrol(name: 'Ana', vectors: [_axis(0)]);
      await reg.enrol(name: 'Me', vectors: [_axis(1)], isOwner: true);
      await reg.clearAll();
      expect(reg.profiles, isEmpty);
      expect(tmp.listSync().where((e) => e.path.endsWith('.f32')), isEmpty);
      expect(File('${tmp.path}/profiles.json').existsSync(), isFalse);
    });
  });

  group('input validation', () {
    test('wrong dimension is rejected at enrol, not at match', () async {
      expect(() => reg.enrol(name: 'Ana', vectors: [Float32List(10)]), throwsArgumentError);
    });
    test('empty enrolment is rejected', () async {
      expect(() => reg.enrol(name: 'Ana', vectors: const []), throwsArgumentError);
    });
  });
}
