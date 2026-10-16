/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Split out of device.test.ts. `stt.ts` imports `../../env.js`, which did not
 * come across when server-contract/ was extracted, so this file does not load
 * and these tests do not run. It was previously inside device.test.ts, where it
 * took the whole file down with it — including every test of commands.ts, the
 * habitat/button contract. Restore `env.ts` (or inject the config) to bring
 * these back.
 */
import { describe, expect, test } from "bun:test";
import { groupWordsBySpeaker } from "../src/device/stt.js";

describe("stt word grouping", () => {
  // Deterministic stub labeller — lets us assert on grouping without touching
  // SQLite (which bun can't load). Maps speaker_1 to "Kelvin" + owner, rest
  // stay as unknowns.
  const labelStub = (_dev: string, sid: string) => sid === "speaker_1"
    ? { label: "Kelvin", isOwner: true }
    : { label: `Unknown (${sid})`, isOwner: false };

  test("groups contiguous words by speaker into utterances", () => {
    const words = [
      { word: "hello", punctuated_word: "Hello,", start: 0.0, end: 0.5, confidence: 0.9, speaker: 0 },
      { word: "alice", punctuated_word: "Alice.", start: 0.5, end: 1.0, confidence: 0.88, speaker: 0 },
      { word: "hi", punctuated_word: "Hi", start: 1.2, end: 1.4, confidence: 0.92, speaker: 1 },
      { word: "there", punctuated_word: "there.", start: 1.4, end: 1.8, confidence: 0.91, speaker: 1 },
      { word: "ok", punctuated_word: "OK.", start: 2.0, end: 2.2, confidence: 0.85, speaker: 0 },
    ];
    const utts = groupWordsBySpeaker(words, true, "deepgram:wearable-3", "fake-dev", labelStub);
    expect(utts).toHaveLength(3);
    expect(utts[0].speakerId).toBe("speaker_1");
    expect(utts[0].speakerLabel).toBe("Kelvin");
    expect(utts[0].isOwner).toBe(true);
    expect(utts[0].text).toBe("Hello, Alice.");
    expect(utts[1].speakerId).toBe("speaker_2");
    expect(utts[1].isOwner).toBe(false);
    expect(utts[1].text).toBe("Hi there.");
    expect(utts[2].speakerId).toBe("speaker_1");
    expect(utts[2].text).toBe("OK.");
  });

  test("empty word list produces empty utterance list", () => {
    expect(groupWordsBySpeaker([], true, "deepgram:wearable-3", "fake-dev", labelStub)).toEqual([]);
  });

  test("defaults missing speaker index to 0 → speaker_1", () => {
    const utts = groupWordsBySpeaker(
      [{ word: "hi", start: 0, end: 0.1, confidence: 0.9 }],
      false,
      "deepgram:wearable-3",
      "fake-dev",
      labelStub,
    );
    expect(utts[0].speakerId).toBe("speaker_1");
    expect(utts[0].isFinal).toBe(false);
  });

  test("confidence is averaged across grouped words", () => {
    const utts = groupWordsBySpeaker(
      [
        { word: "a", start: 0, end: 0.1, confidence: 1.0, speaker: 0 },
        { word: "b", start: 0.1, end: 0.2, confidence: 0.5, speaker: 0 },
      ],
      true,
      "deepgram:wearable-3",
      "fake-dev",
      labelStub,
    );
    expect(utts[0].confidence).toBeCloseTo(0.75);
  });

  test("word-level start/end convert to ms integers", () => {
    const utts = groupWordsBySpeaker(
      [
        { word: "a", start: 1.234, end: 1.56, confidence: 0.9, speaker: 0 },
      ],
      true,
      "deepgram:wearable-3",
      "fake-dev",
      labelStub,
    );
    expect(utts[0].startMs).toBe(1234);
    expect(utts[0].endMs).toBe(1560);
  });
});
