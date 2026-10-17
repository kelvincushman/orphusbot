// Settings: the same jobs as the web page's Settings sheet (crates/ui), on the
// server's own API. Bots (edit and add), connections and which bots get them,
// machines, usage, passkeys, linking a device, the wearable, and signing out.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'avatar.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.onSignedOut,
  });
  final Api api;
  final VoidCallback onSignedOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Map<String, dynamic>> bots = [];
  List<dynamic> passkeys = [];
  List<dynamic> nodes = [];
  List<dynamic> fleets = [];
  Map<String, dynamic> connections = {};
  Map<String, dynamic> usage = {};
  Map<String, dynamic> wearables = {};
  String? enrol; // the command to enrol a new machine
  String? pairing; // a wearable pairing code
  Map<String, dynamic>? linking; // a device waiting to be approved
  final linkCode = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    linkCode.dispose();
    super.dispose();
  }

  Future<void> _load() => _act(() async {
    final api = widget.api;
    final got = await Future.wait([
      api.get('/api/bots'),
      api.get('/api/passkeys'),
      api.get('/api/nodes'),
      api.get('/api/connections'),
      api.get('/api/usage'),
      api.get('/api/devices'),
      api.get('/api/fleets'),
    ]);
    setState(() {
      bots = (got[0] as List).cast<Map<String, dynamic>>();
      passkeys = got[1] as List;
      nodes = got[2] as List;
      connections = got[3] as Map<String, dynamic>;
      usage = got[4] as Map<String, dynamic>;
      wearables = got[5] as Map<String, dynamic>;
      fleets = got[6] as List;
    });
  });

  Future<void> _act(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null) _say(done);
    } on SignedOut {
      _signedOut();
    } catch (e) {
      _say('$e');
    }
  }

  // Settings sits above the chat, so close it before showing sign-in.
  void _signedOut() {
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    widget.onSignedOut();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _sure(String question) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(question),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _remove(String path, int id, String question) async {
    if (!await _sure(question)) return;
    await _act(() => widget.api.post(path, {'id': id}), done: 'Removed.');
    _load();
  }

  Future<void> _editBot(Map<String, dynamic>? bot) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => BotEditor(api: widget.api, bot: bot),
    );
    if (saved == true) _load();
  }

  Future<void> _editFleet(Map<String, dynamic>? fleet) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => FleetEditor(api: widget.api, fleet: fleet),
    );
    if (changed == true) _load();
  }

  /// Sends a bot `/fleet <name> <task>`; the run shows in that bot's chat.
  Future<void> _runFleet(String name) async {
    final task = TextEditingController();
    String bot = bots.isEmpty ? 'inbox' : bots.first['slug'] as String;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Run $name'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: bot,
                  decoration: const InputDecoration(labelText: 'Run it as'),
                  items: [
                    for (final b in bots)
                      DropdownMenuItem(
                        value: b['slug'] as String,
                        child: Text(b['name'] as String),
                      ),
                  ],
                  onChanged: (v) => set(() => bot = v ?? bot),
                ),
                TextField(
                  controller: task,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'The task or question',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Run'),
            ),
          ],
        ),
      ),
    );
    final text = task.text.trim();
    task.dispose();
    if (go != true || text.isEmpty) return;
    await _act(
      () => widget.api.send(bot, '/fleet $name $text'),
      done: 'Started. It shows in that bot\'s chat.',
    );
  }

  Future<void> _addConnection() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _ConnectionForm(api: widget.api),
    );
    if (added == true) _load();
  }

  static String day(String? when) =>
      when == null ? 'never' : when.substring(0, 10);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget heading(String title, [String? note]) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(note, style: text.bodySmall),
            ),
        ],
      ),
    );
    final conns = (connections['connections'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              heading('Bots', 'Tap a bot to change its model or instructions.'),
              for (final b in bots)
                ListTile(
                  leading: BotAvatar(
                    key: ValueKey(b['slug']),
                    slug: b['slug'] as String,
                    mood: 0,
                  ),
                  title: Text(
                    '${b['name']}${b['disabled'] == true ? ' (disabled)' : ''}',
                  ),
                  subtitle: Text(
                    '${b['model'] ?? 'Orphus default'} · ${b['scope']}',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _editBot(b),
                ),
              _buttons([
                OutlinedButton.icon(
                  onPressed: () => _editBot(null),
                  icon: const Icon(Icons.add),
                  label: const Text('New bot'),
                ),
              ]),

              heading(
                'Connections',
                'MCP servers your bots may use. Pick which bots get each one; '
                    'every call that does something asks you first.',
              ),
              for (final c in conns) _connection(c),
              _buttons([
                OutlinedButton.icon(
                  onPressed: _addConnection,
                  icon: const Icon(Icons.add),
                  label: const Text('Add a connection'),
                ),
              ]),
              if (connections['secrets'] == false)
                _note(
                  'To save tokens, set ORPHUSBOT_SECRET_KEY_FILE on the server.',
                ),

              heading(
                'Fleets',
                'Teams of agents, each seat on its own model, that argue in a '
                    'room or split up the work. Run one by sending a bot '
                    '/fleet <name> <task>, or with ▶ here.',
              ),
              for (final f in fleets)
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(f['name'] as String),
                  subtitle: Text(f['description'] as String),
                  onTap: () => _editFleet(f as Map<String, dynamic>),
                  trailing: IconButton(
                    tooltip: 'Run',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => _runFleet(f['name'] as String),
                  ),
                ),
              _buttons([
                OutlinedButton.icon(
                  onPressed: () => _editFleet(null),
                  icon: const Icon(Icons.add),
                  label: const Text('New fleet'),
                ),
              ]),

              heading('Machines', 'The computers your bots run on (nodes).'),
              for (final n in nodes)
                ListTile(
                  leading: const Icon(Icons.computer),
                  title: Text(n['name'] as String),
                  subtitle: Text(
                    'Enrolled ${day(n['created_at'] as String?)} · '
                    'last seen ${day(n['last_seen_at'] as String?)}',
                  ),
                  trailing: _removeButton(
                    () => _remove(
                      '/api/nodes/remove',
                      n['id'] as int,
                      "Remove this machine? It's disconnected and can't come "
                          'back without enrolling again.',
                    ),
                  ),
                ),
              _buttons([
                OutlinedButton.icon(
                  onPressed: () => _act(() async {
                    final r = await widget.api.postJson('/api/nodes/code', {});
                    setState(() => enrol = 'orphusbot-node enrol ${r['code']}');
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a machine'),
                ),
              ]),
              if (enrol != null) ...[
                _note(
                  'On the machine, run this within 10 minutes. '
                  'The code works once.',
                ),
                _copyable(enrol!),
              ],

              heading('Usage'),
              _note(_usageLine()),
              for (final (key, period) in [
                ('today', 'today'),
                ('week', 'last 7 days'),
              ])
                for (final m in (usage[key] as List? ?? []))
                  ListTile(
                    dense: true,
                    title: Text('${m['provider']} ${m['model']}'),
                    subtitle: Text(
                      '$period · ${m['turns']} turns · ${m['input']} in / '
                      '${m['output']} out · \$${(m['cost'] as num).toStringAsFixed(2)}',
                    ),
                  ),
              for (final b in (usage['bots_today'] as List? ?? []))
                ListTile(
                  dense: true,
                  title: Text('${b['bot']}'),
                  subtitle: Text(
                    'today · ${b['turns']} turns · ${b['tokens']} tokens',
                  ),
                ),

              heading(
                'Passkeys',
                'Add passkeys from the web page in a browser; this app signs '
                    'in by linking instead.',
              ),
              for (final p in passkeys)
                ListTile(
                  leading: const Icon(Icons.key),
                  title: Text(p['name'] as String),
                  subtitle: Text(
                    'Added ${day(p['created_at'] as String?)} · '
                    'last used ${day(p['last_used_at'] as String?)}',
                  ),
                  trailing: _removeButton(
                    () => _remove(
                      '/api/passkeys/remove',
                      p['id'] as int,
                      'Remove this passkey? Every device signed in with it '
                          'is signed out, perhaps this one too.',
                    ),
                  ),
                ),

              heading(
                'Link a device',
                "For a device that can't use passkeys. Enter the code it shows.",
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: linkCode,
                        decoration: const InputDecoration(
                          hintText: 'ABCD-EFGH',
                        ),
                        onSubmitted: (_) => _checkLink(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _checkLink,
                      child: const Text('Check'),
                    ),
                  ],
                ),
              ),
              if (linking != null) ...[
                _note(
                  'Approve ${linking!['user_code']} from '
                  '${linking!['label']}? It gets its own sign-in.',
                ),
                _buttons([
                  FilledButton(
                    onPressed: () => _act(() async {
                      await widget.api.post('/api/links/approve', {
                        'user_code': linking!['user_code'],
                      });
                      setState(() {
                        linking = null;
                        linkCode.clear();
                      });
                    }, done: 'Device linked.'),
                    child: const Text('Approve'),
                  ),
                ]),
              ],

              heading('Wearable'),
              for (final d in (wearables['devices'] as List? ?? []))
                SwitchListTile(
                  secondary: const Icon(Icons.watch),
                  title: Text(
                    (d['label'] as String?)?.isNotEmpty == true
                        ? d['label'] as String
                        : d['id'] as String,
                  ),
                  subtitle: Text(
                    'last seen ${day(d['last_seen'] as String?)} · hands-free',
                  ),
                  value: d['hands_free'] == true,
                  onChanged: (on) => _act(() async {
                    await widget.api.post('/api/devices/hands-free', {
                      'id': d['id'],
                      'on': on,
                    });
                    await _load();
                  }),
                ),
              _buttons([
                OutlinedButton.icon(
                  onPressed: () => _act(() async {
                    final r = await widget.api.postJson(
                      '/api/devices/pairing-code',
                      {},
                    );
                    setState(() => pairing = r['code'] as String?);
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('Pair a wearable'),
                ),
              ]),
              if (pairing != null) ...[
                _note(
                  "In the wearable app's pairing page, use this server "
                  'address and paste the code as the token. It works once, '
                  'for 10 minutes.',
                ),
                _copyable('Server: ${widget.api.server}\nToken:  $pairing'),
              ],

              heading('This device'),
              _buttons([
                OutlinedButton.icon(
                  onPressed: () async {
                    await _act(() => widget.api.post('/api/logout', {}));
                    _signedOut();
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  String _usageLine() {
    final today = usage['today_tokens'] ?? 0;
    final budget = usage['budget'];
    return budget == null
        ? '$today tokens today. Set ORPHUSBOT_DAILY_TOKEN_BUDGET to be warned.'
        : '$today tokens today of a $budget budget.';
  }

  Future<void> _checkLink() => _act(() async {
    final code = linkCode.text.trim();
    if (code.isEmpty) return;
    final found = await widget.api.get(
      '/api/links/${Uri.encodeComponent(code)}',
    );
    setState(() => linking = found as Map<String, dynamic>);
  });

  Widget _connection(Map<String, dynamic> c) {
    final id = c['id'] as int;
    final granted = (c['bots'] as List).cast<String>();
    final token = c['signed_in'] == true
        ? ' · signed in'
        : (c['has_token'] == true ? ' · token saved' : '');
    return ListTile(
      leading: const Icon(Icons.extension_outlined),
      title: Text(c['name'] as String),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${c['target']}$token'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in bots)
                FilterChip(
                  label: Text(b['name'] as String),
                  selected: granted.contains(b['slug']),
                  onSelected: (on) => _act(() async {
                    await widget.api.post('/api/connections/grant', {
                      'id': id,
                      'bot': b['slug'],
                      'granted': on,
                    });
                    await _load();
                  }),
                ),
            ],
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c['url'] != null)
            TextButton(
              // The provider's sign-in page opens in the browser and comes
              // back to the server, which keeps the tokens.
              onPressed: () => _act(() async {
                final r = await widget.api.postJson('/api/connections/oauth', {
                  'id': id,
                });
                await launchUrl(Uri.parse(r['url'] as String));
              }),
              child: const Text('Sign in'),
            ),
          _removeButton(
            () => _remove(
              '/api/connections/delete',
              id,
              'Remove this connection? Bots lose it on their next run, and '
                  'its token is deleted.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _removeButton(VoidCallback onPressed) => IconButton(
    tooltip: 'Remove',
    icon: const Icon(Icons.delete_outline),
    onPressed: onPressed,
  );

  Widget _buttons(List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Wrap(spacing: 8, children: children),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );

  Widget _copyable(String value) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            _say('Copied.');
          },
        ),
      ],
    ),
  );
}

/// Edits a bot, or makes a new one when [bot] is null. Pops true once saved.
class BotEditor extends StatefulWidget {
  const BotEditor({super.key, required this.api, this.bot});
  final Api api;
  final Map<String, dynamic>? bot;

  @override
  State<BotEditor> createState() => _BotEditorState();
}

class _BotEditorState extends State<BotEditor> {
  static const thinkingLevels = [
    'off',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  ];
  late final Map<String, dynamic> bot = {
    'slug': '',
    'name': '',
    'remit': '',
    'instructions': '',
    'model': null,
    'thinking': null,
    'exclude_tools': <String>[],
    'scope': 'private',
    'disabled': false,
    'computer': 'node',
    'google': 'read',
    ...?widget.bot,
  };
  late final name = TextEditingController(text: bot['name'] as String);
  late final remit = TextEditingController(text: bot['remit'] as String);
  late final instructions = TextEditingController(
    text: bot['instructions'] as String,
  );
  late final model = TextEditingController(text: bot['model'] as String?);
  List<String> models = [];
  String? error;
  bool get isNew => widget.bot == null;

  @override
  void initState() {
    super.initState();
    widget.api.get('/api/models').then((list) {
      if (!mounted) return;
      setState(
        () => models = [for (final m in list as List) m['id'] as String],
      );
    }, onError: (_) {});
  }

  @override
  void dispose() {
    for (final c in [name, remit, instructions, model]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final m = model.text.trim();
    final edited = {
      ...bot,
      'name': name.text.trim(),
      'remit': remit.text.trim(),
      'instructions': instructions.text,
      'model': m.isEmpty ? null : m,
    };
    try {
      await widget.api.post(isNew ? '/api/bots' : '/api/bots/update', edited);
      if (mounted) Navigator.pop(context, true);
    } on SignedOut {
      if (mounted) Navigator.pop(context, false);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final inbox = bot['slug'] == 'inbox';
    return AlertDialog(
      title: Text(isNew ? 'New bot' : 'Edit ${bot['name']}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 40,
                autofocus: isNew,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: remit,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: "What it's for (one line; used to route work)",
                ),
              ),
              TextField(
                controller: instructions,
                maxLength: 8000,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Instructions',
                  alignLabelWithHint: true,
                ),
              ),
              // Every model the machines reported, or one typed by hand;
              // empty means Orphus's default.
              DropdownMenu<String>(
                controller: model,
                expandedInsets: EdgeInsets.zero,
                enableFilter: true,
                requestFocusOnTap: true,
                label: const Text('Model (empty: Orphus default)'),
                dropdownMenuEntries: [
                  for (final m in models) DropdownMenuEntry(value: m, label: m),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: bot['thinking'] as String?,
                decoration: const InputDecoration(labelText: 'Thinking'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Default')),
                  for (final t in thinkingLevels)
                    DropdownMenuItem(value: t, child: Text(t)),
                ],
                onChanged: (t) => bot['thinking'] = t,
              ),
              DropdownButtonFormField<String>(
                initialValue: bot['google'] as String? ?? 'read',
                decoration: const InputDecoration(
                  labelText: 'Google (Gmail, Calendar, Tasks, Drive, Docs)',
                ),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('No access')),
                  DropdownMenuItem(
                    value: 'read',
                    child: Text('Look things up only'),
                  ),
                  DropdownMenuItem(
                    value: 'write',
                    child: Text('Also create and change (asks you each time)'),
                  ),
                ],
                onChanged: (g) => bot['google'] = g,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Team bot'),
                subtitle: const Text(
                  'Shares the team folder and can be asked by other bots',
                ),
                value: bot['scope'] == 'team',
                onChanged: (on) =>
                    setState(() => bot['scope'] = on ? 'team' : 'private'),
              ),
              if (!isNew && !inbox)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Disabled'),
                  subtitle: const Text('Takes no new work'),
                  value: bot['disabled'] == true,
                  onChanged: (on) => setState(() => bot['disabled'] = on),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(isNew ? 'Create bot' : 'Save'),
        ),
      ],
    );
  }
}

/// Edits a fleet blueprint (Orphus's YAML), or makes a new one from a council
/// template. Pops true when it was saved or deleted.
class FleetEditor extends StatefulWidget {
  const FleetEditor({super.key, required this.api, this.fleet});
  final Api api;
  final Map<String, dynamic>? fleet;
  @override
  State<FleetEditor> createState() => _FleetEditorState();
}

class _FleetEditorState extends State<FleetEditor> {
  static const template = '''name: my-council
description: Four seats argue a decision to a verdict, strongest dissent kept.
version: 1

teams:
  council:
    mode: deliberate          # argue in a room; or dispatch: split up the work
    rounds: 2
    members:
      - agent: worker
        model: provider/model   # pick from the list below; a different one per seat
        tools: [read, roundtable]
        brief: Architect. Propose the structure that best fits; cite evidence.
      - agent: worker
        model: provider/model
        tools: [read, roundtable]
        brief: Skeptic. Find the failure mode in every proposal.
      - agent: worker
        model: provider/model
        tools: [read, roundtable]
        brief: Pragmatist. Argue for the smallest change that ships.
      - agent: worker
        model: provider/model
        tools: [read, roundtable]
        brief: Critic. State the strongest opposing view plainly.
''';
  late final name = TextEditingController(
    text: widget.fleet?['name'] as String? ?? 'my-council',
  );
  late final yaml = TextEditingController(
    text: widget.fleet?['yaml'] as String? ?? template,
  );
  List<String> models = [];
  String? error;
  bool get isNew => widget.fleet == null;

  @override
  void initState() {
    super.initState();
    widget.api.get('/api/models').then((list) {
      if (mounted) {
        setState(
          () => models = [for (final m in list as List) m['id'] as String],
        );
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    name.dispose();
    yaml.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.api.post('/api/fleets', {
        'name': name.text.trim(),
        'yaml': yaml.text,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> _delete() async {
    try {
      await widget.api.post('/api/fleets/delete', {
        'name': widget.fleet!['name'],
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: Text(isNew ? 'New fleet' : 'Fleet ${widget.fleet!['name']}'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                enabled: isNew,
                maxLength: 48,
                // Keeps the blueprint's own name line in step with the name.
                onChanged: (v) => yaml.text = yaml.text.replaceFirst(
                  RegExp(r'^name:.*$', multiLine: true),
                  'name: ${v.trim()}',
                ),
                decoration: const InputDecoration(
                  labelText: 'Name (lower case; also the name: line below)',
                ),
              ),
              TextField(
                controller: yaml,
                minLines: 14,
                maxLines: 24,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Blueprint (Orphus fleet YAML)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Check it by sending a bot "/fleet validate <name>". Every seat '
                'is a live model session, so more seats cost more.',
                style: small,
              ),
              if (models.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Models your machines can use:', style: small),
                SelectableText(models.join('\n'), style: small),
              ],
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (!isNew) TextButton(onPressed: _delete, child: const Text('Delete')),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Adds an MCP server, by address or as a command a machine runs.
class _ConnectionForm extends StatefulWidget {
  const _ConnectionForm({required this.api});
  final Api api;
  @override
  State<_ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<_ConnectionForm> {
  final name = TextEditingController();
  final target = TextEditingController();
  final token = TextEditingController();
  final tokenEnv = TextEditingController();
  String? error;

  @override
  void dispose() {
    for (final c in [name, target, token, tokenEnv]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _add() async {
    try {
      await widget.api.post('/api/connections', {
        'name': name.text.trim(),
        'url': target.text.trim(),
        'token': token.text,
        'token_env': tokenEnv.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final command = !target.text.trim().startsWith('http');
    return AlertDialog(
      title: const Text('Add a connection'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              maxLength: 24,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'pa',
              ),
            ),
            TextField(
              controller: target,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Address, or a command a machine runs',
                hintText: 'https://pa.example.com/mcp, or npx -y some-mcp',
              ),
            ),
            TextField(
              controller: token,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Token (optional)'),
            ),
            if (command)
              TextField(
                controller: tokenEnv,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: 'Token variable for the command',
                  hintText: 'GITHUB_TOKEN',
                ),
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _add, child: const Text('Add')),
      ],
    );
  }
}
