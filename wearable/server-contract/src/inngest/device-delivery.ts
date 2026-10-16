/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Device delivery step function — maps agent results back to the physical
 * device as LED + haptic habitat alerts.
 *
 * Subscribes to wearable/agent.result. Only processes events where channel is
 * "device" (the harness emits this event for every channel; other deliveries
 * are handled by src/harness/inngest/delivery.ts).
 *
 * Outcome → alert name resolution:
 *   ok && output.startsWith("Refused —")   → error        (budget refusals)
 *   ok                                     → task_done
 *   !ok                                    → error
 *
 * Future enrichment: inspect the response for "needs input" markers and fire
 * awaiting_input instead of task_done. Requires a structured response
 * envelope, which is plan §4.x — v1 uses the heuristic above.
 */
import { inngest } from "./client.js";
import { database } from "../../db.js";
import { logger } from "../../logger.js";
import { enqueueCommands } from "../device/channel.js";
import { resolveAlert } from "../device/commands.js";
import { pickAlert } from "../device/alert-mapping.js";

export { pickAlert };

const DEVICE_CHAT_PREFIX = "device:";

export const deviceDelivery = inngest.createFunction(
  {
    id: "device-delivery",
    retries: 2,
  },
  { event: "wearable/agent.result" },
  async ({ event }) => {
    const { channel, chatId, ok, output } = event.data;
    if (channel !== "device") return { skipped: true, reason: `channel=${channel}` };
    if (!chatId.startsWith(DEVICE_CHAT_PREFIX)) {
      logger.warn({ chatId }, "device delivery: chatId does not start with device:");
      return { skipped: true, reason: "malformed chatId" };
    }
    const devId = chatId.slice(DEVICE_CHAT_PREFIX.length);

    const alertName = pickAlert({ ok, output });

    // Enqueue OUTSIDE step.run — the queue is in-memory and non-idempotent;
    // wrapping it in step.run means an Inngest retry re-pushes the alert and
    // the device double-flashes. step.run is for work that must survive
    // crashes; pushing to a local Map doesn't benefit from that guarantee.
    enqueueCommands(devId, resolveAlert(alertName));

    database.audit("device.delivery", { devId, alert: alertName, ok }, chatId);
    logger.info({ devId, alert: alertName, ok }, "device delivery enqueued");
    return { delivered: true, devId, alert: alertName };
  },
);

