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
}
