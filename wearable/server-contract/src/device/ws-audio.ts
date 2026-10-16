/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Device audio WebSocket — final piece of the device channel (plan §1.1).
 *
 * Endpoint: GET /api/device/ws/audio?devId=<id>&token=<pairing_token>
 *   - HTTP Upgrade-only. Other methods fall through to the Hono HTTP layer.
 *   - Auth via verifyPairingToken (constant-time compare) — same primitive
 *     as the HTTP device routes.
 *   - Binary frames in: Opus packets from the firmware (via the phone-app BLE
 *     bridge) or 16 kHz PCM from the phone mic.
 *   - Text frames in: control JSON like {"kind":"mark","code":"AGENT_REQUEST"}.
 *   - Out: nothing on the WS itself. Transcripts fan out as Inngest
 *     wearable/device.audio.final events so the rest of the harness can react.
 *
 * Overheard detection: keeps an in-memory `recentButtonPressAt` per devId.
 * When a final transcript arrives, if there's been no AGENT_REQUEST (or D5
 * LONG/TRIPLE — see device-prompt.ts contract) within OVERHEARD_WINDOW_MS,
 * mark the transcript as overheard. The channel.ts button handler pokes
 * this map from the existing /api/device/event path.
 */
import type { Server as HttpServer } from "node:http";
import type { Server as HttpsServer } from "node:https";
import type { IncomingMessage } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocketServer, type WebSocket } from "ws";
import { inngest } from "../inngest/client.js";
import { database, DEFAULT_BUSINESS_ID } from "../../db.js";
import { logger } from "../../logger.js";
import { takeToken } from "../../rate-limit.js";
import { chatIdFor, getDevice, getHandsFreeMode, touchDevice, verifyPairingToken } from "./registry.js";
import { openSttStream, type Utterance } from "./stt.js";
import { createOpusPcmDecoder, type PcmDecoder } from "./opus-decoder.js";
import { env } from "../../env.js";
import { shouldProcessAudioFrame, extendCaptureWindow } from "./capture-gate.js";

// Public: channel.ts notifies us when a button event arrives so we can flip
// the overheard flag off for the next final transcript.
const OVERHEARD_WINDOW_MS = 10_000;
const recentButtonPress = new Map<string, number>();

/** S-4: button press opens an WEARABLE_CAPTURE_WINDOW_MS window on the stream
 *  state; frames outside the window are dropped before they reach Deepgram.
 *  Per-device map so out-of-band presses (/api/device/event) can open the
 *  window even when no WS is currently connected — the next connect picks
 *  up the deadline. */
const captureWindowUntil = new Map<string, number>();

/** Per-devId last-press wall-clock. Used to rate-limit button presses from
 *  WS control frames (the HTTP /api/device/event path is rate-limited by
 *  the per-request middleware). Without this, a compromised device could
 *  send {"kind":"mark","code":"AGENT_REQUEST"} at wire speed and keep the
 *  capture window open indefinitely. */
const lastMarkAt = new Map<string, number>();
/** Minimum interval between accepted button presses. Well below the window
 *  length so a user tapping twice in quick succession still wins, but
 *  enough that a flood can't keep the window alive. */
const MIN_MARK_INTERVAL_MS = 1_000;

export function markAgentRequestAt(devId: string, atMs: number = Date.now()): void {
  const prevMark = lastMarkAt.get(devId) ?? 0;
  if (atMs - prevMark < MIN_MARK_INTERVAL_MS) {
    // Drop silently — audit the reject so floods show up in observability.
    database.audit("device.capture_window_rate_limited", {
      devId,
      atMs,
      prevMark,
      intervalMs: atMs - prevMark,
    });
    return;
  }
  lastMarkAt.set(devId, atMs);
  recentButtonPress.set(devId, atMs);
  // Window-monotonic: a late-arriving or clock-skewed press MUST NOT shrink
  // a live window. Always take the later of existing-deadline and new-press
  // window so only a forward-moving deadline ever wins.
  const newDeadline = extendCaptureWindow(atMs, env.WEARABLE_CAPTURE_WINDOW_MS);
  const existing = captureWindowUntil.get(devId) ?? 0;
  const deadline = Math.max(existing, newDeadline);
  captureWindowUntil.set(devId, deadline);
  // Mirror onto the active stream so the per-frame gate uses the same value.
  const stream = activeStreams.get(devId);
  if (stream) stream.captureWindowUntil = deadline;
  database.audit("device.capture_window_open", {
    devId,
    windowMs: env.WEARABLE_CAPTURE_WINDOW_MS,
    deadline,
  });
}

/** Wall-clock ms of the most recent AGENT_REQUEST for a device (or undefined).
 *  The on-device-STT text path (POST /api/device/text) reads this to derive the
 *  overheard flag SERVER-SIDE rather than trusting a client-supplied value —
 *  mirroring the audio path's authority (the device still sends the button event
 *  via /api/device/event, which records the press here). */
export function lastAgentRequestAt(devId: string): number | undefined {
  return recentButtonPress.get(devId);
}

/** S-4: HTTP `POST /api/device/hands-free` calls this so the active WS
 *  stream picks up the new flag immediately — otherwise the StreamState
 *  snapshot from connect-time persists until the next reconnect and the
 *  gate runs on stale policy. */
export function refreshHandsFreeMode(devId: string, enabled: boolean): void {
  const stream = activeStreams.get(devId);
  if (stream) stream.handsFreeMode = enabled;
}

interface StreamState {
  ws: WebSocket;
  devId: string;
  chatId: string;
  businessId: string;
  /** New sessionId per WS connection. Flows end-to-end through audio.final
   *  → agent.prompt → agent.result → conversation-log's captureBuffer so
   *  utterances attach to the exact turn they belong to, not just any turn
   *  on the same chatId. (Fixes TS-H3 cross-turn contamination.) */
  sessionId: string;
  openedAt: number;
  closed: boolean;
  sttClose: () => void;
  sttSend: (frame: Uint8Array | ArrayBuffer) => boolean;
  pendingFrame?: Uint8Array;
  decoder?: PcmDecoder;
  /** S-4 capture-window deadline (epoch ms). When undefined or in the past,
   *  binary frames are dropped unless handsFreeMode is on. */
  captureWindowUntil?: number;
  /** S-4 per-device hands-free flag snapshot; re-read from registry on each
   *  WS connection. */
  handsFreeMode: boolean;
  /** S-4 drop counter for throttled "audio_dropped" audit logging. */
  dropCount: number;
  dropBytes: number;
  lastDropAuditAt: number;
}

const activeStreams = new Map<string, StreamState>();   // keyed by devId

// ---------------------------------------------------------------------------
// Auth + URL parsing
// ---------------------------------------------------------------------------

/** Extract the pairing token from a Sec-WebSocket-Protocol header of the
 *  form `wearable-token, <token>` (mirrors Deepgram's own auth pattern). The
 *  ?token= URL query is no longer accepted — query-string tokens leak into
 *  access logs (Caddy / journald / kernel audit / browser history / Referer).
 *  parseWsRequest detects the query form and hard-rejects with code 1008. */
function extractToken(req: IncomingMessage): string | null {
  const protoHeader = req.headers["sec-websocket-protocol"];
  if (typeof protoHeader === "string") {
    const parts = protoHeader.split(",").map((s) => s.trim()).filter(Boolean);
    const idx = parts.indexOf("wearable-token");
    if (idx >= 0 && idx + 1 < parts.length) {
      return parts[idx + 1];
    }
  }
  return null;
}

type WsParseResult =
  | { ok: true; devId: string; token: string; encoding: "opus" | "linear16"; sampleRate: number; frameMs: number }
  | { ok: false; reason: "bad_url" | "bad_path" | "query_token_forbidden" | "missing_devId" | "missing_token" };

function parseWsRequest(req: IncomingMessage): WsParseResult {
  if (!req.url) return { ok: false, reason: "bad_url" };
  let parsed: URL;
  try { parsed = new URL(req.url, "http://wearable"); } catch { return { ok: false, reason: "bad_url" }; }
  if (parsed.pathname !== "/api/device/ws/audio") return { ok: false, reason: "bad_path" };
  // [security] Hard-reject any URL that carries a `token` query parameter.
  // Query tokens land in HTTP access logs (Caddy / journald / kernel audit)
  // and browser history. The only accepted auth path is the
  // Sec-WebSocket-Protocol subprotocol.
  if (parsed.searchParams.has("token")) {
    return { ok: false, reason: "query_token_forbidden" };
  }
  const devId = parsed.searchParams.get("devId");
  if (!devId) return { ok: false, reason: "missing_devId" };
  const token = extractToken(req);
  if (!token) return { ok: false, reason: "missing_token" };
  const encParam = parsed.searchParams.get("encoding");
  const encoding = encParam === "linear16" ? "linear16" : "opus";
  const sampleRate = Number.parseInt(parsed.searchParams.get("sampleRate") ?? "16000", 10);
  // frameMs reflects firmware Opus packetization: 10ms (CODEC_ID=20) or 20ms
  // (CODEC_ID=21 aka opus_fs320). libopus auto-detects from TOC; we keep the
  // value for logging + future non-auto-detecting decoders.
  const frameMs = Number.parseInt(parsed.searchParams.get("frameMs") ?? "10", 10);
  return {
    ok: true,
    devId,
    token,
    encoding,
    sampleRate: Number.isFinite(sampleRate) ? sampleRate : 16000,
    frameMs: Number.isFinite(frameMs) ? frameMs : 10,
  };
}

// ---------------------------------------------------------------------------
// Per-connection lifecycle
// ---------------------------------------------------------------------------

async function emitAudioFinal(state: StreamState, utterances: Utterance[]): Promise<void> {
  if (utterances.length === 0) return;
  // S-4 hands-free owner filter. If hands-free is on, drop utterances whose
  // diarised speaker is not the enrolled owner before they hit the
  // orchestrator. The transcript echo to the client WS already happened in
  // the onUtterance handler so the app can render "(dropped, overheard)"
  // for UX honesty — but nothing leaves the device boundary for non-owner
  // speech. Button-window-driven captures bypass this filter: the user
  // explicitly opened the window so everything spoken inside it is intentional.
  const now = Date.now();
  const inWindow = (state.captureWindowUntil ?? 0) > now;
  const filtered = (state.handsFreeMode && env.WEARABLE_HANDS_FREE_ALLOWED && !inWindow)
    ? utterances.filter((u) => u.isOwner)
    : utterances;
  if (filtered.length === 0) {
    database.audit(
      "device.audio_dropped",
      { devId: state.devId, reason: "hands_free_non_owner", count: utterances.length },
      state.chatId,
      state.businessId,
    );
    return;
  }
  const transcript = filtered
    .map((u) => `${u.isOwner ? `${u.speakerLabel} (owner)` : u.speakerLabel}: ${u.text.trim()}`)
    .join("\n");
  const lastPress = recentButtonPress.get(state.devId) ?? 0;
  const overheard = Date.now() - lastPress > OVERHEARD_WINDOW_MS;

  await inngest.send({
    name: "wearable/device.audio.final",
    data: {
      devId: state.devId,
      chatId: state.chatId,
      businessId: state.businessId,
      sessionId: state.sessionId,
      transcript,
      utterances: filtered.map((u) => ({
        speakerId: u.speakerId,
        speakerLabel: u.speakerLabel,
        isOwner: u.isOwner,
        text: u.text,
        startMs: u.startMs,
        endMs: u.endMs,
      })),
      overheard,
      capturedAt: Date.now(),
    },
  });
  database.audit("device.audio.final", { devId: state.devId, overheard, n: filtered.length, handsFree: state.handsFreeMode }, state.chatId, state.businessId);
}

async function handleConnection(ws: WebSocket, req: IncomingMessage): Promise<void> {
  const parsed = parseWsRequest(req);
  if (!parsed.ok) {
    if (parsed.reason === "query_token_forbidden") {
      // [security] Query-string tokens leak into access logs / browser history.
      // We log + audit ONLY the path so the rejected token doesn't survive in
      // pino / journald / SQLite — defeats the purpose of the rejection
      // otherwise. Code 1008 = policy violation.
      const safePath = (() => {
        try {
          return req.url ? new URL(req.url, "http://wearable").pathname : null;
        } catch {
          return null;
        }
      })();
      logger.warn({ path: safePath }, "device ws: ?token= query rejected — must use Sec-WebSocket-Protocol");
      database.audit("device.ws.query_token_rejected", { path: safePath });
      ws.close(1008, "token must be sent via Sec-WebSocket-Protocol, not query");
      return;
    }
    ws.close(1008, "bad request");
    return;
  }
  if (!verifyPairingToken(parsed.devId, parsed.token)) {
    database.audit("device.ws.auth_failed", { devId: parsed.devId });
    ws.close(1008, "auth failed");
    return;
  }
  touchDevice(parsed.devId);
  const dev = getDevice(parsed.devId);
  if (!dev) {
    ws.close(1011, "device gone");
    return;
  }
  const chatId = dev.chat_id ?? chatIdFor(parsed.devId);
  const businessId = dev.business_id ?? DEFAULT_BUSINESS_ID;

  // One stream per device — dropping older connections is safer than
  // multiplexing mismatched audio against a stale STT session.
  const existing = activeStreams.get(parsed.devId);
  if (existing) {
    try { existing.ws.close(1000, "superseded"); } catch { /* ignore */ }
    try { existing.sttClose(); } catch { /* ignore */ }
    activeStreams.delete(parsed.devId);
  }

  const state: StreamState = {
    ws,
    devId: parsed.devId,
    chatId,
    businessId,
    sessionId: randomUUID(),
    openedAt: Date.now(),
    closed: false,
    sttClose: () => { /* replaced once STT opens */ },
    sttSend: () => false,
    // S-4: seed the gate state. captureWindowUntil carries over from any
    // recent button press that happened while no WS was connected.
    captureWindowUntil: captureWindowUntil.get(parsed.devId),
    handsFreeMode: getHandsFreeMode(parsed.devId),
    dropCount: 0,
    dropBytes: 0,
    lastDropAuditAt: 0,
  };
  activeStreams.set(parsed.devId, state);

  // Spin up an Opus decoder per connection if the client streams Opus.
  // Linear16 input is passed straight to Deepgram unchanged.
  if (parsed.encoding === "opus") {
    try {
      state.decoder = createOpusPcmDecoder(parsed.sampleRate, parsed.frameMs);
      logger.info({ devId: parsed.devId, sampleRate: parsed.sampleRate, frameMs: parsed.frameMs }, "opus decoder ready");
    } catch (err) {
      logger.error({ err, devId: parsed.devId }, "opus decoder init failed");
      ws.close(1011, "opus decoder unavailable");
      activeStreams.delete(parsed.devId);
      return;
    }
  }

  let sttStream: { close: () => void; send: (frame: Uint8Array | ArrayBuffer) => boolean } | null = null;
  try {
    // We decode Opus to PCM16 server-side so Deepgram always sees linear16.
    // Deepgram's encoding=opus expects WebM/OGG-containerized Opus, not the
    // raw Opus frames the KelvinLee firmware emits.
    sttStream = openSttStream({
      devId: parsed.devId,
      encoding: parsed.encoding === "opus" ? "linear16" : parsed.encoding,
      sampleRate: parsed.sampleRate,
      handlers: {
        onUtterance: (u) => {
          // Echo every utterance (interim + final) back on the client WS so
          // the app can render live partial text + finalized segments without
          // a separate subscription. Frontier Phase 10 wiring: the Flutter
          // WearableDeviceBridge parses these JSON text frames and feeds them
          // into the KelvinLee CaptureProvider's segment stream.
          try {
            if (ws.readyState === ws.OPEN) {
              ws.send(JSON.stringify({
                type: "transcript",
                utterance: {
                  text: u.text,
                  speakerId: u.speakerId,
                  speakerLabel: u.speakerLabel,
                  isOwner: u.isOwner,
                  isFinal: u.isFinal,
                  startMs: u.startMs,
                  endMs: u.endMs,
                },
              }));
            } else {
              logger.warn({ devId: state.devId, readyState: ws.readyState }, "transcript echo skipped: ws not open");
            }
          } catch (err) {
            logger.warn({ err, devId: state.devId }, "transcript echo failed");
          }
          // Emit one audio.final per Deepgram final for the Inngest dispatch
          // chain. Silence-window aggregation is a v2 refinement — device-
          // prompt already serialises per-devId so back-to-back finals queue.
          if (!u.isFinal) return;
          emitAudioFinal(state, [u]).catch((err) => {
            logger.warn({ err, devId: state.devId }, "emit audio.final failed");
          });
        },
        onError: (err) => {
          logger.warn({ err, devId: state.devId }, "stt error");
        },
        onClose: (code, reason) => {
          logger.info({ devId: state.devId, code, reason }, "stt stream closed");
        },
      },
    });
    state.sttClose = () => sttStream?.close();
    state.sttSend = (frame) => sttStream?.send(frame) ?? false;
  } catch (err) {
    logger.error({ err, devId: parsed.devId }, "failed to open stt stream");
    ws.close(1011, "stt unavailable");
    activeStreams.delete(parsed.devId);
    return;
  }

  ws.on("message", (data, isBinary) => {
    if (state.closed) return;
    if (isBinary) {
      const frame = data instanceof Buffer ? new Uint8Array(data) : (Array.isArray(data) ? Buffer.concat(data) : data as ArrayBuffer);
      // Client strips KelvinLee 3-byte BLE header (capture_provider.dart:358 or
      // WearableDeviceBridge). Each binary frame is a complete Opus packet.
      const opusFrame = frame instanceof Uint8Array ? frame : new Uint8Array(frame);
      if (opusFrame.length === 0) return;
      // RFC 6716 §3.4: Opus packets are ≤ 1275 bytes. Anything larger is
      // malformed and should not reach libopus. Drop-and-log caps pathological
      // decode time + closes an oversized-input attack surface.
      if (opusFrame.length > 1275) {
        logger.warn({ devId: state.devId, len: opusFrame.length }, "oversized opus frame dropped");
        return;
      }
      // S-4 privacy gate: before any decode/transcription, check whether the
      // capture window is open (recent button press) or the device is in
      // hands-free mode (and hands-free is allowed server-wide). Frames
      // rejected here never reach Deepgram — the whole point of the gate.
      const decision = shouldProcessAudioFrame({
        now: Date.now(),
        captureWindowUntil: state.captureWindowUntil,
        handsFreeMode: state.handsFreeMode,
        handsFreeAllowed: env.WEARABLE_HANDS_FREE_ALLOWED,
      });
      if (!decision.admit) {
        state.dropCount += 1;
        state.dropBytes += opusFrame.length;
        // Throttle audit writes: flush every 1000 drops or every 10s,
        // whichever comes first. Keeps the audit log useful without
        // flooding during a long no-window period.
        const nowMs = Date.now();
        if (state.dropCount >= 1000 || nowMs - state.lastDropAuditAt > 10_000) {
          database.audit(
            "device.audio_dropped",
            { devId: state.devId, reason: decision.reason, count: state.dropCount, bytes: state.dropBytes },
            state.chatId,
            state.businessId,
          );
          state.dropCount = 0;
          state.dropBytes = 0;
          state.lastDropAuditAt = nowMs;
        }
        return;
      }
      if (state.decoder) {
        try {
          const pcm = state.decoder.decode(opusFrame);
          if (pcm.length > 0) state.sttSend(pcm);
        } catch (err) {
          logger.warn({ err, devId: state.devId, len: opusFrame.length }, "opus decode failed");
        }
      } else {
        state.sttSend(opusFrame);
      }
      return;
    }
    // Text frames: control messages.
    try {
      const msg = JSON.parse(data.toString()) as { kind?: string; code?: string };
      if (msg.kind === "mark" && msg.code === "AGENT_REQUEST") {
        markAgentRequestAt(state.devId);
      }
    } catch {
      // ignore malformed control frames
    }
  });

  ws.on("close", () => {
    if (state.closed) return;
    state.closed = true;
    try { state.sttClose(); } catch { /* ignore */ }
    try { state.decoder?.close(); } catch { /* ignore */ }
    // Only clear our own entry — if a newer WS has already superseded us,
    // its entry must not be deleted by this stale closer. (TS C3)
    if (activeStreams.get(state.devId) === state) {
      activeStreams.delete(state.devId);
    }
    logger.info({ devId: state.devId, durMs: Date.now() - state.openedAt }, "device ws closed");
  });

  ws.on("error", (err) => {
    logger.warn({ err, devId: state.devId }, "device ws error");
  });

  logger.info({ devId: state.devId, encoding: parsed.encoding, sampleRate: parsed.sampleRate }, "device ws opened");
}

// ---------------------------------------------------------------------------
// Public: attach to the running http(s) server
// ---------------------------------------------------------------------------

export interface AttachWsAudioOpts {
  server: HttpServer | HttpsServer;
}

export function attachDeviceAudioWebSocket(opts: AttachWsAudioOpts): WebSocketServer {
  const wss = new WebSocketServer({
    noServer: true,
    perMessageDeflate: false,
    // Echo "wearable-token" back when the client offers it so the handshake
    // completes. The actual token value is adjacent in the protocols list
    // (Deepgram's pattern) but only the marker "wearable-token" is echoed —
    // never echo the token itself in the response protocol header, or it
    // lands in access logs.
    handleProtocols: (protocols) => {
      return protocols.has("wearable-token") ? "wearable-token" : false;
    },
  });
  opts.server.on("upgrade", (req, socket, head) => {
    // Only handle our path; other upgrades (if any) bubble up unhandled.
    if (!req.url || !req.url.startsWith("/api/device/ws/audio")) return;

    // Per-IP rate limit on WS upgrades — Hono middleware doesn't see this
    // code path (upgrade is node:http direct), so without a bucket here a
    // LAN attacker can brute-force devId / token permutations at wire speed.
    // 20 attempts up front, refill at 1/s — mirrors the /api/* bucket.
    const ip = (req.socket.remoteAddress ?? "local").toString();
    if (!takeToken(`ws:audio:ip:${ip}`, { capacity: 20, refillPerSec: 1 })) {
      database.audit("device.ws.rate_limited", { ip });
      socket.write("HTTP/1.1 429 Too Many Requests\r\n\r\n");
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  });
  wss.on("connection", handleConnection);
  logger.info("device audio websocket attached at /api/device/ws/audio");
  return wss;
}
