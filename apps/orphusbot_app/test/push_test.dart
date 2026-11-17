import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/push.dart';

void main() {
  test('a push becomes a notification on a desktop only', () {
    bool yes({
      bool desktop = true,
      bool focused = false,
      String? bot = 'coder',
      String? open = 'orchestrator',
    }) =>
        shouldNotify(desktop: desktop, focused: focused, bot: bot, open: open);
    expect(yes(), isTrue);
    // Android has UnifiedPush; the event would be a duplicate.
    expect(yes(desktop: false), isFalse);
    // Focused on another bot's chat: still told.
    expect(yes(focused: true), isTrue);
    // Focused on that bot's chat: it's in front of the owner already.
    expect(yes(focused: true, open: 'coder'), isFalse);
    // That bot's chat open, but the window is in the background.
    expect(yes(open: 'coder'), isTrue);
    // About no bot (a digest, a budget): always told.
    expect(yes(focused: true, bot: null), isTrue);
    // No chat showing (the Gallery is on top): told.
    expect(yes(focused: true, open: null), isTrue);
  });

  testWidgets('a chat covered by another page is not showing', (t) async {
    late BuildContext chat;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            chat = c;
            return const Text('chat');
          },
        ),
      ),
    );
    expect(showingChat(chat, 'coder'), 'coder');
    Navigator.of(chat)
        .push(MaterialPageRoute<void>(builder: (_) => const Text('gallery')));
    await t.pumpAndSettle();
    expect(showingChat(chat, 'coder'), isNull);
    Navigator.of(chat).pop();
    await t.pumpAndSettle();
    expect(showingChat(chat, 'coder'), 'coder');
  });

  test('showPush hands the event to the notifier', () async {
    final shown = <List<Object?>>[];
    Future<void> show(String title, String body, String? bot, int p) async =>
        shown.add([title, body, bot, p]);
    final e = {
      'type': 'push',
      'bot': 'coder',
      'title': 'Coder failed',
      'body': 'The build broke.',
      'priority': 4,
    };
    await showPush(e, open: 'coder', desktop: true, focused: true, show: show);
    expect(shown, isEmpty);
    await showPush(
      e,
      open: 'orchestrator',
      desktop: true,
      focused: true,
      show: show,
    );
    await showPush(
      e,
      open: 'orchestrator',
      desktop: false,
      focused: false,
      show: show,
    );
    expect(shown, [
      ['Coder failed', 'The build broke.', 'coder', 4],
    ]);
  });
}
