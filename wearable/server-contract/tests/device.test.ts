/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Pure-helper tests for the Phase 1 Wearable device modules.
 *
 * Intentionally scoped to functions that don't touch SQLite — bun:test cannot
 * load better-sqlite3's native binding (see oven-sh/bun#4290), so the
 * DB-backed bits (registry, voice-profiles, obsidian-writer, channel HTTP
 * handlers) are exercised via the production runtime (tsx) through the
 * dashboard instead. This file covers the pure encoder + grouping helpers.
 */
import { describe, expect, test } from "bun:test";
import { encodeCommand, HABITAT_ALERTS, resolveAlert, OP, PATTERN } from "../src/device/commands.js";
import {
  buildPromptFromTranscript,
  buildPromptFromDeviceText,
  deriveDeviceTextOverheard,
  pickAlert,
  validateDeviceTextBody,
  MAX_DEVICE_TEXT_LEN,
} from "../src/device/alert-mapping.js";

describe("device commands encoder", () => {
  test("LED_COLOR packs RGB into bytes 1-3", () => {
    const buf = encodeCommand({ kind: "led_color", r: 10, g: 200, b: 255 });
    expect(buf).toEqual(new Uint8Array([OP.LED_COLOR, 10, 200, 255]));
  });

  test("LED_PATTERN encodes duration big-endian", () => {
    const buf = encodeCommand({ kind: "led_pattern", pattern: PATTERN.PULSE, durationMs: 1500 });
    expect(buf[0]).toBe(OP.LED_PATTERN);
    expect(buf[1]).toBe(PATTERN.PULSE);
    // 1500 = 0x05DC → [0x05, 0xDC]
    expect(buf[2]).toBe(0x05);
    expect(buf[3]).toBe(0xDC);
  });

  test("HAPTIC uses op 0x03", () => {
    const buf = encodeCommand({ kind: "haptic", pattern: PATTERN.DOUBLE, durationMs: 300 });
    expect(buf[0]).toBe(OP.HAPTIC);
    expect(buf[1]).toBe(PATTERN.DOUBLE);
  });

  test("duration clamps to 16-bit max", () => {
    const buf = encodeCommand({ kind: "led_pattern", pattern: PATTERN.SOLID, durationMs: 999_999 });
    expect(buf[2]).toBe(0xFF);
    expect(buf[3]).toBe(0xFF);
  });

  test("LED_COLOR byte channels clamp to 0..255", () => {
    const buf = encodeCommand({ kind: "led_color", r: -5, g: 999, b: 100.6 });
    expect(buf).toEqual(new Uint8Array([OP.LED_COLOR, 0, 255, 101]));
  });

  test("STATUS_QUERY packs op byte only", () => {
    const buf = encodeCommand({ kind: "status_query" });
    expect(buf).toEqual(new Uint8Array([OP.STATUS_QUERY, 0, 0, 0]));
  });

  test("HABITAT_ALERTS has the full vocabulary", () => {
    for (const key of ["task_queued", "task_running", "awaiting_input", "task_done", "error", "budget_warn"]) {
      expect(HABITAT_ALERTS[key]).toBeDefined();
      expect(HABITAT_ALERTS[key].length).toBeGreaterThan(0);
    }
  });

  // The habitat op is the only channel the button grammar's cues travel on.
  // It shipped once with no firmware case and once with a name/id mismatch in
  // the app codec; both dropped every cue silently, so pin the wire here.
  test("every button cue is one OP.HABITAT write with its documented id", () => {
    const expected: Record<string, number> = {
      capture_open: 0x01, note_filed: 0x02, discarded: 0x03, ack: 0x04,
      nop: 0x05, ble_searching: 0x06, ble_connected: 0x07, ble_idle: 0x08,
      budget_warn: 0x09, error: 0x0a, task_running: 0x0b, awaiting_input: 0x0c,
    };
    for (const [cue, id] of Object.entries(expected)) {
      expect(encodeCommand({ kind: "habitat", cue: cue as never })).toEqual(
        new Uint8Array([OP.HABITAT, id, 0, 0]),
      );
    }
  });

  test("the two alerts the app must recognise resolve to a named cue", () => {
    // An LED+haptic triple carries no name, so ALERT_PENDING (spec rows E/F)
    // can only arm off the habitat form.
    expect(resolveAlert("awaiting_input")).toEqual([{ kind: "habitat", cue: "awaiting_input" }]);
    expect(resolveAlert("error")).toEqual([{ kind: "habitat", cue: "error" }]);
  });

  test("resolveAlert returns [] for unknown names", () => {
    expect(resolveAlert("not-a-real-alert")).toEqual([]);
  });

  test("task_queued resolves to blue LED + single haptic", () => {
    const cmds = resolveAlert("task_queued");
    // Expect at least one LED command and one haptic command.
    const hasLed = cmds.some((c) => c.kind === "led_color" || c.kind === "led_pattern");
    const hasHaptic = cmds.some((c) => c.kind === "haptic");
    expect(hasLed).toBe(true);
    expect(hasHaptic).toBe(true);
  });
});


describe("device-prompt buildPromptFromTranscript", () => {
  test("prefers transcript text when non-empty", () => {
    const prompt = buildPromptFromTranscript(
      "Kelvin (owner): remind me tomorrow\nAlice: sounds good",
      [],
    );
    expect(prompt).toContain("Kelvin (owner): remind me tomorrow");
    expect(prompt).toContain("Respond to the owner's intent");
  });

  test("formats from utterances when transcript is empty", () => {
    const prompt = buildPromptFromTranscript("", [
      { speakerId: "speaker_1", speakerLabel: "Kelvin", isOwner: true, text: "remind me", startMs: 0, endMs: 500 },
      { speakerId: "speaker_2", speakerLabel: "Alice", isOwner: false, text: "good", startMs: 600, endMs: 900 },
    ]);
    expect(prompt).toContain("Kelvin (owner): remind me");
    expect(prompt).toContain("Alice: good");
  });

  test("empty inputs produce a sentinel string, never crash", () => {
    expect(buildPromptFromTranscript("", [])).toContain("Empty transcript");
  });
});

describe("device-text buildPromptFromDeviceText", () => {
  test("wraps cleaned text with the on-device STT framing", () => {
    const prompt = buildPromptFromDeviceText("remind me to call Alice tomorrow");
    expect(prompt).toContain("on-device speech-to-text");
    expect(prompt).toContain("remind me to call Alice tomorrow");
    expect(prompt).toContain("Respond to the wearer's intent");
  });

  test("trims surrounding whitespace", () => {
    const prompt = buildPromptFromDeviceText("   hello there   ");
    expect(prompt).toContain("\nhello there\n");
  });

  test("empty / whitespace-only input produces a sentinel, never crashes", () => {
    expect(buildPromptFromDeviceText("")).toContain("Empty transcript");
    expect(buildPromptFromDeviceText("    ")).toContain("Empty transcript");
  });
});

describe("device-text validateDeviceTextBody", () => {
  test("accepts a minimal valid body and defaults overheard=false + at=now", () => {
    const parsed = validateDeviceTextBody({ text: "hello" }, 1234);
    expect(parsed).toEqual({ text: "hello", overheard: false, at: 1234 });
  });

  test("trims text and honours explicit overheard + at", () => {
    const parsed = validateDeviceTextBody({ text: "  hi  ", overheard: true, at: 99 });
    expect(parsed).toEqual({ text: "hi", overheard: true, at: 99 });
  });

  test("rejects non-object, missing text, and empty text", () => {
    expect(typeof validateDeviceTextBody(null)).toBe("string");
    expect(typeof validateDeviceTextBody({})).toBe("string");
    expect(typeof validateDeviceTextBody({ text: "   " })).toBe("string");
  });

  test("rejects oversized text", () => {
    const tooLong = "a".repeat(MAX_DEVICE_TEXT_LEN + 1);
    expect(typeof validateDeviceTextBody({ text: tooLong })).toBe("string");
  });

  test("rejects wrong-typed overheard / at", () => {
    expect(typeof validateDeviceTextBody({ text: "hi", overheard: "yes" })).toBe("string");
    expect(typeof validateDeviceTextBody({ text: "hi", at: "now" })).toBe("string");
  });
});

describe("device-text deriveDeviceTextOverheard", () => {
  test("keeps client-marked SD/phone ambient text overheard even after an intent button", () => {
    expect(
      deriveDeviceTextOverheard({
        clientOverheard: true,
        lastIntentAt: 1_000,
        now: 2_000,
        explicitGraceMs: 90_000,
      }),
    ).toBe(true);
  });

  test("treats non-ambient text after a recent intent button as explicit", () => {
    expect(
      deriveDeviceTextOverheard({
        clientOverheard: false,
        lastIntentAt: 1_000,
        now: 2_000,
        explicitGraceMs: 90_000,
      }),
    ).toBe(false);
  });

  test("classifies missing or stale intent as overheard", () => {
    expect(
      deriveDeviceTextOverheard({
        clientOverheard: false,
        now: 2_000,
        explicitGraceMs: 90_000,
      }),
    ).toBe(true);
    expect(
      deriveDeviceTextOverheard({
        clientOverheard: false,
        lastIntentAt: 1_000,
        now: 100_001,
        explicitGraceMs: 90_000,
      }),
    ).toBe(true);
  });
});

describe("device-delivery pickAlert", () => {
  test("ok=true and normal output → task_done", () => {
    expect(pickAlert({ ok: true, output: "Scheduled your reminder." })).toBe("task_done");
  });
  test("ok=true but Refused prefix → budget_warn", () => {
    expect(pickAlert({ ok: true, output: "Refused — daily USD cap reached." })).toBe("budget_warn");
  });
  test("ok=false → error", () => {
    expect(pickAlert({ ok: false, output: "worker crashed" })).toBe("error");
  });
  test("handles leading whitespace on output", () => {
    expect(pickAlert({ ok: true, output: "   Refused — daily dispatch cap." })).toBe("budget_warn");
  });
});
