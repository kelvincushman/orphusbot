import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/thread.dart';

void main() {
  test('folds a run the way the server does', () {
    final v = ThreadView();
    expect(v.mood, 0);
    v.apply({'type': 'message', 'role': 'user', 'text': 'write a file'});
    v.apply({'type': 'run_queued', 'run': 1, 'waiting': null});
    expect(v.mood, 1);
    v.apply({
      'type': 'run_started',
      'run': 1,
      'resumed': false,
      'node': 'gpu-box',
      'why': 'least busy machine',
    });
    expect(v.run, RunState.running);
    expect(v.where, 'on gpu-box (least busy machine)');
    expect(v.mood, 2);
    v.apply({
      'type': 'dialog_opened',
      'dialog': {
        'id': 'd1',
        'run': 1,
        'kind': {
          'kind': 'approval',
          'tool': 'write',
          'input': {},
          'uncertain': false,
        },
      },
    });
    expect(v.waiting, 1);
    expect(v.mood, 3);
    v.apply({'type': 'dialog_closed', 'id': 'd1', 'outcome': 'Allowed once'});
    expect(v.waiting, 0);
    v.apply({'type': 'delta', 'run': 1, 'text': 'Done'});
    v.apply({
      'type': 'artifact',
      'id': 7,
      'name': 'chart.PNG',
      'version': 2,
      'size': 2048,
    });
    v.apply({
      'type': 'message',
      'role': 'assistant',
      'text': 'Done: I wrote it.',
    });
    expect(v.streaming, isNull);
    v.apply({'type': 'run_ended', 'run': 1, 'outcome': 'completed'});
    expect(v.run, RunState.idle);
    expect(v.mood, 4);
    expect(v.lastReply, 'Done: I wrote it.');
    expect(v.items.whereType<Artifact>().single.isImage, isTrue);
  });

  test('files the owner sent are items', () {
    final v = ThreadView();
    v.apply({
      'type': 'attached',
      'id': 3,
      'name': 'plan.png',
      'size': 9000,
      'image': true,
    });
    final a = v.items.single as Attached;
    expect((a.id, a.name, a.image), (3, 'plan.png', true));
  });

  test('a failed run keeps what streamed and says why', () {
    final v = ThreadView();
    v.apply({'type': 'delta', 'run': 2, 'text': 'Half an ans'});
    v.apply({
      'type': 'run_ended',
      'run': 2,
      'outcome': 'failed',
      'error': 'rate limited',
    });
    expect((v.items[0] as Message).text, 'Half an ans');
    expect((v.items[1] as Notice).text, 'The run failed: rate limited');
    expect((v.items[1] as Notice).error, isTrue);
    expect(v.mood, 5, reason: 'it blows itself up');
    v.apply({'type': 'run_queued', 'run': 3});
    expect(v.mood, 1, reason: 'and pulls itself together for the next go');
  });

  // The same cases as crates/proto/src/view.rs.
  group('steps', () {
    Map<String, dynamic> start(int run, String id, String label, int at) => {
      'type': 'step_started',
      'run': run,
      'id': id,
      'label': label,
      'kind': 'other',
      'at': at,
    };
    Map<String, dynamic> end(int run, String id, bool ok, int at) => {
      'type': 'step_ended',
      'run': run,
      'id': id,
      'ok': ok,
      'at': at,
    };

    test('steps in a row fold into one line', () {
      final v = ThreadView()
        ..apply(start(1, 'a', 'Reading a file', 1000))
        ..apply(end(1, 'a', true, 2000))
        ..apply(start(1, 'b', 'Running a command', 3000));
      expect(v.items, hasLength(1));
      expect(v.doing, 'Running a command');
      final steps = v.items.single as Steps;
      expect(steps.line, 'Running a command · 2 steps');
      v.apply(end(1, 'b', false, 4000));
      expect(v.doing, isNull);
      expect(steps.steps.map((s) => s.done), [true, false]);
      expect(steps.open, isTrue);
    });

    test('another item closes the fold-up; the next step starts a new one', () {
      final v = ThreadView()
        ..apply(start(1, 'a', 'Reading a file', 1000))
        ..apply(end(1, 'a', true, 2000))
        ..apply({
          'type': 'message',
          'role': 'assistant',
          'text': 'Found it.',
          'at': 3000,
        })
        ..apply(start(1, 'b', 'Writing a file', 4000));
      expect(v.items, hasLength(3));
      expect((v.items[0] as Steps).line, 'Worked for 2s · 1 step');
      expect((v.items[2] as Steps).line, 'Writing a file · 1 step');
    });

    test('a step that needed approval ends behind its card', () {
      final v = ThreadView()
        ..apply(start(1, 'a', 'Running a command', 1000))
        ..apply({
          'type': 'dialog_opened',
          'at': 2000,
          'dialog': {
            'id': 'd',
            'run': 1,
            'kind': {'kind': 'approval', 'tool': 'bash', 'input': {}},
          },
        });
      final steps = v.items.first as Steps;
      expect(v.doing, 'Running a command');
      // The same call id in another run is another step.
      v.apply(end(2, 'a', true, 3000));
      expect(steps.steps.single.done, isNull);
      v.apply(end(1, 'a', true, 131000));
      expect(v.doing, isNull);
      expect(steps.steps.single.done, isTrue);
      expect(steps.line, 'Worked for 2m 10s · 1 step');
    });

    test('a denied call fails and the step before it shows again', () {
      final v = ThreadView()
        ..apply(start(1, 'a', 'Reading a file', 1000))
        ..apply(start(1, 'b', 'Running a command', 2000))
        ..apply(end(1, 'b', false, 3000));
      expect(v.doing, 'Reading a file');
      expect((v.items.single as Steps).steps[1].done, isFalse);
    });

    test('a run that ends mid-step closes the fold-up', () {
      final v = ThreadView()
        ..apply(start(1, 'a', 'Running a command', 1000))
        ..apply({
          'type': 'run_ended',
          'run': 1,
          'outcome': 'completed',
          'at': 2000,
        });
      expect(v.doing, isNull);
      final steps = v.items.single as Steps;
      expect(steps.steps.single.done, isNull);
      expect(steps.line, 'Worked for 1s · 1 step');
      // A later run that ends without adding anything doesn't stretch it.
      v.apply({
        'type': 'run_ended',
        'run': 2,
        'outcome': 'completed',
        'at': 62000,
      });
      expect((v.items.single as Steps).line, 'Worked for 1s · 1 step');
      v.apply(start(3, 'a', 'Reading a file', 70000));
      expect(v.items, hasLength(2));
    });

    test('the kind of the current step drives the face', () {
      final v = ThreadView()
        ..apply({...start(1, 'a', 'Reading a file', 1000), 'kind': 'read'});
      expect(v.doingKind, 1);
      v.apply({...start(1, 'b', 'Odd', 1500), 'kind': 'something-new'});
      expect(v.doingKind, 0);
      v.apply({
        'type': 'run_ended',
        'run': 1,
        'outcome': 'completed',
        'at': 2000,
      });
      expect(v.doingKind, 0);
    });

    test('an end that matches no step leaves the line and the face alone', () {
      final v = ThreadView()
        ..apply({...start(1, 'a', 'Reading a file', 1000), 'kind': 'read'})
        ..apply(end(2, 'a', true, 1500));
      expect(v.doing, 'Reading a file');
      expect(v.doingKind, 1);
    });

    test('long work is told in hours', () {
      final v = ThreadView()
        ..apply(start(1, 'a', 'Working', 0))
        ..apply({'type': 'notice', 'text': 'x', 'at': 3725000});
      expect((v.items.first as Steps).line, 'Worked for 1h 2m · 1 step');
    });
  });

  Map<String, dynamic> asked(int ticket) => {
    'type': 'asked',
    'from': 'researcher',
    'to': 'coder',
    'ticket': ticket,
  };
  Map<String, dynamic> answered(int ticket, bool ok) => {
    'type': 'answered',
    'from': 'coder',
    'to': 'researcher',
    'ticket': ticket,
    'ok': ok,
  };
  // The hand-off lines, with the slugs standing in for names.
  List<String> handoffs(ThreadView v) => [
    for (final i in v.items)
      if (i is Asked) i.line((s) => s) else if (i is Answered) i.line((s) => s),
  ];

  // The same cases as the server's reducer (crates/proto/src/view.rs).
  test('an answer settles the ask with its ticket and no other', () {
    final v = ThreadView()
      ..apply(asked(142))
      ..apply(asked(143))
      ..apply(answered(143, true));
    expect(handoffs(v), [
      'researcher asked coder · OB-142 · waiting',
      'researcher asked coder · OB-143',
      'coder answered researcher · OB-143',
    ]);
  });

  test('an answer that never comes leaves the ask waiting', () {
    final v = ThreadView()
      ..apply(asked(142))
      ..apply({'type': 'run_ended', 'run': 1, 'outcome': 'completed'});
    expect(handoffs(v), ['researcher asked coder · OB-142 · waiting']);
  });

  test('a teammate that failed answers not ok; a lone answer still shows', () {
    final v = ThreadView()
      ..apply(asked(142))
      ..apply(answered(142, false))
      ..apply(answered(7, true));
    expect(handoffs(v), [
      'researcher asked coder · OB-142',
      "coder couldn't finish for researcher · OB-142",
      'coder answered researcher · OB-7',
    ]);
  });

  test('a denied ask is a failed step and no hand-off', () {
    final v = ThreadView()
      ..apply({
        'type': 'step_started',
        'run': 1,
        'id': 'a',
        'label': 'Checking with Coder',
        'kind': 'talk',
      })
      ..apply({'type': 'step_ended', 'run': 1, 'id': 'a', 'ok': false});
    expect(handoffs(v), isEmpty);
    expect((v.items.single as Steps).steps.single.done, isFalse);
  });

  test('a hand-off plays only when it arrives live', () {
    final v = ThreadView()
      ..apply(asked(142))
      ..apply(answered(142, true), live: true);
    expect((v.items[0] as Asked).play, isFalse);
    expect((v.items[1] as Answered).play, isTrue);
  });
}
