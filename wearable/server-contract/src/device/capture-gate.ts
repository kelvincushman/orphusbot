/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Audio capture gate (S-4, docs/plans/wearable-one-product-pivot.md §4.5).
 *
 * The core privacy contract: audio frames never reach Deepgram (and therefore
 * never reach the orchestrator, Obsidian, or memory) unless EITHER
 *   (a) the user opened a capture window via a button press within the last
 *       WEARABLE_CAPTURE_WINDOW_MS (button-press gating), OR
 *   (b) the device has hands-free mode turned on AND the operator has not
 *       forbidden hands-free at the server level (WEARABLE_HANDS_FREE_ALLOWED).
 *
 * Hands-free mode *admits* frames into the STT pipeline; owner-voice filtering
 * then drops non-owner utterances at the STT-output layer (see stt.ts). That
 * split is intentional: Deepgram diarisation is required to know who is
 * speaking, so we can't gate at the frame level for hands-free.
 *
 * This module is deliberately pure — it takes a snapshot and returns a
 * decision. No fs, no db, no env. The env-level hands-free allow bit is
 * passed in by the caller so tests don't need to set env vars.
 */

export interface CaptureGateInput {
  /** Current wall-clock ms. Passed explicitly so tests can control time. */
  now: number;
  /** Epoch ms after which the button-press capture window expires. Undefined
   *  or any past value means the window is closed. */
  captureWindowUntil: number | undefined;
  /** Per-device hands-free flag from device_registrations. */
  handsFreeMode: boolean;
  /** Global operator kill-switch (env WEARABLE_HANDS_FREE_ALLOWED). When false,
   *  the device-level flag is ignored — button press is the only path in. */
  handsFreeAllowed: boolean;
}

export type CaptureDecision =
  | { admit: true; reason: "button_window" | "hands_free" }
  | { admit: false; reason: "no_window" | "hands_free_disallowed" };

/** Decide whether an incoming audio frame should be passed to Deepgram.
 *  Returned `reason` feeds audit logging so operators can tell the gate apart
 *  from other drop causes (malformed Opus, WS hiccup, etc.). */
export function shouldProcessAudioFrame(input: CaptureGateInput): CaptureDecision {
  const { now, captureWindowUntil, handsFreeMode, handsFreeAllowed } = input;
  const inWindow = typeof captureWindowUntil === "number" && captureWindowUntil > now;
  if (inWindow) return { admit: true, reason: "button_window" };
  if (handsFreeMode && handsFreeAllowed) return { admit: true, reason: "hands_free" };
  if (handsFreeMode && !handsFreeAllowed) return { admit: false, reason: "hands_free_disallowed" };
  return { admit: false, reason: "no_window" };
}

/** Compute the new captureWindowUntil after a button press. Pure; caller
 *  stores the result on per-connection state. Rolling window semantics:
 *  subsequent presses within an active window extend the deadline rather
 *  than start a fresh one. */
export function extendCaptureWindow(now: number, windowMs: number): number {
  return now + windowMs;
}
