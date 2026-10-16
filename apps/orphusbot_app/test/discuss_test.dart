import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/discuss.dart';

void main() {
  testWidgets('a discussion shows its rounds, posts and verdict', (t) async {
    final api = Api(
      'http://server',
      'session=x',
      MockClient(
        (r) async => http.Response(
          jsonEncode({
            'id': 3,
            'question': 'Ship the panel?',
            'bots': ['researcher', 'checker'],
            'chair': 'researcher',
            'rounds': 2,
            'round': 3,
            'status': 'done',
            'verdict': '**Decision:** ship it.',
            'created_at': '2026-10-16T22:00:00Z',
            'posts': [
              {'bot': 'researcher', 'round': 1, 'text': 'Opening: yes.'},
              {'bot': 'checker', 'round': 1, 'text': 'Opening: no.'},
              {'bot': 'checker', 'round': 2, 'text': 'FINAL: ship it'},
            ],
          }),
          200,
        ),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: DiscussionScreen(
          api: api,
          id: 3,
          bots: const [
            {'slug': 'researcher', 'name': 'Researcher'},
            {'slug': 'checker', 'name': 'Checker'},
          ],
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Discussion #3 · verdict in'), findsOneWidget);
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Opening: no.'), findsOneWidget);
    expect(find.text('Verdict'), findsOneWidget);
    expect(find.textContaining('Chair: Researcher'), findsOneWidget);
  });
}
