// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Widget tests for WearablePeoplePage — the delete path for stored voiceprints.
//
// The page's whole reason to exist is that a user can get their biometric
// vectors off the phone, so the tests assert on the registry after each
// action, not just on what the screen says. The registry is pure Dart over a
// directory, so a temp dir is the only fixture needed.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/speaker_registry.dart';
import 'package:kelvinlee/wearable/local_llm/owner_voice.dart';
import 'package:kelvinlee/wearable/pages/settings/wearable_people_page.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Float32List _axis(int axis) {
  final v = Float32List(kSpeakerDim);
  v[axis] = 1;
  return v;
}

/// Real file I/O never completes inside the fake-async zone a widget test
/// body runs in, and every registry mutation writes to disk. Seeding runs
/// under runAsync. A tap that deletes something also runs under runAsync, and
/// the loop alternates real-time waits (for the write) with pumps (for the
/// page's own refresh) until the UI reaches [done]. Polling the UI rather
/// than the registry is deliberate — the registry updates before its write
/// finishes, and the page only refreshes after it.
Future<void> seed(WidgetTester tester, Future<void> Function() writes) =>
    tester.runAsync(writes);

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

Future<void> pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: WearableTheme.light(),
    home: const WearablePeoplePage(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('people_page_');
    SpeakerRegistry.instance.useDirectoryForTest(tmp);
    OwnerVoice.instance.resetForTest();
    await SpeakerRegistry.instance.ensureLoaded();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('0 profiles — empty state, and delete-all is inert', (tester) async {
    await pumpPage(tester);

    expect(find.text('KNOWN VOICES (0)'), findsOneWidget);
    expect(find.textContaining('No voices stored yet'), findsOneWidget);

    // The destructive action is present but disabled, so its absence does not
    // read as "there is no way to delete these".
    expect(find.text('Delete all voices'), findsOneWidget);
    expect(find.text('Nothing stored.'), findsOneWidget);
    await tester.tap(find.text('Delete all voices'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('1 profile — name, counts and created date render', (tester) async {
    await seed(tester, () async {
      final p = await SpeakerRegistry.instance.enrol(name: 'Ana', vectors: [_axis(0), _axis(1)]);
      await SpeakerRegistry.instance.observe(p.id, _axis(2));
    });

    await pumpPage(tester);

    final today = DateTime.now();
    final stamp = '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    expect(find.text('KNOWN VOICES (1)'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('2 enrolled · 1 observed · added $stamp'), findsOneWidget);
  });

  testWidgets('10 profiles — the full gallery renders', (tester) async {
    await seed(tester, () async {
      for (var i = 0; i < SpeakerRegistry.maxNamed; i++) {
        await SpeakerRegistry.instance.enrol(name: 'Person $i', vectors: [_axis(i)]);
      }
    });
    await pumpPage(tester);

    expect(find.text('KNOWN VOICES (${SpeakerRegistry.maxNamed})'), findsOneWidget);
    // The list is scrollable, so assert on the ones that fit plus the count.
    expect(find.text('Person 0'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Person 9'), 200);
    expect(find.text('Person 9'), findsOneWidget);
  });

  testWidgets('the owner is listed first and marked', (tester) async {
    await seed(tester, () async {
      await SpeakerRegistry.instance.enrol(name: 'Ana', vectors: [_axis(0)]);
      await SpeakerRegistry.instance.enrol(name: 'Kelvin', vectors: [_axis(1)], isOwner: true);
    });

    await pumpPage(tester);

    expect(find.text('Kelvin (you)'), findsOneWidget);
    final owner = tester.getTopLeft(find.text('Kelvin (you)'));
    final other = tester.getTopLeft(find.text('Ana'));
    expect(owner.dy, lessThan(other.dy));
  });

  testWidgets('removing one profile deletes it from the registry', (tester) async {
    await seed(tester, () async {
      await SpeakerRegistry.instance.enrol(name: 'Ana', vectors: [_axis(0)]);
      await SpeakerRegistry.instance.enrol(name: 'Bo', vectors: [_axis(1)]);
    });
    await pumpPage(tester);

    await tapUntil(tester, find.byTooltip('Delete Ana'),
        () => find.text('Ana').evaluate().isEmpty);

    expect(SpeakerRegistry.instance.profiles.map((p) => p.name), ['Bo']);
    expect(find.text('Bo'), findsOneWidget);
    expect(File('${tmp.path}/profiles.json').readAsStringSync(), isNot(contains('Ana')));
  });

  testWidgets('delete-all asks first, and cancelling keeps everything', (tester) async {
    await seed(tester, () => SpeakerRegistry.instance.enrol(name: 'Ana', vectors: [_axis(0)]));
    await pumpPage(tester);

    await tester.tap(find.text('Delete all voices'));
    await tester.pumpAndSettle();

    // The confirmation must name what is being deleted.
    expect(find.textContaining('biometric data'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(SpeakerRegistry.instance.profiles, hasLength(1));
  });

  testWidgets('delete-all confirmed empties the registry, owner included', (tester) async {
    await seed(tester, () async {
      await SpeakerRegistry.instance.enrol(name: 'Ana', vectors: [_axis(0)]);
      await SpeakerRegistry.instance.enrol(name: 'Kelvin', vectors: [_axis(1)], isOwner: true);
    });
    await pumpPage(tester);

    await tester.tap(find.text('Delete all voices'));
    await tester.pumpAndSettle();
    await tapUntil(tester, find.text('Delete everything'),
        () => find.textContaining('No voices stored yet').evaluate().isNotEmpty);

    expect(SpeakerRegistry.instance.profiles, isEmpty);
    // Gone from disk too — the index and every vector file.
    expect(File('${tmp.path}/profiles.json').existsSync(), isFalse);
    expect(tmp.listSync().where((f) => f.path.endsWith('.f32')), isEmpty);
  });

  testWidgets('a profile from an older embedding model is flagged, not hidden',
      (tester) async {
    // Written straight to disk so the stale modelId survives — enrol() always
    // stamps the current one.
    File('${tmp.path}/old.f32').writeAsBytesSync(Float32List(kSpeakerDim).buffer.asUint8List());
    File('${tmp.path}/profiles.json').writeAsStringSync(
      '{"version":1,"profiles":[{"id":"old","name":"Ana","isOwner":false,'
      '"modelId":"some_older_model","dim":$kSpeakerDim,"enrolled":1,"observed":0,'
      '"createdAt":"2026-01-02T03:04:05.000","updatedAt":"2026-01-02T03:04:05.000"}]}',
    );
    SpeakerRegistry.instance.useDirectoryForTest(tmp);
    await seed(tester, () => SpeakerRegistry.instance.ensureLoaded());

    await pumpPage(tester);

    expect(find.text('Ana'), findsOneWidget);
    expect(find.textContaining('older voice model'), findsOneWidget);
    expect(find.text('1 enrolled · 0 observed · added 2026-01-02'), findsOneWidget);
  });
}
