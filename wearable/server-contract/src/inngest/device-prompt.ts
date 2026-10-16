/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Device-prompt step function.
 *
 * Two triggers:
 *
 *   1. wearable/device.audio.final — a diarized transcript has been finalised by
 *      the STT pipeline. Build a speaker-annotated prompt, fan out as
 *      wearable/agent.prompt with channel:"device" and the overheard flag.
 *      The existing agentPrompt step fn then dispatches through the harness.
 *
 *   2. wearable/device.button with an intent code ("AGENT_REQUEST", "NOTE", or
 *      "REPLY") — the owner tapped the wearable button to signal intent.
 *      Queue a task_queued habitat alert and wait for the transcript.
 *
 * Both paths funnel through orchestrator.intake() via the existing
 * agentPrompt handler. This file only builds + dispatches events — it never
 * calls intake directly (keeps one code path for turns across all channels).
 */
import { inngest } from "./client.js";
import { database } from "../../db.js";
import { logger } from "../../logger.js";
import { enqueueCommands } from "../device/channel.js";
import { resolveAlert } from "../device/commands.js";
import { buildPromptFromTranscript, buildPromptFromDeviceText } from "../device/alert-mapping.js";
import { stripRolePrefix } from "../../routing.js";

export { buildPromptFromTranscript, buildPromptFromDeviceText };

export const deviceAudioPrompt = inngest.createFunction(
  {
    id: "device-audio-prompt",
    retries: 2,
    // Serialise per-device so two near-simultaneous finals don't race.
    concurrency: [{ scope: "fn", key: "event.data.devId", limit: 1 }],
  },
  { event: "wearable/device.audio.final" },
  async ({ event, step }) => {
    const { devId, chatId, businessId, sessionId, utterances, overheard, transcript } = event.data;

    // Queue the running pattern so the wearer knows Wearable heard them and is
    // working. device-delivery will overwrite this with the final alert.
    // For overheard turns (ambient capture, no tap): skip the LED entirely —
    // bystanders shouldn't see a "Wearable is listening" signal for background
    // conversation they didn't consent to trigger.
    //
    // Enqueue OUTSIDE step.run for the same reason as device-delivery: the
    // in-memory queue is non-idempotent; Inngest retries must not re-push.
    if (!overheard) {
      enqueueCommands(devId, resolveAlert("task_running"));
    }

    // [security S-3] Strip any `@role:` prefix from the transcript before
    // wrapping. STT can transcribe ambient speech; an adversary speaking
    // "at ops colon ..." near the wearable must not be able to hijack role
    // routing. Pair with the channel-based force in orchestrator.intake()
    // for defense-in-depth.
    const stripped = stripRolePrefix(transcript);
    if (stripped.attemptedRole) {
      database.audit(
        "device.voice_role_prefix_stripped",
        { devId, attemptedRole: stripped.attemptedRole },
        chatId,
        businessId,
      );
      logger.warn(
        { devId, attemptedRole: stripped.attemptedRole },
        "device transcript contained @role: prefix; stripped before dispatch",
      );
    }
    const message = buildPromptFromTranscript(stripped.message, utterances);

    // sessionId passed through from audio.final so conversation-log can
    // attribute utterances to exactly this turn (not any turn on the same
    // chatId — that was the captureBuffer contamination bug).
    await step.sendEvent("dispatch", {
      name: "wearable/agent.prompt",
      data: {
        sessionId,
        chatId,
        channel: "device",
        businessId,
        message,
        overheard,
      },
    });

    database.audit("device.prompt.audio", { devId, overheard, utterances: utterances.length }, chatId, businessId);
    logger.info({ devId, overheard, n: utterances.length }, "device audio prompt dispatched");
    return { dispatched: true, sessionId };
  },
);

export const deviceTextPrompt = inngest.createFunction(
  {
    id: "device-text-prompt",
    retries: 2,
    // Serialise per-device, same as the audio path, so back-to-back on-device
    // transcripts don't race into two overlapping turns.
    concurrency: [{ scope: "fn", key: "event.data.devId", limit: 1 }],
  },
  { event: "wearable/device.text.final" },
  async ({ event, step }) => {
    const { devId, chatId, businessId, sessionId, text, overheard } = event.data;

    // Same UX as the audio path: flash "Wearable is working" for explicit asks,
    // stay dark for ambient (overheard) capture. Enqueue OUTSIDE step.run —
    // the in-memory queue is non-idempotent and must not be re-pushed on retry.
    if (!overheard) {
      enqueueCommands(devId, resolveAlert("task_running"));
    }

    // [security S-3] Strip any `@role:` prefix before wrapping. The on-device
    // transcript is just as adversary-influenced as a cloud STT transcript —
    // someone speaking "at ops colon ..." near the wearable must not hijack
    // role routing. Pairs with the channel-based force in orchestrator.intake().
    const stripped = stripRolePrefix(text);
    if (stripped.attemptedRole) {
      database.audit(
        "device.text_role_prefix_stripped",
        { devId, attemptedRole: stripped.attemptedRole },
        chatId,
        businessId,
      );
      logger.warn(
        { devId, attemptedRole: stripped.attemptedRole },
        "device text contained @role: prefix; stripped before dispatch",
      );
    }
    const message = buildPromptFromDeviceText(stripped.message);

    await step.sendEvent("dispatch", {
      name: "wearable/agent.prompt",
      data: {
        sessionId,
        chatId,
        channel: "device",
        businessId,
        message,
        overheard,
      },
    });

    database.audit("device.prompt.text", { devId, overheard }, chatId, businessId);
    logger.info({ devId, overheard }, "device text prompt dispatched");
    return { dispatched: true, sessionId };
  },
);

export const deviceButtonPrompt = inngest.createFunction(
  {
    id: "device-button-prompt",
    retries: 0,
    concurrency: [{ scope: "fn", key: "event.data.devId", limit: 1 }],
  },
  { event: "wearable/device.button" },
  async ({ event }) => {
    const { devId, chatId, businessId, code } = event.data;
    // Intent button codes mean "I'm about to speak" — we queue the habitat alert
    // so Kelvin knows Wearable is ready to listen, but we do NOT dispatch an
    // agent prompt here. The actual dispatch comes from the matching audio
    // final fired by ws-audio.ts. Previously this emitted a stub agent
    // prompt when the WS path wasn't wired; now that it is, a stub would
    // just produce a duplicate dispatch per button press.
    const isIntentButton = code === "AGENT_REQUEST" || code === "NOTE" || code === "REPLY";
    if (!isIntentButton) {
      return { dispatched: false, reason: `ignored code=${code}` };
    }
    enqueueCommands(devId, resolveAlert("task_queued"));
    database.audit("device.button.intent", { devId, code }, chatId, businessId);
    logger.info({ devId, code }, "device intent button acknowledged; awaiting audio final");
    return { dispatched: false, queued: "task_queued" };
  },
);
