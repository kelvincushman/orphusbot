import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/health.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final google = {
    'name': 'google',
    'label': 'Google',
    'ok': false,
    'problem': 'Google needs reconnecting',
    'fix': 'Run gws auth login.',
    'since': DateTime.now()
        .subtract(const Duration(minutes: 5))
        .toUtc()
        .toIso8601String(),
    'checked_at': DateTime.now().toUtc().toIso8601String(),
  };
  final disk = {
    'name': 'disk',
    'label': 'Disk space',
    'ok': true,
    'problem': null,
    'fix': null,
    'since': null,
    'checked_at': DateTime.now().toUtc().toIso8601String(),
  };

  Api fake(List<Object> answer, List<String> posted) => Api(
    'http://server',
    'session=x',
    MockClient((r) async {
      if (r.method == 'POST') posted.add(r.url.path);
      return http.Response(jsonEncode(answer), 200);
    }),
  );

  test('says how long a check has been failing', () {
    final now = DateTime(2026, 11, 17, 15, 30);
    String at(DateTime d) => failingSince(d.toIso8601String(), now);
    expect(at(DateTime(2026, 11, 17, 15, 30)), 'Failing since just now');
    expect(at(DateTime(2026, 11, 17, 15, 29)), 'Failing for 1 minute');
    expect(at(DateTime(2026, 11, 17, 15, 5)), 'Failing for 25 minutes');
    expect(at(DateTime(2026, 11, 17, 9, 7)), 'Failing since 09:07');
    expect(at(DateTime(2026, 11, 16, 22, 0)), 'Failing since yesterday, 22:00');
    expect(failingSince(null, now), '');
  });

  test('the banner speaks only while something is red', () {
    expect(bannerText([disk]), isNull);
    expect(bannerText([]), isNull);
    expect(
      bannerText([google, disk]),
      'Google needs reconnecting. Tap for Health.',
    );
    expect(
      bannerText([
        google,
        {...google, 'name': 'xai'},
      ]),
      '2 things need attention. Tap for Health.',
    );
  });

  testWidgets('Health lists each check in words and checks now', (t) async {
    final posted = <String>[];
    await t.pumpWidget(
      MaterialApp(home: HealthScreen(api: fake([google, disk], posted))),
    );
    await settle(t);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Google needs reconnecting'), findsOneWidget);
    expect(find.text('How to fix: Run gws auth login.'), findsOneWidget);
    expect(find.textContaining('Failing for'), findsOneWidget);
    expect(find.text('Disk space'), findsOneWidget);
    expect(find.text('Working'), findsOneWidget);
    // Not colour alone: each icon is labelled.
    expect(find.bySemanticsLabel(RegExp(r'^Problem\nGoogle')), findsOneWidget);

    await t.tap(find.text('Check now'));
    await settle(t);
    expect(posted, ['/api/health/check']);
  });

  testWidgets('the banner shows while red and opens Health', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HealthBanner(api: fake([google], []))),
      ),
    );
    await settle(t);
    expect(
      find.text('Google needs reconnecting. Tap for Health.'),
      findsOneWidget,
    );
    await t.tap(find.byType(HealthBanner));
    await settle(t);
    expect(find.text('Health'), findsOneWidget);
  });

  testWidgets('no banner when everything works', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HealthBanner(api: fake([disk], []))),
      ),
    );
    await settle(t);
    expect(find.byType(InkWell), findsNothing);
  });
}
