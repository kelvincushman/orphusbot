import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/avatar.dart';
import 'package:rive/rive.dart' as rive;

void main() {
  // The names BotAvatar relies on (design/bot-avatar/gen.py makes them).
  testWidgets('the avatar file keeps its contract', (t) async {
    await rive.RiveNative.init();
    await t.runAsync(() async {
      final f = (await rive.File.asset(
        'assets/bot-avatar.riv',
        riveFactory: rive.Factory.flutter,
      ))!;
      final c = rive.RiveWidgetController(f);
      expect(c.artboard.name, 'Avatar');
      expect(c.stateMachine.name, 'Bot');
      // ignore: deprecated_member_use
      expect(c.stateMachine.number('state'), isNotNull);
      await t.pumpWidget(const MaterialApp(home: BotAvatar(mood: 3)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pump();
    expect(find.byType(rive.RiveWidget), findsOneWidget);
  });
}
