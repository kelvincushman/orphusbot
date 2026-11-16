import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/avatar.dart';
import 'package:orphusbot_app/motion.dart';
import 'package:orphusbot_app/stage.dart';
import 'package:orphusbot_app/thread.dart';

void main() {
  tearDown(() => motion.value = Motion.full);

  final house = [
    for (final slug in ['researcher', 'coder', 'blogger'])
      <String, dynamic>{
        'slug': slug,
        'name': '${slug[0].toUpperCase()}${slug.substring(1)}',
      },
  ];
  final api = Api(
    'http://server',
    'session=x',
    MockClient(
      (r) async => http.Response(
        '[{"id":142,"title":"Write a benchmark","body":"For both.",'
        '"status":"doing","bot":"coder"}]',
        200,
      ),
    ),
  );

  Future<(StreamController<Map<String, dynamic>>, List<String>)> stage(
    WidgetTester t, {
    bool reduce = false,
    List<Map<String, dynamic>>? team,
    String asker = 'researcher',
    Size size = const Size(600, 800),
  }) async {
    final bots = team ?? house;
    final handoffs = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(handoffs.close);
    final opened = <String>[];
    final coder = ThreadView()
      ..apply({'type': 'run_started', 'run': 1, 'resumed': false})
      ..apply({
        'type': 'step_started',
        'run': 1,
        'id': 'a',
        'label': 'Running a command',
        'kind': 'command',
      });
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: reduce),
          child: TeamStage(
            api: api,
            changed: ValueNotifier(0),
            bots: () => bots,
            threads: {'coder': coder},
            open: () => [
              {'id': 142, 'bot': 'coder', 'asked_by': asker, 'blocked': false},
            ],
            handoffs: handoffs.stream,
            onOpen: opened.add,
          ),
        ),
      ),
    );
    return (handoffs, opened);
  }

  double left(WidgetTester t, String slug) =>
      t.getTopLeft(find.byKey(ValueKey(slug))).dx;

  const asked = {
    'type': 'asked',
    'from': 'blogger',
    'to': 'coder',
    'ticket': 143,
  };

  testWidgets('every bot stands in its spot with its state in words', (
    t,
  ) async {
    final (_, opened) = await stage(t);
    final robots = t.widgetList<BotAvatar>(find.byType(BotAvatar)).toList();
    expect(robots.length, 3);
    expect(robots.every((r) => r.body), isTrue);
    // The coder is working at a command, in its robot and in words.
    final coder = robots.firstWhere((r) => r.slug == 'coder');
    expect((coder.mood, coder.doing), (2, 3));
    expect(find.text('Running a command…'), findsOneWidget);
    expect(find.text('Ready'), findsNWidgets(2));
    // Tapping a robot opens its chat.
    await t.tap(find.text('Blogger'));
    expect(opened, ['blogger']);
    // The open hand-off's line has its ticket, which opens it.
    expect(
      find.bySemanticsLabel('Researcher is waiting on Coder, OB-142'),
      findsOneWidget,
    );
    await t.tap(find.text('OB-142'));
    await t.pump();
    await t.pump();
    expect(find.text('OB-142 · Write a benchmark'), findsOneWidget);
    expect(find.text('doing · coder'), findsOneWidget);
  });

  testWidgets('on full, the asker goes across to its teammate and back', (
    t,
  ) async {
    final (handoffs, _) = await stage(t);
    final home = left(t, 'blogger');
    handoffs.add(asked);
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    expect(left(t, 'blogger'), isNot(home));
    // It stands just to the left of the coder, who turns to face it.
    expect(left(t, 'blogger'), lessThan(left(t, 'coder')));
    final coder = t
        .widgetList<BotAvatar>(find.byType(BotAvatar))
        .firstWhere((r) => r.slug == 'coder');
    expect(coder.flip, isTrue);
    await t.pump(const Duration(milliseconds: 1300));
    await t.pump(const Duration(milliseconds: 800));
    expect(left(t, 'blogger'), home);
  });

  testWidgets('on calm, off or reduce-motion nobody travels', (t) async {
    for (final (m, reduce) in [
      (Motion.calm, false),
      (Motion.off, false),
      (Motion.full, true),
    ]) {
      motion.value = m;
      final (handoffs, _) = await stage(t, reduce: reduce);
      final home = left(t, 'blogger');
      handoffs.add(asked);
      await t.pump();
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 100));
        expect(left(t, 'blogger'), home, reason: '$m, reduce $reduce');
      }
      // The line and its ticket are there whatever the setting.
      expect(find.text('OB-142'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an answer to a bot that has no spot moves nobody and breaks '
      'nothing', (t) async {
    final (handoffs, _) = await stage(t);
    final home = left(t, 'coder');
    // A closed mission's chief isn't on the stage, but can still be answered.
    handoffs.add({
      'type': 'answered',
      'from': 'coder',
      'to': 'chief--7',
      'ticket': 9,
      'ok': true,
    });
    await t.pump();
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 100));
      expect(left(t, 'coder'), home);
    }
    expect(t.takeException(), isNull);
  });

  testWidgets("the longest line's ticket stays on the stage", (t) async {
    final eight = [
      for (var i = 0; i < 8; i++)
        <String, dynamic>{'slug': i == 7 ? 'coder' : 'bot$i', 'name': 'Bot $i'},
    ];
    await stage(t, team: eight, asker: 'bot0', size: const Size(1200, 800));
    final ticket = t.getRect(find.text('OB-142'));
    final stageTop = t.getRect(find.byType(SingleChildScrollView)).top;
    expect(ticket.top, greaterThan(stageTop));
    // So it can be tapped.
    await t.tap(find.text('OB-142'));
    await t.pump();
    await t.pump();
    expect(find.text('OB-142 · Write a benchmark'), findsOneWidget);
  });
}
