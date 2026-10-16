// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The device-text wire body. The bridge used to push '$talker: $text', which
// meant a speaker renamed on the phone could never propagate — the label was
// already baked into the server's copy. It now travels as its own field.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/wearable_client.dart';

void main() {
  test('a labelled transcript carries the talker as a field, not in the text', () {
    final body = buildDeviceTextBody(
      text: 'MOVE THE STANDUP TO TEN',
      overheard: false,
      at: 1700000000000,
      talker: 'Kelvin',
    );

    expect(body['talker'], 'Kelvin');
    expect(body['text'], 'MOVE THE STANDUP TO TEN');
    expect(body['text'], isNot(contains('Kelvin')));
    expect(body['overheard'], isFalse);
    expect(body['at'], 1700000000000);
  });

  test('no talker means the key is absent — byte-identical to before the field', () {
    final without = buildDeviceTextBody(text: 'HELLO', overheard: true, at: 1);
    expect(without.containsKey('talker'), isFalse);
    expect(without, <String, dynamic>{'text': 'HELLO', 'overheard': true, 'at': 1});

    // A blank or whitespace-only label is the same as none.
    expect(buildDeviceTextBody(text: 'HELLO', overheard: true, at: 1, talker: '   '),
        without);
    expect(buildDeviceTextBody(text: 'HELLO', overheard: true, at: 1, talker: ''), without);
  });

  test('a talker is trimmed and capped rather than failing the push', () {
    expect(
      buildDeviceTextBody(text: 'X', overheard: true, at: 1, talker: '  Talker 2 ')['talker'],
      'Talker 2',
    );

    final long = 'A' * (kMaxTalkerLength + 40);
    final capped = buildDeviceTextBody(text: 'X', overheard: true, at: 1, talker: long)['talker'] as String;
    expect(capped.length, kMaxTalkerLength);
  });
}
