// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// TasksLedgerPage — carousel-by-status task overview (plan §5.4 M-3 restyle).
// Replaces the segmented-control + filtered list with three horizontal card
// carousels (Active / Needs input / Done) so every group is visible from one
// screen. Tapping a card navigates to TaskDetailPage (unchanged). Data is
// fetched via three parallel WearableClient.listTasks calls — the provider and
// model are untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/wearable_task.dart';
import '../wearable_client.dart';
import '../wearable_theme.dart';
import '../providers/wearable_tasks_provider.dart';
import '../widgets/wearable_task_card.dart';
import 'task_detail_page.dart';

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

class TasksLedgerPage extends StatefulWidget {
  const TasksLedgerPage({super.key});

  @override
  State<TasksLedgerPage> createState() => _TasksLedgerPageState();
}

class _TasksLedgerPageState extends State<TasksLedgerPage> {
  // All-status task lists fetched in parallel.
  List<WearableTaskSummary> _active = const [];
  List<WearableTaskSummary> _pendingInput = const [];
  List<WearableTaskSummary> _done = const [];

  bool _loading = false;
  bool _paired = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = WearableClient.instance;
      final paired = await client.isPaired();
      if (!mounted) return;
      if (!paired) {
        setState(() {
          _paired = false;
          _loading = false;
          _active = const [];
          _pendingInput = const [];
          _done = const [];
        });
        return;
      }
      // Fetch all three statuses in parallel.
      final results = await Future.wait([
        client.listTasks(status: WearableTaskStatus.active, limit: 50),
        client.listTasks(status: WearableTaskStatus.pendingInput, limit: 50),
        client.listTasks(status: WearableTaskStatus.completed, limit: 50),
      ]);
      if (!mounted) return;
      setState(() {
        _paired = true;
        _active = results[0];
        _pendingInput = results[1];
        _done = results[2];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach Wearable: $e';
        _loading = false;
      });
    }
  }

  Future<void> _openDetail(WearableTaskSummary task) async {
    final tasksProvider = context.read<WearableTasksProvider>();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: task.taskId)),
    );
    // Refresh on return — server state may have changed in detail page.
    if (mounted) {
      await _refresh();
      // Keep provider in sync so other consumers (if any) also reflect changes.
      tasksProvider.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _active.isEmpty && _pendingInput.isEmpty && _done.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: WearableColors.primary),
      );
    }
    if (!_paired && !_loading) {
      return const _NotPairedState();
    }
    if (_error != null && _active.isEmpty && _pendingInput.isEmpty && _done.isEmpty) {
      return _ErrorState(message: _error!, onRetry: _refresh);
    }

    return RefreshIndicator(
      color: WearableColors.primary,
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // Active carousel
          SliverToBoxAdapter(
            child: _SectionHeader(
              label: 'Active',
              count: _active.length,
              accentColor: const Color(0xFF3B82F6),
            ),
          ),
          SliverToBoxAdapter(
            child: _TaskCarousel(
              tasks: _active,
              onTap: _openDetail,
              emptyMessage: 'No active tasks',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          // Needs input carousel
          SliverToBoxAdapter(
            child: _SectionHeader(
              label: 'Needs input',
              count: _pendingInput.length,
              accentColor: WearableColors.warning,
            ),
          ),
          SliverToBoxAdapter(
            child: _TaskCarousel(
              tasks: _pendingInput,
              onTap: _openDetail,
              emptyMessage: 'Nothing needs your input',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          // Done carousel
          SliverToBoxAdapter(
            child: _SectionHeader(
              label: 'Done',
              count: _done.length,
              accentColor: WearableColors.primary,
            ),
          ),
          SliverToBoxAdapter(
            child: _TaskCarousel(
              tasks: _done,
              onTap: _openDetail,
              emptyMessage: 'No completed tasks yet',
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.count,
    required this.accentColor,
  });

  final String label;
  final int count;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: WearableColors.foreground,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 8),
          if (count > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: accentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Horizontal carousel strip
// ---------------------------------------------------------------------------

class _TaskCarousel extends StatelessWidget {
  const _TaskCarousel({
    required this.tasks,
    required this.onTap,
    required this.emptyMessage,
  });

  final List<WearableTaskSummary> tasks;
  final void Function(WearableTaskSummary) onTap;
  final String emptyMessage;

  // Fixed carousel height: card content + top bar accent.
  static const double _carouselHeight = 148.0;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return SizedBox(
        height: _carouselHeight,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              emptyMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: _carouselHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tasks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final task = tasks[i];
          return WearableTaskCard(
            task: task,
            onTap: () => onTap(task),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error / not-paired states (verbatim from previous version)
// ---------------------------------------------------------------------------

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
              'Pair this app to a Wearable server to see your tasks.',
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
            const Icon(
              Icons.warning_amber_outlined,
              color: WearableColors.destructive,
              size: 32,
            ),
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
