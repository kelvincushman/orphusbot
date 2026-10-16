// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Unit tests for expandSlashCommand — pure function, no Flutter bindings needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/chat/slash_commands.dart';

void main() {
  group('expandSlashCommand — local actions', () {
    test('/clear returns localAction:clear', () {
      final r = expandSlashCommand('/clear');
      expect(r, isNotNull);
      expect(r!.localAction, 'clear');
      expect(r.prompt, isNull);
    });

    test('/help returns localAction:help', () {
      final r = expandSlashCommand('/help');
      expect(r, isNotNull);
      expect(r!.localAction, 'help');
      expect(r.prompt, isNull);
    });

    test('/clear with trailing whitespace is still recognized', () {
      final r = expandSlashCommand('  /clear  ');
      expect(r?.localAction, 'clear');
    });

    test('/CLEAR is case-insensitive', () {
      final r = expandSlashCommand('/CLEAR');
      expect(r?.localAction, 'clear');
    });

    test('/HELP is case-insensitive', () {
      final r = expandSlashCommand('/HELP');
      expect(r?.localAction, 'help');
    });
  });

  group('expandSlashCommand — prompt shortcuts', () {
    test('/email expands with args', () {
      final r = expandSlashCommand('/email follow up with Alice about the Q2 deck');
      expect(r, isNotNull);
      expect(r!.localAction, isNull);
      expect(r.prompt,
          'Draft an email: follow up with Alice about the Q2 deck and put it in my drafts');
    });

    test('/email without args still produces a prompt', () {
      final r = expandSlashCommand('/email');
      expect(r?.prompt, isNotNull);
      expect(r!.prompt, contains('email'));
    });

    test('/research expands with args', () {
      final r = expandSlashCommand('/research quantum computing trends 2025');
      expect(r?.prompt, 'Research: quantum computing trends 2025');
    });

    test('/remind expands with args', () {
      final r = expandSlashCommand('/remind call Mum on Sunday');
      expect(r?.prompt, 'Remind me to call Mum on Sunday');
    });

    test('/note expands with args', () {
      final r = expandSlashCommand('/note buy oat milk');
      expect(r?.prompt, 'Make a note: buy oat milk');
    });

    test('/blog expands with args', () {
      final r = expandSlashCommand('/blog the future of wearables');
      expect(r?.prompt, 'Write a blog post: the future of wearables');
    });

    test('/research without args still produces a prompt', () {
      final r = expandSlashCommand('/research');
      expect(r?.prompt, isNotNull);
    });

    test('/remind without args still produces a prompt', () {
      final r = expandSlashCommand('/remind');
      expect(r?.prompt, isNotNull);
    });
  });

  group('expandSlashCommand — plain text passthrough', () {
    test('plain text returns null', () {
      expect(expandSlashCommand('hello world'), isNull);
    });

    test('empty string returns null', () {
      expect(expandSlashCommand(''), isNull);
    });

    test('unrecognized slash command returns null', () {
      expect(expandSlashCommand('/unknown'), isNull);
    });

    test('text with slash not at start returns null', () {
      expect(expandSlashCommand('visit https://example.com'), isNull);
    });

    test('whitespace-only string returns null', () {
      expect(expandSlashCommand('   '), isNull);
    });
  });

  group('filterCommands', () {
    test('empty query returns all commands', () {
      expect(filterCommands(''), hasLength(kSlashCommands.length));
    });

    test('c filters to commands starting with c', () {
      final result = filterCommands('c');
      expect(result.every((c) => c.name.startsWith('c')), isTrue);
    });

    test('re matches research and remind', () {
      final result = filterCommands('re');
      expect(result.map((c) => c.name), containsAll(['research', 'remind']));
    });

    test('exact match returns single command', () {
      final result = filterCommands('clear');
      expect(result, hasLength(1));
      expect(result.first.name, 'clear');
    });

    test('no match returns empty list', () {
      expect(filterCommands('zzz'), isEmpty);
    });

    test('case-insensitive filter', () {
      final result = filterCommands('CLEAR');
      expect(result, hasLength(1));
      expect(result.first.name, 'clear');
    });
  });
}
