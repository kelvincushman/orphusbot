// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Dart mirror of `src/harness/device/commands.ts::encodeCommand`.
// Decodes the JSON command shape returned by `/api/device/command/poll` and
// encodes to the 4-byte GATT packet written to the device's 0xCAB1AB97
// characteristic.
//
// Packet authority: `devices/wearable-kelvinlee/firmware/devkit/src/agent_commands.h`.
// When that header changes, update this file AND `src/harness/device/
// commands.ts` in the same commit.

import 'dart:typed_data';

class CommandOps {
  CommandOps._();
  static const int ledColor    = 0x01;
  static const int ledPattern  = 0x02;
  static const int haptic      = 0x03;
  static const int statusQuery = 0x04;
  static const int habitat     = 0x06;  // 0x05 = NOTIFY, encoded by firmware only
}

/// Cue ids carried in byte 1 of a habitat write. Mirrors `HABITAT_CUE` in
/// commands.ts and the `AGENT_CUE_*` defines in agent_commands.h. The server
/// queues these by *name*; firmware owns what each one looks and feels like.
const Map<String, int> kHabitatCueIds = <String, int>{
  'capture_open': 0x01,
  'note_filed': 0x02,
  'discarded': 0x03,
  'ack': 0x04,
  'nop': 0x05,
  'ble_searching': 0x06,
  'ble_connected': 0x07,
  'ble_idle': 0x08,
  'budget_warn': 0x09,
  'error': 0x0A,
  'task_running': 0x0B,
  'awaiting_input': 0x0C,
};

class CommandPatterns {
  CommandPatterns._();
  static const int off        = 0x00;
  static const int solid      = 0x01;
  static const int breathing  = 0x02;
  static const int pulse      = 0x03;
  static const int blink      = 0x04;
  static const int flash      = 0x05;
  static const int fade       = 0x06;
  static const int altFlash   = 0x07;
  static const int doubleBlink = 0x08;
  // Haptic-specific pattern codes (see commands.ts)
  static const int single     = 0x10;
  static const int double_    = 0x11;  // double is reserved in Dart
  static const int triple     = 0x12;
  static const int long_      = 0x13;
}

/// Encode a JSON command (as returned by /api/device/command/poll) into the
/// 4-byte GATT write payload.
///
/// Returns null if the command kind is unknown — the caller drops it. The
/// server side may add new kinds before the app is updated; dropping
/// unknowns is the safe degradation.
Uint8List? encodeCommandFromJson(Map<String, dynamic> cmd) {
  final kind = cmd['kind'];
  final buf = Uint8List(4);
  switch (kind) {
    case 'led_color':
      buf[0] = CommandOps.ledColor;
      buf[1] = _clampByte(cmd['r']);
      buf[2] = _clampByte(cmd['g']);
      buf[3] = _clampByte(cmd['b']);
      return buf;
    case 'led_pattern':
      buf[0] = CommandOps.ledPattern;
      buf[1] = (cmd['pattern'] as int? ?? 0) & 0xFF;
      _writeDurationBE(buf, cmd['durationMs'] as int?);
      return buf;
    case 'haptic':
      buf[0] = CommandOps.haptic;
      buf[1] = (cmd['pattern'] as int? ?? CommandPatterns.single) & 0xFF;
      _writeDurationBE(buf, cmd['durationMs'] as int?);
      return buf;
    case 'status_query':
      buf[0] = CommandOps.statusQuery;
      return buf;
    case 'habitat':
      // The server names a cue; an int is accepted too so the app can build
      // its own button cues through the same encoder.
      final cue = cmd['cue'];
      final id = cue is int ? cue : kHabitatCueIds[cue];
      if (id == null) return null; // unknown cue name — drop, don't guess
      buf[0] = CommandOps.habitat;
      buf[1] = id & 0xFF;
      return buf;
    default:
      return null;
  }
}

int _clampByte(dynamic v) {
  if (v == null) return 0;
  final n = v is int ? v : (v as num).round();
  if (n < 0) return 0;
  if (n > 255) return 255;
  return n;
}

void _writeDurationBE(Uint8List buf, int? ms) {
  final v = (ms == null || ms < 0) ? 0 : (ms > 0xFFFF ? 0xFFFF : ms);
  buf[2] = (v >> 8) & 0xFF;
  buf[3] = v & 0xFF;
}
