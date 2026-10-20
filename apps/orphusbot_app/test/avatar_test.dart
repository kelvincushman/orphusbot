import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/avatar.dart';
import 'package:rive/rive.dart' as rive;

void main() {
  // The names BotAvatar relies on (design/bot-avatar/gen.py makes them).
  testWidgets('every face keeps the contract', (t) async {
    await rive.RiveNative.init();
    await t.runAsync(() async {
      final faces = io.Directory('assets/faces').listSync();
      expect(faces.map((f) => f.path), contains('assets/faces/default.riv'));
      for (final path in faces.map((f) => f.path)) {
        final f = (await rive.File.asset(
          path,
          riveFactory: rive.Factory.flutter,
        ))!;
        final c = rive.RiveWidgetController(f);
        expect(c.artboard.name, 'Avatar', reason: path);
        expect(c.stateMachine.name, 'Bot', reason: path);
        // ignore: deprecated_member_use
        expect(c.stateMachine.number('state'), isNotNull, reason: path);
        // ignore: deprecated_member_use
        expect(c.stateMachine.trigger('poke'), isNotNull, reason: path);
        final body = rive.RiveWidgetController(
          f,
          artboardSelector: rive.ArtboardSelector.byName('Robot'),
        );
        expect(body.artboard.name, 'Robot', reason: path);
        expect(body.stateMachine.name, 'Bot', reason: path);
        // ignore: deprecated_member_use
        expect(body.stateMachine.trigger('poke'), isNotNull, reason: path);
      }
      // A bot without its own style gets the default face.
      expect(await faceFile('someone-new'), isNotNull);
      await t.pumpWidget(
        const MaterialApp(home: BotAvatar(slug: 'inbox', mood: 3)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pump();
    expect(find.byType(rive.RiveWidget), findsOneWidget);
  });
}
