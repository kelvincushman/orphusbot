import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orphusbot_app/live_voice.dart';
import 'package:orphusbot_app/room.dart';

void main() {
  test('each moment of the conversation has its look and sound', () {
    expect(phaseOf(LiveState.hearing), Phase.listening);
    expect(phaseOf(LiveState.researching), Phase.researching);
    expect(phaseOf(LiveState.closed), Phase.idle);
    expect(cueFor(Phase.thinking), 'assets/sounds/thinking.mp3');
    expect(cueFor(Phase.researching), 'assets/sounds/research.mp3');
    expect(cueFor(Phase.speaking), isNull);
    expect(cueFor(Phase.listening), isNull);
  });

  test('the orb follows Grok and the mic from raw PCM', () {
    Uint8List pcm(int amplitude) {
      final b = ByteData(480 * 2);
      for (var i = 0; i < 480; i++) {
        b.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
      }
      return b.buffer.asUint8List();
    }

    expect(pcmLevel(pcm(0)), 0);
    expect(pcmLevel(Uint8List(0)), 0);
    expect(pcmLevel(pcm(1000)), closeTo(0.153, 0.01));
    expect(pcmLevel(pcm(32000)), 1);
  });

  testWidgets('the rating card returns a thumb and a note', (t) async {
    (int, String)? got;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () async => got = await showModalBottomSheet(
              context: c,
              builder: (_) => const RateSession(),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
          .onPressed,
      isNull,
    );
    await t.tap(find.byIcon(Icons.thumb_up_alt_outlined));
    await t.enterText(find.byType(TextField), 'More depth next time');
    await t.pump();
    await t.tap(find.text('Send'));
    await t.pumpAndSettle();
    expect(got, (1, 'More depth next time'));
  });
}
