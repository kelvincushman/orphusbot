import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/avatar.dart';
import 'package:orphusbot_app/handoff.dart';
import 'package:orphusbot_app/motion.dart';
import 'package:orphusbot_app/settings.dart';

const line = 'Researcher asked Coder · OB-142';

Widget strip({required bool play, VoidCallback? onOpen, bool reduce = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(
          body: HandoffStrip(
            asker: 'researcher',
            teammate: 'coder',
            line: line,
            answer: false,
            ok: true,
            play: play,
            onOpen: onOpen ?? () {},
          ),
        ),
      ),
    );

void main() {
  tearDown(() => motion.value = Motion.full);

  testWidgets('from history the strip rests as a line that opens the ticket', (
    t,
  ) async {
    var opened = 0;
    await t.pumpWidget(strip(play: false, onOpen: () => opened++));
    expect(find.text(line), findsOneWidget);
    expect(find.byType(BotAvatar), findsNothing);
    // Nothing is waiting to move.
    await t.pump(const Duration(seconds: 5));
    expect(find.byType(BotAvatar), findsNothing);
    await t.tap(find.text(line));
    expect(opened, 1);
  });

  testWidgets('arriving live it plays once with its line, then rests', (
    t,
  ) async {
    await t.pumpWidget(strip(play: true));
    // The two faces, and the words from the first frame.
    expect(find.byType(BotAvatar), findsNWidgets(2));
    expect(find.text(line), findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
    // Mid-flight the note is showing.
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 450));
    expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    await t.pump(const Duration(seconds: 3));
    expect(find.byType(BotAvatar), findsNothing);
    expect(find.text(line), findsOneWidget);
    // Built again (the list rebuilds on every event) it stays at rest.
    await t.pumpWidget(strip(play: true));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(BotAvatar), findsNothing);
  });

  testWidgets('with animation off a live strip is the plain line', (t) async {
    motion.value = Motion.off;
    await t.pumpWidget(strip(play: true));
    expect(find.byType(BotAvatar), findsNothing);
    expect(find.text(line), findsOneWidget);
  });

  testWidgets('reduce-motion makes full calm: the note never flies', (t) async {
    late Motion applied;
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (c) {
            applied = motionOf(c);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(applied, Motion.calm);

    await t.pumpWidget(strip(play: true, reduce: true));
    // The faces still react, so the strip shows, but nothing crosses it.
    expect(find.byType(BotAvatar), findsNWidgets(2));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 100));
      expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 0);
    }
    await t.pump(const Duration(seconds: 3));
    expect(find.byType(BotAvatar), findsNothing);

    // It only ever makes things calmer: off stays off.
    motion.value = Motion.off;
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (c) {
            applied = motionOf(c);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(applied, Motion.off);
  });

  testWidgets('the Animation setting chooses full, calm or off', (t) async {
    Widget setting({bool reduce = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: const Scaffold(body: MotionSetting()),
      ),
    );
    await t.pumpWidget(setting());
    expect(motion.value, Motion.full);
    expect(find.textContaining('cross the Team stage'), findsOneWidget);
    await t.tap(find.text('Calm'));
    await t.pump();
    expect(motion.value, Motion.calm);
    expect(find.textContaining('no idle fidgets'), findsOneWidget);
    await t.tap(find.text('Off'));
    await t.pump();
    expect(motion.value, Motion.off);
    expect(find.text('Still faces and plain lines.'), findsOneWidget);
    // Full, on a system that asks for less motion, says why it's calm.
    await t.tap(find.text('Full'));
    await t.pumpWidget(setting(reduce: true));
    await t.pump();
    expect(motion.value, Motion.full);
    expect(find.textContaining('asks for less motion'), findsOneWidget);
    // Let the "couldn't save" notes (no app folder in a test) time out.
    await t.pump(const Duration(seconds: 30));
  });
}
