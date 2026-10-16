// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// TaskDetailPage — per-task view (plan §5.4 M-3.4).
// Shows header (title, status, role, created), the task's response (raw
// RESPONSE.md from the server), pending-input question with inline reply,
// children list with quick navigation, and Reply / Cancel / Copy actions.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/wearable_task.dart';
import '../wearable_client.dart';
import '../wearable_theme.dart';
import '../providers/wearable_tasks_provider.dart';

class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage({super.key, required this.taskId});

  final String taskId;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  WearableTaskDetail? _detail;
  String? _error;
  bool _loading = true;
  final _replyController = TextEditingController();
  bool _submittingReply = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await WearableClient.instance.getTaskDetail(widget.taskId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load task: $e';
        _loading = false;
      });
    }
  }

  Future<void> _submitReply() async {
    final answer = _replyController.text.trim();
    if (answer.isEmpty) return;
    setState(() => _submittingReply = true);
    try {
      await context.read<WearableTasksProvider>().replyToTask(widget.taskId, answer);
      if (!mounted) return;
      _replyController.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reply sent.')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reply failed: $e')));
    } finally {
      if (mounted) setState(() => _submittingReply = false);
    }
  }

  Future<void> _cancelTask() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: WearableColors.card,
        title: const Text('Cancel this task?'),
        content: const Text(
          'The server will mark it as failed with reason "user_cancelled". Any work already completed stays in the log.',
          style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel task', style: TextStyle(color: WearableColors.destructive)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<WearableTasksProvider>().cancelTask(widget.taskId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cancel failed: $e')));
    }
  }

  Future<void> _openDriveLink(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid Drive link.')));
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open Drive link.")));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open Drive link.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(title: const Text('Task'), backgroundColor: WearableColors.background),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: WearableColors.primary))
          : _error != null
          ? _ErrorState(message: _error!, onRetry: _refresh)
          : _buildBody(_detail!),
    );
  }

  Widget _buildBody(WearableTaskDetail d) {
    return RefreshIndicator(
      color: WearableColors.primary,
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HeaderCard(detail: d),
          const SizedBox(height: 16),
          if (d.pendingInput != null) ...[
            _PendingInputCard(
              question: d.pendingInput!.question,
              controller: _replyController,
              submitting: _submittingReply,
              onSubmit: _submitReply,
            ),
            const SizedBox(height: 16),
          ],
          if (d.response != null && d.response!.isNotEmpty) ...[
            const _SectionHeader(title: 'Response'),
            _ResponseCard(text: d.response!),
            const SizedBox(height: 16),
          ],
          if (d.driveLinks.isNotEmpty) ...[
            const _SectionHeader(title: 'Google Drive'),
            _DriveLinksCard(links: d.driveLinks, onOpen: _openDriveLink),
            const SizedBox(height: 16),
          ],
          if (d.artifacts.isNotEmpty) ...[
            const _SectionHeader(title: 'Artifacts'),
            _ArtifactsCard(artifacts: d.artifacts),
            const SizedBox(height: 16),
          ],
          if (d.children.isNotEmpty) ...[
            const _SectionHeader(title: 'Children'),
            _ChildrenCard(children: d.children),
            const SizedBox(height: 16),
          ],
          _ActionsRow(
            canCancel:
                d.status == WearableTaskStatus.active ||
                d.status == WearableTaskStatus.pendingInput ||
                d.status == WearableTaskStatus.awaitingChildren,
            canCopyResponse: d.response != null && d.response!.isNotEmpty,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: d.response ?? ''));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Response copied to clipboard.')));
            },
            onCancel: _cancelTask,
          ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.detail});
  final WearableTaskDetail detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.prompt ?? '(no prompt)',
            style: const TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                detail.role.toUpperCase(),
                style: const TextStyle(
                  color: WearableColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Text(
                'Task ${detail.taskId.substring(0, detail.taskId.length < 10 ? detail.taskId.length : 10)}…',
                style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11, fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PendingInputCard extends StatelessWidget {
  const _PendingInputCard({
    required this.question,
    required this.controller,
    required this.submitting,
    required this.onSubmit,
  });

  final String question;
  final TextEditingController controller;
  final bool submitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.help_outline, color: WearableColors.primary, size: 16),
              SizedBox(width: 6),
              Text(
                'Wearable needs your input',
                style: TextStyle(color: WearableColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(question, style: const TextStyle(color: WearableColors.foreground, fontSize: 14, height: 1.4)),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: 1,
            maxLines: 4,
            enabled: !submitting,
            style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Type your answer…',
              hintStyle: const TextStyle(color: WearableColors.mutedFg),
              filled: true,
              fillColor: WearableColors.cardAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: WearableColors.border),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: submitting ? null : onSubmit,
              style: ElevatedButton.styleFrom(backgroundColor: WearableColors.primary, foregroundColor: Colors.white),
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Send reply'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResponseCard extends StatelessWidget {
  const _ResponseCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.border),
      ),
      child: SelectableText(text, style: const TextStyle(color: WearableColors.foreground, fontSize: 14, height: 1.5)),
    );
  }
}

class _ChildrenCard extends StatelessWidget {
  const _ChildrenCard({required this.children});
  final List<WearableChildTask> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.border),
      ),
      child: Column(
        children: children
            .map(
              (c) => ListTile(
                title: Text(
                  c.id,
                  style: const TextStyle(color: WearableColors.foreground, fontSize: 12, fontFamily: 'monospace'),
                ),
                subtitle: Text(c.status.wire, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11)),
                trailing: const Icon(Icons.chevron_right, color: WearableColors.mutedFg, size: 18),
                onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TaskDetailPage(taskId: c.id)));
                },
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _DriveLinksCard extends StatelessWidget {
  const _DriveLinksCard({required this.links, required this.onOpen});

  final List<String> links;
  final Future<void> Function(String link) onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.border),
      ),
      child: Column(
        children: links
            .map(
              (link) => ListTile(
                leading: const Icon(Icons.add_to_drive_outlined, color: WearableColors.primary),
                title: Text(Uri.parse(link).host, style: const TextStyle(color: WearableColors.foreground, fontSize: 13)),
                subtitle: Text(
                  link,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                ),
                trailing: const Icon(Icons.open_in_new, color: WearableColors.mutedFg, size: 18),
                onTap: () => onOpen(link),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _ArtifactsCard extends StatelessWidget {
  const _ArtifactsCard({required this.artifacts});

  final List<WearableTaskArtifact> artifacts;

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WearableColors.border),
      ),
      child: Column(
        children: artifacts
            .map(
              (artifact) => ListTile(
                leading: const Icon(Icons.description_outlined, color: WearableColors.foreground),
                title: Text(
                  artifact.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: WearableColors.foreground, fontSize: 12, fontFamily: 'monospace'),
                ),
                subtitle: Text(
                  _sizeLabel(artifact.size),
                  style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                ),
                trailing: IconButton(
                  tooltip: 'Copy artifact path',
                  icon: const Icon(Icons.copy_outlined, color: WearableColors.mutedFg, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: artifact.path));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Artifact path copied.')));
                  },
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: WearableColors.mutedFg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.canCancel,
    required this.canCopyResponse,
    required this.onCopy,
    required this.onCancel,
  });

  final bool canCancel;
  final bool canCopyResponse;
  final VoidCallback onCopy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (canCopyResponse)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_outlined, size: 16, color: WearableColors.foreground),
              label: const Text('Copy response', style: TextStyle(color: WearableColors.foreground)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: WearableColors.border)),
            ),
          ),
        if (canCopyResponse && canCancel) const SizedBox(width: 12),
        if (canCancel)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.cancel_outlined, size: 16, color: WearableColors.destructive),
              label: const Text('Cancel task', style: TextStyle(color: WearableColors.destructive)),
              style: OutlinedButton.styleFrom(side: BorderSide(color: WearableColors.destructive.withValues(alpha: 0.5))),
            ),
          ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

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
