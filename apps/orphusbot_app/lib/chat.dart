// The main screen: bots down the left, the chosen bot's whole conversation on
// the right (formatted text, pictures and files it shared, approvals to answer),
// and the composer at the bottom.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'api.dart';
import 'thread.dart' as t;

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api, required this.onSignedOut});
  final Api api;
  final VoidCallback onSignedOut;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Map<String, dynamic>> bots = [];
  final threads = <String, t.ThreadView>{};
  String chosen = 'inbox';
  String? problem;
  StreamSubscription<Map<String, dynamic>>? sub;
  final composer = TextEditingController();
  // Files waiting to go with the next message: (name, bytes).
  final pending = <(String, Uint8List)>[];
  static const maxBytes = 10 * 1024 * 1024;
  final scroll = ScrollController();
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final list = await widget.api.get('/api/bots') as List<dynamic>;
      setState(
        () => bots = list
            .cast<Map<String, dynamic>>()
            .where((b) => b['disabled'] != true)
            .toList(),
      );
    } on SignedOut {
      return widget.onSignedOut();
    } catch (e) {
      setState(() => problem = '$e');
    }
    sub = widget.api.events().listen(
      (e) {
        final bot = e['bot'] as String?;
        if (bot == null) return;
        setState(() => threads.putIfAbsent(bot, t.ThreadView.new).apply(e));
        if (bot == chosen) _toBottom();
      },
      onError: (Object e) => e is SignedOut
          ? widget.onSignedOut()
          : setState(() => problem = '$e'),
    );
  }

  @override
  void dispose() {
    sub?.cancel();
    composer.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
  });

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      setState(() => problem = null);
    } on SignedOut {
      widget.onSignedOut();
    } catch (e) {
      setState(() => problem = '$e');
    }
  }

  void _send() {
    final text = composer.text.trim();
    if (text.isEmpty && pending.isEmpty) return;
    final files = List.of(pending);
    final bot = chosen;
    composer.clear();
    setState(pending.clear);
    _act(() async {
      final ids = <int>[];
      for (final (name, bytes) in files) {
        ids.add(await widget.api.upload(bot, name, bytes));
      }
      await widget.api.send(bot, text, attachments: ids);
    });
    focus.requestFocus();
  }

  void _add(String name, Uint8List bytes) {
    final total = pending.fold<int>(bytes.length, (n, f) => n + f.$2.length);
    if (total > maxBytes) {
      setState(() => problem = 'Files sent together can be up to 10 MB.');
    } else if (pending.length >= 10) {
      setState(() => problem = 'Send at most ten files at once.');
    } else {
      setState(() => pending.add((name, bytes)));
    }
  }

  Future<void> _attach() async {
    for (final f in await openFiles()) {
      _add(f.name, await f.readAsBytes());
    }
  }

  /// Ctrl+V: a copied picture becomes an attachment; text pastes as usual.
  Future<void> _paste() async {
    final image = await Pasteboard.image;
    if (image != null) {
      _add('pasted-${DateTime.now().millisecondsSinceEpoch}.png', image);
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null) return;
    final sel = composer.selection;
    final start = sel.isValid ? sel.start : composer.text.length;
    final end = sel.isValid ? sel.end : composer.text.length;
    composer.value = TextEditingValue(
      text: composer.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// Saves bytes where the owner chooses.
  Future<void> _save(String suggested, List<int> Function() bytes) async {
    final where = await getSaveLocation(suggestedName: suggested);
    if (where == null) return;
    await File(where.path).writeAsBytes(bytes());
    setState(() => problem = 'Saved to ${where.path}');
  }

  t.ThreadView get view => threads[chosen] ?? t.ThreadView();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 220, child: _botList(scheme)),
          VerticalDivider(width: 1, color: scheme.outlineVariant),
          Expanded(child: _conversation(scheme)),
        ],
      ),
    );
  }

  Widget _botList(ColorScheme scheme) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            'OrphusBot',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        for (final b in bots)
          Builder(
            builder: (context) {
              final slug = b['slug'] as String;
              final v = threads[slug];
              final waiting = v?.waiting ?? 0;
              final working = v != null && v.run != t.RunState.idle;
              return ListTile(
                selected: slug == chosen,
                selectedTileColor: scheme.primary.withValues(alpha: 0.12),
                title: Text(b['name'] as String),
                subtitle: Text(
                  waiting > 0
                      ? 'needs you'
                      : (working ? 'working…' : (b['remit'] as String? ?? '')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: waiting > 0 ? scheme.error : null),
                ),
                trailing: waiting > 0
                    ? Badge(label: Text('$waiting'))
                    : (working
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null),
                onTap: () {
                  setState(() => chosen = slug);
                  _toBottom();
                  focus.requestFocus();
                },
              );
            },
          ),
      ],
    );
  }

  Widget _conversation(ColorScheme scheme) {
    final v = view;
    final name =
        bots.firstWhere(
              (b) => b['slug'] == chosen,
              orElse: () => {'name': chosen},
            )['name']
            as String;
    return Column(
      children: [
        // Header: who, and what it's doing.
        ListTile(
          title: Text(name, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text(switch (v.run) {
            t.RunState.idle => 'Ready',
            t.RunState.queued =>
              'Waiting${v.where == null ? '' : ': ${v.where}'}',
            t.RunState.running =>
              'Working${v.where == null ? '' : ' ${v.where}'}',
          }),
          trailing: v.run == t.RunState.idle
              ? null
              : OutlinedButton.icon(
                  onPressed: () => _act(() => widget.api.stop(chosen)),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
        ),
        if (problem != null)
          MaterialBanner(
            content: Text(problem!),
            actions: [
              TextButton(
                onPressed: () => setState(() => problem = null),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              if (v.items.isEmpty)
                Center(
                  child: Text(
                    'Say hello to $name.',
                    style: TextStyle(color: scheme.outline),
                  ),
                ),
              for (final item in v.items) _item(item, scheme, name),
              if (v.streaming != null) _bubble(v.streaming!, false, scheme),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        _composer(name),
      ],
    );
  }

  Widget _item(t.Item item, ColorScheme scheme, String name) => switch (item) {
    t.Message(:final mine, :final text) => _bubble(text, mine, scheme),
    t.Notice(:final text, :final error) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          text,
          style: TextStyle(color: error ? scheme.error : scheme.outline),
        ),
      ),
    ),
    t.Artifact() => _artifact(item, scheme),
    t.Attached() => _attached(item, scheme),
    t.Card() => _card(item, scheme, name),
  };

  Widget _bubble(String text, bool mine, ColorScheme scheme) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 720),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: mine
          ? SelectableText(text)
          : MarkdownBlock(
              data: text,
              selectable: true,
              config: dark
                  ? MarkdownConfig.darkConfig
                  : MarkdownConfig.defaultConfig,
            ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          // Copy or save a reply.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Copy',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  setState(() => problem = 'Copied.');
                },
              ),
              if (!mine)
                IconButton(
                  tooltip: 'Save as a file',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.save_alt),
                  onPressed: () =>
                      _save('$chosen-reply.md', () => utf8.encode(text)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// A file the owner sent: pictures show; anything else is a tile.
  Widget _attached(t.Attached a, ColorScheme scheme) {
    final url = widget.api.attachmentUrl(a.id);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: a.image
            ? Image.network(
                url,
                headers: widget.api.headers,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: Text(a.name),
                ),
              )
            : ListTile(
                leading: const Icon(Icons.attach_file),
                title: Text(a.name),
                subtitle: Text('${(a.size / 1024).ceil()} KB'),
              ),
      ),
    );
  }

  /// A file the bot shared: pictures show in the chat; everything opens or saves.
  Widget _artifact(t.Artifact a, ColorScheme scheme) {
    final url = widget.api.artifactUrl(a.id);
    final label =
        '${a.name}${a.version > 1 ? ' (version ${a.version})' : ''} · ${(a.size / 1024).ceil()} KB';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (a.isImage)
              Image.network(
                url,
                headers: widget.api.headers,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text("Couldn't load the picture"),
                ),
              ),
            ListTile(
              leading: Icon(
                a.isImage ? Icons.image_outlined : Icons.description_outlined,
              ),
              title: Text(label),
              trailing: IconButton(
                tooltip: 'Save',
                icon: const Icon(Icons.download),
                onPressed: () => _act(() async {
                  final bytes = await widget.api.download(url);
                  await _save(a.name, () => bytes);
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(t.Card c, ColorScheme scheme, String name) {
    final k = c.kind;
    final title = switch (k['kind']) {
      'approval' => 'Allow $name to use ${k['tool']}?',
      'takeover' => '$name needs you on its screen',
      _ => (k['title'] as String?) ?? 'A question',
    };
    final detail = switch (k['kind']) {
      'approval' => const JsonEncoder.withIndent('  ').convert(k['input']),
      'takeover' => k['reason'] as String? ?? '',
      _ => k['message'] as String? ?? '',
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: c.outcome == null ? scheme.error : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                detail,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
            const SizedBox(height: 10),
            if (c.outcome != null)
              Text(c.outcome!, style: TextStyle(color: scheme.outline))
            else if (c.approval)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => _act(
                      () => widget.api.answer(c.id, {'decision': 'allow'}),
                    ),
                    child: const Text('Allow once'),
                  ),
                  OutlinedButton(
                    onPressed: () => _act(
                      () => widget.api.answer(c.id, {'decision': 'always'}),
                    ),
                    child: Text('Always allow ${k['tool']}'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                    onPressed: () => _act(
                      () => widget.api.answer(c.id, {'decision': 'deny'}),
                    ),
                    child: const Text('Deny'),
                  ),
                ],
              )
            else if (k['kind'] == 'takeover')
              FilledButton(
                onPressed: () =>
                    _act(() => widget.api.answer(c.id, {'confirmed': true})),
                child: const Text("I'm done"),
              )
            else
              _QuestionAnswer(
                options: (k['options'] as List<dynamic>? ?? []).cast<String>(),
                onAnswer: (v) =>
                    _act(() => widget.api.answer(c.id, {'value': v})),
              ),
          ],
        ),
      ),
    );
  }

  Widget _composer(String name) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, (fname, bytes)) in pending.indexed)
                  InputChip(
                    avatar:
                        RegExp(
                          r'\.(png|jpe?g|gif|webp)$',
                          caseSensitive: false,
                        ).hasMatch(fname)
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.memory(
                              bytes,
                              width: 24,
                              height: 24,
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Icon(Icons.attach_file, size: 18),
                    label: Text('$fname · ${(bytes.length / 1024).ceil()} KB'),
                    onDeleted: () => setState(() => pending.removeAt(i)),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            IconButton(
              tooltip: 'Attach pictures or files',
              icon: const Icon(Icons.attach_file),
              onPressed: _attach,
            ),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): _send,
                  const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                      _paste,
                },
                child: TextField(
                  controller: composer,
                  focusNode: focus,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText:
                        'Message $name  (Enter sends, Shift+Enter new line, Ctrl+V pastes pictures)',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _send,
              icon: const Icon(Icons.send),
              label: const Text('Send'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Pick an option, or type an answer.
class _QuestionAnswer extends StatefulWidget {
  const _QuestionAnswer({required this.options, required this.onAnswer});
  final List<String> options;
  final void Function(String) onAnswer;
  @override
  State<_QuestionAnswer> createState() => _QuestionAnswerState();
}

class _QuestionAnswerState extends State<_QuestionAnswer> {
  final text = TextEditingController();
  @override
  Widget build(BuildContext context) => widget.options.isNotEmpty
      ? Wrap(
          spacing: 8,
          children: [
            for (final o in widget.options)
              OutlinedButton(
                onPressed: () => widget.onAnswer(o),
                child: Text(o),
              ),
          ],
        )
      : Row(
          children: [
            Expanded(
              child: TextField(
                controller: text,
                decoration: const InputDecoration(hintText: 'Your answer'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.onAnswer(text.text),
              child: const Text('Answer'),
            ),
          ],
        );
}
