/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Command packet encoder for GATT characteristic 0xCAB1AB97 on the Wearable
 * firmware (see plan §2.4 and devices/wearable-kelvinlee/firmware/devkit/src/
 * agent_commands.c).
 *
 * Wire format: 4 bytes, little-endian semantics per op.
 *
 *   [op][a][b][c]
 *
 *   op = 0x01  LED_COLOR       a=R  b=G  c=B
 *   op = 0x02  LED_PATTERN     a=pattern  b=duration_hi  c=duration_lo (ms)
 *   op = 0x03  HAPTIC          a=pattern  b=duration_hi  c=duration_lo (ms)
 *   op = 0x04  STATUS_QUERY    a=b=c=0   (device responds via 0x23BA7924 notify)
 *   op = 0x05  NOTIFY          a=tier    (firmware-owned; nothing here encodes it)
 *   op = 0x06  HABITAT         a=cue id  b=c=0
 *
 * OP.HABITAT names a whole cue (colour + pattern + haptic) in a single write so
 * the phone never composes LED/haptic triples and the two sides cannot drift on
 * pattern enums. Firmware dispatches byte 1 straight to its habitat_*() table.
 *
 * The *uplink* button codes (characteristic 0x23BA7925) are NOT in this file --
 * they live in ./channel.ts. Per the A2 button spec their numeric values are
 * unchanged: 6, 7 and 8 keep their wire values and only change meaning
 * (AGENT_REQUEST->CANCEL, NOTE->CAPTURE_TOGGLE, REPLY->LINK_RECOVER), and 9/10/11
 * are new. Nothing in this encoder is renumbered by that change.
 *
 * Pattern codes are shared by LED_PATTERN and HAPTIC ops so the encoder doesn't
 * need to track which is which. Durations are unsigned 16-bit big-endian
 * (high byte first) so an operator reading the packet on a serial log can
 * decode visually.
 */

export const GATT_AGENT_COMMANDS_UUID = "CAB1AB97-0000-1000-8000-00805F9B34FB";

export const OP = {
  LED_COLOR: 0x01,
  LED_PATTERN: 0x02,
  HAPTIC: 0x03,
  STATUS_QUERY: 0x04,
  // 0x05 = NOTIFY: firmware picks the LED+haptic for a tier itself, so the
  // server has never needed to encode it. Left as a hole, not a typo.
  HABITAT: 0x06,
} as const;

export const PATTERN = {
  OFF: 0x00,
  SOLID: 0x01,
  BREATHING: 0x02,
  PULSE: 0x03,       // single slow pulse
  BLINK: 0x04,       // fast on/off
  FLASH: 0x05,       // one bright flash then off
  FADE: 0x06,        // linear fade from current brightness to 0
  ALT_FLASH: 0x07,   // two-colour alternating flash (uses the alt colour)
  DOUBLE_BLINK: 0x08,
  SINGLE: 0x10,      // haptic: one short buzz
  DOUBLE: 0x11,      // haptic: two short
  TRIPLE: 0x12,      // haptic: three short
  LONG: 0x13,        // haptic: one long buzz
} as const;

/** Habitat cue ids carried in byte 1 of an OP.HABITAT write. Names match the
 *  firmware habitat_*() functions one-for-one; mirrored in
 *  firmware/devkit/src/agent_commands.h and app/lib/wearable/command_codec.dart. */
export const HABITAT_CUE = {
  capture_open: 0x01,
  note_filed: 0x02,
  discarded: 0x03,
  ack: 0x04,
  nop: 0x05,
  ble_searching: 0x06,
  ble_connected: 0x07,
  ble_idle: 0x08,
  budget_warn: 0x09,
  error: 0x0a,
  task_running: 0x0b,
  awaiting_input: 0x0c,
} as const;

export type Op = (typeof OP)[keyof typeof OP];
export type Pattern = (typeof PATTERN)[keyof typeof PATTERN];
export type HabitatCue = keyof typeof HABITAT_CUE;

export interface LedColorCmd { kind: "led_color"; r: number; g: number; b: number; }
export interface LedPatternCmd { kind: "led_pattern"; pattern: Pattern; durationMs?: number; }
export interface HapticCmd { kind: "haptic"; pattern: Pattern; durationMs?: number; }
export interface StatusQueryCmd { kind: "status_query"; }
export interface HabitatCmd { kind: "habitat"; cue: HabitatCue; }
export type DeviceCommand = LedColorCmd | LedPatternCmd | HapticCmd | StatusQueryCmd | HabitatCmd;

function clampByte(n: number): number {
  if (!Number.isFinite(n)) return 0;
  const i = Math.round(n);
  if (i < 0) return 0;
  if (i > 255) return 255;
  return i;
}

function clampMs(ms: number | undefined): [number, number] {
  // Big-endian u16, max 65535 ms (~65 s). Callers wanting forever durations
  // should issue SOLID with duration 0 and clear with explicit OFF later.
  const v = Math.max(0, Math.min(0xffff, Math.round(ms ?? 0)));
  return [(v >> 8) & 0xff, v & 0xff];
}

/** Encode a DeviceCommand into the 4-byte GATT write payload. */
export function encodeCommand(cmd: DeviceCommand): Uint8Array {
  const buf = new Uint8Array(4);
  switch (cmd.kind) {
    case "led_color":
      buf[0] = OP.LED_COLOR;
      buf[1] = clampByte(cmd.r);
      buf[2] = clampByte(cmd.g);
      buf[3] = clampByte(cmd.b);
      return buf;
    case "led_pattern": {
      const [hi, lo] = clampMs(cmd.durationMs);
      buf[0] = OP.LED_PATTERN;
      buf[1] = cmd.pattern & 0xff;
      buf[2] = hi;
      buf[3] = lo;
      return buf;
    }
    case "haptic": {
      const [hi, lo] = clampMs(cmd.durationMs);
      buf[0] = OP.HAPTIC;
      buf[1] = cmd.pattern & 0xff;
      buf[2] = hi;
      buf[3] = lo;
      return buf;
    }
    case "status_query":
      buf[0] = OP.STATUS_QUERY;
      return buf;
    case "habitat":
      buf[0] = OP.HABITAT;
      // Unknown cue -> 0, which no habitat_*() claims, so firmware ignores it.
      buf[1] = HABITAT_CUE[cmd.cue] ?? 0;
      return buf;
  }
}

/** Named habitat-alert signals, resolved to {led + haptic} command pairs.
 *  Source vocabulary: devices/wearable-kelvinlee/docs/HABITAT_ALERTS.md (plan §4.3). */
export const HABITAT_ALERTS: Record<string, DeviceCommand[]> = {
  // Task lifecycle
  task_queued: [
    { kind: "led_pattern", pattern: PATTERN.PULSE, durationMs: 1000 },
    { kind: "led_color", r: 0, g: 80, b: 200 },
    { kind: "haptic", pattern: PATTERN.SINGLE, durationMs: 120 },
  ],
  task_running: [
    { kind: "led_pattern", pattern: PATTERN.BREATHING, durationMs: 0 },
    { kind: "led_color", r: 0, g: 80, b: 200 },
  ],
  // Habitat form, not a triple: these two are the only alerts the app has to
  // recognise (spec section 3 rows E/F arm ALERT_PENDING off the cue id), and
  // an LED+haptic triple carries no name to recognise. habitat_awaiting_input()
  // and habitat_error() compose exactly what the triples did.
  awaiting_input: [{ kind: "habitat", cue: "awaiting_input" }],
  task_done: [
    { kind: "led_pattern", pattern: PATTERN.FLASH, durationMs: 2000 },
    { kind: "led_color", r: 0, g: 200, b: 60 },
    { kind: "haptic", pattern: PATTERN.DOUBLE, durationMs: 300 },
  ],
  error: [{ kind: "habitat", cue: "error" }],
  budget_warn: [
    { kind: "led_pattern", pattern: PATTERN.BREATHING, durationMs: 0 },
    { kind: "led_color", r: 220, g: 140, b: 0 },
  ],

  // Button + capture cues (A2 button spec section 3). One OP.HABITAT write
  // each -- firmware owns the colour/pattern/haptic composition, so these
  // cannot drift from habitat.c the way an LED+haptic triple can.
  //
  // Ponytail: the four task alerts above stay as LED+haptic triples because they
  // already work on shipped firmware. budget_warn and task_running have cue ids
  // and are a one-line swap once OP.HABITAT is proven on hardware; task_queued
  // and task_done would need a new id minted on both sides first.
  //
  // Ponytail: this is one flat map, so the server can technically name a ble_*
  // cue that the spec says firmware owns. Splitting it into server-sendable and
  // app-sendable halves costs a second map and an access check for a caller
  // that does not exist. If the server ever starts lying about link state,
  // that is the split to make.
  capture_open: [{ kind: "habitat", cue: "capture_open" }],
  note_filed: [{ kind: "habitat", cue: "note_filed" }],
  discarded: [{ kind: "habitat", cue: "discarded" }],
  ack: [{ kind: "habitat", cue: "ack" }],
  nop: [{ kind: "habitat", cue: "nop" }],
  ble_searching: [{ kind: "habitat", cue: "ble_searching" }],
  ble_connected: [{ kind: "habitat", cue: "ble_connected" }],
  ble_idle: [{ kind: "habitat", cue: "ble_idle" }],
};

/** Resolve a habitat-alert name into its queued command packets. Returns
 *  an empty array for unknown names (caller can log but never crash). */
export function resolveAlert(name: string): DeviceCommand[] {
  return HABITAT_ALERTS[name] ?? [];
}
