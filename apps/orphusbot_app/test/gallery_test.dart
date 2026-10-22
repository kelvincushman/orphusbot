import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/gallery.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final items = [
    {
      'id': 1,
      'name': 'brand-guide.pdf',
      'mime': 'application/pdf',
      'size': 2048,
      'tags': ['brand'],
      'description': 'Colours and fonts',
      'pinned_for': ['media-creator'],
      'source': 'upload',
      'created_at': '2026-10-20T21:00:00Z',
    },
    {
      'id': 2,
      'name': 'launch.mp4',
      'mime': 'video/mp4',
      'size': 5 * 1024 * 1024,
      'tags': [],
      'description': '',
      'pinned_for': [],
      'source': 'bot:media-creator',
      'created_at': '2026-10-20T21:01:00Z',
    },
  ];
  Api fake(Map<String, Object?> posted) => Api(
    'http://server',
    'session=x',
    MockClient((r) async {
      if (r.method == 'POST') {
        posted[r.url.path] = jsonDecode(r.body);
        return http.Response('{}', 200);
      }
      return http.Response(jsonEncode(items), 200);
    }),
  );
  const bots = [
    {'slug': 'media-creator', 'name': 'Media Creator'},
    {'slug': 'researcher', 'name': 'Researcher'},
  ];

  testWidgets('the gallery lists items and saves their details', (t) async {
    final posted = <String, Object?>{};
    await t.pumpWidget(
      MaterialApp(
        home: GalleryScreen(api: fake(posted), bots: bots),
      ),
    );
    await settle(t);
    expect(find.text('brand-guide.pdf'), findsOneWidget);
    expect(find.text('launch.mp4'), findsOneWidget);
    await t.tap(find.text('brand-guide.pdf'));
    await settle(t);
    await t.scrollUntilVisible(
      find.text('Researcher'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await t.tap(find.text('Researcher'));
    await t.tap(find.text('Save'));
    await settle(t);
    final saved = posted['/api/gallery/update'] as Map<String, dynamic>;
    expect(saved['tags'], ['brand']);
    expect((saved['pinned_for'] as List).toSet(), {
      'media-creator',
      'researcher',
    });
  });

  testWidgets('an item can be renamed and tagged', (t) async {
    final posted = <String, Object?>{};
    await t.pumpWidget(
      MaterialApp(
        home: GalleryScreen(api: fake(posted), bots: bots),
      ),
    );
    await settle(t);
    await t.tap(find.text('launch.mp4'));
    await settle(t);
    expect(find.text('Details'), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, 'launch.mp4'),
      'Launch teaser.mp4',
    );
    final tagField = find.widgetWithText(
      TextField,
      'Add a tag, such as brand or logo',
    );
    await t.enterText(tagField, 'Video, launch');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    expect(find.widgetWithText(InputChip, 'video'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'launch'), findsOneWidget);
    // Remove one again with its x.
    await t.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, 'video'),
        matching: find.byTooltip('Delete'),
      ),
    );
    await settle(t);
    await t.tap(find.text('Save'));
    await settle(t);
    final saved = posted['/api/gallery/update'] as Map<String, dynamic>;
    expect(saved['name'], 'Launch teaser.mp4');
    expect(saved['tags'], ['launch']);
  });

  testWidgets('picking returns the chosen items', (t) async {
    List<Map<String, dynamic>>? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.of(context)
                .push<List<Map<String, dynamic>>>(
                  MaterialPageRoute(
                    builder: (_) =>
                        GalleryScreen(api: fake({}), bots: bots, picking: true),
                  ),
                ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await settle(t);
    await t.tap(find.text('launch.mp4'));
    await t.pump();
    await t.tap(find.text('Attach 1'));
    await settle(t);
    expect(result?.single['name'], 'launch.mp4');
  });
}
