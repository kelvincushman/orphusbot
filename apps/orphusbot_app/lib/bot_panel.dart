// A bot's panel, opened from its pill at the top of the chat (DESIGN §5.6):
// Soul (its instructions), Notes (its own standing notes, which it also keeps
// itself) and Can do (what it is told it can do, read only).
import 'package:flutter/material.dart';

import 'api.dart';

/// 2340 → "2,340".
String grouped(int n) =>
    '$n'.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

/// Where the part of [text] a run isn't told begins: after [cap] characters,
/// counted as the server counts them (code points, not UTF-16 units).
int loadedEnd(String text, int cap) {
  var end = 0, seen = 0;
  for (final rune in text.runes) {
    if (seen == cap) break;
    end += rune > 0xFFFF ? 2 : 1;
    seen++;
  }
  return end;
}

/// The count under the notes: "340 of 2,000 loaded", and what the grey means
/// once they are longer than a run is told.
String notesCount(String text, int cap) {
  final total = text.runes.length;
  final count = '${grouped(total)} of ${grouped(cap)} loaded';
  return total > cap
      ? '$count · the grey part is left out of runs until the notes are tidied'
      : count;
}

/// Shows the notes with everything past [cap] characters greyed.
class NotesController extends TextEditingController {
  NotesController({super.text});
  int cap = 2000;
  Color grey = Colors.grey;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final end = loadedEnd(text, cap);
    if (end >= text.length) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: text.substring(0, end)),
        TextSpan(
          text: text.substring(end),
          style: TextStyle(color: grey),
        ),
      ],
    );
  }
}

/// Pops true if the bot's instructions were saved, so the chat reloads it.
class BotPanel extends StatefulWidget {
  const BotPanel({super.key, required this.api, required this.bot});
  final Api api;
  final Map<String, dynamic> bot;

  @override
  State<BotPanel> createState() => _BotPanelState();
}

class _BotPanelState extends State<BotPanel> {
  late Map<String, dynamic> bot = widget.bot;
  late final soul = TextEditingController(text: bot['instructions'] as String?);
  final notes = NotesController();
  // What the server holds, to tell an unsaved edit from a saved one.
  String savedNotes = '';
  int version = 0;
  String canDo = '';
  bool loading = true;
  // A save of the notes is on its way: Reload and Save wait for it, so an
  // older answer can't land on top of what was just saved.
  bool saving = false;
  bool savingSoul = false;
  bool soulSaved = false;
  String? notesProblem;
  String? soulProblem;

  String get _path => '/api/bots/${bot['slug']}/notes';
  bool get _soulDirty => soul.text != (bot['instructions'] as String? ?? '');
  bool get _notesDirty => notes.text != savedNotes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    soul.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // The editor is hidden while this is asked, so nothing typed meanwhile
    // can be replaced by the answer.
    if (!loading) setState(() => loading = true);
    try {
      final got = await widget.api.get(_path) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        savedNotes = got['notes'] as String? ?? '';
        notes.text = savedNotes;
        notes.cap = (got['loaded_chars'] as num?)?.toInt() ?? notes.cap;
        version = (got['version'] as num?)?.toInt() ?? 0;
        canDo = got['can_do'] as String? ?? '';
        loading = false;
        notesProblem = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          notesProblem = explain(e);
        });
      }
    }
  }

  Future<void> _saveNotes() async {
    // What is sent, not what is in the box when the answer comes: an edit
    // typed while the save is on its way stays unsaved, and says so.
    final sent = notes.text;
    setState(() => saving = true);
    try {
      // With the version this panel loaded: the server refuses the save if the
      // bot changed its notes meanwhile, rather than losing what it wrote.
      final got = await widget.api.putJson(_path, {
        'notes': sent,
        'version': version,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        savedNotes = sent;
        version = (got['version'] as num).toInt();
        notesProblem = null;
        saving = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          notesProblem = explain(e);
          saving = false;
        });
      }
    }
  }

  /// Reload replaces what's in the box, so an unsaved edit asks first.
  Future<void> _reload() async {
    if (_notesDirty) {
      final drop = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Reload and lose your changes?'),
          content: const Text("Your changes to the notes haven't been saved."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Reload'),
            ),
          ],
        ),
      );
      if (drop != true || !mounted) return;
    }
    await _load();
  }

  Future<void> _saveSoul() async {
    // What is sent, not what is in the box when the answers come: an edit
    // typed meanwhile stays unsaved. One save at a time, so two can't land
    // out of order.
    final sent = soul.text;
    setState(() => savingSoul = true);
    try {
      // The bot as it is now, not as it was when this opened: the update
      // writes every setting, and one changed elsewhere meanwhile must stay.
      final now = (await widget.api.get('/api/bots') as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((b) => b['slug'] == bot['slug'], orElse: () => bot);
      final edited = {...now, 'instructions': sent};
      await widget.api.post('/api/bots/update', edited);
      if (!mounted) return;
      setState(() {
        bot = edited;
        soulSaved = true;
        soulProblem = null;
        savingSoul = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          soulProblem = explain(e);
          savingSoul = false;
        });
      }
    }
  }

  /// Closing with an edit that isn't saved asks first.
  Future<void> _close() async {
    if (_soulDirty || _notesDirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Leave without saving?'),
          content: const Text("Your changes here haven't been saved."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Leave'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    if (mounted) Navigator.pop(context, soulSaved);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    notes.grey = scheme.outline;
    Widget heading(String title, String about) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text(title, style: text.titleMedium)),
          Text(about, style: text.bodySmall?.copyWith(color: scheme.outline)),
        ],
      ),
    );
    Widget problem(String? what) => what == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(what, style: TextStyle(color: scheme.error)),
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _close();
      },
      child: Scaffold(
        appBar: AppBar(title: Text('${bot['name']}')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            heading('Soul', 'Its instructions: who it is and how it works.'),
            TextField(
              key: const ValueKey('soul'),
              controller: soul,
              maxLength: 8000,
              minLines: 4,
              maxLines: 12,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Instructions',
                alignLabelWithHint: true,
              ),
            ),
            problem(soulProblem),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('save-soul'),
                onPressed: _soulDirty && !savingSoul ? _saveSoul : null,
                child: const Text('Save instructions'),
              ),
            ),
            heading(
              'Notes',
              'Its own short notes on how you like it to work. It adds to them '
                  'when you correct it, and you can edit them here. The start '
                  'is loaded into every run.',
            ),
            if (loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              TextField(
                key: const ValueKey('notes'),
                controller: notes,
                minLines: 4,
                maxLines: 16,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                  helperText: notesCount(notes.text, notes.cap),
                  helperMaxLines: 3,
                ),
              ),
              problem(notesProblem),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('reload-notes'),
                    onPressed: saving ? null : _reload,
                    child: const Text('Reload'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('save-notes'),
                    onPressed: _notesDirty && !saving ? _saveNotes : null,
                    child: const Text('Save notes'),
                  ),
                ],
              ),
              heading(
                'Can do',
                'What it is told it can do. Change it in Settings.',
              ),
              SelectableText(canDo.isEmpty ? 'Not known.' : canDo),
            ],
          ],
        ),
      ),
    );
  }
}
