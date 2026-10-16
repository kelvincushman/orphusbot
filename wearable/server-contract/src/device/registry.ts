/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Device registry — pairing tokens + business/chat bindings for Wearable
 * wearables. Owns the `device_registrations` SQLite table declared in db.ts.
 *
 * Pairing model:
 *   1. Operator calls createDevice({label, businessId}) during enrollment.
 *   2. A random 24-byte pairing token is returned ONCE (plaintext) to show
 *      the operator; only its SHA-256 hash persists.
 *   3. Every subsequent /api/device/* request arrives with (devId, token);
 *      verifyPairingToken() runs constant-time compare on the stored hash.
 *   4. Successful verification bumps last_seen_at; the chat_id defaults to
 *      `device:<devId>` and can be rebound.
 *
 * Security:
 *   - Plaintext token is never logged. Only the hash prefix is referenced.
 *   - dev_id and label are sanitized before SQL (no SQL injection risk —
 *     we use parameter binding — but we reject weird characters early so
 *     paths and log lines stay safe).
 *   - timingSafeEqual for the hash compare (same primitive used by
 *     src/security.ts for dashboard bearer tokens).
 */
import crypto from "node:crypto";
import { database, DEFAULT_BUSINESS_ID } from "../../db.js";
import { logger } from "../../logger.js";

// Same slug shape businesses.ts uses: safe for filenames + log lines.
const DEV_ID_RE = /^[a-z0-9][a-z0-9_-]{1,63}$/;
const PAIRING_TOKEN_BYTES = 24;

export interface DeviceRow {
  dev_id: string;
  pairing_token_hash: string;
  business_id: string;
  chat_id: string | null;
  label: string | null;
  created_at: number;
  last_seen_at: number | null;
  /** S-4: 1 = hands-free audio capture active (frames gated by owner-voice
   *  diarisation instead of button press). Defaults to 0; toggled via
   *  POST /api/device/hands-free. */
  hands_free_mode: number;
}

export interface CreateDeviceResult {
  device: DeviceRow;
  /** Plaintext pairing token — shown ONCE, then discarded. */
  pairingToken: string;
}

function assertDevId(devId: string): void {
  if (!DEV_ID_RE.test(devId)) throw new Error(`invalid device id: ${devId}`);
}

function hashToken(token: string): string {
  return crypto.createHash("sha256").update(token).digest("hex");
}

export function chatIdFor(devId: string): string {
  assertDevId(devId);
  return `device:${devId}`;
}

/** Register a new device. Returns the row plus the plaintext pairing token. */
export function createDevice(input: {
  devId: string;
  label?: string;
  businessId?: string;
}): CreateDeviceResult {
  assertDevId(input.devId);
  const existing = getDevice(input.devId);
  if (existing) throw new Error(`device already registered: ${input.devId}`);
  const businessId = input.businessId ?? DEFAULT_BUSINESS_ID;
  // Reject unknown business ids early so a typo doesn't silently fall back
  // to default (which would cross-contaminate the isolation domain).
  if (businessId !== DEFAULT_BUSINESS_ID && !database.getBusiness(businessId)) {
    throw new Error(`unknown business: ${businessId}`);
  }
  const token = crypto.randomBytes(PAIRING_TOKEN_BYTES).toString("base64url");
  const hash = hashToken(token);
  const now = Date.now();
  database.raw
    .prepare(
      "INSERT INTO device_registrations(dev_id, pairing_token_hash, business_id, chat_id, label, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
    )
    .run(input.devId, hash, businessId, chatIdFor(input.devId), input.label ?? null, now);
  const device = getDevice(input.devId);
  if (!device) throw new Error(`device disappeared after insert: ${input.devId}`);
  database.audit("device.created", { devId: input.devId, businessId, label: input.label }, chatIdFor(input.devId), businessId);
  logger.info({ devId: input.devId, businessId }, "device registered");
  return { device, pairingToken: token };
}

export function getDevice(devId: string): DeviceRow | null {
  assertDevId(devId);
  const row = database.raw
    .prepare(
      "SELECT dev_id, pairing_token_hash, business_id, chat_id, label, created_at, last_seen_at, hands_free_mode FROM device_registrations WHERE dev_id = ?",
    )
    .get(devId) as DeviceRow | undefined;
  return row ?? null;
}

export function listDevices(businessId?: string): DeviceRow[] {
  if (businessId) {
    return database.raw
      .prepare(
        "SELECT dev_id, pairing_token_hash, business_id, chat_id, label, created_at, last_seen_at, hands_free_mode FROM device_registrations WHERE business_id = ? ORDER BY created_at DESC",
      )
      .all(businessId) as DeviceRow[];
  }
  return database.raw
    .prepare(
      "SELECT dev_id, pairing_token_hash, business_id, chat_id, label, created_at, last_seen_at, hands_free_mode FROM device_registrations ORDER BY created_at DESC",
    )
    .all() as DeviceRow[];
}

/** Constant-time compare against the stored token hash. Returns false on any
 *  mismatch (wrong device, wrong token, unknown device). Never logs the token. */
export function verifyPairingToken(devId: string, token: string): boolean {
  if (!DEV_ID_RE.test(devId)) return false;
  if (typeof token !== "string" || token.length === 0) return false;
  const row = getDevice(devId);
  if (!row) return false;
  const got = Buffer.from(hashToken(token), "hex");
  const want = Buffer.from(row.pairing_token_hash, "hex");
  if (got.length !== want.length) return false;
  return crypto.timingSafeEqual(got, want);
}

/** Bump last_seen_at. Called on every authenticated device request. */
export function touchDevice(devId: string): void {
  assertDevId(devId);
  database.raw
    .prepare("UPDATE device_registrations SET last_seen_at = ? WHERE dev_id = ?")
    .run(Date.now(), devId);
}

/** Bind / rebind the device to a business. */
export function setDeviceBusiness(devId: string, businessId: string): void {
  assertDevId(devId);
  if (businessId !== DEFAULT_BUSINESS_ID && !database.getBusiness(businessId)) {
    throw new Error(`unknown business: ${businessId}`);
  }
  const result = database.raw
    .prepare("UPDATE device_registrations SET business_id = ? WHERE dev_id = ?")
    .run(businessId, devId);
  if (result.changes === 0) throw new Error(`unknown device: ${devId}`);
  database.audit("device.rebound", { devId, businessId }, chatIdFor(devId), businessId);
}

/** S-4: read the device's hands-free flag. Returns false if the device is
 *  unknown or the column was never set. */
export function getHandsFreeMode(devId: string): boolean {
  if (!DEV_ID_RE.test(devId)) return false;
  const row = database.raw
    .prepare("SELECT hands_free_mode FROM device_registrations WHERE dev_id = ?")
    .get(devId) as { hands_free_mode?: number } | undefined;
  return (row?.hands_free_mode ?? 0) === 1;
}

/** S-4: flip the device's hands-free flag. The privacy-critical gate in
 *  ws-audio.ts and stt.ts reads this on every capture decision. */
export function setHandsFreeMode(devId: string, enabled: boolean): void {
  assertDevId(devId);
  const result = database.raw
    .prepare("UPDATE device_registrations SET hands_free_mode = ? WHERE dev_id = ?")
    .run(enabled ? 1 : 0, devId);
  if (result.changes === 0) throw new Error(`unknown device: ${devId}`);
  database.audit("device.hands_free_set", { devId, enabled }, chatIdFor(devId));
  logger.info({ devId, enabled }, "hands-free mode updated");
}

export function deleteDevice(devId: string): void {
  assertDevId(devId);
  const row = getDevice(devId);
  if (!row) return;
  database.raw.prepare("DELETE FROM device_registrations WHERE dev_id = ?").run(devId);
  database.audit("device.deleted", { devId, businessId: row.business_id }, row.chat_id ?? undefined, row.business_id);
  logger.warn({ devId }, "device deleted");
}
