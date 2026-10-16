/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Diarizing realtime speech-to-text for the Wearable device channel.
 *
 * Design (mirrors upstream KelvinLee's backend/utils/stt/streaming.py dispatcher):
 *   - An env-configured ordered list of providers picks who answers.
 *     STT_SERVICE_MODELS=dg-wearable-3,dg-wearable-2-multi   (default)
 *     STT_SERVICE_MODELS=sx-stt-rt-preview,dg-wearable-3 (opt-in Soniox)
 *   - Primary is Deepgram Wearable-3 (newest, multi-language, includes speaker
 *     diarization by sending diarize=true, punctuate=true, smart_format=true).
 *   - Fallback 1 is Deepgram Wearable-2 (legacy; same wire shape, different model).
 *   - Fallback 2 is Soniox (stubbed — enable via SONIOX_API_KEY).
 *   - The caller holds a stream handle; we stream binary frames (Opus from the
 *     device, or 16 kHz PCM from the phone mic) in and receive Utterance[]
 *     events as they arrive.
 *
 * Transport: global WebSocket (available in Bun and Node 22+). No new npm dep.
 *
 * Speaker handling: Deepgram attaches an integer speaker index per word when
 * diarize=true. We group contiguous words by speaker into one Utterance and
 * map the index to a stable string id "speaker_<n+1>" so callers can look it
 * up against voice_profiles via labelSpeaker().
 */
import { env } from "../../env.js";
import { logger } from "../../logger.js";
import WebSocket from "ws";
// labelSpeaker is lazy-imported inside openDeepgramStream so this module's
// pure helpers (groupWordsBySpeaker, selectSttProvider) stay importable under
// bun:test — better-sqlite3 can't load there and it's transitively required
// by voice-profiles.ts.
import type { labelSpeaker as LabelSpeakerFn } from "./voice-profiles.js";

/** Unified transcript shape emitted to callers regardless of provider. */
export interface Utterance {
  speakerId: string;              // "speaker_1" | "speaker_2" | ...
  speakerLabel: string;           // profile.name or "Unknown (speaker_2)"
  isOwner: boolean;               // true if the profile is marked is_owner
  text: string;
  confidence: number;             // 0..1
  startMs: number;
  endMs: number;
  isFinal: boolean;
  provider: string;               // e.g. "deepgram:wearable-3"
}

export interface SttStream {
  /** Push a binary audio frame (Opus or PCM, codec-dependent per session).
   *  Returns false if the stream is closed or not yet open. */
  send(frame: Uint8Array | ArrayBuffer): boolean;
  /** Idempotent close. Fires onClose once. */
  close(): void;
  /** True until close() or server-side termination. */
  readonly isOpen: boolean;
}

export interface SttHandlers {
  onUtterance: (u: Utterance) => void;
  onError?: (err: Error) => void;
  onClose?: (code: number, reason: string) => void;
}

export interface OpenSttOpts {
  devId: string;
  encoding: "opus" | "linear16";
  sampleRate: number;             // 16000 for the nRF52840 PDM mic; phone mic can use 16000 or 48000
  language?: string;              // IETF tag, default "multi"
  handlers: SttHandlers;
}

// ---------------------------------------------------------------------------
// Provider selection
// ---------------------------------------------------------------------------

export type SttProvider = "deepgram" | "soniox";

export interface SttProviderPick {
  provider: SttProvider;
  model: string;                  // wire-level model string to pass to the provider
  language: string;
}

/** Pick the first reachable provider from STT_SERVICE_MODELS. Matches upstream
 *  KelvinLee's order semantics: first token that has a working key wins. Falls back
 *  to Deepgram Wearable-2 English as a hard safety net. */
export function selectSttProvider(language: string = "multi"): SttProviderPick {
  const ordered = env.STT_SERVICE_MODELS.split(",").map((s) => s.trim()).filter(Boolean);
  for (const token of ordered) {
    if (token === "sx-stt-rt-preview") {
      if (env.SONIOX_API_KEY) return { provider: "soniox", model: "stt-rt-preview", language };
      continue;
    }
    if (token === "dg-wearable-3") {
      if (env.DEEPGRAM_API_KEY) return { provider: "deepgram", model: "wearable-3", language };
      continue;
    }
    if (token === "dg-wearable-2-multi" || token === "dg-wearable-2") {
      if (env.DEEPGRAM_API_KEY) return { provider: "deepgram", model: "wearable-2-general", language };
      continue;
    }
  }
  // Hard safety net — if nothing matched but we do have a Deepgram key, use it
  // at Wearable-2 English. If we have neither, the caller gets an error at open().
  if (env.DEEPGRAM_API_KEY) return { provider: "deepgram", model: "wearable-2-general", language: "en" };
  return { provider: "deepgram", model: "wearable-2-general", language: "en" };
}

// ---------------------------------------------------------------------------
// Deepgram realtime
// ---------------------------------------------------------------------------

interface DeepgramWord {
  word: string;
  start: number;
  end: number;
  confidence: number;
  speaker?: number;
  punctuated_word?: string;
}

interface DeepgramTranscriptMessage {
  type: "Results";
  is_final?: boolean;
  speech_final?: boolean;
  channel: {
    alternatives: Array<{
      transcript: string;
      confidence: number;
      words: DeepgramWord[];
    }>;
  };
  start?: number;
  duration?: number;
}

function deepgramUrl(opts: OpenSttOpts, pick: SttProviderPick): string {
  const params = new URLSearchParams({
    model: pick.model,
    language: pick.language,
    diarize: "true",
    punctuate: "true",
    smart_format: "true",
    interim_results: "true",
    endpointing: "300",
    encoding: opts.encoding === "opus" ? "opus" : "linear16",
    sample_rate: String(opts.sampleRate),
  });
  return `wss://api.deepgram.com/v1/listen?${params.toString()}`;
}

/** Label resolver signature (matches voice-profiles.ts::labelSpeaker).
 *  Dependency-injected so grouping stays testable without loading SQLite. */
export type LabelResolver = (devId: string, speakerId: string) => { label: string; isOwner: boolean };

/** Group diarized words by contiguous speaker index into one Utterance each.
 *  Pure (no SQLite): pass a resolver to map speaker_id → {label, isOwner}.
 *  Tests can pass a stub; production passes the real labelSpeaker. */
export function groupWordsBySpeaker(
  words: DeepgramWord[],
  isFinal: boolean,
  provider: string,
  devId: string,
  labelFn: LabelResolver = fallbackLabel,
): Utterance[] {
  if (words.length === 0) return [];
  const out: Utterance[] = [];
  let current: DeepgramWord[] = [words[0]];
  for (let i = 1; i < words.length; i++) {
    const w = words[i];
    const prevSpeaker = current[current.length - 1].speaker ?? 0;
    const thisSpeaker = w.speaker ?? 0;
    if (thisSpeaker === prevSpeaker) {
      current.push(w);
      continue;
    }
    out.push(makeUtterance(current, isFinal, provider, devId, labelFn));
    current = [w];
  }
  out.push(makeUtterance(current, isFinal, provider, devId, labelFn));
  return out;
}

/** Trivial labeller for tests / degraded modes — doesn't touch the DB. */
function fallbackLabel(_devId: string, speakerId: string): { label: string; isOwner: boolean } {
  return { label: `Unknown (${speakerId})`, isOwner: false };
}

function makeUtterance(words: DeepgramWord[], isFinal: boolean, provider: string, devId: string, labelFn: LabelResolver): Utterance {
  const speakerIdx = (words[0].speaker ?? 0) + 1;
  const speakerId = `speaker_${speakerIdx}`;
  const { label, isOwner } = labelFn(devId, speakerId);
  const text = words.map((w) => w.punctuated_word ?? w.word).join(" ");
  const confSum = words.reduce((s, w) => s + (w.confidence ?? 0), 0);
  return {
    speakerId,
    speakerLabel: label,
    isOwner,
    text,
    confidence: words.length > 0 ? confSum / words.length : 0,
    startMs: Math.round(words[0].start * 1000),
    endMs: Math.round(words[words.length - 1].end * 1000),
    isFinal,
    provider,
  };
}

/** Open a Deepgram realtime stream. Returns a handle the caller uses to push
 *  frames and wait for utterances. */
export function openDeepgramStream(opts: OpenSttOpts): SttStream {
  if (!env.DEEPGRAM_API_KEY) {
    throw new Error("DEEPGRAM_API_KEY not set");
  }
  const pick = selectSttProvider(opts.language ?? "multi");
  if (pick.provider !== "deepgram") {
    throw new Error(`openDeepgramStream called but selectSttProvider picked ${pick.provider}`);
  }
  const url = deepgramUrl(opts, pick);
  const providerTag = `deepgram:${pick.model}`;
  // Deepgram accepts the API key as a Sec-WebSocket-Protocol "token, <key>".
  // The global WebSocket signature accepts subprotocols as the 2nd arg.
  const ws = new WebSocket(url, ["token", env.DEEPGRAM_API_KEY]);
  let open = false;
  let closed = false;
  const pendingFrames: Uint8Array[] = [];
  // Lazy-import so this function's first call is when SQLite gets touched.
  // Production paths always have the DB; tests that exercise grouping
  // directly pass their own labeller to groupWordsBySpeaker.
  let labelResolver: LabelResolver | undefined;
  const ensureResolver = async (): Promise<LabelResolver> => {
    if (labelResolver) return labelResolver;
    const mod: { labelSpeaker: typeof LabelSpeakerFn } = await import("./voice-profiles.js");
    labelResolver = mod.labelSpeaker;
    return labelResolver;
  };

  ws.addEventListener("open", () => {
    open = true;
    for (const f of pendingFrames) ws.send(f);
    pendingFrames.length = 0;
    logger.info({ devId: opts.devId, provider: providerTag, url }, "deepgram stream open");
  });

  ws.addEventListener("message", (ev) => {
    void (async () => {
      try {
        const data = typeof ev.data === "string" ? ev.data : new TextDecoder().decode(ev.data as ArrayBuffer);
        const msg = JSON.parse(data) as DeepgramTranscriptMessage;
        if (msg.type !== "Results") return;
        const alt = msg.channel?.alternatives?.[0];
        if (!alt) return;
        // Log every final transcript at info so operators can spot whether
        // transcription is flowing in production without running a probe.
        if (msg.is_final && (alt.transcript ?? "").trim().length > 0) {
          logger.info({ devId: opts.devId, transcript: alt.transcript }, "transcript final");
        }
        const resolver = await ensureResolver();
        const utterances = groupWordsBySpeaker(alt.words ?? [], !!msg.is_final, providerTag, opts.devId, resolver);
        for (const u of utterances) opts.handlers.onUtterance(u);
      } catch (err) {
        logger.warn({ err, devId: opts.devId }, "deepgram message parse failed");
      }
    })();
  });

  ws.addEventListener("error", (ev) => {
    const err = new Error(`deepgram websocket error: ${String((ev as unknown as { type?: string }).type ?? "unknown")}`);
    logger.warn({ devId: opts.devId, err }, "deepgram stream error");
    opts.handlers.onError?.(err);
  });

  ws.addEventListener("close", (ev) => {
    open = false;
    closed = true;
    const ce = ev as unknown as { code?: number; reason?: string };
    opts.handlers.onClose?.(ce.code ?? 0, ce.reason ?? "");
    logger.info({ devId: opts.devId, code: ce.code, reason: ce.reason }, "deepgram stream closed");
  });

  return {
    send(frame: Uint8Array | ArrayBuffer): boolean {
      if (closed) return false;
      const buf = frame instanceof Uint8Array ? frame : new Uint8Array(frame);
      if (!open) {
        pendingFrames.push(buf);
        return true;
      }
      ws.send(buf);
      return true;
    },
    close(): void {
      if (closed) return;
      try { ws.close(); } catch { /* ignore */ }
    },
    get isOpen() { return open && !closed; },
  };
}

// ---------------------------------------------------------------------------
// Unified entry point
// ---------------------------------------------------------------------------

/** Open a realtime STT stream using the first available provider per
 *  STT_SERVICE_MODELS. Today this routes to Deepgram; Soniox is stubbed. */
export function openSttStream(opts: OpenSttOpts): SttStream {
  const pick = selectSttProvider(opts.language ?? "multi");
  switch (pick.provider) {
    case "deepgram":
      return openDeepgramStream(opts);
    case "soniox":
      // Soniox is in the enum but the wire-level client is not ported in v1.
      // Fall through to Deepgram instead of failing hard — matches upstream
      // KelvinLee's "try next provider" fallback behaviour.
      logger.warn({ devId: opts.devId }, "soniox stt not implemented; falling back to deepgram");
      return openDeepgramStream(opts);
  }
}
