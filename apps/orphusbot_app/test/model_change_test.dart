import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/settings.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the orchestrator model can be picked and saved', (t) async {
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
              'slug': 'orchestrator',
              'name': 'Orchestrator',
              'remit': 'Plans bigger jobs',
              'instructions': 'x' * 1136,
              'model': null,
              'thinking': null,
              'exclude_tools': [],
              'scope': 'team',
              'disabled': false,
              'computer': 'node',
              'google': 'read',
            },
          ],
          '/api/models' => [
            {
              'id': 'claude-bridge/claude-opus-5',
              'nodes': ['gpu-box'],
            },
            {
              'id': 'openai-codex/gpt-6-astra',
              'nodes': ['gpu-box'],
            },
          ],
          '/api/connections' => {'connections': [], 'secrets': true},
          '/api/usage' => {'today_tokens': 0},
          '/api/devices' => {'devices': []},
          _ => [],
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    // Kelvin's window is about 620 x 670.
    t.view.physicalSize = const Size(621, 670);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: SettingsScreen(api: api, onSignedOut: () {}),
      ),
    );
    await settle(t);
    await t.tap(find.text('Orchestrator').first);
    await settle(t);
    await t.ensureVisible(find.text('Model'));
    await settle(t);
    await t.tap(find.text('Orphus default'));
    await settle(t);
    await t.tap(find.text('claude-bridge/claude-opus-5').last);
    await settle(t);
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await settle(t);
    final saved = posted['/api/bots/update'] as Map<String, dynamic>?;
    expect(saved?['model'], 'claude-bridge/claude-opus-5');
  });
}
