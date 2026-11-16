// One bot's conversation, folded from events exactly as the server's own
// reducer does it (crates/proto/src/view.rs), so every client agrees.
import 'dart:math';

sealed class Item {}

class Message extends Item {
  Message(this.mine, this.text);
  final bool mine;
  final String text;
}

class Notice extends Item {
  Notice(this.text, {this.error = false});
  final String text;
  final bool error;
}

class Artifact extends Item {
  Artifact(this.id, this.name, this.version, this.size);
  final int id;
  final String name;
  final int version;
  final int size;
  bool get isImage =>
      RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(name);
}

/// A file the owner sent.
class Attached extends Item {
  Attached(this.id, this.name, this.size, this.image);
  final int id;
  final String name;
  final int size;
  final bool image;
}

/// An approval, a question or a takeover the bot is waiting on.
class Card extends Item {
  Card(this.id, this.kind);
  final String id;
  final Map<String, dynamic> kind;
  String? outcome;
  bool get approval => kind['kind'] == 'approval';
}

/// One tool call. `id` is only unique within `run`.
class Step {
  Step(this.run, this.id, this.label, this.kind);
  final int run;
  final String id;
  final String label;

  /// What sort of work it is (read, write, command, …), for the animations.
  final String kind;

  /// How it ended; null while it runs, or if its end was never reported.
  bool? done;
}

/// Tool calls in a row, shown as one line. `open` until another item or the
/// run's end follows; `from` and `to` are its first step's start and the
/// latest thing known about it, in milliseconds.
class Steps extends Item {
  Steps(Step first, this.from) : steps = [first], to = from;
  final List<Step> steps;
  bool open = true;
  final int from;
  int to;

  /// What it's doing while open, then "Worked for 2m 10s · 7 steps".
  String get line {
    final count = steps.length == 1 ? '1 step' : '${steps.length} steps';
    if (open) {
      final now = steps.lastWhere(
        (s) => s.done == null,
        orElse: () => steps.last,
      );
      return '${now.label} · $count';
    }
    final secs = (to - from < 0 ? 0 : to - from) ~/ 1000;
    final took = secs < 60
        ? '${secs}s'
        : secs < 3600
        ? '${secs ~/ 60}m ${secs % 60}s'
        : '${secs ~/ 3600}h ${secs % 3600 ~/ 60}m';
    return 'Worked for $took · $count';
  }
}

enum RunState { idle, queued, running }

class ThreadView {
  final items = <Item>[];
  String? streaming;
  RunState run = RunState.idle;
  String? where;

  // The newest unfinished step.
  Step? _now;

  /// The label of the newest unfinished step.
  String? get doing => _now?.label;

  /// Its kind as the bot faces' `doing` input (design/bot-avatar): 0 other,
  /// 1 read, 2 write, 3 command, 4 browse, 5 search, 6 talk, 7 google,
  /// 8 media, 9 phone.
  int get doingKind => max(0, _kinds.indexOf(_now?.kind ?? 'other'));
  static const _kinds = [
    'other', 'read', 'write', 'command', 'browse', //
    'search', 'talk', 'google', 'media', 'phone',
  ];
  // The last run finished well and nothing has happened since.
  bool done = false;
  // The last run failed and nothing has happened since.
  bool failed = false;

  /// Unfinished hand-offs this bot is waiting on (`/api/team/open`).
  int waitingOn = 0;

  /// The avatar's state (design/bot-avatar): 0 idle, 1 thinking (queued, or
  /// waiting on teammates),
  /// 2 working, 3 needs you, 4 done, 5 failed (it blows itself up, then
  /// stays dizzy).
  int get mood => waiting > 0
      ? 3
      : switch (run) {
          RunState.queued => 1,
          RunState.running => 2,
          RunState.idle => waitingOn > 0 ? 1 : (failed ? 5 : (done ? 4 : 0)),
        };

  int get waiting =>
      items.whereType<Card>().where((c) => c.outcome == null).length;

  String get lastReply {
    for (final i in items.reversed) {
      if (i is Message && !i.mine) return i.text;
    }
    return '';
  }

  void apply(Map<String, dynamic> e) {
    // When it happened, in milliseconds (the envelope's `at`).
    final at = e['at'] as int? ?? 0;
    final before = items.length;
    switch (e['type']) {
      case 'message':
        final mine = e['role'] == 'user';
        if (!mine) streaming = null;
        items.add(Message(mine, e['text'] as String));
      case 'delta':
        streaming = (streaming ?? '') + (e['text'] as String);
      case 'run_queued':
        run = RunState.queued;
        done = false;
        failed = false;
        where = e['waiting'] as String?;
        streaming = null;
        _now = null;
      case 'run_started':
        run = RunState.running;
        done = false;
        failed = false;
        final node = e['node'] as String?;
        where = node == null
            ? null
            : 'on $node${e['why'] == null ? '' : ' (${e['why']})'}';
      case 'run_ended':
        run = RunState.idle;
        where = null;
        _now = null;
        // A run that ends with nothing more to say still ends its steps.
        // Only steps still open: an earlier run's are already timed.
        if (items.lastOrNull case final Steps s when s.open) _close(s, at);
        done = e['outcome'] == 'completed';
        failed = e['outcome'] == 'failed';
        if (streaming != null && streaming!.isNotEmpty) {
          items.add(Message(false, streaming!));
        }
        streaming = null;
        if (e['outcome'] == 'cancelled') items.add(Notice('Stopped.'));
        if (e['outcome'] == 'failed') {
          items.add(
            Notice(
              'The run failed: ${e['error'] ?? 'unknown error'}',
              error: true,
            ),
          );
        }
      case 'notice':
        items.add(Notice(e['text'] as String));
      case 'routed':
        items.add(
          Notice('Sent to ${e['name']} (System 1 was ${e['sure']}% sure)'),
        );
      case 'attached':
        items.add(
          Attached(
            e['id'] as int,
            e['name'] as String,
            e['size'] as int,
            e['image'] as bool,
          ),
        );
      case 'artifact':
        items.add(
          Artifact(
            e['id'] as int,
            e['name'] as String,
            e['version'] as int,
            e['size'] as int,
          ),
        );
      case 'dialog_opened':
        final d = e['dialog'] as Map<String, dynamic>;
        items.add(Card(d['id'] as String, d['kind'] as Map<String, dynamic>));
      case 'dialog_closed':
        for (final c in items.whereType<Card>()) {
          if (c.id == e['id']) c.outcome = e['outcome'] as String;
        }
      case 'step_started':
        final step = Step(
          e['run'] as int,
          e['id'] as String,
          e['label'] as String,
          e['kind'] as String? ?? 'other',
        );
        _now = step;
        if (items.lastOrNull case final Steps s when s.open) {
          s.steps.add(step);
          if (at > s.to) s.to = at;
        } else {
          items.add(Steps(step, at));
        }
      case 'step_ended':
        bool same(Step s) => s.run == e['run'] && s.id == e['id'];
        // Not only the last fold-up: an approval card may sit between a
        // step's start and its end.
        for (final s in items.reversed.whereType<Steps>()) {
          final step = s.steps.where(same).firstOrNull;
          if (step == null) continue;
          step.done = e['ok'] as bool;
          if (at > s.to) s.to = at;
          break;
        }
        _now = items.reversed
            .whereType<Steps>()
            .expand((s) => s.steps.reversed)
            .where((s) => s.run == e['run'] && s.done == null)
            .firstOrNull;
    }
    // Whatever comes after a fold-up closes it to new steps.
    if (items.length > before && before > 0) {
      if (items[before - 1] case final Steps s when s.open) _close(s, at);
    }
  }

  void _close(Steps s, int at) {
    s.open = false;
    if (at > s.to) s.to = at;
  }
}
