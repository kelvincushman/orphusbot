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
    late List<String> news;
    late OrchestratorLine line;
    // The run the server says carries each message, in order.
    late List<int> runs;
    // Called as the server takes a message, before it answers.
    void Function()? meanwhile;
    late Api api;
    Map<String, dynamic> nodes() => {'type': 'nodes', 'nodes': []};
    Map<String, dynamic> reply(String text) => {
      'type': 'message',
      'role': 'assistant',
      'text': text,
    };
    Map<String, dynamic> ended(int run) => {
      'type': 'run_ended',
      'run': run,
      'outcome': 'completed',
    };
    Map<String, dynamic> approval(int run) => {
      'type': 'dialog_opened',
      'dialog': {
        'id': 'd$run',
        'run': run,
        'kind': {'kind': 'approval', 'tool': 'send_email', 'input': {}},
      },
    };
    setUp(() {
      sent = [];
      news = [];
      runs = [];
      meanwhile = null;
      api = Api(
        'http://server',
        'session=x',
        MockClient((r) async {
          sent.add(jsonDecode(r.body) as Map<String, dynamic>);
          meanwhile?.call();
          return http.Response(jsonEncode({'run': runs.removeAt(0)}), 202);
        }),
      );
      line = OrchestratorLine(inChat: true, name: 'Coder', onNews: news.add);
    });

    test('replayed history is never taken for a new answer', () async {
      // History: an old job that finished, replayed before the current state.
      line.handle(reply('Old.'));
      line.handle(ended(7));
      runs = [8];
      final answer = line.ask(api, 'coder', 'ask', {'request': 'status?'});
      await pumpEventQueue();
      // Nothing is sent until the stream has caught up.
      expect(sent, isEmpty);
      line.handle(nodes());
      await pumpEventQueue();
      expect(sent.single, containsPair('voice', true));
      expect(sent.single.containsKey('work'), isFalse);
      line.handle(reply('New.'));
      line.handle(ended(8));
      expect(await answer, 'New.');
      expect(news, isEmpty);
    });

    test('nothing is sent if the stream never catches up', () async {
      line = OrchestratorLine(
        inChat: true,
        name: 'Coder',
        catchUp: Duration.zero,
      );
      expect(
        await line.ask(api, 'coder', 'ask', {'request': 'status?'}),
        contains("Can't reach Coder"),
      );
      expect(sent, isEmpty);
    });

    test('a question is not steered into another task', () async {
      line.handle(nodes());
      line.handle({'type': 'run_queued', 'run': 3, 'waiting': null});
      expect(
        await line.ask(api, 'coder', 'ask', {'request': 'how is it going?'}),
        contains('busy with another task'),
      );
      expect(sent, isEmpty);
    });

    test('do starts work and the result comes back at a pause', () async {
      line.handle(nodes());
      runs = [1];
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
      line.handle(approval(1));
      expect(news, ['(Coder needs your OK on the screen.)']);
      // Another run's end is not this job's.
      line.handle(ended(5));
      expect(news, hasLength(1));
      line.handle(reply('All green.'));
      line.handle(ended(1));
      expect(news.last, '(Coder has finished: All green.)');
    });

    test('each job reports back, joined or in a run of its own', () async {
      line.handle(nodes());
      // The second job joins the first's run; the third has its own.
      runs = [1, 1, 2];
      await line.ask(api, 'coder', 'do', {'task': 'fix the tests'});
      await line.ask(api, 'coder', 'do', {'task': 'and the lint'});
      line.handle(reply('Tests and lint.'));
      line.handle(ended(1));
      await line.ask(api, 'coder', 'do', {'task': 'then the docs'});
      line.handle(reply('Docs.'));
      line.handle(ended(2));
      expect(news, [
        '(Coder has finished: Tests and lint.)',
        '(Coder has finished: Docs.)',
      ]);
    });

    test('a run that ends before its send returns still reports', () async {
      line.handle(nodes());
      runs = [4];
      meanwhile = () {
        line.handle(reply('Quick one.'));
        line.handle(ended(4));
      };
      await line.ask(api, 'coder', 'do', {'task': 'tiny job'});
      expect(news, ['(Coder has finished: Quick one.)']);
    });

    test('an early end with no reply never borrows an old one', () async {
      line.handle(reply('Old.'));
      line.handle(ended(7));
      line.handle(nodes());
      runs = [8];
      meanwhile = () => line.handle(ended(8));
      expect(
        await line.ask(api, 'coder', 'ask', {'request': 'status?'}),
        "Coder didn't answer.",
      );
    });

    test(
      'a job joining a run that ends before its answer is told once',
      () async {
        line.handle(nodes());
        runs = [1, 1, 2];
        await line.ask(api, 'coder', 'do', {'task': 'fix the tests'});
        meanwhile = () {
          line.handle(reply('Both done.'));
          line.handle(ended(1));
        };
        await line.ask(api, 'coder', 'do', {'task': 'and the lint'});
        meanwhile = null;
        expect(news, ['(Coder has finished: Both done.)']);
        // Nothing is left waiting: the next question goes through.
        final next = line.ask(api, 'coder', 'ask', {
          'request': 'anything else?',
        });
        await pumpEventQueue();
        expect(sent, hasLength(3));
        line.handle(reply('No.'));
        line.handle(ended(2));
        expect(await next, 'No.');
      },
    );

    test('a new run answered before the last one ends both report', () async {
      line.handle(nodes());
      runs = [1, 2];
      await line.ask(api, 'coder', 'do', {'task': 'fix the tests'});
      await line.ask(api, 'coder', 'do', {'task': 'then the docs'});
      line.handle(reply('Tests.'));
      line.handle(ended(1));
      line.handle(reply('Docs.'));
      line.handle(ended(2));
      expect(news, [
        '(Coder has finished: Tests.)',
        '(Coder has finished: Docs.)',
      ]);
    });

    test('a card that opens before the send returns is still told', () async {
      line.handle(nodes());
      runs = [1, 2];
      meanwhile = () => line.handle(approval(1));
      expect(
        await line.ask(api, 'coder', 'ask', {'request': 'send it?'}),
        startsWith('Coder needs your OK on the screen.'),
      );
      line.handle(ended(1));
      meanwhile = () => line.handle(approval(2));
      await line.ask(api, 'coder', 'do', {'task': 'send the rest'});
      expect(news.last, '(Coder needs your OK on the screen.)');
    });

    test('a card answered before the send returns is not told', () async {
      line.handle(nodes());
      runs = [1];
      meanwhile = () {
        line.handle(approval(1));
        line.handle({
          'type': 'dialog_closed',
          'id': 'd1',
          'outcome': 'Allowed once',
        });
      };
      final answer = line.ask(api, 'coder', 'ask', {'request': 'send it?'});
      await pumpEventQueue();
      line.handle(reply('Sent.'));
      line.handle(ended(1));
      expect(await answer, 'Sent.');
    });

    test('ask answers with the reply, or says it needs a tap', () async {
      line.handle(nodes());
      runs = [1, 2];
      final answer = line.ask(api, 'coder', 'ask', {'request': 'status?'});
      await pumpEventQueue();
      line.handle(approval(1));
      expect(await answer, startsWith('Coder needs your OK on the screen.'));
      // Its run is still the question's: a job now would join it on the
      // quick model.
      expect(
        await line.ask(api, 'coder', 'do', {'task': 'and send it'}),
        contains('still on your question'),
      );
      expect(sent, hasLength(1));
      line.handle(reply('Sent.'));
      line.handle(ended(1));
      expect(news, ['(Coder has finished: Sent.)']);

      final next = line.ask(api, 'coder', 'ask', {'request': 'and now?'});
      await pumpEventQueue();
      line.handle(reply('All done.'));
      line.handle(ended(2));
      expect(await next, 'All done.');
      expect(news, hasLength(1));
    });
  });
}
