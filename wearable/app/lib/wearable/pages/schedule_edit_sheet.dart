// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// ScheduleEditSheet — modal bottom sheet that creates or edits a single
// Wearable schedule (plan §5.5 M-4.2). Name + cron picker + message template
// + channel dropdown. On save, forwards to WearableSchedulesProvider.create
// or .update depending on whether `initial` was supplied.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/wearable_schedule.dart';
import '../wearable_theme.dart';
import '../providers/wearable_schedules_provider.dart';
import '../widgets/wearable_cron_picker.dart';

class ScheduleEditSheet extends StatefulWidget {
  const ScheduleEditSheet({super.key, this.initial});

  final WearableSchedule? initial;

  @override
  State<ScheduleEditSheet> createState() => _ScheduleEditSheetState();

  /// Convenience launcher — pushes the sheet and resolves with `true` if a
  /// save completed (caller refreshes its list).
  static Future<bool> show(BuildContext context, {WearableSchedule? initial}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: WearableColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: ScheduleEditSheet(initial: initial),
      ),
    );
    return result == true;
  }
}

class _ScheduleEditSheetState extends State<ScheduleEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _message;
  late final TextEditingController _chatId;
  late String _cron;
  late String _channel;
  bool _saving = false;
  String? _errorText;

  static const _channels = <String>['telegram', 'discord', 'boardroom', 'web'];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _message = TextEditingController(text: initial?.message ?? '');
    _chatId = TextEditingController(text: initial?.chatId ?? '');
    _cron = initial?.cron ?? '0 7 * * *';
    _channel = initial != null && _channels.contains(initial.channel)
        ? initial.channel
        : 'boardroom';
  }

  @override
  void dispose() {
    _name.dispose();
    _message.dispose();
    _chatId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final message = _message.text.trim();
    final chatId = _chatId.text.trim();
    final cron = _cron.trim();
    if (name.isEmpty || message.isEmpty || chatId.isEmpty) {
      setState(() => _errorText = 'Name, message, and chatId are required.');
      return;
    }
    // Cron picker can emit an empty string when the user clears the Custom
    // field. The server returns a generic 400 in that case; intercept here
    // so the user gets an inline-actionable message instead.
    if (cron.isEmpty) {
      setState(() => _errorText = 'Cron expression is required.');
      return;
    }
    if (cron.split(RegExp(r'\s+')).length != 5) {
      setState(() => _errorText = 'Cron must have five fields (minute hour day month dow).');
      return;
    }
    final provider = context.read<WearableSchedulesProvider>();
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      if (widget.initial == null) {
        await provider.create(
          name: name,
          cron: cron,
          message: message,
          chatId: chatId,
          channel: _channel,
        );
      } else {
        await provider.update(
          widget.initial!.id,
          name: name,
          cron: cron,
          message: message,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: WearableColors.mutedFg.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isEdit ? 'Edit schedule' : 'New schedule',
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            const _Label('Name'),
            _FieldShell(
              child: TextField(
                controller: _name,
                enabled: !_saving,
                style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
                decoration: _fieldDecoration('e.g. Morning inbox check'),
              ),
            ),
            const SizedBox(height: 16),
            const _Label('Cron'),
            WearableCronPicker(
              initialCron: _cron,
              onChanged: (next) => _cron = next,
            ),
            const SizedBox(height: 16),
            const _Label('Message template'),
            _FieldShell(
              child: TextField(
                controller: _message,
                enabled: !_saving,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
                decoration: _fieldDecoration('e.g. Check my inbox and summarise what needs my attention'),
              ),
            ),
            const SizedBox(height: 16),
            const _Label('Channel'),
            _FieldShell(
              child: DropdownButtonFormField<String>(
                initialValue: _channel,
                dropdownColor: WearableColors.cardAlt,
                style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
                decoration: _fieldDecoration(''),
                items: _channels
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(growable: false),
                // Channel + chatId together form the schedule's destination
                // identity. The server's PATCH endpoint accepts only
                // name/cron/message/enabled — silently dropping a channel
                // change would mislead the user. Lock both on edit; users
                // who need to retarget a schedule delete + recreate.
                onChanged: (_saving || widget.initial != null)
                    ? null
                    : (v) => setState(() => _channel = v ?? _channel),
              ),
            ),
            if (widget.initial != null)
              const Padding(
                padding: EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  'Channel and chat ID are fixed after creation. Delete and recreate to retarget.',
                  style: TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                ),
              ),
            const SizedBox(height: 16),
            const _Label('Chat ID'),
            _FieldShell(
              child: TextField(
                controller: _chatId,
                enabled: !_saving && widget.initial == null,   // immutable on edit
                style: const TextStyle(color: WearableColors.foreground, fontSize: 14, fontFamily: 'monospace'),
                decoration: _fieldDecoration(
                  'Telegram/Discord ID or "boardroom" / "web:…"',
                ),
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: WearableColors.destructive.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: WearableColors.destructive.withValues(alpha: 0.4)),
                ),
                child: Text(
                  _errorText!,
                  style: const TextStyle(color: WearableColors.foreground, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: WearableColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Cancel', style: TextStyle(color: WearableColors.foreground)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: WearableColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            isEdit ? 'Save' : 'Create',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: WearableColors.mutedFg),
        filled: true,
        fillColor: WearableColors.cardAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WearableColors.border),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
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

class _FieldShell extends StatelessWidget {
  const _FieldShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
