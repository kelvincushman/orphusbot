// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// SchedulesPage — cron ledger tab (plan §5.5 M-4). M-1 shipped an empty
// scaffold; M-4 wires the WearableSchedulesProvider against /api/schedules
// (S-3, commit 70a0b71), renders each schedule with a human-readable
// cron label + enable switch + long-press menu (edit / run now /
// delete), and opens ScheduleEditSheet on FAB tap.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/wearable_schedule.dart';
import '../wearable_theme.dart';
import '../providers/wearable_schedules_provider.dart';
import 'schedule_edit_sheet.dart';

class SchedulesPage extends StatefulWidget {
  const SchedulesPage({super.key});

  @override
  State<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends State<SchedulesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<WearableSchedulesProvider>().refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      body: SafeArea(
        child: Consumer<WearableSchedulesProvider>(
          builder: (context, provider, _) => _SchedulesBody(provider: provider),
        ),
      ),
      floatingActionButton: Builder(
        builder: (innerContext) => FloatingActionButton(
          onPressed: () async {
            final saved = await ScheduleEditSheet.show(innerContext);
            if (!context.mounted) return;
            if (saved) await context.read<WearableSchedulesProvider>().refresh();
          },
          backgroundColor: WearableColors.primary,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }
}

class _SchedulesBody extends StatelessWidget {
  const _SchedulesBody({required this.provider});
  final WearableSchedulesProvider provider;

  @override
  Widget build(BuildContext context) {
    if (!provider.paired && !provider.isLoading) {
      return const _NotPairedState();
    }
    if (provider.error != null && provider.schedules.isEmpty) {
      return _ErrorState(
        message: provider.error!,
        onRetry: provider.refresh,
      );
    }
    if (provider.schedules.isEmpty && !provider.isLoading) {
      return const _EmptyState();
    }
    return RefreshIndicator(
      color: WearableColors.primary,
      onRefresh: provider.refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),  // bottom pad for FAB
        itemCount: provider.schedules.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (context, i) => _ScheduleRow(schedule: provider.schedules[i]),
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.schedule});
  final WearableSchedule schedule;

  @override
  Widget build(BuildContext context) {
    final summary = CronSummary.describe(schedule.cron);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _edit(context),
        onLongPress: () => _openMenu(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          schedule.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: WearableColors.foreground,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          summary.label,
                          style: const TextStyle(color: WearableColors.primary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: schedule.enabled,
                    activeThumbColor: WearableColors.primary,
                    onChanged: (v) async {
                      try {
                        await context.read<WearableSchedulesProvider>().setEnabled(schedule.id, v);
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Toggle failed: $e')),
                        );
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                schedule.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.3),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _MetaChip(
                    icon: Icons.send_outlined,
                    label: schedule.channel,
                  ),
                  const SizedBox(width: 6),
                  _MetaChip(
                    icon: Icons.schedule_outlined,
                    label: _nextFireLabel(schedule),
                  ),
                  const Spacer(),
                  if (schedule.lastRunAt != null)
                    Text(
                      _relativeTime(schedule.lastRunAt!),
                      style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _nextFireLabel(WearableSchedule s) {
    if (!s.enabled) return 'disabled';
    if (s.nextRunAt <= 0) return '—';
    return 'next ${_relativeTime(s.nextRunAt, future: true)}';
  }

  static String _relativeTime(int epochMs, {bool future = false}) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    final diff = future ? dt.difference(now) : now.difference(dt);
    final s = diff.inSeconds.abs();
    if (s < 60) return future ? 'soon' : 'just now';
    if (diff.inMinutes.abs() < 60) return '${diff.inMinutes.abs()}m';
    if (diff.inHours.abs() < 24) return '${diff.inHours.abs()}h';
    if (diff.inDays.abs() < 7) return '${diff.inDays.abs()}d';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> _edit(BuildContext context) async {
    // Capture both the provider AND the messenger BEFORE any await so we
    // never reach across an async gap into a possibly-disposed context.
    // refresh() failures need to surface — silently swallowing them leaves
    // the user looking at stale list data with no indication anything went
    // wrong.
    final provider = context.read<WearableSchedulesProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final saved = await ScheduleEditSheet.show(context, initial: schedule);
    if (!saved) return;
    try {
      await provider.refresh();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Refresh failed: $e')));
    }
  }

  Future<void> _openMenu(BuildContext context) async {
    final provider = context.read<WearableSchedulesProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: WearableColors.background,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: WearableColors.foreground),
              title: const Text('Edit', style: TextStyle(color: WearableColors.foreground)),
              onTap: () => Navigator.of(ctx).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow_outlined, color: WearableColors.primary),
              title: const Text('Run now', style: TextStyle(color: WearableColors.foreground)),
              subtitle: const Text(
                'Dispatch immediately, outside the cron cadence.',
                style: TextStyle(color: WearableColors.mutedFg, fontSize: 11),
              ),
              onTap: () => Navigator.of(ctx).pop('run-now'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: WearableColors.destructive),
              title: const Text(
                'Delete',
                style: TextStyle(color: WearableColors.destructive),
              ),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'edit':
        await _edit(context);
      case 'run-now':
        try {
          await provider.runNow(schedule.id);
          messenger.showSnackBar(const SnackBar(content: Text('Scheduled to run now.')));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('Run-now failed: $e')));
        }
      case 'delete':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: WearableColors.card,
            title: const Text('Delete this schedule?'),
            content: Text(
              '"${schedule.name}" will stop firing. This cannot be undone.',
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Keep'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: WearableColors.destructive),
                ),
              ),
            ],
          ),
        );
        // Second async gap — re-check that the row still has a live context
        // before continuing. provider + messenger were captured pre-bottom-
        // sheet so they're safe; this guard is defence-in-depth against a
        // late dialog dismissal racing a parent rebuild.
        if (!context.mounted) return;
        if (confirm != true) return;
        try {
          await provider.delete(schedule.id);
          messenger.showSnackBar(const SnackBar(content: Text('Schedule deleted.')));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
    }
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: WearableColors.cardAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: WearableColors.mutedFg),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 10)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.alarm_outlined,
            color: WearableColors.mutedFg.withValues(alpha: 0.5),
            size: 40,
          ),
          const SizedBox(height: 12),
          const Text(
            'No schedules yet',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tap + to create a recurring task.',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 11),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.link_off_outlined,
              color: WearableColors.mutedFg.withValues(alpha: 0.5),
              size: 40,
            ),
            const SizedBox(height: 12),
            const Text(
              'Pair this app to a Wearable server to manage schedules.',
              textAlign: TextAlign.center,
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
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
      ),
    );
  }
}
