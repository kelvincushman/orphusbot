// What OrphusBot has learned about you from what you say to your bots
// (DESIGN §11.9): each fact, the messages it came from, a search, and Forget.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

/// "today", "yesterday", "3 days ago" or a date, for when a fact was last heard.
String heardWhen(String? iso, DateTime now) {
  final at = DateTime.tryParse(iso ?? '')?.toLocal();
  if (at == null) return '';
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final year = at.year == now.year ? '' : ' ${at.year}';
  return '${at.day} ${months[at.month - 1]}$year';
}

/// The line under a fact: how often it was said and when last.
String factNote(Map<String, dynamic> fact, DateTime now) {
  final times = (fact['times_seen'] as num?)?.toInt() ?? 1;
  final when = heardWhen(fact['last_seen_at'] as String?, now);
  return [
    if (times > 1) 'Said $times times',
    if (when.isNotEmpty) when,
  ].join(' · ');
}

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.api});
  final Api api;
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  List<Map<String, dynamic>> facts = [];
  bool enabled = true;
  bool loading = true;
  String? note;
  final search = TextEditingController();
  Timer? typing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    typing?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = search.text.trim();
    try {
      final got = await widget.api.get(
        '/api/memory${q.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(q)}'}',
      ) as Map<String, dynamic>;
      // An answer to an older search mustn't replace a newer one.
      if (!mounted || q != search.text.trim()) return;
      setState(() {
        facts = (got['facts'] as List).cast<Map<String, dynamic>>();
        enabled = got['enabled'] == true;
        loading = false;
        note = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          note = explain(e);
        });
      }
    }
  }

  void _typed(String _) {
    typing?.cancel();
    typing = Timer(const Duration(milliseconds: 400), _load);
  }

  Future<void> _forget(Map<String, dynamic> fact) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Forget this?'),
        content: Text('${fact['text']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.api.delete('/api/memory/${fact['id']}');
      if (mounted) setState(() => facts.remove(fact));
    } catch (e) {
      if (mounted) setState(() => note = explain(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final empty = !enabled
        ? 'Memory is switched off on the server.'
        : search.text.trim().isEmpty
        ? 'Nothing learned yet. Facts appear here a minute or so after you '
              'tell a bot something worth remembering.'
        : 'Nothing found for that.';
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: search,
              onChanged: _typed,
              onSubmitted: (_) => _load(),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search what it knows about you',
              ),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(note!, style: TextStyle(color: scheme.error)),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : facts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        empty,
                        textAlign: TextAlign.center,
                        style: text.bodyLarge?.copyWith(color: scheme.outline),
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 32),
                      itemCount: facts.length,
                      itemBuilder: (context, i) {
                        final fact = facts[i];
                        final sources = (fact['sources'] as List? ?? [])
                            .cast<Map<String, dynamic>>();
                        final under = factNote(fact, now);
                        return ExpansionTile(
                          key: ValueKey(fact['id']),
                          title: Text('${fact['text']}'),
                          subtitle: under.isEmpty ? null : Text(under),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            12,
                          ),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sources.length == 1
                                  ? 'From what you said:'
                                  : 'From what you said (${sources.length} times):',
                              style: text.labelMedium?.copyWith(
                                color: scheme.outline,
                              ),
                            ),
                            for (final s in sources)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '“${s['text']}”\n'
                                  'to ${s['bot']}, ${heardWhen(s['heard_at'] as String?, now)}',
                                  style: text.bodyMedium,
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => _forget(fact),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Forget'),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
