// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableMissionControlPage — asynchronous-PM view that mirrors the dashboard
// front-page Mission Control section. KPI strip + in-flight task cards +
// course-correction feed. Polls /api/mission-control via
// WearableMissionControlProvider.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/wearable_shell_provider.dart';

import '../models/wearable_mission_control.dart';
import '../models/wearable_task.dart';
import '../wearable_theme.dart';
import '../providers/wearable_mission_control_provider.dart';
import 'task_detail_page.dart';

class WearableMissionControlPage extends StatefulWidget {
  const WearableMissionControlPage({super.key});

  @override
  State<WearableMissionControlPage> createState() => _WearableMissionControlPageState();
}

class _WearableMissionControlPageState extends State<WearableMissionControlPage> {
  final Set<String> _expanded = <String>{};
  Timer? _agoTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<WearableMissionControlProvider>().start();
    });
    // 1 Hz re-render so the "Xs ago" labels keep moving between the 8s
    // provider polls. setState with no state mutation just rebuilds the
    // subtree; cards are cheap (no animations, no layout changes).
    _agoTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _agoTicker?.cancel();
    _agoTicker = null;
    // Provider is owned by an ancestor (e.g. ChangeNotifierProvider in
    // wearable_root.dart). Stop polling so backgrounded pages don't keep firing.
    context.read<WearableMissionControlProvider>().stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Mission Control'),
        backgroundColor: WearableColors.background,
        foregroundColor: WearableColors.foreground,
        elevation: 0,
      ),
      body: SafeArea(
        child: Consumer<WearableMissionControlProvider>(
          builder: (context, provider, _) {
            return RefreshIndicator(
              color: WearableColors.primary,
              onRefresh: provider.refresh,
              child: _MissionControlBody(
                provider: provider,
                expanded: _expanded,
                onToggleExpand: (id) {
                  setState(() {
                    if (_expanded.contains(id)) {
                      _expanded.remove(id);
                    } else {
                      _expanded.add(id);
                    }
                  });
                },
                onOpenDetail: _openDetail,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, String taskId) async {
    final provider = context.read<WearableMissionControlProvider>();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: taskId)),
    );
    if (mounted) await provider.refresh();
  }
}

class _MissionControlBody extends StatelessWidget {
  const _MissionControlBody({
    required this.provider,
    required this.expanded,
    required this.onToggleExpand,
    required this.onOpenDetail,
  });

  final WearableMissionControlProvider provider;
  final Set<String> expanded;
  final ValueChanged<String> onToggleExpand;
  final Future<void> Function(BuildContext, String) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final data = provider.data;
    if (!provider.paired && !provider.isLoading && data == null) {
      return _scrollWrap(const _NotPairedState());
    }
    if (data == null && provider.error != null) {
      return _scrollWrap(_ErrorState(message: provider.error!, onRetry: provider.refresh));
    }
    if (data == null) {
      return _scrollWrap(const _SkeletonState());
    }
    final tasks = data.active;
    final corrections = data.recentCourseCorrections;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (provider.error != null)
          _StaleBanner(message: provider.error!, onRetry: provider.refresh),
        _KpiStrip(data: data),
        const SizedBox(height: 16),
        if (tasks.isEmpty)
          const _EmptyTasksState()
        else
          ...tasks.map(
            (t) => _TaskCard(
              task: t,
              expanded: expanded.contains(t.taskId),
              onToggleExpand: () => onToggleExpand(t.taskId),
              onOpenDetail: () => onOpenDetail(context, t.taskId),
            ),
          ),
        const SizedBox(height: 24),
        _FeedSection(corrections: corrections),
      ],
    );
  }

  Widget _scrollWrap(Widget child) {
    // AlwaysScrollableScrollPhysics alone is enough to keep RefreshIndicator
    // triggerable; the 80-px spacer that used to live here was dead air.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [child],
    );
  }
}

// ---------------------------------------------------------------------------
// KPI strip
// ---------------------------------------------------------------------------

class _KpiStrip extends StatelessWidget {
  const _KpiStrip({required this.data});

  final WearableMissionControl data;

  @override
  Widget build(BuildContext context) {
    final today = data.budget.today;
    final caps = data.budget.caps;
    final capCents = caps?.usdCentsDay ?? 0;
    final burnPct = capCents > 0 ? (today.usdCents / capCents).clamp(0.0, 1.0) : 0.0;
    final activeCount = data.active.length;
    final ccs24h = _countSince(data.recentCourseCorrections, 24 * 3600 * 1000);

    // Average completion only across `children`-method rows. `attempts` and
    // `elapsed` rise as a task is in trouble; mixing them in produces a
    // headline number that climbs when things go wrong.
    final tracked = data.active.where((t) => t.completion.method == 'children').toList();
    final avgPct = tracked.isEmpty
        ? 0.0
        : tracked.map((t) => t.completion.pct).reduce((a, b) => a + b) / tracked.length;
    final avgValue = tracked.isEmpty ? '—' : '${(avgPct * 100).round()}%';
    final avgSub = tracked.isEmpty
        ? 'no children-tracked'
        : 'of ${tracked.length} tracked';

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
          // Headline = USD (the actual cap axis); tokens demoted to sub.
          value: _fmtUsd(today.usdCents),
          sub: capCents > 0
              ? 'of ${_fmtUsd(capCents)} · ${_fmtTokens(today.tokens)} tok'
              : '${_fmtTokens(today.tokens)} tok (no cap)',
          progress: capCents > 0 ? burnPct.toDouble() : null,
        ),
        _KpiTile(label: 'Avg completion', value: avgValue, sub: avgSub),
        _KpiTile(label: 'Course corrections', value: '$ccs24h', sub: 'last 24h'),
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
// Per-task card
// ---------------------------------------------------------------------------

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.expanded,
    required this.onToggleExpand,
    required this.onOpenDetail,
  });

  final WearableMissionControlTaskRow task;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final pct = task.completion.pct.clamp(0.0, 1.0);
    final burnColor = task.burn.pctMax >= 0.95
        ? WearableColors.destructive
        : (task.burn.pctMax >= 0.80 ? WearableColors.warning : WearableColors.primary);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border(
          left: BorderSide(color: _roleColor(task.role), width: 3),
          top: BorderSide(color: WearableColors.border),
          right: BorderSide(color: WearableColors.border),
          bottom: BorderSide(color: WearableColors.border),
        ),
        borderRadius: BorderRadius.circular(WearableRadii.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onToggleExpand,
        onLongPress: onOpenDetail,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    task.taskId.length >= 8 ? task.taskId.substring(0, 8) : task.taskId,
                    style: const TextStyle(
                      color: WearableColors.mutedFg,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Pill(text: task.role, color: WearableColors.primary),
                  if (_statusLabel(task.status) != null) ...[
                    const SizedBox(width: 6),
                    _Pill(
                      text: _statusLabel(task.status)!,
                      color: _statusColor(task.status),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    '${_ago(task.createdAt)} ago',
                    style: const TextStyle(
                      color: WearableColors.mutedFg,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                task.prompt ?? task.taskId,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: WearableColors.foreground,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 6,
                  backgroundColor: WearableColors.cardAlt,
                  valueColor: const AlwaysStoppedAnimation<Color>(WearableColors.primary),
                  semanticsLabel: 'completion',
                  semanticsValue: '${(pct * 100).round()} percent',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                task.completion.detail,
                style: const TextStyle(color: WearableColors.mutedFg, fontSize: 10),
              ),
              const SizedBox(height: 10),
              _BurnRow(
                label: 'tokens',
                used: task.burn.tokensIn + task.burn.tokensOut,
                budget: task.burn.tokensInBudget + task.burn.tokensOutBudget,
                fmt: _fmtTokens,
                color: burnColor,
              ),
              const SizedBox(height: 4),
              _BurnRow(
                label: 'elapsed',
                used: task.burn.wallClockMs,
                budget: task.burn.wallClockMsBudget,
                fmt: _fmtMs,
                color: burnColor,
              ),
              if (task.workerKind != null || task.workerName != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${task.workerKind ?? '?'}:${task.workerName ?? '?'}',
                  style: const TextStyle(
                    color: WearableColors.mutedFg,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 10),
              _DoingNow(doing: task.doing),
              if (expanded) ...[
                const SizedBox(height: 10),
                Container(height: 1, color: WearableColors.border),
                const SizedBox(height: 8),
                if (task.lastHandoff != null) ...[
                  _HandoffRow(handoff: task.lastHandoff!),
                  const SizedBox(height: 8),
                ],
                if (task.lastCorrection != null)
                  _CorrectionRow(correction: task.lastCorrection!),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onOpenDetail,
                    child: const Text(
                      'Open detail →',
                      style: TextStyle(color: WearableColors.primary, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

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
}

class _BurnRow extends StatelessWidget {
  const _BurnRow({
    required this.label,
    required this.used,
    required this.budget,
    required this.fmt,
    required this.color,
  });

  final String label;
  final int used;
  final int budget;
  final String Function(int) fmt;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = budget > 0 ? (used / budget).clamp(0.0, 1.0) : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 3,
              backgroundColor: WearableColors.cardAlt,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${fmt(used)} / ${fmt(budget)}',
          style: const TextStyle(
            color: WearableColors.mutedFg,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

class _DoingNow extends StatelessWidget {
  const _DoingNow({required this.doing});

  final WearableTaskDoing? doing;

  @override
  Widget build(BuildContext context) {
    final d = doing;
    if (d == null) {
      return Row(
        children: const [
          _PulseDot(active: false),
          SizedBox(width: 6),
          Text('idle', style: TextStyle(color: WearableColors.mutedFg, fontSize: 11)),
        ],
      );
    }
    return Row(
      children: [
        const _PulseDot(active: true),
        const SizedBox(width: 6),
        Text(
          d.kind == 'tool_call' ? '⚙' : '▶',
          style: const TextStyle(color: WearableColors.primary, fontSize: 11),
        ),
        const SizedBox(width: 4),
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

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.active});
  final bool active;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    // Animation start is deferred to didChangeDependencies — that's the first
    // hook with a usable MediaQuery, and is also called whenever the
    // user-pref `disableAnimations` flips.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    _syncController();
  }

  @override
  void didUpdateWidget(covariant _PulseDot old) {
    super.didUpdateWidget(old);
    _syncController();
  }

  /// Single source of truth for whether the controller should be running.
  /// Called only from lifecycle hooks (never from build) so we never trigger
  /// a setState during the build phase.
  void _syncController() {
    final shouldRun = widget.active && !_reduceMotion;
    if (shouldRun && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!shouldRun && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || _reduceMotion) {
      // Honor disableAnimations: render a static dot in the active hue so the
      // operator still sees the "running" state via color, no motion.
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.active ? WearableColors.primary : WearableColors.mutedFg,
          shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: WearableColors.primary.withValues(alpha: 0.3 + 0.7 * (1 - _ctrl.value)),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: WearableColors.accentSky.withValues(alpha: 0.5 * (1 - _ctrl.value)),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}

class _HandoffRow extends StatelessWidget {
  const _HandoffRow({required this.handoff});
  final WearableMissionHandoff handoff;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Pill(
          text: '${_kindIcon(handoff.kind)} ${handoff.kind.replaceAll('_', ' ')}',
          color: _kindColor(handoff.kind),
        ),
        const SizedBox(width: 8),
        Text(
          '${_ago(handoff.t)} ago',
          style: const TextStyle(
            color: WearableColors.mutedFg,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            handoff.summary,
            maxLines: 3,
            style: const TextStyle(color: WearableColors.foreground, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _CorrectionRow extends StatelessWidget {
  const _CorrectionRow({required this.correction});
  final WearableCourseCorrection correction;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Pill(
          text: '${_kindIcon(correction.kind)} ${correction.kind.replaceAll('_', ' ')}',
          color: _kindColor(correction.kind),
        ),
        const SizedBox(width: 8),
        Text(
          '${_ago(correction.t)} ago',
          style: const TextStyle(
            color: WearableColors.mutedFg,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            correction.summary.isNotEmpty ? correction.summary : correction.trigger,
            maxLines: 3,
            style: const TextStyle(color: WearableColors.foreground, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Course-correction feed (full list)
// ---------------------------------------------------------------------------

class _FeedSection extends StatelessWidget {
  const _FeedSection({required this.corrections});

  final List<WearableCourseCorrection> corrections;

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
            child: Text(
              'COURSE CORRECTIONS',
              style: const TextStyle(
                color: WearableColors.mutedFg,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (corrections.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 8, 14, 16),
              child: Text(
                'No course corrections.',
                style: TextStyle(color: WearableColors.mutedFg, fontSize: 12),
              ),
            )
          else
            ...corrections.take(50).map(
                  (c) => Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    child: _CorrectionRow(correction: c),
                  ),
                ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty / error / not-paired / banner
// ---------------------------------------------------------------------------

class _EmptyTasksState extends StatelessWidget {
  const _EmptyTasksState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: WearableColors.card,
        border: Border.all(color: WearableColors.border),
        borderRadius: BorderRadius.circular(WearableRadii.lg),
      ),
      child: Column(
        children: [
          const Icon(Icons.checklist_rtl, color: WearableColors.mutedFg, size: 32),
          const SizedBox(height: 8),
          const Text(
            'No tasks running.',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => context.read<WearableShellProvider>().setIndex(0),
            icon: const Icon(Icons.forum_outlined, size: 16),
            label: const Text('Start in Chat'),
            style: ElevatedButton.styleFrom(
              backgroundColor: WearableColors.primary,
              foregroundColor: WearableColors.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _NotPairedState extends StatelessWidget {
  const _NotPairedState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.link_off_outlined, color: WearableColors.mutedFg.withValues(alpha: 0.5), size: 40),
          const SizedBox(height: 12),
          const Text(
            'Pair this app to a Wearable server to see Mission Control.',
            textAlign: TextAlign.center,
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.warning_amber_outlined, color: WearableColors.destructive, size: 32),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
          const SizedBox(height: 16),
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

class _SkeletonState extends StatelessWidget {
  const _SkeletonState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: List.generate(
          4,
          (_) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            height: 96,
            decoration: BoxDecoration(
              color: WearableColors.card,
              border: Border.all(color: WearableColors.border),
              borderRadius: BorderRadius.circular(WearableRadii.md),
            ),
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
// Tiny shared widgets
// ---------------------------------------------------------------------------

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w500),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatters + kind→color
// ---------------------------------------------------------------------------

String _ago(int t) {
  // Clamp the delta to >= 0 — a future-stamped event (e.g. fallback `t = 0`
  // path or clock skew) would otherwise render as `-Xs ago`. The web side
  // applies the same clamp via `Math.max(1, ...)`.
  final ms = (DateTime.now().millisecondsSinceEpoch - t).clamp(0, 1 << 53);
  if (ms < 60_000) return '${(ms ~/ 1000).clamp(1, 59)}s';
  if (ms < 3_600_000) return '${ms ~/ 60_000}m';
  if (ms < 86_400_000) return '${ms ~/ 3_600_000}h';
  return '${ms ~/ 86_400_000}d';
}

String _fmtTokens(int n) {
  if (n >= 1_000_000) return '${(n / 1_000_000).toStringAsFixed(1)}M';
  if (n >= 1_000) return '${(n / 1_000).toStringAsFixed(1)}k';
  return '$n';
}

String _fmtUsd(int cents) {
  final n = cents / 100;
  if (n >= 100) return '\$${n.toStringAsFixed(0)}';
  if (n >= 10) return '\$${n.toStringAsFixed(1)}';
  return '\$${n.toStringAsFixed(2)}';
}

String _fmtMs(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 60_000) return '${(ms / 1000).toStringAsFixed(1)}s';
  return '${(ms ~/ 60_000)}m';
}

Color _kindColor(String kind) {
  // Canonical mapping (matches src/dashboard-html.ts kind-* CSS classes):
  //   attempt_boundary  → warning  (something stalled and is being retried)
  //   worker_failover   → destructive (a worker died)
  //   completion_check  → info  (a gate fired — informational handoff)
  //   child_dispatch / child_result → mutedFg (operational, not problem)
  switch (kind) {
    case 'attempt_boundary':
      return WearableColors.warning;
    case 'worker_failover':
      return WearableColors.destructive;
    case 'completion_check':
      return WearableColors.info;
    default:
      return WearableColors.mutedFg;
  }
}

/// Returns a human-readable label for `status`, or null if the status is the
/// default running/terminal state where a separate pill would just add noise.
String? _statusLabel(WearableTaskStatus s) {
  switch (s) {
    case WearableTaskStatus.pendingInput:
      return 'pending input';
    case WearableTaskStatus.awaitingChildren:
      return 'awaiting children';
    case WearableTaskStatus.unknown:
      return 'unknown';
    case WearableTaskStatus.active:
    case WearableTaskStatus.completed:
    case WearableTaskStatus.failed:
      return null;
  }
}

Color _statusColor(WearableTaskStatus s) {
  switch (s) {
    case WearableTaskStatus.pendingInput:
      return WearableColors.warning;
    case WearableTaskStatus.awaitingChildren:
      return WearableColors.info;
    default:
      return WearableColors.mutedFg;
  }
}

String _kindIcon(String kind) {
  switch (kind) {
    case 'attempt_boundary':
      return '↻';
    case 'worker_failover':
      return '→';
    case 'completion_check':
      return '⚠';
    case 'child_dispatch':
      return '↗';
    case 'child_result':
      return '↘';
    default:
      return '·';
  }
}
