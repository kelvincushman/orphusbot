/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Pure helpers used by the device Inngest step functions.
 *
 * Kept in a separate module so they can be unit-tested under bun:test — the
 * step functions themselves import db.ts transitively, which can't load
 * better-sqlite3 in the bun environment.
 */

export interface Utterance {
  speakerId: string;
  speakerLabel: string;
  isOwner: boolean;
  text: string;
  startMs: number;
  endMs: number;
}

/** Format a diarized transcript (plus raw utterances) into an agent-facing
 *  prompt. Preserves speaker labels and marks the device owner so the agent
 *  knows which speaker's intent to act on. */
export function buildPromptFromTranscript(transcript: string, utterances: Utterance[]): string {
  if (transcript && transcript.trim().length > 0) {
    return [
      "Recent audio captured from the Wearable wearable. Speakers are labelled; the owner (device wearer) is marked (owner).",
      "",
      transcript,
      "",
      "Respond to the owner's intent concisely. If the exchange is ambient chatter with no actionable intent, answer with a single short acknowledgement.",
    ].join("\n");
  }
  if (utterances.length === 0) return "[Empty transcript received from device.]";
  const lines = utterances.map((u) => {
    const ownerTag = u.isOwner ? " (owner)" : "";
    return `${u.speakerLabel}${ownerTag}: ${u.text.trim()}`;
  });
  return [
    "Recent audio captured from the Wearable wearable. Speakers are labelled; the owner is marked (owner).",
    "",
    ...lines,
    "",
    "Respond to the owner's intent concisely.",
  ].join("\n");
}

// Matches the dashboard /api/chat cap so a paired device can't push a larger
// prompt than a web client. The on-device transcriber enforces the same bound.
export const MAX_DEVICE_TEXT_LEN = 4000;

export interface DeviceTextBody {
  text: string;
  overheard: boolean;
  at: number;
}

/** Validate + normalise the POST /api/device/text body. Pure (no SQLite) so it
 *  can be unit-tested under bun:test. Returns the parsed body or an error
 *  string. `now` is injectable for deterministic tests. */
export function validateDeviceTextBody(raw: unknown, now: number = Date.now()): DeviceTextBody | string {
  if (!raw || typeof raw !== "object") return "body must be an object";
  const r = raw as Record<string, unknown>;
  if (typeof r.text !== "string") return "text must be a string";
  const text = r.text.trim();
  if (text.length === 0) return "text must not be empty";
  if (text.length > MAX_DEVICE_TEXT_LEN) return `text exceeds ${MAX_DEVICE_TEXT_LEN} chars`;
  if (r.overheard !== undefined && typeof r.overheard !== "boolean") return "overheard must be a boolean";
  if (r.at !== undefined && typeof r.at !== "number") return "at must be a number";
  return {
    text,
    overheard: r.overheard === true,
    at: typeof r.at === "number" ? r.at : now,
  };
}

export function deriveDeviceTextOverheard(input: {
  clientOverheard: boolean;
  lastIntentAt?: number;
  now: number;
  explicitGraceMs: number;
}): boolean {
  if (input.clientOverheard) return true;
  return input.lastIntentAt === undefined || input.now - input.lastIntentAt > input.explicitGraceMs;
}

/** Wrap an on-device-transcribed request (single speaker, no diarization) into
 *  an agent-facing prompt. Used by the on-device STT path (device-text-prompt):
 *  the phone already transcribed the wearable/mic audio locally with Gemma 4, so
 *  there are no speaker labels — just the cleaned text. */
export function buildPromptFromDeviceText(text: string): string {
  const trimmed = text.trim();
  if (trimmed.length === 0) return "[Empty transcript received from device.]";
  return [
    "Transcribed request from the Wearable wearable (on-device speech-to-text).",
    "",
    trimmed,
    "",
    "Respond to the wearer's intent concisely.",
  ].join("\n");
}

/** Map an agent-result outcome to a habitat-alert name. See device-delivery.ts
 *  for the full routing; this function owns the pure decision. */
export function pickAlert(input: { ok: boolean; output: string }): string {
  if (!input.ok) return "error";
  if (typeof input.output === "string" && input.output.trimStart().startsWith("Refused —")) {
    return "budget_warn";
  }
  return "task_done";
}
