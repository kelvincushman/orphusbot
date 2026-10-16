/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * KelvinLee-compat speech-profile endpoints (S-4 + M-5 precursor).
 *
 * The existing KelvinLee app at `devices/wearable-kelvinlee/app/lib/pages/speech_profile/`
 * enrolls the user's voice by streaming a short sample through the wearable,
 * building a WAV in-memory, and multipart-POSTing it to `v3/upload-audio`
 * while polling `v3/speech-profile` to see whether a profile exists.
 *
 * This module provides Wearable-native equivalents so the existing UX can work
 * end-to-end against Wearable instead of the KelvinLee cloud. Two flows:
 *
 *   - check: does this device have an owner voice profile?
 *   - upload: accept a WAV sample, persist to disk, mark an owner row in
 *     voice_profiles if none exists yet.
 *
 * Authentication is the Wearable pairing-token (X-Device-Id + X-Device-Token),
 * NOT the Firebase bearer the KelvinLee shared.dart currently attaches. M-5 is
 * responsible for updating the Dart HTTP layer; this module only covers the
 * server half of the compat surface.
 *
 * Storage layout:
 *   <WEARABLE_HOME>/store/voice-samples/<devId>/<ulid>.wav
 * One file per upload, immutable. Owner identity is determined by the
 * voice_profiles row with is_owner=1 for this devId; the WAV is the raw
 * sample kept for future embedding-based matching (Phase 1.1b).
 */
import fs from "node:fs";
import path from "node:path";
import { ulid } from "ulid";
import { paths } from "../../config.js";
import { database } from "../../db.js";
import { logger } from "../../logger.js";
import { ensureOwnerProfile, listProfiles } from "./voice-profiles.js";

const VOICE_SAMPLE_DIR = path.join(paths.store, "voice-samples");
const MAX_WAV_BYTES = 10 * 1024 * 1024;   // 10 MB — enrollment is seconds of 16kHz PCM

/** Same slug shape as registry's DEV_ID_RE; duplicated to avoid a circular
 *  import. Callers should already have verified auth before getting here,
 *  so a mismatch here is a programming error. */
const DEV_ID_RE = /^[a-z0-9][a-z0-9_-]{1,63}$/;

export interface HasProfileResult {
  has_profile: boolean;
  profile_id?: number;
  trained_at?: number;
}

/** True if an owner profile exists for this device. Mirrors the shape KelvinLee's
 *  `v3/speech-profile` returns so the existing app contract works. */
export function hasOwnerProfile(devId: string): HasProfileResult {
  if (!DEV_ID_RE.test(devId)) return { has_profile: false };
  const owner = listProfiles(devId).find((p) => p.isOwner);
  if (!owner) return { has_profile: false };
  return { has_profile: true, profile_id: owner.id, trained_at: owner.trainedAt };
}

export interface UploadResult {
  ok: true;
  profileId: number;
  samplePath: string;
  bytes: number;
  createdOwner: boolean;
}

export interface UploadError {
  ok: false;
  reason: "empty" | "too_large" | "invalid_device" | "write_failed";
}

/** Persist a WAV sample under `<store>/voice-samples/<devId>/<ulid>.wav` and
 *  register an owner voice profile on first upload. Subsequent uploads add
 *  new samples but do not change ownership. */
export function storeWavSample(devId: string, data: Uint8Array): UploadResult | UploadError {
  if (!DEV_ID_RE.test(devId)) return { ok: false, reason: "invalid_device" };
  if (data.byteLength === 0) return { ok: false, reason: "empty" };
  if (data.byteLength > MAX_WAV_BYTES) return { ok: false, reason: "too_large" };

  const deviceDir = path.join(VOICE_SAMPLE_DIR, devId);
  try {
    fs.mkdirSync(deviceDir, { recursive: true });
  } catch (err) {
    logger.error({ err, devId }, "voice-sample dir creation failed");
    return { ok: false, reason: "write_failed" };
  }

  const fileName = `${ulid()}.wav`;
  const samplePath = path.join(deviceDir, fileName);
  try {
    fs.writeFileSync(samplePath, data, { mode: 0o600 });
  } catch (err) {
    logger.error({ err, devId, samplePath }, "voice-sample write failed");
    return { ok: false, reason: "write_failed" };
  }

  // Atomic check-then-insert under a single SQLite transaction so two
  // concurrent uploads can't both see "no owner" and both create one.
  const { profile, created } = ensureOwnerProfile({
    devId,
    name: "Owner",
    embedding: null,   // embedding-based matching is Phase 1.1b
  });
  const profileId = profile.id;
  const createdOwner = created;

  database.audit(
    "device.voice_profile_upload",
    { devId, samplePath, bytes: data.byteLength, createdOwner, profileId },
    undefined,
  );
  logger.info({ devId, samplePath, bytes: data.byteLength, createdOwner }, "voice sample stored");
  return {
    ok: true,
    profileId,
    samplePath,
    bytes: data.byteLength,
    createdOwner,
  };
}

/** Reverse-lookup a stored sample path for download. Used by the KelvinLee
 *  `v4/speech-profile` contract which returns `{url: string}` to the app. */
export function latestSamplePath(devId: string): string | null {
  if (!DEV_ID_RE.test(devId)) return null;
  const deviceDir = path.join(VOICE_SAMPLE_DIR, devId);
  if (!fs.existsSync(deviceDir)) return null;
  const entries = fs.readdirSync(deviceDir).filter((f) => f.endsWith(".wav"));
  if (entries.length === 0) return null;
  // ULID filenames sort lexicographically by time; latest == last.
  entries.sort();
  return path.join(deviceDir, entries[entries.length - 1]);
}
