import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/wearable.dart';

void main() {
  test('last seen reads as a short age, then a date', () {
    final now = DateTime.now();
    String ago(Duration d) =>
        lastSeen(now.subtract(d).toUtc().toIso8601String());
    expect(lastSeen(null), 'never');
    expect(ago(const Duration(seconds: 30)), 'just now');
    expect(ago(const Duration(minutes: 5)), '5 min ago');
    expect(ago(const Duration(hours: 3)), '3 h ago');
    expect(lastSeen(DateTime(2026, 1, 2, 9).toIso8601String()), '2026-01-02');
  });
}
