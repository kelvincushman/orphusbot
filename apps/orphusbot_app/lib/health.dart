// The Health screen (DESIGN §16.1): whether the outside services the bots rely
// on (Google, nodes, xAI, model servers, ntfy, disk) are working, what's wrong
// and how to fix it, and a slim banner on the main screen while anything is red.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'memory.dart' show heardWhen;

/// How long a check has been failing, in plain words.
String failingSince(String? iso, DateTime now) {
  final at = DateTime.tryParse(iso ?? '')?.toLocal();
  if (at == null) return '';
  final minutes = now.difference(at).inMinutes;
  if (minutes < 1) return 'Failing since just now';
  if (minutes < 60) {
    return 'Failing for $minutes minute${minutes == 1 ? '' : 's'}';
  }
  final hm =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final day = heardWhen(iso, now);
  return day == 'today' ? 'Failing since $hm' : 'Failing since $day, $hm';
}

/// What the banner says about the failing checks, or null when all is well.
String? bannerText(List<Map<String, dynamic>> checks) {
  final red = checks.where((c) => c['ok'] != true).toList();
  if (red.isEmpty) return null;
  if (red.length == 1) return '${red.first['problem']}. Tap for Health.';
  return '${red.length} things need attention. Tap for Health.';
}

List<Map<String, dynamic>> _checks(Object? got) =>
    (got as List).cast<Map<String, dynamic>>();

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, required this.api});
  final Api api;
  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  List<Map<String, dynamic>> checks = [];
  bool loading = true;
  bool checking = false;
  String? note;

  @override
  void initState() {
    super.initState();
    _load(() => widget.api.get('/api/health'));
  }

  Future<void> _load(Future<dynamic> Function() ask) async {
    try {
      final got = _checks(await ask());
      if (!mounted) return;
      setState(() {
        checks = got;
        note = null;
      });
    } catch (e) {
      if (mounted) setState(() => note = explain(e));
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          checking = false;
        });
      }
    }
  }

  void _checkNow() {
    setState(() => checking = true);
    _load(() => widget.api.postJson('/api/health/check', {}));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              // Not while the first list is loading: it could land after
              // the check's newer answer.
              onPressed: loading || checking ? null : _checkNow,
              icon: checking
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(checking ? 'Checking…' : 'Check now'),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(note!, style: TextStyle(color: scheme.error)),
            ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (checks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Nothing checked yet. The server checks every 15 minutes; '
                'tap Check now to check straight away.',
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(color: scheme.outline),
              ),
            ),
          for (final c in checks) _check(c, scheme, text, now),
        ],
      ),
    );
  }

  Widget _check(
    Map<String, dynamic> c,
    ColorScheme scheme,
    TextTheme text,
    DateTime now,
  ) {
    final ok = c['ok'] == true;
    final since = failingSince(c['since'] as String?, now);
    // Words as well as colour: the icon has a label and the first line says it.
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ListTile(
        leading: Icon(
          ok ? Icons.check_circle_outline : Icons.error_outline,
          color: ok ? Colors.green.shade700 : scheme.error,
          semanticLabel: ok ? 'Working' : 'Problem',
        ),
        title: Text('${c['label']}'),
        subtitle: ok
            ? const Text('Working')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${c['problem']}',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText('How to fix: ${c['fix']}'),
                  if (since.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        since,
                        style: text.labelMedium?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// A slim red bar at the top of the main screen while any check is failing;
/// tapping it opens Health.
class HealthBanner extends StatefulWidget {
  const HealthBanner({super.key, required this.api});
  final Api api;
  @override
  State<HealthBanner> createState() => HealthBannerState();
}

class HealthBannerState extends State<HealthBanner> {
  String? message;
  Timer? every;

  @override
  void initState() {
    super.initState();
    refresh();
    // ponytail: polled; an event on the stream if two minutes ever feels slow.
    every = Timer.periodic(const Duration(minutes: 2), (_) => refresh());
  }

  @override
  void dispose() {
    every?.cancel();
    super.dispose();
  }

  // Counts requests, so a slow older answer can't replace a newer one.
  int asked = 0;

  /// Asks the server again, such as after Health closes.
  Future<void> refresh() async {
    final mine = ++asked;
    try {
      final got = bannerText(_checks(await widget.api.get('/api/health')));
      if (mounted && mine == asked) setState(() => message = got);
    } catch (_) {
      // Offline or signed out: the rest of the screen says so.
    }
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => HealthScreen(api: widget.api)),
    );
    await refresh();
  }

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      liveRegion: true,
      child: Material(
        color: scheme.errorContainer,
        child: InkWell(
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 20,
                  color: scheme.onErrorContainer,
                  semanticLabel: 'Problem',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
