import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/settings.dart';

// The faces animate for ever, so wait a fixed time rather than pumpAndSettle.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('settings lists everything and saves a bot whole', (t) async {
    final posted = <String, Object?>{};
    final api = Api(
      'http://server',
      'session=x',
      MockClient((r) async {
        if (r.method == 'POST') {
          posted[r.url.path] = jsonDecode(r.body);
          return http.Response('{}', 200);
        }
        final body = switch (r.url.path) {
          '/api/bots' => [
            {
              'slug': 'coder',
              'name': 'Coder',
              'remit': 'Writes code',
              'instructions': 'Be careful',
              'model': 'openai-codex/gpt-5.5',
              'thinking': null,
              'exclude_tools': [],
              'scope': 'team',
              'disabled': false,
              'computer': 'node',
            },
          ],
          '/api/connections' => {
            'connections': [
              {
                'id': 4,
                'name': 'docs',
                'url': 'https://mcp.example.com/mcp',
                'target': 'https://mcp.example.com/mcp',
                'has_token': false,
                'signed_in': false,
                'bots': ['coder'],
              },
            ],
            'secrets': true,
          },
          '/api/nodes' => [
            {
              'id': 1,
              'name': 'gpu-box',
              'created_at': '2026-10-15T10:00:00Z',
              'last_seen_at': null,
            },
          ],
          '/api/usage' => {'today_tokens': 1234, 'budget': null},
          '/api/devices' => {'devices': []},
          '/api/models' => [
            {
              'id': 'local/qwen',
              'nodes': ['gpu-box'],
            },
          ],
          _ => [],
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    // Tall enough to build every section at once.
    t.view.physicalSize = const Size(1000, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: SettingsScreen(api: api, onSignedOut: () {}),
      ),
    );
    await settle(t);
    expect(find.text('Coder'), findsWidgets);
    expect(find.text('openai-codex/gpt-5.5 · team'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);
    expect(find.text('gpu-box'), findsOneWidget);
    expect(find.textContaining('1234 tokens today'), findsOneWidget);

    // Edit the bot's instructions and save: the whole bot goes back.
    await t.tap(find.text('openai-codex/gpt-5.5 · team'));
    await settle(t);
    await t.enterText(
      find.widgetWithText(TextField, 'Instructions'),
      'Write tests first',
    );
    await t.tap(find.text('Save'));
    await settle(t);
    final saved = posted['/api/bots/update'] as Map<String, dynamic>;
    expect(saved['instructions'], 'Write tests first');
    expect(saved['model'], 'openai-codex/gpt-5.5');
    expect(saved['scope'], 'team');
    expect(saved['slug'], 'coder');
  });
}
