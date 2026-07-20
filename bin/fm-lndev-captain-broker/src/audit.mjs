import { createHmac, randomBytes } from "node:crypto";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

import {
  BROKER_VERSION,
  auditDir,
  canonicalJson,
  randomId,
  redactText,
  sha256,
  withDirLock,
} from "./common.mjs";

const ZERO_HASH = "0".repeat(64);

export async function appendAudit(home, entry) {
  const dir = auditDir(home);
  const key = loadAuditKey(home);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return await withDirLock(join(dir, ".lock"), async () => {
    const head = readHead(dir);
    const timestamp = new Date().toISOString();
    const date = timestamp.slice(0, 10);
    const seq = head.seq + 1;
    const base = redactObject({
      event_id: randomId("lndaudit"),
      timestamp,
      seq,
      prev_hash: head.hash || ZERO_HASH,
      broker_version: BROKER_VERSION,
      audit_hash_alg: "hmac-sha256",
      audit_key_id: key.id,
      ...entry,
    });
    const recordHash = hmacSha256(key.bytes, `${base.prev_hash}${canonicalJson(base)}`);
    const record = { ...base, record_hash: recordHash };
    const daily = join(dir, `${date}.jsonl`);
    appendFileSync(daily, `${JSON.stringify(record)}\n`, { mode: 0o600 });
    chmodSync(daily, 0o600);
    const nextHead = {
      version: 1,
      seq,
      hash: recordHash,
      hash_alg: "hmac-sha256",
      key_id: key.id,
      updated_at: timestamp,
      file: daily,
    };
    writeHead(dir, nextHead);
    return record;
  });
}

export function verifyAudit(home) {
  const dir = auditDir(home);
  if (!existsSync(dir)) return { ok: true, records: 0, head: null };
  const key = loadAuditKey(home);
  const files = readdirSync(dir)
    .filter((name) => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name))
    .sort();
  let prev = ZERO_HASH;
  let seq = 0;
  let records = 0;
  for (const file of files) {
    const full = join(dir, file);
    const lines = readFileSync(full, "utf8")
      .split(/\r?\n/)
      .filter(Boolean);
    for (const line of lines) {
      const record = JSON.parse(line);
      records += 1;
      seq += 1;
      if (record.seq !== seq) {
        return { ok: false, reason: `seq mismatch at ${file}:${records}` };
      }
      if (record.prev_hash !== prev) {
        return { ok: false, reason: `prev_hash mismatch at ${file}:${records}` };
      }
      if (record.audit_hash_alg !== "hmac-sha256" || record.audit_key_id !== key.id) {
        return { ok: false, reason: `audit key metadata mismatch at ${file}:${records}` };
      }
      const { record_hash: _recordHash, ...withoutHash } = record;
      const computed = hmacSha256(key.bytes, `${prev}${canonicalJson(withoutHash)}`);
      if (computed !== record.record_hash) {
        return { ok: false, reason: `record_hash mismatch at ${file}:${records}` };
      }
      prev = record.record_hash;
    }
  }
  const head = readHead(dir);
  if (head.seq !== seq || (head.hash || ZERO_HASH) !== prev) {
    return { ok: false, reason: "head.json does not match chain tail" };
  }
  if (head.hash_alg !== "hmac-sha256" || head.key_id !== key.id) {
    return { ok: false, reason: "head.json audit key metadata mismatch" };
  }
  return { ok: true, records, head };
}

function readHead(dir) {
  const path = join(dir, "head.json");
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (parsed.version !== 1 || typeof parsed.seq !== "number" || typeof parsed.hash !== "string") {
      throw new Error("invalid head schema");
    }
    return parsed;
  } catch (error) {
    if (error.code === "ENOENT") return { version: 1, seq: 0, hash: ZERO_HASH };
    throw error;
  }
}

function writeHead(dir, head) {
  const path = join(dir, "head.json");
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(head, null, 2)}\n`, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
  chmodSync(path, 0o600);
}

function loadAuditKey(home) {
  const path = auditKeyPath(home);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  if (!existsSync(path)) {
    writeFileSync(path, `${randomBytes(32).toString("hex")}\n`, { mode: 0o600 });
    chmodSync(path, 0o600);
  }
  const raw = readFileSync(path, "utf8").trim();
  if (!/^[A-Fa-f0-9]{64,}$/.test(raw)) {
    throw new Error(`audit HMAC key ${path} must be at least 32 bytes of hex`);
  }
  const bytes = Buffer.from(raw, "hex");
  return { path, bytes, id: sha256(bytes.toString("hex")).slice(0, 16) };
}

function auditKeyPath(home) {
  const path = resolve(
    process.env.FM_LNDEV_AUDIT_KEY_FILE ||
      join(homedir(), ".firstmate", "lndev-captain-audit.hmac-key")
  );
  const rel = relative(resolve(home), path);
  if (rel === "" || (!rel.startsWith("..") && !isAbsolute(rel))) {
    throw new Error(`audit HMAC key must be outside FM_HOME: ${path}`);
  }
  return path;
}

function hmacSha256(key, value) {
  return createHmac("sha256", key).update(value).digest("hex");
}

function redactObject(value) {
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map(redactObject);
  if (!value || typeof value !== "object") return value;
  const out = {};
  for (const [key, entry] of Object.entries(value)) {
    out[key] = sensitiveKey(key) ? "[REDACTED]" : redactObject(entry);
  }
  return out;
}

function sensitiveKey(key) {
  return /raw.*token|token.*value|secret|authorization|bearer|password|credential_value|handle/i.test(
    key
  );
}
