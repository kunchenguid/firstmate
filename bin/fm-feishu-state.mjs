#!/usr/bin/env node
// Private durable state owner for the Firstmate Feishu channel.
//
// This module contains no network or Agent code.  It owns the pairing and
// binding schemas, private accepted-event publication with inbound media
// envelopes and cache bytes, native Pi queue handoff, finalized-Assistant
// registration intents and outbox records, attempts, receipts, quarantine,
// transport health, and crash reconciliation.  The Pi extension
// and the no-Agent transport import this same owner rather than duplicating
// those state machines.
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
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
export const BINDING_SCHEMA = "fm-feishu-binding.v2";
export const INBOUND_SCHEMA = "fm-feishu-inbound.v2";
export const PROCESSED_INBOUND_SCHEMA = "fm-feishu-inbound-processed.v1";
export const INBOUND_LEDGER_SCHEMA = "fm-feishu-inbound-ledger.v2";
export const OUTBOUND_SCHEMA = "fm-feishu-assistant-outbound.v2";
export const PROCESSED_OUTBOUND_SCHEMA = "fm-feishu-assistant-outbound-processed.v1";
export const OUTBOUND_LEDGER_SCHEMA = "fm-feishu-outbound-ledger.v1";
export const OUTBOUND_RECEIPT_SCHEMA = "fm-feishu-outbound-receipt.v1";
export const OUTBOUND_INTENT_SCHEMA = "fm-feishu-outbound-registration-intent.v2";
export const TRANSPORT_HEALTH_SCHEMA = "fm-feishu-transport-health.v2";
export const DEFAULT_MAX_INBOUND_BYTES = 64 * 1024;
export const DEFAULT_MAX_INBOUND_MEDIA_BYTES = 10 * 1024 * 1024;
export const DEFAULT_MAX_INBOUND_MESSAGE_MEDIA_BYTES = 20 * 1024 * 1024;
export const DEFAULT_MAX_INBOUND_ATTACHMENTS = 8;
export const DEFAULT_INBOUND_MEDIA_RETENTION_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_MAX_OUTBOUND_CHUNK_BYTES = 20 * 1024;
export const DEFAULT_MAX_OUTBOUND_BYTES = 1024 * 1024;
export const DEFAULT_MAX_PENDING_INBOUND = 10000;
export const DEFAULT_MAX_PENDING_OUTBOUND = 1000;
export const DEFAULT_MIN_FREE_BYTES = 64 * 1024 * 1024;
export const IDEMPOTENCY_WINDOW_MS = 60 * 60 * 1000;
const LOCK_WAIT_MS = 3000;
const LOCK_STALE_MS = 30000;
const LOCK_PID_RECORD_MAX_BYTES = 32;
const RETRY_BASE_MS = 1000;
const RETRY_MAX_MS = 60000;
const MODULE_FILE = fileURLToPath(import.meta.url);
const LEGACY_INBOUND_SCHEMA = "fm-feishu-inbound.v1";
const INBOUND_MEDIA_SCHEMA = "fm-feishu-inbound-media.v1";
const SUPPORTED_INBOUND_TYPES = ["text", "image", "post"];
const SUPPORTED_IMAGE_MIME_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

export class FeishuStateLockContentionError extends Error {
  constructor(lockName) {
    super(`timed out acquiring Feishu ${lockName} state lock`);
    this.name = "FeishuStateLockContentionError";
    this.code = "FM_FEISHU_LOCK_CONTENDED";
    this.lockName = lockName;
  }
}

const RECORD_HASH = /^sha256:[a-f0-9]{64}$/;
const SESSION_ID = /^[0-9a-fA-F-]{16,128}$/;
const DELIVERY_REF = /^in_[a-f0-9]{24}$/;
const SESSION_ENTRY_ID = /^[a-f0-9]{8}$/;
const OUTBOUND_EVENT_ID = /^out_[a-f0-9]{40}$/;
const MESSAGE_ID = /^om_[A-Za-z0-9_-]{4,128}$/;
const CHAT_ID = /^oc_[A-Za-z0-9_-]{4,128}$/;
const LOCAL_ROUTINE_ASSISTANT_TEXTS = new Set(["Captain, shipshape.", "Captain，shipshape.", "船长，处理中。"]);

// A finalized Assistant response equal to a fixed routine acknowledgement stays
// local even when its persisted representation carries surrounding whitespace,
// such as a trailing newline. Only outer whitespace is normalized, so a longer
// response that merely contains the phrase as a substring is still delivered.
function isLocalRoutineAssistantText(text) {
  return typeof text === "string" && LOCAL_ROUTINE_ASSISTANT_TEXTS.has(text.trim());
}

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
    if (Buffer.isBuffer(bytes) || bytes instanceof Uint8Array) writeFileSync(fd, bytes);
    else writeFileSync(fd, bytes, { encoding: "utf8" });
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

function stateLockKind(stat) {
  if (stat.isSymbolicLink()) return "symlink";
  if (!stat.isFile()) return "non-regular";
  return stat.nlink >= 2n ? "hardlinked" : "regular";
}

function stateLockEvidence(stat) {
  return {
    dev: stat.dev,
    ino: stat.ino,
    nlink: stat.nlink,
    size: stat.size,
    mtimeNs: stat.mtimeNs,
  };
}

function sameStateLockInode(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameStateLockEvidence(left, right) {
  return sameStateLockInode(left, right)
    && left.nlink === right.nlink
    && left.size === right.size
    && left.mtimeNs === right.mtimeNs;
}

function hardlinkedStateLockChanged(name) {
  return new Error(`unsafe Feishu ${name} hardlinked state lock changed during recovery`);
}

function stateLockShapeError(name, kind) {
  return new Error(`unsafe Feishu ${name} ${kind} state lock`);
}

function readBoundedStateLockOwner(fd) {
  const bytes = Buffer.alloc(LOCK_PID_RECORD_MAX_BYTES + 1);
  let length = 0;
  for (;;) {
    const count = readSync(fd, bytes, length, bytes.length - length, length);
    if (count === 0) break;
    length += count;
    if (length === bytes.length) break;
  }
  const raw = length <= LOCK_PID_RECORD_MAX_BYTES ? bytes.toString("utf8", 0, length) : undefined;
  const owner = raw !== undefined && /^[1-9][0-9]*\n$/.test(raw) ? Number(raw.trim()) : undefined;
  return Number.isSafeInteger(owner) && owner > 1 ? owner : undefined;
}

function openStateLock(lock, name, { expectedHardlink } = {}) {
  let pathStat;
  try {
    pathStat = lstatSync(lock, { bigint: true });
  } catch (error) {
    if (error?.code === "ENOENT" && expectedHardlink) throw hardlinkedStateLockChanged(name);
    if (error?.code === "ENOENT") return { changed: true };
    throw error;
  }
  const pathKind = stateLockKind(pathStat);
  const pathEvidence = stateLockEvidence(pathStat);
  if (expectedHardlink && (pathKind !== "hardlinked" || !sameStateLockEvidence(pathEvidence, expectedHardlink))) {
    throw hardlinkedStateLockChanged(name);
  }
  if (pathKind === "symlink" || pathKind === "non-regular") {
    throw stateLockShapeError(name, pathKind);
  }

  let fd;
  try {
    try {
      fd = openSync(lock, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (error) {
      if (pathKind === "hardlinked" || expectedHardlink) throw hardlinkedStateLockChanged(name);
      if (error?.code === "ELOOP") throw stateLockShapeError(name, "symlink");
      if (error?.code === "ENOENT") return { changed: true };
      throw error;
    }
    const openedStat = fstatSync(fd, { bigint: true });
    const openedKind = stateLockKind(openedStat);
    const openedEvidence = stateLockEvidence(openedStat);
    if (openedKind === "symlink" || openedKind === "non-regular") {
      if (pathKind === "hardlinked" || expectedHardlink) throw hardlinkedStateLockChanged(name);
      throw stateLockShapeError(name, openedKind);
    }
    if (!sameStateLockEvidence(pathEvidence, openedEvidence)) {
      if (pathKind === "hardlinked" || openedKind === "hardlinked" || expectedHardlink) throw hardlinkedStateLockChanged(name);
      closeSync(fd);
      fd = undefined;
      return { changed: true };
    }
    const owner = readBoundedStateLockOwner(fd);
    const afterReadStat = fstatSync(fd, { bigint: true });
    let afterReadPathStat;
    try {
      afterReadPathStat = lstatSync(lock, { bigint: true });
    } catch (error) {
      if (pathKind === "hardlinked" || expectedHardlink) throw hardlinkedStateLockChanged(name);
      if (error?.code === "ENOENT") {
        closeSync(fd);
        fd = undefined;
        return { changed: true };
      }
      throw error;
    }
    const afterReadPathKind = stateLockKind(afterReadPathStat);
    const afterReadEvidence = stateLockEvidence(afterReadPathStat);
    if (!sameStateLockEvidence(openedEvidence, stateLockEvidence(afterReadStat))
      || afterReadPathKind !== openedKind
      || !sameStateLockEvidence(openedEvidence, afterReadEvidence)) {
      if (pathKind === "hardlinked" || openedKind === "hardlinked" || afterReadPathKind === "hardlinked" || expectedHardlink) {
        throw hardlinkedStateLockChanged(name);
      }
      closeSync(fd);
      fd = undefined;
      return { changed: true };
    }
    return {
      changed: false,
      fd,
      age: Date.now() - Number(openedStat.mtimeMs),
      owner,
      hardlinked: openedKind === "hardlinked",
      evidence: openedEvidence,
    };
  } catch (error) {
    if (fd !== undefined) closeSync(fd);
    throw error;
  }
}

function inspectStateLock(lock, name, { requireOwner = false, expectedHardlink } = {}) {
  const opened = openStateLock(lock, name, { expectedHardlink });
  if (opened.changed) return opened;
  try {
    const label = opened.hardlinked ? `${name} hardlinked` : name;
    const { owner } = opened;
    if (owner === undefined || !Number.isSafeInteger(owner) || owner <= 1) {
      if (requireOwner || opened.age >= LOCK_WAIT_MS) throw new Error(`malformed Feishu ${label} state lock`);
      return { ...opened, fd: undefined, owner: undefined };
    }
    return { ...opened, fd: undefined, owner };
  } finally {
    closeSync(opened.fd);
  }
}

function reclaimHardlinkedStateLock(lock, name, observed) {
  const opened = openStateLock(lock, name, { expectedHardlink: observed.evidence });
  try {
    if (opened.owner === undefined) throw new Error(`malformed Feishu ${name} hardlinked state lock`);
    if (opened.owner !== observed.owner || opened.age <= LOCK_STALE_MS) throw hardlinkedStateLockChanged(name);
    if (pidAlive(opened.owner)) return false;
    let pathStat;
    try {
      pathStat = lstatSync(lock, { bigint: true });
    } catch {
      throw hardlinkedStateLockChanged(name);
    }
    const descriptorStat = fstatSync(opened.fd, { bigint: true });
    if (stateLockKind(pathStat) !== "hardlinked"
      || !sameStateLockEvidence(stateLockEvidence(pathStat), observed.evidence)
      || !sameStateLockEvidence(stateLockEvidence(descriptorStat), observed.evidence)) {
      throw hardlinkedStateLockChanged(name);
    }
    try {
      unlinkSync(lock);
    } catch {
      throw new Error(`unsafe Feishu ${name} hardlinked state lock could not be reclaimed safely`);
    }
    return true;
  } finally {
    closeSync(opened.fd);
  }
}

function withLock(paths, name, callback) {
  const lock = join(paths.stateRoot, `.${name}.lock`);
  const started = Date.now();
  let expectedHardlink;
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
      const observed = inspectStateLock(lock, name, { expectedHardlink });
      if (observed.changed) continue;
      if (observed.hardlinked && expectedHardlink === undefined) expectedHardlink = observed.evidence;
      if (observed.owner !== undefined && observed.age > LOCK_STALE_MS && !pidAlive(observed.owner)) {
        if (observed.hardlinked) {
          if (!reclaimHardlinkedStateLock(lock, name, observed)) continue;
          expectedHardlink = undefined;
        } else {
          try { unlinkSync(lock); } catch {}
        }
        continue;
      }
      if (Date.now() - started >= LOCK_WAIT_MS) {
        const lockOwner = inspectStateLock(lock, name, { requireOwner: true, expectedHardlink });
        if (lockOwner.changed) continue;
        if (pidAlive(lockOwner.owner)) throw new FeishuStateLockContentionError(name);
        const label = lockOwner.hardlinked ? `${name} hardlinked` : name;
        throw new Error(`Feishu ${label} state lock owner is not live within the stale-owner grace period`);
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
    inboundCleanup: join(stateRoot, "inbound-cleanup.json"),
    outboundCleanup: join(stateRoot, "outbound-cleanup.json"),
    inboundPending: join(stateRoot, "inbound-pending"),
    inboundPendingCount: join(stateRoot, "inbound-pending-count"),
    inboundDeliveryMap: join(stateRoot, "inbound-delivery-map"),
    inboundPublications: join(stateRoot, "inbound-publications"),
    inboundMedia: join(stateRoot, "inbound-media"),
    inboundMediaCache: join(stateRoot, "inbound-media-cache"),
    outbox: join(stateRoot, "outbox"),
    outboundLedger: join(stateRoot, "outbound-ledger"),
    outboundReceipts: join(stateRoot, "outbound-receipts"),
    outboundPending: join(stateRoot, "outbound-pending"),
    outboundRegistrationIntents: join(stateRoot, "outbound-registration-intents"),
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
    paths.inboundMedia,
    paths.inboundMediaCache,
    paths.outbox,
    paths.outboundLedger,
    paths.outboundReceipts,
    paths.outboundPending,
    paths.outboundRegistrationIntents,
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
  if (!new Set([LEGACY_INBOUND_SCHEMA, INBOUND_SCHEMA, PROCESSED_INBOUND_SCHEMA]).has(event.schema) || event.source !== "feishu") throw new Error("invalid Feishu inbound event schema or source");
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
  if (event.schema === PROCESSED_INBOUND_SCHEMA) {
    requireIso(event.body_removed_at, "inbound body removal time");
    if (Object.hasOwn(event, "text") || Object.hasOwn(event, "content")) throw new Error("processed Feishu inbound event retained message body");
  } else if (event.schema === LEGACY_INBOUND_SCHEMA) {
    if (event.message_type !== "text") throw new Error("invalid legacy Feishu inbound message type");
    if (typeof event.text !== "string" || event.text.trim().length === 0 || Buffer.from(event.text, "utf8").toString("utf8") !== event.text) throw new Error("invalid Feishu inbound text");
  } else {
    if (!SUPPORTED_INBOUND_TYPES.includes(event.message_type)) throw new Error("invalid Feishu inbound message type");
    if (!Array.isArray(event.content) || event.content.length === 0 || event.content.length > DEFAULT_MAX_INBOUND_ATTACHMENTS * 2 + 1) throw new Error("invalid Feishu inbound content");
    let imageCount = 0;
    let meaningful = false;
    for (const part of event.content) {
      if (!part || typeof part !== "object" || Array.isArray(part)) throw new Error("invalid Feishu inbound content part");
      if (part.type === "text") {
        if (typeof part.text !== "string" || Buffer.from(part.text, "utf8").toString("utf8") !== part.text) throw new Error("invalid Feishu inbound text part");
        meaningful ||= part.text.trim().length > 0;
      } else if (part.type === "image") {
        requireString(part.media_id, "inbound media id", /^media_[a-f0-9]{24}$/);
        imageCount += 1;
        meaningful = true;
      } else {
        throw new Error("unsupported Feishu inbound content part");
      }
    }
    if (!meaningful || imageCount > DEFAULT_MAX_INBOUND_ATTACHMENTS || (event.message_type === "text" && imageCount !== 0) || (event.message_type === "image" && (imageCount !== 1 || event.content.length !== 1))) {
      throw new Error("invalid Feishu inbound content shape");
    }
  }
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
  return event;
}

function validateInboundMedia(record) {
  if (record.schema !== INBOUND_MEDIA_SCHEMA) throw new Error("invalid Feishu inbound media schema");
  requireString(record.media_id, "inbound media id", /^media_[a-f0-9]{24}$/);
  requireString(record.message_id, "inbound media message id", MESSAGE_ID);
  requireString(record.delivery_ref, "inbound media delivery ref", DELIVERY_REF);
  requireSafeInteger(record.part_index, "inbound media part index");
  if (record.resource_type !== "image") throw new Error("invalid Feishu inbound media resource type");
  requireString(record.resource_key, "inbound media resource key", /^[A-Za-z0-9._-]{4,512}$/);
  requireString(record.resource_key_hash, "inbound media resource key hash", RECORD_HASH);
  if (record.resource_key_hash !== `sha256:${sha(record.resource_key)}`) throw new Error("Feishu inbound media resource key hash mismatch");
  if (!new Set(["pending", "downloading", "ready", "failed"]).has(record.state)) throw new Error("invalid Feishu inbound media state");
  requireSafeInteger(record.attempts, "inbound media attempts");
  if (record.next_attempt_at_ms != null) requireSafeInteger(record.next_attempt_at_ms, "inbound media next attempt time");
  requireNullableString(record.owner_nonce ?? null, "inbound media owner nonce", /^[a-f0-9]{24,128}$/);
  requireNullableString(record.mime_type ?? null, "inbound media MIME type", /^image\/[a-z0-9.+-]+$/, 128);
  if (record.byte_length !== null) requireSafeInteger(record.byte_length, "inbound media byte length", { min: 1 });
  requireNullableString(record.byte_hash ?? null, "inbound media byte hash", RECORD_HASH);
  requireNullableString(record.cache_filename ?? null, "inbound media cache filename", /^[a-f0-9]{64}\.bin$/);
  if (record.last_error_kind !== null && !/^[a-z0-9-]{1,80}$/.test(record.last_error_kind)) throw new Error("invalid Feishu inbound media error kind");
  requireIso(record.created_at, "inbound media creation time");
  if (record.download_started_at !== null) requireIso(record.download_started_at, "inbound media download start time");
  if (record.ready_at !== null) requireIso(record.ready_at, "inbound media ready time");
  if (record.failed_at !== null) requireIso(record.failed_at, "inbound media failure time");
  const readyFields = [record.mime_type, record.byte_length, record.byte_hash, record.cache_filename, record.ready_at];
  if (record.state === "ready" && readyFields.some((value) => value === null)) throw new Error("ready Feishu inbound media lacks byte evidence");
  if (record.state !== "ready" && readyFields.some((value) => value !== null)) throw new Error("non-ready Feishu inbound media has stale byte evidence");
  if (record.state === "downloading" && (record.owner_nonce === null || record.download_started_at === null)) throw new Error("downloading Feishu media lacks owner evidence");
  if (record.state !== "downloading" && record.owner_nonce !== null) throw new Error("non-downloading Feishu media has stale owner evidence");
  if (record.state === "failed" && (record.failed_at === null || record.last_error_kind === null)) throw new Error("failed Feishu media lacks terminal evidence");
  return record;
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
  if (ledger.content_digest != null) requireString(ledger.content_digest, "inbound ledger content digest", RECORD_HASH);
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
  if (outbox.schema !== OUTBOUND_SCHEMA || outbox.source !== "pi-assistant") throw new Error("invalid Feishu outbox schema or source");
  requireString(outbox.event_id, "outbound event id", OUTBOUND_EVENT_ID);
  requireString(outbox.assistant_entry_id, "outbound Assistant entry", SESSION_ENTRY_ID);
  requireSafeInteger(outbox.session_order, "outbound session order");
  requireString(outbox.session_id, "outbound session", SESSION_ID);
  requireString(outbox.binding_id, "outbound binding", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(outbox.binding_generation, "outbound generation", { min: 1 });
  requireString(outbox.destination_chat_id, "outbound destination", CHAT_ID);
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
  if (outbox.rendered_text_hash === undefined) {
    if (combined !== outbox.text) throw new Error("legacy Feishu outbound chunks changed final text");
  } else {
    if (outbox.rendered_text_hash !== `sha256:${sha(combined)}`) throw new Error("Feishu outbound rendered text hash mismatch");
    if (combined !== renderFeishuPostMarkdown(outbox.text)) throw new Error("Feishu outbound rendering changed after persistence");
  }
  requireIso(outbox.session_entry_timestamp, "outbound Assistant entry time");
  requireIso(outbox.created_at, "outbound creation time");
  return outbox;
}

function validateProcessedOutbound(outbox) {
  if (outbox.schema !== PROCESSED_OUTBOUND_SCHEMA || outbox.source !== "pi-assistant") throw new Error("invalid processed Feishu outbox schema or source");
  requireString(outbox.event_id, "processed outbound event id", OUTBOUND_EVENT_ID);
  requireString(outbox.assistant_entry_id, "processed outbound Assistant entry", SESSION_ENTRY_ID);
  requireSafeInteger(outbox.session_order, "processed outbound session order");
  requireString(outbox.session_id, "processed outbound session", SESSION_ID);
  requireString(outbox.binding_id, "processed outbound binding", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(outbox.binding_generation, "processed outbound generation", { min: 1 });
  requireString(outbox.destination_chat_id, "processed outbound destination", CHAT_ID);
  requireString(outbox.text_hash, "processed outbound text hash", RECORD_HASH);
  requireSafeInteger(outbox.chunk_count, "processed outbound chunk count", { min: 1 });
  requireIso(outbox.session_entry_timestamp, "processed outbound Assistant entry time");
  requireIso(outbox.created_at, "processed outbound creation time");
  requireIso(outbox.body_removed_at, "processed outbound body removal time");
  if (Object.hasOwn(outbox, "text") || Object.hasOwn(outbox, "chunks") || Object.hasOwn(outbox, "rendered_text_hash")) throw new Error("processed Feishu outbox retained message body");
  return outbox;
}

function validateAnyOutbound(outbox) {
  return outbox.schema === PROCESSED_OUTBOUND_SCHEMA ? validateProcessedOutbound(outbox) : validateOutbound(outbox);
}

function validateOutboundLedger(ledger) {
  if (ledger.schema !== OUTBOUND_LEDGER_SCHEMA) throw new Error("invalid Feishu outbound ledger schema");
  requireString(ledger.event_id, "outbound ledger event", OUTBOUND_EVENT_ID);
  if (!new Set(["pending", "retryable", "sending", "posted", "superseded", "delivery_uncertain"]).has(ledger.state)) throw new Error("invalid Feishu outbound ledger state");
  requireSafeInteger(ledger.next_chunk, "outbound next chunk");
  requireSafeInteger(ledger.attempts, "outbound attempts");
  requireSafeInteger(ledger.retry_at_ms, "outbound retry time");
  requireSafeInteger(ledger.binding_generation, "outbound ledger generation", { min: 1 });
  if (ledger.text_hash !== undefined) requireString(ledger.text_hash, "outbound ledger text hash", RECORD_HASH);
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
  if (intent.schema !== OUTBOUND_INTENT_SCHEMA || intent.source !== "pi-assistant") throw new Error("invalid Feishu outbound registration intent");
  requireString(intent.intent_id, "outbound intent id", /^reg_[a-f0-9]{40}$/);
  if (intent.event_id !== undefined) requireString(intent.event_id, "outbound intent event id", OUTBOUND_EVENT_ID);
  requireString(intent.assistant_entry_id, "outbound intent Assistant entry", SESSION_ENTRY_ID);
  requireSafeInteger(intent.session_order, "outbound intent session order");
  requireString(intent.session_id, "outbound intent session", SESSION_ID);
  requireString(intent.binding_id, "outbound intent binding", /^bind_[a-f0-9]{24}$/);
  requireSafeInteger(intent.binding_generation, "outbound intent generation", { min: 1 });
  if (typeof intent.text !== "string" || intent.text.trim().length === 0 || isLocalRoutineAssistantText(intent.text) || intent.text_hash !== `sha256:${sha(intent.text)}`) throw new Error("invalid Feishu outbound intent text");
  requireIso(intent.session_entry_timestamp, "outbound intent Assistant entry time");
  requireIso(intent.created_at, "outbound intent creation time");
  return intent;
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
  } else if (parent === "inbound-media") {
    validateInboundMedia(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.media_id)}.json`) throw new Error("Feishu inbound media filename identity mismatch");
  } else if (parent === "outbox") {
    validateAnyOutbound(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbox filename identity mismatch");
  } else if (parent === "outbound-ledger") {
    validateOutboundLedger(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbound ledger filename identity mismatch");
  } else if (parent === "outbound-receipts") {
    validateOutboundReceipt(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbound receipt filename identity mismatch");
  }
  else if (parent === "outbound-registration-intents") {
    validateOutboundIntent(record);
    if (path.split(/[\\/]/).pop() !== `${sha(record.intent_id)}.json`) throw new Error("Feishu outbound intent filename identity mismatch");
  } else if (parent === "inbound-publications") {
    if (record.schema !== "fm-feishu-inbound-publication.v1" || !record.event || !record.ledger || (record.media !== undefined && !Array.isArray(record.media))) throw new Error("invalid Feishu inbound publication intent");
    validateInboundEvent(record.event);
    validateInboundLedger(record.ledger);
    for (const media of record.media ?? []) validateInboundMedia(media);
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
  } else if (parent === "outbound-pending") {
    if (record.schema !== "fm-feishu-outbound-pending.v1") throw new Error("invalid Feishu outbound pending index");
    requireString(record.event_id, "outbound pending event", OUTBOUND_EVENT_ID);
    requireIso(record.created_at, "outbound pending creation time");
    if (path.split(/[\\/]/).pop() !== `${sha(record.event_id)}.json`) throw new Error("Feishu outbound pending filename identity mismatch");
  } else if (path.endsWith("/inbound-cleanup.json")) {
    if (record.schema !== "fm-feishu-inbound-cleanup.v1") throw new Error("invalid inbound cleanup intent");
    requireString(record.filename, "cleanup filename", /^[a-f0-9]{64}\.json$/);
    requireString(record.delivery_ref, "cleanup delivery ref", DELIVERY_REF);
    requireSafeInteger(record.binding_generation, "cleanup generation", { min: 1 });
  } else if (path.endsWith("/outbound-cleanup.json")) {
    if (record.schema !== "fm-feishu-outbound-cleanup.v1") throw new Error("invalid outbound cleanup intent");
    validateCompletedReceipt(record.receipt);
  } else if (parent === "inbound-event-ids" && record.schema === "fm-feishu-processed-inbound-id.v1") {
    requireSafeInteger(record.binding_generation, "processed inbound generation", { min: 1 });
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
    requireNullableString(record.config_file_identity ?? null, "transport config file identity", /^[0-9]+:[0-9]+:[0-9.]+:[0-9]+$/, 256);
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
    if (record.recovery_class !== undefined && record.recovery_class !== null && !new Set(["retryable", "terminal"]).has(record.recovery_class)) throw new Error("invalid Feishu transport process recovery class");
    if (record.recovery_class && !new Set(["degraded", "stopped"]).has(record.phase)) throw new Error("active Feishu transport health has a process recovery class");
    requireIso(record.updated_at, "transport update time");
  }
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
  const inboundPolicy = JSON.stringify(pairing.inbound_types);
  if (pairing.chat_policy !== "p2p-only" || !new Set([JSON.stringify(["text"]), JSON.stringify(SUPPORTED_INBOUND_TYPES)]).has(inboundPolicy)) {
    throw new Error("invalid Feishu pairing policy");
  }
  if (pairing.managed_by !== undefined && !new Set(["local-tui", "local-config"]).has(pairing.managed_by)) {
    throw new Error("invalid Feishu pairing owner");
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
  if (binding.thread_policy !== "bound-chat-mirror" || !new Set(["local-tui", "local-config"]).has(binding.bound_by)) throw new Error("invalid Feishu binding policy");
  requireNullableString(binding.outbound_after_entry_id, "binding outbound history boundary", SESSION_ENTRY_ID);
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
      inbound_types: [...SUPPORTED_INBOUND_TYPES],
      managed_by: "local-tui",
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
      if (JSON.stringify(prior.inbound_types) === JSON.stringify(SUPPORTED_INBOUND_TYPES)) return prior;
      const upgraded = { ...prior, inbound_types: [...SUPPORTED_INBOUND_TYPES], updated_at: nowIso() };
      atomicJson(paths.pairing, upgraded);
      return upgraded;
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
  const outboundAfterEntryId = requireNullableString(session.outboundAfterEntryId ?? null, "Pi outbound history boundary", SESSION_ENTRY_ID);
  if (id !== headerId || cwd !== headerCwd) throw new Error("Pi session identity does not match its persisted header");
  return { id, file, cwd, headerId, headerCwd, outboundAfterEntryId };
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
      thread_policy: "bound-chat-mirror",
      session_id: identity.id,
      session_file_realpath: identity.file,
      session_cwd_realpath: identity.cwd,
      session_header_id: identity.headerId,
      session_header_cwd_realpath: identity.headerCwd,
      outbound_after_entry_id: identity.outboundAfterEntryId,
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

export function configuredSessionMatches(home, input, session) {
  const desired = {
    appIdFingerprint: requireString(input.appIdFingerprint, "app id fingerprint", /^sha256:[a-f0-9]{64}$/),
    allowedUser: requireString(input.allowedUser, "allowed user open_id", /^ou_[A-Za-z0-9_-]{4,128}$/),
    allowedChat: requireString(input.allowedChat, "allowed P2P chat_id", /^oc_[A-Za-z0-9_-]{4,128}$/),
  };
  const identity = validateSessionIdentity(session);
  const paths = pathsForHome(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  try {
    assertConfigurationIdentity(paths, pairing, binding);
  } catch (error) {
    if (pairing?.managed_by === "local-config" || binding?.bound_by === "local-config") return false;
    throw error;
  }
  return pairing?.disabled_at === null &&
    pairing.app_id_fingerprint === desired.appIdFingerprint &&
    pairing.allowed_users[0] === desired.allowedUser &&
    pairing.allowed_chats[0] === desired.allowedChat &&
    binding?.status === "active" &&
    binding.chat_id === desired.allowedChat &&
    binding.session_id === identity.id &&
    binding.session_file_realpath === identity.file &&
    binding.session_cwd_realpath === identity.cwd &&
    binding.session_header_id === identity.headerId &&
    binding.session_header_cwd_realpath === identity.headerCwd;
}

export function convergeConfiguredSession(home, input, session, options = {}) {
  const desired = {
    appIdFingerprint: requireString(input.appIdFingerprint, "app id fingerprint", /^sha256:[a-f0-9]{64}$/),
    allowedUser: requireString(input.allowedUser, "allowed user open_id", /^ou_[A-Za-z0-9_-]{4,128}$/),
    allowedChat: requireString(input.allowedChat, "allowed P2P chat_id", /^oc_[A-Za-z0-9_-]{4,128}$/),
  };
  const identity = validateSessionIdentity(session);
  const paths = ensurePrivateLayout(home);
  const converge = () => {
    repairInboundPublicationsLocked(paths);
    const priorPairingRaw = readJson(paths.pairing, { optional: true });
    const priorPairing = priorPairingRaw ? validatePairingRecord(priorPairingRaw) : undefined;
    const priorBindingRaw = readJson(paths.activeBinding, { optional: true });
    const priorBinding = priorBindingRaw ? validateBindingRecord(priorBindingRaw) : undefined;
    let priorIdentityConsistent = true;
    try {
      assertConfigurationIdentity(paths, priorPairing, priorBinding);
    } catch (error) {
      if (priorPairing?.managed_by !== "local-config" && priorBinding?.bound_by !== "local-config") throw error;
      priorIdentityConsistent = false;
    }
    const pairingMatches = priorPairing?.app_id_fingerprint === desired.appIdFingerprint &&
      priorPairing.allowed_users[0] === desired.allowedUser &&
      priorPairing.allowed_chats[0] === desired.allowedChat;
    const bindingMatches = pairingMatches &&
      priorPairing?.disabled_at === null &&
      priorBinding?.status === "active" &&
      priorBinding.chat_id === desired.allowedChat &&
      priorBinding.session_id === identity.id &&
      priorBinding.session_file_realpath === identity.file &&
      priorBinding.session_cwd_realpath === identity.cwd &&
      priorBinding.session_header_id === identity.headerId &&
      priorBinding.session_header_cwd_realpath === identity.headerCwd;
    if (bindingMatches) {
      if (options.hardTakeover) fencePriorLiveSessionsLocked(paths);
      if (JSON.stringify(priorPairing.inbound_types) === JSON.stringify(SUPPORTED_INBOUND_TYPES)) return { changed: false, pairing: priorPairing, binding: priorBinding };
      const upgradedPairing = { ...priorPairing, inbound_types: [...SUPPORTED_INBOUND_TYPES], updated_at: nowIso() };
      atomicJson(paths.pairing, upgradedPairing);
      return { changed: true, pairing: upgradedPairing, binding: priorBinding };
    }
    if (!options.hardTakeover || !pairingMatches || !priorIdentityConsistent) {
      for (const name of safeJsonNames(paths.inboundPending)) {
        const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
        if (ledger.state === "offered") throw new Error("cannot replace a configured Feishu binding while a message belongs to the prior Pi native queue");
      }
    }
    const generation = Number(priorBinding?.generation ?? 0) + 1;
    if (!Number.isSafeInteger(generation) || generation <= 0) throw new Error("invalid Feishu binding generation");
    const homeId = priorPairing?.home_id ?? `home_${randomBytes(16).toString("hex")}`;
    const pairing = {
      schema: PAIRING_SCHEMA,
      home_id: homeId,
      fm_home_realpath: paths.home,
      app_id_fingerprint: desired.appIdFingerprint,
      allowed_users: [desired.allowedUser],
      allowed_chats: [desired.allowedChat],
      chat_policy: "p2p-only",
      inbound_types: [...SUPPORTED_INBOUND_TYPES],
      managed_by: "local-config",
      created_at: priorPairing?.created_at ?? nowIso(),
      updated_at: nowIso(),
      disabled_at: null,
    };
    const bindingId = stableId("bind_", `${homeId}\0${generation}\0${identity.id}\0${identity.file}`, 24);
    const binding = {
      schema: BINDING_SCHEMA,
      binding_id: bindingId,
      home_id: homeId,
      fm_home_realpath: paths.home,
      chat_id: desired.allowedChat,
      thread_policy: "bound-chat-mirror",
      session_id: identity.id,
      session_file_realpath: identity.file,
      session_cwd_realpath: identity.cwd,
      session_header_id: identity.headerId,
      session_header_cwd_realpath: identity.headerCwd,
      outbound_after_entry_id: identity.outboundAfterEntryId,
      generation,
      status: "active",
      bound_by: "local-config",
      bound_at: nowIso(),
      previous_binding_id: priorBinding?.binding_id ?? null,
    };
    if (pairingMatches && priorIdentityConsistent) {
      retargetPendingIngressLocked(paths, binding, { includeOffered: options.hardTakeover === true });
      if (options.hardTakeover) retargetPendingOutboundLocked(paths, priorBinding, binding);
    } else {
      for (const name of safeJsonNames(paths.inboundPending)) {
        const path = join(paths.inboundLedger, name);
        const ledger = requireSchema(readJson(path), INBOUND_LEDGER_SCHEMA, "inbound ledger");
        if (ledger.state !== "pending") continue;
        atomicJson(path, {
          ...ledger,
          state: "superseded",
          superseded_at: nowIso(),
          last_error: "configured Feishu identity changed before native Pi submission",
        });
        removeInboundPendingIndex(paths, name);
      }
      syncInboundPendingCount(paths);
    }
    if (options.hardTakeover) fencePriorLiveSessionsLocked(paths);
    atomicJson(paths.pairing, pairing);
    atomicJson(join(paths.bindings, `generation-${String(generation).padStart(8, "0")}.json`), binding);
    atomicJson(paths.activeBinding, binding);
    return { changed: true, pairing, binding };
  };
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => (
    options.hardTakeover
      ? withLock(paths, "outbound-state", () => withLock(paths, "live-session", converge))
      : converge()
  )));
}

function retargetPendingIngressLocked(paths, binding, { includeOffered = false } = {}) {
  repairInboundPublicationsLocked(paths);
  const names = safeJsonNames(paths.inboundPending);
  for (const name of names) {
    const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (ledger.state === "offered" && !includeOffered) throw new Error("cannot rebind while a Feishu message belongs to the current Pi native queue");
  }
  for (const name of names) {
    const path = join(paths.inboundLedger, name);
    const ledger = requireSchema(readJson(path), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (!new Set(["pending", ...(includeOffered ? ["offered"] : [])]).has(ledger.state)) continue;
    const event = validateInboundEvent(readJson(join(paths.inbox, name)));
    atomicJson(path, {
      ...ledger,
      state: "pending",
      offered_at: null,
      original_binding_id: ledger.original_binding_id ?? ledger.binding_id,
      original_binding_generation: ledger.original_binding_generation ?? ledger.binding_generation,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      target_session_id: binding.session_id,
      last_error: ledger.state === "offered" ? "prior Pi session was fenced before native queue delivery could be confirmed" : ledger.last_error,
      retargeted_at: nowIso(),
    });
    for (const part of event.content ?? []) {
      if (part.type !== "image") continue;
      const media = readInboundMedia(paths, part.media_id);
      if (media?.state !== "downloading") continue;
      atomicJson(mediaRecordPath(paths, media.media_id), {
        ...media,
        state: "pending",
        owner_nonce: null,
        next_attempt_at_ms: null,
        last_error_kind: "binding-takeover",
        download_started_at: null,
      });
    }
  }
  syncInboundPendingCount(paths);
}

function retargetPendingOutboundLocked(paths, priorBinding, binding) {
  repairOutboundStateLocked(paths, priorBinding);
  if (!priorBinding) return;
  for (const name of safeJsonNames(paths.outboundRegistrationIntents)) {
    const path = join(paths.outboundRegistrationIntents, name);
    const intent = validateOutboundIntent(readJson(path));
    if (intent.binding_id !== priorBinding.binding_id || intent.binding_generation !== priorBinding.generation || intent.session_id !== priorBinding.session_id) continue;
    atomicJson(path, {
      ...intent,
      original_binding_id: intent.original_binding_id ?? intent.binding_id,
      original_binding_generation: intent.original_binding_generation ?? intent.binding_generation,
      original_session_id: intent.original_session_id ?? intent.session_id,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      session_id: binding.session_id,
      retargeted_at: nowIso(),
    });
  }
  for (const name of safeJsonNames(paths.outbox)) {
    const outboxPath = join(paths.outbox, name);
    const ledgerPath = join(paths.outboundLedger, name);
    const outbox = validateAnyOutbound(readJson(outboxPath));
    const ledger = validateOutboundLedger(readJson(ledgerPath));
    if (!["pending", "retryable", "sending"].includes(ledger.state)) continue;
    if (outbox.binding_id !== priorBinding.binding_id || outbox.binding_generation !== priorBinding.generation || outbox.session_id !== priorBinding.session_id) continue;
    const retargetedOutbox = {
      ...outbox,
      original_binding_id: outbox.original_binding_id ?? outbox.binding_id,
      original_binding_generation: outbox.original_binding_generation ?? outbox.binding_generation,
      original_session_id: outbox.original_session_id ?? outbox.session_id,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      session_id: binding.session_id,
      retargeted_at: nowIso(),
    };
    atomicJson(outboxPath, retargetedOutbox);
    atomicJson(ledgerPath, {
      ...ledger,
      original_binding_generation: ledger.original_binding_generation ?? ledger.binding_generation,
      binding_generation: binding.generation,
      retargeted_at: nowIso(),
    });
    writeOutboundPendingIndex(paths, name, retargetedOutbox);
  }
}

function fencePriorLiveSessionsLocked(paths) {
  for (const name of safeJsonNames(paths.liveSession)) {
    readJson(join(paths.liveSession, name));
    unlinkSync(join(paths.liveSession, name));
  }
  fsyncDirectory(paths.liveSession);
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
  const event = readJson(join(paths.inbox, map.filename), { optional: true });
  const ledger = readJson(join(paths.inboundLedger, map.filename));
  if (ledger.delivery_ref !== deliveryRef || ledger.message_id !== map.message_id || (event && (event.delivery_ref !== deliveryRef || event.message_id !== map.message_id))) throw new Error("Feishu inbound delivery lookup mismatch");
  if (!event && ledger.state !== "delivered") throw new Error("unfinished Feishu inbound delivery lost its message record");
  return { name: map.filename, event, ledger };
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

function mediaRecordPath(paths, mediaId) {
  requireString(mediaId, "inbound media id", /^media_[a-f0-9]{24}$/);
  return join(paths.inboundMedia, `${sha(mediaId)}.json`);
}

function readInboundMedia(paths, mediaId) {
  const record = readJson(mediaRecordPath(paths, mediaId), { optional: true });
  return record ? validateInboundMedia(record) : undefined;
}

function expectedAuthorizationSnapshot(pairing, inboundTypes = pairing.inbound_types) {
  return `sha256:${sha(JSON.stringify({
    app: pairing.app_id_fingerprint,
    user: pairing.allowed_users,
    chat: pairing.allowed_chats,
    type: inboundTypes,
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
    const snapshotTypes = event.schema === LEGACY_INBOUND_SCHEMA ? ["text"] : pairing.inbound_types;
    if (event.sender_id !== pairing.allowed_users[0] || event.chat_id !== pairing.allowed_chats[0] || !pairing.inbound_types.includes(event.message_type) || event.authorization_snapshot !== expectedAuthorizationSnapshot(pairing, snapshotTypes)) {
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
  for (const media of publication.media ?? []) {
    const mediaPath = join(paths.inboundMedia, `${sha(media.media_id)}.json`);
    const existingMedia = readJson(mediaPath, { optional: true });
    if (existingMedia && (
      existingMedia.media_id !== media.media_id ||
      existingMedia.message_id !== media.message_id ||
      existingMedia.delivery_ref !== media.delivery_ref ||
      existingMedia.part_index !== media.part_index ||
      existingMedia.resource_type !== media.resource_type ||
      existingMedia.resource_key_hash !== media.resource_key_hash
    )) throw new Error("conflicting immutable Feishu inbound media publication");
    if (!existingMedia) atomicJson(mediaPath, media);
  }
  writeInboundDeliveryMap(paths, publication.event);
  for (const eventId of publication.event.event_ids) recordInboundEventId(paths, eventId, publication.event.message_id, publication.event.delivery_ref);
  writeInboundPendingIndex(paths, name, publication.ledger);
  syncInboundPendingCount(paths);
  removeIndexedFile(join(paths.inboundPublications, name));
}

function publishInboundRecordsLocked(paths, event, ledger, media = []) {
  validateInboundEvent(event);
  validateInboundLedger(ledger);
  const name = inboundFilename(event.message_id);
  const publication = {
    schema: "fm-feishu-inbound-publication.v1",
    event,
    ledger,
    media,
    created_at: nowIso(),
  };
  const path = join(paths.inboundPublications, name);
  const prior = readJson(path, { optional: true });
  if (prior && JSON.stringify(prior) !== JSON.stringify(publication)) throw new Error("conflicting Feishu inbound publication intent");
  if (!prior) atomicJson(path, publication);
  completeInboundPublicationLocked(paths, name, prior ?? publication);
}

function repairInboundPublicationsLocked(paths) {
  finishInboundCleanupLocked(paths);
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

function normalizedInboundParts(raw, messageType, options) {
  if (messageType === "text") {
    const text = normalizeContent(raw.content ?? raw.text);
    if (text.trim().length === 0) throw new Error("empty-content");
    const maxBytes = positiveInteger(options.maxInboundBytes ?? process.env.FM_FEISHU_MAX_INBOUND_BYTES, DEFAULT_MAX_INBOUND_BYTES);
    if (Buffer.byteLength(text, "utf8") > maxBytes) throw new Error("overlength");
    return [{ type: "text", text }];
  }
  if (!Array.isArray(raw.content) || raw.content.length === 0) throw new Error("malformed-content");
  const maxAttachments = Math.min(positiveInteger(options.maxInboundAttachments ?? process.env.FM_FEISHU_MAX_INBOUND_ATTACHMENTS, DEFAULT_MAX_INBOUND_ATTACHMENTS), DEFAULT_MAX_INBOUND_ATTACHMENTS);
  const parts = [];
  let attachmentCount = 0;
  let textBytes = 0;
  let unsupportedType = null;
  for (const part of raw.content) {
    if (!part || typeof part !== "object" || Array.isArray(part)) throw new Error("malformed-content");
    if (part.type === "text") {
      const text = normalizeContent(part.text);
      textBytes += Buffer.byteLength(text, "utf8");
      if (text.length > 0) {
        const prior = parts.at(-1);
        if (prior?.type === "text") prior.text += text;
        else parts.push({ type: "text", text });
      }
      continue;
    }
    if (part.type === "image") {
      attachmentCount += 1;
      const resourceKey = requireString(part.resource_key, "inbound image resource key", /^[A-Za-z0-9._-]{4,512}$/);
      parts.push({ type: "image", resourceKey });
      continue;
    }
    if (part.type === "unsupported") {
      unsupportedType ??= typeof part.media_type === "string" && /^[a-z0-9._-]{1,80}$/.test(part.media_type) ? part.media_type : "unknown";
      continue;
    }
    throw new Error("unsupported-content");
  }
  const maxBytes = positiveInteger(options.maxInboundBytes ?? process.env.FM_FEISHU_MAX_INBOUND_BYTES, DEFAULT_MAX_INBOUND_BYTES);
  if (textBytes > maxBytes) throw new Error("overlength");
  if (attachmentCount > maxAttachments) throw new Error("attachment-count-limit");
  if (unsupportedType !== null) {
    const error = new Error("unsupported-content");
    error.unsupportedType = unsupportedType;
    throw error;
  }
  const meaningful = parts.some((part) => part.type === "image" || part.text.trim().length > 0);
  if (!meaningful || (messageType === "image" && (parts.length !== 1 || attachmentCount !== 1))) throw new Error("malformed-content");
  return parts;
}

export function publishFeishuInbound(home, raw, options = {}) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  assertConfigurationIdentity(paths, pairing, binding);
  const audit = {
    event_id_hash: typeof raw?.event_id === "string" ? sha(raw.event_id) : null,
    message_id_hash: typeof raw?.message_id === "string" ? sha(raw.message_id) : null,
    sender_id_hash: typeof raw?.sender_id === "string" ? sha(raw.sender_id) : null,
    chat_id_hash: typeof raw?.chat_id === "string" ? sha(raw.chat_id) : null,
    sender_type: raw?.sender_type ?? null,
    chat_type: raw?.chat_type ?? null,
    message_type: raw?.message_type ?? raw?.msg_type ?? null,
    content_size_bytes: Number.isSafeInteger(raw?.content_size_bytes) && raw.content_size_bytes >= 0 ? raw.content_size_bytes : null,
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
  if (existsSync(join(paths.inbox, filename)) || existsSync(join(paths.inboundLedger, filename)) || inboundEventIdExists(paths, raw.event_id) || processedInboundIdentity(paths, stableId("in_", `${pairing.home_id}\0${messageId}`, 24))) {
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
  let contentParts = [];
  if (!reject) {
    try {
      contentParts = normalizedInboundParts(raw, messageType, options);
    } catch (error) {
      reject = new Set(["empty-content", "overlength", "unsupported-content", "attachment-count-limit"]).has(error?.message)
        ? error.message
        : "malformed-content";
      if (error?.unsupportedType) audit.unsupported_media_type = error.unsupportedType;
    }
  }
  if (reject) {
    quarantine(paths, reject, messageId, { ...audit, message_id_hash: sha(messageId) });
    if (reject === "unsupported-type" || reject === "unsupported-content") {
      createLocalAlert(paths, "inbound-unsupported-input", stableId("in_", messageId, 24), "Feishu input used a rich-media type that this Pi channel cannot represent safely and was not delivered.");
    }
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
    if (existsSync(join(paths.inbox, filename)) || existsSync(join(paths.inboundLedger, filename)) || inboundEventIdExists(paths, raw.event_id) || processedInboundIdentity(paths, stableId("in_", `${pairing.home_id}\0${messageId}`, 24))) {
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
    const media = [];
    const durableContent = contentParts.map((part, partIndex) => {
      if (part.type === "text") return part;
      const mediaId = stableId("media_", `${deliveryRef}\0${partIndex}\0${sha(part.resourceKey)}`, 24);
      media.push({
        schema: INBOUND_MEDIA_SCHEMA,
        media_id: mediaId,
        message_id: messageId,
        delivery_ref: deliveryRef,
        part_index: partIndex,
        resource_type: "image",
        resource_key: part.resourceKey,
        resource_key_hash: `sha256:${sha(part.resourceKey)}`,
        state: "pending",
        attempts: 0,
        next_attempt_at_ms: null,
        owner_nonce: null,
        mime_type: null,
        byte_length: null,
        byte_hash: null,
        cache_filename: null,
        last_error_kind: null,
        created_at: nowIso(),
        download_started_at: null,
        ready_at: null,
        failed_at: null,
      });
      return { type: "image", media_id: mediaId };
    });
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
      content: durableContent,
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
    publishInboundRecordsLocked(paths, event, ledger, media);
    return { status: "published", ingressSeq, deliveryRef, messageIdHash: sha(messageId) };
  }));
}

export function pendingFeishuMedia(home, ownerFence, options = {}) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => {
    const binding = readJson(paths.activeBinding, { optional: true });
    if (!binding || binding.status !== "active" || binding.binding_id !== ownerFence.bindingId || binding.generation !== ownerFence.bindingGeneration || binding.session_id !== ownerFence.sessionId) {
      throw new Error("Feishu media download binding fence mismatch");
    }
    const claims = [];
    const ownerNonce = requireString(ownerFence.ownerNonce, "Feishu media owner nonce", /^[a-f0-9]{24,128}$/);
    const staleMs = positiveInteger(options.downloadStaleMs ?? process.env.FM_FEISHU_MEDIA_DOWNLOAD_STALE_MS, 5 * 60 * 1000);
    for (const name of safeJsonNames(paths.inboundMedia)) {
      const path = join(paths.inboundMedia, name);
      const media = validateInboundMedia(readJson(path));
      if (media.state === "ready" || media.state === "failed") continue;
      if (media.state === "pending" && media.next_attempt_at_ms != null && media.next_attempt_at_ms > Date.now()) continue;
      if (media.state === "downloading" && Date.now() - Date.parse(media.download_started_at) < staleMs) continue;
      const inboundName = inboundFilename(media.message_id);
      const event = readJson(join(paths.inbox, inboundName), { optional: true });
      const ledger = readJson(join(paths.inboundLedger, inboundName), { optional: true });
      if (!event || !ledger || event.delivery_ref !== media.delivery_ref || !new Set(["pending", "offered"]).has(ledger.state) || ledger.binding_id !== binding.binding_id || ledger.binding_generation !== binding.generation || ledger.target_session_id !== binding.session_id) continue;
      assertInboundPair(paths, inboundName, event, ledger, { binding });
      const claimed = {
        ...media,
        state: "downloading",
        attempts: media.attempts + 1,
        owner_nonce: ownerNonce,
        last_error_kind: null,
        next_attempt_at_ms: null,
        download_started_at: nowIso(),
        failed_at: null,
      };
      atomicJson(path, claimed);
      claims.push(claimed);
    }
    return claims.sort((a, b) => a.message_id.localeCompare(b.message_id) || a.part_index - b.part_index);
  }));
}

export function completeFeishuMediaDownload(home, claim, bytes, evidence, ownerFence, options = {}) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => {
    const binding = readJson(paths.activeBinding, { optional: true });
    if (!binding || binding.status !== "active" || binding.binding_id !== ownerFence.bindingId || binding.generation !== ownerFence.bindingGeneration || binding.session_id !== ownerFence.sessionId) {
      throw new Error("Feishu media completion binding fence mismatch");
    }
    const current = readInboundMedia(paths, claim.media_id);
    if (!current || current.state !== "downloading" || current.owner_nonce !== ownerFence.ownerNonce || current.attempts !== claim.attempts || current.resource_key_hash !== claim.resource_key_hash) {
      throw new Error("Feishu media download claim changed before completion");
    }
    if (!(bytes instanceof Uint8Array) || bytes.length === 0) throw new Error("empty Feishu media download");
    const mediaBytes = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const maxObjectBytes = Math.min(positiveInteger(options.maxMediaBytes ?? process.env.FM_FEISHU_MAX_INBOUND_MEDIA_BYTES, DEFAULT_MAX_INBOUND_MEDIA_BYTES), DEFAULT_MAX_INBOUND_MEDIA_BYTES);
    if (mediaBytes.length > maxObjectBytes) throw new Error("Feishu media object exceeded its byte limit");
    if (evidence.declaredResourceType !== current.resource_type) throw new Error("Feishu media declared resource type mismatch");
    const responseMime = requireString(evidence.responseMimeType, "response Feishu media MIME type", /^image\/[a-z0-9.+-]+$/, 128).toLowerCase();
    const actualMime = requireString(evidence.actualMimeType, "actual Feishu media MIME type", /^image\/[a-z0-9.+-]+$/, 128).toLowerCase();
    if (!SUPPORTED_IMAGE_MIME_TYPES.has(responseMime) || responseMime !== actualMime) throw new Error("Feishu media content type mismatch");
    const byteHash = `sha256:${createHash("sha256").update(mediaBytes).digest("hex")}`;
    const cacheFilename = `${sha(current.media_id)}.bin`;
    const maxMessageBytes = Math.min(positiveInteger(options.maxMessageMediaBytes ?? process.env.FM_FEISHU_MAX_INBOUND_MESSAGE_MEDIA_BYTES, DEFAULT_MAX_INBOUND_MESSAGE_MEDIA_BYTES), DEFAULT_MAX_INBOUND_MESSAGE_MEDIA_BYTES);
    let messageBytes = mediaBytes.length;
    for (const name of safeJsonNames(paths.inboundMedia)) {
      const media = validateInboundMedia(readJson(join(paths.inboundMedia, name)));
      if (media.media_id !== current.media_id && media.delivery_ref === current.delivery_ref && media.state === "ready") messageBytes += media.byte_length;
    }
    if (messageBytes > maxMessageBytes) throw new Error("Feishu media message exceeded its byte limit");
    const cachePath = join(paths.inboundMediaCache, cacheFilename);
    if (existsSync(cachePath)) {
      safeFile(cachePath);
      const cached = readFileSync(cachePath);
      if (cached.length !== mediaBytes.length || `sha256:${createHash("sha256").update(cached).digest("hex")}` !== byteHash) throw new Error("conflicting Feishu media cache bytes");
    } else {
      atomicWrite(cachePath, mediaBytes);
    }
    const ready = {
      ...current,
      state: "ready",
      owner_nonce: null,
      mime_type: actualMime,
      byte_length: mediaBytes.length,
      byte_hash: byteHash,
      cache_filename: cacheFilename,
      last_error_kind: null,
      next_attempt_at_ms: null,
      download_started_at: null,
      ready_at: nowIso(),
      failed_at: null,
    };
    atomicJson(mediaRecordPath(paths, current.media_id), ready);
    return { mediaId: ready.media_id, byteHash, byteLength: mediaBytes.length, mimeType: actualMime };
  }));
}

export function failFeishuMediaDownload(home, claim, errorKind, ownerFence, { terminal = false, retryAfterMs, nowMs } = {}) {
  const paths = ensurePrivateLayout(home);
  const now = Number.isSafeInteger(nowMs) ? nowMs : Date.now();
  return withLock(paths, "inbound-state", () => {
    const current = readInboundMedia(paths, claim.media_id);
    if (!current || current.state !== "downloading" || current.owner_nonce !== ownerFence.ownerNonce || current.attempts !== claim.attempts) return false;
    const kind = requireString(errorKind, "Feishu media error kind", /^[a-z0-9-]+$/, 80);
    let nextAttemptAtMs = null;
    if (!terminal) {
      let delay;
      if (retryAfterMs !== undefined) {
        delay = Number(retryAfterMs);
        if (!Number.isSafeInteger(delay) || delay < 0) throw new Error("invalid Feishu Retry-After delay");
        delay = Math.min(RETRY_MAX_MS, delay);
      } else {
        delay = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.min(10, current.attempts - 1));
      }
      nextAttemptAtMs = now + delay;
    }
    atomicJson(mediaRecordPath(paths, current.media_id), {
      ...current,
      state: terminal ? "failed" : "pending",
      owner_nonce: null,
      last_error_kind: kind,
      next_attempt_at_ms: nextAttemptAtMs,
      download_started_at: null,
      failed_at: terminal ? nowIso() : null,
    });
    if (terminal) {
      const name = inboundFilename(current.message_id);
      const ledgerPath = join(paths.inboundLedger, name);
      const ledger = readJson(ledgerPath, { optional: true });
      if (ledger && new Set(["pending", "offered"]).has(ledger.state)) {
        atomicJson(ledgerPath, {
          ...ledger,
          state: "superseded",
          offered_at: null,
          superseded_at: nowIso(),
          last_error: `media-${kind}`,
        });
        removeInboundPendingIndex(paths, name);
        syncInboundPendingCount(paths);
        createLocalAlert(paths, "inbound-media-refused", ledger.delivery_ref, "Feishu rich-media input was refused before Pi delivery; inspect the private media state for the non-sensitive failure category.");
      }
    }
    return true;
  });
}

function readyMediaForEvent(paths, event) {
  const result = new Map();
  let totalBytes = 0;
  for (const part of event.content ?? []) {
    if (part.type !== "image") continue;
    const media = readInboundMedia(paths, part.media_id);
    if (!media || media.message_id !== event.message_id || media.delivery_ref !== event.delivery_ref || media.state !== "ready") return undefined;
    const cachePath = join(paths.inboundMediaCache, media.cache_filename);
    safeFile(cachePath);
    const bytes = readFileSync(cachePath);
    const byteHash = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
    if (bytes.length !== media.byte_length || byteHash !== media.byte_hash) throw new Error("Feishu media cache no longer matches durable byte evidence");
    totalBytes += bytes.length;
    if (totalBytes > DEFAULT_MAX_INBOUND_MESSAGE_MEDIA_BYTES) throw new Error("Feishu media message exceeded its byte limit");
    result.set(part.media_id, { data: bytes.toString("base64"), mimeType: media.mime_type });
  }
  return result;
}

export function loadFeishuIngressContent(home, event) {
  const paths = ensurePrivateLayout(home);
  validateInboundEvent(event);
  if (event.schema === PROCESSED_INBOUND_SCHEMA) return undefined;
  if (event.schema === LEGACY_INBOUND_SCHEMA) return [{ type: "text", text: event.text }];
  const media = readyMediaForEvent(paths, event);
  if (!media) return undefined;
  return event.content.map((part) => part.type === "text" ? { type: "text", text: part.text } : { type: "image", ...media.get(part.media_id) });
}

function cleanupFeishuMediaLocked(paths, nowMs, retentionMs) {
  const removable = [];
  const retainedCacheNames = new Set();
  for (const name of safeJsonNames(paths.inboundMedia)) {
    const path = join(paths.inboundMedia, name);
    const media = validateInboundMedia(readJson(path));
    const ledger = readJson(join(paths.inboundLedger, inboundFilename(media.message_id)), { optional: true });
    const terminalAt = ledger?.state === "delivered" ? ledger.delivered_at : ledger?.state === "superseded" ? ledger.superseded_at : null;
    if (!terminalAt || nowMs - Date.parse(terminalAt) < retentionMs) {
      if (media.cache_filename) retainedCacheNames.add(media.cache_filename);
      continue;
    }
    removable.push({ name, path, media });
  }
  let removedRecords = 0;
  let removedBytes = 0;
  for (const item of removable) {
    if (item.media.cache_filename && !retainedCacheNames.has(item.media.cache_filename)) {
      const cachePath = join(paths.inboundMediaCache, item.media.cache_filename);
      if (existsSync(cachePath)) {
        safeFile(cachePath);
        const stat = lstatSync(cachePath);
        removedBytes += stat.size;
        unlinkSync(cachePath);
        fsyncDirectory(paths.inboundMediaCache);
      }
    }
    unlinkSync(item.path);
    fsyncDirectory(paths.inboundMedia);
    removedRecords += 1;
  }
  return { removedRecords, removedBytes };
}

export function cleanupFeishuMedia(home, options = {}) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    const nowMs = Number.isSafeInteger(options.nowMs) ? options.nowMs : Date.now();
    const retentionMs = Math.max(1, Number.isSafeInteger(options.retentionMs) && options.retentionMs > 0
      ? options.retentionMs
      : positiveInteger(process.env.FM_FEISHU_MEDIA_RETENTION_MS, DEFAULT_INBOUND_MEDIA_RETENTION_MS));
    return cleanupFeishuMediaLocked(paths, nowMs, retentionMs);
  });
}

function inboundEventHasBody(event) {
  return event.schema !== PROCESSED_INBOUND_SCHEMA;
}

// These constant-size intents exist only while unlinking one proven terminal
// record. Replay them before reading active records after an interrupted cleanup.
function processedInboundIdentity(paths, deliveryRef) {
  const record = readJson(join(paths.inboundEventIds, `${sha(`processed\0${deliveryRef}`)}.json`), { optional: true });
  if (record) requireSchema(record, "fm-feishu-processed-inbound-id.v1", "processed inbound identity");
  return record;
}

function finishInboundCleanupLocked(paths) {
  const intent = readJson(paths.inboundCleanup, { optional: true });
  if (!intent) return;
  const ledger = readJson(join(paths.inboundLedger, intent.filename), { optional: true });
  const event = readJson(join(paths.inbox, intent.filename), { optional: true });
  const map = readJson(join(paths.inboundDeliveryMap, `${sha(intent.delivery_ref)}.json`), { optional: true });
  const prior = processedInboundIdentity(paths, intent.delivery_ref);
  if ((ledger && (ledger.state !== "delivered" || ledger.delivery_ref !== intent.delivery_ref || ledger.binding_generation !== intent.binding_generation)) ||
      (event && event.delivery_ref !== intent.delivery_ref) || (map && map.filename !== intent.filename) ||
      (prior && prior.binding_generation !== intent.binding_generation)) throw new Error("inbound cleanup intent conflicts with remaining evidence");
  if (event && ledger) assertInboundPair(paths, intent.filename, event, ledger);
  atomicJson(join(paths.inboundEventIds, `${sha(`processed\0${intent.delivery_ref}`)}.json`), {
    schema: "fm-feishu-processed-inbound-id.v1",
    binding_generation: intent.binding_generation,
  });
  removeIndexedFile(join(paths.inbox, intent.filename));
  removeInboundPendingIndex(paths, intent.filename);
  removeIndexedFile(join(paths.inboundDeliveryMap, `${sha(intent.delivery_ref)}.json`));
  removeIndexedFile(join(paths.inboundLedger, intent.filename));
  syncInboundPendingCount(paths);
  removeIndexedFile(paths.inboundCleanup);
}

function validateCompletedReceipt(receipt) {
  validateOutboundReceipt(receipt);
  requireString(receipt.text_hash, "completed outbound text hash", RECORD_HASH);
  if (!receipt.message_ids.length || receipt.message_ids.length !== receipt.idempotency_keys.length || receipt.idempotency_keys.some((key, index) => key !== stableId("fm", `${receipt.event_id}\0${index}`, 44))) {
    throw new Error("invalid completed outbound receipt");
  }
  return receipt;
}

function finishOutboundCleanupLocked(paths) {
  const intent = readJson(paths.outboundCleanup, { optional: true });
  if (!intent) return;
  const receipt = validateCompletedReceipt(intent.receipt);
  const name = `${sha(receipt.event_id)}.json`;
  const ledger = readJson(join(paths.outboundLedger, name), { optional: true });
  const outbox = readJson(join(paths.outbox, name), { optional: true });
  if (ledger && (ledger.state !== "posted" || ledger.next_chunk !== receipt.message_ids.length)) throw new Error("outbound cleanup intent conflicts with remaining ledger");
  if (outbox && (outbox.text_hash !== receipt.text_hash || outbox.destination_chat_id !== receipt.chat_id || (outbox.chunk_count ?? outbox.chunks.length) !== receipt.message_ids.length)) throw new Error("outbound cleanup intent conflicts with remaining body");
  atomicJson(join(paths.outboundReceipts, name), receipt);
  removeIndexedFile(join(paths.outbox, name));
  removeOutboundPendingIndex(paths, name);
  removeIndexedFile(join(paths.outboundLedger, name));
  removeIndexedFile(paths.outboundCleanup);
}

function cleanupProcessedInboundBodiesLocked(paths, nowMs) {
  repairInboundPublicationsLocked(paths);
  // Media eligibility still needs the terminal ledger, so retire it first.
  const media = cleanupFeishuMediaLocked(paths, nowMs, 0);
  let filesBefore = 0;
  let filesAfter = 0;
  let removedLedgers = 0;
  const removedDeliveryRefs = [];
  for (const name of safeJsonNames(paths.inboundLedger)) {
    const ledger = validateInboundLedger(readJson(join(paths.inboundLedger, name)));
    const rawEvent = readJson(join(paths.inbox, name), { optional: true });
    if (rawEvent) {
      assertInboundPair(paths, name, rawEvent, ledger);
      filesBefore += 1;
    } else if (ledger.state !== "delivered") throw new Error("unfinished Feishu inbound ledger lost its message record");
    if (ledger.state !== "delivered") {
      filesAfter += 1;
      continue;
    }
    const map = readJson(join(paths.inboundDeliveryMap, `${sha(ledger.delivery_ref)}.json`));
    if (map.filename !== name || map.message_id !== ledger.message_id) throw new Error("processed inbound map identity mismatch");
    atomicJson(paths.inboundCleanup, {
      schema: "fm-feishu-inbound-cleanup.v1", filename: name,
      delivery_ref: ledger.delivery_ref, binding_generation: ledger.binding_generation,
    });
    finishInboundCleanupLocked(paths);
    removedLedgers += 1;
    removedDeliveryRefs.push(ledger.delivery_ref);
  }
  return {
    filesBefore, filesAfter, removedFiles: filesBefore - filesAfter,
    removedLedgers, removedMaps: removedLedgers,
    retainedUnprocessedFiles: filesAfter, removedDeliveryRefs,
    removedMediaRecords: media.removedRecords, removedMediaBytes: media.removedBytes,
  };
}

function cleanupProcessedOutboundBodiesLocked(paths) {
  finishOutboundCleanupLocked(paths);
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  let filesBefore = 0;
  let filesAfter = 0;
  let removedFiles = 0;
  let removedLedgers = 0;
  // Never enumerate historical receipts in periodic cleanup. Only active
  // bodies/ledgers can need retirement; receipts are point-lookup evidence.
  const names = new Set([...safeJsonNames(paths.outbox), ...safeJsonNames(paths.outboundLedger)]);
  for (const name of names) {
    const outbox = readJson(join(paths.outbox, name), { optional: true });
    let ledger = readJson(join(paths.outboundLedger, name), { optional: true });
    let receipt = readJson(join(paths.outboundReceipts, name), { optional: true });
    if (outbox) {
      filesBefore += 1;
      ledger ??= newOutboundLedger(outbox);
      assertOutboundPair(name, outbox, ledger, binding);
      ({ ledger, receipt } = reconcileOutboundReceiptLocked(paths, name, outbox, ledger));
      if (ledger.state !== "posted") { filesAfter += 1; continue; }
      receipt = { ...receipt, text_hash: outbox.text_hash };
    } else {
      if (!ledger || !receipt) throw new Error("orphan Feishu outbound ledger");
      assertProcessedOutboundEvidence(name, ledger, receipt);
      receipt = { ...receipt, text_hash: ledger.text_hash };
    }
    validateCompletedReceipt(receipt);
    atomicJson(paths.outboundCleanup, { schema: "fm-feishu-outbound-cleanup.v1", receipt });
    finishOutboundCleanupLocked(paths);
    removedLedgers += 1;
    if (outbox) removedFiles += 1;
  }
  return { filesBefore, filesAfter, removedFiles, removedLedgers };
}

export function cleanupProcessedFeishuBodies(home, options = {}) {
  const paths = ensurePrivateLayout(home);
  const nowMs = Number.isSafeInteger(options.nowMs) ? options.nowMs : Date.now();
  const inbound = withLock(paths, "inbound-state", () => cleanupProcessedInboundBodiesLocked(paths, nowMs));
  const outbound = withLock(paths, "outbound-state", () => cleanupProcessedOutboundBodiesLocked(paths));
  return {
    filesBefore: inbound.filesBefore + outbound.filesBefore,
    filesAfter: inbound.filesAfter + outbound.filesAfter,
    removedFiles: inbound.removedFiles + outbound.removedFiles,
    retainedUnprocessedFiles: inbound.filesAfter + outbound.filesAfter,
    inbound,
    outbound,
    removedDeliveryRefs: inbound.removedDeliveryRefs,
  };
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
    const event = validateInboundEvent(readJson(join(paths.inbox, name)));
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
    const ledger = validateInboundLedger(readJson(join(paths.inboundLedger, name)));
    validDeliveryMaps.add(`${sha(ledger.delivery_ref)}.json`);
    const event = readJson(join(paths.inbox, name), { optional: true });
    if (event) assertInboundPair(paths, name, validateInboundEvent(event), ledger);
    else if (ledger.state !== "delivered") throw new Error("unfinished Feishu inbound ledger lost its message record");
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
    repairInboundPublicationsLocked(paths);
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    assertConfigurationIdentity(paths, pairing, binding);
    if (!pairingIsActive(pairing) || !binding || binding.status !== "active" || binding.session_id !== fence.sessionId || binding.binding_id !== fence.bindingId || binding.generation !== fence.bindingGeneration) return [];
    const pending = [];
    const candidates = [];
    for (const name of safeJsonNames(paths.inboundPending)) {
      const ledger = readJson(join(paths.inboundLedger, name));
      if (ledger.state !== "pending" || ledger.target_session_id !== fence.sessionId || ledger.binding_id !== fence.bindingId || ledger.binding_generation !== fence.bindingGeneration) continue;
      const event = readJson(join(paths.inbox, name));
      assertInboundPair(paths, name, event, ledger, { pairing, binding });
      candidates.push({ name, event, ledger });
    }
    candidates.sort((a, b) => a.ledger.ingress_seq - b.ledger.ingress_seq || a.name.localeCompare(b.name));
    for (const candidate of candidates) {
      if (!readyMediaForEvent(paths, candidate.event)) break;
      pending.push({ filename: candidate.name, event: deliveryEventForLedger(candidate.event, candidate.ledger), ledger: candidate.ledger });
    }
    return pending;
  }));
}

export function offerFeishuIngress(home, deliveryRef, fence) {
  const paths = ensurePrivateLayout(home);
  return withConfigurationLocks(paths, () => withLock(paths, "inbound-state", () => {
    repairInboundPublicationsLocked(paths);
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
    repairInboundPublicationsLocked(paths);
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
    return found?.event ? deliveryEventForLedger(found.event, found.ledger) : undefined;
  });
}

export function recordInboundContentDigest(home, deliveryRef, contentDigest) {
  const paths = ensurePrivateLayout(home);
  requireString(deliveryRef, "inbound delivery ref", DELIVERY_REF);
  requireString(contentDigest, "inbound content digest", RECORD_HASH);
  return withLock(paths, "inbound-state", () => {
    const found = readInboundByDeliveryRef(paths, deliveryRef);
    if (!found) throw new Error("Feishu inbound content evidence referenced an unknown delivery");
    if (found.ledger.content_digest === contentDigest) return false;
    if (found.ledger.content_digest != null) throw new Error("conflicting immutable Feishu inbound content evidence");
    atomicJson(join(paths.inboundLedger, found.name), { ...found.ledger, content_digest: contentDigest });
    return true;
  });
}

export function findInboundDeliveryEvidence(home, deliveryRef) {
  const paths = ensurePrivateLayout(home);
  requireString(deliveryRef, "inbound delivery ref", DELIVERY_REF);
  return withLock(paths, "inbound-state", () => {
    repairInboundPublicationsLocked(paths);
    const processed = processedInboundIdentity(paths, deliveryRef);
    if (processed) return { event: { delivery_ref: deliveryRef, binding_generation: processed.binding_generation }, bodyAvailable: false };
    const found = readInboundByDeliveryRef(paths, deliveryRef);
    if (!found) return undefined;
    return {
      event: found.event ? deliveryEventForLedger(found.event, found.ledger) : {
        delivery_ref: found.ledger.delivery_ref,
        binding_generation: found.ledger.binding_generation,
      },
      contentDigest: typeof found.ledger.content_digest === "string" ? found.ledger.content_digest : undefined,
      bodyAvailable: Boolean(found.event && inboundEventHasBody(found.event)),
    };
  });
}

export function claimLiveSession(home, binding, session, ownerToken) {
  const paths = ensurePrivateLayout(home);
  const path = join(paths.liveSession, `${sha(binding.binding_id)}.json`);
  return withLock(paths, "live-session", () => {
    const active = readJson(paths.activeBinding, { optional: true });
    if (!active || active.status !== "active" || active.binding_id !== binding.binding_id || active.generation !== binding.generation || active.session_id !== session.sessionId || active.session_file_realpath !== session.sessionFile || active.session_cwd_realpath !== session.sessionCwd) {
      return { ok: false, reason: "binding is no longer owned by this Pi session" };
    }
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

export function liveSessionOwnsBinding(home, binding, session, ownerToken) {
  const paths = pathsForHome(home);
  privateDir(paths.liveSession);
  const record = readJson(join(paths.liveSession, `${sha(binding.binding_id)}.json`), { optional: true });
  if (!record || record.binding_id !== binding.binding_id || record.binding_generation !== binding.generation || record.home_id !== binding.home_id || record.fm_home_realpath !== paths.home || record.session_id !== binding.session_id || record.session_file_realpath !== binding.session_file_realpath || record.session_cwd_realpath !== binding.session_cwd_realpath || !pidAlive(record.pid)) return false;
  if (session && (record.session_id !== session.sessionId || record.session_file_realpath !== session.sessionFile || record.session_cwd_realpath !== session.sessionCwd)) return false;
  if (ownerToken !== undefined && record.owner_token !== ownerToken) return false;
  return true;
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

function markdownFenceEnd(text, index) {
  if (index !== 0 && text[index - 1] !== "\n") return -1;
  let opener = index;
  while (opener < text.length && opener - index < 3 && text[opener] === " ") opener += 1;
  const marker = text[opener];
  if (marker !== "`" && marker !== "~") return -1;
  let markerEnd = opener;
  while (text[markerEnd] === marker) markerEnd += 1;
  const markerLength = markerEnd - opener;
  if (markerLength < 3) return -1;
  const openerLineEnd = text.indexOf("\n", markerEnd);
  if (marker === "`" && text.slice(markerEnd, openerLineEnd < 0 ? text.length : openerLineEnd).includes("`")) return -1;
  let lineStart = openerLineEnd < 0 ? text.length : openerLineEnd + 1;
  while (lineStart < text.length) {
    let candidate = lineStart;
    while (candidate < text.length && candidate - lineStart < 3 && text[candidate] === " ") candidate += 1;
    let candidateEnd = candidate;
    while (text[candidateEnd] === marker) candidateEnd += 1;
    const lineEnd = text.indexOf("\n", candidateEnd);
    const remainderEnd = lineEnd < 0 ? text.length : lineEnd;
    if (candidateEnd - candidate >= markerLength && /^[ \t]*$/.test(text.slice(candidateEnd, remainderEnd))) {
      return lineEnd < 0 ? text.length : lineEnd + 1;
    }
    lineStart = lineEnd < 0 ? text.length : lineEnd + 1;
  }
  return text.length;
}

function markdownCodeSpanEnd(text, index) {
  if (text[index] !== "`") return -1;
  let openerEnd = index;
  while (text[openerEnd] === "`") openerEnd += 1;
  const markerLength = openerEnd - index;
  for (let cursor = openerEnd; cursor < text.length;) {
    const candidate = text.indexOf("`", cursor);
    if (candidate < 0) return -1;
    let candidateEnd = candidate;
    while (text[candidateEnd] === "`") candidateEnd += 1;
    if (candidateEnd - candidate === markerLength) return candidateEnd;
    cursor = candidateEnd;
  }
  return -1;
}

function markdownLinkEnd(text, index) {
  const bracket = text[index] === "!" && text[index + 1] === "[" ? index + 1 : index;
  if (text[bracket] !== "[") return -1;
  let depth = 1;
  let cursor = bracket + 1;
  for (; cursor < text.length && depth > 0; cursor += 1) {
    if (text[cursor] === "\\") cursor += 1;
    else if (text[cursor] === "[") depth += 1;
    else if (text[cursor] === "]") depth -= 1;
  }
  if (depth !== 0 || text[cursor] !== "(") return -1;
  depth = 1;
  for (cursor += 1; cursor < text.length; cursor += 1) {
    if (text[cursor] === "\\") cursor += 1;
    else if (text[cursor] === "(") depth += 1;
    else if (text[cursor] === ")" && --depth === 0) return cursor + 1;
  }
  return -1;
}

function markdownAutolinkEnd(text, index) {
  if (text[index] !== "<" || !/^https?:\/\//.test(text.slice(index + 1))) return -1;
  const end = text.indexOf(">", index + 1);
  if (end < 0 || /\s/.test(text.slice(index + 1, end))) return -1;
  return end + 1;
}

function lineAt(text, index) {
  const lineEnd = text.indexOf("\n", index);
  const end = lineEnd < 0 ? text.length : lineEnd + 1;
  return { content: text.slice(index, lineEnd < 0 ? text.length : lineEnd), end };
}

function inlineLiteral(source) {
  const runs = source.match(/`+/gu) ?? [];
  const marker = "`".repeat(Math.max(1, ...runs.map((run) => run.length + 1)));
  const padding = /^[ `]|[ `]$/u.test(source) ? " " : "";
  return `${marker}${padding}${source}${padding}${marker}`;
}

function fencedLiteral(source, language) {
  const runs = source.match(/`+/gu) ?? [];
  const marker = "`".repeat(Math.max(3, ...runs.map((run) => run.length + 1)));
  const separator = source.endsWith("\n") ? "" : "\n";
  const suffix = source.endsWith("\n") ? "\n" : "";
  return `${marker}${language}\n${source}${separator}${marker}${suffix}`;
}

function findDelimited(text, start, opener, closer) {
  const end = text.indexOf(closer, start + opener.length);
  return end < 0 ? -1 : end + closer.length;
}

function inlinePostMarkdown(text) {
  let rendered = "";
  for (let cursor = 0; cursor < text.length;) {
    let end = markdownCodeSpanEnd(text, cursor);
    if (end >= 0) {
      rendered += text.slice(cursor, end);
      cursor = end;
      continue;
    }
    end = markdownLinkEnd(text, cursor);
    if (end >= 0) {
      const source = text.slice(cursor, end);
      rendered += text[cursor] === "!" ? inlineLiteral(source) : source;
      cursor = end;
      continue;
    }
    if (text[cursor] === "!") {
      const imageReference = text.slice(cursor).match(/^!\[(?:\\.|[^\]\n])*\](?:\[(?:\\.|[^\]\n])*\])?/u);
      if (imageReference) {
        rendered += inlineLiteral(imageReference[0]);
        cursor += imageReference[0].length;
        continue;
      }
    }
    end = markdownAutolinkEnd(text, cursor);
    if (end >= 0) {
      rendered += text.slice(cursor, end);
      cursor = end;
      continue;
    }
    if (text[cursor] === "<") {
      const mention = text.slice(cursor).match(/^<at\b[^>]*>(?:[\s\S]*?<\/at>)?/iu);
      const email = text.slice(cursor).match(/^<[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}>/iu);
      const html = text.slice(cursor).match(/^<\/?[A-Za-z][^>]*>/u);
      const source = mention?.[0] ?? email?.[0] ?? html?.[0];
      if (source) {
        rendered += inlineLiteral(source);
        cursor += source.length;
        continue;
      }
    }
    if (text[cursor] === "[" && /^\[\^[^\]\n]+\]/u.test(text.slice(cursor))) {
      const source = text.slice(cursor).match(/^\[\^[^\]\n]+\]/u)[0];
      rendered += inlineLiteral(source);
      cursor += source.length;
      continue;
    }
    if (text[cursor] === "\\" && text[cursor + 1] === "(") {
      end = findDelimited(text, cursor, "\\(", "\\)");
      if (end >= 0) {
        rendered += inlineLiteral(text.slice(cursor, end));
        cursor = end;
        continue;
      }
    }
    if (text[cursor] === "$" && text[cursor + 1] === "$" && !/\s/u.test(text[cursor + 2] ?? "")) {
      end = findDelimited(text, cursor, "$$", "$$");
      if (end >= 0) {
        rendered += inlineLiteral(text.slice(cursor, end));
        cursor = end;
        continue;
      }
    }
    if (text[cursor] === "$" && text[cursor + 1] !== "$" && !/\s/u.test(text[cursor + 1] ?? "")) {
      for (let candidate = cursor + 1; candidate < text.length; candidate += 1) {
        if (text[candidate] === "\\") {
          candidate += 1;
          continue;
        }
        if (text[candidate] === "$" && !/\s/u.test(text[candidate - 1] ?? "")) {
          end = candidate + 1;
          break;
        }
      }
      if (end >= 0) {
        rendered += inlineLiteral(text.slice(cursor, end));
        cursor = end;
        continue;
      }
    }
    const broadMention = text[cursor] === "@" ? text.slice(cursor).match(/^@(?:all|everyone|here)\b/iu) : null;
    if (broadMention && (cursor === 0 || /[\s([{]/u.test(text[cursor - 1]))) {
      rendered += inlineLiteral(broadMention[0]);
      cursor += broadMention[0].length;
      continue;
    }
    rendered += text[cursor];
    cursor += 1;
  }
  return rendered;
}

function blockUntil(text, index, closePattern) {
  let cursor = index;
  while (cursor < text.length) {
    const line = lineAt(text, cursor);
    cursor = line.end;
    if (closePattern.test(line.content)) return cursor;
  }
  return text.length;
}

function rawHtmlBlockEnd(text, index) {
  const line = lineAt(text, index);
  const trimmed = line.content.trimStart();
  if (/^<details(?:\s|>)/iu.test(trimmed)) return blockUntil(text, index, /<\/details\s*>/iu);
  if (/^<!--/u.test(trimmed)) return blockUntil(text, index, /-->/u);
  if (/^<\?/u.test(trimmed)) return blockUntil(text, index, /\?>/u);
  if (/^<!\[CDATA\[/iu.test(trimmed)) return blockUntil(text, index, /\]\]>/u);
  const tag = trimmed.match(/^<(script|pre|style|address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\s|\/?>)/iu);
  if (!tag) return -1;
  const closing = new RegExp(`<\\/${tag[1]}\\s*>`, "iu");
  if (closing.test(trimmed)) return line.end;
  let cursor = line.end;
  while (cursor < text.length) {
    const next = lineAt(text, cursor);
    if (closing.test(next.content)) return next.end;
    if (next.content.trim().length === 0) return cursor;
    cursor = next.end;
  }
  return text.length;
}

function indentedBlockEnd(text, index) {
  const first = lineAt(text, index);
  if (first.content.trim().length === 0 || !/^(?: {4}|\t)/u.test(first.content)) return -1;
  let cursor = index;
  let contentEnd = index;
  while (cursor < text.length) {
    const line = lineAt(text, cursor);
    if (line.content.trim().length !== 0 && !/^(?: {4}|\t)/u.test(line.content)) break;
    if (line.content.trim().length !== 0) contentEnd = line.end;
    cursor = line.end;
  }
  return contentEnd;
}

function footnoteDefinitionEnd(text, index) {
  if (!/^ {0,3}\[\^[^\]\n]+\]:/u.test(lineAt(text, index).content)) return -1;
  let cursor = lineAt(text, index).end;
  let contentEnd = cursor;
  while (cursor < text.length) {
    const line = lineAt(text, cursor);
    if (line.content.trim().length !== 0 && !/^(?: {2,}|\t)/u.test(line.content)) break;
    if (line.content.trim().length !== 0) contentEnd = line.end;
    cursor = line.end;
  }
  return contentEnd;
}

function blockMathEnd(text, index) {
  const line = lineAt(text, index);
  const trimmed = line.content.trim();
  if (trimmed.startsWith("$$")) {
    if (trimmed.length > 2 && trimmed.endsWith("$$")) return line.end;
    let cursor = line.end;
    while (cursor < text.length) {
      const candidate = lineAt(text, cursor);
      cursor = candidate.end;
      if (/\$\$\s*$/u.test(candidate.content)) return cursor;
    }
    return text.length;
  }
  if (trimmed.startsWith("\\[")) return blockUntil(text, index, /\\\]\s*$/u);
  const environment = trimmed.match(/^\\begin\{([^{}]+)\}/u);
  if (environment) return blockUntil(text, index, new RegExp(`\\\\end\\{${environment[1].replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}\\}\\s*$`, "u"));
  return -1;
}

export function renderFeishuPostMarkdown(text) {
  if (typeof text !== "string") throw new Error("Feishu post Markdown source is not text");
  let rendered = "";
  for (let cursor = 0; cursor < text.length;) {
    let end = markdownFenceEnd(text, cursor);
    if (end >= 0) {
      rendered += text.slice(cursor, end);
      cursor = end;
      continue;
    }
    const line = lineAt(text, cursor);
    const next = line.end < text.length ? lineAt(text, line.end) : undefined;
    if (line.content.trim().length > 0 && next && /^ {0,3}(?:=+|-+)\s*$/u.test(next.content)) {
      end = next.end;
      rendered += fencedLiteral(text.slice(cursor, end), "markdown");
      cursor = end;
      continue;
    }
    end = blockMathEnd(text, cursor);
    if (end >= 0) {
      rendered += fencedLiteral(text.slice(cursor, end), "text");
      cursor = end;
      continue;
    }
    end = rawHtmlBlockEnd(text, cursor);
    if (end >= 0) {
      rendered += fencedLiteral(text.slice(cursor, end), "html");
      cursor = end;
      continue;
    }
    end = footnoteDefinitionEnd(text, cursor);
    if (end >= 0) {
      rendered += fencedLiteral(text.slice(cursor, end), "markdown");
      cursor = end;
      continue;
    }
    end = indentedBlockEnd(text, cursor);
    if (end >= 0) {
      rendered += fencedLiteral(text.slice(cursor, end), "markdown");
      cursor = end;
      continue;
    }
    rendered += inlinePostMarkdown(text.slice(cursor, line.end));
    cursor = line.end;
  }
  const maximumBytes = Math.max(4096, utf8Bytes(text) * 4);
  if (utf8Bytes(rendered) > maximumBytes) throw new Error("Feishu post Markdown rendering exceeded its fixed expansion bound");
  return rendered;
}

function markdownTableEnd(text, index) {
  const header = lineAt(text, index);
  if (!header.content.includes("|") || header.end >= text.length) return -1;
  const delimiter = lineAt(text, header.end);
  if (!/^ {0,3}\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$/u.test(delimiter.content)) return -1;
  let cursor = delimiter.end;
  while (cursor < text.length) {
    const line = lineAt(text, cursor);
    if (line.content.trim().length === 0 || !line.content.includes("|")) break;
    cursor = line.end;
  }
  return cursor;
}

function markdownQuoteEnd(text, index) {
  if (!/^ {0,3}>/u.test(lineAt(text, index).content)) return -1;
  let cursor = index;
  while (cursor < text.length) {
    const line = lineAt(text, cursor);
    if (!/^ {0,3}>/u.test(line.content)) break;
    cursor = line.end;
  }
  return cursor;
}

function markdownListEnd(text, index) {
  const marker = /^ {0,3}(?:[-+*]|\d{1,9}[.)])[ \t]+/u;
  if (!marker.test(lineAt(text, index).content)) return -1;
  let cursor = index;
  let separated = false;
  while (cursor < text.length) {
    const line = lineAt(text, cursor);
    if (line.content.trim().length === 0) {
      separated = true;
      cursor = line.end;
      continue;
    }
    if (separated && !marker.test(line.content) && !/^(?: {2,}|\t)/u.test(line.content)) break;
    separated = false;
    cursor = line.end;
  }
  return cursor;
}

function markdownStructuralBlockEnd(text, index) {
  if (index !== 0 && text[index - 1] !== "\n") return -1;
  for (const detector of [markdownFenceEnd, markdownTableEnd, markdownQuoteEnd, markdownListEnd]) {
    const end = detector(text, index);
    if (end >= 0) return end;
  }
  return -1;
}

function markdownUnits(text, maxBytes) {
  const units = [];
  let plainStart = 0;
  let cursor = 0;
  while (cursor < text.length) {
    let protectedEnd = markdownStructuralBlockEnd(text, cursor);
    if (protectedEnd < 0) protectedEnd = markdownCodeSpanEnd(text, cursor);
    if (protectedEnd < 0) protectedEnd = markdownLinkEnd(text, cursor);
    if (protectedEnd < 0) protectedEnd = markdownAutolinkEnd(text, cursor);
    if (protectedEnd < 0) {
      cursor += 1;
      continue;
    }
    if (plainStart < cursor) {
      const plain = text.slice(plainStart, cursor);
      units.push(...plain.split(/(?<=\n\n)/u).flatMap((paragraph) => splitUnit(paragraph, maxBytes)));
    }
    const protectedUnit = text.slice(cursor, protectedEnd);
    if (utf8Bytes(protectedUnit) > maxBytes) throw new Error("a complete Markdown construct exceeds the Feishu chunk size");
    units.push(protectedUnit);
    cursor = protectedEnd;
    plainStart = cursor;
  }
  if (plainStart < text.length) {
    const plain = text.slice(plainStart);
    units.push(...plain.split(/(?<=\n\n)/u).flatMap((paragraph) => splitUnit(paragraph, maxBytes)));
  }
  return units;
}

export function deterministicChunks(text, maxBytes = DEFAULT_MAX_OUTBOUND_CHUNK_BYTES) {
  maxBytes = positiveInteger(maxBytes, DEFAULT_MAX_OUTBOUND_CHUNK_BYTES);
  if (utf8Bytes(text) <= maxBytes) return [text];
  const chunks = packUnits(markdownUnits(text, maxBytes), maxBytes);
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
  return stableId("out_", `${homeId}\0${input.bindingGeneration}\0${input.sessionId}\0${input.assistantEntryId}`, 40);
}

function outboundEventIdForIntent(homeId, intent) {
  if (intent.event_id) return intent.event_id;
  return outboundEventId(homeId, {
    bindingGeneration: intent.original_binding_generation ?? intent.binding_generation,
    sessionId: intent.original_session_id ?? intent.session_id,
    assistantEntryId: intent.assistant_entry_id,
  });
}

function outboundLogicalQueueCount(paths, pairing) {
  const pending = new Set(safeJsonNames(paths.outboundPending));
  let count = pending.size;
  for (const name of safeJsonNames(paths.outboundRegistrationIntents)) {
    const intent = validateOutboundIntent(readJson(join(paths.outboundRegistrationIntents, name)));
    const eventId = outboundEventIdForIntent(pairing.home_id, intent);
    if (!pending.has(`${sha(eventId)}.json`)) count += 1;
  }
  return count;
}

function maxPendingOutbound(input = {}) {
  return positiveInteger(input.maxPendingOutbound ?? process.env.FM_FEISHU_MAX_PENDING_OUTBOUND, DEFAULT_MAX_PENDING_OUTBOUND);
}

function assertOutboundPair(name, outbox, ledger, binding) {
  validateAnyOutbound(outbox);
  validateOutboundLedger(ledger);
  const chunkCount = outbox.schema === PROCESSED_OUTBOUND_SCHEMA ? outbox.chunk_count : outbox.chunks.length;
  if (name !== `${sha(outbox.event_id)}.json` || ledger.event_id !== outbox.event_id || ledger.binding_generation !== outbox.binding_generation || ledger.next_chunk > chunkCount) throw new Error("Feishu outbox and ledger identity do not match");
  if (outbox.schema === PROCESSED_OUTBOUND_SCHEMA && ledger.state !== "posted") throw new Error("processed Feishu outbox lacks authoritative posted state");
  if (binding && outbox.binding_generation === binding.generation && (outbox.binding_id !== binding.binding_id || outbox.session_id !== binding.session_id || outbox.destination_chat_id !== binding.chat_id)) throw new Error("Feishu outbox destination does not match the active binding");
}

// A finalized Assistant response equal to a fixed routine acknowledgement is
// never created as a new outbox, but a record persisted by an earlier build
// whose exact filter missed surrounding whitespace can still sit active in the
// outbox. Reconciliation neutralizes such a record locally by driving its
// ledger to the terminal superseded state, so no chunk is ever sent, rather
// than crashing ingress. Event id, binding generation, and the chunk cursor are
// preserved, so persisted-entry identity and delivery cursors are unchanged.
function supersedeRoutineOutboundLedger(ledger) {
  return { ...ledger, state: "superseded", superseded_at: nowIso(), last_error: "finalized Assistant response is a fixed routine acknowledgement kept local" };
}

function reconcileOutboundReceiptLocked(paths, name, outbox, ledger) {
  const receipt = readJson(join(paths.outboundReceipts, name), { optional: true });
  const receivedChunks = receipt?.message_ids.length ?? 0;
  const chunkCount = outbox.schema === PROCESSED_OUTBOUND_SCHEMA ? outbox.chunk_count : outbox.chunks.length;
  let repaired = 0;
  if (receipt) {
    const mismatchedIdempotency = outbox.schema === PROCESSED_OUTBOUND_SCHEMA
      ? receipt.idempotency_keys.length !== chunkCount
      : receipt.idempotency_keys.length !== chunkCount || receipt.idempotency_keys.some((key, index) => key !== outbox.chunks[index].idempotency_key);
    if (receipt.event_id !== outbox.event_id || receipt.chat_id !== outbox.destination_chat_id || mismatchedIdempotency || receivedChunks > chunkCount) throw new Error("Feishu outbound receipt does not match its immutable outbox");
  }
  if (ledger.state === "posted" && (!receipt || receivedChunks !== chunkCount || ledger.next_chunk !== chunkCount)) throw new Error("posted Feishu outbound ledger has no complete durable receipt");
  if (ledger.next_chunk > receivedChunks) throw new Error("Feishu outbound ledger advances beyond its durable receipt");
  if (receivedChunks > ledger.next_chunk || (receivedChunks === chunkCount && ledger.state !== "posted")) {
    const { attempt_id: _attemptId, last_attempt_ms: _lastAttemptMs, ...rest } = ledger;
    const updated = {
      ...rest,
      state: receivedChunks === chunkCount ? "posted" : "pending",
      next_chunk: receivedChunks,
      retry_at_ms: 0,
      last_error: null,
      idempotency_started_ms: null,
      idempotency_expires_ms: null,
      posted_at: receivedChunks === chunkCount ? receipt.posted_at : null,
    };
    atomicJson(join(paths.outboundLedger, name), updated);
    return { ledger: updated, receipt, repaired: repaired + 1 };
  }
  return { ledger, receipt, repaired };
}

function assertProcessedOutboundEvidence(name, ledger, receipt) {
  validateOutboundLedger(ledger);
  validateOutboundReceipt(receipt);
  requireString(ledger.text_hash, "processed outbound ledger text hash", RECORD_HASH);
  if (name !== `${sha(ledger.event_id)}.json` || ledger.state !== "posted" || receipt.event_id !== ledger.event_id || receipt.message_ids.length !== ledger.next_chunk || receipt.idempotency_keys.length !== ledger.next_chunk || receipt.idempotency_keys.some((key, index) => key !== stableId("fm", `${ledger.event_id}\0${index}`, 44))) {
    throw new Error("processed Feishu outbound ledger lacks complete authoritative receipt evidence");
  }
}

function repairOutboundStateLocked(paths, binding) {
  finishOutboundCleanupLocked(paths);
  assertConfigurationIdentity(paths, undefined, binding);
  let repaired = 0;
  const outboxNames = safeJsonNames(paths.outbox);
  const outboxSet = new Set(outboxNames);
  const ledgerNames = safeJsonNames(paths.outboundLedger);
  const ledgerSet = new Set(ledgerNames);
  for (const name of safeJsonNames(paths.outboundReceipts)) {
    if (!ledgerSet.has(name)) validateCompletedReceipt(readJson(join(paths.outboundReceipts, name)));
  }
  for (const name of ledgerNames) {
    if (outboxSet.has(name)) continue;
    const ledger = readJson(join(paths.outboundLedger, name));
    const receipt = readJson(join(paths.outboundReceipts, name), { optional: true });
    if (!receipt) throw new Error("orphan Feishu outbound ledger");
    assertProcessedOutboundEvidence(name, ledger, receipt);
    if (removeOutboundPendingIndex(paths, name)) repaired += 1;
  }
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
    if (["pending", "retryable", "sending"].includes(ledger.state) && isLocalRoutineAssistantText(outbox.text)) {
      ledger = supersedeRoutineOutboundLedger(ledger);
      atomicJson(ledgerPath, ledger);
      repaired += 1;
    }
    if (["pending", "retryable", "sending"].includes(ledger.state)) writeOutboundPendingIndex(paths, name, outbox);
    else if (removeOutboundPendingIndex(paths, name)) repaired += 1;
  }
  const outboxPendingSet = new Set(outboxNames);
  for (const name of safeJsonNames(paths.outboundPending)) {
    if (outboxPendingSet.has(name)) continue;
    removeOutboundPendingIndex(paths, name);
    repaired += 1;
  }
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
  const assistantEntryId = requireString(input.assistantEntryId, "outbound intent Assistant entry", SESSION_ENTRY_ID);
  const sessionOrder = requireSafeInteger(input.sessionOrder, "outbound intent session order");
  const sessionEntryTimestamp = requireIso(input.sessionEntryTimestamp, "outbound intent Assistant entry time");
  const text = typeof input.text === "string" ? input.text : "";
  if (text.trim().length === 0) return { status: "skipped", reason: "empty" };
  if (isLocalRoutineAssistantText(text)) return { status: "skipped", reason: "routine" };
  return withLock(paths, "outbound-state", () => {
    finishOutboundCleanupLocked(paths);
    const pairingRaw = readJson(paths.pairing, { optional: true });
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    if (!pairingIsActive(pairing) || !binding || binding.status !== "active" || binding.session_id !== input.sessionId || binding.generation !== input.bindingGeneration) throw new Error("outbound registration intent does not match the active binding");
    const eventId = outboundEventId(pairing.home_id, { bindingGeneration: binding.generation, sessionId: input.sessionId, assistantEntryId });
    const intentId = stableId("reg_", `${binding.binding_id}\0${eventId}`, 40);
    const existingOutbox = readJson(join(paths.outbox, `${sha(eventId)}.json`), { optional: true });
    if (existingOutbox) {
      validateAnyOutbound(existingOutbox);
      if (existingOutbox.assistant_entry_id !== assistantEntryId || existingOutbox.session_order !== sessionOrder || existingOutbox.session_entry_timestamp !== sessionEntryTimestamp || existingOutbox.text_hash !== `sha256:${sha(text)}`) throw new Error("persisted Assistant entry conflicts with its existing Feishu outbound record");
      return { status: "duplicate", eventId };
    }
    const completedReceipt = readJson(join(paths.outboundReceipts, `${sha(eventId)}.json`), { optional: true });
    if (completedReceipt?.text_hash) {
      validateCompletedReceipt(completedReceipt);
      if (completedReceipt.text_hash !== `sha256:${sha(text)}`) throw new Error("persisted Assistant entry conflicts with its processed Feishu outbound identity");
      return { status: "duplicate", eventId };
    }
    const existingLedger = readJson(join(paths.outboundLedger, `${sha(eventId)}.json`), { optional: true });
    if (existingLedger) {
      const receipt = readJson(join(paths.outboundReceipts, `${sha(eventId)}.json`), { optional: true });
      if (!receipt) throw new Error("processed Feishu outbound identity lacks its durable receipt");
      assertProcessedOutboundEvidence(`${sha(eventId)}.json`, existingLedger, receipt);
      if (existingLedger.text_hash !== `sha256:${sha(text)}`) throw new Error("persisted Assistant entry conflicts with its processed Feishu outbound identity");
      return { status: "duplicate", eventId };
    }
    const secretPattern = assistantSecretPattern(text);
    if (secretPattern) {
      quarantine(paths, "outbound-secret-refused", intentId, { intent_id: intentId, pattern: secretPattern, text_hash: `sha256:${sha(text)}`, bytes: utf8Bytes(text) });
      const alert = createLocalAlert(paths, "outbound-secret-refused", intentId, "A finalized Assistant response matched a fixed credential pattern. The entire response stayed local; inspect it in the TUI before deciding what to send.");
      return { status: "secret-refused", pattern: secretPattern, alert };
    }
    const record = {
      schema: OUTBOUND_INTENT_SCHEMA,
      intent_id: intentId,
      event_id: eventId,
      source: "pi-assistant",
      assistant_entry_id: assistantEntryId,
      session_order: sessionOrder,
      session_entry_timestamp: sessionEntryTimestamp,
      session_id: input.sessionId,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      text,
      text_hash: `sha256:${sha(text)}`,
      created_at: nowIso(),
    };
    validateOutboundIntent(record);
    const path = join(paths.outboundRegistrationIntents, `${sha(intentId)}.json`);
    const prior = readJson(path, { optional: true });
    if (prior) {
      if (prior.event_id === undefined) {
        const { event_id: _eventId, ...legacyRecord } = record;
        if (JSON.stringify({ ...prior, created_at: record.created_at }) !== JSON.stringify(legacyRecord)) throw new Error("conflicting Feishu outbound registration intent");
        const upgraded = { ...prior, event_id: record.event_id };
        atomicJson(path, upgraded);
        return upgraded;
      }
      if (JSON.stringify({ ...prior, created_at: record.created_at }) !== JSON.stringify(record)) throw new Error("conflicting Feishu outbound registration intent");
      return prior;
    }
    const free = statfsSync(paths.stateRoot);
    const freeBytes = Number(free.bavail) * Number(free.bsize);
    const maxBytes = positiveInteger(input.maxOutboundBytes ?? process.env.FM_FEISHU_MAX_OUTBOUND_BYTES, DEFAULT_MAX_OUTBOUND_BYTES);
    const minFreeBytes = positiveInteger(process.env.FM_FEISHU_MIN_FREE_BYTES, DEFAULT_MIN_FREE_BYTES);
    if (utf8Bytes(text) > maxBytes || !Number.isFinite(freeBytes) || freeBytes < minFreeBytes) {
      const alert = createLocalAlert(paths, "outbound-resource-refused", intentId, "A finalized Assistant response exceeded the local outbound resource policy or free-space floor. The entire response stayed local.");
      return { status: "resource-refused", reason: "resource-limit", alert };
    }
    if (outboundLogicalQueueCount(paths, pairing) >= maxPendingOutbound(input)) {
      const alert = createLocalAlert(paths, "outbound-queue-refused", intentId, "A finalized Assistant response reached the bounded Feishu outbound queue. The entire response stayed local until capacity is reconciled.");
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
  records.sort((a, b) => a.record.session_order - b.record.session_order || a.record.assistant_entry_id.localeCompare(b.record.assistant_entry_id));
  return records;
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
  const assistantEntryId = requireString(input.assistantEntryId, "outbound Assistant entry", SESSION_ENTRY_ID);
  const sessionOrder = requireSafeInteger(input.sessionOrder, "outbound session order");
  const sessionEntryTimestamp = requireIso(input.sessionEntryTimestamp, "outbound Assistant entry time");
  const text = typeof input.text === "string" ? input.text : "";
  if (text.trim().length === 0) return { status: "skipped", reason: "empty" };
  if (isLocalRoutineAssistantText(text)) return { status: "skipped", reason: "routine" };
  let registrationIntent;
  if (input.registrationIntentId) {
    const intent = readJson(join(paths.outboundRegistrationIntents, `${sha(input.registrationIntentId)}.json`), { optional: true });
    registrationIntent = intent ? validateOutboundIntent(intent) : undefined;
    const matches = registrationIntent && registrationIntent.intent_id === input.registrationIntentId && registrationIntent.source === "pi-assistant" && registrationIntent.assistant_entry_id === assistantEntryId && registrationIntent.session_order === sessionOrder && registrationIntent.session_entry_timestamp === sessionEntryTimestamp && registrationIntent.session_id === input.sessionId && registrationIntent.binding_generation === input.bindingGeneration && registrationIntent.text_hash === `sha256:${sha(text)}`;
    if (!matches) throw new Error("outbound registration does not match its durable intent");
  }
  const eventId = registrationIntent
    ? outboundEventIdForIntent(pairing.home_id, registrationIntent)
    : outboundEventId(pairing.home_id, { bindingGeneration: binding.generation, sessionId: input.sessionId, assistantEntryId });
  const maxOutboundBytes = positiveInteger(input.maxOutboundBytes ?? process.env.FM_FEISHU_MAX_OUTBOUND_BYTES, DEFAULT_MAX_OUTBOUND_BYTES);
  const minFreeBytes = positiveInteger(process.env.FM_FEISHU_MIN_FREE_BYTES, DEFAULT_MIN_FREE_BYTES);
  const free = statfsSync(paths.stateRoot);
  const freeBytes = Number(free.bavail) * Number(free.bsize);
  if (utf8Bytes(text) > maxOutboundBytes || !Number.isFinite(freeBytes) || freeBytes < minFreeBytes) {
    const alert = createLocalAlert(paths, "outbound-resource-refused", eventId, "A finalized Assistant response exceeded the local outbound resource policy or free-space floor. The entire response stayed local.");
    return { status: "resource-refused", alert };
  }
  const pattern = assistantSecretPattern(text);
  if (pattern) {
    quarantine(paths, "outbound-secret-refused", eventId, { event_id: eventId, pattern, text_hash: `sha256:${sha(text)}`, bytes: utf8Bytes(text) });
    const alert = createLocalAlert(paths, "outbound-secret-refused", eventId, "A finalized Assistant response matched a fixed credential pattern. The entire response stayed local; inspect it in the TUI before deciding what to send.");
    return { status: "secret-refused", pattern, alert };
  }
  let renderedText;
  try {
    renderedText = renderFeishuPostMarkdown(text);
  } catch (error) {
    const alert = createLocalAlert(paths, "outbound-chunk-refused", eventId, "A finalized Assistant response could not be rendered within the fixed Feishu Markdown boundary. It stayed local.");
    return { status: "chunk-refused", error: String(error), alert };
  }
  if (utf8Bytes(renderedText) > maxOutboundBytes) {
    const alert = createLocalAlert(paths, "outbound-resource-refused", eventId, "A finalized Assistant response exceeded the local outbound resource policy after deterministic Markdown rendering. The entire response stayed local.");
    return { status: "resource-refused", reason: "resource-limit", alert };
  }
  let chunks;
  try {
    chunks = deterministicChunks(renderedText, input.maxChunkBytes ?? process.env.FM_FEISHU_MAX_OUTBOUND_CHUNK_BYTES);
  } catch (error) {
    const alert = createLocalAlert(paths, "outbound-chunk-refused", eventId, "A finalized Assistant response could not be split without breaking a complete URL or Markdown construct. It stayed local.");
    return { status: "chunk-refused", error: String(error), alert };
  }
  const filename = `${sha(eventId)}.json`;
  return withLock(paths, "outbound-state", () => {
    finishOutboundCleanupLocked(paths);
    const currentBindingRaw = readJson(paths.activeBinding, { optional: true });
    const currentBinding = currentBindingRaw ? validateBindingRecord(currentBindingRaw) : undefined;
    if (!currentBinding || currentBinding.status !== "active" || currentBinding.binding_id !== binding.binding_id || currentBinding.generation !== binding.generation) {
      return { status: "stale-binding" };
    }
    if (existsSync(join(paths.outbox, filename))) {
      const outbox = readJson(join(paths.outbox, filename));
      if (outbox.assistant_entry_id !== assistantEntryId || outbox.session_order !== sessionOrder || outbox.session_entry_timestamp !== sessionEntryTimestamp || outbox.text_hash !== `sha256:${sha(text)}`) throw new Error("persisted Assistant entry conflicts with its existing Feishu outbound record");
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
    const completedReceipt = readJson(join(paths.outboundReceipts, filename), { optional: true });
    if (completedReceipt?.text_hash) {
      validateCompletedReceipt(completedReceipt);
      if (completedReceipt.text_hash !== `sha256:${sha(text)}`) throw new Error("persisted Assistant entry conflicts with its processed Feishu outbound identity");
      return { status: "duplicate", eventId };
    }
    const processedLedger = readJson(join(paths.outboundLedger, filename), { optional: true });
    if (processedLedger) {
      const receipt = readJson(join(paths.outboundReceipts, filename), { optional: true });
      if (!receipt) throw new Error("processed Feishu outbound identity lacks its durable receipt");
      assertProcessedOutboundEvidence(filename, processedLedger, receipt);
      if (processedLedger.text_hash !== `sha256:${sha(text)}`) throw new Error("persisted Assistant entry conflicts with its processed Feishu outbound identity");
      return { status: "duplicate", eventId };
    }
    let transferringIntent = false;
    if (input.registrationIntentId) {
      const intent = readJson(join(paths.outboundRegistrationIntents, `${sha(input.registrationIntentId)}.json`), { optional: true });
      transferringIntent = Boolean(intent && intent.intent_id === registrationIntent.intent_id && intent.event_id === registrationIntent.event_id && intent.session_id === input.sessionId && intent.binding_generation === input.bindingGeneration && intent.text_hash === `sha256:${sha(text)}`);
      if (!transferringIntent) throw new Error("outbound registration does not match its durable intent");
    }
    if (!transferringIntent && outboundLogicalQueueCount(paths, pairing) >= maxPendingOutbound(input)) {
      const alert = createLocalAlert(paths, "outbound-queue-refused", eventId, "A finalized Assistant response reached the bounded Feishu outbound queue. The entire response stayed local until capacity is reconciled.");
      return { status: "resource-refused", reason: "queue-limit", alert };
    }
    const outbox = {
      schema: OUTBOUND_SCHEMA,
      event_id: eventId,
      source: "pi-assistant",
      assistant_entry_id: assistantEntryId,
      session_order: sessionOrder,
      session_entry_timestamp: sessionEntryTimestamp,
      session_id: input.sessionId,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      destination_chat_id: binding.chat_id,
      text,
      text_hash: `sha256:${sha(text)}`,
      rendered_text_hash: `sha256:${sha(renderedText)}`,
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
    finishOutboundCleanupLocked(paths);
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
      if (isLocalRoutineAssistantText(outbox.text)) {
        atomicJson(path, supersedeRoutineOutboundLedger(ledger));
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
    candidates.sort((a, b) => a.outbox.created_at.localeCompare(b.outbox.created_at) || a.outbox.session_order - b.outbox.session_order || a.outbox.assistant_entry_id.localeCompare(b.outbox.assistant_entry_id));
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
    finishOutboundCleanupLocked(paths);
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    const path = join(paths.outboundLedger, claim.filename);
    const ledger = readJson(path, { optional: true });
    if (!ledger) {
      validateCompletedReceipt(readJson(join(paths.outboundReceipts, claim.filename)));
      return false;
    }
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
    finishOutboundCleanupLocked(paths);
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    const ledgerPath = join(paths.outboundLedger, claim.filename);
    const ledger = readJson(ledgerPath, { optional: true });
    if (!ledger) {
      validateCompletedReceipt(readJson(join(paths.outboundReceipts, claim.filename)));
      return false;
    }
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
      config_file_identity: owner.configFileIdentity === undefined
        ? null
        : requireString(owner.configFileIdentity, "transport config file identity", /^[0-9]+:[0-9]+:[0-9.]+:[0-9]+$/, 256),
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
    recovery_class: patch.recoveryClass ?? null,
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

export function transportOwnerIncarnationIsLive(owner) {
  if (!owner || !pidAlive(owner.pid)) return false;
  let stat;
  try { stat = readFileSync(`/proc/${owner.pid}/stat`, "utf8"); }
  catch { return false; }
  const suffix = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
  return suffix[0] !== "Z" && /^[0-9]+$/.test(suffix[19] ?? "") && suffix[19] === owner.process_start_token;
}

export function transportHealthAllowsDispatch(home, binding) {
  const paths = pathsForHome(home);
  const health = readJson(paths.health, { optional: true });
  const owner = readJson(paths.owner, { optional: true });
  if (!health || !owner || health.phase !== "healthy" || health.healthy !== true) return false;
  if (health.binding_id !== binding.binding_id || health.binding_generation !== binding.generation) return false;
  if (owner.home_realpath !== paths.home || owner.pid !== health.owner_pid || owner.nonce !== health.owner_nonce || owner.process_start_token !== health.owner_process_start_token) return false;
  return transportOwnerIncarnationIsLive(owner);
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
    live_session_owned: binding ? liveSessionOwnsBinding(home, binding) : false,
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
    live_session_owned: status.live_session_owned,
    inbound_pending: status.inbound.pending,
    inbound_queued: status.inbound.queued,
    outbound_pending: status.outbound_pending,
    outbound_uncertain: status.outbound_uncertain,
  };
}

function cliUsage() {
  return "usage: fm-feishu-state.mjs status [--public] [--home <path>]";
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
        ` session_owned=${value.live_session_owned === true ? "yes" : "no"}` +
        ` inbox_pending=${value.inbound_pending ?? value.inbound?.pending ?? 0}` +
        ` outbox_pending=${value.outbound_pending ?? 0} uncertain=${value.outbound_uncertain ?? 0}\n`,
      );
    } else {
      process.stdout.write(`${JSON.stringify(value)}\n`);
    }
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
