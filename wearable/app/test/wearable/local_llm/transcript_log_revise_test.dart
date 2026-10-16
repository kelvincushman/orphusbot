// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The revise half of OnDeviceTranscriptLog — ids, replaceText and the tidy
// flag. Separate file from transcript_log_test.dart, which covers add().
//
// The log is a singleton with no reset, so every test here anchors on the id
// it just got back rather than on a position in the list.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/tidy_runner.dart';
import 'package:kelvinlee/wearable/local_llm/transcript_log.dart';

void main() {
  final log = OnDeviceTranscriptLog.instance;

  group('ids', () {
    test('add returns a handle that finds the entry again', () {
      final id = log.add('the first line of a note');
      expect(id, isNotNull);
      expect(log.byId(id!)!.text, 'the first line of a note');
    });

    test('ignored text returns null, so the caller has nothing to revise', () {
      expect(log.add(''), isNull);
      expect(log.add('   '), isNull);
      expect(log.add('[no speech]'), isNull);
    });

    test('entries logged in the same microsecond still get distinct ids', () {
      // A diarized clip adds one entry per segment in a tight loop; a
      // timestamp alone collides there and replaceText would hit the wrong
      // line.
      final ids = [for (var i = 0; i < 20; i++) log.add('segment number $i')];
      expect(ids.whereType<String>().toSet(), hasLength(20));
    });

    test('a fresh entry is not marked tidied', () {
      final id = log.add('as the recogniser wrote it');
      expect(log.byId(id!)!.isTidied, isFalse);
    });
  });

  group('replaceText', () {
    test('replaces the text and flags the line, leaving the rest alone', () {
      final other = log.add('an unrelated line')!;
      final id = log.add('JEST LOOKIN SEE IF I NEEDER HAD A DIARIN')!;

      expect(log.replaceText(id, 'Just looking to see if I need a diary in.'), isTrue);

      final e = log.byId(id)!;
      expect(e.text, 'Just looking to see if I need a diary in.');
      expect(e.isTidied, isTrue);
      expect(log.byId(other)!.text, 'an unrelated line');
      expect(log.byId(other)!.isTidied, isFalse);
    });

    test('identity evidence survives the rewrite', () {
      // A tidy must not cost the wearer the ability to name that voice.
      final id = log.add('SOME WORDS HERE',
          talker: 'Talker 1', clipId: 'clip-a', clusterIndex: 2, durationS: 7.5)!;
      log.replaceText(id, 'Some words here.');
      final e = log.byId(id)!;
      expect(e.talker, 'Talker 1');
      expect(e.clipId, 'clip-a');
      expect(e.clusterIndex, 2);
      expect(e.durationS, 7.5);
    });

    test('an unknown id changes nothing', () {
      final before = log.entries;
      expect(log.replaceText('no-such-id', 'anything'), isFalse);
      expect(identical(log.entries, before), isTrue);
    });

    test('blank replacement text is refused', () {
      final id = log.add('keep this exactly')!;
      expect(log.replaceText(id, '   '), isFalse);
      expect(log.byId(id)!.text, 'keep this exactly');
    });

    test('a no-op rewrite does not notify listeners', () {
      // Gemma is allowed to return the input unchanged — that is the correct
      // answer for a clean note. Rebuilding the list for it would flicker the
      // transcript page for nothing.
      final id = log.add('already correct')!;
      log.replaceText(id, 'already correct', tidied: true);
      final settled = log.entries;
      expect(log.replaceText(id, 'already correct', tidied: true), isFalse);
      expect(identical(log.entries, settled), isTrue);
    });

    test('relabel still reaches a line that was tidied', () {
      final id = log.add('WE SHOULD MEET ON TUESDAY',
          talker: 'Talker 1', clipId: 'clip-b', clusterIndex: 0)!;
      log.replaceText(id, 'We should meet on Tuesday.');
      expect(log.relabel(clipId: 'clip-b', clusterIndex: 0, talker: 'You'), 1);
      final e = log.byId(id)!;
      expect(e.talker, 'You');
      expect(e.text, 'We should meet on Tuesday.');
      expect(e.isTidied, isTrue);
    });
  });

  // maybeTidy's own guards (the toggle, whether the model is installed) are
  // plugin-backed and belong on hardware. What is testable here is the wiring:
  // which entry the decision lands on, and that a rejected rewrite leaves the
  // recogniser's text alone.
  group('maybeTidy wiring', () {
    Future<bool> on() async => true;

    test('a null id is a no-op', () async {
      final before = log.entries;
      await maybeTidy(null, enabled: on, generate: (_) async => 'anything');
      expect(identical(log.entries, before), isTrue);
    });

    test('the toggle off means the model is never asked', () async {
      var asked = false;
      final id = log.add('ONE TWO THREE FOUR FIVE SIX')!;
      await maybeTidy(id,
          preview: 'wholly different words entirely here now',
          enabled: () async => false,
          generate: (_) async {
            asked = true;
            return 'One, two, three, four, five, six.';
          });
      expect(asked, isFalse);
      expect(log.byId(id)!.text, 'ONE TWO THREE FOUR FIVE SIX');
    });

    test('a gate that says no means the model is never asked', () async {
      var asked = false;
      final id = log.add('ONE TWO THREE FOUR FIVE SIX')!;
      await maybeTidy(id,
          preview: 'one two three four five six', // agreement: nothing to do
          enabled: on,
          generate: (_) async {
            asked = true;
            return 'One, two, three, four, five, six.';
          });
      expect(asked, isFalse);
      expect(log.byId(id)!.isTidied, isFalse);
    });

    test('a gate that says yes replaces that entry and no other', () async {
      final other = log.add('AN UNRELATED LINE OF TEXT')!;
      final id = log.add('JEST LOOKIN SEE IF I NEEDER HAD A DIARIN')!;
      await maybeTidy(id,
          preview: 'just looking see whether needed diary for missing',
          enabled: on,
          generate: (_) async => 'Just looking to see if I need a diary in.');
      expect(log.byId(id)!.text, 'Just looking to see if I need a diary in.');
      expect(log.byId(id)!.isTidied, isTrue);
      expect(log.byId(other)!.isTidied, isFalse);
    });

    test('an invented opening is rejected — the line keeps what was heard', () async {
      const heard = 'JEST LOOKIN SEE IF I NEEDER HAD A DIARIN';
      final id = log.add(heard)!;
      await maybeTidy(id,
          preview: 'just looking see whether needed diary for missing',
          enabled: on,
          generate: (_) async => 'Thank you, Madame President. Just looking to '
              'see if I need a diary in for the meeting today.');
      expect(log.byId(id)!.text, heard);
      expect(log.byId(id)!.isTidied, isFalse);
    });

    test('a model that throws leaves the line alone and does not escape', () async {
      const heard = 'JEST LOOKIN SEE IF I NEEDER HAD A DIARIN';
      final id = log.add(heard)!;
      await maybeTidy(id,
          preview: 'just looking see whether needed diary for missing',
          enabled: on,
          generate: (_) async => throw StateError('model unavailable'));
      expect(log.byId(id)!.text, heard);
    });

    test('no preview (SD sync, continuous) falls back to words-per-second', () async {
      // The bridge has no preview for the SD backlog or a continuous segment
      // and passes null. A normal talking rate must then skip, even though the
      // last button clip's preview would have disagreed with this text.
      var asked = false;
      final id = log.add('ONE TWO THREE FOUR FIVE SIX')!;
      await maybeTidy(id, preview: null, clipSeconds: 2.5, enabled: on, generate: (_) async {
        asked = true;
        return 'One, two, three, four, five, six.';
      });
      expect(asked, isFalse);
      expect(log.byId(id)!.isTidied, isFalse);
    });

    test('the entry pooled duration is preferred over the clip length', () async {
      // 6 words over 12 s of this speaker's pooled speech is 0.5 wps and fires;
      // the same words over the 2 s clipSeconds argument would not have.
      var asked = false;
      final id = log.add('ONE TWO THREE FOUR FIVE SIX', durationS: 12)!;
      await maybeTidy(id, clipSeconds: 2, enabled: on, generate: (_) async {
        asked = true;
        return 'One, two, three, four, five, six.';
      });
      expect(asked, isTrue);
    });
  });
}
