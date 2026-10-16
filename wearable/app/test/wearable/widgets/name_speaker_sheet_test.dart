// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Widget tests for NameSpeakerSheet — the tap-to-name enrolment path.
//
// Nothing here mocks OwnerVoice or SpeakerRegistry. The interesting assertion
// is not "a method was called" but "a biometric vector was actually stored and
// the right lines were relabelled", and both are reachable without sherpa:
// enrollFromEmbedding() writes straight through the registry, and the registry
// is pure Dart over a directory we point at a temp dir.
//
// The two refusal states are the ones worth pinning. Under the evidence floor
// the sheet must not offer to enrol at all (a 1-second clip is where speaker
// models are least reliable, and a bad enrolment poisons every later match).
// At the named cap the free-text field must disappear rather than throw
// StateError out of enrol() after the user has typed a name.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/owner_voice.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_registry.dart';
import 'package:kelvinlee/wearable/local_llm/transcript_log.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:kelvinlee/wearable/widgets/name_speaker_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A unit vector with a 1 at [axis] — the registry's own test fixture shape.
Float32List _axis(int axis) {
  final v = Float32List(kSpeakerDim);
  v[axis] = 1;
  return v;
}

TranscriptEntry _entry({
  required String clipId,
  int clusterIndex = 0,
  double durationS = 8,
  String text = 'hello there',
  int axis = 0,
}) =>
    TranscriptEntry(
      id: '$clipId-$clusterIndex',
      text: text,
      at: DateTime(2026, 4, 27),
      overheard: true,
      talker: 'Talker ${clusterIndex + 1}',
      clipId: clipId,
      clusterIndex: clusterIndex,
      embedding: _axis(axis),
      durationS: durationS,
    );

/// Pumps a host page and opens the sheet on it, so the sheet gets the
/// Navigator and ScaffoldMessenger its own code reaches for.
Future<void> openSheet(WidgetTester tester, TranscriptEntry entry) async {
  await tester.pumpWidget(MaterialApp(
    theme: WearableTheme.light(),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showNameSpeakerSheet(context, entry),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Real file I/O never completes inside the fake-async zone a widget test
/// body runs in, and every registry mutation writes to disk. So a tap that
/// triggers one runs under runAsync, and the loop alternates real-time waits
/// (for the write) with pumps (for the sheet's own continuation: relabel,
/// pop, snackbar) until the UI reaches [done]. Polling the UI rather than the
/// registry is deliberate — the registry updates before its write finishes,
/// and the sheet only pops after it.
Future<void> tapUntil(WidgetTester tester, Finder target, bool Function() done) async {
  await tester.runAsync(() async {
    await tester.tap(target);
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
  });
  expect(done(), isTrue, reason: 'the tap never produced the expected state');
  await tester.pumpAndSettle();
}

bool sheetClosed() => find.textContaining('Leave as').evaluate().isEmpty;

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('name_sheet_');
    SpeakerRegistry.instance.useDirectoryForTest(tmp);
    OwnerVoice.instance.resetForTest();
    await SpeakerRegistry.instance.ensureLoaded();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('under the evidence floor, no enrol action is offered and the copy says why',
      (tester) async {
    await openSheet(
      tester,
      _entry(clipId: 'clip-short', durationS: SpeakerRegistry.minEvidenceS - 0.5),
    );

    expect(find.textContaining('Only 2.5 s of speech'), findsOneWidget);
    expect(find.textContaining('needed to enrol a voice reliably'), findsOneWidget);

    // No way to enrol from here at all — not the owner action, not a named
    // profile, not the free-text field.
    expect(find.text('This is me'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    // Only the dismissal remains.
    expect(find.text('Leave as Talker 1'), findsOneWidget);
  });

  testWidgets('at the named cap the free-text field is replaced by the cap message',
      (tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < SpeakerRegistry.maxNamed; i++) {
        await SpeakerRegistry.instance.enrol(name: 'Person $i', vectors: [_axis(i + 20)]);
      }
    });
    expect(SpeakerRegistry.instance.canAddNamed, isFalse);

    await openSheet(tester, _entry(clipId: 'clip-full'));

    expect(find.byType(TextField), findsNothing);
    expect(
      find.textContaining('Registry full — ${SpeakerRegistry.maxNamed} people is the limit'),
      findsOneWidget,
    );
    // The known people are still offered — adding a sample to an existing
    // profile does not grow the gallery.
    expect(find.text('Person 0'), findsOneWidget);
  });

  testWidgets('"This is me" enrols the owner and relabels the same clip and cluster',
      (tester) async {
    const clip = 'clip-me';
    final log = OnDeviceTranscriptLog.instance;
    log.add('first line', clipId: clip, clusterIndex: 0, embedding: _axis(0), durationS: 8,
        talker: 'Talker 1');
    log.add('second line', clipId: clip, clusterIndex: 0, embedding: _axis(0), durationS: 8,
        talker: 'Talker 1');
    log.add('someone else', clipId: clip, clusterIndex: 1, embedding: _axis(5), durationS: 8,
        talker: 'Talker 2');

    await openSheet(tester, _entry(clipId: clip));
    await tapUntil(tester, find.text('This is me'), sheetClosed);

    // The vector reached the registry through OwnerVoice.enrollFromEmbedding.
    final owner = SpeakerRegistry.instance.owner;
    expect(owner, isNotNull);
    expect(owner!.isOwner, isTrue);
    expect(owner.enrolled, hasLength(1));
    expect(SpeakerRegistry.cosineSimilarity(owner.enrolled.single, _axis(0)),
        closeTo(1.0, 1e-6));

    // Both lines of cluster 0 are relabelled; cluster 1 is untouched.
    final byText = {for (final e in log.entries) e.text: e};
    expect(byText['first line']!.talker, 'You');
    expect(byText['second line']!.talker, 'You');
    expect(byText['second line']!.profileId, owner.id);
    expect(byText['someone else']!.talker, 'Talker 2');

    // And the sheet closed.
    expect(find.text('Leave as Talker 1'), findsNothing);
  });

  testWidgets('tapping a known person adds a sample to that profile and relabels',
      (tester) async {
    const clip = 'clip-known';
    final log = OnDeviceTranscriptLog.instance;
    late SpeakerProfile ana;
    await tester.runAsync(() async {
      ana = await SpeakerRegistry.instance.enrol(name: 'Ana', vectors: [_axis(3)]);
    });
    log.add('her line', clipId: clip, clusterIndex: 0, embedding: _axis(0), durationS: 8,
        talker: 'Talker 1');

    await openSheet(tester, _entry(clipId: clip));
    await tapUntil(tester, find.text('Ana'), sheetClosed);

    final after = SpeakerRegistry.instance.profiles.singleWhere((p) => p.id == ana.id);
    expect(after.enrolled, hasLength(2));
    // No new profile was created for a name that already exists.
    expect(SpeakerRegistry.instance.profiles, hasLength(1));

    final entry = log.entries.firstWhere((e) => e.text == 'her line');
    expect(entry.talker, 'Ana');
    expect(entry.profileId, ana.id);
  });

  testWidgets('naming someone new creates a named profile and relabels', (tester) async {
    const clip = 'clip-new';
    final log = OnDeviceTranscriptLog.instance;
    log.add('her line', clipId: clip, clusterIndex: 0, embedding: _axis(0), durationS: 8,
        talker: 'Talker 1');

    await openSheet(tester, _entry(clipId: clip));
    await tester.enterText(find.byType(TextField), 'Ana');
    await tapUntil(tester, find.byIcon(Icons.check), sheetClosed);

    final ana = SpeakerRegistry.instance.profiles.singleWhere((p) => p.name == 'Ana');
    expect(ana.isOwner, isFalse);
    expect(ana.enrolled, hasLength(1));

    final entry = log.entries.firstWhere((e) => e.text == 'her line');
    expect(entry.talker, 'Ana');
    expect(entry.profileId, ana.id);
  });
}
