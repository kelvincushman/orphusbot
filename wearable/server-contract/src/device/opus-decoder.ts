/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Opus → PCM16 LE decoder for the device audio ingestion path.
 *
 * Uses `@discordjs/opus` — a N-API wrapper around libopus (the same C library
 * upstream KelvinLee uses via python-opuslib). Handles `RESTRICTED_LOWDELAY` frames
 * from the KelvinLee firmware correctly; the previous `opus-decoder` WASM package
 * silently emitted flatline PCM for those frames.
 *
 * One decoder instance per WebSocket connection — libopus is stateful across
 * frames for packet-loss concealment and pre-echo handling.
 *
 * The class is named `OpusEncoder` upstream but exposes both encode() and
 * decode() methods; we use only decode(). Deepgram accepts the PCM16 output
 * when called with encoding=linear16.
 */
// @discordjs/opus is CommonJS; Node's ESM loader requires default-import then
// destructure to read named exports (won't work with `import { OpusEncoder }`).
import opus from "@discordjs/opus";
const { OpusEncoder } = opus;

export type PcmDecoder = {
  decode: (opusFrame: Uint8Array) => Uint8Array;
  close: () => void;
};

export function createOpusPcmDecoder(sampleRate: number, _frameMs: number): PcmDecoder {
  const dec = new OpusEncoder(sampleRate, 1);
  return {
    decode(opusFrame: Uint8Array): Uint8Array {
      const buf = Buffer.from(opusFrame.buffer, opusFrame.byteOffset, opusFrame.byteLength);
      const pcm = dec.decode(buf);
      return new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength);
    },
    close() { /* libopus decoder cleans up on GC */ },
  };
}
