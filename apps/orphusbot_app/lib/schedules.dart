// Schedules: tasks a bot runs on its own at set times (the server's routines,
// DESIGN §12.3). The owner picks a bot, says what to do and when; the server's
// scheduler does the rest, so every device shows the same list.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

/// How often, in the owner's words. Turned into five-field cron for the server.
enum Repeat { daily, weekdays, weekly, hours, once, custom, webhookOnly }

const weekdayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

/// Cron for a repeating choice; null for once, webhook-only and custom.
String? cronFor(
  Repeat r, {
  TimeOfDay at = const TimeOfDay(hour: 9, minute: 0),
  int weekday = 1,
  int hours = 4,
}) {
  final m = at.minute, h = at.hour;
  return switch (r) {
    Repeat.daily => '$m $h * * *',
    Repeat.weekdays => '$m $h * * 1-5',
    Repeat.weekly => '$m $h * * $weekday',
    Repeat.hours => '0 */$hours * * *',
    _ => null,
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

/// The simple shapes [cronFor] makes, read back: what the editor shows when a
/// schedule is opened again. Anything else is custom.
({Repeat repeat, TimeOfDay at, int weekday, int hours}) readCron(String cron) {
  final f = cron.trim().split(RegExp(r'\s+'));
  const fallback = TimeOfDay(hour: 9, minute: 0);
  final custom = (repeat: Repeat.custom, at: fallback, weekday: 1, hours: 4);
  if (f.length != 5 || f[2] != '*' || f[3] != '*') return custom;
  final hourStep = RegExp(r'^\*/(\d+)$').firstMatch(f[1]);
  if (f[0] == '0' && hourStep != null && f[4] == '*') {
    return (
      repeat: Repeat.hours,
      at: fallback,
      weekday: 1,
      hours: int.parse(hourStep[1]!),
    );
  }
  final m = int.tryParse(f[0]), h = int.tryParse(f[1]);
  if (m == null || h == null || m > 59 || h > 23) return custom;
  final at = TimeOfDay(hour: h, minute: m);
  if (f[4] == '*') return (repeat: Repeat.daily, at: at, weekday: 1, hours: 4);
  if (f[4] == '1-5') {
    return (repeat: Repeat.weekdays, at: at, weekday: 1, hours: 4);
  }
  final d = int.tryParse(f[4]);
  if (d != null && d >= 0 && d <= 6) {
    return (repeat: Repeat.weekly, at: at, weekday: d, hours: 4);
  }
  return custom;
}

/// One line for the list, such as "Weekdays at 09:00".
String describeSchedule(Map<String, dynamic> r) {
  final cron = r['cron'] as String?;
  final once = r['once_at'] as String?;
  final hook = r['webhook'] == true;
  String when;
  if (cron != null && cron.isNotEmpty) {
    final c = readCron(cron);
    final t = '${_two(c.at.hour)}:${_two(c.at.minute)}';
    when = switch (c.repeat) {
      Repeat.daily => 'Every day at $t',
      Repeat.weekdays => 'Weekdays at $t',
      Repeat.weekly => 'Every ${weekdayNames[c.weekday]} at $t',
      Repeat.hours => c.hours == 1 ? 'Every hour' : 'Every ${c.hours} hours',
      _ => 'Custom: $cron',
    };
  } else if (once != null && once.isNotEmpty) {
    when = 'Once, ${once.replaceFirst('T', ' at ')}';
  } else {
    when = 'Only when its webhook is called';
  }
  return hook && (cron != null || once != null) ? '$when, or by webhook' : when;
}

/// "2026-10-22 09:00" from the server's RFC 3339 time, in this device's time.
String shortTime(String? rfc3339) {
  if (rfc3339 == null) return '';
  final t = DateTime.tryParse(rfc3339)?.toLocal();
  if (t == null) return rfc3339;
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';
}

class SchedulesScreen extends StatefulWidget {
  final Api api;
  final List<Map<String, dynamic>> bots;
  const SchedulesScreen({super.key, required this.api, required this.bots});

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  List<Map<String, dynamic>> routines = [];
  bool loaded = false;
  String? note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.api.get('/api/routines') as List;
      if (!mounted) return;
      setState(() {
        routines = rows.cast<Map<String, dynamic>>();
        loaded = true;
        note = null;
      });
    } catch (e) {
      if (mounted) setState(() => note = '$e');
    }
  }

  String _botName(String slug) {
    for (final b in widget.bots) {
      if (b['slug'] == slug) return b['name'] as String? ?? slug;
    }
    return slug;
  }

  Future<void> _save(Map<String, dynamic> r) async {
    try {
      final saved = await widget.api.postJson('/api/routines', r);
      final hook = saved is Map ? saved['hook_path'] as String? : null;
      await _load();
      if (hook != null && mounted) {
        final url = '${widget.api.server}$hook';
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Webhook address'),
            content: SelectableText(
              'Calling this address runs the schedule. It is shown only '
              'once; keep it private.\n\n$url',
            ),
            actions: [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: url)),
                child: const Text('Copy'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => note = '$e');
    }
  }

  Future<void> _edit([Map<String, dynamic>? r]) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ScheduleEditor(bots: widget.bots, routine: r),
      ),
    );
    if (result != null) await _save(result);
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${r['name']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.api.post('/api/routines/delete', {'id': r['id']});
      await _load();
    } catch (e) {
      if (mounted) setState(() => note = '$e');
    }
  }

  Future<void> _runNow(Map<String, dynamic> r) async {
    try {
      await widget.api.post('/api/routines/run', {'id': r['id']});
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Started "${r['name']}"')));
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => note = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final quiet = TextStyle(color: Theme.of(context).colorScheme.outline);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedules'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New schedule'),
      ),
      body: Column(
        children: [
          if (note != null)
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
            child: !loaded
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        if (routines.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'No schedules yet. Add one to have a bot do '
                              'something on its own, such as checking your '
                              'mentions every morning.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        for (final r in routines)
                          Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          r['name'] as String,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium,
                                        ),
                                      ),
                                      Switch(
                                        value: r['active'] == true,
                                        onChanged: (on) =>
                                            _save({...r, 'active': on}),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '${_botName(r['bot'] as String)} · '
                                    '${describeSchedule(r)}',
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    r['prompt'] as String,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (r['active'] != true)
                                        'Paused'
                                      else if (r['next_at'] != null)
                                        'Next: ${shortTime(r['next_at'] as String?)}',
                                      if (r['last_fired_at'] != null)
                                        'Last: ${shortTime(r['last_fired_at'] as String?)}',
                                    ].join(' · '),
                                    style: quiet,
                                  ),
                                  Wrap(
                                    spacing: 4,
                                    children: [
                                      TextButton.icon(
                                        onPressed: () => _runNow(r),
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text('Run now'),
                                      ),
                                      TextButton.icon(
                                        onPressed: () => _edit(r),
                                        icon: const Icon(Icons.edit_outlined),
                                        label: const Text('Edit'),
                                      ),
                                      TextButton.icon(
                                        onPressed: () => _delete(r),
                                        icon: const Icon(Icons.delete_outline),
                                        label: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Makes or changes one schedule; pops the routine to save, or null.
class ScheduleEditor extends StatefulWidget {
  final List<Map<String, dynamic>> bots;
  final Map<String, dynamic>? routine;
  const ScheduleEditor({super.key, required this.bots, this.routine});

  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  late final r = widget.routine ?? const <String, dynamic>{};
  late final name = TextEditingController(text: r['name'] as String? ?? '');
  late final prompt = TextEditingController(text: r['prompt'] as String? ?? '');
  late final custom = TextEditingController(text: r['cron'] as String? ?? '');
  late final timezone = TextEditingController(
    text: r['timezone'] as String? ?? 'Europe/London',
  );
  late String? bot =
      r['bot'] as String? ??
      (widget.bots.isEmpty ? null : widget.bots.first['slug'] as String);
  late Repeat repeat;
  late TimeOfDay at;
  late int weekday;
  late int hours;
  late DateTime once;
  late bool webhook = r['webhook'] == true;
  late bool preflight = r['preflight'] == true;
  String? error;

  @override
  void initState() {
    super.initState();
    final cron = r['cron'] as String?;
    final onceAt = DateTime.tryParse(r['once_at'] as String? ?? '');
    once =
        onceAt ??
        DateTime.now().add(const Duration(hours: 1)).copyWith(minute: 0);
    if (cron != null && cron.isNotEmpty) {
      final c = readCron(cron);
      repeat = c.repeat;
      at = c.at;
      weekday = c.weekday;
      hours = c.hours;
    } else {
      repeat = onceAt != null
          ? Repeat.once
          : (r.isNotEmpty && webhook ? Repeat.webhookOnly : Repeat.daily);
      at = const TimeOfDay(hour: 9, minute: 0);
      weekday = 1;
      hours = 4;
    }
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: at);
    if (t != null) setState(() => at = t);
  }

  Future<void> _pickOnce() async {
    final d = await showDatePicker(
      context: context,
      initialDate: once,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(once),
    );
    if (t == null) return;
    setState(() => once = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  void _done() {
    if (bot == null) return setState(() => error = 'Choose a bot');
    if (name.text.trim().isEmpty) {
      return setState(() => error = 'Give it a name');
    }
    if (prompt.text.trim().isEmpty) {
      return setState(() => error = 'Say what the bot should do');
    }
    final cron = repeat == Repeat.custom
        ? custom.text.trim()
        : cronFor(repeat, at: at, weekday: weekday, hours: hours);
    Navigator.pop(context, <String, dynamic>{
      'id': r['id'] ?? 0,
      'bot': bot,
      'name': name.text.trim(),
      'prompt': prompt.text.trim(),
      'cron': cron,
      'timezone': timezone.text.trim(),
      'once_at': repeat == Repeat.once
          ? '${once.year}-${_two(once.month)}-${_two(once.day)}'
                'T${_two(once.hour)}:${_two(once.minute)}'
          : null,
      'webhook': webhook || repeat == Repeat.webhookOnly,
      'preflight': preflight,
      'active': r['active'] ?? true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final time = '${_two(at.hour)}:${_two(at.minute)}';
    return Scaffold(
      appBar: AppBar(
        title: Text(r.isEmpty ? 'New schedule' : 'Edit schedule'),
        actions: [TextButton(onPressed: _done, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Morning mentions',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: bot,
            decoration: const InputDecoration(labelText: 'Bot'),
            items: [
              for (final b in widget.bots)
                DropdownMenuItem(
                  value: b['slug'] as String,
                  child: Text(b['name'] as String? ?? b['slug'] as String),
                ),
            ],
            onChanged: (v) => setState(() => bot = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: prompt,
            minLines: 3,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'What should it do?',
              hintText:
                  'Check my X mentions and LinkedIn comments and queue '
                  'replies for me to approve.',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Repeat>(
            isExpanded: true,
            initialValue: repeat,
            decoration: const InputDecoration(labelText: 'When'),
            items: const [
              DropdownMenuItem(value: Repeat.daily, child: Text('Every day')),
              DropdownMenuItem(
                value: Repeat.weekdays,
                child: Text('Weekdays (Monday to Friday)'),
              ),
              DropdownMenuItem(value: Repeat.weekly, child: Text('Every week')),
              DropdownMenuItem(
                value: Repeat.hours,
                child: Text('Every few hours'),
              ),
              DropdownMenuItem(value: Repeat.once, child: Text('Once')),
              DropdownMenuItem(
                value: Repeat.custom,
                child: Text('Custom (cron)'),
              ),
              DropdownMenuItem(
                value: Repeat.webhookOnly,
                child: Text('Only when called by webhook'),
              ),
            ],
            onChanged: (v) => setState(() => repeat = v ?? repeat),
          ),
          if (repeat == Repeat.weekly)
            DropdownButtonFormField<int>(
              initialValue: weekday,
              decoration: const InputDecoration(labelText: 'Day'),
              items: [
                for (var d = 1; d <= 7; d++)
                  DropdownMenuItem(
                    value: d % 7,
                    child: Text(weekdayNames[d % 7]),
                  ),
              ],
              onChanged: (v) => setState(() => weekday = v ?? weekday),
            ),
          if (const {
            Repeat.daily,
            Repeat.weekdays,
            Repeat.weekly,
          }.contains(repeat))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('At'),
              trailing: Text(time),
              onTap: _pickTime,
            ),
          if (repeat == Repeat.hours)
            DropdownButtonFormField<int>(
              initialValue: hours,
              decoration: const InputDecoration(labelText: 'Every'),
              items: [
                for (final h in const [1, 2, 3, 4, 6, 8, 12])
                  DropdownMenuItem(
                    value: h,
                    child: Text(h == 1 ? 'hour' : '$h hours'),
                  ),
              ],
              onChanged: (v) => setState(() => hours = v ?? hours),
            ),
          if (repeat == Repeat.once)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('On'),
              trailing: Text(
                '${once.year}-${_two(once.month)}-${_two(once.day)} '
                '${_two(once.hour)}:${_two(once.minute)}',
              ),
              onTap: _pickOnce,
            ),
          if (repeat == Repeat.custom)
            TextField(
              controller: custom,
              decoration: const InputDecoration(
                labelText: 'Cron (minute hour day month weekday)',
                hintText: '30 8 * * 1-5',
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: timezone,
            decoration: const InputDecoration(labelText: 'Time zone'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Also run when a webhook is called'),
            subtitle: const Text('Gives you a private address to trigger it'),
            value: webhook || repeat == Repeat.webhookOnly,
            onChanged: repeat == Repeat.webhookOnly
                ? null
                : (v) => setState(() => webhook = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Skip when there is nothing new'),
            subtitle: const Text(
              'System 1 checks first and skips a run it is sure is not needed',
            ),
            value: preflight,
            onChanged: (v) => setState(() => preflight = v),
          ),
        ],
      ),
    );
  }
}
