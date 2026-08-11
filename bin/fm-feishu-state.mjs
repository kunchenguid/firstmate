#!/usr/bin/env node
// Private durable state owner for the Firstmate Feishu channel.
//
// This module contains no network or Agent code.  It owns the pairing and
// binding schemas, private accepted-event publication, native Pi queue handoff,
// direct-Assistant outbox records, attempts, receipts, correlation maps,
// quarantine, transport health, and crash reconciliation.  The Pi extension
// and the no-Agent transport import this same owner rather than duplicating
// those state machines.
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  statfsSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const PAIRING_SCHEMA = "fm-feishu-pairing.v2";
export const BINDING_SCHEMA = "fm-feishu-binding.v1";
export const INBOUND_SCHEMA = "fm-feishu-inbound.v1";
export const INBOUND_LEDGER_SCHEMA = "fm-feishu-inbound-ledger.v2";
export const OUTBOUND_SCHEMA = "fm-feishu-assistant-outbound.v1";
export const OUTBOUND_LEDGER_SCHEMA = "fm-feishu-outbound-ledger.v1";
export const OUTBOUND_RECEIPT_SCHEMA = "fm-feishu-outbound-receipt.v1";
export const OUTBOUND_INTENT_SCHEMA = "fm-feishu-outbound-registration-intent.v1";
export const TRANSPORT_HEALTH_SCHEMA = "fm-feishu-transport-health.v2";
export const DECISION_SCHEMA = "fm-feishu-pending-decision.v1";
export const DEFAULT_MAX_INBOUND_BYTES = 64 * 1024;
export const DEFAULT_MAX_OUTBOUND_CHUNK_BYTES = 20 * 1024;
export const DEFAULT_MAX_OUTBOUND_BYTES = 1024 * 1024;
export const DEFAULT_MAX_PENDING_INBOUND = 10000;
export const DEFAULT_MAX_PENDING_OUTBOUND = 1000;
export const DEFAULT_MIN_FREE_BYTES = 64 * 1024 * 1024;
export const IDEMPOTENCY_WINDOW_MS = 60 * 60 * 1000;
const LOCK_WAIT_MS = 3000;
const LOCK_STALE_MS = 30000;
const RETRY_BASE_MS = 1000;
const RETRY_MAX_MS = 60000;
const MODULE_FILE = fileURLToPath(import.meta.url);
const RECORD_HASH = /^sha256:[a-f0-9]{64}$/;
const SESSION_ID = /^[0-9a-fA-F-]{16,128}$/;
const DELIVERY_REF = /^in_[a-f0-9]{24}$/;
const OUTBOUND_EVENT_ID = /^out_[a-f0-9]{40}$/;
const MESSAGE_ID = /^om_[A-Za-z0-9_-]{4,128}$/;
const CHAT_ID = /^oc_[A-Za-z0-9_-]{4,128}$/;

function nowIso() {
  return new Date().toISOString();
}

function sha(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function stableId(prefix, value, length = 32) {
  return `${prefix}${sha(value).slice(0, length)}`;
}

function sleepSync(ms) {
  const cell = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(cell, 0, 0, ms);
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : fallback;
}

function privateDir(path) {
  if (!existsSync(path)) mkdirSync(path, { mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`unsafe Feishu state directory: ${path}`);
  }
  chmodSync(path, 0o700);
}

function safeFile(path, { optional = false } = {}) {
  if (!existsSync(path)) {
    if (optional) return false;
    throw new Error(`missing Feishu state file: ${path}`);
  }
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) {
    throw new Error(`unsafe Feishu state file: ${path}`);
  }
  return true;
}

function fsyncDirectory(path) {
  let fd;
  try {
    fd = openSync(path, "r");
    fsyncSync(fd);
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function atomicWrite(path, bytes, mode = 0o600) {
  privateDir(dirname(path));
  if (existsSync(path)) safeFile(path);
  const tempDir = join(dirname(dirname(path)), ".fm-feishu-atomic");
  privateDir(tempDir);
  const temp = join(tempDir, `.${sha(path).slice(0, 10)}.${process.pid}.${randomBytes(5).toString("hex")}.tmp`);
  let fd;
  try {
    fd = openSync(temp, "wx", mode);
    writeFileSync(fd, bytes, { encoding: "utf8" });
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    chmodSync(temp, mode);
    renameSync(temp, path);
    fsyncDirectory(dirname(path));
  } finally {
    if (fd !== undefined) closeSync(fd);
    try { unlinkSync(temp); } catch {}
  }
}

function atomicJson(path, value) {
  atomicWrite(path, `${JSON.stringify(value)}\n`);
}

function readJson(path, { optional = false } = {}) {
  if (!safeFile(path, { optional })) return undefined;
  const raw = readFileSync(path, "utf8");
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error(`malformed Feishu JSON: ${path}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`invalid Feishu JSON object: ${path}`);
  }
  validateRecordAtPath(path, value);
  return value;
}

function pidAlive(pid) {
  if (!Number.isSafeInteger(Number(pid)) || Number(pid) <= 1) return false;
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function withLock(paths, name, callback) {
  const lock = join(paths.stateRoot, `.${name}.lock`);
  const started = Date.now();
  for (;;) {
    let fd;
    try {
      fd = openSync(lock, "wx", 0o600);
      writeFileSync(fd, `${process.pid}\n`, "utf8");
      fsyncSync(fd);
      closeSync(fd);
      fd = undefined;
      break;
    } catch (error) {
      if (fd !== undefined) closeSync(fd);
      if (error?.code !== "EEXIST") throw error;
      let stale = false;
      try {
        const age = Date.now() - statSync(lock).mtimeMs;
        const owner = Number(readFileSync(lock, "utf8").trim());
        stale = age > LOCK_STALE_MS && !pidAlive(owner);
      } catch {
        stale = false;
      }
      if (stale) {
        try { unlinkSync(lock); } catch {}
        continue;
      }
      if (Date.now() - started >= LOCK_WAIT_MS) {
        throw new Error(`timed out acquiring Feishu ${name} state lock`);
      }
      sleepSync(10);
    }
  }
  try {
    return callback();
  } finally {
    try { unlinkSync(lock); } catch {}
    fsyncDirectory(paths.stateRoot);
  }
}

function withConfigurationLocks(paths, callback) {
  return withLock(paths, "pairing", () => withLock(paths, "binding", callback));
}

export function pathsForHome(home) {
  const homePath = resolve(home);
  const homeRealpath = realpathSync(homePath);
  const dataRoot = join(homeRealpath, "data", "feishu");
  const stateRoot = join(homeRealpath, "state", "feishu");
  return {
    home: homeRealpath,
    dataRoot,
    pairing: join(dataRoot, "pairing.json"),
    bindings: join(dataRoot, "bindings"),
    activeBinding: join(dataRoot, "bindings", "active.json"),
    stateRoot,
    inbox: join(stateRoot, "inbox"),
    inboundLedger: join(stateRoot, "inbound-ledger"),
    inboundEventIds: join(stateRoot, "inbound-event-ids"),
    inboundPending: join(stateRoot, "inbound-pending"),
    inboundPendingCount: join(stateRoot, "inbound-pending-count"),
    inboundDeliveryMap: join(stateRoot, "inbound-delivery-map"),
    inboundPublications: join(stateRoot, "inbound-publications"),
    outbox: join(stateRoot, "outbox"),
    outboundLedger: join(stateRoot, "outbound-ledger"),
    outboundReceipts: join(stateRoot, "outbound-receipts"),
    outboundMessageMap: join(stateRoot, "outbound-message-map"),
    outboundPending: join(stateRoot, "outbound-pending"),
    outboundRegistrationIntents: join(stateRoot, "outbound-registration-intents"),
    pendingDecisions: join(stateRoot, "pending-decisions"),
    pendingDecisionOpen: join(stateRoot, "pending-decision-open"),
    attemptsOut: join(stateRoot, "attempts", "out"),
    quarantine: join(stateRoot, "quarantine"),
    alerts: join(stateRoot, "alerts"),
    transport: join(stateRoot, "transport"),
    health: join(stateRoot, "transport", "health.json"),
    owner: join(stateRoot, "transport", "owner.json"),
    liveSession: join(stateRoot, "live-session"),
    sequence: join(stateRoot, "sequence"),
  };
}

export function ensurePrivateLayout(home) {
  const paths = pathsForHome(home);
  privateDir(dirname(paths.dataRoot));
  privateDir(paths.dataRoot);
  privateDir(paths.bindings);
  privateDir(dirname(paths.stateRoot));
  for (const path of [
    paths.stateRoot,
    paths.inbox,
    paths.inboundLedger,
    paths.inboundEventIds,
    paths.inboundPending,
    paths.inboundDeliveryMap,
    paths.inboundPublications,
    paths.outbox,
    paths.outboundLedger,
    paths.outboundReceipts,
    paths.outboundMessageMap,
    paths.outboundPending,
    paths.outboundRegistrationIntents,
    paths.pendingDecisions,
    paths.pendingDecisionOpen,
    join(paths.stateRoot, "attempts"),
    paths.attemptsOut,
    paths.quarantine,
    paths.alerts,
    paths.transport,
    paths.liveSession,
  ]) privateDir(path);
  if (!existsSync(paths.sequence)) atomicWrite(paths.sequence, "0\n");
  if (!existsSync(paths.inboundPendingCount)) {
    let pending = 0;
    for (const name of safeJsonNames(paths.inboundLedger)) {
      const ledger = readJson(join(paths.inboundLedger, name));
      if (ledger.state === "pending" || ledger.state === "offered") {
        writeInboundPendingIndex(paths, name, ledger);
        pending += 1;
      }
    }
    atomicWrite(paths.inboundPendingCount, `${pending}\n`);
  }
  return paths;
}

function nextSequence(paths) {
  return withLock(paths, "sequence", () => {
    let current = 0;
    if (existsSync(paths.sequence)) {
      safeFile(paths.sequence);
      const raw = readFileSync(paths.sequence, "utf8");
      if (!/^(0|[1-9][0-9]*)\n$/.test(raw)) throw new Error("malformed Feishu ingress sequence");
      current = Number(raw.trim());
    }
    if (!Number.isSafeInteger(current) || current < 0 || current >= Number.MAX_SAFE_INTEGER) {
      throw new Error("exhausted Feishu ingress sequence");
    }
    const next = current + 1;
    atomicWrite(paths.sequence, `${next}\n`);
    return next;
  });
}

function requireString(value, label, pattern, max = 512) {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value, "utf8") > max || (pattern && !pattern.test(value))) {
    throw new Error(`invalid ${label}`);
  }
  return value;
}

function requireNullableString(value, label, pattern, max = 512) {
  if (value === null) return null;
  return requireString(value, label, pattern, max);
}

function requireSafeInteger(value, label, { min = 0 } = {}) {
  if (!Number.isSafeInteger(value) || value < min) throw new Error(`invalid ${label}`);
  return value;
}

function requireIso(value, label, { nullable = false } = {}) {
  if (nullable && value === null) return null;
  requireString(value, label, undefined, 64);
  if (!Number.isFinite(Date.parse(value))) throw new Error(`invalid ${label}`);
  return value;
}

function validateInboundEvent(event) {
  if (event.schema !== INBOUND_SCHEMA || event.source !== "feishu") throw new Error("invalid Feishu inbound event schema or source");
  requireString(event.message_id, "inbound message id", MESSAGE_ID);
  if (!Array.isArray(event.event_ids) || event.event_ids.some((id) => typeof id !== "string" || id.length === 0 || Buffer.byteLength(id, "utf8") > 512)) throw new Error("invalid Feishu inbound event ids");
  requireString(event.transport, "inbound transport", /^[A-Za-z0-9._-]+$/, 128);
  requireString(event.sender_id, "inbound sender", /^ou_[A-Za-z0-9_-]{4,128}$/);
  if (event.sender_type !== "user") throw new Error("invalid Feishu inbound sender type");
  requireString(event.chat_id, "inbound chat", CHAT_ID);
  if (event.chat_type !== "p2p") throw new Error("invalid Feishu inbound chat type");
  requireNullableString(event.reply_to, "inbound reply", MESSAGE_ID);
  requireNullableString(event.root_id, "inbound root id", /^(?:om_|omt_)[A-Za-z0-9_-]{4,128}$/);
  requireNullableString(event.thread_id, "inbound thread id", /^(?:om_|omt_)[A-Za-z0-9_-]{4,128}$/);
  if (event.message_type !== "text") throw new Error("invalid Feishu inbound message type");
  if (typeof event.text !== "string" || event.text.trim().length === 0 || Buffer.from(event.text, "utf8").toString("utf8") !== event.text) throw new Error("invalid Feishu inbound text");
  requireSafeInteger(event.create_time_ms, "inbound create time");
  if (event.update_time_ms !== undefined && event.update_time_ms !== null) requireSafeInteger(event.update_time_ms, "inbound update time");
  requireIso(event.received_at, "inbound received time");
  requireString(event.payload_hash, "inbound payload hash", RECORD_HASH);
  requireString(event.binding_id, "inbound binding id", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(event.binding_generation, "inbound binding generation", { min: 1 });
  requireString(event.target_session_id, "inbound target session", SESSION_ID);
  requireString(event.authorization_snapshot, "inbound authorization snapshot", RECORD_HASH);
  requireSafeInteger(event.ingress_seq, "inbound sequence", { min: 1 });
  requireString(event.delivery_ref, "inbound delivery ref", DELIVERY_REF);
  requireNullableString(event.decision_ref, "inbound decision ref", /^[A-Za-z0-9._:-]{1,160}$/);
  requireNullableString(event.decision_key, "inbound decision key", /^[A-Za-z0-9._:-]{1,160}$/);
  if ((event.decision_ref === null) !== (event.decision_key === null)) throw new Error("partial Feishu inbound decision identity");
  if (!new Set(["exact", "unrelated", "none"]).has(event.decision_reply)) throw new Error("invalid Feishu inbound decision fence");
  return event;
}

function validateInboundLedger(ledger) {
  if (ledger.schema !== INBOUND_LEDGER_SCHEMA || ledger.source !== "feishu") throw new Error("invalid Feishu inbound ledger schema or source");
  requireString(ledger.message_id, "inbound ledger message id", MESSAGE_ID);
  requireSafeInteger(ledger.ingress_seq, "inbound ledger sequence", { min: 1 });
  if (!new Set(["pending", "offered", "delivered", "superseded"]).has(ledger.state)) throw new Error("invalid Feishu inbound ledger state");
  requireSafeInteger(ledger.attempt, "inbound ledger attempt");
  requireString(ledger.target_session_id, "inbound target session", SESSION_ID);
  requireString(ledger.binding_id, "inbound ledger binding", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(ledger.binding_generation, "inbound ledger generation", { min: 1 });
  requireString(ledger.delivery_ref, "inbound ledger delivery ref", DELIVERY_REF);
  if (ledger.last_error !== null && typeof ledger.last_error !== "string") throw new Error("invalid Feishu inbound ledger error");
  requireIso(ledger.created_at, "inbound ledger creation time");
  if (ledger.offered_at !== undefined && ledger.offered_at !== null) requireIso(ledger.offered_at, "inbound native queue offer time");
  if (ledger.delivered_at !== undefined && ledger.delivered_at !== null) requireIso(ledger.delivered_at, "inbound delivery time");
  if (ledger.superseded_at !== undefined && ledger.superseded_at !== null) requireIso(ledger.superseded_at, "inbound superseded time");
  if (ledger.state === "offered" && ledger.offered_at == null) throw new Error("offered Feishu inbound ledger lacks native queue evidence");
  if (ledger.state !== "offered" && ledger.offered_at != null) throw new Error("non-offered Feishu inbound ledger has stale native queue evidence");
  if (ledger.state === "delivered" && ledger.delivered_at == null) throw new Error("delivered Feishu inbound ledger lacks session-marker proof");
  if (ledger.state === "superseded" && ledger.superseded_at == null) throw new Error("superseded Feishu inbound ledger lacks terminal proof");
  if (ledger.state !== "delivered" && ledger.delivered_at != null) throw new Error("non-delivered Feishu inbound ledger has stale persistence proof");
  return ledger;
}

function validateOutbound(outbox) {
  if (outbox.schema !== OUTBOUND_SCHEMA || outbox.source !== "feishu") throw new Error("invalid Feishu outbox schema or source");
  requireString(outbox.event_id, "outbound event id", OUTBOUND_EVENT_ID);
  requireString(outbox.source_ref, "outbound source ref", DELIVERY_REF);
  requireString(outbox.session_id, "outbound session", SESSION_ID);
  requireString(outbox.binding_id, "outbound binding", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(outbox.binding_generation, "outbound generation", { min: 1 });
  requireString(outbox.destination_chat_id, "outbound destination", CHAT_ID);
  requireNullableString(outbox.reply_to_message_id, "outbound reply", MESSAGE_ID);
  requireNullableString(outbox.decision_ref, "outbound decision ref", /^[A-Za-z0-9._:-]{1,160}$/);
  requireNullableString(outbox.decision_key, "outbound decision key", /^[A-Za-z0-9._:-]{1,160}$/);
  if ((outbox.decision_ref === null) !== (outbox.decision_key === null)) throw new Error("partial Feishu outbound decision identity");
  if (typeof outbox.text !== "string" || outbox.text.trim().length === 0) throw new Error("invalid Feishu outbound text");
  if (outbox.text_hash !== `sha256:${sha(outbox.text)}`) throw new Error("Feishu outbound text hash mismatch");
  if (!Array.isArray(outbox.chunks) || outbox.chunks.length === 0) throw new Error("invalid Feishu outbound chunks");
  let combined = "";
  for (let index = 0; index < outbox.chunks.length; index += 1) {
    const chunk = outbox.chunks[index];
    if (!chunk || chunk.index !== index || chunk.count !== outbox.chunks.length || typeof chunk.chunk !== "string" || chunk.chunk.length === 0) throw new Error("invalid Feishu outbound chunk ordering");
    if (chunk.chunk_hash !== `sha256:${sha(chunk.chunk)}`) throw new Error("Feishu outbound chunk hash mismatch");
    if (chunk.idempotency_key !== stableId("fm", `${outbox.event_id}\0${index}`, 44)) throw new Error("Feishu outbound idempotency identity mismatch");
    combined += chunk.chunk;
  }
  if (combined !== outbox.text) throw new Error("Feishu outbound chunks changed final text");
  requireIso(outbox.created_at, "outbound creation time");
  return outbox;
}

function validateOutboundLedger(ledger) {
  if (ledger.schema !== OUTBOUND_LEDGER_SCHEMA) throw new Error("invalid Feishu outbound ledger schema");
  requireString(ledger.event_id, "outbound ledger event", OUTBOUND_EVENT_ID);
  if (!new Set(["pending", "retryable", "sending", "posted", "superseded", "delivery_uncertain"]).has(ledger.state)) throw new Error("invalid Feishu outbound ledger state");
  requireSafeInteger(ledger.next_chunk, "outbound next chunk");
  requireSafeInteger(ledger.attempts, "outbound attempts");
  requireSafeInteger(ledger.retry_at_ms, "outbound retry time");
  requireSafeInteger(ledger.binding_generation, "outbound ledger generation", { min: 1 });
  if (ledger.attempt_id !== undefined) requireString(ledger.attempt_id, "outbound attempt id", /^attempt_[a-f0-9]{24}$/);
  if (ledger.last_attempt_ms !== undefined) requireSafeInteger(ledger.last_attempt_ms, "outbound last attempt");
  if (ledger.idempotency_started_ms !== undefined && ledger.idempotency_started_ms !== null) requireSafeInteger(ledger.idempotency_started_ms, "outbound idempotency start");
  if (ledger.idempotency_expires_ms !== undefined && ledger.idempotency_expires_ms !== null) requireSafeInteger(ledger.idempotency_expires_ms, "outbound idempotency expiry");
  if ((ledger.idempotency_started_ms == null) !== (ledger.idempotency_expires_ms == null)) throw new Error("partial Feishu idempotency window");
  if (ledger.idempotency_started_ms != null && ledger.idempotency_expires_ms !== ledger.idempotency_started_ms + IDEMPOTENCY_WINDOW_MS) throw new Error("invalid Feishu idempotency window");
  if (ledger.last_error !== null && typeof ledger.last_error !== "string") throw new Error("invalid Feishu outbound ledger error");
  requireIso(ledger.created_at, "outbound ledger creation time");
  if (ledger.posted_at !== undefined && ledger.posted_at !== null) requireIso(ledger.posted_at, "outbound posted time");
  if (ledger.superseded_at !== undefined && ledger.superseded_at !== null) requireIso(ledger.superseded_at, "outbound superseded time");
  if (ledger.uncertain_at !== undefined && ledger.uncertain_at !== null) requireIso(ledger.uncertain_at, "outbound uncertainty time");
  if (ledger.state === "posted" && (ledger.next_chunk < 1 || ledger.posted_at == null)) throw new Error("posted Feishu outbound ledger lacks durable receipt proof");
  if (ledger.state === "superseded" && ledger.superseded_at == null) throw new Error("superseded Feishu outbound ledger lacks terminal proof");
  if (ledger.state === "delivery_uncertain" && ledger.uncertain_at == null) throw new Error("uncertain Feishu outbound ledger lacks terminal proof");
  if (ledger.state !== "posted" && ledger.posted_at != null) throw new Error("non-posted Feishu outbound ledger has stale receipt proof");
  return ledger;
}

function validateOutboundReceipt(receipt) {
  if (receipt.schema !== OUTBOUND_RECEIPT_SCHEMA) throw new Error("invalid Feishu outbound receipt schema");
  requireString(receipt.event_id, "outbound receipt event", OUTBOUND_EVENT_ID);
  requireSafeInteger(receipt.attempt, "outbound receipt attempt", { min: 1 });
  if (!Array.isArray(receipt.idempotency_keys) || receipt.idempotency_keys.some((key) => typeof key !== "string" || !/^fm[a-f0-9]{44}$/.test(key))) throw new Error("invalid Feishu receipt idempotency keys");
  if (!Array.isArray(receipt.message_ids) || receipt.message_ids.some((id) => typeof id !== "string" || !MESSAGE_ID.test(id))) throw new Error("invalid Feishu receipt message ids");
  requireString(receipt.chat_id, "outbound receipt chat", CHAT_ID);
  requireIso(receipt.posted_at, "outbound receipt time");
  return receipt;
}

function validateOutboundIntent(intent) {
  if (intent.schema !== OUTBOUND_INTENT_SCHEMA || intent.source !== "feishu") throw new Error("invalid Feishu outbound registration intent");
  requireString(intent.intent_id, "outbound intent id", /^reg_[a-f0-9]{40}$/);
  requireString(intent.source_ref, "outbound intent source ref", DELIVERY_REF);
  requireString(intent.session_id, "outbound intent session", SESSION_ID);
  requireString(intent.binding_id, "outbound intent binding", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(intent.binding_generation, "outbound intent generation", { min: 1 });
  requireNullableString(intent.reply_to_message_id, "outbound intent reply", MESSAGE_ID);
  if (typeof intent.decision_captured !== "boolean") throw new Error("invalid Feishu outbound intent decision snapshot");
  requireNullableString(intent.decision_ref, "outbound intent decision ref", /^[A-Za-z0-9._:-]{1,160}$/);
  requireNullableString(intent.decision_key, "outbound intent decision key", /^[A-Za-z0-9._:-]{1,160}$/);
  if ((intent.decision_ref === null) !== (intent.decision_key === null) || (!intent.decision_captured && intent.decision_ref !== null)) throw new Error("partial Feishu outbound intent decision identity");
  if (typeof intent.text !== "string" || intent.text_hash !== `sha256:${sha(intent.text)}`) throw new Error("invalid Feishu outbound intent text");
  requireIso(intent.created_at, "outbound intent creation time");
  return intent;
}

function validateDecision(record) {
  if (record.schema !== DECISION_SCHEMA) throw new Error("invalid Feishu pending decision schema");
  requireString(record.decision_ref, "decision ref", /^[A-Za-z0-9._:-]{1,160}$/);
  requireString(record.decision_key, "decision key", /^[A-Za-z0-9._:-]{1,160}$/);
  requireString(record.session_id, "decision session", SESSION_ID);
  requireSafeInteger(record.binding_generation, "decision generation", { min: 1 });
  if (record.source !== "feishu") throw new Error("invalid Feishu decision source");
  requireString(record.source_ref, "decision source ref", DELIVERY_REF);
  if (!new Set(["awaiting-outbound", "sent-to-outbox", "reply-received", "outbound-skipped", "outbound-refused"]).has(record.state)) throw new Error("invalid Feishu decision state");
  requireIso(record.registered_at, "decision registration time");
  requireNullableString(record.outbound_event_id, "decision outbound event", OUTBOUND_EVENT_ID);
  if (record.terminal_at !== undefined) requireIso(record.terminal_at, "decision terminal time");
  if (record.outbound_outcome !== undefined) requireString(record.outbound_outcome, "decision outbound outcome", /^[a-z-]{1,80}$/);
  if (record.state === "awaiting-outbound" && (record.outbound_event_id !== null || record.terminal_at !== undefined || record.outbound_outcome !== undefined)) throw new Error("awaiting Feishu decision has terminal state");
  if (record.state === "sent-to-outbox" && (!record.outbound_event_id || record.terminal_at !== undefined || record.outbound_outcome !== undefined)) throw new Error("sent Feishu decision lacks exact outbound identity");
  if (record.state === "reply-received") {
    if (!record.outbound_event_id) throw new Error("replied Feishu decision lacks exact outbound identity");
    requireString(record.inbound_delivery_ref, "decision inbound reply", DELIVERY_REF);
    requireString(record.reply_message_id_hash, "decision reply message hash", RECORD_HASH);
    requireIso(record.replied_at, "decision reply time");
  }
  if (new Set(["outbound-skipped", "outbound-refused"]).has(record.state) && (record.outbound_event_id !== null || record.terminal_at === undefined || record.outbound_outcome === undefined)) throw new Error("terminal Feishu decision lacks exact outcome proof");
  return record;
}

function validateRecordAtPath(path, record) {
  const parent = dirname(path).split(/[\\/]/).pop();
  const grandparent = dirname(dirname(path)).split(/[\\/]/).pop();
  if (path.endsWith("/pairing.json")) validatePairingRecord(record);
  else if (parent === "bindings") validateBindingRecord(record);
  else if (parent === "inbox") {
    validateInboundEvent(record);
    if (path.split(/[\\/]/).pop() !== inboundFilename(record.message_id)) throw new Error("Feishu inbound filename identity mismatch");
  } else if (parent === "inbound-ledger") {
    validateInboundLedger(record);
    if (path.split(/[\\/]/).pop() !== inboundFilename(record.message_id)) throw new Error("Feishu inbound ledger filename identity mismatch");
  } else if (parent === "outbox") {
    validateOutbound(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbox filename identity mismatch");
  } else if (parent === "outbound-ledger") {
    validateOutboundLedger(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbound ledger filename identity mismatch");
  } else if (parent === "outbound-receipts") {
    validateOutboundReceipt(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbound receipt filename identity mismatch");
  }
  else if (parent === "pending-decisions") validateDecision(record);
  else if (parent === "outbound-registration-intents") {
    validateOutboundIntent(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.intent_id)}.json`) throw new Error("Feishu outbound intent filename identity mismatch");
  } else if (parent === "inbound-publications") {
    if (record.schema !== "fm-feishu-inbound-publication.v1" || !record.event || !record.ledger) throw new Error("invalid Feishu inbound publication intent");
    validateInboundEvent(record.event);
    validateInboundLedger(record.ledger);
    if (record.event.message_id !== record.ledger.message_id || record.event.delivery_ref !== record.ledger.delivery_ref || record.event.ingress_seq !== record.ledger.ingress_seq) throw new Error("Feishu inbound publication identity mismatch");
    requireIso(record.created_at, "inbound publication time");
    if (path.split(/[\\/]/).pop() !== inboundFilename(record.event.message_id)) throw new Error("Feishu inbound publication filename mismatch");
  } else if (parent === "inbound-delivery-map") {
    if (record.schema !== "fm-feishu-inbound-delivery-map.v1") throw new Error("invalid Feishu inbound delivery map");
    requireString(record.delivery_ref, "inbound delivery map ref", DELIVERY_REF);
    requireString(record.message_id, "inbound delivery map message", MESSAGE_ID);
    requireString(record.filename, "inbound delivery map filename", /^[a-f0-9]{64}\.json$/);
    requireIso(record.recorded_at, "inbound delivery map time");
    if (record.filename !== inboundFilename(record.message_id) || path.split(/[\\/]/).pop() !== `${sha(record.delivery_ref)}.json`) throw new Error("Feishu inbound delivery map identity mismatch");
  } else if (parent === "inbound-pending") {
    if (record.schema !== "fm-feishu-inbound-pending.v1") throw new Error("invalid Feishu inbound pending index");
    requireString(record.message_id, "inbound pending message", MESSAGE_ID);
    requireString(record.delivery_ref, "inbound pending delivery", DELIVERY_REF);
    requireSafeInteger(record.ingress_seq, "inbound pending sequence", { min: 1 });
    requireIso(record.created_at, "inbound pending creation time");
    if (path.split(/[\\/]/).pop() !== inboundFilename(record.message_id)) throw new Error("Feishu inbound pending filename identity mismatch");
  } else if (parent === "pending-decision-open") {
    if (record.schema !== "fm-feishu-pending-decision-index.v1") throw new Error("invalid Feishu pending decision index");
    requireString(record.decision_ref, "pending decision index ref", /^[A-Za-z0-9._:-]{1,160}$/);
    requireString(record.decision_key, "pending decision index key", /^[A-Za-z0-9._:-]{1,160}$/);
    requireString(record.session_id, "pending decision index session", SESSION_ID);
    requireSafeInteger(record.binding_generation, "pending decision index generation", { min: 1 });
    if (record.source !== "feishu") throw new Error("invalid pending decision index source");
    requireString(record.source_ref, "pending decision index source ref", DELIVERY_REF);
    if (!new Set(["awaiting-outbound", "sent-to-outbox"]).has(record.state)) throw new Error("invalid pending decision index state");
    if (path.split(/[\\/]/).pop() !== `${sha(record.decision_ref)}.json`) throw new Error("Feishu pending decision index filename mismatch");
  } else if (parent === "outbound-pending") {
    if (record.schema !== "fm-feishu-outbound-pending.v1") throw new Error("invalid Feishu outbound pending index");
    requireString(record.event_id, "outbound pending event", OUTBOUND_EVENT_ID);
    requireIso(record.created_at, "outbound pending creation time");
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbound pending filename identity mismatch");
  } else if (parent === "outbound-message-map") {
    if (record.schema !== "fm-feishu-outbound-message-map.v1") throw new Error("invalid Feishu outbound message map schema");
    requireString(record.message_id, "outbound map message", MESSAGE_ID);
    if (path.split(/[\\/]/).pop() !== `${sha(record.message_id)}.json`) throw new Error("Feishu outbound map filename identity mismatch");
    requireString(record.event_id, "outbound map event", OUTBOUND_EVENT_ID);
    requireSafeInteger(record.chunk_index, "outbound map chunk index");
    requireNullableString(record.decision_ref, "outbound map decision ref", /^[A-Za-z0-9._:-]{1,160}$/);
    requireNullableString(record.decision_key, "outbound map decision key", /^[A-Za-z0-9._:-]{1,160}$/);
    if ((record.decision_ref === null) !== (record.decision_key === null)) throw new Error("partial Feishu outbound map decision identity");
    requireSafeInteger(record.binding_generation, "outbound map generation", { min: 1 });
    requireIso(record.recorded_at, "outbound map time");
  } else if (parent === "inbound-event-ids") {
    if (record.schema !== "fm-feishu-inbound-event-id.v1") throw new Error("invalid Feishu event-id record schema");
    requireString(record.event_id_hash, "inbound event-id hash", RECORD_HASH);
    requireString(record.message_id_hash, "inbound event message hash", RECORD_HASH);
    requireString(record.delivery_ref, "inbound event delivery ref", DELIVERY_REF);
    requireIso(record.recorded_at, "inbound event-id time");
  } else if (parent === "live-session") {
    if (record.schema !== "fm-feishu-live-session.v1") throw new Error("invalid Feishu live-session schema");
    requireString(record.binding_id, "live binding", /^bind_[a-f0-9]{24}$/);
    requireSafeInteger(record.binding_generation, "live generation", { min: 1 });
    requireString(record.home_id, "live home id", /^home_[a-f0-9]{32}$/);
    requireString(record.fm_home_realpath, "live home path", undefined, 4096);
    requireString(record.session_id, "live session", SESSION_ID);
    requireString(record.session_file_realpath, "live session file", undefined, 4096);
    requireString(record.session_cwd_realpath, "live session cwd", undefined, 4096);
    requireSafeInteger(record.pid, "live owner pid", { min: 2 });
    requireString(record.owner_token, "live owner token", /^pi_[0-9]+_[a-f0-9]{24}$/);
    requireIso(record.claimed_at, "live claim time");
  } else if (path.endsWith("/transport/owner.json")) {
    if (record.schema !== "fm-feishu-transport-owner.v1") throw new Error("invalid Feishu transport owner schema");
    requireSafeInteger(record.pid, "transport owner pid", { min: 2 });
    requireString(record.nonce, "transport nonce", /^[a-f0-9]{24,128}$/);
    requireString(record.module_file, "transport module path", undefined, 4096);
    requireString(record.home_realpath, "transport home path", undefined, 4096);
    requireString(record.process_start_token, "transport process start token", /^[0-9]+$/, 64);
    requireIso(record.started_at, "transport owner start time");
  } else if (path.endsWith("/transport/health.json")) {
    if (record.schema !== TRANSPORT_HEALTH_SCHEMA || !new Set(["starting", "connecting", "healthy", "reconnecting", "degraded", "stopped"]).has(record.phase) || typeof record.healthy !== "boolean") throw new Error("invalid Feishu transport health");
    if (record.owner_pid !== null) requireSafeInteger(record.owner_pid, "transport health owner", { min: 2 });
    requireNullableString(record.owner_nonce, "transport health nonce", /^[a-f0-9]{24,128}$/);
    requireNullableString(record.owner_process_start_token, "transport health process start", /^[0-9]+$/, 64);
    requireNullableString(record.binding_id, "transport health binding", /^bind_[a-f0-9]{24}$/);
    if (record.binding_generation !== null) requireSafeInteger(record.binding_generation, "transport health generation", { min: 1 });
    const ownerPartial = [record.owner_pid, record.owner_nonce, record.owner_process_start_token].filter((value) => value !== null).length;
    const bindingPartial = [record.binding_id, record.binding_generation].filter((value) => value !== null).length;
    if ((ownerPartial !== 0 && ownerPartial !== 3) || (bindingPartial !== 0 && bindingPartial !== 2)) throw new Error("partial Feishu transport health identity");
    if (record.healthy && (record.phase !== "healthy" || ownerPartial !== 3 || bindingPartial !== 2)) throw new Error("unfenced healthy Feishu transport state");
    requireSafeInteger(record.reconnects, "transport reconnect count");
    for (const [key, label] of [["last_connected_at", "connection"], ["last_identity_verified_at", "identity verification"]]) if (record[key] !== null) requireIso(record[key], `transport ${label} time`);
    if (record.last_error_type !== null && typeof record.last_error_type !== "string") throw new Error("invalid Feishu transport health error");
    requireIso(record.updated_at, "transport update time");
  } else if (grandparent === "pending-decisions") validateDecision(record);
  return record;
}

function pairingIsActive(pairing) {
  return pairing?.schema === PAIRING_SCHEMA && pairing.disabled_at === null;
}

function requireSchema(record, schema, label) {
  if (!record || record.schema !== schema) throw new Error(`invalid Feishu ${label} schema`);
  return record;
}

function validatePairingRecord(pairing) {
  if (pairing.schema !== PAIRING_SCHEMA) throw new Error("unsupported Feishu pairing schema");
  requireString(pairing.home_id, "pairing home_id", /^home_[a-f0-9]{32}$/);
  requireString(pairing.fm_home_realpath, "pairing home path", undefined, 4096);
  requireString(pairing.app_id_fingerprint, "pairing app fingerprint", /^sha256:[a-f0-9]{64}$/);
  if (!Array.isArray(pairing.allowed_users) || pairing.allowed_users.length !== 1) throw new Error("invalid Feishu pairing user allowlist");
  if (!Array.isArray(pairing.allowed_chats) || pairing.allowed_chats.length !== 1) throw new Error("invalid Feishu pairing chat allowlist");
  requireString(pairing.allowed_users[0], "pairing allowed user", /^ou_[A-Za-z0-9_-]{4,128}$/);
  requireString(pairing.allowed_chats[0], "pairing allowed chat", /^oc_[A-Za-z0-9_-]{4,128}$/);
  if (pairing.chat_policy !== "p2p-only" || JSON.stringify(pairing.inbound_types) !== JSON.stringify(["text"])) {
    throw new Error("invalid Feishu pairing policy");
  }
  requireIso(pairing.created_at, "pairing creation time");
  requireIso(pairing.updated_at, "pairing update time");
  if (pairing.disabled_at !== null) requireIso(pairing.disabled_at, "pairing disabled time");
  return pairing;
}

function validateBindingRecord(binding) {
  if (binding.schema !== BINDING_SCHEMA) throw new Error("unsupported Feishu binding schema");
  requireString(binding.binding_id, "binding id", /^bind_[a-f0-9]{24}$/);
  requireString(binding.home_id, "binding home_id", /^home_[a-f0-9]{32}$/);
  requireString(binding.fm_home_realpath, "binding home path", undefined, 4096);
  requireString(binding.chat_id, "binding chat", /^oc_[A-Za-z0-9_-]{4,128}$/);
  requireString(binding.session_id, "binding session id", /^[0-9a-fA-F-]{16,128}$/);
  requireString(binding.session_file_realpath, "binding session file", undefined, 4096);
  requireString(binding.session_cwd_realpath, "binding session cwd", undefined, 4096);
  requireString(binding.session_header_id, "binding session header id", /^[0-9a-fA-F-]{16,128}$/);
  requireString(binding.session_header_cwd_realpath, "binding session header cwd", undefined, 4096);
  if (!Number.isSafeInteger(binding.generation) || binding.generation <= 0) throw new Error("invalid Feishu binding generation");
  if (!new Set(["active", "disabled"]).has(binding.status)) throw new Error("invalid Feishu binding status");
  if (binding.thread_policy !== "reply-correlation-only" || binding.bound_by !== "local-tui") throw new Error("invalid Feishu binding policy");
  requireIso(binding.bound_at, "binding time");
  requireNullableString(binding.previous_binding_id, "previous binding id", /^bind_[a-f0-9]{24}$/);
  return binding;
}

function assertConfigurationIdentity(paths, pairing, binding) {
  if (pairing && pairing.fm_home_realpath !== paths.home) throw new Error("Feishu pairing belongs to another canonical home");
  if (binding && binding.fm_home_realpath !== paths.home) throw new Error("Feishu binding belongs to another canonical home");
  if (pairing && binding && (pairing.home_id !== binding.home_id || pairing.allowed_chats[0] !== binding.chat_id)) throw new Error("Feishu pairing and binding identities do not match");
}

export function readPairing(home) {
  const paths = pathsForHome(home);
  const pairing = readJson(paths.pairing, { optional: true });
  if (pairing) assertConfigurationIdentity(paths, pairing, undefined);
  return pairing ? validatePairingRecord(pairing) : undefined;
}

export function readActiveBinding(home) {
  const paths = pathsForHome(home);
  const binding = readJson(paths.activeBinding, { optional: true });
  if (binding) assertConfigurationIdentity(paths, undefined, binding);
  return binding ? validateBindingRecord(binding) : undefined;
}

export function createPairing(home, input) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => {
    const priorRaw = readJson(paths.pairing, { optional: true });
    const prior = priorRaw ? validatePairingRecord(priorRaw) : undefined;
    const homeId = prior?.home_id ?? `home_${randomBytes(16).toString("hex")}`;
    const pairing = {
      schema: PAIRING_SCHEMA,
      home_id: homeId,
      fm_home_realpath: paths.home,
      app_id_fingerprint: requireString(input.appIdFingerprint, "app id fingerprint", /^sha256:[a-f0-9]{64}$/),
      allowed_users: [requireString(input.allowedUser, "allowed user open_id", /^ou_[A-Za-z0-9_-]{4,128}$/)],
      allowed_chats: [requireString(input.allowedChat, "allowed P2P chat_id", /^oc_[A-Za-z0-9_-]{4,128}$/)],
      chat_policy: "p2p-only",
      inbound_types: ["text"],
      created_at: prior?.created_at ?? nowIso(),
      updated_at: nowIso(),
      disabled_at: null,
    };
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    if (binding?.status === "active" && prior?.disabled_at === null) {
      const unchanged = prior.app_id_fingerprint === pairing.app_id_fingerprint &&
        prior.allowed_users[0] === pairing.allowed_users[0] &&
        prior.allowed_chats[0] === pairing.allowed_chats[0];
      if (!unchanged) throw new Error("disable the active Feishu binding before changing its pairing identity");
      return prior;
    }
    atomicJson(paths.pairing, pairing);
    return pairing;
  });
}

export function disablePairing(home) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => {
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    if (!pairing) return { changed: false };
    if (pairing.disabled_at !== null) return { changed: false, pairing };
    const disabled = { ...pairing, updated_at: nowIso(), disabled_at: nowIso() };
    atomicJson(paths.pairing, disabled);
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    if (binding) {
      const retired = { ...binding, status: "disabled", generation: Number(binding.generation) + 1, disabled_at: nowIso() };
      atomicJson(paths.activeBinding, retired);
      atomicJson(join(paths.bindings, `generation-${String(retired.generation).padStart(8, "0")}.json`), retired);
    }
    return { changed: true, pairing: disabled };
  });
}

function validateSessionIdentity(session) {
  const id = requireString(session.sessionId, "Pi session id", /^[0-9a-fA-F-]{16,128}$/);
  const file = realpathSync(requireString(session.sessionFile, "Pi session file", undefined, 4096));
  const cwd = realpathSync(requireString(session.sessionCwd, "Pi session cwd", undefined, 4096));
  const headerId = requireString(session.headerId, "Pi session header id", /^[0-9a-fA-F-]{16,128}$/);
  const headerCwd = realpathSync(requireString(session.headerCwd, "Pi session header cwd", undefined, 4096));
  if (id !== headerId || cwd !== headerCwd) throw new Error("Pi session identity does not match its persisted header");
  return { id, file, cwd, headerId, headerCwd };
}

export function bindSession(home, session, { rebind = false } = {}) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => {
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    if (!pairingIsActive(pairing)) throw new Error("Feishu pairing is not active");
    if (pairing.fm_home_realpath !== paths.home) throw new Error("Feishu pairing belongs to another home path");
    const identity = validateSessionIdentity(session);
    const priorRaw = readJson(paths.activeBinding, { optional: true });
    const prior = priorRaw ? validateBindingRecord(priorRaw) : undefined;
    if (rebind && !prior) throw new Error("no Feishu binding exists to rebind");
    if (!rebind && prior?.status === "active") throw new Error("an active Feishu binding already exists; use rebind explicitly");
    const generation = Number(prior?.generation ?? 0) + 1;
    if (!Number.isSafeInteger(generation) || generation <= 0) throw new Error("invalid Feishu binding generation");
    const bindingId = stableId("bind_", `${pairing.home_id}\0${generation}\0${identity.id}\0${identity.file}`, 24);
    const binding = {
      schema: BINDING_SCHEMA,
      binding_id: bindingId,
      home_id: pairing.home_id,
      fm_home_realpath: paths.home,
      chat_id: pairing.allowed_chats[0],
      thread_policy: "reply-correlation-only",
      session_id: identity.id,
      session_file_realpath: identity.file,
      session_cwd_realpath: identity.cwd,
      session_header_id: identity.headerId,
      session_header_cwd_realpath: identity.headerCwd,
      generation,
      status: "active",
      bound_by: "local-tui",
      bound_at: nowIso(),
      previous_binding_id: prior?.binding_id ?? null,
    };
    const publishBinding = () => {
      atomicJson(join(paths.bindings, `generation-${String(generation).padStart(8, "0")}.json`), binding);
      atomicJson(paths.activeBinding, binding);
    };
    if (rebind) {
      withLock(paths, "inbound-state", () => {
        retargetPendingIngressLocked(paths, binding);
        publishBinding();
      });
    } else {
      publishBinding();
    }
    return binding;
  });
}

function retargetPendingIngressLocked(paths, binding) {
  repairInboundPublicationsLocked(paths);
  const names = safeJsonNames(paths.inboundPending);
  for (const name of names) {
    const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (ledger.state === "offered") throw new Error("cannot rebind while a Feishu message belongs to the current Pi native queue");
  }
  for (const name of names) {
    const path = join(paths.inboundLedger, name);
    const ledger = requireSchema(readJson(path), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (ledger.state !== "pending") continue;
    requireSchema(readJson(join(paths.inbox, name)), INBOUND_SCHEMA, "inbound event");
    atomicJson(path, {
      ...ledger,
      original_binding_id: ledger.original_binding_id ?? ledger.binding_id,
      original_binding_generation: ledger.original_binding_generation ?? ledger.binding_generation,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      target_session_id: binding.session_id,
      retargeted_at: nowIso(),
    });
  }
}

function safeJsonNames(path) {
  if (!existsSync(path)) return [];
  privateDir(path);
  const names = readdirSync(path);
  for (const name of names) {
    if (!/^[a-f0-9]{64}\.json$/.test(name)) throw new Error(`unexpected partial Feishu state artifact: ${join(path, name)}`);
    safeFile(join(path, name));
  }
  return names.sort();
}

function removeIndexedFile(path) {
  if (!existsSync(path)) return false;
  safeFile(path);
  unlinkSync(path);
  fsyncDirectory(dirname(path));
  return true;
}

function writeInboundPendingIndex(paths, name, ledger) {
  atomicJson(join(paths.inboundPending, name), {
    schema: "fm-feishu-inbound-pending.v1",
    message_id: ledger.message_id,
    delivery_ref: ledger.delivery_ref,
    ingress_seq: ledger.ingress_seq,
    created_at: ledger.created_at,
  });
}

function removeInboundPendingIndex(paths, name) {
  return removeIndexedFile(join(paths.inboundPending, name));
}

function writeOutboundPendingIndex(paths, name, outbox) {
  atomicJson(join(paths.outboundPending, name), {
    schema: "fm-feishu-outbound-pending.v1",
    event_id: outbox.event_id,
    created_at: outbox.created_at,
  });
}

function removeOutboundPendingIndex(paths, name) {
  return removeIndexedFile(join(paths.outboundPending, name));
}

function syncInboundPendingCount(paths) {
  const count = safeJsonNames(paths.inboundPending).length;
  atomicWrite(paths.inboundPendingCount, `${count}\n`);
  return count;
}

function writeInboundDeliveryMap(paths, event) {
  const path = join(paths.inboundDeliveryMap, `${sha(event.delivery_ref)}.json`);
  const record = {
    schema: "fm-feishu-inbound-delivery-map.v1",
    delivery_ref: event.delivery_ref,
    message_id: event.message_id,
    filename: inboundFilename(event.message_id),
    recorded_at: event.received_at,
  };
  const prior = readJson(path, { optional: true });
  if (prior && (prior.delivery_ref !== record.delivery_ref || prior.message_id !== record.message_id || prior.filename !== record.filename)) throw new Error("conflicting Feishu inbound delivery map");
  if (!prior) atomicJson(path, record);
}

function readInboundByDeliveryRef(paths, deliveryRef) {
  requireString(deliveryRef, "inbound delivery ref", DELIVERY_REF);
  const map = readJson(join(paths.inboundDeliveryMap, `${sha(deliveryRef)}.json`), { optional: true });
  if (!map) return undefined;
  const event = readJson(join(paths.inbox, map.filename));
  const ledger = readJson(join(paths.inboundLedger, map.filename));
  if (event.delivery_ref !== deliveryRef || ledger.delivery_ref !== deliveryRef || event.message_id !== map.message_id || ledger.message_id !== map.message_id) throw new Error("Feishu inbound delivery lookup mismatch");
  return { name: map.filename, event, ledger };
}

function writePendingDecisionIndex(paths, decision) {
  atomicJson(join(paths.pendingDecisionOpen, `${sha(decision.decision_ref)}.json`), {
    schema: "fm-feishu-pending-decision-index.v1",
    decision_ref: decision.decision_ref,
    decision_key: decision.decision_key,
    session_id: decision.session_id,
    binding_generation: decision.binding_generation,
    source: decision.source,
    source_ref: decision.source_ref,
    state: decision.state,
  });
}

function removePendingDecisionIndex(paths, decisionRef) {
  return removeIndexedFile(join(paths.pendingDecisionOpen, `${sha(decisionRef)}.json`));
}

function repairPendingDecisionIndexesLocked(paths) {
  const expected = new Set();
  let repaired = 0;
  for (const name of safeJsonNames(paths.pendingDecisions)) {
    const decision = readJson(join(paths.pendingDecisions, name));
    if (new Set(["awaiting-outbound", "sent-to-outbox"]).has(decision.state)) {
      expected.add(name);
      const marker = readJson(join(paths.pendingDecisionOpen, name), { optional: true });
      if (!marker || marker.decision_ref !== decision.decision_ref || marker.decision_key !== decision.decision_key || marker.state !== decision.state || marker.source !== decision.source || marker.source_ref !== decision.source_ref) {
        writePendingDecisionIndex(paths, decision);
        repaired += 1;
      }
    } else if (removePendingDecisionIndex(paths, decision.decision_ref)) {
      repaired += 1;
    }
  }
  for (const name of safeJsonNames(paths.pendingDecisionOpen)) if (!expected.has(name)) throw new Error("orphan Feishu pending decision index");
  return repaired;
}

function quarantine(paths, kind, identity, data) {
  const dir = join(paths.quarantine, requireString(kind, "quarantine kind", /^[a-z0-9-]+$/, 80));
  privateDir(dir);
  const key = sha(`${identity}\0${JSON.stringify(data)}`);
  const path = join(dir, `${key}.json`);
  if (!existsSync(path)) {
    atomicJson(path, {
      schema: "fm-feishu-quarantine.v1",
      kind,
      recorded_at: nowIso(),
      data,
    });
  }
  return path;
}

function inboundFilename(messageId) {
  return `${sha(messageId)}.json`;
}

function expectedAuthorizationSnapshot(pairing) {
  return `sha256:${sha(JSON.stringify({
    app: pairing.app_id_fingerprint,
    user: pairing.allowed_users,
    chat: pairing.allowed_chats,
    type: pairing.inbound_types,
    disabled_at: pairing.disabled_at,
  }))}`;
}

function assertInboundPair(paths, name, event, ledger, { pairing, binding } = {}) {
  validateInboundEvent(event);
  validateInboundLedger(ledger);
  if (name !== inboundFilename(event.message_id) || event.message_id !== ledger.message_id || event.source !== ledger.source || event.ingress_seq !== ledger.ingress_seq || event.delivery_ref !== ledger.delivery_ref) {
    throw new Error("Feishu inbound event and ledger identity do not match");
  }
  const retargeted = event.source === "feishu" && ledger.retargeted_at &&
    ledger.original_binding_id === event.binding_id && ledger.original_binding_generation === event.binding_generation;
  if (!retargeted && (event.binding_id !== ledger.binding_id || event.binding_generation !== ledger.binding_generation || event.target_session_id !== ledger.target_session_id)) {
    throw new Error("Feishu inbound event and ledger binding do not match");
  }
  if (pairing && event.source === "feishu") {
    if (event.sender_id !== pairing.allowed_users[0] || event.chat_id !== pairing.allowed_chats[0] || event.message_type !== "text" || event.authorization_snapshot !== expectedAuthorizationSnapshot(pairing)) {
      throw new Error("Feishu inbound authorization snapshot no longer matches its immutable event");
    }
  }
  if (binding && ledger.binding_generation === binding.generation && (ledger.binding_id !== binding.binding_id || ledger.target_session_id !== binding.session_id || (event.source === "feishu" && event.chat_id !== binding.chat_id))) {
    throw new Error("Feishu inbound record does not match the active binding");
  }
  return retargeted;
}

function inboundEventIdExists(paths, eventId) {
  if (typeof eventId !== "string" || eventId.length === 0) return false;
  const path = join(paths.inboundEventIds, `${sha(eventId)}.json`);
  if (!existsSync(path)) return false;
  safeFile(path);
  return true;
}

function recordInboundEventId(paths, eventId, messageId, deliveryRef) {
  if (typeof eventId !== "string" || eventId.length === 0) return;
  const path = join(paths.inboundEventIds, `${sha(eventId)}.json`);
  if (existsSync(path)) {
    const prior = readJson(path);
    if (prior.event_id_hash !== `sha256:${sha(eventId)}` || prior.message_id_hash !== `sha256:${sha(messageId)}` || prior.delivery_ref !== deliveryRef) throw new Error("conflicting Feishu inbound event identity");
    return;
  }
  atomicJson(path, {
    schema: "fm-feishu-inbound-event-id.v1",
    event_id_hash: `sha256:${sha(eventId)}`,
    message_id_hash: `sha256:${sha(messageId)}`,
    delivery_ref: deliveryRef,
    recorded_at: nowIso(),
  });
}

function completeInboundPublicationLocked(paths, name, publication) {
  assertInboundPair(paths, name, publication.event, publication.ledger);
  const eventPath = join(paths.inbox, name);
  const ledgerPath = join(paths.inboundLedger, name);
  const existingEvent = readJson(eventPath, { optional: true });
  if (existingEvent && JSON.stringify(existingEvent) !== JSON.stringify(publication.event)) throw new Error("conflicting immutable Feishu inbound event publication");
  if (!existingEvent) atomicJson(eventPath, publication.event);
  const existingLedger = readJson(ledgerPath, { optional: true });
  if (existingLedger && JSON.stringify(existingLedger) !== JSON.stringify(publication.ledger)) throw new Error("conflicting Feishu inbound ledger publication");
  if (!existingLedger) atomicJson(ledgerPath, publication.ledger);
  writeInboundDeliveryMap(paths, publication.event);
  for (const eventId of publication.event.event_ids) recordInboundEventId(paths, eventId, publication.event.message_id, publication.event.delivery_ref);
  writeInboundPendingIndex(paths, name, publication.ledger);
  syncInboundPendingCount(paths);
  if (publication.event.decision_ref && publication.event.decision_key) {
    withLock(paths, "outbound-state", () => {
      const decisionPath = join(paths.pendingDecisions, `${sha(publication.event.decision_ref)}.json`);
      const pending = readJson(decisionPath, { optional: true });
      if (!pending || pending.decision_key !== publication.event.decision_key) throw new Error("Feishu inbound decision publication lost its exact pending decision");
      if (pending.state === "sent-to-outbox") {
        removePendingDecisionIndex(paths, pending.decision_ref);
        atomicJson(decisionPath, {
          ...pending,
          state: "reply-received",
          inbound_delivery_ref: publication.event.delivery_ref,
          reply_message_id_hash: `sha256:${sha(publication.event.message_id)}`,
          replied_at: nowIso(),
        });
      } else if (pending.state !== "reply-received" || pending.inbound_delivery_ref !== publication.event.delivery_ref || pending.reply_message_id_hash !== `sha256:${sha(publication.event.message_id)}`) {
        throw new Error("Feishu inbound decision publication conflicts with its terminal reply");
      }
      removePendingDecisionIndex(paths, pending.decision_ref);
    });
  }
  removeIndexedFile(join(paths.inboundPublications, name));
}

function publishInboundRecordsLocked(paths, event, ledger) {
  validateInboundEvent(event);
  validateInboundLedger(ledger);
  const name = inboundFilename(event.message_id);
  const publication = {
    schema: "fm-feishu-inbound-publication.v1",
    event,
    ledger,
    created_at: nowIso(),
  };
  const path = join(paths.inboundPublications, name);
  const prior = readJson(path, { optional: true });
  if (prior && JSON.stringify(prior) !== JSON.stringify(publication)) throw new Error("conflicting Feishu inbound publication intent");
  if (!prior) atomicJson(path, publication);
  completeInboundPublicationLocked(paths, name, prior ?? publication);
}

function repairInboundPublicationsLocked(paths) {
  let repaired = 0;
  for (const name of safeJsonNames(paths.inboundPublications)) {
    completeInboundPublicationLocked(paths, name, readJson(join(paths.inboundPublications, name)));
    repaired += 1;
  }
  return repaired;
}

function readInboundPendingCount(paths) {
  safeFile(paths.inboundPendingCount);
  const raw = readFileSync(paths.inboundPendingCount, "utf8");
  if (!/^(0|[1-9][0-9]*)\n$/.test(raw)) throw new Error("malformed Feishu pending-ingress count");
  const count = Number(raw.trim());
  if (!Number.isSafeInteger(count) || count < 0) throw new Error("invalid Feishu pending-ingress count");
  return count;
}

function inboundResourcePressure(paths, options) {
  const maxPending = positiveInteger(options.maxPendingInbound ?? process.env.FM_FEISHU_MAX_PENDING_INBOUND, DEFAULT_MAX_PENDING_INBOUND);
  if (readInboundPendingCount(paths) >= maxPending) return `pending ingress limit ${maxPending} reached`;
  const minFreeBytes = positiveInteger(options.minFreeBytes ?? process.env.FM_FEISHU_MIN_FREE_BYTES, DEFAULT_MIN_FREE_BYTES);
  const stat = statfsSync(paths.stateRoot);
  const freeBytes = Number(stat.bavail) * Number(stat.bsize);
  if (!Number.isFinite(freeBytes) || freeBytes < minFreeBytes) return `free-space floor ${minFreeBytes} reached`;
  return null;
}

function normalizeContent(content) {
  if (typeof content !== "string") throw new Error("message content is not text");
  const bytes = Buffer.from(content, "utf8");
  if (bytes.toString("utf8") !== content) throw new Error("message content is not valid UTF-8");
  return content;
}

function decisionForReply(paths, replyTo, binding) {
  if (!replyTo) return null;
  const map = readJson(join(paths.outboundMessageMap, `${sha(replyTo)}.json`), { optional: true });
  if (!map || map.message_id !== replyTo || map.binding_generation !== binding.generation || !map.decision_ref || !map.decision_key) return null;
  const receipt = readJson(join(paths.outboundReceipts, `${sha(map.event_id)}.json`), { optional: true });
  if (!receipt || receipt.event_id !== map.event_id || !receipt.message_ids.includes(replyTo)) throw new Error("Feishu decision map has no matching durable receipt");
  return { decision_ref: map.decision_ref, decision_key: map.decision_key };
}

function hasPendingDecisionReply(paths, binding) {
  for (const name of safeJsonNames(paths.pendingDecisionOpen)) {
    const marker = readJson(join(paths.pendingDecisionOpen, name));
    if (marker.state === "sent-to-outbox" && marker.binding_generation === binding.generation) return true;
  }
  return false;
}

export function publishFeishuInbound(home, raw, options = {}) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  assertConfigurationIdentity(paths, pairing, binding);
  const audit = {
    event_id: typeof raw?.event_id === "string" ? raw.event_id : null,
    message_id_hash: typeof raw?.message_id === "string" ? sha(raw.message_id) : null,
    sender_id_hash: typeof raw?.sender_id === "string" ? sha(raw.sender_id) : null,
    chat_id_hash: typeof raw?.chat_id === "string" ? sha(raw.chat_id) : null,
    sender_type: raw?.sender_type ?? null,
    chat_type: raw?.chat_type ?? null,
    message_type: raw?.message_type ?? raw?.msg_type ?? null,
  };
  if (!pairingIsActive(pairing) || !binding || binding.schema !== BINDING_SCHEMA || binding.status !== "active") {
    quarantine(paths, "inactive-binding", audit.message_id_hash ?? randomUUID(), audit);
    return { status: "quarantined", reason: "inactive-binding" };
  }
  let messageId;
  try {
    messageId = requireString(raw.message_id ?? raw.id, "message_id", /^om_[A-Za-z0-9_-]{4,128}$/);
  } catch {
    quarantine(paths, "malformed-event", JSON.stringify(audit), audit);
    return { status: "quarantined", reason: "malformed-event" };
  }
  const filename = inboundFilename(messageId);
  if (existsSync(join(paths.inbox, filename)) || inboundEventIdExists(paths, raw.event_id)) {
    return withLock(paths, "inbound-state", () => {
      repairInboundPublicationsLocked(paths);
      return { status: "duplicate", messageIdHash: sha(messageId) };
    });
  }
  const senderId = raw.sender_id;
  const chatId = raw.chat_id;
  const senderType = raw.sender_type;
  const chatType = raw.chat_type;
  const messageType = raw.message_type ?? raw.msg_type;
  let reject;
  if (senderType !== "user") reject = "bot-or-self";
  else if (!pairing.allowed_users.includes(senderId)) reject = "unauthorized-user";
  else if (chatType !== "p2p" || !pairing.allowed_chats.includes(chatId) || chatId !== binding.chat_id) reject = "unauthorized-chat";
  else if (!pairing.inbound_types.includes(messageType)) reject = "unsupported-type";
  let content = "";
  if (!reject) {
    try {
      content = normalizeContent(raw.content ?? raw.text);
      if (content.trim().length === 0) reject = "empty-content";
      const maxBytes = positiveInteger(options.maxInboundBytes ?? process.env.FM_FEISHU_MAX_INBOUND_BYTES, DEFAULT_MAX_INBOUND_BYTES);
      if (Buffer.byteLength(content, "utf8") > maxBytes) reject = "overlength";
    } catch {
      reject = "malformed-content";
    }
  }
  if (reject) {
    quarantine(paths, reject, messageId, { ...audit, message_id_hash: sha(messageId) });
    return { status: "quarantined", reason: reject, messageIdHash: sha(messageId) };
  }
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => {
    repairInboundPublicationsLocked(paths);
    const currentPairingRaw = readJson(paths.pairing, { optional: true });
    const currentBindingRaw = readJson(paths.activeBinding, { optional: true });
    const currentPairing = currentPairingRaw ? validatePairingRecord(currentPairingRaw) : undefined;
    const currentBinding = currentBindingRaw ? validateBindingRecord(currentBindingRaw) : undefined;
    assertConfigurationIdentity(paths, currentPairing, currentBinding);
    if (!pairingIsActive(currentPairing) || !currentBinding || currentBinding.status !== "active") {
      quarantine(paths, "inactive-binding", messageId, { ...audit, message_id_hash: sha(messageId) });
      return { status: "quarantined", reason: "inactive-binding", messageIdHash: sha(messageId) };
    }
    const fence = options.bindingFence;
    if (fence && (
      currentBinding.binding_id !== fence.bindingId ||
      currentBinding.generation !== fence.bindingGeneration ||
      currentBinding.session_id !== fence.sessionId ||
      currentBinding.chat_id !== fence.chatId
    )) throw new Error("Feishu SDK callback binding generation changed before durable publication");
    if (!currentPairing.allowed_users.includes(senderId) || chatType !== "p2p" || !currentPairing.allowed_chats.includes(chatId) || chatId !== currentBinding.chat_id) {
      quarantine(paths, "authorization-changed", messageId, { ...audit, message_id_hash: sha(messageId) });
      return { status: "quarantined", reason: "authorization-changed", messageIdHash: sha(messageId) };
    }
    if (existsSync(join(paths.inbox, filename)) || inboundEventIdExists(paths, raw.event_id)) {
      return { status: "duplicate", messageIdHash: sha(messageId) };
    }
    const pressure = inboundResourcePressure(paths, options);
    if (pressure) {
      quarantine(paths, "resource-pressure", messageId, { ...audit, message_id_hash: sha(messageId), pressure });
      createLocalAlert(paths, "inbound-resource-pressure", stableId("in_", messageId, 24), "Feishu ingress stopped at its local queue or disk-space safety threshold. Reconcile local capacity before reconnecting.");
      return { status: "quarantined", reason: "resource-pressure", messageIdHash: sha(messageId) };
    }
    const ingressSeq = nextSequence(paths);
    const deliveryRef = stableId("in_", `${currentPairing.home_id}\0${messageId}`, 24);
    const replyTo = typeof raw.reply_to === "string" && /^om_[A-Za-z0-9_-]{4,128}$/.test(raw.reply_to) ? raw.reply_to : null;
    const decision = decisionForReply(paths, replyTo, currentBinding);
    const event = {
      schema: INBOUND_SCHEMA,
      source: "feishu",
      message_id: messageId,
      event_ids: typeof raw.event_id === "string" ? [raw.event_id] : [],
      transport: options.transport ?? "lark-websocket",
      sender_id: senderId,
      sender_type: senderType,
      chat_id: chatId,
      chat_type: chatType,
      reply_to: replyTo,
      root_id: typeof raw.root_id === "string" ? raw.root_id : null,
      thread_id: typeof raw.thread_id === "string" ? raw.thread_id : null,
      message_type: messageType,
      text: content,
      create_time_ms: Number(raw.create_time ?? raw.create_time_ms ?? 0) || 0,
      update_time_ms: Number(raw.update_time ?? 0) || null,
      received_at: nowIso(),
      payload_hash: `sha256:${sha(JSON.stringify(raw))}`,
      binding_id: currentBinding.binding_id,
      binding_generation: currentBinding.generation,
      authorization_snapshot: expectedAuthorizationSnapshot(currentPairing),
      target_session_id: currentBinding.session_id,
      ingress_seq: ingressSeq,
      delivery_ref: deliveryRef,
      decision_ref: decision?.decision_ref ?? null,
      decision_key: decision?.decision_key ?? null,
      decision_reply: decision ? "exact" : hasPendingDecisionReply(paths, currentBinding) ? "unrelated" : "none",
    };
    const ledger = {
      schema: INBOUND_LEDGER_SCHEMA,
      source: "feishu",
      message_id: messageId,
      ingress_seq: ingressSeq,
      state: "pending",
      attempt: 0,
      target_session_id: currentBinding.session_id,
      binding_id: currentBinding.binding_id,
      binding_generation: currentBinding.generation,
      delivery_ref: deliveryRef,
      last_error: null,
      created_at: nowIso(),
    };
    publishInboundRecordsLocked(paths, event, ledger);
    return { status: "published", ingressSeq, deliveryRef, messageIdHash: sha(messageId) };
  }));
}

function deliveryEventForLedger(event, ledger) {
  if (!ledger.retargeted_at) return event;
  return {
    ...event,
    binding_id: ledger.binding_id,
    binding_generation: ledger.binding_generation,
    target_session_id: ledger.target_session_id,
  };
}

function repairInboundLedgersLocked(paths) {
  let repaired = repairInboundPublicationsLocked(paths);
  const validDeliveryMaps = new Set();
  for (const name of safeJsonNames(paths.inbox)) {
    const ledgerPath = join(paths.inboundLedger, name);
    const event = requireSchema(readJson(join(paths.inbox, name)), INBOUND_SCHEMA, "inbound event");
    validDeliveryMaps.add(`${sha(event.delivery_ref)}.json`);
    writeInboundDeliveryMap(paths, event);
    for (const eventId of event.event_ids) recordInboundEventId(paths, eventId, event.message_id, event.delivery_ref);
    if (existsSync(ledgerPath)) continue;
    atomicJson(ledgerPath, {
      schema: INBOUND_LEDGER_SCHEMA,
      source: "feishu",
      message_id: event.message_id,
      ingress_seq: event.ingress_seq,
      state: "pending",
      attempt: 0,
      target_session_id: event.target_session_id,
      binding_id: event.binding_id,
      binding_generation: event.binding_generation,
      delivery_ref: event.delivery_ref,
      last_error: "ledger repaired after interrupted publish",
      created_at: nowIso(),
    });
    repaired += 1;
  }
  let pending = 0;
  const indexed = new Set(safeJsonNames(paths.inboundPending));
  for (const name of safeJsonNames(paths.inboundLedger)) {
    const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    const event = requireSchema(readJson(join(paths.inbox, name)), INBOUND_SCHEMA, "inbound event");
    assertInboundPair(paths, name, event, ledger);
    if (new Set(["pending", "offered"]).has(ledger.state)) {
      writeInboundPendingIndex(paths, name, ledger);
      indexed.delete(name);
      pending += 1;
    } else if (removeInboundPendingIndex(paths, name)) {
      indexed.delete(name);
      repaired += 1;
    }
  }
  for (const name of indexed) {
    removeInboundPendingIndex(paths, name);
    repaired += 1;
  }
  for (const name of safeJsonNames(paths.inboundDeliveryMap)) if (!validDeliveryMaps.has(name)) throw new Error("orphan Feishu inbound delivery map");
  atomicWrite(paths.inboundPendingCount, `${pending}\n`);
  return repaired;
}

export function repairInboundLedgers(home) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => repairInboundLedgersLocked(paths));
}

export function pendingFeishuIngress(home, fence) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => {
    repairInboundLedgersLocked(paths);
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    assertConfigurationIdentity(paths, pairing, binding);
    if (!pairingIsActive(pairing) || !binding || binding.status !== "active" || binding.session_id !== fence.sessionId || binding.binding_id !== fence.bindingId || binding.generation !== fence.bindingGeneration) return [];
    const pending = [];
    for (const name of safeJsonNames(paths.inboundPending)) {
      const ledger = readJson(join(paths.inboundLedger, name));
      if (ledger.state !== "pending" || ledger.target_session_id !== fence.sessionId || ledger.binding_id !== fence.bindingId || ledger.binding_generation !== fence.bindingGeneration) continue;
      const event = readJson(join(paths.inbox, name));
      assertInboundPair(paths, name, event, ledger, { pairing, binding });
      pending.push({ filename: name, event: deliveryEventForLedger(event, ledger), ledger });
    }
    return pending.sort((a, b) => a.ledger.ingress_seq - b.ledger.ingress_seq || a.filename.localeCompare(b.filename));
  }));
}

export function offerFeishuIngress(home, deliveryRef, fence) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => {
    repairInboundLedgersLocked(paths);
    const binding = readJson(paths.activeBinding, { optional: true });
    if (!binding || binding.status !== "active" || binding.session_id !== fence.sessionId || binding.binding_id !== fence.bindingId || binding.generation !== fence.bindingGeneration) throw new Error("Feishu native-queue offer binding fence mismatch");
    const found = readInboundByDeliveryRef(paths, deliveryRef);
    if (!found || found.ledger.state !== "pending") return undefined;
    if (found.ledger.target_session_id !== fence.sessionId || found.ledger.binding_id !== fence.bindingId || found.ledger.binding_generation !== fence.bindingGeneration) throw new Error("Feishu native-queue offer event fence mismatch");
    const ledger = {
      ...found.ledger,
      state: "offered",
      attempt: found.ledger.attempt + 1,
      offered_at: nowIso(),
      last_error: null,
    };
    atomicJson(join(paths.inboundLedger, found.name), ledger);
    return { filename: found.name, event: deliveryEventForLedger(found.event, ledger), ledger };
  }));
}

export function releaseFeishuIngressOffer(home, deliveryRef, error) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    const found = readInboundByDeliveryRef(paths, deliveryRef);
    if (!found || found.ledger.state !== "offered") return false;
    atomicJson(join(paths.inboundLedger, found.name), {
      ...found.ledger,
      state: "pending",
      offered_at: null,
      last_error: String(error).slice(0, 500),
      released_at: nowIso(),
    });
    return true;
  });
}

export function reconcileFeishuIngress(home, markers, fence, resetUnobservedOffers = false) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    repairInboundLedgersLocked(paths);
    const markerByRef = new Map();
    for (const marker of markers) {
      if (marker.sessionId === fence.sessionId && marker.bindingGeneration === fence.bindingGeneration) markerByRef.set(marker.deliveryRef, marker);
    }
    let repaired = 0;
    for (const name of safeJsonNames(paths.inboundPending)) {
      const path = join(paths.inboundLedger, name);
      const ledger = readJson(path);
      const marker = markerByRef.get(ledger.delivery_ref);
      if (marker && ledger.target_session_id === fence.sessionId && ledger.binding_generation === fence.bindingGeneration) {
        atomicJson(path, { ...ledger, state: "delivered", offered_at: null, delivered_at: nowIso(), last_error: null });
        removeInboundPendingIndex(paths, name);
        repaired += 1;
        continue;
      }
      if (resetUnobservedOffers && ledger.state === "offered" && ledger.target_session_id === fence.sessionId && ledger.binding_generation === fence.bindingGeneration) {
        atomicJson(path, { ...ledger, state: "pending", offered_at: null, last_error: "prior Pi process ended before the native queue offer reached persisted session history" });
        repaired += 1;
      }
    }
    syncInboundPendingCount(paths);
    return repaired;
  });
}

export function findInboundByDeliveryRef(home, deliveryRef) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    repairInboundPublicationsLocked(paths);
    const found = readInboundByDeliveryRef(paths, deliveryRef);
    return found ? deliveryEventForLedger(found.event, found.ledger) : undefined;
  });
}

export function claimLiveSession(home, binding, session, ownerToken) {
  const paths = ensurePrivateLayout(home);
  const path = join(paths.liveSession, `${sha(binding.binding_id)}.json`);
  return withLock(paths, "live-session", () => {
    const prior = readJson(path, { optional: true });
    if (prior && prior.owner_token !== ownerToken && pidAlive(prior.pid)) {
      return { ok: false, reason: "another identity-matched live Pi owns this binding" };
    }
    const record = {
      schema: "fm-feishu-live-session.v1",
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      home_id: binding.home_id,
      fm_home_realpath: paths.home,
      session_id: session.sessionId,
      session_file_realpath: session.sessionFile,
      session_cwd_realpath: session.sessionCwd,
      pid: process.pid,
      owner_token: ownerToken,
      claimed_at: nowIso(),
    };
    atomicJson(path, record);
    return { ok: true, record };
  });
}

export function releaseLiveSession(home, bindingId, ownerToken) {
  const paths = pathsForHome(home);
  privateDir(paths.liveSession);
  const path = join(paths.liveSession, `${sha(bindingId)}.json`);
  return withLock(paths, "live-session", () => {
    const record = readJson(path, { optional: true });
    if (!record || record.owner_token !== ownerToken || record.pid !== process.pid) return false;
    unlinkSync(path);
    fsyncDirectory(paths.liveSession);
    return true;
  });
}

export function ingressCounts(home) {
  const paths = ensurePrivateLayout(home);
  const counts = { pending: 0, queued: 0, delivered: 0, other: 0 };
  for (const name of safeJsonNames(paths.inboundLedger)) {
    const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (ledger.state === "pending") counts.pending += 1;
    else if (ledger.state === "offered") counts.queued += 1;
    else if (ledger.state === "delivered") counts.delivered += 1;
    else counts.other += 1;
  }
  return counts;
}

const SECRET_PATTERNS = [
  /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/i,
  /\bAuthorization\s*:\s*(?:Bearer|Basic)\s+[^\s]+/i,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/,
  /\bsk-[A-Za-z0-9_-]{16,}\b/,
  /\b(?:access[_-]?token|refresh[_-]?token|app[_-]?secret|api[_-]?key|client[_-]?secret|credential|password)\s*[:=]\s*["']?[A-Za-z0-9._~+/=-]{8,}/i,
];

export function assistantSecretPattern(text) {
  for (let index = 0; index < SECRET_PATTERNS.length; index += 1) {
    if (SECRET_PATTERNS[index].test(text)) return `fixed-pattern-${index + 1}`;
  }
  return null;
}

function utf8Bytes(text) {
  return Buffer.byteLength(text, "utf8");
}

function splitAtomicToken(token, maxBytes) {
  if (utf8Bytes(token) <= maxBytes) return [token];
  if (/https?:\/\/\S+/.test(token)) throw new Error("a complete URL exceeds the Feishu chunk size");
  const chunks = [];
  let current = "";
  for (const character of token) {
    if (current && utf8Bytes(current + character) > maxBytes) {
      chunks.push(current);
      current = character;
    } else {
      current += character;
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

function splitUnit(unit, maxBytes) {
  if (utf8Bytes(unit) <= maxBytes) return [unit];
  const lines = unit.split(/(?<=\n)/u);
  if (lines.length > 1) return packUnits(lines.flatMap((line) => splitUnit(line, maxBytes)), maxBytes);
  const tokens = unit.match(/https?:\/\/\S+|\s+|[^\s]+/gu) ?? [unit];
  return packUnits(tokens.flatMap((token) => splitAtomicToken(token, maxBytes)), maxBytes);
}

function packUnits(units, maxBytes) {
  const chunks = [];
  let current = "";
  for (const unit of units) {
    if (utf8Bytes(unit) > maxBytes) throw new Error("unbreakable Feishu output unit exceeds platform size");
    if (current && utf8Bytes(current + unit) > maxBytes) {
      chunks.push(current);
      current = unit;
    } else {
      current += unit;
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

export function deterministicChunks(text, maxBytes = DEFAULT_MAX_OUTBOUND_CHUNK_BYTES) {
  maxBytes = positiveInteger(maxBytes, DEFAULT_MAX_OUTBOUND_CHUNK_BYTES);
  if (utf8Bytes(text) <= maxBytes) return [text];
  const paragraphs = text.split(/(?<=\n\n)/u);
  const chunks = packUnits(paragraphs.flatMap((paragraph) => splitUnit(paragraph, maxBytes)), maxBytes);
  if (chunks.join("") !== text) throw new Error("Feishu chunking changed Assistant text");
  return chunks;
}

function createLocalAlert(paths, kind, eventId, message) {
  const id = stableId("alert_", `${kind}\0${eventId}`, 24);
  const path = join(paths.alerts, `${sha(id)}.json`);
  if (existsSync(path)) return { id, created: false };
  atomicJson(path, {
    schema: "fm-feishu-local-alert.v1",
    alert_id: id,
    kind,
    event_id: eventId,
    message,
    created_at: nowIso(),
    acknowledged_at: null,
  });
  return { id, created: true };
}

function newOutboundLedger(outbox, patch = {}) {
  return {
    schema: OUTBOUND_LEDGER_SCHEMA,
    event_id: outbox.event_id,
    state: "pending",
    next_chunk: 0,
    attempts: 0,
    retry_at_ms: 0,
    binding_generation: outbox.binding_generation,
    created_at: outbox.created_at,
    last_error: null,
    idempotency_started_ms: null,
    idempotency_expires_ms: null,
    ...patch,
  };
}

function outboundEventId(homeId, input) {
  return stableId("out_", `${homeId}\0${input.bindingGeneration}\0${input.sessionId}\0${input.sourceRef}\0${sha(input.text)}\0${input.replyTo ?? "chat"}`, 40);
}

function outboundLogicalQueueCount(paths, pairing) {
  const pending = new Set(safeJsonNames(paths.outboundPending));
  let count = pending.size;
  for (const name of safeJsonNames(paths.outboundRegistrationIntents)) {
    const intent = readJson(join(paths.outboundRegistrationIntents, name));
    const eventId = outboundEventId(pairing.home_id, {
      bindingGeneration: intent.binding_generation,
      sessionId: intent.session_id,
      sourceRef: intent.source_ref,
      text: intent.text,
      replyTo: intent.reply_to_message_id,
    });
    if (!pending.has(`${sha(eventId)}.json`)) count += 1;
  }
  return count;
}

function maxPendingOutbound(input = {}) {
  return positiveInteger(input.maxPendingOutbound ?? process.env.FM_FEISHU_MAX_PENDING_OUTBOUND, DEFAULT_MAX_PENDING_OUTBOUND);
}

function assertOutboundPair(name, outbox, ledger, binding) {
  validateOutbound(outbox);
  validateOutboundLedger(ledger);
  if (name !== `${sha(outbox.event_id)}.json` || ledger.event_id !== outbox.event_id || ledger.binding_generation !== outbox.binding_generation || ledger.next_chunk > outbox.chunks.length) throw new Error("Feishu outbox and ledger identity do not match");
  if (binding && outbox.binding_generation === binding.generation && (outbox.binding_id !== binding.binding_id || outbox.session_id !== binding.session_id || outbox.destination_chat_id !== binding.chat_id)) throw new Error("Feishu outbox destination does not match the active binding");
}

function writeOutboundMessageMap(paths, outbox, messageId, chunkIndex) {
  const path = join(paths.outboundMessageMap, `${sha(messageId)}.json`);
  const record = {
    schema: "fm-feishu-outbound-message-map.v1",
    message_id: messageId,
    event_id: outbox.event_id,
    chunk_index: chunkIndex,
    decision_ref: outbox.decision_ref,
    decision_key: outbox.decision_key,
    binding_generation: outbox.binding_generation,
    recorded_at: nowIso(),
  };
  const prior = readJson(path, { optional: true });
  if (prior && (prior.message_id !== record.message_id || prior.event_id !== record.event_id || prior.chunk_index !== record.chunk_index || prior.decision_ref !== record.decision_ref || prior.decision_key !== record.decision_key || prior.binding_generation !== record.binding_generation)) throw new Error("conflicting Feishu outbound correlation map");
  if (!prior) atomicJson(path, record);
}

function reconcileOutboundReceiptLocked(paths, name, outbox, ledger) {
  const receipt = readJson(join(paths.outboundReceipts, name), { optional: true });
  const receivedChunks = receipt?.message_ids.length ?? 0;
  let repaired = 0;
  if (receipt) {
    if (receipt.event_id !== outbox.event_id || receipt.chat_id !== outbox.destination_chat_id || receipt.idempotency_keys.length !== outbox.chunks.length || receipt.idempotency_keys.some((key, index) => key !== outbox.chunks[index].idempotency_key) || receivedChunks > outbox.chunks.length) throw new Error("Feishu outbound receipt does not match its immutable outbox");
    for (let index = 0; index < receivedChunks; index += 1) {
      if (!existsSync(join(paths.outboundMessageMap, `${sha(receipt.message_ids[index])}.json`))) repaired += 1;
      writeOutboundMessageMap(paths, outbox, receipt.message_ids[index], index);
    }
  }
  if (ledger.state === "posted" && (!receipt || receivedChunks !== outbox.chunks.length || ledger.next_chunk !== outbox.chunks.length)) throw new Error("posted Feishu outbound ledger has no complete durable receipt");
  if (ledger.next_chunk > receivedChunks) throw new Error("Feishu outbound ledger advances beyond its durable receipt");
  if (receivedChunks > ledger.next_chunk || (receivedChunks === outbox.chunks.length && ledger.state !== "posted")) {
    const { attempt_id: _attemptId, last_attempt_ms: _lastAttemptMs, ...rest } = ledger;
    const updated = {
      ...rest,
      state: receivedChunks === outbox.chunks.length ? "posted" : "pending",
      next_chunk: receivedChunks,
      retry_at_ms: 0,
      last_error: null,
      idempotency_started_ms: null,
      idempotency_expires_ms: null,
      posted_at: receivedChunks === outbox.chunks.length ? receipt.posted_at : null,
    };
    atomicJson(join(paths.outboundLedger, name), updated);
    return { ledger: updated, receipt, repaired: repaired + 1 };
  }
  return { ledger, receipt, repaired };
}

function repairOutboundStateLocked(paths, binding) {
  assertConfigurationIdentity(paths, undefined, binding);
  let repaired = repairPendingDecisionIndexesLocked(paths);
  const outboxNames = safeJsonNames(paths.outbox);
  const outboxSet = new Set(outboxNames);
  for (const name of safeJsonNames(paths.outboundLedger)) if (!outboxSet.has(name)) throw new Error("orphan Feishu outbound ledger");
  for (const name of safeJsonNames(paths.outboundReceipts)) if (!outboxSet.has(name)) throw new Error("orphan Feishu outbound receipt");
  const validMapNames = new Set();
  for (const name of outboxNames) {
    const outbox = readJson(join(paths.outbox, name));
    const ledgerPath = join(paths.outboundLedger, name);
    let ledger = readJson(ledgerPath, { optional: true });
    if (!ledger) {
      ledger = newOutboundLedger(outbox);
      atomicJson(ledgerPath, ledger);
      repaired += 1;
    }
    assertOutboundPair(name, outbox, ledger, binding);
    const reconciliation = reconcileOutboundReceiptLocked(paths, name, outbox, ledger);
    ledger = reconciliation.ledger;
    repaired += reconciliation.repaired;
    for (const messageId of reconciliation.receipt?.message_ids ?? []) validMapNames.add(`${sha(messageId)}.json`);
    if (["pending", "retryable", "sending"].includes(ledger.state)) writeOutboundPendingIndex(paths, name, outbox);
    else if (removeOutboundPendingIndex(paths, name)) repaired += 1;
  }
  const outboxPendingSet = new Set(outboxNames);
  for (const name of safeJsonNames(paths.outboundPending)) {
    if (outboxPendingSet.has(name)) continue;
    removeOutboundPendingIndex(paths, name);
    repaired += 1;
  }
  for (const name of safeJsonNames(paths.outboundMessageMap)) if (!validMapNames.has(name)) throw new Error("orphan Feishu outbound correlation map");
  return repaired;
}

export function repairOutboundState(home) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "outbound-state", () => {
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    return repairOutboundStateLocked(paths, binding);
  });
}

export function persistAssistantOutboundIntent(home, input) {
  const paths = pathsForHome(home);
  privateDir(paths.stateRoot);
  privateDir(paths.outboundPending);
  privateDir(paths.outboundRegistrationIntents);
  privateDir(paths.alerts);
  const source = requireString(input.source, "outbound intent source", /^feishu$/);
  const sourceRef = requireString(input.sourceRef, "outbound intent source ref", DELIVERY_REF);
  const text = typeof input.text === "string" ? input.text : "";
  const replyTo = input.replyTo ?? null;
  requireNullableString(replyTo, "outbound intent reply", MESSAGE_ID);
  return withLock(paths, "outbound-state", () => {
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    if (!pairingIsActive(pairing) || !binding || binding.status !== "active" || binding.session_id !== input.sessionId || binding.generation !== input.bindingGeneration) throw new Error("outbound registration intent does not match the active binding");
    const intentId = stableId("reg_", `${binding.binding_id}\0${binding.generation}\0${input.sessionId}\0${source}\0${sourceRef}\0${sha(text)}\0${replyTo ?? "chat"}`, 40);
    const secretPattern = assistantSecretPattern(text);
    if (secretPattern) {
      quarantine(paths, "outbound-secret-refused", intentId, { intent_id: intentId, pattern: secretPattern, text_hash: `sha256:${sha(text)}`, bytes: utf8Bytes(text) });
      const alert = createLocalAlert(paths, "outbound-secret-refused", intentId, "A final Assistant response matched a fixed credential pattern. The entire response stayed local; inspect it in the TUI before deciding what to send.");
      return { status: "secret-refused", pattern: secretPattern, alert };
    }
    const record = {
      schema: OUTBOUND_INTENT_SCHEMA,
      intent_id: intentId,
      source,
      source_ref: sourceRef,
      session_id: input.sessionId,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      reply_to_message_id: replyTo,
      decision_captured: false,
      decision_ref: null,
      decision_key: null,
      text,
      text_hash: `sha256:${sha(text)}`,
      created_at: nowIso(),
    };
    validateOutboundIntent(record);
    const path = join(paths.outboundRegistrationIntents, `${sha(intentId)}.json`);
    const prior = readJson(path, { optional: true });
    if (prior) {
      if (JSON.stringify({ ...prior, created_at: record.created_at }) !== JSON.stringify(record)) throw new Error("conflicting Feishu outbound registration intent");
      return prior;
    }
    const free = statfsSync(paths.stateRoot);
    const freeBytes = Number(free.bavail) * Number(free.bsize);
    const maxBytes = positiveInteger(input.maxOutboundBytes ?? process.env.FM_FEISHU_MAX_OUTBOUND_BYTES, DEFAULT_MAX_OUTBOUND_BYTES);
    const minFreeBytes = positiveInteger(process.env.FM_FEISHU_MIN_FREE_BYTES, DEFAULT_MIN_FREE_BYTES);
    if (utf8Bytes(text) > maxBytes || !Number.isFinite(freeBytes) || freeBytes < minFreeBytes) {
      const alert = createLocalAlert(paths, "outbound-resource-refused", intentId, "A final Assistant response exceeded the local outbound resource policy or free-space floor. The entire response stayed local.");
      return { status: "resource-refused", reason: "resource-limit", alert };
    }
    if (outboundLogicalQueueCount(paths, pairing) >= maxPendingOutbound(input)) {
      const alert = createLocalAlert(paths, "outbound-queue-refused", intentId, "A final Assistant response reached the bounded Feishu outbound queue. The entire response stayed local until capacity is reconciled.");
      return { status: "resource-refused", reason: "queue-limit", alert };
    }
    atomicJson(path, record);
    return record;
  });
}

export function readAssistantOutboundIntents(home, fence) {
  const paths = pathsForHome(home);
  privateDir(paths.outboundRegistrationIntents);
  const records = [];
  for (const name of safeJsonNames(paths.outboundRegistrationIntents)) {
    const record = readJson(join(paths.outboundRegistrationIntents, name));
    if (record.session_id !== fence.sessionId || record.binding_generation !== fence.bindingGeneration || record.binding_id !== fence.bindingId) continue;
    records.push({ name, record });
  }
  records.sort((a, b) => a.record.created_at.localeCompare(b.record.created_at) || a.name.localeCompare(b.name));
  return records;
}

export function bindAssistantOutboundIntentDecision(home, candidate, decision) {
  const paths = pathsForHome(home);
  privateDir(paths.outboundRegistrationIntents);
  return withLock(paths, "outbound-state", () => {
    const path = join(paths.outboundRegistrationIntents, candidate.name);
    const current = readJson(path);
    const decisionRef = decision?.record.decision_ref ?? null;
    const decisionKey = decision?.record.decision_key ?? null;
    if (current.decision_captured) {
      if (current.decision_ref !== decisionRef || current.decision_key !== decisionKey) throw new Error("conflicting Feishu outbound intent decision snapshot");
      return { name: candidate.name, record: current };
    }
    const updated = { ...current, decision_captured: true, decision_ref: decisionRef, decision_key: decisionKey };
    atomicJson(path, updated);
    return { name: candidate.name, record: updated };
  });
}

export function completeAssistantOutboundIntent(home, candidate) {
  const paths = pathsForHome(home);
  privateDir(paths.outboundRegistrationIntents);
  if (!candidate || !/^[a-f0-9]{64}\.json$/.test(candidate.name)) throw new Error("invalid Feishu outbound intent completion");
  return withLock(paths, "outbound-state", () => {
    const path = join(paths.outboundRegistrationIntents, candidate.name);
    const current = readJson(path, { optional: true });
    if (!current) return false;
    if (current.intent_id !== candidate.record.intent_id || current.text_hash !== candidate.record.text_hash) throw new Error("Feishu outbound intent completion mismatch");
    return removeIndexedFile(path);
  });
}

export function registerAssistantOutbound(home, input) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  assertConfigurationIdentity(paths, pairing, binding);
  if (!pairingIsActive(pairing) || !binding || binding.status !== "active") return { status: "inactive" };
  if (binding.session_id !== input.sessionId || binding.generation !== input.bindingGeneration) return { status: "stale-binding" };
  if (input.source !== "feishu") throw new Error("Feishu outbound requires an exact Feishu source turn");
  const text = typeof input.text === "string" ? input.text : "";
  if (text.trim().length === 0) return { status: "skipped", reason: "empty" };
  if (text === "Captain, shipshape.") return { status: "skipped", reason: "routine" };
  const eventId = outboundEventId(pairing.home_id, {
    bindingGeneration: binding.generation,
    sessionId: input.sessionId,
    sourceRef: input.sourceRef,
    text,
    replyTo: input.replyTo,
  });
  const maxOutboundBytes = positiveInteger(input.maxOutboundBytes ?? process.env.FM_FEISHU_MAX_OUTBOUND_BYTES, DEFAULT_MAX_OUTBOUND_BYTES);
  const minFreeBytes = positiveInteger(process.env.FM_FEISHU_MIN_FREE_BYTES, DEFAULT_MIN_FREE_BYTES);
  const free = statfsSync(paths.stateRoot);
  const freeBytes = Number(free.bavail) * Number(free.bsize);
  if (utf8Bytes(text) > maxOutboundBytes || !Number.isFinite(freeBytes) || freeBytes < minFreeBytes) {
    const alert = createLocalAlert(paths, "outbound-resource-refused", eventId, "A final Assistant response exceeded the local outbound resource policy or free-space floor. The entire response stayed local.");
    return { status: "resource-refused", alert };
  }
  const pattern = assistantSecretPattern(text);
  if (pattern) {
    quarantine(paths, "outbound-secret-refused", eventId, { event_id: eventId, pattern, text_hash: `sha256:${sha(text)}`, bytes: utf8Bytes(text) });
    const alert = createLocalAlert(paths, "outbound-secret-refused", eventId, "A final Assistant response matched a fixed credential pattern. The entire response stayed local; inspect it in the TUI before deciding what to send.");
    return { status: "secret-refused", pattern, alert };
  }
  let chunks;
  try {
    chunks = deterministicChunks(text, input.maxChunkBytes ?? process.env.FM_FEISHU_MAX_OUTBOUND_CHUNK_BYTES);
  } catch (error) {
    const alert = createLocalAlert(paths, "outbound-chunk-refused", eventId, "A final Assistant response could not be split without changing a complete URL. It stayed local.");
    return { status: "chunk-refused", error: String(error), alert };
  }
  const filename = `${sha(eventId)}.json`;
  return withLock(paths, "outbound-state", () => {
    if (existsSync(join(paths.outbox, filename))) {
      const outbox = readJson(join(paths.outbox, filename));
      let ledger = readJson(join(paths.outboundLedger, filename), { optional: true });
      if (!ledger) {
        ledger = newOutboundLedger(outbox, { last_error: "ledger repaired by exact registration retry" });
        atomicJson(join(paths.outboundLedger, filename), ledger);
      }
      assertOutboundPair(filename, outbox, ledger, binding);
      ledger = reconcileOutboundReceiptLocked(paths, filename, outbox, ledger).ledger;
      if (["pending", "retryable", "sending"].includes(ledger.state)) writeOutboundPendingIndex(paths, filename, outbox);
      else removeOutboundPendingIndex(paths, filename);
      return { status: "duplicate", eventId };
    }
    let transferringIntent = false;
    if (input.registrationIntentId) {
      const intent = readJson(join(paths.outboundRegistrationIntents, `${sha(input.registrationIntentId)}.json`), { optional: true });
      transferringIntent = Boolean(intent && intent.intent_id === input.registrationIntentId && intent.source === input.source && intent.source_ref === input.sourceRef && intent.session_id === input.sessionId && intent.binding_generation === input.bindingGeneration && intent.text_hash === `sha256:${sha(text)}` && intent.reply_to_message_id === (input.replyTo ?? null));
      if (!transferringIntent) throw new Error("outbound registration does not match its durable intent");
    }
    if (!transferringIntent && outboundLogicalQueueCount(paths, pairing) >= maxPendingOutbound(input)) {
      const alert = createLocalAlert(paths, "outbound-queue-refused", eventId, "A final Assistant response reached the bounded Feishu outbound queue. The entire response stayed local until capacity is reconciled.");
      return { status: "resource-refused", reason: "queue-limit", alert };
    }
    const outbox = {
      schema: OUTBOUND_SCHEMA,
      event_id: eventId,
      source: input.source,
      source_ref: input.sourceRef,
      session_id: input.sessionId,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      destination_chat_id: binding.chat_id,
      reply_to_message_id: input.replyTo ?? null,
      decision_ref: input.decisionRef ?? null,
      decision_key: input.decisionKey ?? null,
      text,
      text_hash: `sha256:${sha(text)}`,
      chunks: chunks.map((chunk, index) => ({ index, count: chunks.length, chunk, chunk_hash: `sha256:${sha(chunk)}`, idempotency_key: stableId("fm", `${eventId}\0${index}`, 44) })),
      created_at: nowIso(),
    };
    const ledger = newOutboundLedger(outbox);
    validateOutbound(outbox);
    validateOutboundLedger(ledger);
    atomicJson(join(paths.outbox, filename), outbox);
    atomicJson(join(paths.outboundLedger, filename), ledger);
    writeOutboundPendingIndex(paths, filename, outbox);
    return { status: "registered", eventId, chunks: chunks.length };
  });
}

export function claimNextOutbound(home, options = {}) {
  const paths = ensurePrivateLayout(home);
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  const now = Number.isSafeInteger(options.nowMs) ? options.nowMs : Date.now();
  return withLock(paths, "outbound-state", () => {
    const candidates = [];
    for (const name of safeJsonNames(paths.outboundPending)) {
      const marker = readJson(join(paths.outboundPending, name));
      const path = join(paths.outboundLedger, name);
      const outbox = readJson(join(paths.outbox, name));
      let ledger = readJson(path, { optional: true });
      if (!ledger) {
        ledger = newOutboundLedger(outbox, { last_error: "ledger repaired from the bounded pending index" });
        atomicJson(path, ledger);
      }
      if (marker.event_id !== outbox.event_id) throw new Error("Feishu outbound pending index mismatch");
      assertOutboundPair(name, outbox, ledger, binding);
      ledger = reconcileOutboundReceiptLocked(paths, name, outbox, ledger).ledger;
      if (!["pending", "retryable", "sending"].includes(ledger.state)) {
        removeOutboundPendingIndex(paths, name);
        continue;
      }
      if (!binding || binding.status !== "active" || outbox.binding_generation !== binding.generation || outbox.binding_id !== binding.binding_id) {
        atomicJson(path, { ...ledger, state: "superseded", superseded_at: nowIso(), last_error: "binding generation changed before send" });
        removeOutboundPendingIndex(paths, name);
        continue;
      }
      if (ledger.idempotency_expires_ms !== null && now >= ledger.idempotency_expires_ms) {
        atomicJson(path, { ...ledger, state: "delivery_uncertain", uncertain_at: nowIso(), last_error: "send exceeded the fixed Feishu idempotency window" });
        removeOutboundPendingIndex(paths, name);
        createLocalAlert(paths, "outbound-delivery-uncertain", outbox.event_id, "A Feishu send may have succeeded, but no receipt was recorded before the idempotency window ended. Automatic resend stopped.");
        continue;
      }
      if (ledger.retry_at_ms > now) continue;
      candidates.push({ name, path, ledger, outbox });
    }
    candidates.sort((a, b) => String(a.outbox.created_at).localeCompare(String(b.outbox.created_at)) || a.name.localeCompare(b.name));
    const candidate = candidates[0];
    if (!candidate) return undefined;
    const chunk = candidate.outbox.chunks[candidate.ledger.next_chunk];
    if (!chunk) throw new Error("Feishu outbound candidate exhausted chunks without a complete receipt");
    const attempt = candidate.ledger.attempts + 1;
    const attemptId = stableId("attempt_", `${candidate.outbox.event_id}\0${chunk.index}\0${attempt}`, 24);
    const started = candidate.ledger.idempotency_started_ms ?? now;
    const ledger = {
      ...candidate.ledger,
      state: "sending",
      attempts: attempt,
      attempt_id: attemptId,
      last_attempt_ms: now,
      last_attempt_at: nowIso(),
      retry_at_ms: 0,
      idempotency_started_ms: started,
      idempotency_expires_ms: started + IDEMPOTENCY_WINDOW_MS,
    };
    atomicJson(candidate.path, ledger);
    const attemptDir = join(paths.attemptsOut, candidate.name.replace(/\.json$/, ""));
    privateDir(attemptDir);
    atomicJson(join(attemptDir, `${String(attempt).padStart(8, "0")}.json`), {
      schema: "fm-feishu-outbound-attempt.v1",
      event_id: candidate.outbox.event_id,
      attempt_id: attemptId,
      attempt,
      chunk_index: chunk.index,
      idempotency_key: chunk.idempotency_key,
      started_at: nowIso(),
    });
    return { filename: candidate.name, outbox: candidate.outbox, ledger, chunk };
  });
}

export function failOutboundAttempt(home, claim, error, { ambiguous = false, retryAfterMs, nowMs } = {}) {
  const paths = ensurePrivateLayout(home);
  const now = Number.isSafeInteger(nowMs) ? nowMs : Date.now();
  return withLock(paths, "outbound-state", () => {
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    const path = join(paths.outboundLedger, claim.filename);
    const ledger = readJson(path);
    const outbox = readJson(join(paths.outbox, claim.filename));
    assertOutboundPair(claim.filename, outbox, ledger, binding);
    if (ledger.attempt_id !== claim.ledger.attempt_id) return false;
    const expiry = ledger.idempotency_expires_ms;
    if (expiry === null) throw new Error("Feishu outbound attempt has no fixed idempotency window");
    if (now >= expiry) {
      atomicJson(path, { ...ledger, state: "delivery_uncertain", uncertain_at: nowIso(), last_error: String(error).slice(0, 500) });
      removeOutboundPendingIndex(paths, claim.filename);
      createLocalAlert(paths, "outbound-delivery-uncertain", claim.outbox.event_id, "A Feishu send may have succeeded, but its result is uncertain. Automatic resend stopped.");
      return true;
    }
    let delay;
    if (retryAfterMs !== undefined) {
      delay = Number(retryAfterMs);
      if (!Number.isSafeInteger(delay) || delay < 0) throw new Error("invalid Feishu Retry-After delay");
    } else {
      delay = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.min(10, ledger.attempts - 1));
    }
    atomicJson(path, { ...ledger, state: ambiguous ? "sending" : "retryable", retry_at_ms: now + delay, last_error: String(error).slice(0, 500) });
    return true;
  });
}

export function receiptOutbound(home, claim, receipt) {
  const paths = ensurePrivateLayout(home);
  const messageId = requireString(receipt.messageId, "outbound message_id", MESSAGE_ID);
  const chatId = requireString(receipt.chatId, "outbound chat_id", CHAT_ID);
  if (chatId !== claim.outbox.destination_chat_id) throw new Error("Feishu receipt chat does not match the bound destination");
  return withLock(paths, "outbound-state", () => {
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    const ledgerPath = join(paths.outboundLedger, claim.filename);
    const ledger = readJson(ledgerPath);
    const outbox = readJson(join(paths.outbox, claim.filename));
    assertOutboundPair(claim.filename, outbox, ledger, binding);
    if (ledger.attempt_id !== claim.ledger.attempt_id) return false;
    if (claim.chunk.index !== ledger.next_chunk || outbox.chunks[claim.chunk.index].idempotency_key !== claim.chunk.idempotency_key) throw new Error("Feishu receipt does not match the active outbound chunk");
    const existing = readJson(join(paths.outboundReceipts, claim.filename), { optional: true });
    const messageIds = existing ? [...existing.message_ids] : [];
    if (messageIds.length !== claim.chunk.index) throw new Error("Feishu outbound receipt sequence is partial or out of order");
    messageIds.push(messageId);
    const receiptRecord = {
      schema: OUTBOUND_RECEIPT_SCHEMA,
      event_id: outbox.event_id,
      attempt: ledger.attempts,
      idempotency_keys: outbox.chunks.map((chunk) => chunk.idempotency_key),
      message_ids: messageIds,
      chat_id: chatId,
      posted_at: nowIso(),
    };
    validateOutboundReceipt(receiptRecord);
    atomicJson(join(paths.outboundReceipts, claim.filename), receiptRecord);
    writeOutboundMessageMap(paths, outbox, messageId, claim.chunk.index);
    const nextChunk = claim.chunk.index + 1;
    const { attempt_id: _attemptId, last_attempt_ms: _lastAttemptMs, ...rest } = ledger;
    atomicJson(ledgerPath, {
      ...rest,
      state: nextChunk >= outbox.chunks.length ? "posted" : "pending",
      next_chunk: nextChunk,
      retry_at_ms: 0,
      last_error: null,
      idempotency_started_ms: null,
      idempotency_expires_ms: null,
      posted_at: nextChunk >= outbox.chunks.length ? nowIso() : null,
    });
    if (nextChunk >= outbox.chunks.length) removeOutboundPendingIndex(paths, claim.filename);
    return true;
  });
}

export function registerPendingDecision(home, input) {
  const paths = ensurePrivateLayout(home);
  const decisionRef = requireString(input.decisionRef, "decision_ref", /^[A-Za-z0-9._:-]{1,160}$/);
  const decisionKey = requireString(input.decisionKey, "decision_key", /^[A-Za-z0-9._:-]{1,160}$/);
  const sessionId = requireString(input.sessionId, "Pi session id", /^[0-9a-fA-F-]{16,128}$/);
  const sourceRef = requireString(input.sourceRef, "decision source ref", DELIVERY_REF);
  const sourceRecord = withLock(paths, "inbound-state", () => {
    repairInboundPublicationsLocked(paths);
    const found = readInboundByDeliveryRef(paths, sourceRef);
    if (!found || !new Set(["queued", "delivered"]).has(found.ledger.state)) throw new Error("decision source is not an exact Feishu message submitted to this Pi native queue");
    return found;
  });
  return withLock(paths, "outbound-state", () => {
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    assertConfigurationIdentity(paths, pairing, binding);
    if (!pairingIsActive(pairing) || !binding || binding.status !== "active") throw new Error("Feishu channel is not active");
    if (sessionId !== binding.session_id || sourceRecord.event.target_session_id !== sessionId || sourceRecord.ledger.binding_generation !== binding.generation) throw new Error("decision registration does not match the bound Pi turn");
    const path = join(paths.pendingDecisions, `${sha(decisionRef)}.json`);
    const prior = readJson(path, { optional: true });
    if (prior && (prior.decision_ref !== decisionRef || prior.decision_key !== decisionKey || prior.source_ref !== sourceRef || prior.source !== sourceRecord.event.source)) throw new Error("decision_ref is already bound to another exact turn or key");
    if (prior && !new Set(["awaiting-outbound", "sent-to-outbox"]).has(prior.state)) throw new Error("decision_ref is already terminal");
    if (!prior && safeJsonNames(paths.pendingDecisionOpen).length >= maxPendingOutbound(input)) throw new Error("pending Feishu decision limit reached");
    const record = prior ?? {
      schema: DECISION_SCHEMA,
      decision_ref: decisionRef,
      decision_key: decisionKey,
      session_id: sessionId,
      binding_generation: binding.generation,
      source: sourceRecord.event.source,
      source_ref: sourceRef,
      state: "awaiting-outbound",
      registered_at: nowIso(),
      outbound_event_id: null,
    };
    atomicJson(path, record);
    writePendingDecisionIndex(paths, record);
    return record;
  });
}

export function findPendingDecisionForOutbound(home, decisionRef, decisionKey, sessionId, bindingGeneration, source, sourceRef) {
  const paths = ensurePrivateLayout(home);
  const name = `${sha(decisionRef)}.json`;
  const record = readJson(join(paths.pendingDecisions, name), { optional: true });
  if (!record || record.decision_ref !== decisionRef || record.decision_key !== decisionKey || record.session_id !== sessionId || record.binding_generation !== bindingGeneration || record.source !== source || record.source_ref !== sourceRef) throw new Error("Feishu outbound intent decision snapshot is unavailable for this exact turn");
  return { name, record };
}

export function claimPendingDecisionForOutbound(home, sessionId, bindingGeneration, source, sourceRef) {
  const paths = ensurePrivateLayout(home);
  const candidates = [];
  for (const name of safeJsonNames(paths.pendingDecisionOpen)) {
    const marker = readJson(join(paths.pendingDecisionOpen, name));
    const record = readJson(join(paths.pendingDecisions, name));
    if (marker.decision_ref !== record.decision_ref || marker.decision_key !== record.decision_key || marker.state !== record.state || marker.source !== record.source || marker.source_ref !== record.source_ref) throw new Error("Feishu pending decision index mismatch");
    if (record.state === "awaiting-outbound" && record.session_id === sessionId && record.binding_generation === bindingGeneration && record.source === source && record.source_ref === sourceRef) candidates.push({ name, record });
  }
  if (candidates.length === 0) return undefined;
  if (candidates.length > 1) {
    createLocalAlert(paths, "ambiguous-decision-correlation", stableId("decision_", `${sessionId}\0${bindingGeneration}\0${source}\0${sourceRef}`, 24), "More than one exact Feishu decision registration awaited the same final response. None was guessed; reconcile the registrations locally.");
    return undefined;
  }
  return candidates[0];
}

export function bindPendingDecisionToOutbound(home, candidate, eventId) {
  if (!candidate) return;
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "outbound-state", () => {
    const path = join(paths.pendingDecisions, candidate.name);
    const current = readJson(path);
    if (current.state !== "awaiting-outbound") return;
    const updated = { ...current, state: "sent-to-outbox", outbound_event_id: eventId, outbound_registered_at: nowIso() };
    atomicJson(path, updated);
    writePendingDecisionIndex(paths, updated);
  });
}

export function finishPendingDecisionForOutbound(home, candidate, outcome) {
  if (!candidate) return;
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "outbound-state", () => {
    const path = join(paths.pendingDecisions, candidate.name);
    const current = readJson(path);
    if (current.state !== "awaiting-outbound") return;
    const refused = new Set(["secret-refused", "chunk-refused", "resource-refused"]).has(outcome);
    removePendingDecisionIndex(paths, current.decision_ref);
    atomicJson(path, {
      ...current,
      state: refused ? "outbound-refused" : "outbound-skipped",
      outbound_outcome: requireString(outcome, "decision outbound outcome", /^[a-z-]{1,80}$/),
      terminal_at: nowIso(),
    });
  });
}

export function claimTransportOwner(home, owner) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "transport-owner", () => {
    const prior = readJson(paths.owner, { optional: true });
    if (prior && prior.nonce !== owner.nonce && pidAlive(prior.pid)) return { ok: false, owner: prior };
    const record = {
      schema: "fm-feishu-transport-owner.v1",
      pid: process.pid,
      nonce: requireString(owner.nonce, "transport nonce", /^[a-f0-9]{24,128}$/),
      module_file: requireString(owner.moduleFile, "transport module path", undefined, 4096),
      home_realpath: paths.home,
      process_start_token: requireString(owner.processStartToken, "transport process start token", /^[0-9]+$/, 64),
      started_at: nowIso(),
    };
    validateRecordAtPath(paths.owner, record);
    atomicJson(paths.owner, record);
    return { ok: true, owner: record };
  });
}

export function readTransportOwner(home) {
  const paths = pathsForHome(home);
  return readJson(paths.owner, { optional: true });
}

export function retireStaleTransportOwner(home, expected) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "transport-owner", () => {
    const owner = readJson(paths.owner, { optional: true });
    if (!owner || owner.pid !== expected.pid || owner.nonce !== expected.nonce || owner.process_start_token !== expected.process_start_token || owner.module_file !== expected.module_file || owner.home_realpath !== expected.home_realpath) return false;
    unlinkSync(paths.owner);
    fsyncDirectory(paths.transport);
    return true;
  });
}

export function releaseTransportOwner(home, nonce) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "transport-owner", () => {
    const owner = readJson(paths.owner, { optional: true });
    if (!owner || owner.nonce !== nonce || owner.pid !== process.pid) return false;
    unlinkSync(paths.owner);
    fsyncDirectory(paths.transport);
    return true;
  });
}

export function recordTransportDiagnostic(home, kind, line) {
  const paths = ensurePrivateLayout(home);
  const dir = join(paths.transport, "diagnostics");
  privateDir(dir);
  const safeKind = requireString(kind, "transport diagnostic kind", /^[a-z0-9-]+$/, 80);
  const raw = String(line);
  const detailHash = `sha256:${sha(raw)}`;
  const id = sha(`${safeKind}\0${detailHash}`);
  const path = join(dir, `${id}.json`);
  if (!existsSync(path)) atomicJson(path, {
    schema: "fm-feishu-transport-diagnostic.v1",
    kind: safeKind,
    detail_hash: detailHash,
    detail_bytes: Buffer.byteLength(raw, "utf8"),
    summary: "SDK transport diagnostic recorded; inspect the owning command directly if local remediation is needed",
    recorded_at: nowIso(),
  });
  return path;
}

export function writeTransportHealth(home, patch) {
  const paths = ensurePrivateLayout(home);
  const prior = readJson(paths.health, { optional: true });
  const health = {
    schema: TRANSPORT_HEALTH_SCHEMA,
    phase: patch.phase ?? prior?.phase ?? "stopped",
    healthy: patch.healthy ?? prior?.healthy ?? false,
    owner_pid: patch.ownerPid !== undefined ? patch.ownerPid : prior?.owner_pid ?? null,
    owner_nonce: patch.ownerNonce !== undefined ? patch.ownerNonce : prior?.owner_nonce ?? null,
    owner_process_start_token: patch.ownerProcessStartToken !== undefined ? patch.ownerProcessStartToken : prior?.owner_process_start_token ?? null,
    binding_id: patch.bindingId !== undefined ? patch.bindingId : prior?.binding_id ?? null,
    binding_generation: patch.bindingGeneration !== undefined ? patch.bindingGeneration : prior?.binding_generation ?? null,
    reconnects: patch.reconnects ?? prior?.reconnects ?? 0,
    last_connected_at: patch.lastConnectedAt ?? prior?.last_connected_at ?? null,
    last_identity_verified_at: patch.lastIdentityVerifiedAt ?? prior?.last_identity_verified_at ?? null,
    last_error_type: patch.lastErrorType ?? null,
    updated_at: nowIso(),
  };
  validateRecordAtPath(paths.health, health);
  atomicJson(paths.health, health);
  return health;
}

export function readTransportHealth(home) {
  const paths = pathsForHome(home);
  const health = readJson(paths.health, { optional: true });
  if (!health) return undefined;
  if (health.schema !== TRANSPORT_HEALTH_SCHEMA) throw new Error("unsupported Feishu transport health schema");
  return health;
}

function readProcessStartToken(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const suffix = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    return /^[0-9]+$/.test(suffix[19] ?? "") ? suffix[19] : "";
  } catch {
    return "";
  }
}

export function transportHealthAllowsDispatch(home, binding) {
  const paths = pathsForHome(home);
  const health = readJson(paths.health, { optional: true });
  const owner = readJson(paths.owner, { optional: true });
  if (!health || !owner || health.phase !== "healthy" || health.healthy !== true) return false;
  if (health.binding_id !== binding.binding_id || health.binding_generation !== binding.generation) return false;
  if (owner.home_realpath !== paths.home || owner.pid !== health.owner_pid || owner.nonce !== health.owner_nonce || owner.process_start_token !== health.owner_process_start_token) return false;
  return pidAlive(owner.pid) && readProcessStartToken(owner.pid) === owner.process_start_token;
}

export function statusSummary(home) {
  const paths = ensurePrivateLayout(home);
  repairOutboundState(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  assertConfigurationIdentity(paths, pairing, binding);
  const healthRaw = readJson(paths.health, { optional: true });
  const health = healthRaw ? requireSchema(healthRaw, TRANSPORT_HEALTH_SCHEMA, "transport health") : undefined;
  const inbound = ingressCounts(home);
  let outboundPending = 0;
  let outboundUncertain = 0;
  for (const name of safeJsonNames(paths.outboundLedger)) {
    const ledger = requireSchema(readJson(join(paths.outboundLedger, name)), OUTBOUND_LEDGER_SCHEMA, "outbound ledger");
    if (["pending", "retryable", "sending"].includes(ledger.state)) outboundPending += 1;
    if (ledger.state === "delivery_uncertain") outboundUncertain += 1;
  }
  return {
    schema: "fm-feishu-status.v2",
    paired: pairingIsActive(pairing),
    disabled: Boolean(pairing && pairing.disabled_at !== null),
    binding_status: binding?.status ?? "absent",
    binding_generation: binding?.generation ?? null,
    session_id: binding?.session_id ?? null,
    session_file: binding?.session_file_realpath ?? null,
    session_cwd: binding?.session_cwd_realpath ?? null,
    home_realpath: paths.home,
    chat_id: binding?.chat_id ?? pairing?.allowed_chats?.[0] ?? null,
    allowed_user: pairing?.allowed_users?.[0] ?? null,
    transport_phase: health?.phase ?? "stopped",
    transport_healthy: binding ? transportHealthAllowsDispatch(home, binding) : false,
    inbound,
    outbound_pending: outboundPending,
    outbound_uncertain: outboundUncertain,
  };
}

export function publicStatusSummary(home) {
  const status = statusSummary(home);
  return {
    schema: status.schema,
    paired: status.paired,
    disabled: status.disabled,
    binding_status: status.binding_status,
    binding_generation: status.binding_generation,
    transport_phase: status.transport_phase,
    transport_healthy: status.transport_healthy,
    inbound_pending: status.inbound.pending,
    inbound_queued: status.inbound.queued,
    outbound_pending: status.outbound_pending,
    outbound_uncertain: status.outbound_uncertain,
  };
}

function cliUsage() {
  return "usage: fm-feishu-state.mjs status [--public] [--home <path>] | decision-register <decision-ref> <decision-key> <source-ref> [--home <path>]";
}

async function main(argv) {
  let home = process.env.FM_HOME || resolve(dirname(MODULE_FILE), "..");
  const homeIndex = argv.indexOf("--home");
  if (homeIndex >= 0) {
    home = argv[homeIndex + 1];
    argv.splice(homeIndex, 2);
  }
  const command = argv.shift();
  if (command === "status") {
    const value = argv.includes("--public") ? publicStatusSummary(home) : statusSummary(home);
    if (argv.includes("--active-only") && value.paired !== true) return;
    if (argv.includes("--line")) {
      process.stdout.write(
        `FEISHU: paired=${value.paired === true ? "yes" : "no"} binding=${value.binding_status ?? "absent"}` +
        ` generation=${value.binding_generation ?? "none"} transport=${value.transport_phase ?? "stopped"}` +
        ` inbox_pending=${value.inbound_pending ?? value.inbound?.pending ?? 0}` +
        ` outbox_pending=${value.outbound_pending ?? 0} uncertain=${value.outbound_uncertain ?? 0}\n`,
      );
    } else {
      process.stdout.write(`${JSON.stringify(value)}\n`);
    }
    return;
  }
  if (command === "decision-register") {
    const [decisionRef, decisionKey, sourceRef] = argv;
    if (!decisionRef || !decisionKey || !sourceRef || !process.env.PI_SESSION_ID) throw new Error(cliUsage());
    const record = registerPendingDecision(home, {
      decisionRef,
      decisionKey,
      sourceRef,
      sessionId: process.env.PI_SESSION_ID,
    });
    process.stdout.write(`${JSON.stringify({ ok: true, decision_ref: record.decision_ref, decision_key: record.decision_key })}\n`);
    return;
  }
  throw new Error(cliUsage());
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(MODULE_FILE)) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`fm-feishu-state: ${error.message}\n`);
    process.exitCode = 2;
  });
}
