/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Device HTTP channel — harness-internal endpoints mounted by dashboard.ts.
 *
 * Routes (all under /api/device/*):
 *   POST /event              — button / heartbeat / agent_request
 *   POST /text               — on-device-STT transcript intake (Gemma 4 on phone)
 *   POST /command/poll       — app polls pending LED/haptic commands
 *   POST /command/enqueue    — internal (delivery step fn only)
 *   POST /voice-profile/train — enroll a speaker profile
 *   GET  /voice-profiles     — list profiles for a device
 *   PATCH /voice-profiles/:id — rename a profile / mark as owner
 *   GET  /list               — operator: list all paired devices
 *   POST /register           — operator: register a new device, returns token
 *
 * Auth model:
 *   - /register, /list, and PATCH voice-profiles require the dashboard
 *     bearer token (same primitive as /api/*).
 *   - Device-facing routes (/event, /command/poll, /voice-profile/train)
 *     require the device pairing token — verified via verifyPairingToken()
 *     with constant-time compare. The token travels in the X-Device-Token
 *     header or as ?token= on the URL (for WebSocket-ish clients).
 *
 * WebSocket audio streaming (GET /ws/audio?devId=&token=) is a separate, next
 * commit — it needs the `ws` npm dependency wired into index.ts's server.
 * For now this file ships the HTTP surface; audio arrives via POST /audio
 * chunks as a fallback (also not in v1 — enable in the WS sibling commit).
 */
import { randomUUID } from "node:crypto";
import type { Context, Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { inngest } from "../inngest/client.js";
import { takeToken } from "../../rate-limit.js";
import { database, DEFAULT_BUSINESS_ID } from "../../db.js";
import { logger } from "../../logger.js";
import {
  chatIdFor,
  createDevice,
  deleteDevice,
  getDevice,
  getHandsFreeMode,
  listDevices,
  setDeviceBusiness,
  setHandsFreeMode,
  touchDevice,
  verifyPairingToken,
} from "./registry.js";
import {
  deleteProfile,
  enrollProfile,
  listProfiles,
  markOwner,
  renameProfile,
} from "./voice-profiles.js";
import type { DeviceCommand } from "./commands.js";
import { deriveDeviceTextOverheard, validateDeviceTextBody } from "./alert-mapping.js";
import { lastAgentRequestAt, markAgentRequestAt, refreshHandsFreeMode } from "./ws-audio.js";
import { hasOwnerProfile, latestSamplePath, storeWavSample } from "./speech-profile-api.js";
import { env } from "../../env.js";

// ---------------------------------------------------------------------------
// Per-device command queue (in-memory; fine for single-instance deployment).
// The Flutter app polls /command/poll on a 1-2 s cadence. If we scale out or
// restart under load, queued commands are lost — acceptable for habitat alerts
// (they're time-sensitive; a dropped "task done" flash is recoverable by the
// operator checking the dashboard).
// ---------------------------------------------------------------------------

const COMMAND_QUEUE_MAX = 32;
const queues = new Map<string, DeviceCommand[]>();

// On-device STT text turns arrive after local transcription, which adds latency
// on top of the capture window. Treat a turn as explicit (not overheard) if an
// Intent button press landed within this window before the text POST. Covers
// NOTE's 60 s voice-note cap plus on-device transcription/send latency so a
// deliberate button capture isn't misread as ambient.
const DEVICE_TEXT_EXPLICIT_GRACE_MS = 90_000;

export function enqueueCommands(devId: string, commands: DeviceCommand[]): void {
  if (commands.length === 0) return;
  const existing = queues.get(devId) ?? [];
  const next = existing.concat(commands).slice(-COMMAND_QUEUE_MAX);
  queues.set(devId, next);
}

function drainQueue(devId: string): DeviceCommand[] {
  const q = queues.get(devId);
  if (!q || q.length === 0) return [];
  queues.delete(devId);
  return q;
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

function extractDeviceAuth(c: Context): { devId: string; token: string } | null {
  const devId = c.req.header("X-Device-Id") ?? c.req.query("devId");
  const token = c.req.header("X-Device-Token") ?? c.req.query("token");
  if (!devId || !token) return null;
  return { devId, token };
}

async function requireDeviceAuth(c: Context): Promise<{ devId: string } | Response> {
  const auth = extractDeviceAuth(c);
  if (!auth) return c.json({ error: "device auth required (X-Device-Id + X-Device-Token)" }, 401);
  if (!verifyPairingToken(auth.devId, auth.token)) {
    database.audit("device.auth_failed", { devId: auth.devId });
    return c.json({ error: "invalid device credentials" }, 401);
  }
  touchDevice(auth.devId);
  return { devId: auth.devId };
}

// ---------------------------------------------------------------------------
// Event handling
// ---------------------------------------------------------------------------

type ButtonCode = "AGENT_REQUEST" | "NOTE" | "REPLY" | "SINGLE" | "DOUBLE" | "LONG";

interface DeviceEventBody {
  kind: "button" | "heartbeat";
  code?: ButtonCode;
  at?: number;
}

const KNOWN_BUTTON_CODES: ReadonlySet<ButtonCode> = new Set<ButtonCode>(["AGENT_REQUEST", "NOTE", "REPLY", "SINGLE", "DOUBLE", "LONG"]);

function validateEventBody(raw: unknown): DeviceEventBody | string {
  if (!raw || typeof raw !== "object") return "body must be an object";
  const r = raw as Record<string, unknown>;
  if (r.kind !== "button" && r.kind !== "heartbeat") return 'kind must be "button" or "heartbeat"';
  if (r.kind === "button") {
    if (typeof r.code !== "string" || !KNOWN_BUTTON_CODES.has(r.code as ButtonCode)) {
      return `button code must be one of: ${[...KNOWN_BUTTON_CODES].join(", ")}`;
    }
    return { kind: "button", code: r.code as ButtonCode, at: typeof r.at === "number" ? r.at : Date.now() };
  }
  return { kind: "heartbeat", at: typeof r.at === "number" ? r.at : Date.now() };
}

// ---------------------------------------------------------------------------
// Route mount
// ---------------------------------------------------------------------------

export interface MountDeviceChannelOpts {
  /** Hono app from src/dashboard.ts. Routes are added under /api/device/*. */
  app: Hono;
  /** Middleware guarding operator-only routes (dashboard bearer). Provided by
   *  the caller (dashboard.ts) so this module doesn't duplicate auth logic. */
  requireWriteAuth: (c: Context, next: () => Promise<void>) => Promise<void | Response>;
}

export function mountDeviceChannel(opts: MountDeviceChannelOpts): void {
  const { app, requireWriteAuth } = opts;

  // --- device-facing: POST /api/device/event (pairing-token auth) ----------
  app.post("/api/device/event", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    const devId = auth.devId;

    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "invalid JSON" }, 400);
    }
    const parsed = validateEventBody(body);
    if (typeof parsed === "string") return c.json({ error: parsed }, 400);

    const dev = getDevice(devId);
    if (!dev) return c.json({ error: "device not found after auth" }, 500);

    const receivedAt = Date.now();
    if (parsed.kind === "heartbeat") {
      // touchDevice already ran in requireDeviceAuth — just ack.
      return c.json({ ok: true, at: parsed.at });
    }

    // Button event. Emit to Inngest for any downstream step fn (device-prompt
    // triggers on AGENT_REQUEST/NOTE/REPLY; other codes flow into the conversation
    // transcript as annotation events in future phases).
    // Also poke the WS-audio overheard detector: a recent intent button
    // prevents the next final transcript from being classified as overheard.
    if (parsed.code === "AGENT_REQUEST" || parsed.code === "NOTE" || parsed.code === "REPLY") {
      markAgentRequestAt(devId, receivedAt);
    }
    await inngest.send({
      name: "wearable/device.button",
      data: {
        devId,
        chatId: dev.chat_id ?? chatIdFor(devId),
        businessId: dev.business_id,
        code: parsed.code as ButtonCode,
        at: receivedAt,
      },
    });
    database.audit("device.button", { devId, code: parsed.code }, dev.chat_id ?? undefined, dev.business_id);
    return c.json({ ok: true });
  });

  // --- device-facing: POST /api/device/text (on-device STT path) -----------
  // The phone transcribes wearable/mic audio LOCALLY (Gemma 4 on-device) and
  // pushes the cleaned transcript here instead of streaming raw audio to the
  // WS for server-side Deepgram. Same security posture as the audio path:
  // pairing-token auth here, and the @role: prefix is stripped downstream in
  // deviceTextPrompt (S-3). Returns the chatId so the app knows which SSE
  // stream to subscribe for the agent's textual reply.
  // bodyLimit guards memory before c.req.json() buffers the payload. 8 KB
  // comfortably holds a 4000-char text field (worst-case UTF-8) + JSON framing.
  app.post("/api/device/text", bodyLimit({ maxSize: 8_192 }) as never, async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    const devId = auth.devId;

    // Per-device rate limit: a paired-but-misbehaving device must not inject
    // Inngest events / agent turns at wire speed. ~10 burst, then 1 per 6 s.
    if (!takeToken(`device:text:${devId}`, { capacity: 10, refillPerSec: 1 / 6 })) {
      database.audit("device.text_rate_limited", { devId });
      return c.json({ error: "rate limited" }, 429);
    }

    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "invalid JSON" }, 400);
    }
    const parsed = validateDeviceTextBody(body);
    if (typeof parsed === "string") return c.json({ error: parsed }, 400);

    const dev = getDevice(devId);
    if (!dev) return c.json({ error: "device not found after auth" }, 500);

    // [security] The client may force ambient, but never force explicit. An
    // explicit on-device capture is preceded by an intent button event (POST
    // /api/device/event → markAgentRequestAt). No recent press, or an explicit
    // ambient client flag from SD/phone-mic capture, stays overheard.
    const lastPress = lastAgentRequestAt(devId);
    const overheard = deriveDeviceTextOverheard({
      clientOverheard: parsed.overheard,
      lastIntentAt: lastPress,
      now: Date.now(),
      explicitGraceMs: DEVICE_TEXT_EXPLICIT_GRACE_MS,
    });

    const chatId = dev.chat_id ?? chatIdFor(devId);
    await inngest.send({
      name: "wearable/device.text.final",
      data: {
        devId,
        chatId,
        businessId: dev.business_id,
        sessionId: randomUUID(),
        text: parsed.text,
        overheard,
        capturedAt: parsed.at,
      },
    });
    database.audit("device.text", { devId, overheard }, chatId, dev.business_id);
    return c.json({ ok: true, chatId });
  });

  // --- device-facing: POST /api/device/command/poll ------------------------
  app.post("/api/device/command/poll", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    const cmds = drainQueue(auth.devId);
    return c.json({ commands: cmds });
  });

  // --- device-facing: POST /api/device/voice-profile/train -----------------
  // Operator (Kelvin) trains a voice profile by recording a short clip and
  // posting the derived speaker embedding. For v1 embedding is optional;
  // enrollment still records the name and owner flag so the label + rename
  // UI works end-to-end.
  app.post("/api/device/voice-profile/train", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    let body: unknown;
    try { body = await c.req.json(); } catch { return c.json({ error: "invalid JSON" }, 400); }
    if (!body || typeof body !== "object") return c.json({ error: "body must be an object" }, 400);
    const b = body as Record<string, unknown>;
    if (typeof b.name !== "string" || b.name.length === 0) {
      return c.json({ error: "name required" }, 400);
    }
    const speakerId = typeof b.speakerId === "string" ? b.speakerId : undefined;
    const isOwner = b.isOwner === true;
    let embedding: Uint8Array | null = null;
    if (typeof b.embeddingB64 === "string" && b.embeddingB64.length > 0) {
      try {
        embedding = Uint8Array.from(Buffer.from(b.embeddingB64, "base64"));
      } catch {
        return c.json({ error: "embeddingB64 is not valid base64" }, 400);
      }
    }
    const profile = enrollProfile({
      devId: auth.devId,
      speakerId,
      name: b.name,
      isOwner,
      embedding,
    });
    return c.json({ ok: true, profile });
  });

  // --- device-facing: GET /api/device/voice-profiles -----------------------
  app.get("/api/device/voice-profiles", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    return c.json({ profiles: listProfiles(auth.devId) });
  });

  // --- operator: PATCH /api/device/voice-profiles/:id (rename / set owner) -
  app.patch("/api/device/voice-profiles/:id", requireWriteAuth as never, async (c) => {
    const idRaw = c.req.param("id");
    const id = Number(idRaw);
    if (!Number.isFinite(id)) return c.json({ error: "bad id" }, 400);
    let body: unknown;
    try { body = await c.req.json(); } catch { return c.json({ error: "invalid JSON" }, 400); }
    if (!body || typeof body !== "object") return c.json({ error: "body must be an object" }, 400);
    const b = body as Record<string, unknown>;
    try {
      let profile;
      if (typeof b.name === "string") profile = renameProfile(id, b.name);
      if (b.isOwner === true) profile = markOwner(id);
      if (!profile) return c.json({ error: "no-op: pass name or isOwner:true" }, 400);
      return c.json({ ok: true, profile });
    } catch (err) {
      return c.json({ error: String((err as Error).message ?? err) }, 400);
    }
  });

  // --- operator: DELETE /api/device/voice-profiles/:id ---------------------
  app.delete("/api/device/voice-profiles/:id", requireWriteAuth as never, async (c) => {
    const id = Number(c.req.param("id"));
    if (!Number.isFinite(id)) return c.json({ error: "bad id" }, 400);
    deleteProfile(id);
    return c.json({ ok: true });
  });

  // --- operator: GET /api/device/list --------------------------------------
  app.get("/api/device/list", (c) => {
    const businessId = c.req.query("businessId");
    const rows = listDevices(businessId);
    // Never leak the token hash externally — hash column is internal.
    const safe = rows.map((r) => ({
      devId: r.dev_id,
      businessId: r.business_id,
      chatId: r.chat_id,
      label: r.label,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at,
    }));
    return c.json({ devices: safe });
  });

  // --- operator: POST /api/device/register ---------------------------------
  app.post("/api/device/register", requireWriteAuth as never, async (c) => {
    let body: unknown;
    try { body = await c.req.json(); } catch { return c.json({ error: "invalid JSON" }, 400); }
    if (!body || typeof body !== "object") return c.json({ error: "body must be an object" }, 400);
    const b = body as Record<string, unknown>;
    if (typeof b.devId !== "string") return c.json({ error: "devId required" }, 400);
    const businessId = typeof b.businessId === "string" ? b.businessId : DEFAULT_BUSINESS_ID;
    const label = typeof b.label === "string" ? b.label : undefined;
    try {
      const result = createDevice({ devId: b.devId, label, businessId });
      // Return the plaintext pairing token exactly once; the operator copies
      // it into the app's pairing flow. After this response the server only
      // has the hash.
      return c.json({
        ok: true,
        device: {
          devId: result.device.dev_id,
          businessId: result.device.business_id,
          chatId: result.device.chat_id,
          label: result.device.label,
        },
        pairingToken: result.pairingToken,
      });
    } catch (err) {
      return c.json({ error: String((err as Error).message ?? err) }, 400);
    }
  });

  // --- operator: POST /api/device/:devId/bind (rebind business) ------------
  app.post("/api/device/:devId/bind", requireWriteAuth as never, async (c) => {
    const devId = c.req.param("devId");
    let body: unknown;
    try { body = await c.req.json(); } catch { return c.json({ error: "invalid JSON" }, 400); }
    if (!body || typeof body !== "object") return c.json({ error: "body must be an object" }, 400);
    const b = body as Record<string, unknown>;
    if (typeof b.businessId !== "string") return c.json({ error: "businessId required" }, 400);
    try {
      setDeviceBusiness(devId, b.businessId);
      return c.json({ ok: true });
    } catch (err) {
      return c.json({ error: String((err as Error).message ?? err) }, 400);
    }
  });

  // --- operator: DELETE /api/device/:devId ---------------------------------
  app.delete("/api/device/:devId", requireWriteAuth as never, async (c) => {
    deleteDevice(c.req.param("devId"));
    return c.json({ ok: true });
  });

  // --- device-facing: POST /api/device/hands-free (S-4) -------------------
  app.post("/api/device/hands-free", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    if (!env.WEARABLE_HANDS_FREE_ALLOWED) {
      return c.json({ error: "hands-free mode disabled at server level" }, 403);
    }
    let body: unknown;
    try { body = await c.req.json(); } catch { return c.json({ error: "invalid JSON" }, 400); }
    if (!body || typeof body !== "object") return c.json({ error: "body must be an object" }, 400);
    const b = body as Record<string, unknown>;
    if (typeof b.enabled !== "boolean") return c.json({ error: "enabled:boolean required" }, 400);
    // Guard: enabling hands-free without an enrolled owner profile leaves the
    // diarisation filter with nothing to match — all utterances drop. Reject
    // explicitly so the app can prompt the user to enroll first.
    if (b.enabled && !hasOwnerProfile(auth.devId).has_profile) {
      return c.json({ error: "enroll an owner voice profile before enabling hands-free" }, 409);
    }
    setHandsFreeMode(auth.devId, b.enabled);
    // Propagate to any live WS stream so the per-frame gate picks up the
    // new policy immediately (prevents stale-snapshot correctness bug).
    refreshHandsFreeMode(auth.devId, b.enabled);
    return c.json({ ok: true, handsFreeMode: b.enabled });
  });

  // --- device-facing: GET /api/device/hands-free (S-4) --------------------
  app.get("/api/device/hands-free", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    return c.json({
      handsFreeMode: getHandsFreeMode(auth.devId),
      allowed: env.WEARABLE_HANDS_FREE_ALLOWED,
    });
  });

  // --- KelvinLee-compat: GET /api/v3/speech-profile (S-4) -----------------------
  // Mirrors the shape of KelvinLee cloud's v3/speech-profile so the existing
  // speech_profile.dart code works against Wearable when apiBaseUrl is pointed
  // at the Wearable server (M-5). Returns `{has_profile: boolean}`.
  app.get("/api/v3/speech-profile", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    return c.json(hasOwnerProfile(auth.devId));
  });

  // --- KelvinLee-compat: POST /api/v3/upload-audio (S-4) ------------------------
  // Multipart upload of a WAV voice sample. Stored per-device under
  // <WEARABLE_HOME>/store/voice-samples/<devId>/<ulid>.wav. First upload creates
  // the owner voice_profiles row.
  app.post("/api/v3/upload-audio", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    // Pre-check Content-Length BEFORE parseBody() buffers the whole upload
    // in memory. Any pairing-token holder must not be able to exhaust the
    // process heap with a 1 GB multipart POST.
    const contentLength = Number(c.req.header("content-length") ?? 0);
    if (!Number.isFinite(contentLength) || contentLength <= 0) {
      return c.json({ error: "content-length required" }, 411);
    }
    // Leave a small envelope for multipart framing overhead on top of the
    // actual WAV size cap. 512 KB slack is generous.
    const MAX_UPLOAD_BYTES = 10 * 1024 * 1024 + 512 * 1024;
    if (contentLength > MAX_UPLOAD_BYTES) {
      return c.json({ error: "upload too large" }, 413);
    }
    let form: Awaited<ReturnType<typeof c.req.parseBody>>;
    try {
      form = await c.req.parseBody();
    } catch {
      return c.json({ error: "multipart parse failed" }, 400);
    }
    const file = form.file;
    if (!(file instanceof File)) {
      return c.json({ error: "file field required (multipart/form-data, field 'file')" }, 400);
    }
    const bytes = new Uint8Array(await file.arrayBuffer());
    const result = storeWavSample(auth.devId, bytes);
    if (!result.ok) {
      return c.json({ error: `upload rejected: ${result.reason}` }, result.reason === "too_large" ? 413 : 400);
    }
    return c.json({
      ok: true,
      profileId: result.profileId,
      bytes: result.bytes,
      createdOwner: result.createdOwner,
    });
  });

  // --- KelvinLee-compat: GET /api/v4/speech-profile (S-4) -----------------------
  // KelvinLee clients call this to fetch a URL for the stored profile (playback /
  // re-training UX). Wearable returns a RELATIVE URL that points at the device-
  // authenticated download route below — never the raw filesystem path (that
  // would leak WEARABLE_HOME layout and the per-device directory name). Returns
  // null when no sample exists yet so the app can render "no profile to
  // re-play" without erroring.
  app.get("/api/v4/speech-profile", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    const sample = latestSamplePath(auth.devId);
    if (!sample) return c.json({ url: null });
    // URL the app can GET back through this server (with device auth). The
    // download route verifies the caller and streams the latest sample.
    return c.json({ url: "/api/device/voice-sample/latest" });
  });

  // --- device-facing: GET /api/device/voice-sample/latest -----------------
  // Streams the most recent enrolment WAV back to an authenticated caller.
  // Auth is the same pairing token as other device routes; the file is
  // resolved server-side from latestSamplePath so the caller never sees an
  // OS path. Rejects if no sample exists.
  app.get("/api/device/voice-sample/latest", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    const samplePath = latestSamplePath(auth.devId);
    if (!samplePath) return c.json({ error: "no voice sample" }, 404);
    // Read the file off disk. Sample files are chmod 600 and sized-capped by
    // the upload handler, so a full read is bounded.
    let bytes: Uint8Array<ArrayBuffer>;
    try {
      const nodeFs = await import("node:fs");
      const buf = nodeFs.readFileSync(samplePath);
      // Copy into a fresh ArrayBuffer so the type system is satisfied —
      // Node's Buffer may sit on ArrayBufferLike (incl. SharedArrayBuffer)
      // which Hono's BodyInit does not accept.
      const ab = new ArrayBuffer(buf.byteLength);
      bytes = new Uint8Array(ab);
      bytes.set(buf);
    } catch {
      return c.json({ error: "sample unavailable" }, 500);
    }
    return c.body(bytes, 200, {
      "Content-Type": "audio/wav",
      "Cache-Control": "private, max-age=0",
    });
  });

  // --- KelvinLee-compat: GET/DELETE /api/v3/speech-profile/expand (stubs) -------
  // The KelvinLee "expanded samples" feature (additional enrollment clips) is not
  // part of Phase 1. Return an empty list and accept deletions as no-ops so
  // the existing app flow doesn't error when it queries these endpoints.
  app.get("/api/v3/speech-profile/expand", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    return c.json([]);
  });
  app.delete("/api/v3/speech-profile/expand", async (c) => {
    const auth = await requireDeviceAuth(c);
    if (auth instanceof Response) return auth;
    return c.json({ ok: true });
  });

  logger.info("device channel routes mounted under /api/device/* and /api/v3|v4/*");
}
