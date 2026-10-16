/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Voice profiles — per-device speaker labels with owner flag + rename support.
 *
 * Scope (v1): store/retrieve/rename profiles keyed by (dev_id, speaker_id).
 * speaker_id is the short-lived label emitted by the diarizer (speaker_1,
 * speaker_2, ...); the profile row is how the operator maps those labels to
 * real names ("speaker_2 → Alice") and marks which profile represents Kelvin.
 *
 * NOT in v1 scope: embedding-based matching across sessions (i.e. the ability
 * to automatically recognise Kelvin across device reboots when the diarizer
 * assigns a different speaker_id). That requires loading a speaker-embedding
 * model (pyannote/titanet/speechbrain) and comparing vectors — a Phase 1.1b
 * or v2 task. The `embedding` blob column is reserved in the schema; reads
 * of it are no-ops here until the matcher is wired.
 */
import { database } from "../../db.js";
import { logger } from "../../logger.js";

export interface VoiceProfile {
  id: number;
  devId: string;
  speakerId: string | null;    // diarizer label at enrollment time
  name: string;
  isOwner: boolean;
  trainedAt: number;
  updatedAt: number;
}

interface Row {
  id: number;
  dev_id: string;
  speaker_id: string | null;
  name: string;
  is_owner: number;
  embedding: Buffer | null;
  trained_at: number;
  updated_at: number;
}

function toProfile(row: Row): VoiceProfile {
  return {
    id: row.id,
    devId: row.dev_id,
    speakerId: row.speaker_id,
    name: row.name,
    isOwner: row.is_owner === 1,
    trainedAt: row.trained_at,
    updatedAt: row.updated_at,
  };
}

/** Enroll a new voice profile for a device. The caller is responsible for
 *  passing the embedding buffer (or null if embedding-matching is deferred).
 *  If isOwner is true, any existing owner for this device is demoted first —
 *  only one owner per device. */
export function enrollProfile(input: {
  devId: string;
  speakerId?: string;
  name: string;
  isOwner?: boolean;
  embedding?: Uint8Array | null;
}): VoiceProfile {
  if (!input.name || input.name.trim().length === 0) throw new Error("enrollProfile: name required");
  const now = Date.now();
  const db = database.raw;
  const blob = input.embedding ? Buffer.from(input.embedding) : null;
  // Demote + insert must be atomic — two concurrent isOwner:true enrolments
  // both passing the demote (no-op) then both inserting would produce two
  // owners. Matches the markOwner transaction below.
  const tx = db.transaction(() => {
    if (input.isOwner) {
      db.prepare("UPDATE voice_profiles SET is_owner = 0, updated_at = ? WHERE dev_id = ? AND is_owner = 1")
        .run(now, input.devId);
    }
    return db.prepare(
      "INSERT INTO voice_profiles(dev_id, speaker_id, name, is_owner, embedding, trained_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run(
      input.devId,
      input.speakerId ?? null,
      input.name.trim().slice(0, 120),
      input.isOwner ? 1 : 0,
      blob,
      now,
      now,
    );
  });
  const result = tx();
  logger.info({ devId: input.devId, speakerId: input.speakerId, name: input.name, isOwner: !!input.isOwner }, "voice profile enrolled");
  return getProfileById(Number(result.lastInsertRowid)) as VoiceProfile;
}

export function getProfileById(id: number): VoiceProfile | null {
  const row = database.raw
    .prepare("SELECT id, dev_id, speaker_id, name, is_owner, embedding, trained_at, updated_at FROM voice_profiles WHERE id = ?")
    .get(id) as Row | undefined;
  return row ? toProfile(row) : null;
}

/** Look up a profile by diarizer speaker_id. Useful when a diarized transcript
 *  arrives and we want to resolve `speaker_1` → `{name: "Kelvin", isOwner: true}`. */
export function getProfileBySpeakerId(devId: string, speakerId: string): VoiceProfile | null {
  const row = database.raw
    .prepare("SELECT id, dev_id, speaker_id, name, is_owner, embedding, trained_at, updated_at FROM voice_profiles WHERE dev_id = ? AND speaker_id = ? ORDER BY updated_at DESC LIMIT 1")
    .get(devId, speakerId) as Row | undefined;
  return row ? toProfile(row) : null;
}

export function listProfiles(devId: string): VoiceProfile[] {
  const rows = database.raw
    .prepare("SELECT id, dev_id, speaker_id, name, is_owner, embedding, trained_at, updated_at FROM voice_profiles WHERE dev_id = ? ORDER BY is_owner DESC, updated_at DESC")
    .all(devId) as Row[];
  return rows.map(toProfile);
}

/** Rename a profile. This is how the KelvinLee-style "speaker_2 → Alice" UX
 *  flows through: the app PATCHes the profile name and future transcripts
 *  render with the new label. */
export function renameProfile(id: number, name: string): VoiceProfile {
  if (!name || name.trim().length === 0) throw new Error("renameProfile: name required");
  const now = Date.now();
  const result = database.raw
    .prepare("UPDATE voice_profiles SET name = ?, updated_at = ? WHERE id = ?")
    .run(name.trim().slice(0, 120), now, id);
  if (result.changes === 0) throw new Error(`voice profile not found: ${id}`);
  return getProfileById(id) as VoiceProfile;
}

/** Mark a profile as the device owner. Demotes the previous owner (if any)
 *  atomically in the same transaction. */
export function markOwner(id: number): VoiceProfile {
  const profile = getProfileById(id);
  if (!profile) throw new Error(`voice profile not found: ${id}`);
  const now = Date.now();
  const tx = database.raw.transaction(() => {
    database.raw.prepare("UPDATE voice_profiles SET is_owner = 0, updated_at = ? WHERE dev_id = ? AND is_owner = 1")
      .run(now, profile.devId);
    database.raw.prepare("UPDATE voice_profiles SET is_owner = 1, updated_at = ? WHERE id = ?")
      .run(now, id);
  });
  tx();
  return getProfileById(id) as VoiceProfile;
}

export function deleteProfile(id: number): void {
  database.raw.prepare("DELETE FROM voice_profiles WHERE id = ?").run(id);
}

/** Best-effort label for a raw diarizer speaker_id. Returns the profile name
 *  if known, or a fallback "Unknown speaker N" string. Annotates whether the
 *  label is the device owner for downstream memory bookkeeping. */
export function labelSpeaker(devId: string, speakerId: string): { label: string; isOwner: boolean } {
  const profile = getProfileBySpeakerId(devId, speakerId);
  if (profile) return { label: profile.name, isOwner: profile.isOwner };
  return { label: `Unknown (${speakerId})`, isOwner: false };
}

/** Atomically ensure a device has exactly one owner profile. If one already
 *  exists, returns it unchanged. If not, creates a new owner row inside a
 *  transaction that reads-then-writes under SQLite's WAL single-writer
 *  semantics — prevents the TOCTOU where two concurrent uploads both see
 *  "no owner" and both insert. Returns {profile, created}.
 *
 *  Used by speech-profile-api.storeWavSample on first upload. */
export function ensureOwnerProfile(input: {
  devId: string;
  name: string;
  embedding?: Uint8Array | null;
}): { profile: VoiceProfile; created: boolean } {
  if (!input.name || input.name.trim().length === 0) {
    throw new Error("ensureOwnerProfile: name required");
  }
  const now = Date.now();
  const db = database.raw;
  const blob = input.embedding ? Buffer.from(input.embedding) : null;
  const tx = db.transaction(() => {
    const row = db
      .prepare(
        "SELECT id, dev_id, speaker_id, name, is_owner, embedding, trained_at, updated_at FROM voice_profiles WHERE dev_id = ? AND is_owner = 1 LIMIT 1",
      )
      .get(input.devId) as Row | undefined;
    if (row) return { profileId: row.id, created: false };
    const result = db
      .prepare(
        "INSERT INTO voice_profiles(dev_id, speaker_id, name, is_owner, embedding, trained_at, updated_at) VALUES (?, NULL, ?, 1, ?, ?, ?)",
      )
      .run(input.devId, input.name.trim().slice(0, 120), blob, now, now);
    return { profileId: Number(result.lastInsertRowid), created: true };
  });
  const { profileId, created } = tx();
  const profile = getProfileById(profileId);
  if (!profile) throw new Error(`voice profile disappeared: ${profileId}`);
  if (created) {
    logger.info({ devId: input.devId, profileId }, "owner voice profile created");
  }
  return { profile, created };
}
