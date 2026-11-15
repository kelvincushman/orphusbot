import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/memory.dart';

void main() {
  final now = DateTime(2026, 11, 15, 10);

  test('says when a fact was last heard in plain words', () {
    String at(DateTime d) => heardWhen(d.toIso8601String(), now);
    expect(at(DateTime(2026, 11, 15, 0, 5)), 'today');
    expect(at(DateTime(2026, 11, 14, 23, 59)), 'yesterday');
    expect(at(DateTime(2026, 11, 12, 9)), '3 days ago');
    expect(at(DateTime(2026, 10, 2)), '2 Oct');
    expect(at(DateTime(2025, 12, 30)), '30 Dec 2025');
    // The day after the clocks go forward is still "yesterday" the next morning.
    expect(
      heardWhen(
        DateTime(2026, 3, 29, 0, 30).toIso8601String(),
        DateTime(2026, 3, 30, 0, 10),
      ),
      'yesterday',
    );
    expect(heardWhen(null, now), '');
    expect(heardWhen('not a date', now), '');
  });

  test('a fact said once shows only when; a repeat shows the count', () {
    final at = DateTime(2026, 11, 14, 8).toIso8601String();
    expect(factNote({'times_seen': 1, 'last_seen_at': at}, now), 'yesterday');
    expect(
      factNote({'times_seen': 3, 'last_seen_at': at}, now),
      'Said 3 times · yesterday',
    );
    expect(factNote({}, now), '');
  });
}
