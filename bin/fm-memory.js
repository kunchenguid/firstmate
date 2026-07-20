#!/usr/bin/env node
/*
 * fm-memory.js - canonical private durable session-memory owner.
 *
 * Canonical files live under $FM_DATA_OVERRIDE/memory or
 * $FM_HOME/data/memory. Events are immutable, one-file append records under
 * events/<writer>/; this per-writer layout avoids a shared append race.
 * Checkpoints are immutable Markdown plus a SHA-256 sidecar under checkpoints/.
 * Canonical files never depend on the optional search projection.
 *
 * Event schema fm.memory.event.v1:
 *   schema, event_id, sequence, created_at, writer, runtime, session, task,
 *   project, type, payload, sources[], sensitivity, previous_high_water.
 * sequence is the sortable <UTC milliseconds>-<event id prefix>. Retries with
 * the same --idempotency-key resolve to the same event_id and never append a
 * duplicate. Payload JSON is limited to 8192 bytes; source references to 32.
 *
 * Checkpoint schema fm.memory.checkpoint.v1 is the JSON object inside the
 * generated Markdown fence. It carries checkpoint_id, created_at, reason,
 * runtime/session/project scope, event_high_water, objective, completed,
 * pending, decisions, constraints, blockers, active_tasks, evidence,
 * next_safe_action, provenance, and sensitivity. Input is JSON from --input
 * or stdin. Unknown fields are rejected. Files are temp-written, fsynced,
 * published by hard link, read back, schema/high-water validated, and never
 * overwritten. The sidecar hashes the exact Markdown bytes.
 *
 * Bounds: 8192-byte event payload, 65536-byte checkpoint input, 5000 events,
 * 1000 retained checkpoints, 20 search results by default (max 100), 12000-byte
 * recovery capsule. Restricted events and checkpoints are excluded from search
 * unless explicitly requested; curated files retain file-level access. Event
 * capacity exhaustion refuses, while checkpoint publication retains the newest
 * validated 1000 records and removes older checkpoint/hash pairs.
 *
 * Usage:
 *   fm-memory.sh event --type TYPE [scope flags] [--payload-file FILE|-]
 *   fm-memory.sh checkpoint --reason REASON [--input FILE|-]
 *   fm-memory.sh boundary --reason REASON [--runtime NAME]
 *   fm-memory.sh validate [checkpoint-file]
 *   fm-memory.sh recover [--max-events N]
 *   fm-memory.sh codex-stage-recovery
 *   fm-memory.sh codex-claim-recovery --event Stop|UserPromptSubmit
 *   fm-memory.sh search [--query TEXT] [--kind events|checkpoints|curated]
 *                       [--project P] [--task T] [--type T] [--status S] [--since ISO]
 *                       [--limit N] [--include-sensitive]
 *   fm-memory.sh transcript-ref --runtime NAME --session ID [--path FILE]
 *
 * This implementation was inspired by Nous Research Hermes Agent's durable
 * session lineage, bounded retrieval, pre-compression memory callback, atomic
 * curated-memory writes, and source-first search policy. It is an independent
 * Node/shell implementation for Firstmate, not format-compatible copied code.
 */

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCHEMA_EVENT = "fm.memory.event.v1";
const SCHEMA_CHECKPOINT = "fm.memory.checkpoint.v1";
const SCHEMA_CODEX_RECOVERY = "fm.memory.codex-recovery.v1";
const MAX_EVENT_PAYLOAD = 8192;
const MAX_CHECKPOINT_INPUT = 65536;
const MAX_EVENTS = 5000;
const MAX_CHECKPOINTS = 1000;
const MAX_CAPSULE = 12000;
const TYPES = new Set(["objective", "decision", "approval", "blocker", "task-transition", "artifact", "pr", "test", "checkpoint", "recovery", "session-lineage"]);
const SENSITIVITY = new Set(["internal", "private", "restricted"]);
const CHECKPOINT_KEYS = new Set(["runtime", "session", "project", "objective", "completed", "pending", "decisions", "constraints", "blockers", "active_tasks", "evidence", "next_safe_action", "provenance", "sensitivity", "event_high_water"]);
const SECRET_RE = /(-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|["']?\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)\b["']?\s*[:=]\s*["']?[^\s"']{6,}|\b(?:bearer|basic)\s+[A-Za-z0-9+/_=-]{12,}|\b(?:gh[opusr]_|sk-[A-Za-z0-9])\S{8,})/i;
const COT_RE = /\b(chain[- ]of[- ]thought|hidden reasoning|private reasoning|scratchpad reasoning)\b/i;

function fail(message, code = 2) {
  process.stderr.write(`fm-memory: ${message}\n`);
  process.exit(code);
}

function argsOf(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) { out._.push(arg); continue; }
    const key = arg.slice(2);
    if (["include-sensitive", "read-only", "retain"].includes(key)) { out[key] = true; continue; }
    if (i + 1 >= argv.length) fail(`missing value for ${arg}`);
    out[key] = argv[++i];
  }
  return out;
}

function resolvedLayout() {
  const root = process.env.FM_ROOT_OVERRIDE || path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const data = process.env.FM_DATA_OVERRIDE || path.join(home, "data");
  const state = process.env.FM_STATE_OVERRIDE || path.join(home, "state");
  return { root: path.resolve(root), home: path.resolve(home), data: path.resolve(data), state: path.resolve(state), memory: path.resolve(data, "memory") };
}

function inside(child, parent) {
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function safeName(value, label, fallback = "none") {
  const text = String(value || fallback);
  if (!/^[A-Za-z0-9._-]{1,128}$/.test(text)) fail(`unsafe ${label}: ${text}`);
  return text;
}

function ensurePrivateDataRoot(layout) {
  let stat;
  try {
    stat = fs.lstatSync(layout.data);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    const parent = path.dirname(layout.data);
    const parentStat = fs.lstatSync(parent);
    if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) fail("active data root parent must be a real directory");
    try { fs.mkdirSync(layout.data, { mode: 0o700 }); } catch (mkdirError) {
      if (mkdirError?.code !== "EEXIST") throw mkdirError;
    }
    stat = fs.lstatSync(layout.data);
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail("active data root must be a real directory");
  fs.chmodSync(layout.data, 0o700);
}

function ensurePrivateDirectory(layout, dir) {
  const target = path.resolve(dir);
  if (!inside(target, layout.memory)) fail("memory directory escapes the active data root");
  ensurePrivateDataRoot(layout);
  let current = layout.data;
  const parts = path.relative(layout.data, target).split(path.sep).filter(Boolean);
  for (const part of parts) {
    current = path.join(current, part);
    try {
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`memory parent is not a real directory: ${current}`);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      try { fs.mkdirSync(current, { mode: 0o700 }); } catch (mkdirError) {
        if (mkdirError?.code !== "EEXIST") throw mkdirError;
      }
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`memory parent is not a real directory: ${current}`);
    }
    fs.chmodSync(current, 0o700);
  }
}

function safeMemoryDirectory(layout, dir) {
  const target = path.resolve(dir);
  if (!inside(target, layout.memory)) return false;
  try {
    const dataStat = fs.lstatSync(layout.data);
    if (!dataStat.isDirectory() || dataStat.isSymbolicLink()) return false;
    let current = layout.data;
    const parts = path.relative(layout.data, target).split(path.sep).filter(Boolean);
    for (const part of parts) {
      current = path.join(current, part);
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) return false;
    }
    return true;
  } catch { return false; }
}

function sha(value) { return crypto.createHash("sha256").update(value).digest("hex"); }
function hashFile(file, maxBytes = 100 * 1024 * 1024) {
  const stat = fs.statSync(file);
  if (stat.size > maxBytes) fail(`evidence file exceeds ${maxBytes} bytes`);
  const hash = crypto.createHash("sha256");
  const fd = fs.openSync(file, "r");
  const buffer = Buffer.alloc(64 * 1024);
  let offset = 0;
  try {
    while (offset < stat.size) {
      const read = fs.readSync(fd, buffer, 0, Math.min(buffer.length, stat.size - offset), offset);
      if (!read) break;
      hash.update(buffer.subarray(0, read));
      offset += read;
    }
  } finally { fs.closeSync(fd); }
  return hash.digest("hex");
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
function stableJson(value) { return JSON.stringify(canonical(value)); }
function now() { return new Date().toISOString(); }
function compactTime(iso) { return iso.replace(/[-:.TZ]/g, "").slice(0, 17); }

function readBounded(file, limit) {
  if (file === "-") {
    return readStdinBounded(limit);
  }
  const target = path.resolve(file);
  const stat = fs.lstatSync(target);
  if (!stat.isFile() || stat.isSymbolicLink()) fail("input must be a regular non-symlink file");
  if (stat.size > limit) fail(`input exceeds ${limit} bytes`);
  return fs.readFileSync(target, "utf8");
}

function readStdinBounded(limit) {
  const chunks = [];
  const buffer = Buffer.alloc(Math.min(64 * 1024, limit + 1));
  let total = 0;
  while (total <= limit) {
    const read = fs.readSync(0, buffer, 0, Math.min(buffer.length, limit + 1 - total), null);
    if (!read) break;
    chunks.push(Buffer.from(buffer.subarray(0, read)));
    total += read;
  }
  if (total > limit) fail(`stdin exceeds ${limit} bytes`);
  return Buffer.concat(chunks).toString("utf8");
}

function rejectSecrets(value) {
  const text = typeof value === "string" ? value : stableJson(value);
  if (SECRET_RE.test(text)) fail("content resembles a secret or credential");
  if (COT_RE.test(text)) fail("chain-of-thought or private reasoning is not valid memory evidence");
}

function atomicCreate(layout, file, bytes) {
  ensurePrivateDirectory(layout, path.dirname(file));
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
  const fd = fs.openSync(tmp, "wx", 0o600);
  try {
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  let created = true;
  try { fs.linkSync(tmp, file); } catch (error) {
    if (error.code !== "EEXIST") throw error;
    created = false;
  } finally { fs.unlinkSync(tmp); }
  try {
    const dfd = fs.openSync(path.dirname(file), "r");
    try { fs.fsyncSync(dfd); } finally { fs.closeSync(dfd); }
  } catch { /* Directory fsync is unavailable on some filesystems. */ }
  return created;
}

function atomicReplace(layout, file, bytes) {
  ensurePrivateDirectory(layout, path.dirname(file));
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
  const fd = fs.openSync(tmp, "wx", 0o600);
  try {
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  try { fs.renameSync(tmp, file); } catch (error) {
    try { fs.unlinkSync(tmp); } catch { }
    throw error;
  }
  try {
    const dfd = fs.openSync(path.dirname(file), "r");
    try { fs.fsyncSync(dfd); } finally { fs.closeSync(dfd); }
  } catch { }
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error?.code === "EPERM"; }
}

function pause(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function withWriteLock(layout, action) {
  ensurePrivateDirectory(layout, layout.memory);
  const lock = path.join(layout.memory, ".write-lock");
  const token = `${process.pid}:${crypto.randomBytes(12).toString("hex")}`;
  const deadline = Date.now() + 10000;
  while (true) {
    try {
      const fd = fs.openSync(lock, "wx", 0o600);
      try { fs.writeFileSync(fd, `${token}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      let stat;
      let current;
      try {
        stat = fs.lstatSync(lock);
        current = fs.readFileSync(lock, "utf8").trim();
      } catch (readError) {
        if (readError?.code === "ENOENT") continue;
        throw readError;
      }
      if (!stat.isFile() || stat.isSymbolicLink()) fail("memory write lock is not a regular file");
      const holder = Number(current.split(":", 1)[0]);
      if (Number.isSafeInteger(holder) && holder > 1 && !processAlive(holder)) {
        try {
          if (fs.readFileSync(lock, "utf8").trim() === current) fs.unlinkSync(lock);
        } catch (staleError) {
          if (staleError?.code !== "ENOENT") throw staleError;
        }
        continue;
      }
      if (Date.now() >= deadline) fail("timed out waiting for the memory write lock");
      pause(10);
    }
  }
  try { return action(); } finally {
    try {
      if (fs.readFileSync(lock, "utf8").trim() === token) fs.unlinkSync(lock);
    } catch { }
  }
}

function listFiles(dir, suffix) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) out.push(...listFiles(full, suffix));
    else if (ent.isFile() && ent.name.endsWith(suffix)) out.push(full);
  }
  return out.sort();
}

function readEvent(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 32768) return null;
    const event = JSON.parse(fs.readFileSync(file, "utf8"));
    if (event.schema !== SCHEMA_EVENT || !event.event_id || !event.sequence || !event.created_at) return null;
    return event;
  } catch { return null; }
}

function allEvents(layout) {
  if (!safeMemoryDirectory(layout, path.join(layout.memory, "events"))) return [];
  return listFiles(path.join(layout.memory, "events"), ".json").map(readEvent).filter(Boolean).sort((a, b) => `${a.sequence}|${a.event_id}`.localeCompare(`${b.sequence}|${b.event_id}`));
}

function highWater(events) {
  const last = events.at(-1);
  return last ? `${last.sequence}|${last.event_id}` : "none";
}

function parsePayload(opts) {
  if (!opts["payload-file"]) return {};
  const raw = readBounded(opts["payload-file"], MAX_EVENT_PAYLOAD);
  try { return JSON.parse(raw || "{}"); } catch { return { summary: raw.trim() }; }
}

function writeEvent(layout, opts, forced = {}) {
  const type = forced.type || opts.type;
  if (!TYPES.has(type)) fail(`unsupported event type: ${type || "(missing)"}`);
  const runtime = safeName(forced.runtime || opts.runtime || "unknown", "runtime");
  const session = safeName(forced.session || opts.session || "unknown", "session");
  const writer = safeName(forced.writer || opts.writer || `${runtime}-${session === "unknown" ? process.pid : session}`, "writer");
  const task = safeName(forced.task || opts.task || "none", "task");
  const project = safeName(forced.project || opts.project || "none", "project");
  const sensitivity = forced.sensitivity || opts.sensitivity || "private";
  if (!SENSITIVITY.has(sensitivity)) fail(`unsupported sensitivity: ${sensitivity}`);
  const payload = forced.payload ?? parsePayload(opts);
  const sources = forced.sources || (opts.source ? String(opts.source).split(",").map((v) => v.trim()).filter(Boolean) : []);
  if (sources.length > 32 || sources.some((v) => typeof v !== "string" || v.length > 512)) fail("source references exceed bounds");
  const payloadBytes = Buffer.byteLength(stableJson(payload));
  if (payloadBytes > MAX_EVENT_PAYLOAD) fail(`event payload exceeds ${MAX_EVENT_PAYLOAD} bytes`);
  rejectSecrets(payload);
  rejectSecrets(sources);
  const events = allEvents(layout);
  if (events.length >= MAX_EVENTS) fail(`event capacity ${MAX_EVENTS} reached; archive this home's memory before writing more`);
  const idempotency = opts["idempotency-key"] || forced.idempotency || stableJson({ type, writer, runtime, session, task, project, payload, sources });
  if (String(idempotency).length > 512) fail("idempotency key exceeds 512 characters");
  const eventId = `ev_${sha(`${SCHEMA_EVENT}\0${writer}\0${idempotency}`).slice(0, 24)}`;
  const existing = events.find((item) => item.event_id === eventId);
  if (existing) {
    const retryShape = { runtime, session, task, project, type, payload, sources, sensitivity };
    const existingShape = Object.fromEntries(Object.keys(retryShape).map((key) => [key, existing[key]]));
    if (stableJson(retryShape) !== stableJson(existingShape)) fail("idempotency key already belongs to a different event");
    if (!forced.quiet) process.stdout.write(`${existing.event_id}\n`);
    return existing;
  }
  const createdAt = forced.createdAt || now();
  const record = {
    schema: SCHEMA_EVENT,
    event_id: eventId,
    sequence: `${compactTime(createdAt)}-${eventId.slice(3, 11)}`,
    created_at: createdAt,
    writer, runtime, session, task, project, type, payload, sources,
    sensitivity,
    previous_high_water: highWater(events),
  };
  const file = path.join(layout.memory, "events", writer, `${eventId}.json`);
  const created = atomicCreate(layout, file, `${stableJson(record)}\n`);
  if (!created) {
    const winner = readEvent(file);
    const retryShape = { runtime, session, task, project, type, payload, sources, sensitivity };
    const winnerShape = winner && Object.fromEntries(Object.keys(retryShape).map((key) => [key, winner[key]]));
    if (!winner || stableJson(retryShape) !== stableJson(winnerShape)) fail("concurrent idempotency key conflict");
    if (!forced.quiet) process.stdout.write(`${winner.event_id}\n`);
    return winner;
  }
  if (!forced.quiet) process.stdout.write(`${eventId}\n`);
  return record;
}

function eventCommand(opts, forced = {}) {
  const layout = resolvedLayout();
  if (!lockOwned(layout)) fail("event write requires the active home session lock");
  return withWriteLock(layout, () => writeEvent(layout, opts, forced));
}

function currentGitEvidence(layout) {
  try {
    const head = execFileSync("git", ["-C", layout.root, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 2000 }).trim();
    const dirty = execFileSync("git", ["-C", layout.root, "status", "--porcelain"], { encoding: "utf8", timeout: 2000 }).trim() !== "";
    return { kind: "git", ref: layout.root, expected: { head, dirty } };
  } catch { return { kind: "git", ref: layout.root, expected: { unavailable: true } }; }
}

function activeTaskRefs(layout) {
  if (!fs.existsSync(layout.state)) return [];
  return fs.readdirSync(layout.state).filter((name) => name.endsWith(".meta")).sort().slice(0, 100).map((name) => name.slice(0, -5));
}

function validateEvidence(evidence, layout) {
  for (const item of evidence) {
    if (!item || typeof item !== "object" || Array.isArray(item) || typeof item.kind !== "string" || typeof item.ref !== "string") fail("checkpoint evidence entries require kind and ref strings");
    if (item.kind === "task") {
      const task = safeName(item.ref, "task evidence");
      if (!fs.existsSync(path.join(layout.state, `${task}.meta`))) fail(`task evidence is not currently verifiable: ${task}`);
    } else if (item.kind === "git") {
      if (path.resolve(item.ref) !== layout.root || typeof item.expected?.head !== "string") fail("git evidence must reference the active root and expected HEAD");
      let head;
      try { head = execFileSync("git", ["-C", layout.root, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 2000 }).trim(); } catch { fail("git evidence is not currently verifiable"); }
      if (head !== item.expected.head) fail("git evidence expected HEAD does not match current authority");
    } else if (item.kind === "file") {
      const target = path.resolve(item.ref);
      if (!inside(target, layout.data) && !inside(target, layout.state)) fail("file evidence must remain under the active home's data or state directory");
      const stat = fs.lstatSync(target);
      if (!stat.isFile() || stat.isSymbolicLink() || typeof item.expected?.sha256 !== "string" || hashFile(target) !== item.expected.sha256) fail("file evidence hash is not currently verifiable");
    } else if (!["artifact", "commit", "pr", "test", "report"].includes(item.kind) || item.validation !== "external") {
      fail(`unsupported or unvalidated evidence kind: ${item.kind}`);
    }
  }
}

function normalizeCheckpoint(input, opts, layout) {
  for (const key of Object.keys(input)) if (!CHECKPOINT_KEYS.has(key)) fail(`unknown checkpoint field: ${key}`);
  const strings = ["objective", "next_safe_action"];
  for (const key of strings) if (typeof input[key] !== "string" || !input[key].trim()) fail(`checkpoint ${key} is required`);
  const arrays = ["completed", "pending", "decisions", "constraints", "blockers", "active_tasks", "evidence", "provenance"];
  for (const key of arrays) {
    if (input[key] === undefined) input[key] = [];
    if (!Array.isArray(input[key]) || input[key].length > 100) fail(`checkpoint ${key} must be an array of at most 100 items`);
  }
  validateEvidence(input.evidence, layout);
  rejectSecrets(input);
  const events = allEvents(layout);
  const eventHighWater = input.event_high_water || highWater(events);
  if (eventHighWater !== "none" && !events.some((event) => `${event.sequence}|${event.event_id}` === eventHighWater)) fail("checkpoint event_high_water does not reference a valid event");
  const createdAt = now();
  const scope = {
    runtime: safeName(input.runtime || opts.runtime || "unknown", "runtime"),
    session: safeName(input.session || opts.session || "unknown", "session"),
    project: safeName(input.project || opts.project || "none", "project"),
  };
  const reason = safeName(opts.reason || "manual", "reason");
  const body = { schema: SCHEMA_CHECKPOINT, created_at: createdAt, reason, ...scope, event_high_water: eventHighWater, ...input };
  delete body.checkpoint_id;
  body.checkpoint_id = `cp_${sha(stableJson(body)).slice(0, 24)}`;
  return body;
}

function checkpointMarkdown(cp) {
  return `---\nschema: ${SCHEMA_CHECKPOINT}\ncheckpoint_id: ${cp.checkpoint_id}\ncreated_at: ${cp.created_at}\nreason: ${cp.reason}\nruntime: ${cp.runtime}\nsession: ${cp.session}\nproject: ${cp.project}\nsensitivity: ${cp.sensitivity || "private"}\n---\n\n# Firstmate Recovery Checkpoint\n\nThis immutable record references authoritative owners; it does not override them.\n\n\`\`\`json\n${stableJson(cp)}\n\`\`\`\n`;
}

function parseCheckpoint(file, layout = resolvedLayout()) {
  try {
    const target = path.resolve(file);
    if (!inside(target, path.join(layout.memory, "checkpoints"))) return { valid: false, reason: "outside checkpoint directory" };
    if (!safeMemoryDirectory(layout, path.dirname(target))) return { valid: false, reason: "unsafe checkpoint parent" };
    const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 131072) return { valid: false, reason: "unsafe checkpoint file" };
    const markdown = fs.readFileSync(target, "utf8");
    const sidecar = `${target}.sha256`;
    const sidecarStat = fs.lstatSync(sidecar);
    if (!sidecarStat.isFile() || sidecarStat.isSymbolicLink() || sidecarStat.size > 256 || fs.readFileSync(sidecar, "utf8").trim() !== sha(markdown)) return { valid: false, reason: "hash mismatch" };
    const match = markdown.match(/```json\n([^\n]+)\n```/);
    if (!match) return { valid: false, reason: "missing canonical JSON fence" };
    const cp = JSON.parse(match[1]);
    if (cp.schema !== SCHEMA_CHECKPOINT || !cp.checkpoint_id || !cp.objective || !cp.next_safe_action) return { valid: false, reason: "schema invalid" };
    const claimedId = cp.checkpoint_id;
    const unhashed = { ...cp };
    delete unhashed.checkpoint_id;
    if (`cp_${sha(stableJson(unhashed)).slice(0, 24)}` !== claimedId) return { valid: false, reason: "checkpoint id mismatch" };
    const events = allEvents(layout);
    if (cp.event_high_water !== "none" && !events.some((event) => `${event.sequence}|${event.event_id}` === cp.event_high_water)) return { valid: false, reason: "event high-water missing" };
    return { valid: true, checkpoint: cp, file: target };
  } catch (error) { return { valid: false, reason: error.message }; }
}

function checkpointCommand(opts, supplied) {
  const layout = resolvedLayout();
  if (!lockOwned(layout)) fail("checkpoint write requires the active home session lock");
  let input = supplied;
  if (!input) {
    const raw = readBounded(opts.input || "-", MAX_CHECKPOINT_INPUT);
    try { input = JSON.parse(raw); } catch { fail("checkpoint input must be valid JSON"); }
  }
  const result = withWriteLock(layout, () => {
    if (allEvents(layout).length >= MAX_EVENTS) fail(`event capacity ${MAX_EVENTS} reached; archive this home's memory before writing more`);
    const cp = normalizeCheckpoint(input, opts, layout);
    const markdown = checkpointMarkdown(cp);
    const dir = path.join(layout.memory, "checkpoints");
    const file = path.join(dir, `${compactTime(cp.created_at)}-${cp.checkpoint_id}.md`);
    atomicCreate(layout, file, markdown);
    atomicCreate(layout, `${file}.sha256`, `${sha(markdown)}\n`);
    const checked = parseCheckpoint(file, layout);
    if (!checked.valid) fail(`checkpoint read-back validation failed: ${checked.reason}`);
    writeEvent(layout, opts, { type: "checkpoint", runtime: cp.runtime, session: cp.session, project: cp.project, payload: { checkpoint_id: cp.checkpoint_id, reason: cp.reason, event_high_water: cp.event_high_water }, sources: [`checkpoint:${cp.checkpoint_id}`], idempotency: cp.checkpoint_id, quiet: true });
    retainRecentCheckpoints(layout, file);
    return { cp, file };
  });
  const { cp, file } = result;
  process.stdout.write(`${file}\n`);
  return cp;
}

function retainRecentCheckpoints(layout, protectedFile) {
  const dir = path.join(layout.memory, "checkpoints");
  const files = listFiles(dir, ".md");
  const removable = files.filter((file) => path.resolve(file) !== path.resolve(protectedFile));
  while (removable.length > MAX_CHECKPOINTS - 1) {
    const file = removable.shift();
    if (!file) break;
    try { fs.unlinkSync(file); } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    try { fs.unlinkSync(`${file}.sha256`); } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  try {
    const dfd = fs.openSync(dir, "r");
    try { fs.fsyncSync(dfd); } finally { fs.closeSync(dfd); }
  } catch { }
}

function lockOwned(layout) {
  const lock = path.join(layout.state, ".lock");
  try {
    const holder = fs.readFileSync(lock, "utf8").trim();
    if (!/^\d+$/.test(holder) || holder === "1") return false;
    let pid = process.pid;
    for (let i = 0; i < 10; i += 1) {
      if (String(pid) === holder) return true;
      const out = execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8", timeout: 1000 }).trim();
      if (!/^\d+$/.test(out) || out === "1") break;
      pid = Number(out);
    }
    return false;
  } catch { return false; }
}

function runtimeFromEnv(opts) {
  if (opts.runtime) return opts.runtime;
  if (process.env.FM_MEMORY_RUNTIME) return process.env.FM_MEMORY_RUNTIME;
  if (process.env.CLAUDECODE) return "claude";
  if (process.env.PI_CODING_AGENT) return "pi";
  if (process.env.GROK_AGENT || process.env.GROK_HOOK_EVENT) return "grok";
  return "unknown";
}

function payloadSession(raw) {
  try {
    const value = JSON.parse(raw || "{}");
    return value.session_id || value.sessionId || value.thread_id || value.threadId || "unknown";
  } catch { return "unknown"; }
}

function payloadTurn(raw) {
  try {
    const value = JSON.parse(raw || "{}");
    return value.turn_id || value.turnId || "";
  } catch { return ""; }
}

function latestCheckpoint(layout) {
  if (!safeMemoryDirectory(layout, path.join(layout.memory, "checkpoints"))) return { valid: false, invalid: [] };
  const files = listFiles(path.join(layout.memory, "checkpoints"), ".md").reverse();
  const invalid = [];
  for (const file of files) {
    const result = parseCheckpoint(file, layout);
    if (result.valid) return { ...result, invalid };
    invalid.push({ file, reason: result.reason });
  }
  return { valid: false, invalid };
}

function boundaryCommand(opts) {
  const layout = resolvedLayout();
  if (opts["read-only"] || !lockOwned(layout)) { process.stdout.write("skipped: session lock not owned\n"); return; }
  const raw = readStdinBounded(16384);
  const runtime = safeName(runtimeFromEnv(opts), "runtime");
  const session = safeName(opts.session || payloadSession(raw), "session");
  const reason = opts.reason || "turn-end";
  const turn = payloadTurn(raw);
  const lineage = eventCommand(opts, { type: "session-lineage", runtime, session, payload: { reason, evidence: "opaque runtime session identifier; transcript content not copied" }, sources: [`runtime:${runtime}`], idempotency: `${reason}:${runtime}:${session}:${opts["idempotency-key"] || turn || compactTime(now()).slice(0, 12)}`, quiet: true });
  const previous = latestCheckpoint(layout);
  const prior = previous.valid ? previous.checkpoint : {};
  const active = activeTaskRefs(layout);
  const input = {
    runtime, session, project: opts.project || prior.project || "none",
    objective: prior.objective || "Recover the active Firstmate session from durable authority after a context boundary.",
    completed: prior.completed || [], pending: prior.pending || [], decisions: prior.decisions || [], constraints: prior.constraints || [], blockers: prior.blockers || [],
    active_tasks: active,
    evidence: [...(prior.evidence || []).filter((item) => !["git", "task", "file"].includes(item?.kind)), currentGitEvidence(layout), ...active.map((task) => ({ kind: "task", ref: task, expected: { meta_present: true } }))].slice(-100),
    next_safe_action: prior.next_safe_action || "Read the bounded recovery capsule, then reconcile it with the session-start digest before consequential work.",
    provenance: [...(prior.provenance || []), `event:${lineage.event_id}`, "authority:data/backlog.md", "authority:state/*.meta", "authority:git"].slice(-100),
    sensitivity: "private",
    event_high_water: prior.event_high_water || "none",
  };
  checkpointCommand({ ...opts, reason, runtime, session }, input);
}

function reconcile(cp, layout) {
  const findings = [];
  for (const evidence of cp.evidence || []) {
    if (!evidence || typeof evidence !== "object") continue;
    if (evidence.kind === "task") {
      const ref = safeName(evidence.ref, "task evidence");
      if (!fs.existsSync(path.join(layout.state, `${ref}.meta`))) findings.push(`stale: task ${ref} no longer has authoritative metadata`);
    } else if (evidence.kind === "git" && path.resolve(evidence.ref) === layout.root && evidence.expected?.head) {
      try {
        const head = execFileSync("git", ["-C", layout.root, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 2000 }).trim();
        if (head !== evidence.expected.head) findings.push(`disputed: Git HEAD changed from ${evidence.expected.head.slice(0, 12)} to ${head.slice(0, 12)}`);
        const dirty = execFileSync("git", ["-C", layout.root, "status", "--porcelain"], { encoding: "utf8", timeout: 2000 }).trim() !== "";
        if (typeof evidence.expected.dirty === "boolean" && dirty !== evidence.expected.dirty) findings.push(`disputed: Git dirty state changed from ${evidence.expected.dirty} to ${dirty}`);
      } catch { findings.push("unverifiable: Git evidence could not be read"); }
    } else if (evidence.kind === "file") {
      try {
        if (hashFile(path.resolve(evidence.ref)) !== evidence.expected?.sha256) findings.push(`disputed: file evidence changed at ${evidence.ref}`);
      } catch { findings.push(`unverifiable: file evidence could not be read at ${evidence.ref}`); }
    }
  }
  return findings;
}

function recoverCommand(opts) {
  const layout = resolvedLayout();
  process.stdout.write(recoveryCapsule(layout, opts));
}

function recoveryCapsule(layout, opts) {
  const latest = latestCheckpoint(layout);
  const maxEvents = Math.max(0, Math.min(Number(opts["max-events"] || 20), 100));
  if (!latest.valid) {
    const note = latest.invalid.length ? `; ${latest.invalid.length} invalid checkpoint(s) ignored` : "";
    return `RECOVERY CAPSULE\ncheckpoint: none${note}\nobjective: use the session-start digest and authoritative records\nnext safe action: establish an objective and write a validated checkpoint before consequential work\n`;
  }
  const cp = latest.checkpoint;
  const events = allEvents(layout);
  const laterAll = events.filter((event) => cp.event_high_water === "none" || `${event.sequence}|${event.event_id}` > cp.event_high_water);
  const meaningful = laterAll.filter((event) => !["checkpoint", "session-lineage"].includes(event.type));
  const selected = meaningful.length ? meaningful : laterAll;
  const later = selected.slice(-maxEvents);
  const findings = reconcile(cp, layout);
  const lines = [
    "RECOVERY CAPSULE (bounded; memory is evidence, current authority wins)",
    `checkpoint: ${cp.checkpoint_id}`,
    `event high-water: ${cp.event_high_water}`,
    `objective: ${cp.objective}`,
    `next safe action: ${cp.next_safe_action}`,
    `unresolved decisions: ${(cp.decisions || []).length ? stableJson(cp.decisions) : "none recorded"}`,
    `blockers: ${(cp.blockers || []).length ? stableJson(cp.blockers) : "none recorded"}`,
    `active task references: ${(cp.active_tasks || []).join(", ") || "none"}`,
    `artifacts/evidence: ${(cp.evidence || []).length ? stableJson(cp.evidence).slice(0, 3000) : "none recorded"}`,
    `later event evidence (shown ${later.length} of ${selected.length}): ${later.length ? later.map((e) => `${e.event_id}:${e.type}:${stableJson(e.payload).slice(0, 400)}`).join(", ") : "none"}`,
    `contradictions: ${findings.length ? findings.join("; ") : "none found by bounded checks; reconcile with digest below"}`,
    `invalid newer checkpoints ignored: ${latest.invalid.length}`,
  ];
  let output = `${lines.join("\n")}\n`;
  if (Buffer.byteLength(output) > MAX_CAPSULE) {
    const suffix = `\n[recovery capsule truncated at ${MAX_CAPSULE} bytes]\n`;
    const budget = MAX_CAPSULE - Buffer.byteLength(suffix);
    const bytes = Buffer.from(output);
    let end = budget;
    while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
    output = `${bytes.subarray(0, end).toString("utf8")}${suffix}`;
  }
  return output;
}

function codexHookPayload(raw, expectedEvent) {
  let payload;
  try { payload = JSON.parse(raw); } catch { fail("Codex hook payload must be valid JSON"); }
  if (payload.hook_event_name !== expectedEvent) fail(`expected ${expectedEvent} hook payload`);
  return {
    session: safeName(payload.session_id, "Codex session"),
    turn: safeName(payload.turn_id, "Codex turn"),
    trigger: payload.trigger ? safeName(payload.trigger, "Codex compaction trigger") : "unknown",
  };
}

function codexRecoveryFile(layout, session) {
  return path.join(layout.memory, "pending", "codex", `${session}.json`);
}

function codexStageRecoveryCommand() {
  const layout = resolvedLayout();
  if (!lockOwned(layout)) fail("Codex recovery staging requires the active home session lock");
  const payload = codexHookPayload(readStdinBounded(16384), "PostCompact");
  withWriteLock(layout, () => {
    const record = {
      schema: SCHEMA_CODEX_RECOVERY,
      session: payload.session,
      turn: payload.turn,
      trigger: payload.trigger,
      staged_at: now(),
      capsule: recoveryCapsule(layout, { "max-events": 20 }),
    };
    atomicReplace(layout, codexRecoveryFile(layout, payload.session), `${stableJson(record)}\n`);
  });
}

function codexClaimRecoveryCommand(opts) {
  const layout = resolvedLayout();
  if (!lockOwned(layout)) return;
  const event = opts.event;
  if (!new Set(["Stop", "UserPromptSubmit"]).has(event)) fail("--event must be Stop or UserPromptSubmit");
  const payload = codexHookPayload(readStdinBounded(16384), event);
  const capsule = withWriteLock(layout, () => {
    const file = codexRecoveryFile(layout, payload.session);
    let stat;
    try { stat = fs.lstatSync(file); } catch (error) {
      if (error?.code === "ENOENT") return "";
      throw error;
    }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 32768) fail("pending Codex recovery is not a bounded regular file");
    const record = JSON.parse(fs.readFileSync(file, "utf8"));
    if (record.schema !== SCHEMA_CODEX_RECOVERY || record.session !== payload.session || typeof record.capsule !== "string" || Buffer.byteLength(record.capsule) > MAX_CAPSULE) fail("pending Codex recovery record is invalid");
    if (!opts.retain) fs.unlinkSync(file);
    return record.capsule;
  });
  if (capsule) process.stdout.write(capsule);
}

function searchCommand(opts) {
  const layout = resolvedLayout();
  const limit = Math.max(1, Math.min(Number(opts.limit || 20), 100));
  const query = String(opts.query || "").toLowerCase();
  const since = opts.since ? Date.parse(opts.since) : 0;
  if (opts.since && Number.isNaN(since)) fail("--since must be an ISO date");
  const results = [];
  const allow = (value) => opts["include-sensitive"] || value !== "restricted";
  if (!opts.kind || opts.kind === "events") {
    for (const event of allEvents(layout).reverse()) {
      if (!allow(event.sensitivity) || (opts.project && event.project !== opts.project) || (opts.task && event.task !== opts.task) || (opts.type && event.type !== opts.type) || (opts.status && event.payload?.status !== opts.status) || (since && Date.parse(event.created_at) < since)) continue;
      const text = stableJson(event);
      if (query && !text.toLowerCase().includes(query)) continue;
      results.push({ kind: "event", id: event.event_id, time: event.created_at, provenance: event.sources, snippet: text.slice(0, 600) });
    }
  }
  if (!opts.kind || opts.kind === "checkpoints") {
    const checkpointFiles = safeMemoryDirectory(layout, path.join(layout.memory, "checkpoints")) ? listFiles(path.join(layout.memory, "checkpoints"), ".md").reverse() : [];
    for (const file of checkpointFiles) {
      const parsed = parseCheckpoint(file, layout);
      if (!parsed.valid || !allow(parsed.checkpoint.sensitivity) || (opts.project && parsed.checkpoint.project !== opts.project) || (since && Date.parse(parsed.checkpoint.created_at) < since)) continue;
      const text = stableJson(parsed.checkpoint);
      if (query && !text.toLowerCase().includes(query)) continue;
      results.push({ kind: "checkpoint", id: parsed.checkpoint.checkpoint_id, time: parsed.checkpoint.created_at, provenance: parsed.checkpoint.provenance, snippet: text.slice(0, 600) });
    }
  }
  if (!opts.kind || opts.kind === "curated") {
    for (const name of ["captain.md", "captain-shared.md", "learnings.md", "backlog.md"]) {
      const file = path.join(layout.data, name);
      if (!fs.existsSync(file)) continue;
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink()) continue;
      const text = fs.readFileSync(file, "utf8").slice(0, 262144);
      const lower = text.toLowerCase();
      const at = query ? lower.indexOf(query) : 0;
      if (query && at < 0) continue;
      results.push({ kind: "curated", id: name, time: stat.mtime.toISOString(), provenance: [`authority:data/${name}`], snippet: text.slice(Math.max(0, at - 120), Math.max(0, at - 120) + 600) });
    }
  }
  process.stdout.write(`${stableJson({ schema: "fm.memory.search.v1", count: Math.min(results.length, limit), truncated: results.length > limit, results: results.slice(0, limit) })}\n`);
}

function transcriptRefCommand(opts) {
  const runtime = safeName(opts.runtime, "runtime");
  const session = safeName(opts.session, "session");
  const layout = resolvedLayout();
  const payload = { reference: session, content_copied: false };
  const sources = [`runtime:${runtime}`];
  if (opts.path) {
    const target = path.resolve(opts.path);
    if (inside(target, path.join(layout.home, "projects"))) fail("transcript evidence must not read under projects/");
    const runtimeRoots = {
      codex: [path.join(process.env.HOME || "", ".codex")],
      claude: [path.join(process.env.HOME || "", ".claude")],
      opencode: [path.join(process.env.HOME || "", ".local", "share", "opencode")],
      pi: [path.join(process.env.HOME || "", ".pi")],
      grok: [process.env.GROK_HOME || path.join(process.env.HOME || "", ".grok")],
    };
    const allowed = [layout.home, ...(runtimeRoots[runtime] || [])].filter(Boolean).map((root) => path.resolve(root));
    if (!allowed.some((root) => inside(target, root))) fail("transcript path is outside the active home and the selected runtime's known private store");
    const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.isSymbolicLink()) fail("transcript path must be a regular non-symlink file");
    payload.path = target;
    payload.bytes = stat.size;
    payload.sha256 = hashFile(target);
    sources.push(`file:${target}`);
  }
  eventCommand(opts, { type: "session-lineage", runtime, session, payload, sources, idempotency: `${runtime}:${session}:${payload.sha256 || "opaque"}` });
}

function help() {
  process.stdout.write("Usage: fm-memory.sh event|checkpoint|boundary|validate|recover|search|transcript-ref|codex-stage-recovery|codex-claim-recovery [options]\nSee bin/fm-memory.js header and docs/durable-memory.md for the canonical contracts.\n");
}

const [command, ...rest] = process.argv.slice(2);
const opts = argsOf(rest);
try {
  if (command === "event") eventCommand(opts);
  else if (command === "checkpoint") checkpointCommand(opts);
  else if (command === "boundary") boundaryCommand(opts);
  else if (command === "validate") {
    const layout = resolvedLayout();
    const target = opts._[0];
    const result = target ? parseCheckpoint(target, layout) : latestCheckpoint(layout);
    if (!result.valid) fail(`checkpoint invalid: ${result.reason || "none found"}`, 1);
    process.stdout.write(`${result.checkpoint.checkpoint_id}\n`);
  } else if (command === "recover") recoverCommand(opts);
  else if (command === "codex-stage-recovery") codexStageRecoveryCommand();
  else if (command === "codex-claim-recovery") codexClaimRecoveryCommand(opts);
  else if (command === "search") searchCommand(opts);
  else if (command === "transcript-ref") transcriptRefCommand(opts);
  else if (command === "--help" || command === "help" || !command) help();
  else fail(`unknown command: ${command}`);
} catch (error) {
  fail(error?.message || String(error), 1);
}
