// Discussions (DESIGN §11.4): pick bots and a question; they deliberate in an
// Orphus room, round by round, and a chair writes the verdict. The room shows
// here as it happens, each post with its bot's face.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'api.dart';
import 'avatar.dart';
import 'chat.dart' show markdownConfig;

/// Every discussion, newest first, and a button to start one.
class DiscussionsScreen extends StatefulWidget {
  const DiscussionsScreen({super.key, required this.api, required this.bots});
  final Api api;
  final List<Map<String, dynamic>> bots;
  @override
  State<DiscussionsScreen> createState() => _DiscussionsScreenState();
}

class _DiscussionsScreenState extends State<DiscussionsScreen> {
  List<dynamic> list = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final got = await widget.api.get('/api/discussions') as List;
      if (mounted) setState(() => list = got);
    } catch (_) {}
  }

  void _open(int id) => Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (_) =>
              DiscussionScreen(api: widget.api, id: id, bots: widget.bots),
        ),
      )
      .then((_) => _load());

  Future<void> _new() async {
    final id = await showDialog<int>(
      context: context,
      builder: (_) => _NewDiscussion(api: widget.api, bots: widget.bots),
    );
    if (id != null) _open(id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Discussions')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _new,
      icon: const Icon(Icons.forum_outlined),
      label: const Text('New discussion'),
    ),
    body: list.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Ask a few bots to argue a question out. Each thinks on its '
                'own model, sees the others only as a short summary, and a '
                'chair writes the verdict.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : ListView(
            children: [
              for (final d in list)
                ListTile(
                  leading: Icon(
                    d['status'] == 'done'
                        ? Icons.check_circle_outline
                        : Icons.forum_outlined,
                  ),
                  title: Text(
                    d['question'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${(d['bots'] as List).join(', ')} · ${_status(d)}',
                  ),
                  onTap: () => _open(d['id'] as int),
                ),
            ],
          ),
  );
}

String _status(Map<String, dynamic> d) {
  final round = d['round'] as int, rounds = d['rounds'] as int;
  return switch (d['status']) {
    'done' => 'verdict in',
    'failed' => 'stopped',
    _ when round > rounds => 'writing the verdict',
    _ => 'round $round of $rounds',
  };
}

class _NewDiscussion extends StatefulWidget {
  const _NewDiscussion({required this.api, required this.bots});
  final Api api;
  final List<Map<String, dynamic>> bots;
  @override
  State<_NewDiscussion> createState() => _NewDiscussionState();
}

class _NewDiscussionState extends State<_NewDiscussion> {
  final question = TextEditingController();
  final picked = <String>[];
  int rounds = 2;
  String? error;

  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final r = await widget.api.postJson('/api/discussions', {
        'question': question.text.trim(),
        'bots': picked,
        'rounds': rounds,
      });
      if (mounted) Navigator.pop(context, r['id'] as int);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New discussion'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: question,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              maxLength: 4000,
              decoration: const InputDecoration(
                labelText: 'The question',
                hintText: 'Should we move the blog to a static site?',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Who takes part (2 to 6; the first is the chair)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final b in widget.bots)
                  FilterChip(
                    avatar: BotAvatar(
                      key: ValueKey(b['slug']),
                      slug: faceOf(b, b['slug'] as String),
                      mood: 0,
                      size: 24,
                    ),
                    label: Text(b['name'] as String),
                    selected: picked.contains(b['slug']),
                    onSelected: (on) => setState(
                      () => on
                          ? picked.add(b['slug'] as String)
                          : picked.remove(b['slug']),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: rounds,
              decoration: const InputDecoration(labelText: 'Rounds'),
              items: [
                for (final n in [1, 2, 3, 4])
                  DropdownMenuItem(
                    value: n,
                    child: Text(n == 1 ? '1 (opening positions only)' : '$n'),
                  ),
              ],
              onChanged: (n) => setState(() => rounds = n ?? rounds),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: picked.length >= 2 && question.text.trim().isNotEmpty
            ? _start
            : null,
        child: const Text('Start'),
      ),
    ],
  );
}

/// One discussion: the question, the room's posts as they come, the verdict.
class DiscussionScreen extends StatefulWidget {
  const DiscussionScreen({
    super.key,
    required this.api,
    required this.id,
    required this.bots,
  });
  final Api api;
  final int id;
  final List<Map<String, dynamic>> bots;
  @override
  State<DiscussionScreen> createState() => _DiscussionScreenState();
}

class _DiscussionScreenState extends State<DiscussionScreen> {
  Map<String, dynamic>? d;
  Timer? poll;
  String? problem;

  @override
  void initState() {
    super.initState();
    _load();
    // ponytail: polls every 3 s while it runs; push over /api/events if that's too slow.
    poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (d == null || d!['status'] == 'running') _load();
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final got = await widget.api.get('/api/discussions/${widget.id}');
      if (mounted) setState(() => d = got as Map<String, dynamic>);
    } catch (e) {
      if (mounted) setState(() => problem = '$e');
    }
  }

  String _name(String slug) =>
      widget.bots.firstWhere(
            (b) => b['slug'] == slug,
            orElse: () => {'name': slug},
          )['name']
          as String;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = Theme.of(context).textTheme;
    final d = this.d;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: Text('Discussion #${widget.id}')),
        body: Center(child: Text(problem ?? 'Loading…')),
      );
    }
    final posts = (d['posts'] as List).cast<Map<String, dynamic>>();
    final running = d['status'] == 'running';
    int? lastRound;
    return Scaffold(
      appBar: AppBar(title: Text('Discussion #${widget.id} · ${_status(d)}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(d['question'] as String, style: text.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Chair: ${_name(d['chair'] as String)} · '
                '${(d['bots'] as List).map((b) => _name(b as String)).join(', ')}',
                style: text.bodySmall,
              ),
              for (final p in posts) ...[
                if (p['round'] != lastRound) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 4),
                    child: Text(
                      'Round ${lastRound = p['round'] as int}',
                      style: text.labelLarge,
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      BotAvatar(
                        key: ValueKey('${p['bot']}'),
                        slug: faceOf(
                          widget.bots
                              .where((b) => b['slug'] == p['bot'])
                              .firstOrNull,
                          p['bot'] as String,
                        ),
                        mood: 0,
                        size: 36,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _name(p['bot'] as String),
                                style: text.labelMedium,
                              ),
                              const SizedBox(height: 4),
                              SelectableText(p['text'] as String),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (running)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (d['verdict'] != null) ...[
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: Text('Verdict', style: text.titleMedium)),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: d['verdict'] as String),
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: MarkdownBlock(
                    data: d['verdict'] as String,
                    selectable: true,
                    config: markdownConfig(dark, scheme),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
