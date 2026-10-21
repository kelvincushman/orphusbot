// System 1's decisions (DESIGN §7.5–§7.6): what kev decided about routing
// messages and letting tool calls through, and the owner's verdict on each.
// Every Right or Wrong is a label; with enough of them, Fit tunes the
// thresholds, and Apply puts the new ones to work.
import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';

class DecisionsScreen extends StatefulWidget {
  const DecisionsScreen({super.key, required this.api, required this.bots});
  final Api api;
  final List<Map<String, dynamic>> bots;
  @override
  State<DecisionsScreen> createState() => _DecisionsScreenState();
}

class _DecisionsScreenState extends State<DecisionsScreen> {
  List<Map<String, dynamic>> list = [];
  String? note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final got = await widget.api.get('/api/decisions') as List;
      if (mounted) setState(() => list = got.cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) setState(() => note = explain(e));
    }
  }

  Future<void> _mark(int id, Map<String, Object> label) async {
    try {
      await widget.api.post('/api/decisions/label', {'id': id, ...label});
      await _load();
    } catch (e) {
      setState(() => note = explain(e));
    }
  }

  Future<void> _fit() async {
    try {
      final r = await widget.api.postJson('/api/decisions/fit', {});
      final report = (r['report'] as Map).cast<String, dynamic>();
      final lines = [
        for (final MapEntry(:key, :value) in report.entries)
          '${key == 'triage.bot' ? 'Routing' : 'Edits'}: '
              '${value['needs'] != null ? '${value['labels']} labels so far, needs ${value['needs']}' : 'fitted on ${value['labels']} labels'}',
      ];
      final model = r['model'];
      if (!mounted) return;
      final apply = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Fit'),
          content: Text(lines.join('\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Close'),
            ),
            if (model != null)
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Apply the new thresholds'),
              ),
          ],
        ),
      );
      if (apply == true) {
        await widget.api.post('/api/decisions/apply', {'id': model});
        setState(() => note = 'Applied. You can roll back from the web page.');
      }
    } catch (e) {
      setState(() => note = explain(e));
    }
  }

  String _name(String? slug) {
    for (final b in widget.bots) {
      if (b['slug'] == slug) return b['name'] as String;
    }
    return slug ?? 'nobody';
  }

  Future<void> _pickBot(int id) async {
    final slug = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Which bot should it have gone to?'),
        children: [
          for (final b in widget.bots)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, b['slug'] as String),
              child: Text(b['name'] as String),
            ),
        ],
      ),
    );
    if (slug != null) await _mark(id, {'bot': slug});
  }

  /// What the decision was about, in a line or two.
  String _about(Map<String, dynamic> d) {
    final state = d['state'] as String?;
    if (state == null) return '(older than 30 days; the details are gone)';
    if (d['catalogue'] == 'gate') {
      try {
        final s = jsonDecode(state) as Map<String, dynamic>;
        final args = jsonEncode(s['args']);
        return '${s['tool']} ${args.length > 160 ? '${args.substring(0, 160)}…' : args}';
      } catch (_) {}
    }
    return state.length > 240 ? '${state.substring(0, 240)}…' : state;
  }

  Widget _tile(Map<String, dynamic> d, ColorScheme scheme) {
    final id = d['id'] as int;
    final gate = d['catalogue'] == 'gate';
    final answers = d['answers'] as Map<String, dynamic>?;
    final chose = answers?[gate ? 'verdict' : 'bot']?['choice'] as String?;
    final sure = d['confidence'] == null
        ? ''
        : ' · ${((d['confidence'] as num) * 100).round()}% sure';
    final said = d['label'] == null
        ? null
        : gate
        ? 'You said: ${d['label']['verdict'] == 'pass' ? 'fine to go ahead' : 'should ask'}'
        : 'You said: ${_name(d['label']['bot'] as String?)}';
    final what = d['abstained'] == true
        ? "Didn't answer (no model or too slow)"
        : gate
        ? (chose == 'pass'
              ? 'Thought it could go ahead'
              : 'Thought it should ask')
        : 'Chose ${_name(chose)}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              gate ? 'A tool call' : 'Where a message should go',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Text(_about(d)),
            const SizedBox(height: 6),
            Text(
              '$what$sure · ${d['outcome']}',
              style: TextStyle(color: scheme.outline),
            ),
            if (said != null)
              Text(said, style: TextStyle(color: scheme.primary)),
            Wrap(
              spacing: 8,
              children: gate
                  ? [
                      TextButton(
                        onPressed: () => _mark(id, {'verdict': 'pass'}),
                        child: const Text('Fine to go ahead'),
                      ),
                      TextButton(
                        onPressed: () => _mark(id, {'verdict': 'ask'}),
                        child: const Text('Should ask me'),
                      ),
                    ]
                  : [
                      if (chose != null)
                        TextButton.icon(
                          onPressed: () => _mark(id, {'bot': chose}),
                          icon: const Icon(Icons.check),
                          label: const Text('Right'),
                        ),
                      TextButton.icon(
                        onPressed: () => _pickBot(id),
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(chose == null ? 'Pick the bot' : 'Wrong'),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Only routing and edit checks learn from labels (calibrate.rs).
    final shown = list
        .where((d) => d['catalogue'] == 'triage' || d['catalogue'] == 'gate')
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Decisions'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton(onPressed: _fit, child: const Text('Fit')),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              note ??
                  'System 1 (kev) decides where Inbox messages go and whether a '
                      "harmless edit inside a bot's computer can go ahead without "
                      'asking. Tell it when it was right or wrong; after about 30 '
                      'labels of a kind, Fit tunes how sure it must be. Anything '
                      'irreversible always asks you.',
              style: TextStyle(color: scheme.outline),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('No decisions yet.'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      children: [for (final d in shown) _tile(d, scheme)],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
