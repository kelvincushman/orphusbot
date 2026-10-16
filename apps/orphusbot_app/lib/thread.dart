// One bot's conversation, folded from events exactly as the server's own
// reducer does it (crates/proto/src/view.rs), so every client agrees.

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
  bool get isImage => RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(name);
}

/// An approval, a question or a takeover the bot is waiting on.
class Card extends Item {
  Card(this.id, this.kind);
  final String id;
  final Map<String, dynamic> kind;
  String? outcome;
  bool get approval => kind['kind'] == 'approval';
}

enum RunState { idle, queued, running }

class ThreadView {
  final items = <Item>[];
  String? streaming;
  RunState run = RunState.idle;
  String? where;

  int get waiting => items.whereType<Card>().where((c) => c.outcome == null).length;

  String get lastReply {
    for (final i in items.reversed) {
      if (i is Message && !i.mine) return i.text;
    }
    return '';
  }

  void apply(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'message':
        final mine = e['role'] == 'user';
        if (!mine) streaming = null;
        items.add(Message(mine, e['text'] as String));
      case 'delta':
        streaming = (streaming ?? '') + (e['text'] as String);
      case 'run_queued':
        run = RunState.queued;
        where = e['waiting'] as String?;
        streaming = null;
      case 'run_started':
        run = RunState.running;
        final node = e['node'] as String?;
        where = node == null ? null : 'on $node${e['why'] == null ? '' : ' (${e['why']})'}';
      case 'run_ended':
        run = RunState.idle;
        where = null;
        if (streaming != null && streaming!.isNotEmpty) items.add(Message(false, streaming!));
        streaming = null;
        if (e['outcome'] == 'cancelled') items.add(Notice('Stopped.'));
        if (e['outcome'] == 'failed') {
          items.add(Notice('The run failed: ${e['error'] ?? 'unknown error'}', error: true));
        }
      case 'notice':
        items.add(Notice(e['text'] as String));
      case 'routed':
        items.add(Notice('Sent to ${e['name']} (System 1 was ${e['sure']}% sure)'));
      case 'artifact':
        items.add(Artifact(e['id'] as int, e['name'] as String, e['version'] as int, e['size'] as int));
      case 'dialog_opened':
        final d = e['dialog'] as Map<String, dynamic>;
        items.add(Card(d['id'] as String, d['kind'] as Map<String, dynamic>));
      case 'dialog_closed':
        for (final c in items.whereType<Card>()) {
          if (c.id == e['id']) c.outcome = e['outcome'] as String;
        }
    }
  }
}
