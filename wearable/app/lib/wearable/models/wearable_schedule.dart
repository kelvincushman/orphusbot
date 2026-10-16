// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Wearable schedule model — wire-level mirror of the server's ScheduledTaskRow
// (src/scheduler.ts:46) surfaced via /api/schedules (S-3, commit 70a0b71).

class WearableSchedule {
  const WearableSchedule({
    required this.id,
    required this.name,
    required this.cron,
    required this.message,
    required this.chatId,
    required this.channel,
    required this.enabled,
    required this.createdAt,
    required this.nextRunAt,
    this.lastRunAt,
    this.lastOk,
    this.lastError,
  });

  final int id;
  final String name;
  final String cron;
  final String message;
  final String chatId;
  final String channel;
  final bool enabled;
  final int createdAt;
  final int nextRunAt;
  final int? lastRunAt;
  final int? lastOk;
  final String? lastError;

  factory WearableSchedule.fromJson(Map<String, dynamic> json) {
    return WearableSchedule(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '') as String,
      cron: (json['cron'] ?? '') as String,
      message: (json['message'] ?? '') as String,
      chatId: (json['chat_id'] ?? json['chatId'] ?? '') as String,
      channel: (json['channel'] ?? '') as String,
      enabled: (json['enabled'] is num)
          ? (json['enabled'] as num).toInt() == 1
          : json['enabled'] == true,
      createdAt: (json['created_at'] as num?)?.toInt()
          ?? (json['createdAt'] as num?)?.toInt()
          ?? 0,
      nextRunAt: (json['next_run_at'] as num?)?.toInt()
          ?? (json['nextRunAt'] as num?)?.toInt()
          ?? 0,
      lastRunAt: (json['last_run_at'] as num?)?.toInt()
          ?? (json['lastRunAt'] as num?)?.toInt(),
      lastOk: (json['last_ok'] as num?)?.toInt()
          ?? (json['lastOk'] as num?)?.toInt(),
      lastError: json['last_error'] as String? ?? json['lastError'] as String?,
    );
  }
}

/// Minimal decoder for a cron expression → human-readable description +
/// next upcoming fire times. Handles the four preset shapes the app
/// creates; custom expressions render the raw cron with a "Custom"
/// label (server validates via cron-parser regardless).
class CronSummary {
  const CronSummary({required this.label, required this.isPreset});
  final String label;
  final bool isPreset;

  static CronSummary describe(String cron) {
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return CronSummary(label: cron, isPreset: false);
    final minute = parts[0];
    final hour = parts[1];
    final day = parts[2];
    final month = parts[3];
    final dow = parts[4];
    if (minute == '0' && hour == '*' && day == '*' && month == '*' && dow == '*') {
      return const CronSummary(label: 'Every hour', isPreset: true);
    }
    final hourNum = int.tryParse(hour);
    final minuteNum = int.tryParse(minute);
    if (minuteNum != null &&
        hourNum != null &&
        day == '*' &&
        month == '*' &&
        dow == '*') {
      return CronSummary(
        label: 'Every day at ${_formatTime(hourNum, minuteNum)}',
        isPreset: true,
      );
    }
    if (minuteNum != null &&
        hourNum != null &&
        day == '*' &&
        month == '*' &&
        dow == '1-5') {
      return CronSummary(
        label: 'Weekdays at ${_formatTime(hourNum, minuteNum)}',
        isPreset: true,
      );
    }
    if (minuteNum != null &&
        hourNum != null &&
        day == '*' &&
        month == '*' &&
        _dayOfWeekLabel(dow) != null) {
      return CronSummary(
        label: 'Every ${_dayOfWeekLabel(dow)} at ${_formatTime(hourNum, minuteNum)}',
        isPreset: true,
      );
    }
    return CronSummary(label: cron, isPreset: false);
  }

  static String _formatTime(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  static String? _dayOfWeekLabel(String dow) {
    const names = {
      '0': 'Sunday',
      '1': 'Monday',
      '2': 'Tuesday',
      '3': 'Wednesday',
      '4': 'Thursday',
      '5': 'Friday',
      '6': 'Saturday',
      '7': 'Sunday',
    };
    return names[dow];
  }
}
