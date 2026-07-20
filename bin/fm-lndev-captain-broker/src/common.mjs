import { createHash, randomBytes } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";

export const BROKER_VERSION = "0.1.0";
export const PROTOCOL = "fm-lndev-captain.v1";
export const DEFAULT_SUPPORTED_LNDEV_VERSIONS = [
  "lndev 0.1.0 (f6cc7cfe80561288b2dec737e79c1c12a379bcd8)",
];

export class BrokerDenied extends Error {
  constructor(reason, message = reason, details = {}) {
    super(message);
    this.name = "BrokerDenied";
    this.reason = reason;
    this.details = details;
  }
}

export function supportedLndevVersions() {
  const raw = process.env.FM_LNDEV_SUPPORTED_VERSIONS;
  if (!raw) return DEFAULT_SUPPORTED_LNDEV_VERSIONS;
  return raw
    .split(/\n|;/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

export function requireHome() {
  const home = process.env.FM_LNDEV_CAPTAIN_HOME || process.env.FM_HOME;
  if (!home) {
    throw new BrokerDenied("missing-fm-home", "FM_HOME is required for lndev captain broker");
  }
  return resolve(home);
}

export function ensureHomeDirs(home) {
  mkdirSync(join(home, "state"), { recursive: true, mode: 0o700 });
  mkdirSync(join(home, "data"), { recursive: true, mode: 0o700 });
}

export function socketPath(home) {
  return process.env.FM_LNDEV_CAPTAIN_SOCKET || join(home, "state", "lndev-captain.sock");
}

export function capabilityStorePath(home) {
  return join(home, "data", "lndev-captain-caps", "capabilities.json");
}

export function auditDir(home) {
  return join(home, "data", "lndev-captain-audit");
}

export function transcriptDir(home) {
  return join(home, "data", "lndev-captain-transcripts");
}

export function nowMs() {
  return Number(process.env.FM_LNDEV_NOW_MS || Date.now());
}

export function isoNow() {
  return new Date(nowMs()).toISOString();
}

export function randomId(prefix) {
  return `${prefix}_${randomBytes(12).toString("hex")}`;
}

export function randomHandle() {
  return `lndev_cap_v1_${randomBytes(32).toString("hex")}`;
}

export function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function canonicalJson(value) {
  return JSON.stringify(sortCanonical(value));
}

function sortCanonical(value) {
  if (Array.isArray(value)) return value.map(sortCanonical);
  if (!value || typeof value !== "object") return value;
  const out = {};
  for (const key of Object.keys(value).sort()) out[key] = sortCanonical(value[key]);
  return out;
}

export function atomicWriteJson(path, value, mode = 0o600) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode });
  chmodSync(tmp, mode);
  renameSync(tmp, path);
  chmodSync(path, mode);
}

export function readJsonIfExists(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}

export async function withDirLock(lockPath, fn) {
  const timeoutMs = Number(process.env.FM_LNDEV_LOCK_TIMEOUT_MS || 10_000);
  const staleMs = Number(process.env.FM_LNDEV_LOCK_STALE_MS || 60_000);
  const start = Date.now();
  while (true) {
    try {
      mkdirSync(lockPath, { mode: 0o700 });
      writeFileSync(join(lockPath, "owner"), `${process.pid}\n`, { mode: 0o600 });
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      try {
        const st = statSync(lockPath);
        if (Date.now() - st.mtimeMs > staleMs) {
          rmSync(lockPath, { recursive: true, force: true });
          continue;
        }
      } catch {
        continue;
      }
      if (Date.now() - start > timeoutMs) {
        throw new BrokerDenied("lock-timeout", `timed out waiting for ${lockPath}`);
      }
      await sleep(25);
    }
  }
  try {
    return await fn();
  } finally {
    rmSync(lockPath, { recursive: true, force: true });
  }
}

export function safeTaskId(taskId) {
  return typeof taskId === "string" && /^[A-Za-z0-9._-]+$/.test(taskId);
}

export function readTaskMeta(home, taskId) {
  if (!safeTaskId(taskId)) {
    throw new BrokerDenied("invalid-task-id", "task id must be a safe state-file stem");
  }
  const path = join(home, "state", `${taskId}.meta`);
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      throw new BrokerDenied("task-meta-missing", `state/${taskId}.meta does not exist`);
    }
    throw error;
  }
  const meta = {};
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const idx = line.indexOf("=");
    if (idx <= 0) throw new BrokerDenied("task-meta-malformed", `malformed meta line in ${path}`);
    const key = line.slice(0, idx);
    const value = line.slice(idx + 1);
    if (Object.hasOwn(meta, key)) {
      throw new BrokerDenied("task-meta-ambiguous", `duplicate meta key ${key}`);
    }
    meta[key] = value;
  }
  for (const key of ["kind", "project", "worktree"]) {
    if (!meta[key]) throw new BrokerDenied("task-meta-malformed", `missing meta key ${key}`);
  }
  if (!allowedTaskKind(meta.kind)) {
    throw new BrokerDenied("task-kind-denied", `task kind ${meta.kind} is not allowed`);
  }
  if (isSandboxPath(meta.worktree) || isSandboxPath(meta.project)) {
    throw new BrokerDenied("task-sandbox-path", "task meta resolves inside a sandbox path");
  }
  return meta;
}

export function allowedTaskKind(kind) {
  return new Set(["ship", "scout", "crew", "crewmate", "task"]).has(kind);
}

export function snapshotMeta(meta) {
  const keys = ["kind", "project", "worktree", "harness", "mode", "yolo"];
  const out = {};
  for (const key of keys) if (meta[key] !== undefined) out[key] = meta[key];
  return out;
}

export function assertMetaStillMatches(snapshot, meta) {
  for (const key of ["kind", "project", "worktree"]) {
    if (snapshot[key] !== meta[key]) {
      throw new BrokerDenied("task-meta-changed", `task meta ${key} changed since capability mint`);
    }
  }
}

export function assertNotSandboxCaller(caller) {
  const markers = Array.isArray(caller?.envMarkers) ? caller.envMarkers : [];
  if (markers.length > 0) {
    throw new BrokerDenied("sandbox-marker", `sandbox marker present: ${markers.join(", ")}`);
  }
  if (isSandboxPath(caller?.cwd || "")) {
    throw new BrokerDenied("sandbox-cwd", "caller cwd is under a Daytona/lndev sandbox path");
  }
}

export function isSandboxPath(value) {
  if (!value || typeof value !== "string") return false;
  const normalized = value.replace(/\\/g, "/");
  return (
    /(^|\/)(daytona|lndev|lindy)[^/]*(sandbox|sandboxes|workspace|workspaces|shells?)(\/|$)/i.test(
      normalized
    ) ||
    /(^|\/)(daytona|lndev|lindy)\/(sandbox|sandboxes|workspace|workspaces|shells?)(\/|$)/i.test(
      normalized
    ) ||
    /^\/(?:workspace|workspaces)(?:\/|$)/.test(normalized)
  );
}

export function normalizeOperation(op) {
  if (op === "attach") return "attach-existing";
  if (op === "shell_ls") return "shell-list";
  return op;
}

export function allowedOperation(op) {
  return new Set(["status", "shell-list", "attach-existing"]).has(op);
}

export function redactText(text) {
  const raw = String(text ?? "");
  const normalized = normalizeForSecretScan(raw);
  if (sourceHasSecretMaterial(normalized)) return redactPlainText(normalized);
  return redactPlainText(raw);
}

function redactPlainText(text) {
  const extra = extraSecretValues();
  let out = String(text ?? "");
  out = out.replace(/lcli_[A-Za-z0-9_-]+/g, "[REDACTED_LCLI]");
  out = out.replace(/Bearer\s+[A-Za-z0-9._:-]+/gi, "Bearer [REDACTED]");
  out = out.replace(/sshToken\s*[:=]\s*[^\s,;]+/gi, "sshToken=[REDACTED]");
  out = out.replace(/DAYTONA[_-]SSH[_-]TOKEN[_=:][^\s,;]+/gi, "DAYTONA_SSH_TOKEN=[REDACTED]");
  for (const secret of extra) {
    if (secret.length >= 4) out = out.split(secret).join("[REDACTED_SECRET]");
  }
  return out;
}

export class StreamingRedactor {
  constructor() {
    this.buffer = "";
    this.sawSecret = false;
  }

  push(text) {
    this.buffer += String(text ?? "");
    return this.drain(false);
  }

  finish() {
    return this.drain(true);
  }

  drain(final) {
    const mapped = normalizeWithRawMap(this.buffer);
    if (sourceHasSecretMaterial(mapped.normalized)) {
      this.sawSecret = true;
      throw new BrokerDenied("secret-output", "streaming output contained credential-shaped material");
    }
    const normalizedLimit = final ? mapped.normalized.length : safeNormalizedEmitLimit(mapped.normalized);
    const rawLimit = rawLimitForNormalizedLimit(mapped, normalizedLimit);
    if (rawLimit <= 0) return "";
    const raw = this.buffer.slice(0, rawLimit);
    this.buffer = this.buffer.slice(rawLimit);
    const redacted = redactText(raw);
    if (containsSecretMaterial(redacted)) {
      throw new BrokerDenied("secret-output", "streaming redaction left credential-shaped material");
    }
    return redacted;
  }
}

export function containsSecretMaterial(text) {
  return sourceHasSecretMaterial(normalizeForSecretScan(text));
}

function sourceHasSecretMaterial(source) {
  if (/lcli_[A-Za-z0-9_-]+/.test(source)) return true;
  if (/Bearer\s+[A-Za-z0-9._:-]+/i.test(source)) return true;
  if (/sshToken\s*[:=]\s*[^\s,;]+/i.test(source)) return true;
  if (/DAYTONA[_-]SSH[_-]TOKEN[_=:][^\s,;]+/i.test(source)) return true;
  return extraSecretValues().some((secret) => secret.length >= 4 && source.includes(secret));
}

function safeNormalizedEmitLimit(normalized) {
  let limit = normalized.length;
  if (limit === 0) return 0;
  for (const span of secretSpans(normalized)) {
    if (span.start < limit && span.end > limit) limit = span.start;
    if (span.incomplete && span.start < limit) limit = span.start;
  }
  const suffixHold = unsafeSuffixLength(normalized);
  if (suffixHold > 0) limit = Math.min(limit, normalized.length - suffixHold);
  return Math.max(0, limit);
}

function rawLimitForNormalizedLimit(mapped, normalizedLimit) {
  if (normalizedLimit <= 0) return 0;
  let rawLimit = mapped.raw.length;
  if (normalizedLimit < mapped.rawStarts.length) {
    for (let i = normalizedLimit; i < mapped.rawStarts.length; i += 1) {
      rawLimit = Math.min(rawLimit, mapped.rawStarts[i]);
    }
  }
  if (mapped.incompleteAnsiStart >= 0 && mapped.incompleteAnsiStart < rawLimit) {
    rawLimit = mapped.incompleteAnsiStart;
  }
  return rawLimit;
}

function secretSpans(buffer) {
  return [
    ...prefixTokenSpans(buffer, /lcli_/gi, /[A-Za-z0-9_-]/),
    ...prefixedValueSpans(buffer, /Bearer\s+/gi, /[A-Za-z0-9._:-]/),
    ...prefixedValueSpans(buffer, /sshToken\s*[:=]\s*/gi, /[^\s,;]/),
    ...prefixedValueSpans(buffer, /DAYTONA[_-]SSH[_-]TOKEN[_=:]/gi, /[^\s,;]/),
  ];
}

function prefixTokenSpans(buffer, prefixRe, valueRe) {
  const spans = [];
  for (const match of buffer.matchAll(prefixRe)) {
    const start = match.index;
    let end = start + match[0].length;
    while (end < buffer.length && valueRe.test(buffer[end])) {
      valueRe.lastIndex = 0;
      end += 1;
    }
    valueRe.lastIndex = 0;
    spans.push({ start, end, incomplete: end === buffer.length });
  }
  return spans;
}

function prefixedValueSpans(buffer, prefixRe, valueRe) {
  const spans = [];
  for (const match of buffer.matchAll(prefixRe)) {
    const start = match.index;
    let end = start + match[0].length;
    while (end < buffer.length && valueRe.test(buffer[end])) {
      valueRe.lastIndex = 0;
      end += 1;
    }
    valueRe.lastIndex = 0;
    spans.push({ start, end, incomplete: end === buffer.length });
  }
  return spans;
}

function extraSecretValues() {
  const file = process.env.FM_LNDEV_FAKE_SECRET_FILE;
  if (!file || !existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function unsafeSuffixLength(buffer) {
  const suffixes = secretPrefixCandidates();
  const lower = buffer.toLowerCase();
  let hold = 0;
  for (const candidate of suffixes) {
    const normalized = candidate.toLowerCase();
    const max = Math.min(normalized.length - 1, lower.length);
    for (let len = 1; len <= max; len += 1) {
      if (lower.endsWith(normalized.slice(0, len))) hold = Math.max(hold, len);
    }
  }
  return hold;
}

function secretPrefixCandidates() {
  return [
    "lcli_",
    "Bearer ",
    "sshToken=",
    "sshToken:",
    "DAYTONA_SSH_TOKEN=",
    "DAYTONA_SSH_TOKEN:",
    "DAYTONA_SSH_TOKEN_",
    "DAYTONA-SSH-TOKEN=",
    "DAYTONA-SSH-TOKEN:",
    "DAYTONA-SSH-TOKEN-",
    ...extraSecretValues(),
  ].filter((value) => value.length > 1);
}

export function normalizeOutput(text) {
  return normalizeForSecretScan(text).replace(/\n+$/g, "");
}

function normalizeForSecretScan(text) {
  return normalizeWithRawMap(String(text || "")).normalized;
}

function normalizeWithRawMap(raw) {
  const chars = [];
  const rawStarts = [];
  let incompleteAnsiStart = -1;
  let cursor = 0;
  const writeChar = (ch, rawIndex) => {
    if (cursor < chars.length) {
      chars[cursor] = ch;
      rawStarts[cursor] = rawIndex;
    } else {
      chars.push(ch);
      rawStarts.push(rawIndex);
    }
    cursor += 1;
  };
  const lineStart = () => {
    for (let i = Math.min(cursor, chars.length) - 1; i >= 0; i -= 1) {
      if (chars[i] === "\n") return i + 1;
    }
    return 0;
  };
  const lineEnd = () => {
    for (let i = cursor; i < chars.length; i += 1) {
      if (chars[i] === "\n") return i;
    }
    return chars.length;
  };
  const moveCursor = (delta) => {
    cursor = Math.max(lineStart(), Math.min(lineEnd(), cursor + delta));
  };
  const applyControl = (control) => {
    if (control.kind !== "csi") return;
    const firstParam = Number.parseInt(control.params.split(/[;:]/)[0] || "1", 10);
    const amount = Number.isFinite(firstParam) && firstParam > 0 ? firstParam : 1;
    if (control.final === "D") moveCursor(-amount);
    else if (control.final === "C") moveCursor(amount);
    else if (control.final === "G") cursor = Math.min(lineEnd(), lineStart() + amount - 1);
    else if (control.final === "K") {
      const mode = control.params === "" ? 0 : firstParam;
      const start = lineStart();
      const end = lineEnd();
      if (mode === 0) {
        chars.splice(cursor, end - cursor);
        rawStarts.splice(cursor, end - cursor);
      } else if (mode === 1) {
        chars.splice(start, cursor - start);
        rawStarts.splice(start, cursor - start);
        cursor = start;
      } else if (mode === 2) {
        chars.splice(start, end - start);
        rawStarts.splice(start, end - start);
        cursor = start;
      }
    }
  };
  for (let i = 0; i < raw.length; ) {
    const control = scanTerminalControl(raw, i);
    if (control) {
      if (!control.complete) incompleteAnsiStart = i;
      else applyControl(control);
      i = control.end;
      continue;
    }
    const ch = raw[i];
    if (ch === "\r" && raw[i + 1] === "\n") {
      writeChar("\n", i);
      cursor = chars.length;
      i += 2;
      continue;
    }
    if (ch === "\r") {
      cursor = lineStart();
      i += 1;
      continue;
    }
    if (ch === "\b") {
      moveCursor(-1);
      i += 1;
      continue;
    }
    if (ch === "\u0004") {
      i += 1;
      continue;
    }
    if (ch === "\n") {
      writeChar("\n", i);
      cursor = chars.length;
      i += 1;
      continue;
    }
    if (ch < " " && ch !== "\t") {
      i += 1;
      continue;
    }
    writeChar(ch, i);
    i += 1;
  }
  const normalized = chars.join("");
  return { raw, normalized, rawStarts, incompleteAnsiStart };
}

function scanTerminalControl(raw, index) {
  const code = raw.charCodeAt(index);
  if (code === 0x9b) return scanCsi(raw, index + 1);
  if (code === 0x9d) return scanStringControl(raw, index, index + 1, true);
  if (code === 0x90 || code === 0x98 || code === 0x9e || code === 0x9f) {
    return scanStringControl(raw, index, index + 1, false);
  }
  if (code === 0x8e || code === 0x8f) {
    return { kind: code === 0x8e ? "ss2" : "ss3", complete: index + 1 < raw.length, end: Math.min(raw.length, index + 2) };
  }
  if (code !== 0x1b) return null;
  const next = raw[index + 1];
  if (next === undefined) return { kind: "escape", complete: false, end: raw.length };
  if (next === "[") return scanCsi(raw, index + 2);
  if (next === "]") return scanStringControl(raw, index, index + 2, true);
  if (next === "P" || next === "X" || next === "^" || next === "_") {
    return scanStringControl(raw, index, index + 2, false);
  }
  if (next === "N" || next === "O") {
    return { kind: next === "N" ? "ss2" : "ss3", complete: index + 2 < raw.length, end: Math.min(raw.length, index + 3) };
  }
  return { kind: "escape", complete: true, end: index + 2 };
}

function scanCsi(raw, bodyStart) {
  for (let i = bodyStart; i < raw.length; i += 1) {
    const code = raw.charCodeAt(i);
    if (code >= 0x40 && code <= 0x7e) {
      return { kind: "csi", complete: true, end: i + 1, final: raw[i], params: raw.slice(bodyStart, i) };
    }
  }
  return { kind: "csi", complete: false, end: raw.length };
}

function scanStringControl(raw, start, bodyStart, allowBel) {
  for (let i = bodyStart; i < raw.length; i += 1) {
    if (allowBel && raw.charCodeAt(i) === 0x07) return { kind: "string", complete: true, end: i + 1 };
    if (raw.charCodeAt(i) === 0x9c) return { kind: "string", complete: true, end: i + 1 };
    if (raw.charCodeAt(i) === 0x1b && raw[i + 1] === "\\") {
      return { kind: "string", complete: true, end: i + 2 };
    }
  }
  return { kind: "string", complete: false, end: raw.length };
}

export function conciseError(error) {
  if (error instanceof BrokerDenied) return `${error.reason}: ${error.message}`;
  return error?.message || String(error);
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}
