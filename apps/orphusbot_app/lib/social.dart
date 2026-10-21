// Social (DESIGN §11.6): what the content bot drafted for X and LinkedIn,
// shown the way it will look, for the owner to approve, edit, schedule or
// reject; replies to comments beside the comment; what's scheduled and what
// went out; the phone's screen; and each account's voice. ContentSwarm on the
// server's machine keeps all of it; the server passes these calls on.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

const _platforms = {'x': 'X', 'linkedin': 'LinkedIn', 'facebook': 'Facebook'};

/// The longest post each platform takes.
const _limits = {'x': 280, 'linkedin': 3000, 'facebook': 63206};

String platformName(String? p) => _platforms[p] ?? (p ?? '?');

/// ContentSwarm's errors are `{"error": "…"}`; show just the sentence.
String socialError(Object e) {
  final text = explain(e);
  try {
    final m = jsonDecode(text.replaceFirst('Exception: ', ''));
    if (m is Map && m['error'] is String) return m['error'] as String;
  } catch (_) {}
  return text;
}

/// A time as ISO 8601 with the local offset, as ContentSwarm wants it.
String isoWithOffset(DateTime t) {
  final o = t.timeZoneOffset;
  String two(int n) => n.abs().toString().padLeft(2, '0');
  final base = t.toIso8601String().split('.').first;
  return '$base${o.isNegative ? '-' : '+'}${two(o.inHours)}:${two(o.inMinutes % 60)}';
}

String _when(num? epoch) {
  if (epoch == null) return 'as soon as approved';
  final t = DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round());
  final now = DateTime.now();
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return 'today $hm';
  }
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${days[t.weekday - 1]} ${t.day}/${t.month} $hm';
}

/// The Pipeline tab's sections, in order: what needs the owner comes first.
const pipelineSections = [
  ('Check these', {'uncertain'}),
  ('Sending now', {'executing'}),
  ('Waiting to send', {'approved'}),
  ('Posted', {'verified'}),
  ('Rejected or cancelled', {'rejected', 'cancelled'}),
];

class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key, required this.api});
  final Api api;
  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  List<Map<String, dynamic>> reviews = [];
  List<Map<String, dynamic>> accounts = [];
  String? note;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.get('/api/social/reviews') as Map;
      final a = await widget.api.get('/api/social/social/accounts') as Map;
      if (!mounted) return;
      setState(() {
        reviews = (r['reviews'] as List).cast<Map<String, dynamic>>();
        accounts = (a['accounts'] as List).cast<Map<String, dynamic>>();
        loaded = true;
        note = null;
      });
    } catch (e) {
      if (mounted) setState(() => note = socialError(e));
    }
  }

  /// One of the owner's decisions on a review; reloads after.
  Future<void> act(
    Map<String, dynamic> r,
    String action, [
    Map<String, Object> more = const {},
  ]) async {
    try {
      await widget.api.post('/api/social/reviews/${r['id']}/$action', {
        'revision': r['revision'],
        ...more,
      });
    } catch (e) {
      if (mounted) setState(() => note = socialError(e));
    }
    await _load();
  }

  Future<void> _edit(Map<String, dynamic> r) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _EditDialog(
        text: r['reply'] as String,
        limit: _limits[r['platform']],
      ),
    );
    if (text != null && text.trim() != r['reply']) {
      await act(r, 'edit', {'reply': text.trim()});
    }
  }

  Future<void> _schedule(Map<String, dynamic> r) async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null) return;
    final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (!at.isAfter(DateTime.now())) {
      setState(() => note = 'Pick a time in the future.');
      return;
    }
    await act(r, 'schedule', {'at': isoWithOffset(at)});
  }

  /// Rejecting can say why; the reason goes into that account's memory so
  /// the next drafts learn from it.
  Future<void> _reject(Map<String, dynamic> r) async {
    final why = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reject this draft'),
        content: TextField(
          controller: why,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Why? (optional, teaches the next drafts)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await act(r, 'reject');
    final account = r['account_id'];
    if (why.text.trim().isNotEmpty && account != null) {
      try {
        await widget.api.post('/api/social/social/accounts/$account/memory', {
          'text':
              'Kelvin rejected this draft: "${r['reply']}". His reason: ${why.text.trim()}',
          'source': 'Rejected in OrphusBot',
        });
      } catch (e) {
        if (mounted) setState(() => note = socialError(e));
      }
    }
  }

  List<Map<String, dynamic>> _waiting(String kind) => [
    for (final r in reviews)
      if (r['status'] == 'pending' && (r['kind'] ?? 'reply') == kind) r,
  ];

  Widget _card(Map<String, dynamic> r) => ReviewCard(
    review: r,
    onApprove: () => act(r, 'approve'),
    onEdit: () => _edit(r),
    onSchedule: () => _schedule(r),
    onReject: () => _reject(r),
    onCancel: () => act(r, 'cancel'),
    onConfirm: () => act(r, 'confirm'),
    onRetry: () => act(r, 'retry'),
  );

  /// Everything past approval, by where it is: what needs the owner first.
  Widget _pipeline() {
    final sections = [
      for (final (title, statuses) in pipelineSections)
        (
          title,
          [
            for (final r in reviews)
              if (statuses.contains(r['status'])) r,
          ],
        ),
    ];
    return _list(
      const [],
      'Nothing approved yet. Approved posts and replies show here until '
      'they are posted.',
      sections: [
        for (final (title, items) in sections)
          if (items.isNotEmpty) (title, items),
      ],
    );
  }

  Widget _list(
    List<Map<String, dynamic>> items,
    String empty, {
    List<(String, List<Map<String, dynamic>>)>? sections,
  }) {
    final groups = sections ?? [('', items)];
    if (!loaded) {
      return Center(
        child: note == null
            ? const CircularProgressIndicator()
            : Padding(padding: const EdgeInsets.all(24), child: Text(note!)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: groups.every((g) => g.$2.isEmpty)
          ? ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(empty, textAlign: TextAlign.center),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final (title, rows) in groups) ...[
                  if (title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '$title (${rows.length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  for (final r in rows) _card(r),
                ],
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final posts = _waiting('post');
    final replies = _waiting('reply');
    final toCheck = reviews.where((r) => r['status'] == 'uncertain').length;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Social'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'To approve (${posts.length})'),
              Tab(text: 'Comments (${replies.length})'),
              Tab(
                text: toCheck > 0 ? 'Pipeline ($toCheck to check)' : 'Pipeline',
              ),
              const Tab(text: 'Phone'),
              const Tab(text: 'Voice'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (note != null && loaded)
              MaterialBanner(
                content: Text(note!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => note = null),
                    child: const Text('OK'),
                  ),
                ],
              ),
            Expanded(
              child: TabBarView(
                children: [
                  _list(
                    posts,
                    'Nothing to approve. Ask the content bot for a post, or '
                    'set a schedule under Voice.',
                  ),
                  _list(replies, 'No replies waiting.'),
                  _pipeline(),
                  PhoneTab(api: widget.api),
                  VoiceTab(api: widget.api, accounts: accounts, reload: _load),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One review, drawn like the post it will become.
class ReviewCard extends StatelessWidget {
  const ReviewCard({
    super.key,
    required this.review,
    required this.onApprove,
    required this.onEdit,
    required this.onSchedule,
    required this.onReject,
    required this.onCancel,
    this.onConfirm,
    this.onRetry,
  });
  final Map<String, dynamic> review;
  final VoidCallback onApprove, onEdit, onSchedule, onReject, onCancel;

  /// For an uncertain delivery, after the owner checked the phone.
  final VoidCallback? onConfirm, onRetry;

  static const _status = {
    'pending': 'Waiting for you',
    'rejected': 'Rejected',
    'approved': 'Approved',
    'executing': 'Posting now',
    'verified': 'Posted',
    'uncertain': 'Not confirmed: check the phone',
    'cancelled': 'Cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = review;
    final status = r['status'] as String;
    final reply = (r['kind'] ?? 'reply') == 'reply';
    final body = r['reply'] as String;
    final limit = _limits[r['platform']];
    final account = r['account'] as String? ?? '';
    final over = limit != null && body.characters.length > limit;
    final quiet = TextStyle(color: scheme.outline);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${platformName(r['platform'] as String?)} · $account · '
              '${status == 'pending' || status == 'approved' ? _when(r['publish_at'] as num?) : _status[status] ?? status}',
              style: text.labelMedium,
            ),
            if (reply) ...[
              const SizedBox(height: 8),
              // A comment is someone else's words: quoted, never acted on.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: scheme.outlineVariant, width: 3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r['author'] as String? ?? '', style: text.labelLarge),
                    Text(r['original'] as String? ?? ''),
                    if (r['source_url'] != null)
                      InkWell(
                        onTap: () =>
                            launchUrl(Uri.parse(r['source_url'] as String)),
                        child: Text(
                          'Open the conversation',
                          style: TextStyle(color: scheme.primary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  child: Text(
                    account
                        .replaceAll('@', '')
                        .characters
                        .take(1)
                        .join()
                        .toUpperCase(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(account, style: text.titleSmall),
                      const SizedBox(height: 2),
                      SelectableText(body, style: text.bodyLarge),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                limit == null
                    ? '${body.characters.length}'
                    : '${body.characters.length}/$limit',
                style: TextStyle(color: over ? scheme.error : scheme.outline),
              ),
            ),
            if (r['edited_by_user'] == true)
              Text('Edited by you', style: quiet),
            if (status != 'pending' && r['evidence'] != null)
              Text(
                '${_status[status] ?? status}: ${r['evidence']}',
                style: quiet,
              ),
            Wrap(
              spacing: 8,
              children: [
                if (status == 'pending' || status == 'rejected')
                  FilledButton.icon(
                    onPressed: over ? null : onApprove,
                    icon: const Icon(Icons.check),
                    label: const Text('Approve'),
                  ),
                if (const {
                  'pending',
                  'rejected',
                  'approved',
                }.contains(status)) ...[
                  TextButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: onSchedule,
                    icon: const Icon(Icons.schedule),
                    label: const Text('Schedule'),
                  ),
                ],
                if (status == 'pending')
                  TextButton.icon(
                    onPressed: onReject,
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                  ),
                if (status == 'approved' || status == 'rejected')
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                if (status == 'uncertain' && onConfirm != null) ...[
                  FilledButton.icon(
                    onPressed: onConfirm,
                    icon: const Icon(Icons.check),
                    label: const Text('Yes, it posted'),
                  ),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.replay),
                    label: const Text('No, send it again'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.text, this.limit});
  final String text;
  final int? limit;
  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final c = TextEditingController(text: widget.text);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit'),
    content: SizedBox(
      width: 520,
      child: TextField(
        controller: c,
        autofocus: true,
        minLines: 4,
        maxLines: 12,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          helperText: 'Changing it means approving it again',
          counterText: widget.limit == null
              ? null
              : '${c.text.characters.length}/${widget.limit}',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, c.text),
        child: const Text('Save'),
      ),
    ],
  );
}

/// The phone's screen, refreshed every few seconds while this tab is open.
class PhoneTab extends StatefulWidget {
  const PhoneTab({super.key, required this.api});
  final Api api;
  @override
  State<PhoneTab> createState() => _PhoneTabState();
}

class _PhoneTabState extends State<PhoneTab> {
  List<Map<String, dynamic>> phones = [];
  String? phone;
  String? app;
  String? note;
  int tick = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _load();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.get('/api/social/phones') as Map;
      final list = (r['phones'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        phones = list;
        phone ??= [
          for (final p in list)
            if (p['connected'] == true) p['name'] as String,
        ].firstOrNull;
        note = null;
      });
      _refresh();
    } catch (e) {
      if (mounted) setState(() => note = socialError(e));
    }
  }

  Future<void> _refresh() async {
    final p = phone;
    if (p == null) return;
    try {
      final r =
          await widget.api.get('/api/social/phones/$p/current_app') as Map;
      if (mounted) setState(() => app = r['current_app'] as String?);
    } catch (_) {}
    if (mounted) setState(() => tick++);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = phone;
    if (p == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_android, size: 64, color: scheme.outline),
              const SizedBox(height: 12),
              Text(
                note ??
                    'No phone connected. Plug it into the server by USB, unlock '
                        'it and allow USB debugging.',
                textAlign: TextAlign.center,
              ),
              TextButton(onPressed: _load, child: const Text('Look again')),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '$p${app == null ? '' : ' · $app'}',
            style: TextStyle(color: scheme.outline),
          ),
        ),
        Expanded(
          child: Image.network(
            '${widget.api.server}/api/social/phones/$p/screenshot?t=$tick',
            headers: widget.api.headers,
            gaplessPlayback: true,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Center(child: Text("Couldn't read the phone's screen")),
          ),
        ),
      ],
    );
  }
}

/// Each account's voice ("soul"), what it remembers, and drafting now.
class VoiceTab extends StatelessWidget {
  const VoiceTab({
    super.key,
    required this.api,
    required this.accounts,
    required this.reload,
  });
  final Api api;
  final List<Map<String, dynamic>> accounts;
  final Future<void> Function() reload;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final a in accounts)
          Card(
            child: ListTile(
              title: Text(
                '${platformName(a['platform'] as String?)} · ${a['handle']}',
              ),
              subtitle: Text(
                a['soul'] as String? ?? '',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AccountScreen(api: api, account: a),
                  ),
                );
                await reload();
              },
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add an account'),
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AccountScreen(api: api, account: null),
              ),
            );
            await reload();
          },
        ),
        const SizedBox(height: 16),
        Text(
          'Coming next: import your X archive so drafts sound like you.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      ],
    );
  }
}

/// One account: its voice, phone, memory, and "draft one now".
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.api, required this.account});
  final Api api;
  final Map<String, dynamic>? account;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final a = widget.account;
  late final name = TextEditingController(text: a?['name'] as String? ?? '');
  late final handle = TextEditingController(
    text: a?['handle'] as String? ?? '',
  );
  late final soul = TextEditingController(text: a?['soul'] as String? ?? '');
  late final phones = TextEditingController(
    text: ((a?['phones'] as List?) ?? []).join(', '),
  );
  late String platform = a?['platform'] as String? ?? 'x';
  List<Map<String, dynamic>> memories = [];
  String? note;

  @override
  void initState() {
    super.initState();
    if (a != null) _memories();
  }

  Future<void> _memories() async {
    try {
      final r = await widget.api.get(
        '/api/social/social/accounts/${a!['id']}/memory',
      ) as Map;
      if (mounted) {
        setState(
          () => memories = (r['memories'] as List).cast<Map<String, dynamic>>(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => note = socialError(e));
    }
  }

  Future<void> _save() async {
    try {
      await widget.api.post('/api/social/social/accounts', {
        if (a != null) ...{'id': a!['id'], 'revision': a!['revision']},
        'name': name.text.trim(),
        'platform': platform,
        'handle': handle.text.trim(),
        'soul': soul.text.trim(),
        'phones': [
          for (final p in phones.text.split(','))
            if (p.trim().isNotEmpty) p.trim(),
        ],
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => note = socialError(e));
    }
  }

  Future<void> _ask(String title, String label, String path, String key) async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 5,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await widget.api.post(path, {
        key: text.trim(),
        if (key == 'text') 'source': 'Added in OrphusBot',
        if (key == 'prompt') ...{'account_id': a!['id'], 'kind': 'post'},
      });
      setState(
        () => note = key == 'prompt'
            ? 'Drafting. It appears under To approve in a minute or two.'
            : null,
      );
      await _memories();
    } catch (e) {
      setState(() => note = socialError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = a != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? '${a!['handle']}' : 'Add an account'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(note!, style: TextStyle(color: scheme.primary)),
            ),
          DropdownButtonFormField<String>(
            initialValue: platform,
            decoration: const InputDecoration(labelText: 'Platform'),
            items: [
              for (final MapEntry(:key, :value) in _platforms.entries)
                DropdownMenuItem(value: key, child: Text(value)),
            ],
            // A profile's platform and handle are fixed once made.
            onChanged: editing ? null : (p) => setState(() => platform = p!),
          ),
          TextField(
            controller: handle,
            enabled: !editing,
            decoration: const InputDecoration(
              labelText: 'Handle',
              hintText: '@yourname',
            ),
          ),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: soul,
            minLines: 4,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'Voice',
              helperText:
                  'How you sound, who you write for, and what you never say',
            ),
          ),
          TextField(
            controller: phones,
            decoration: const InputDecoration(
              labelText: 'Phones',
              helperText: 'Which phone posts for it (names from the Phone tab)',
            ),
          ),
          if (editing) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Draft a post now'),
                  onPressed: () => _ask(
                    'Draft a post',
                    'What about?',
                    '/api/social/social/jobs',
                    'prompt',
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Teach it something'),
                  onPressed: () => _ask(
                    'Something it should know',
                    'A fact, an opinion, a phrase you use',
                    '/api/social/social/accounts/${a!['id']}/memory',
                    'text',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'What it knows',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final m in memories)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(m['text'] as String? ?? ''),
                subtitle: Text(
                  '${m['source']}${m['trusted'] == true ? '' : ' · seen, not from you'}',
                ),
              ),
          ],
        ],
      ),
    );
  }
}
