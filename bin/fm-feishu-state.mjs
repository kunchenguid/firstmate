#!/usr/bin/env node
// Private durable state owner for the Firstmate Feishu channel.
//
// This module contains no network or Agent code.  It owns the pairing and
// binding schemas, private artifact publication, ingress ordering and ACKs,
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

export const PAIRING_SCHEMA = "fm-feishu-pairing.v1";
export const BINDING_SCHEMA = "fm-feishu-binding.v1";
export const INBOUND_SCHEMA = "fm-feishu-inbound.v1";
export const INBOUND_LEDGER_SCHEMA = "fm-feishu-inbound-ledger.v1";
export const INBOUND_ACK_SCHEMA = "fm-feishu-pi-ack.v1";
export const OUTBOUND_SCHEMA = "fm-feishu-assistant-outbound.v1";
export const OUTBOUND_LEDGER_SCHEMA = "fm-feishu-outbound-ledger.v1";
export const OUTBOUND_RECEIPT_SCHEMA = "fm-feishu-outbound-receipt.v1";
export const TRANSPORT_HEALTH_SCHEMA = "fm-feishu-transport-health.v1";
export const DECISION_SCHEMA = "fm-feishu-pending-decision.v1";
export const DEFAULT_MAX_INBOUND_BYTES = 64 * 1024;
export const DEFAULT_MAX_OUTBOUND_CHUNK_BYTES = 20 * 1024;
export const DEFAULT_MAX_OUTBOUND_BYTES = 1024 * 1024;
export const DEFAULT_MAX_PENDING_INBOUND = 10000;
export const DEFAULT_MIN_FREE_BYTES = 64 * 1024 * 1024;
export const DEFAULT_MAX_LOCAL_IMAGE_BYTES = 20 * 1024 * 1024;
export const IDEMPOTENCY_WINDOW_MS = 60 * 60 * 1000;
const LOCK_WAIT_MS = 3000;
const LOCK_STALE_MS = 30000;
const RETRY_BASE_MS = 1000;
const RETRY_MAX_MS = 60000;
const MODULE_FILE = fileURLToPath(import.meta.url);

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
  const temp = join(dirname(path), `.${sha(path).slice(0, 10)}.${process.pid}.${randomBytes(5).toString("hex")}.tmp`);
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
    inboundAcks: join(stateRoot, "inbound-acks"),
    inboundPendingCount: join(stateRoot, "inbound-pending-count"),
    outbox: join(stateRoot, "outbox"),
    outboundLedger: join(stateRoot, "outbound-ledger"),
    outboundReceipts: join(stateRoot, "outbound-receipts"),
    outboundMessageMap: join(stateRoot, "outbound-message-map"),
    pendingDecisions: join(stateRoot, "pending-decisions"),
    attemptsIn: join(stateRoot, "attempts", "in"),
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
    paths.inboundAcks,
    paths.outbox,
    paths.outboundLedger,
    paths.outboundReceipts,
    paths.outboundMessageMap,
    paths.pendingDecisions,
    join(paths.stateRoot, "attempts"),
    paths.attemptsIn,
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
      if (ledger.state === "pending" || ledger.state === "dispatching") pending += 1;
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
  requireString(pairing.app_profile, "pairing app profile", /^[A-Za-z0-9._-]+$/, 80);
  if (pairing.app_id_fingerprint !== null) requireString(pairing.app_id_fingerprint, "pairing app fingerprint", /^sha256:[a-f0-9]{64}$/);
  requireString(pairing.bot_open_id, "pairing bot open_id", /^ou_[A-Za-z0-9_-]{4,128}$/);
  if (!Array.isArray(pairing.allowed_users) || pairing.allowed_users.length !== 1) throw new Error("invalid Feishu pairing user allowlist");
  if (!Array.isArray(pairing.allowed_chats) || pairing.allowed_chats.length !== 1) throw new Error("invalid Feishu pairing chat allowlist");
  requireString(pairing.allowed_users[0], "pairing allowed user", /^ou_[A-Za-z0-9_-]{4,128}$/);
  requireString(pairing.allowed_chats[0], "pairing allowed chat", /^oc_[A-Za-z0-9_-]{4,128}$/);
  if (pairing.chat_policy !== "p2p-only" || JSON.stringify(pairing.inbound_types) !== JSON.stringify(["text", "post"])) {
    throw new Error("invalid Feishu pairing policy");
  }
  if (pairing.disabled_at !== null && typeof pairing.disabled_at !== "string") throw new Error("invalid Feishu pairing status");
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
  return binding;
}

export function readPairing(home) {
  const paths = pathsForHome(home);
  const pairing = readJson(paths.pairing, { optional: true });
  return pairing ? validatePairingRecord(pairing) : undefined;
}

export function readActiveBinding(home) {
  const paths = pathsForHome(home);
  const binding = readJson(paths.activeBinding, { optional: true });
  return binding ? validateBindingRecord(binding) : undefined;
}

export function createPairing(home, input) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "pairing", () => {
    const priorRaw = readJson(paths.pairing, { optional: true });
    const prior = priorRaw ? validatePairingRecord(priorRaw) : undefined;
    const homeId = prior?.home_id ?? `home_${randomBytes(16).toString("hex")}`;
    const pairing = {
      schema: PAIRING_SCHEMA,
      home_id: homeId,
      fm_home_realpath: paths.home,
      app_profile: requireString(input.appProfile ?? "default", "app profile", /^[A-Za-z0-9._-]+$/, 80),
      app_id_fingerprint: input.appIdFingerprint
        ? requireString(input.appIdFingerprint, "app id fingerprint", /^sha256:[a-f0-9]{64}$/)
        : null,
      bot_open_id: requireString(input.botOpenId, "bot open_id", /^ou_[A-Za-z0-9_-]{4,128}$/),
      allowed_users: [requireString(input.allowedUser, "allowed user open_id", /^ou_[A-Za-z0-9_-]{4,128}$/)],
      allowed_chats: [requireString(input.allowedChat, "allowed P2P chat_id", /^oc_[A-Za-z0-9_-]{4,128}$/)],
      chat_policy: "p2p-only",
      inbound_types: ["text", "post"],
      created_at: prior?.created_at ?? nowIso(),
      updated_at: nowIso(),
      disabled_at: null,
    };
    const bindingRaw = readJson(paths.activeBinding, { optional: true });
    const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
    if (binding?.status === "active" && prior?.disabled_at === null) {
      const unchanged = prior.app_profile === pairing.app_profile &&
        prior.app_id_fingerprint === pairing.app_id_fingerprint &&
        prior.bot_open_id === pairing.bot_open_id &&
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
  return withLock(paths, "pairing", () => {
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
  return withLock(paths, "binding", () => {
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
  const names = safeJsonNames(paths.inboundLedger);
  for (const name of names) {
    const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (ledger.state === "dispatching") throw new Error("cannot rebind while a Pi ingress is still being accepted");
  }
  for (const name of names) {
    const path = join(paths.inboundLedger, name);
    const ledger = requireSchema(readJson(path), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (ledger.state !== "pending") continue;
    const event = requireSchema(readJson(join(paths.inbox, name)), INBOUND_SCHEMA, "inbound event");
    if (event.source !== "feishu") {
      atomicJson(path, {
        ...ledger,
        state: "superseded",
        superseded_at: nowIso(),
        last_error: "local or internal input belongs to the previous Pi session",
      });
      adjustInboundPendingCount(paths, -1);
      continue;
    }
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
  return readdirSync(path).filter((name) => /^[a-f0-9]{64}\.json$/.test(name)).sort();
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
    safeFile(path);
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

function readInboundPendingCount(paths) {
  safeFile(paths.inboundPendingCount);
  const raw = readFileSync(paths.inboundPendingCount, "utf8");
  if (!/^(0|[1-9][0-9]*)\n$/.test(raw)) throw new Error("malformed Feishu pending-ingress count");
  const count = Number(raw.trim());
  if (!Number.isSafeInteger(count) || count < 0) throw new Error("invalid Feishu pending-ingress count");
  return count;
}

function adjustInboundPendingCount(paths, delta) {
  return withLock(paths, "inbound-count", () => {
    const current = readInboundPendingCount(paths);
    const next = current + delta;
    if (!Number.isSafeInteger(next) || next < 0) throw new Error("invalid Feishu pending-ingress count transition");
    atomicWrite(paths.inboundPendingCount, `${next}\n`);
    return next;
  });
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

function normalizeLocalImages(images) {
  if (images === undefined) return [];
  if (!Array.isArray(images)) throw new Error("local Pi images are malformed");
  const normalized = images.map((image) => {
    if (!image || image.type !== "image" || typeof image.data !== "string" || typeof image.mimeType !== "string") {
      throw new Error("local Pi image is malformed");
    }
    return { type: "image", data: image.data, mimeType: image.mimeType };
  });
  const bytes = normalized.reduce((total, image) => total + Buffer.byteLength(image.data, "utf8"), 0);
  const maxBytes = positiveInteger(process.env.FM_FEISHU_MAX_LOCAL_IMAGE_BYTES, DEFAULT_MAX_LOCAL_IMAGE_BYTES);
  if (bytes > maxBytes) throw new Error("local Pi images exceed the durable channel limit");
  return normalized;
}

function decisionForReply(paths, replyTo) {
  if (!replyTo) return null;
  const map = readJson(join(paths.outboundMessageMap, `${sha(replyTo)}.json`), { optional: true });
  if (!map || map.message_id !== replyTo || !map.decision_ref || !map.decision_key) return null;
  return { decision_ref: map.decision_ref, decision_key: map.decision_key };
}

function hasPendingDecisionReply(paths, binding) {
  for (const name of safeJsonNames(paths.pendingDecisions)) {
    const record = readJson(join(paths.pendingDecisions, name));
    if (record.schema === DECISION_SCHEMA && record.state === "sent-to-outbox" && record.binding_generation === binding.generation) return true;
  }
  return false;
}

export function publishFeishuInbound(home, raw, options = {}) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
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
    return { status: "duplicate", messageIdHash: sha(messageId) };
  }
  const senderId = raw.sender_id;
  const chatId = raw.chat_id;
  const senderType = raw.sender_type;
  const chatType = raw.chat_type;
  const messageType = raw.message_type ?? raw.msg_type;
  let reject;
  if (senderType !== "user" || senderId === pairing.bot_open_id) reject = "bot-or-self";
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
  return withLock(paths, "inbound-state", () => {
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
    const deliveryRef = stableId("in_", `${pairing.home_id}\0${messageId}`, 24);
    const replyTo = typeof raw.reply_to === "string" && /^om_[A-Za-z0-9_-]{4,128}$/.test(raw.reply_to) ? raw.reply_to : null;
    const decision = decisionForReply(paths, replyTo);
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
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      authorization_snapshot: `sha256:${sha(JSON.stringify({
        user: pairing.allowed_users,
        chat: pairing.allowed_chats,
        type: pairing.inbound_types,
        disabled_at: pairing.disabled_at,
      }))}`,
      ingress_seq: ingressSeq,
      delivery_ref: deliveryRef,
      decision_ref: decision?.decision_ref ?? null,
      decision_key: decision?.decision_key ?? null,
      decision_reply: decision ? "exact" : hasPendingDecisionReply(paths, binding) ? "unrelated" : "none",
    };
    const ledger = {
      schema: INBOUND_LEDGER_SCHEMA,
      source: "feishu",
      message_id: messageId,
      ingress_seq: ingressSeq,
      state: "pending",
      attempt: 0,
      claim_generation: null,
      lease_until_ms: null,
      target_session_id: binding.session_id,
      binding_id: binding.binding_id,
      binding_generation: binding.generation,
      delivery_ref: deliveryRef,
      last_error: null,
      created_at: nowIso(),
    };
    atomicJson(join(paths.inbox, filename), event);
    atomicJson(join(paths.inboundLedger, filename), ledger);
    adjustInboundPendingCount(paths, 1);
    recordInboundEventId(paths, raw.event_id, messageId, deliveryRef);
    if (decision) {
      const decisionPath = join(paths.pendingDecisions, `${sha(decision.decision_ref)}.json`);
      const pending = readJson(decisionPath, { optional: true });
      if (pending?.schema === DECISION_SCHEMA && pending.decision_key === decision.decision_key) {
        atomicJson(decisionPath, {
          ...pending,
          state: "reply-received",
          inbound_delivery_ref: deliveryRef,
          reply_message_id_hash: `sha256:${sha(messageId)}`,
          replied_at: nowIso(),
        });
      }
    }
    return { status: "published", ingressSeq, deliveryRef, messageIdHash: sha(messageId) };
  });
}

export function enqueueLocalIngress(home, input) {
  const paths = ensurePrivateLayout(home);
  const messageId = `${input.source === "internal" ? "internal" : "local"}_${randomUUID()}`;
  const filename = inboundFilename(messageId);
  const ingressSeq = nextSequence(paths);
  const deliveryRef = stableId("in_", `${messageId}\0${ingressSeq}`, 24);
  const source = input.source === "internal" ? "internal" : "tui";
  const images = source === "tui" ? normalizeLocalImages(input.images) : [];
  const event = {
    schema: INBOUND_SCHEMA,
    source,
    message_id: messageId,
    event_ids: [],
    transport: "current-pi",
    sender_id: null,
    sender_type: "local",
    chat_id: null,
    chat_type: "local",
    reply_to: null,
    root_id: null,
    thread_id: null,
    message_type: "text",
    text: normalizeContent(input.text),
    images,
    create_time_ms: Date.now(),
    received_at: nowIso(),
    payload_hash: `sha256:${sha(`${input.text}\0${JSON.stringify(images.map((image) => ({ mimeType: image.mimeType, dataHash: sha(image.data) })))}`)}`,
    binding_id: input.bindingId,
    binding_generation: input.bindingGeneration,
    authorization_snapshot: null,
    ingress_seq: ingressSeq,
    delivery_ref: deliveryRef,
    decision_ref: null,
    decision_key: null,
    desired_delivery: input.desiredDelivery ?? "followUp",
  };
  const ledger = {
    schema: INBOUND_LEDGER_SCHEMA,
    source,
    message_id: messageId,
    ingress_seq: ingressSeq,
    state: "pending",
    attempt: 0,
    claim_generation: null,
    lease_until_ms: null,
    target_session_id: input.sessionId,
    binding_id: input.bindingId,
    binding_generation: input.bindingGeneration,
    delivery_ref: deliveryRef,
    last_error: null,
    created_at: nowIso(),
  };
  return withLock(paths, "inbound-state", () => {
    atomicJson(join(paths.inbox, filename), event);
    atomicJson(join(paths.inboundLedger, filename), ledger);
    adjustInboundPendingCount(paths, 1);
    return { event, ledger };
  });
}

export function repairInboundLedgers(home) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    let repaired = 0;
    for (const name of safeJsonNames(paths.inbox)) {
      const ledgerPath = join(paths.inboundLedger, name);
      const event = requireSchema(readJson(join(paths.inbox, name)), INBOUND_SCHEMA, "inbound event");
      for (const eventId of Array.isArray(event.event_ids) ? event.event_ids : []) {
        recordInboundEventId(paths, eventId, event.message_id, event.delivery_ref);
      }
      if (existsSync(ledgerPath)) continue;
      atomicJson(ledgerPath, {
        schema: INBOUND_LEDGER_SCHEMA,
        source: event.source,
        message_id: event.message_id,
        ingress_seq: event.ingress_seq,
        state: "pending",
        attempt: 0,
        claim_generation: null,
        lease_until_ms: null,
        target_session_id: event.target_session_id ?? null,
        binding_id: event.binding_id,
        binding_generation: event.binding_generation,
        delivery_ref: event.delivery_ref,
        last_error: "ledger repaired after interrupted publish",
        created_at: nowIso(),
      });
      repaired += 1;
    }
    let pending = 0;
    for (const name of safeJsonNames(paths.inboundLedger)) {
      const ledgerPath = join(paths.inboundLedger, name);
      let ledger = requireSchema(readJson(ledgerPath), INBOUND_LEDGER_SCHEMA, "inbound ledger");
      const ackRaw = readJson(join(paths.inboundAcks, name), { optional: true });
      const ack = ackRaw ? requireSchema(ackRaw, INBOUND_ACK_SCHEMA, "inbound ACK") : undefined;
      if (ack && ledger.state !== "delivered") {
        ledger = { ...ledger, state: "delivered", lease_until_ms: null, delivered_at: ack.persisted_at };
        atomicJson(ledgerPath, ledger);
        repaired += 1;
      }
      if (ledger.state === "pending" || ledger.state === "dispatching") pending += 1;
    }
    atomicWrite(paths.inboundPendingCount, `${pending}\n`);
    return repaired;
  });
}

export function claimNextIngress(home, fence, options = {}) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    const now = Date.now();
    const candidates = [];
    for (const name of safeJsonNames(paths.inboundLedger)) {
      const path = join(paths.inboundLedger, name);
      let ledger = requireSchema(readJson(path), INBOUND_LEDGER_SCHEMA, "inbound ledger");
      const ackRaw = readJson(join(paths.inboundAcks, name), { optional: true });
      const ack = ackRaw ? requireSchema(ackRaw, INBOUND_ACK_SCHEMA, "inbound ACK") : undefined;
      if (ack) {
        if (ledger.state !== "delivered") atomicJson(path, { ...ledger, state: "delivered", delivered_at: ack.persisted_at });
        continue;
      }
      if (ledger.state === "dispatching" && Number(ledger.lease_until_ms ?? 0) <= now) {
        ledger = { ...ledger, state: "pending", claim_generation: null, lease_until_ms: null, last_error: "expired dispatch lease recovered" };
        atomicJson(path, ledger);
      }
      if (ledger.state !== "pending") continue;
      if (ledger.target_session_id && ledger.target_session_id !== fence.sessionId) continue;
      if (ledger.binding_generation !== fence.bindingGeneration || ledger.binding_id !== fence.bindingId) continue;
      candidates.push({ name, path, ledger });
    }
    candidates.sort((a, b) => Number(a.ledger.ingress_seq) - Number(b.ledger.ingress_seq) || a.name.localeCompare(b.name));
    const candidate = candidates[0];
    if (!candidate) return undefined;
    const event = requireSchema(readJson(join(paths.inbox, candidate.name)), INBOUND_SCHEMA, "inbound event");
    const retargeted = event.source === "feishu" && candidate.ledger.retargeted_at &&
      candidate.ledger.original_binding_id === event.binding_id &&
      candidate.ledger.original_binding_generation === event.binding_generation;
    if (event.delivery_ref !== candidate.ledger.delivery_ref || (!retargeted && (
      event.binding_id !== candidate.ledger.binding_id || event.binding_generation !== candidate.ledger.binding_generation
    ))) {
      throw new Error("Feishu inbound event and ledger identity do not match");
    }
    const deliveryEvent = retargeted ? {
      ...event,
      binding_id: candidate.ledger.binding_id,
      binding_generation: candidate.ledger.binding_generation,
    } : event;
    const attempt = Number(candidate.ledger.attempt ?? 0) + 1;
    const claimGeneration = `claim_${randomBytes(12).toString("hex")}`;
    const leaseMs = positiveInteger(options.leaseMs ?? process.env.FM_FEISHU_INGRESS_LEASE_MS, 60000);
    const ledger = {
      ...candidate.ledger,
      state: "dispatching",
      attempt,
      claim_generation: claimGeneration,
      lease_until_ms: now + leaseMs,
      dispatching_at: nowIso(),
      target_session_id: fence.sessionId,
    };
    atomicJson(candidate.path, ledger);
    const attemptDir = join(paths.attemptsIn, candidate.name.replace(/\.json$/, ""));
    privateDir(attemptDir);
    atomicJson(join(attemptDir, `${String(attempt).padStart(8, "0")}.json`), {
      schema: "fm-feishu-inbound-attempt.v1",
      attempt,
      claim_generation: claimGeneration,
      session_id: fence.sessionId,
      binding_generation: fence.bindingGeneration,
      delivery_ref: ledger.delivery_ref,
      started_at: nowIso(),
    });
    return { event: deliveryEvent, ledger, filename: candidate.name };
  });
}

export function releaseIngressClaim(home, deliveryRef, error) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    for (const name of safeJsonNames(paths.inboundLedger)) {
      const path = join(paths.inboundLedger, name);
      const ledger = requireSchema(readJson(path), INBOUND_LEDGER_SCHEMA, "inbound ledger");
      if (ledger.delivery_ref !== deliveryRef || ledger.state !== "dispatching") continue;
      atomicJson(path, {
        ...ledger,
        state: "pending",
        claim_generation: null,
        lease_until_ms: null,
        last_error: String(error).slice(0, 500),
        released_at: nowIso(),
      });
      return true;
    }
    return false;
  });
}

export function ackIngress(home, deliveryRef, session) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "inbound-state", () => {
    for (const name of safeJsonNames(paths.inboundLedger)) {
      const ledgerPath = join(paths.inboundLedger, name);
      const ledger = requireSchema(readJson(ledgerPath), INBOUND_LEDGER_SCHEMA, "inbound ledger");
      if (ledger.delivery_ref !== deliveryRef) continue;
      const existing = readJson(join(paths.inboundAcks, name), { optional: true });
      if (existing?.schema === INBOUND_ACK_SCHEMA) return existing;
      const ack = {
        schema: INBOUND_ACK_SCHEMA,
        message_id: ledger.message_id,
        delivery_ref: deliveryRef,
        session_id: session.sessionId,
        session_entry_id: session.sessionEntryId,
        binding_generation: session.bindingGeneration,
        persisted_at: nowIso(),
      };
      atomicJson(join(paths.inboundAcks, name), ack);
      atomicJson(ledgerPath, { ...ledger, state: "delivered", lease_until_ms: null, delivered_at: ack.persisted_at });
      if (ledger.state !== "delivered") adjustInboundPendingCount(paths, -1);
      return ack;
    }
    return undefined;
  });
}

export function reconcileIngressFromSession(home, markers, fence) {
  let repaired = 0;
  for (const marker of markers) {
    if (marker.sessionId !== fence.sessionId || marker.bindingGeneration !== fence.bindingGeneration) continue;
    const ack = ackIngress(home, marker.deliveryRef, {
      sessionId: marker.sessionId,
      sessionEntryId: marker.sessionEntryId,
      bindingGeneration: marker.bindingGeneration,
    });
    if (ack) repaired += 1;
  }
  return repaired;
}

export function findInboundByDeliveryRef(home, deliveryRef) {
  const paths = ensurePrivateLayout(home);
  for (const name of safeJsonNames(paths.inbox)) {
    const event = readJson(join(paths.inbox, name));
    if (event.schema === INBOUND_SCHEMA && event.delivery_ref === deliveryRef) return event;
  }
  return undefined;
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
  const paths = ensurePrivateLayout(home);
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
  const counts = { pending: 0, dispatching: 0, delivered: 0, other: 0 };
  for (const name of safeJsonNames(paths.inboundLedger)) {
    const ledger = requireSchema(readJson(join(paths.inboundLedger, name)), INBOUND_LEDGER_SCHEMA, "inbound ledger");
    if (Object.hasOwn(counts, ledger.state)) counts[ledger.state] += 1;
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

export function registerAssistantOutbound(home, input) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  if (!pairingIsActive(pairing) || !binding || binding.status !== "active") return { status: "inactive" };
  if (binding.session_id !== input.sessionId || binding.generation !== input.bindingGeneration) return { status: "stale-binding" };
  const text = typeof input.text === "string" ? input.text : "";
  if (text.trim().length === 0) return { status: "skipped", reason: "empty" };
  if (text === "Captain, shipshape.") return { status: "skipped", reason: "routine" };
  if (input.source === "internal") return { status: "skipped", reason: "internal" };
  const eventId = stableId(
    "out_",
    `${pairing.home_id}\0${binding.generation}\0${input.sessionId}\0${input.sourceRef}\0${sha(text)}\0${input.replyTo ?? "chat"}`,
    40,
  );
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
    quarantine(paths, "outbound-secret-refused", eventId, {
      event_id: eventId,
      pattern,
      text_hash: `sha256:${sha(text)}`,
      bytes: utf8Bytes(text),
    });
    const alert = createLocalAlert(
      paths,
      "outbound-secret-refused",
      eventId,
      "A final Assistant response matched a fixed credential pattern. The entire response stayed local; inspect it in the TUI before deciding what to send.",
    );
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
  if (existsSync(join(paths.outbox, filename))) return { status: "duplicate", eventId };
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
    chunks: chunks.map((chunk, index) => ({
      index,
      count: chunks.length,
      chunk,
      chunk_hash: `sha256:${sha(chunk)}`,
      idempotency_key: stableId("fm", `${eventId}\0${index}`, 44),
    })),
    created_at: nowIso(),
  };
  const ledger = {
    schema: OUTBOUND_LEDGER_SCHEMA,
    event_id: eventId,
    state: "pending",
    next_chunk: 0,
    attempts: 0,
    retry_at_ms: 0,
    binding_generation: binding.generation,
    created_at: outbox.created_at,
    last_error: null,
  };
  atomicJson(join(paths.outbox, filename), outbox);
  atomicJson(join(paths.outboundLedger, filename), ledger);
  return { status: "registered", eventId, chunks: chunks.length };
}

export function claimNextOutbound(home) {
  const paths = ensurePrivateLayout(home);
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  const now = Date.now();
  return withLock(paths, "outbound-claim", () => {
    const candidates = [];
    for (const name of safeJsonNames(paths.outboundLedger)) {
      const path = join(paths.outboundLedger, name);
      const ledger = requireSchema(readJson(path), OUTBOUND_LEDGER_SCHEMA, "outbound ledger");
      if (!["pending", "retryable", "sending"].includes(ledger.state)) continue;
      const outboxRaw = readJson(join(paths.outbox, name), { optional: true });
      const outbox = outboxRaw ? requireSchema(outboxRaw, OUTBOUND_SCHEMA, "outbox") : undefined;
      if (!outbox || !Array.isArray(outbox.chunks)) throw new Error("missing or invalid Feishu outbox for pending ledger");
      if (!binding || binding.status !== "active" || outbox.binding_generation !== binding.generation || outbox.binding_id !== binding.binding_id) {
        atomicJson(path, { ...ledger, state: "superseded", superseded_at: nowIso(), last_error: "binding generation changed before send" });
        continue;
      }
      if (ledger.state === "sending") {
        const age = now - Number(ledger.last_attempt_ms ?? 0);
        if (age >= IDEMPOTENCY_WINDOW_MS) {
          atomicJson(path, { ...ledger, state: "delivery_uncertain", uncertain_at: nowIso(), last_error: "ambiguous send exceeded the idempotency window" });
          createLocalAlert(paths, "outbound-delivery-uncertain", outbox.event_id, "A Feishu send may have succeeded, but no receipt was recorded before the idempotency window ended. Automatic resend stopped.");
          continue;
        }
      }
      if (Number(ledger.retry_at_ms ?? 0) > now) continue;
      candidates.push({ name, path, ledger, outbox });
    }
    candidates.sort((a, b) => String(a.outbox.created_at).localeCompare(String(b.outbox.created_at)) || a.name.localeCompare(b.name));
    const candidate = candidates[0];
    if (!candidate) return undefined;
    const chunk = candidate.outbox.chunks[candidate.ledger.next_chunk];
    if (!chunk) {
      atomicJson(candidate.path, { ...candidate.ledger, state: "posted", posted_at: nowIso() });
      return undefined;
    }
    if (!Number.isSafeInteger(chunk.index) || typeof chunk.chunk !== "string" || typeof chunk.idempotency_key !== "string") {
      throw new Error("invalid Feishu outbound chunk");
    }
    const attempt = Number(candidate.ledger.attempts ?? 0) + 1;
    const attemptId = stableId("attempt_", `${candidate.outbox.event_id}\0${chunk.index}\0${attempt}`, 24);
    const ledger = {
      ...candidate.ledger,
      state: "sending",
      attempts: attempt,
      attempt_id: attemptId,
      last_attempt_ms: now,
      last_attempt_at: nowIso(),
      retry_at_ms: 0,
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

export function failOutboundAttempt(home, claim, error, { ambiguous = false, retryAfterMs } = {}) {
  const paths = ensurePrivateLayout(home);
  const path = join(paths.outboundLedger, claim.filename);
  const ledger = requireSchema(readJson(path), OUTBOUND_LEDGER_SCHEMA, "outbound ledger");
  if (ledger.attempt_id !== claim.ledger.attempt_id) return false;
  const age = Date.now() - Number(ledger.last_attempt_ms ?? Date.now());
  if (ambiguous && age >= IDEMPOTENCY_WINDOW_MS) {
    atomicJson(path, { ...ledger, state: "delivery_uncertain", uncertain_at: nowIso(), last_error: String(error).slice(0, 500) });
    createLocalAlert(paths, "outbound-delivery-uncertain", claim.outbox.event_id, "A Feishu send may have succeeded, but its result is uncertain. Automatic resend stopped.");
    return true;
  }
  const delay = retryAfterMs !== undefined
    ? Math.max(0, Math.min(RETRY_MAX_MS, Number(retryAfterMs)))
    : Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.min(10, Number(ledger.attempts ?? 1) - 1));
  atomicJson(path, {
    ...ledger,
    state: ambiguous ? "sending" : "retryable",
    retry_at_ms: Date.now() + delay,
    last_error: String(error).slice(0, 500),
  });
  return true;
}

export function receiptOutbound(home, claim, receipt) {
  const paths = ensurePrivateLayout(home);
  const messageId = requireString(receipt.messageId, "outbound message_id", /^om_[A-Za-z0-9_-]{4,128}$/);
  const chatId = requireString(receipt.chatId, "outbound chat_id", /^oc_[A-Za-z0-9_-]{4,128}$/);
  if (chatId !== claim.outbox.destination_chat_id) throw new Error("Feishu receipt chat does not match the bound destination");
  const ledgerPath = join(paths.outboundLedger, claim.filename);
  const ledger = requireSchema(readJson(ledgerPath), OUTBOUND_LEDGER_SCHEMA, "outbound ledger");
  if (ledger.attempt_id !== claim.ledger.attempt_id) return false;
  const existingRaw = readJson(join(paths.outboundReceipts, claim.filename), { optional: true });
  const existing = existingRaw ? requireSchema(existingRaw, OUTBOUND_RECEIPT_SCHEMA, "outbound receipt") : undefined;
  const messageIds = Array.isArray(existing?.message_ids) ? [...existing.message_ids] : [];
  messageIds[claim.chunk.index] = messageId;
  const receiptRecord = {
    schema: OUTBOUND_RECEIPT_SCHEMA,
    event_id: claim.outbox.event_id,
    attempt: ledger.attempts,
    idempotency_keys: claim.outbox.chunks.map((chunk) => chunk.idempotency_key),
    message_ids: messageIds,
    chat_id: chatId,
    posted_at: nowIso(),
  };
  atomicJson(join(paths.outboundReceipts, claim.filename), receiptRecord);
  atomicJson(join(paths.outboundMessageMap, `${sha(messageId)}.json`), {
    schema: "fm-feishu-outbound-message-map.v1",
    message_id: messageId,
    event_id: claim.outbox.event_id,
    chunk_index: claim.chunk.index,
    decision_ref: claim.outbox.decision_ref,
    decision_key: claim.outbox.decision_key,
    binding_generation: claim.outbox.binding_generation,
    recorded_at: nowIso(),
  });
  const nextChunk = claim.chunk.index + 1;
  atomicJson(ledgerPath, {
    ...ledger,
    state: nextChunk >= claim.outbox.chunks.length ? "posted" : "pending",
    next_chunk: nextChunk,
    retry_at_ms: 0,
    last_error: null,
    posted_at: nextChunk >= claim.outbox.chunks.length ? nowIso() : null,
  });
  return true;
}

export function registerPendingDecision(home, input) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
  if (!pairingIsActive(pairing) || !binding || binding.status !== "active") throw new Error("Feishu channel is not active");
  const decisionRef = requireString(input.decisionRef, "decision_ref", /^[A-Za-z0-9._:-]{1,160}$/);
  const decisionKey = requireString(input.decisionKey, "decision_key", /^[A-Za-z0-9._:-]{1,160}$/);
  const sessionId = requireString(input.sessionId, "Pi session id", /^[0-9a-fA-F-]{16,128}$/);
  if (sessionId !== binding.session_id) throw new Error("decision registration does not match the bound Pi session");
  const path = join(paths.pendingDecisions, `${sha(decisionRef)}.json`);
  const prior = readJson(path, { optional: true });
  if (prior && (prior.decision_ref !== decisionRef || prior.decision_key !== decisionKey)) throw new Error("decision_ref is already bound to another exact key");
  const record = prior ?? {
    schema: DECISION_SCHEMA,
    decision_ref: decisionRef,
    decision_key: decisionKey,
    session_id: sessionId,
    binding_generation: binding.generation,
    state: "awaiting-outbound",
    registered_at: nowIso(),
    outbound_event_id: null,
  };
  atomicJson(path, record);
  return record;
}

export function claimPendingDecisionForOutbound(home, sessionId, bindingGeneration) {
  const paths = ensurePrivateLayout(home);
  const candidates = [];
  for (const name of safeJsonNames(paths.pendingDecisions)) {
    const record = readJson(join(paths.pendingDecisions, name));
    if (record.schema === DECISION_SCHEMA && record.state === "awaiting-outbound" && record.session_id === sessionId && record.binding_generation === bindingGeneration) {
      candidates.push({ name, record });
    }
  }
  if (candidates.length === 0) return undefined;
  if (candidates.length > 1) {
    createLocalAlert(paths, "ambiguous-decision-correlation", stableId("decision_", `${sessionId}\0${bindingGeneration}`, 24), "More than one exact Feishu decision registration awaited the same final response. None was guessed; reconcile the registrations locally.");
    return undefined;
  }
  return candidates[0];
}

export function bindPendingDecisionToOutbound(home, candidate, eventId) {
  if (!candidate) return;
  const paths = ensurePrivateLayout(home);
  const path = join(paths.pendingDecisions, candidate.name);
  const current = readJson(path);
  if (current.state !== "awaiting-outbound") return;
  atomicJson(path, { ...current, state: "sent-to-outbox", outbound_event_id: eventId, outbound_registered_at: nowIso() });
}

export function claimTransportOwner(home, owner) {
  const paths = ensurePrivateLayout(home);
  return withLock(paths, "transport-owner", () => {
    const prior = readJson(paths.owner, { optional: true });
    if (prior && prior.nonce !== owner.nonce && pidAlive(prior.pid)) {
      return { ok: false, owner: prior };
    }
    const record = {
      schema: "fm-feishu-transport-owner.v1",
      pid: process.pid,
      nonce: requireString(owner.nonce, "transport nonce", /^[a-f0-9]{24,128}$/),
      module_file: requireString(owner.moduleFile, "transport module path", undefined, 4096),
      home_realpath: paths.home,
      started_at: nowIso(),
    };
    atomicJson(paths.owner, record);
    return { ok: true, owner: record };
  });
}

export function readTransportOwner(home) {
  const paths = pathsForHome(home);
  return readJson(paths.owner, { optional: true });
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
    summary: safeKind === "drop" || safeKind === "buffer-overflow"
      ? "lark-cli reported an event loss or backpressure condition"
      : "transport diagnostic recorded; inspect the owning command directly if local remediation is needed",
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
    owner_pid: patch.ownerPid ?? prior?.owner_pid ?? null,
    reconnects: patch.reconnects ?? prior?.reconnects ?? 0,
    drop_diagnostics: patch.dropDiagnostics ?? prior?.drop_diagnostics ?? 0,
    last_ready_at: patch.lastReadyAt ?? prior?.last_ready_at ?? null,
    last_reconcile_at: patch.lastReconcileAt ?? prior?.last_reconcile_at ?? null,
    last_error_type: patch.lastErrorType ?? null,
    updated_at: nowIso(),
  };
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

export function statusSummary(home) {
  const paths = ensurePrivateLayout(home);
  const pairingRaw = readJson(paths.pairing, { optional: true });
  const bindingRaw = readJson(paths.activeBinding, { optional: true });
  const pairing = pairingRaw ? validatePairingRecord(pairingRaw) : undefined;
  const binding = bindingRaw ? validateBindingRecord(bindingRaw) : undefined;
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
    schema: "fm-feishu-status.v1",
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
    transport_healthy: health?.healthy === true,
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
    inbound_dispatching: status.inbound.dispatching,
    outbound_pending: status.outbound_pending,
    outbound_uncertain: status.outbound_uncertain,
  };
}

function cliUsage() {
  return "usage: fm-feishu-state.mjs status [--public] [--home <path>] | decision-register <decision-ref> <decision-key> [--home <path>]";
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
    const [decisionRef, decisionKey] = argv;
    if (!decisionRef || !decisionKey || !process.env.PI_SESSION_ID) throw new Error(cliUsage());
    const record = registerPendingDecision(home, {
      decisionRef,
      decisionKey,
      sessionId: process.env.PI_SESSION_ID,
    });
    process.stdout.write(`${JSON.stringify({ ok: true, decision_ref: record.decision_ref, decision_key: record.decision_key })}\n`);
    return;
  }
  throw new Error(cliUsage());
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(MODULE_FILE)) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`fm-feishu-state: ${error.message}\n`);
    process.exitCode = 2;
  });
}
