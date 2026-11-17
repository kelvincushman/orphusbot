import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:orphusbot_app/api.dart';
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

  testWidgets('the chat panel closes only once what was said is sent', (
    t,
  ) async {
    var sends = 0;
    var closed = false;
    final api = Api(
      'http://server',
      'session=x',
      MockClient((r) async {
        // The event stream stays open and quiet.
        if (r.url.path == '/api/events') {
          return Completer<http.Response>().future;
        }
        if (r.url.path != '/api/messages') return http.Response('', 500);
        return http.Response('', ++sends == 1 ? 500 : 204);
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IdeasRoom(api: api, onClose: () => closed = true),
        ),
      ),
    );
    await t.pump();
    // The session has already dropped, with a conversation not yet in the chat.
    final room = t.state(find.byType(IdeasRoom)) as dynamic;
    room.setState(() {
      room.live = null;
      room.phase = Phase.idle;
    });
    room.transcript.addAll(['You: hello', 'Grok: hi']);
    await t.pump();

    await t.tap(find.byIcon(Icons.close));
    await t.pump();
    await t.pump();
    expect(sends, 1);
    expect(closed, isFalse);
    expect(find.textContaining('Not sent to the chat yet'), findsOneWidget);
    expect(room.transcript, hasLength(2));
    // There is a way out if sending keeps failing.
    expect(find.text('Close without sending'), findsOneWidget);

    await t.tap(find.byIcon(Icons.close));
    await t.pump();
    await t.pump();
    expect(sends, 2);
    expect(closed, isTrue);
  });

  group('a call with a bot', () {
    late List<Map<String, dynamic>> sent;
    late Api api;
    late List<String> news;
    late OrchestratorLine line;
    Map<String, dynamic> approval() => {
      'type': 'dialog_opened',
      'dialog': {
        'id': 'd1',
        'run': 1,
        'kind': {'kind': 'approval', 'tool': 'send_email', 'input': {}},
      },
    };
    setUp(() {
      sent = [];
      news = [];
      api = Api(
        'http://server',
        'session=x',
        MockClient((r) async {
          sent.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response('', 202);
        }),
      );
      line = OrchestratorLine(inChat: true, name: 'Coder', onNews: news.add);
    });

    test('replayed history is never taken for a new answer', () async {
      // History: an old job that finished, replayed before the current state.
      line.handle({'type': 'message', 'role': 'assistant', 'text': 'Old.'});
      line.handle({'type': 'run_ended', 'run': 1, 'outcome': 'completed'});
      final answer = line.ask(api, 'coder', 'ask', {'request': 'status?'});
      await pumpEventQueue();
      // Nothing is sent until the stream has caught up.
      expect(sent, isEmpty);
      line.handle({'type': 'nodes', 'nodes': []});
      await pumpEventQueue();
      expect(sent, hasLength(1));
      line.handle({'type': 'message', 'role': 'assistant', 'text': 'New.'});
      line.handle({'type': 'run_ended', 'run': 2, 'outcome': 'completed'});
      expect(await answer, 'New.');
      expect(news, isEmpty);
    });

    test('a question is not steered into another task', () async {
      line.handle({'type': 'nodes', 'nodes': []});
      line.handle({'type': 'run_queued', 'run': 3, 'waiting': null});
      expect(
        await line.ask(api, 'coder', 'ask', {'request': 'how is it going?'}),
        contains('busy with another task'),
      );
      expect(sent, isEmpty);
    });

    test('do starts work and the result comes back at a pause', () async {
      line.handle({'type': 'nodes', 'nodes': []});
      final out = await line.ask(api, 'coder', 'do', {'task': 'fix the tests'});
      expect(out, startsWith('Started.'));
      expect(sent.single, containsPair('voice', true));
      expect(sent.single, containsPair('work', true));
      // A question would wait behind the job, so the voice is told at once.
      expect(
        await line.ask(api, 'coder', 'ask', {'request': 'how long?'}),
        contains('still on the job'),
      );
      expect(sent, hasLength(1));
      // A card is left to a tap: the voice only hears that it's waiting.
      line.handle(approval());
      expect(news, ['(Coder needs your OK on the screen.)']);
      line.handle({
        'type': 'message',
        'role': 'assistant',
        'text': 'All green.',
      });
      line.handle({'type': 'run_ended', 'run': 1, 'outcome': 'completed'});
      expect(news.last, '(Coder has finished: All green.)');
    });

    test('ask answers with the reply, or says it needs a tap', () async {
      line.handle({'type': 'nodes', 'nodes': []});
      final answer = line.ask(api, 'coder', 'ask', {'request': 'status?'});
      await pumpEventQueue();
      expect(sent.single, containsPair('voice', true));
      expect(sent.single.containsKey('work'), isFalse);
      // A job now would join the question's run, on the quick model.
      expect(
        await line.ask(api, 'coder', 'do', {'task': 'and send it'}),
        contains('still answering'),
      );
      expect(sent, hasLength(1));
      line.handle(approval());
      expect(await answer, startsWith('Coder needs your OK on the screen.'));
      line.handle({'type': 'message', 'role': 'assistant', 'text': 'Sent.'});
      line.handle({'type': 'run_ended', 'run': 1, 'outcome': 'completed'});
      expect(news, ['(Coder has finished: Sent.)']);

      final next = line.ask(api, 'coder', 'ask', {'request': 'and now?'});
      await pumpEventQueue();
      line.handle({
        'type': 'message',
        'role': 'assistant',
        'text': 'All done.',
      });
      line.handle({'type': 'run_ended', 'run': 2, 'outcome': 'completed'});
      expect(await next, 'All done.');
      expect(news, hasLength(1));
    });
  });
}
