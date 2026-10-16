// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// HomeStatusPage — Wearable server health + harness activity dashboard.
//
// Replaces the Knowledge placeholder in the bottom nav (index 2).
// Data sources:
//   • WearableConnectionProvider  — server health (30 s probe)
//   • WearableMissionControlProvider — KPIs + in-flight tasks (8 s poll)
//
// Both providers are registered app-wide in main.dart. This page calls
// `start()` / `stop()` on WearableMissionControlProvider to gate polling to
// when the tab is visible, matching the pattern in WearableMissionControlPage.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/wearable_mission_control.dart';
import '../wearable_theme.dart';
import '../wearable_client.dart';
import '../providers/wearable_connection_provider.dart';
import '../providers/wearable_mission_control_provider.dart';

class HomeStatusPage extends StatefulWidget {
  const HomeStatusPage({super.key});

  @override
  State<HomeStatusPage> createState() => _HomeStatusPageState();
}

class _HomeStatusPageState extends State<HomeStatusPage> {
  Timer? _agoTicker;
  String? _serverBaseUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<WearableMissionControlProvider>().start();
    });
    // 1 Hz re-render to keep "Xs ago" labels current between polls.
    _agoTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _loadBaseUrl();
  }

  Future<void> _loadBaseUrl() async {
    final creds = await WearableClient.instance.loadCredentials();
    if (mounted) setState(() => _serverBaseUrl = creds?.baseUrl);
  }

  @override
  void dispose() {
    _agoTicker?.cancel();
    _agoTicker = null;
    context.read<WearableMissionControlProvider>().stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      body: SafeArea(
        child: Consumer2<WearableConnectionProvider, WearableMissionControlProvider>(
          builder: (context, conn, mc, _) {
            return RefreshIndicator(
              color: WearableColors.primary,
              onRefresh: () async {
                conn.poke();
                await mc.refresh();
              },
              child: _HomeStatusBody(
                conn: conn,
                mc: mc,
                serverBaseUrl: _serverBaseUrl,
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _HomeStatusBody extends StatelessWidget {
  const _HomeStatusBody({
    required this.conn,
    required this.mc,
    required this.serverBaseUrl,
  });

  final WearableConnectionProvider conn;
  final WearableMissionControlProvider mc;
  final String? serverBaseUrl;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 100),
      children: [
        _ServerHealthCard(conn: conn, serverBaseUrl: serverBaseUrl),
        const SizedBox(height: 16),
        _McSection(mc: mc),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Server health card
// ---------------------------------------------------------------------------

class _ServerHealthCard extends StatelessWidget {
  const _ServerHealthCard({required this.conn, required this.serverBaseUrl});

  final WearableConnectionProvider conn;
  final String? serverBaseUrl;

  @override
  Widget build(BuildContext context) {
    final status = conn.status;
    final lastHealthy = conn.lastHealthyAt;

    final (color, icon, label) = switch (status) {
      WearableConnectionStatus.connected => (WearableColors.primary, Icons.cloud_done_outlined, 'Connected'),
      WearableConnectionStatus.syncing => (WearableColors.warning, Icons.sync_outlined, 'Syncing…'),
      WearableConnectionStatus.disconnected => (WearableColors.mutedFg, Icons.cloud_off_outlined, 'Disconnected'),
      WearableConnectionStatus.error => (WearableColors.destructive, Icons.error_outline, 'Error'),
      WearableConnectionStatus.unpaired => (WearableColors.mutedFg, Icons.link_off_outlined, 'Unpaired'),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(WearableRadii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: status == WearableConnectionStatus.connected
                      ? [
                          BoxShadow(
                            color: WearableColors.accentSky.withValues(alpha: 0.5),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Wearable Server',
                style: TextStyle(
                  color: WearableColors.foreground,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(9999),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (serverBaseUrl != null) ...[
            const SizedBox(height: 8),
            Text(
              serverBaseUrl!,
              style: const TextStyle(
                color: WearableColors.mutedFg,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (lastHealthy != null) ...[
            const SizedBox(height: 4),
            Text(
              'Last healthy ${_agoFromDate(lastHealthy)} ago',
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
            ),
          ] else if (status == WearableConnectionStatus.unpaired) ...[
            const SizedBox(height: 8),
            const Text(
              'Open the drawer → Pair to Wearable to connect.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mission Control section (KPIs + active tasks)
// ---------------------------------------------------------------------------

class _McSection extends StatelessWidget {
  const _McSection({required this.mc});

  final WearableMissionControlProvider mc;

  @override
  Widget build(BuildContext context) {
    final data = mc.data;

    if (!mc.paired && !mc.isLoading && data == null) {
      return const _UnpairedMcState();
    }
    if (data == null && mc.error != null) {
      return _McErrorState(message: mc.error!, onRetry: mc.refresh);
    }
    if (data == null) {
      return const _McSkeleton();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mc.error != null) _StaleBanner(message: mc.error!, onRetry: mc.refresh),
        _KpiRow(data: data),
        const SizedBox(height: 16),
        _ActiveTasksSection(tasks: data.active),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// KPI row (4 compact gauge tiles)
// ---------------------------------------------------------------------------

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.data});

  final WearableMissionControl data;

  @override
  Widget build(BuildContext context) {
    final today = data.budget.today;
    final caps = data.budget.caps;
    final capCents = caps?.usdCentsDay ?? 0;
    final burnPct = capCents > 0 ? (today.usdCents / capCents).clamp(0.0, 1.0) : 0.0;
    final activeCount = data.active.length;
    final ccs24h = _countSince(data.recentCourseCorrections, 24 * 3600 * 1000);

    final tracked = data.active.where((t) => t.completion.method == 'children').toList();
    final avgPct = tracked.isEmpty
        ? 0.0
        : tracked.map((t) => t.completion.pct).reduce((a, b) => a + b) / tracked.length;
    final avgValue = tracked.isEmpty ? '—' : '${(avgPct * 100).round()}%';
    final avgSub = tracked.isEmpty ? 'no children-tracked' : 'of ${tracked.length} tracked';

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.5,
      children: [
        _KpiTile(label: 'Active tasks', value: '$activeCount', sub: 'in flight'),
        _KpiTile(
          label: 'Burned today',
          value: _fmtUsd(today.usdCents),
          sub: capCents > 0
              ? 'of ${_fmtUsd(capCents)} · ${_fmtTokens(today.tokens)} tok'
              : '${_fmtTokens(today.tokens)} tok (no cap)',
          progress: capCents > 0 ? burnPct.toDouble() : null,
        ),
        _KpiTile(label: 'Avg completion', value: avgValue, sub: avgSub),
        _KpiTile(label: 'Corrections 24h', value: '$ccs24h', sub: 'course corrections'),
      ],
    );
  }

  static int _countSince(List<WearableCourseCorrection> rows, int ms) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - ms;
    return rows.where((c) => c.t >= cutoff).length;
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    required this.label,
    required this.value,
    required this.sub,
    this.progress,
  });

  final String label;
  final String value;
  final String sub;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final barColor = p != null
        ? (p >= 0.95
            ? WearableColors.destructive
            : (p >= 0.80 ? WearableColors.warning : WearableColors.primary))
        : WearableColors.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border.all(color: WearableColors.border),
        borderRadius: BorderRadius.circular(WearableRadii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: WearableColors.mutedFg,
              fontSize: 10,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
          ),
          if (p != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: p,
                minHeight: 4,
                backgroundColor: WearableColors.cardAlt,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
                semanticsLabel: '$label burn',
                semanticsValue: '${(p * 100).round()} percent',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Active tasks section
// ---------------------------------------------------------------------------

class _ActiveTasksSection extends StatelessWidget {
  const _ActiveTasksSection({required this.tasks});

  final List<WearableMissionControlTaskRow> tasks;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border.all(color: WearableColors.border),
        borderRadius: BorderRadius.circular(WearableRadii.lg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                const Text(
                  'HARNESS ACTIVITY',
                  style: TextStyle(
                    color: WearableColors.mutedFg,
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (tasks.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: WearableColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(9999),
                    ),
                    child: Text(
                      '${tasks.length} running',
                      style: const TextStyle(
                        color: WearableColors.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(height: 1, color: WearableColors.border),
          if (tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 16, 14, 16),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline, color: WearableColors.mutedFg, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Idle — no tasks running',
                    style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
                  ),
                ],
              ),
            )
          else
            ...tasks.map((t) => _ActiveTaskRow(task: t)),
        ],
      ),
    );
  }
}

class _ActiveTaskRow extends StatelessWidget {
  const _ActiveTaskRow({required this.task});

  final WearableMissionControlTaskRow task;

  @override
  Widget build(BuildContext context) {
    final pct = task.completion.pct.clamp(0.0, 1.0);
    final burnColor = task.burn.pctMax >= 0.95
        ? WearableColors.destructive
        : (task.burn.pctMax >= 0.80 ? WearableColors.warning : WearableColors.primary);

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: WearableColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RolePill(role: task.role),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.prompt ?? task.taskId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(pct * 100).round()}%',
                style: const TextStyle(
                  color: WearableColors.mutedFg,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: WearableColors.cardAlt,
              valueColor: AlwaysStoppedAnimation<Color>(burnColor),
              semanticsLabel: 'completion',
              semanticsValue: '${(pct * 100).round()} percent',
            ),
          ),
          const SizedBox(height: 6),
          _DoingRow(doing: task.doing),
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.role});

  final String role;

  static Color _roleColor(String role) {
    switch (role) {
      case 'comms':
        return WearableColors.info;
      case 'content':
        return WearableColors.accentSky;
      case 'ops':
        return WearableColors.warning;
      case 'research':
        return WearableColors.accentViolet;
      default:
        return WearableColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _roleColor(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        role,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _DoingRow extends StatelessWidget {
  const _DoingRow({required this.doing});

  final WearableTaskDoing? doing;

  @override
  Widget build(BuildContext context) {
    final d = doing;
    if (d == null) {
      return const Row(
        children: [
          Icon(Icons.circle, color: WearableColors.mutedFg, size: 6),
          SizedBox(width: 6),
          Text('idle', style: TextStyle(color: WearableColors.mutedFg, fontSize: 11)),
        ],
      );
    }
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: WearableColors.primary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          d.kind == 'tool_call' ? '⚙ ' : '▶ ',
          style: const TextStyle(color: WearableColors.primary, fontSize: 11),
        ),
        Expanded(
          child: Text(
            d.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: WearableColors.foreground, fontSize: 11),
          ),
        ),
        Text(
          ' · ${_ago(DateTime.now().millisecondsSinceEpoch - d.sinceMs)} ago',
          style: const TextStyle(color: WearableColors.mutedFg, fontSize: 10),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty / error / skeleton / stale-banner states
// ---------------------------------------------------------------------------

class _UnpairedMcState extends StatelessWidget {
  const _UnpairedMcState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border.all(color: WearableColors.border),
        borderRadius: BorderRadius.circular(WearableRadii.lg),
      ),
      child: Column(
        children: [
          Icon(
            Icons.link_off_outlined,
            color: WearableColors.mutedFg.withValues(alpha: 0.5),
            size: 36,
          ),
          const SizedBox(height: 12),
          const Text(
            'Pair this app to a Wearable server to see harness status.',
            textAlign: TextAlign.center,
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _McErrorState extends StatelessWidget {
  const _McErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border.all(color: WearableColors.border),
        borderRadius: BorderRadius.circular(WearableRadii.lg),
      ),
      child: Column(
        children: [
          const Icon(Icons.warning_amber_outlined, color: WearableColors.destructive, size: 28),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(backgroundColor: WearableColors.primary),
            child: const Text('Retry', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _McSkeleton extends StatelessWidget {
  const _McSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        3,
        (_) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          height: 72,
          decoration: BoxDecoration(
            color: WearableColors.card,
            border: Border.all(color: WearableColors.border),
            borderRadius: BorderRadius.circular(WearableRadii.md),
          ),
        ),
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: WearableColors.warning.withValues(alpha: 0.15),
        border: Border.all(color: WearableColors.warning.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(WearableRadii.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, color: WearableColors.warning, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: WearableColors.warning, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text(
              'Retry',
              style: TextStyle(color: WearableColors.warning, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatters (replicated from wearable_mission_control_page.dart — both files
// use file-private functions so they don't need a shared import)
// ---------------------------------------------------------------------------

String _ago(int ms) {
  final clamped = ms.clamp(0, 1 << 53);
  if (clamped < 60000) return '${(clamped ~/ 1000).clamp(1, 59)}s';
  if (clamped < 3600000) return '${clamped ~/ 60000}m';
  if (clamped < 86400000) return '${clamped ~/ 3600000}h';
  return '${clamped ~/ 86400000}d';
}

String _agoFromDate(DateTime dt) {
  final ms = DateTime.now().difference(dt).inMilliseconds.clamp(0, 1 << 53);
  return _ago(ms);
}

String _fmtTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

String _fmtUsd(int cents) {
  final n = cents / 100;
  if (n >= 100) return '\$${n.toStringAsFixed(0)}';
  if (n >= 10) return '\$${n.toStringAsFixed(1)}';
  return '\$${n.toStringAsFixed(2)}';
}
