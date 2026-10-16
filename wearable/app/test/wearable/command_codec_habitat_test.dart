// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The habitat leg of the command codec. Without it every button cue in the A2
// grammar is dropped: the server queues cues by *name*, and the firmware only
// acts on AGENT_OP_HABITAT (0x06) with a numeric cue id in byte 1.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/command_codec.dart';

void main() {
  test('encodes a server cue named by string', () {
    expect(
      encodeCommandFromJson(<String, dynamic>{'kind': 'habitat', 'cue': 'capture_open'}),
      <int>[0x06, 0x01, 0, 0],
    );
    expect(
      encodeCommandFromJson(<String, dynamic>{'kind': 'habitat', 'cue': 'awaiting_input'}),
      <int>[0x06, 0x0C, 0, 0],
    );
  });

  test('encodes an app cue given as an id', () {
    expect(
      encodeCommandFromJson(<String, dynamic>{'kind': 'habitat', 'cue': 0x0A}),
      <int>[0x06, 0x0A, 0, 0],
    );
  });

  test('drops an unknown cue name rather than guessing an id', () {
    expect(
      encodeCommandFromJson(<String, dynamic>{'kind': 'habitat', 'cue': 'not_a_cue'}),
      isNull,
    );
  });

  test('the twelve ids match the firmware AGENT_CUE_* table', () {
    expect(kHabitatCueIds, hasLength(12));
    expect(kHabitatCueIds.values.toSet(), List<int>.generate(12, (i) => i + 1).toSet());
  });
}
