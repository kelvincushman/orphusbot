import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orphusbot_app/api.dart';
import 'package:orphusbot_app/bot_panel.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('the count says how much is loaded and when some is left out', () {
    expect(grouped(340), '340');
    expect(grouped(2340), '2,340');
    expect(grouped(1234567), '1,234,567');
    expect(notesCount('x' * 340, 2000), '340 of 2,000 loaded');
    expect(notesCount('x' * 2000, 2000), '2,000 of 2,000 loaded');
    expect(
      notesCount('x' * 2340, 2000),
      startsWith('2,340 of 2,000 loaded · '),
    );
  });

  test('what is loaded is counted in characters, as the server does', () {
    expect(loadedEnd('abc', 2000), 3);
    expect(loadedEnd('abcdef', 4), 4);
    // An emoji is one character to the server and two units in Dart.
    expect(loadedEnd('😀😀😀', 2), 4);
    expect(notesCount('😀😀😀', 2), startsWith('3 of 2 loaded'));
  });

  testWidgets('the part a run is not told is greyed', (t) async {
    final c = NotesController(text: 'abcdef')
      ..cap = 4
      ..grey = Colors.red;
    addTearDown(c.dispose);
    late BuildContext context;
    await t.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    final span = c.buildTextSpan(context: context, withComposing: false);
    expect(span.children!.map((s) => (s as TextSpan).text), ['abcd', 'ef']);
    expect(span.children!.last.style?.color, Colors.red);
    c.text = 'abc';
    expect(
      c.buildTextSpan(context: context, withComposing: false).children,
      isNull,
    );
  });

  testWidgets('the panel shows soul, notes and can do, and saves each', (
    t,
  ) async {
    final sent = <String, Object?>{};
    var notes = 'x' * 2340;
    var version = 3;
    // The bot saves its notes while the panel is open.
    var botSavedMeanwhile = false;
    final api = Api(
      'http://server',
      'session=x',
      MockClient((r) async {
        if (r.method == 'GET' && r.url.path == '/api/bots') {
          // The bot as the server has it now: its model changed elsewhere
          // after the panel opened.
          return http.Response(
            jsonEncode([
              {
                'slug': 'coder',
                'name': 'Coder',
                'instructions': 'Be careful',
                'scope': 'private',
                'model': 'new-model',
              },
            ]),
            200,
          );
        }
        if (r.method == 'GET') {
          expect(r.url.path, '/api/bots/coder/notes');
          return http.Response(
            jsonEncode({
              'notes': notes,
              'version': version,
              'loaded_chars': 2000,
              'can_do': 'model Orphus default; Google: looks up only',
            }),
            200,
          );
        }
        sent['${r.method} ${r.url.path}'] = jsonDecode(r.body);
        if (r.method == 'PUT' && botSavedMeanwhile) {
          return http.Response('The bot changed its notes', 409);
        }
        if (r.method == 'PUT') {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          notes = body['notes'] as String;
          return http.Response(jsonEncode({'version': ++version}), 200);
        }
        return http.Response('{}', 200);
      }),
    );
    t.view.physicalSize = const Size(700, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    bool? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => BotPanel(
                    api: api,
                    bot: const {
                      'slug': 'coder',
                      'name': 'Coder',
                      'instructions': 'Be careful',
                      'scope': 'private',
                    },
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await settle(t);

    expect(find.text('Soul'), findsOneWidget);
    expect(find.text('Be careful'), findsOneWidget);
    expect(find.textContaining('2,340 of 2,000 loaded'), findsOneWidget);
    expect(
      find.text('model Orphus default; Google: looks up only'),
      findsOneWidget,
    );

    // Notes go back with the version that was loaded.
    await t.enterText(find.byKey(const ValueKey('notes')), '- Short replies');
    await settle(t);
    expect(find.text('15 of 2,000 loaded'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('save-notes')));
    await settle(t);
    expect(sent['PUT /api/bots/coder/notes'], {
      'notes': '- Short replies',
      'version': 3,
    });

    // A save the server refuses says why and keeps what was typed.
    botSavedMeanwhile = true;
    await t.enterText(find.byKey(const ValueKey('notes')), '- Mine');
    await settle(t);
    await t.tap(find.byKey(const ValueKey('save-notes')));
    await settle(t);
    expect((sent['PUT /api/bots/coder/notes'] as Map)['version'], 4);
    expect(find.text('The bot changed its notes'), findsOneWidget);
    expect(find.text('- Mine'), findsOneWidget);
    // Reload would lose the draft, so it asks first; "Keep editing" keeps it.
    await t.tap(find.byKey(const ValueKey('reload-notes')));
    await settle(t);
    expect(find.text('Reload and lose your changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await settle(t);
    expect(find.text('- Mine'), findsOneWidget);
    // Reload brings the server's copy back.
    await t.tap(find.byKey(const ValueKey('reload-notes')));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Reload'));
    await settle(t);
    expect(find.text('- Short replies'), findsOneWidget);
    expect(find.text('The bot changed its notes'), findsNothing);

    // The soul is the bot's instructions, saved onto the bot as it is now,
    // so a setting changed elsewhere meanwhile is kept.
    await t.enterText(find.byKey(const ValueKey('soul')), 'Be bold');
    await settle(t);
    await t.tap(find.byKey(const ValueKey('save-soul')));
    await settle(t);
    expect(sent['POST /api/bots/update'], {
      'slug': 'coder',
      'name': 'Coder',
      'instructions': 'Be bold',
      'scope': 'private',
      'model': 'new-model',
    });

    // An unsaved edit asks before the panel closes.
    await t.enterText(find.byKey(const ValueKey('soul')), 'Be bolder');
    await settle(t);
    await t.pageBack();
    await settle(t);
    expect(find.text('Leave without saving?'), findsOneWidget);
    await t.tap(find.text('Leave'));
    await settle(t);
    expect(result, isTrue, reason: 'the instructions were saved earlier');
  });

  testWidgets('nothing typed is lost to a slow save or a slow reload', (
    t,
  ) async {
    // Each answer waits until the test lets it go.
    Completer<void>? hold;
    final puts = <Object?>[];
    final api = Api(
      'http://server',
      'session=x',
      MockClient((r) async {
        await hold?.future;
        if (r.method == 'PUT') {
          puts.add(jsonDecode(r.body));
          return http.Response(jsonEncode({'version': 1 + puts.length}), 200);
        }
        return http.Response(
          jsonEncode({
            'notes': '- From the server',
            'version': 1,
            'loaded_chars': 2000,
            'can_do': 'model Orphus default',
          }),
          200,
        );
      }),
    );
    t.view.physicalSize = const Size(700, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: BotPanel(
          api: api,
          bot: const {'slug': 'coder', 'name': 'Coder', 'instructions': ''},
        ),
      ),
    );
    await settle(t);
    final box = find.byKey(const ValueKey('notes'));
    FilledButton save() =>
        t.widget<FilledButton>(find.byKey(const ValueKey('save-notes')));

    // A is on its way to the server when B is typed: B is still unsaved after.
    await t.enterText(box, 'A');
    await settle(t);
    hold = Completer<void>();
    await t.tap(find.byKey(const ValueKey('save-notes')));
    await t.pump();
    // Reload waits for the save, so an older answer can't land on top of it.
    expect(
      t
          .widget<TextButton>(find.byKey(const ValueKey('reload-notes')))
          .onPressed,
      isNull,
    );
    await t.enterText(box, 'B');
    hold.complete();
    hold = null;
    await settle(t);
    expect(puts, [
      {'notes': 'A', 'version': 1},
    ]);
    expect(find.text('B'), findsOneWidget);
    expect(save().onPressed, isNotNull, reason: 'B has not been saved');
    await t.tap(find.byKey(const ValueKey('save-notes')));
    await settle(t);
    expect(puts.last, {'notes': 'B', 'version': 2});
    expect(save().onPressed, isNull);

    // While a reload is on its way there is no box to type into.
    hold = Completer<void>();
    await t.tap(find.text('Reload'));
    await t.pump();
    expect(box, findsNothing);
    hold.complete();
    hold = null;
    await settle(t);
    expect(find.text('- From the server'), findsOneWidget);
  });

  testWidgets('a slow save of the instructions saves only what was sent', (
    t,
  ) async {
    Completer<void>? hold;
    final posts = <Object?>[];
    final api = Api(
      'http://server',
      'session=x',
      MockClient((r) async {
        if (r.url.path == '/api/bots') {
          await hold?.future;
          return http.Response(
            jsonEncode([
              {'slug': 'coder', 'name': 'Coder', 'instructions': ''},
            ]),
            200,
          );
        }
        if (r.method == 'POST') {
          posts.add((jsonDecode(r.body) as Map)['instructions']);
          return http.Response('{}', 200);
        }
        return http.Response(
          jsonEncode({'notes': '', 'version': 1, 'loaded_chars': 2000}),
          200,
        );
      }),
    );
    t.view.physicalSize = const Size(700, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: BotPanel(
          api: api,
          bot: const {'slug': 'coder', 'name': 'Coder', 'instructions': ''},
        ),
      ),
    );
    await settle(t);
    final box = find.byKey(const ValueKey('soul'));
    FilledButton save() =>
        t.widget<FilledButton>(find.byKey(const ValueKey('save-soul')));
    await t.enterText(box, 'A');
    await settle(t);
    hold = Completer<void>();
    await t.tap(find.byKey(const ValueKey('save-soul')));
    await t.pump();
    // One save at a time, and what is typed meanwhile is not part of it.
    await t.enterText(box, 'B');
    await t.pump();
    expect(save().onPressed, isNull);
    hold.complete();
    hold = null;
    await settle(t);
    expect(posts, ['A']);
    expect(save().onPressed, isNotNull, reason: 'B has not been saved');
  });
}
