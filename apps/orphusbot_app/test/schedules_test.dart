import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/schedules.dart';

void main() {
  test('simple choices become cron and read back the same', () {
    const at = TimeOfDay(hour: 8, minute: 30);
    for (final r in [Repeat.daily, Repeat.weekdays, Repeat.weekly]) {
      final cron = cronFor(r, at: at, weekday: 3)!;
      final back = readCron(cron);
      expect(back.repeat, r, reason: cron);
      expect(back.at, at);
    }
    expect(cronFor(Repeat.weekdays, at: at), '30 8 * * 1-5');
    expect(cronFor(Repeat.hours, hours: 6), '0 */6 * * *');
    expect(readCron('0 */6 * * *').hours, 6);
    expect(readCron('30 8 * * 3').weekday, 3);
    expect(cronFor(Repeat.once), isNull);
    expect(readCron('*/5 * 1 * *').repeat, Repeat.custom);
  });

  test('schedules are described in plain words', () {
    expect(describeSchedule({'cron': '0 9 * * 1-5'}), 'Weekdays at 09:00');
    expect(describeSchedule({'cron': '0 17 * * 0'}), 'Every Sunday at 17:00');
    expect(describeSchedule({'cron': '0 */1 * * *'}), 'Every hour');
    expect(
      describeSchedule({'once_at': '2026-10-23T10:00'}),
      'Once, 2026-10-23 at 10:00',
    );
    expect(
      describeSchedule({'webhook': true}),
      'Only when its webhook is called',
    );
    expect(
      describeSchedule({'cron': '0 9 * * *', 'webhook': true}),
      'Every day at 09:00, or by webhook',
    );
  });

  testWidgets('a new schedule is built from the form', (t) async {
    Map<String, dynamic>? saved;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () async => saved = await Navigator.of(c).push(
              MaterialPageRoute(
                builder: (_) => const ScheduleEditor(
                  bots: [
                    {'slug': 'phone', 'name': 'Phone'},
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Mentions');
    await t.enterText(
      find.widgetWithText(TextField, 'What should it do?'),
      'Check my mentions',
    );
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(saved?['bot'], 'phone');
    expect(saved?['cron'], '0 9 * * *');
    expect(saved?['timezone'], 'Europe/London');
    expect(saved?['active'], isTrue);
  });
}
