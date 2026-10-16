// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The "is it you?" card on the transcripts page.
//
// The page runs a repeating pulse animation while mounted, so pumpAndSettle
// never settles; [_settle] pumps a fixed number of frames instead. Enrolment
// writes real files through SpeakerRegistry, and testWidgets runs under fake
// async where real IO never completes, so anything that enrols runs inside
// runAsync and is polled on the wall clock.
//
// OnDeviceTranscriptLog is a singleton with no reset, so every test here adds
// its own dominant evidence and asserts on that — never on the absence of
// leftovers from an earlier test. The rules about WHEN a proposal exists are
// tested against findOwnerProposal directly in voice_training_test.dart, where
// the input is fully controlled.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/owner_voice.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_registry.dart';
import 'package:kelvinlee/wearable/local_llm/transcript_log.dart';
import 'package:kelvinlee/wearable/pages/transcripts_page.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app() => MaterialApp(
      theme: WearableTheme.light(),
      home: const TranscriptsPage(),
    );

/// A unit vector at cosine [cos] from axis [a], rotated toward axis [a + 1].
/// Different [a] per test keeps one test's voice orthogonal to another's.
Float32List _near(double cos, {int a = 0}) {
  final v = Float32List(kSpeakerDim);
  v[a] = cos;
  v[a + 1] = math.sqrt(1 - cos * cos);
  return v;
}

/// Three captures of one voice, each well over the pooled-speech gate.
///
/// [durationS] breaks ties: the log is never cleared, so a later test's voice
/// must out-weigh an earlier test's leftovers to be the one proposed.
void _logRecurringVoice(String tag, {required int axis, double durationS = 9}) {
  const cosines = [1.0, 0.94, 0.90];
  for (var i = 0; i < cosines.length; i++) {
    OnDeviceTranscriptLog.instance.add(
      'line $tag$i',
      overheard: true,
      talker: 'Talker 1',
      clipId: '$tag$i',
      clusterIndex: 0,
      embedding: _near(cosines[i], a: axis),
      durationS: durationS,
    );
  }
}

const String _question = 'This voice is in most of your recordings — is it you?';

/// Enough frames for the registry read to land and the card to build.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Wall-clock wait for [done], for work that touches real files.
///
/// Generous on purpose: accepting a proposal enrols three clusters and each
/// one rewrites the registry with fsync'd writes (SpeakerRegistry._save uses
/// flush: true), which on a busy disk has been measured past 5 s in total.
/// A tight deadline here turned that into a flaky 'Talker 1' assertion; a
/// real hang still fails, just later.
Future<void> _until(WidgetTester t, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await t.pump();
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('proposal_');
    SpeakerRegistry.instance.useDirectoryForTest(tmp);
    OwnerVoice.instance.resetForTest();
    ownerProposalDismissedForSession = false;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('a recurring unnamed voice is offered, with its evidence', (t) async {
    _logRecurringVoice('a', axis: 0);

    await t.pumpWidget(_app());
    await _settle(t);

    expect(find.text(_question), findsOneWidget);
    expect(
      find.textContaining('3 separate captures, 27 s of speech'),
      findsOneWidget,
      reason: 'the wearer should see what the offer is built on',
    );
    expect(find.text("Yes, that's me"), findsOneWidget);
  });

  testWidgets('one tap enrols the owner and relabels those lines', (t) async {
    _logRecurringVoice('b', axis: 10, durationS: 12);

    await t.pumpWidget(_app());
    await _settle(t);
    await t.runAsync(() async {
      await t.tap(find.text("Yes, that's me"));
      await t.pump();
      await _until(t, () => find.text(_question).evaluate().isEmpty);
    });

    expect(OwnerVoice.instance.isEnrolled, isTrue);
    expect(
      SpeakerRegistry.instance.owner!.enrolled,
      hasLength(3),
      reason: 'three captures must stay three references, not one average',
    );
    for (var i = 0; i < 3; i++) {
      final line = OnDeviceTranscriptLog.instance.entries
          .firstWhere((e) => e.clipId == 'b$i');
      expect(line.talker, 'You');
      expect(line.profileId, isNotNull);
    }
    expect(find.text(_question), findsNothing);
  });

  testWidgets('dismissing it is remembered for the session', (t) async {
    _logRecurringVoice('c', axis: 20, durationS: 15);

    await t.pumpWidget(_app());
    await _settle(t);
    await t.tap(find.text('Not me'));
    await _settle(t);

    expect(find.text(_question), findsNothing);
    expect(OwnerVoice.instance.isEnrolled, isFalse,
        reason: 'dismissing must never enrol anything');

    // A fresh mount of the page — the wearer navigating back — stays quiet.
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpWidget(_app());
    await _settle(t);
    expect(find.text(_question), findsNothing);
  });

  testWidgets('nothing is offered once an owner is enrolled', (t) async {
    await t.runAsync(() => OwnerVoice.instance.injectEmbeddingForTest(_near(1.0, a: 40)));
    _logRecurringVoice('d', axis: 30, durationS: 18);

    await t.pumpWidget(_app());
    await _settle(t);

    expect(find.text(_question), findsNothing);
  });
}
