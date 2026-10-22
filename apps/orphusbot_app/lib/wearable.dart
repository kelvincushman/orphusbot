// Wearable: the one-button wearable linked to this server (DESIGN §9.3). Its
// devices, pairing a new one, hands-free listening, where its button captures
// go (a task in the Inbox or an idea for the Ideas Room), what it overheard
// and the signals sent to the wrist.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

class WearableScreen extends StatefulWidget {
  const WearableScreen({super.key, required this.api});
  final Api api;
  @override
  State<WearableScreen> createState() => _WearableScreenState();
}

class _WearableScreenState extends State<WearableScreen> {
  List<dynamic> devices = [];
  List<dynamic> signals = [];
  List<dynamic> heard = [];
  bool listeningAllowed = true;
  String? pairing;
  String? note;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => _act(_fetch);

  Future<void> _fetch() async {
    final got = await Future.wait([
      widget.api.get('/api/devices'),
      widget.api.get('/api/captures'),
    ]);
    final d = got[0] as Map<String, dynamic>,
        c = got[1] as Map<String, dynamic>;
    if (!mounted) return;
    setState(() {
      devices = d['devices'] as List? ?? [];
      signals = d['messages'] as List? ?? [];
      heard = c['proposals'] as List? ?? [];
      listeningAllowed = c['allowed'] != false;
      loaded = true;
    });
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      if (mounted && note != null) setState(() => note = null);
    } catch (e) {
      if (mounted) setState(() => note = explain(e));
    }
  }

  Future<void> _post(String path, Map<String, Object?> body) => _act(() async {
    await widget.api.post(path, body);
    await _fetch();
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget heading(String title, [String? sub]) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(sub, style: text.bodySmall),
            ),
        ],
      ),
    );
    final open = [
      for (final p in heard)
        if (p['state'] == 'proposed' || p['undoable'] == true) p,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wearable'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(note!, style: TextStyle(color: scheme.error)),
              ),
            heading(
              'Your wearables',
              'Press the button and speak: the words come here. Tap answers '
                  'a question on the wrist, double tap says no.',
            ),
            if (loaded && devices.isEmpty)
              const ListTile(
                leading: Icon(Icons.watch_off_outlined),
                title: Text('None paired yet'),
                subtitle: Text('Pair one below.'),
              ),
            for (final d in devices) _device(d as Map<String, dynamic>, text),
            heading('Pair a wearable'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _act(() async {
                    final r = await widget.api.postJson(
                      '/api/devices/pairing-code',
                      {},
                    );
                    if (!mounted) return;
                    setState(() => pairing = r['code'] as String?);
                  }),
                  icon: const Icon(Icons.add),
                  label: Text(
                    pairing == null ? 'Get a pairing code' : 'New code',
                  ),
                ),
              ),
            ),
            if (pairing != null) _pairing(text),
            heading(
              'Heard hands-free',
              listeningAllowed
                  ? 'What it picked up while listening. Accept makes a ticket; '
                        'nothing starts by itself.'
                  : 'Hands-free capture is turned off on the server.',
            ),
            if (loaded && open.isEmpty)
              const ListTile(dense: true, title: Text('Nothing waiting.')),
            for (final p in open) _heard(p as Map<String, dynamic>, text),
            heading('Signals to the wrist'),
            if (loaded && signals.isEmpty)
              const ListTile(dense: true, title: Text('None yet.')),
            for (final s in signals.take(15))
              ListTile(
                dense: true,
                leading: Icon(
                  s['kind'] == 'ask'
                      ? Icons.help_outline
                      : Icons.circle_notifications_outlined,
                ),
                title: Text('${s['cue']} · ${s['subject']}'),
                subtitle: Text(
                  [
                    s['state'],
                    if ((s['outcome'] as String?)?.isNotEmpty == true)
                      s['outcome'],
                    lastSeen(s['at'] as String?),
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _device(Map<String, dynamic> d, TextTheme text) {
    final label = (d['label'] as String?)?.isNotEmpty == true
        ? d['label'] as String
        : d['id'] as String;
    final toRoom = d['captures_to'] == 'room';
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.watch),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: text.titleMedium)),
                Text(
                  'seen ${lastSeen(d['last_seen'] as String?)}',
                  style: text.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Button captures go to', style: text.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'inbox',
                  icon: Icon(Icons.inbox_outlined),
                  label: Text('Inbox'),
                ),
                ButtonSegment(
                  value: 'room',
                  icon: Icon(Icons.bubble_chart_outlined),
                  label: Text('Ideas Room'),
                ),
              ],
              selected: {toRoom ? 'room' : 'inbox'},
              onSelectionChanged: (s) =>
                  _post('/api/devices/route', {'id': d['id'], 'to': s.first}),
            ),
            const SizedBox(height: 4),
            Text(
              toRoom
                  ? 'Kept as an idea the Ideas Room remembers, and filed by the '
                        'Orchestrator in your vault under wiki/ideas.'
                  : 'A task: the Inbox routes it to the right bot.',
              style: text.bodySmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hands-free listening'),
              subtitle: const Text(
                'Its light stays on the whole time it listens.',
              ),
              value: d['hands_free'] == true,
              onChanged: (on) =>
                  _post('/api/devices/hands-free', {'id': d['id'], 'on': on}),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pairing(TextTheme text) {
    final both = 'Server: ${widget.api.server}\nToken:  $pairing';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "In the wearable app's pairing page, use this server address and "
            'paste the code as the token. It works once, for 10 minutes.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  both,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: both)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heard(Map<String, dynamic> p, TextTheme text) {
    final proposed = p['state'] == 'proposed';
    final id = p['id'];
    return ListTile(
      title: Text(p['title'] as String? ?? ''),
      subtitle: Text(
        [
          if ((p['quote'] as String?)?.isNotEmpty == true) '“${p['quote']}”',
          if ((p['due'] as String?)?.isNotEmpty == true) 'due ${p['due']}',
          if (!proposed) 'filed by itself',
        ].join(' · '),
      ),
      trailing: proposed
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close),
                  onPressed: () => _post('/api/proposals/dismiss', {'id': id}),
                ),
                IconButton(
                  tooltip: 'Accept',
                  icon: const Icon(Icons.check),
                  onPressed: () => _post('/api/proposals/accept', {'id': id}),
                ),
              ],
            )
          : TextButton(
              onPressed: () => _post('/api/proposals/undo', {'id': id}),
              child: const Text('Undo'),
            ),
    );
  }
}

/// How long ago a server timestamp was, in a few characters.
String lastSeen(String? at) {
  final t = at == null ? null : DateTime.tryParse(at)?.toLocal();
  if (t == null) return 'never';
  final ago = DateTime.now().difference(t);
  if (ago.inMinutes < 2) return 'just now';
  if (ago.inHours < 1) return '${ago.inMinutes} min ago';
  if (ago.inDays < 1) return '${ago.inHours} h ago';
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

String _two(int n) => n.toString().padLeft(2, '0');
