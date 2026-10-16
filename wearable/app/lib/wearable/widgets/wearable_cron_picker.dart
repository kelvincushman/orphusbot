// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableCronPicker — preset-first cron chooser used by the schedule edit
// sheet (plan §5.5 M-4.3). Presets cover the 90% case (hourly, daily,
// weekdays, weekly) and fall back to a free-form cron input for advanced
// users. Picker emits a string cron the server will re-validate via
// cron-parser before persisting.

import 'package:flutter/material.dart';

import '../wearable_theme.dart';

enum CronPreset { hourly, daily, weekdays, weekly, custom }

class WearableCronPicker extends StatefulWidget {
  const WearableCronPicker({
    super.key,
    required this.initialCron,
    required this.onChanged,
  });

  final String initialCron;
  final ValueChanged<String> onChanged;

  @override
  State<WearableCronPicker> createState() => _WearableCronPickerState();
}

class _WearableCronPickerState extends State<WearableCronPicker> {
  late CronPreset _preset;
  late TimeOfDay _time;
  late int _dayOfWeek;    // 0 = Sunday … 6 = Saturday
  late TextEditingController _customController;

  @override
  void initState() {
    super.initState();
    _preset = _detectPreset(widget.initialCron);
    _time = _detectTime(widget.initialCron);
    _dayOfWeek = _detectDow(widget.initialCron);
    _customController = TextEditingController(text: widget.initialCron);
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _emit() {
    final cron = _compose();
    widget.onChanged(cron);
  }

  String _compose() {
    switch (_preset) {
      case CronPreset.hourly:
        return '0 * * * *';
      case CronPreset.daily:
        return '${_time.minute} ${_time.hour} * * *';
      case CronPreset.weekdays:
        return '${_time.minute} ${_time.hour} * * 1-5';
      case CronPreset.weekly:
        return '${_time.minute} ${_time.hour} * * $_dayOfWeek';
      case CronPreset.custom:
        return _customController.text.trim();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: CronPreset.values.map((p) => ChoiceChip(
                label: Text(_presetLabel(p)),
                selected: _preset == p,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: (_) {
                  setState(() => _preset = p);
                  _emit();
                },
              )).toList(growable: false),
        ),
        const SizedBox(height: 16),
        if (_preset == CronPreset.daily ||
            _preset == CronPreset.weekdays ||
            _preset == CronPreset.weekly) ...[
          _TimeRow(
            time: _time,
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: _time,
              );
              if (picked == null) return;
              setState(() => _time = picked);
              _emit();
            },
          ),
        ],
        if (_preset == CronPreset.weekly) ...[
          const SizedBox(height: 12),
          _DayOfWeekRow(
            selected: _dayOfWeek,
            onChanged: (dow) {
              setState(() => _dayOfWeek = dow);
              _emit();
            },
          ),
        ],
        if (_preset == CronPreset.custom) ...[
          const SizedBox(height: 4),
          TextField(
            controller: _customController,
            onChanged: (_) => _emit(),
            style: const TextStyle(
              color: WearableColors.foreground,
              fontSize: 14,
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              hintText: '*/15 * * * *',
              hintStyle: const TextStyle(color: WearableColors.mutedFg),
              helperText: 'Five-field cron (minute hour day month dow). Server validates.',
              helperStyle: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
              filled: true,
              fillColor: WearableColors.cardAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: WearableColors.border),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _presetLabel(CronPreset p) => switch (p) {
        CronPreset.hourly => 'Every hour',
        CronPreset.daily => 'Daily at…',
        CronPreset.weekdays => 'Weekdays at…',
        CronPreset.weekly => 'Weekly on…',
        CronPreset.custom => 'Custom',
      };

  static CronPreset _detectPreset(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return CronPreset.custom;
    if (parts[0] == '0' && parts[1] == '*' && parts[2] == '*' && parts[3] == '*' && parts[4] == '*') {
      return CronPreset.hourly;
    }
    if (parts[2] == '*' && parts[3] == '*' && parts[4] == '*' &&
        int.tryParse(parts[0]) != null &&
        int.tryParse(parts[1]) != null) {
      return CronPreset.daily;
    }
    if (parts[2] == '*' && parts[3] == '*' && parts[4] == '1-5' &&
        int.tryParse(parts[0]) != null &&
        int.tryParse(parts[1]) != null) {
      return CronPreset.weekdays;
    }
    if (parts[2] == '*' && parts[3] == '*' &&
        int.tryParse(parts[0]) != null &&
        int.tryParse(parts[1]) != null &&
        int.tryParse(parts[4]) != null) {
      return CronPreset.weekly;
    }
    return CronPreset.custom;
  }

  static TimeOfDay _detectTime(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return const TimeOfDay(hour: 7, minute: 0);
    final m = int.tryParse(parts[0]);
    final h = int.tryParse(parts[1]);
    if (m == null || h == null) return const TimeOfDay(hour: 7, minute: 0);
    return TimeOfDay(hour: h, minute: m);
  }

  static int _detectDow(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return 1;
    final dow = int.tryParse(parts[4]);
    return dow ?? 1;
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.time, required this.onTap});
  final TimeOfDay time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: WearableColors.cardAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: WearableColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.access_time_outlined, color: WearableColors.primary, size: 18),
            const SizedBox(width: 10),
            const Text(
              'Time',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 12),
            ),
            const Spacer(),
            Text(
              _format(time),
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, color: WearableColors.mutedFg, size: 14),
          ],
        ),
      ),
    );
  }

  static String _format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _DayOfWeekRow extends StatelessWidget {
  const _DayOfWeekRow({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const names = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(7, (i) {
        final sel = i == selected;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onChanged(i),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: sel ? WearableColors.primary.withValues(alpha: 0.15) : WearableColors.cardAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: sel ? WearableColors.primary : WearableColors.border,
              ),
            ),
            child: Text(
              names[i],
              style: TextStyle(
                color: sel ? WearableColors.primary : WearableColors.foreground,
                fontSize: 12,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        );
      }),
    );
  }
}
