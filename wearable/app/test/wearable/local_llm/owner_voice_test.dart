// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for OwnerVoice pure logic and persistence.
//
// Embedding extraction needs native sherpa_onnx and is not tested here.
// Storage is now SpeakerRegistry (see speaker_registry_test.dart for the
// match rules); what this file pins is the facade — isEnrolled, ownerName,
// clear — and the one-time migration of an owner stored under the old
// SharedPreferences keys, which is the path an upgraded install takes.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/owner_voice.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

Float32List _vec(List<double> values) => Float32List.fromList(values);

Float32List _randomVec(int dim, {int seed = 42}) {
  final rng = math.Random(seed);
  return Float32List.fromList(List.generate(dim, (_) => rng.nextDouble() * 2 - 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  final ov = OwnerVoice.instance;
  final reg = SpeakerRegistry.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('owner_');
    reg.useDirectoryForTest(tmp);
    ov.resetForTest();
    await ov.clear();
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('cosineSimilarity', () {
    test('identical vectors → 1.0', () {
      final a = _vec([1, 2, 3]);
      expect(ov.cosineSimilarity(a, a), closeTo(1.0, 1e-6));
    });
    test('orthogonal vectors → 0.0', () {
      expect(ov.cosineSimilarity(_vec([1, 0]), _vec([0, 1])), closeTo(0.0, 1e-6));
    });
    test('opposite vectors → -1.0', () {
      expect(ov.cosineSimilarity(_vec([1, 0]), _vec([-1, 0])), closeTo(-1.0, 1e-6));
    });
    test('zero vector returns 0 without throwing', () {
      expect(ov.cosineSimilarity(_vec([0, 0]), _vec([1, 1])), 0);
    });
    test('symmetry: sim(a, b) == sim(b, a)', () {
      final a = _randomVec(8, seed: 1), b = _randomVec(8, seed: 2);
      expect(ov.cosineSimilarity(a, b), closeTo(ov.cosineSimilarity(b, a), 1e-9));
    });
  });

  group('enrollment facade over the registry', () {
    test('not enrolled after clear', () {
      expect(ov.isEnrolled, isFalse);
      expect(ov.ownerName, 'You');
    });

    test('injectEmbeddingForTest → isEnrolled, ownerName, registry owner', () async {
      await ov.injectEmbeddingForTest(_randomVec(kSpeakerDim, seed: 7), name: 'Alice');
      expect(ov.isEnrolled, isTrue);
      expect(ov.ownerName, 'Alice');
      expect(reg.owner?.isOwner, isTrue);
      expect(reg.owner?.enrolled.length, 1);
    });

    test('clear removes the owner profile and resets the name', () async {
      await ov.injectEmbeddingForTest(_randomVec(kSpeakerDim, seed: 7), name: 'Bob');
      await ov.clear();
      expect(ov.isEnrolled, isFalse);
      expect(ov.ownerName, 'You');
      expect(reg.owner, isNull);
    });

    test('survives a reload from disk', () async {
      await ov.injectEmbeddingForTest(_randomVec(kSpeakerDim, seed: 9), name: 'Carol');
      // Fresh in-memory state, same directory — what a restart does.
      reg.useDirectoryForTest(tmp);
      ov.resetForTest();
      await ov.loadEnrollmentState();
      expect(ov.isEnrolled, isTrue);
      expect(ov.ownerName, 'Carol');
    });

    test('a wrong-dimension vector cannot be enrolled', () async {
      expect(() => ov.injectEmbeddingForTest(_vec([0, 0, 1, 0]), name: 'X'),
          throwsArgumentError);
    });
  });

  group('legacy SharedPreferences migration', () {
    test('an owner stored under the old keys becomes the registry owner, once', () async {
      final emb = SpeakerRegistry.l2Normalize(_randomVec(kSpeakerDim, seed: 3));
      SharedPreferences.setMockInitialValues({
        'wearable.owner.enrolled': true,
        'wearable.owner.name': 'Dana',
        'wearable.owner.embedding': base64Encode(Uint8List.view(emb.buffer)),
      });
      ov.resetForTest();
      await ov.loadEnrollmentState();

      expect(ov.isEnrolled, isTrue);
      expect(ov.ownerName, 'Dana');
      expect(reg.owner?.enrolled.length, 1);
      // The old keys are gone, so a later clear() cannot resurrect them.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('wearable.owner.embedding'), isNull);
      expect(prefs.getBool('wearable.owner.enrolled'), isNull);
      // The migrated vector still matches itself through the registry.
      expect(reg.match(emb, durationS: 10).profile?.id, reg.owner?.id);
    });

    test('a legacy vector of the wrong dimension is dropped, not crashed on', () async {
      final bad = Float32List(128);
      SharedPreferences.setMockInitialValues({
        'wearable.owner.enrolled': true,
        'wearable.owner.name': 'Eve',
        'wearable.owner.embedding': base64Encode(Uint8List.view(bad.buffer)),
      });
      ov.resetForTest();
      await expectLater(ov.loadEnrollmentState(), completes);
      expect(ov.isEnrolled, isFalse, reason: 'a 128-dim vector is not this model\'s');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('wearable.owner.enrolled'), isNull, reason: 'keys must still be cleared');
    });

    test('migration does not overwrite an owner the registry already has', () async {
      await ov.injectEmbeddingForTest(_randomVec(kSpeakerDim, seed: 11), name: 'Registry');
      SharedPreferences.setMockInitialValues({
        'wearable.owner.enrolled': true,
        'wearable.owner.name': 'Legacy',
        'wearable.owner.embedding':
            base64Encode(Uint8List.view(_randomVec(kSpeakerDim, seed: 12).buffer)),
      });
      ov.resetForTest();
      await ov.loadEnrollmentState();
      expect(ov.ownerName, 'Registry');
      expect(reg.owner?.enrolled.length, 1);
    });
  });

  group('isOwner', () {
    test('returns false when not enrolled, without touching the extractor', () async {
      expect(await ov.isOwner(Float32List(16000)), isFalse);
    });
    test('the default threshold is the registry floor', () {
      // Two entry points, one rule. If someone moves the floor, this fails
      // until the facade follows.
      expect(SpeakerRegistry.floor, 0.65);
    });
  });
}
