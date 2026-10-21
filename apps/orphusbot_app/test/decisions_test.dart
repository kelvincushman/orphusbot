import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/decisions.dart';

void main() {
  testWidgets('marking routing and gate decisions sends the right labels', (
    t,
  ) async {
    final posted = <Object?>[];
    final api = Api(
      'http://server',
      'session=x',
      MockClient((r) async {
        if (r.method == 'POST') {
          posted.add(jsonDecode(r.body));
          return http.Response('', 204);
        }
        return http.Response(
          jsonEncode([
            {
              'id': 2,
              'catalogue': 'triage',
              'state': 'Please fix the failing test',
              'answers': {
                'bot': {'choice': 'coder'},
              },
              'abstained': false,
              'confidence': 0.62,
              'outcome': 'Not sure enough; kept in the inbox',
              'label': null,
            },
            {
              'id': 3,
              'catalogue': 'gate',
              'state': jsonEncode({
                'task': 'x',
                'tool': 'edit',
                'args': {'path': 'a.rs'},
              }),
              'answers': {
                'verdict': {'choice': 'pass'},
              },
              'abstained': false,
              'confidence': 0.75,
              'outcome': 'asked',
              'label': null,
            },
            // Not labelled from the app, so not shown.
            {'id': 4, 'catalogue': 'capture', 'state': 'x', 'label': null},
          ]),
          200,
        );
      }),
    );
    final bots = [
      {'slug': 'coder', 'name': 'Coder'},
      {'slug': 'researcher', 'name': 'Researcher'},
    ];
    await t.pumpWidget(
      MaterialApp(
        home: DecisionsScreen(api: api, bots: bots),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.text('Chose Coder · 62% sure · Not sure enough; kept in the inbox'),
      findsOneWidget,
    );
    expect(find.textContaining('edit {"path":"a.rs"}'), findsOneWidget);
    expect(find.byType(Card), findsNWidgets(2));

    await t.tap(find.text('Right'));
    await t.pumpAndSettle();
    await t.tap(find.text('Wrong'));
    await t.pumpAndSettle();
    await t.tap(find.text('Researcher'));
    await t.pumpAndSettle();
    await t.tap(find.text('Should ask me'));
    await t.pumpAndSettle();
    expect(posted, [
      {'id': 2, 'bot': 'coder'},
      {'id': 2, 'bot': 'researcher'},
      {'id': 3, 'verdict': 'ask'},
    ]);
  });
}
