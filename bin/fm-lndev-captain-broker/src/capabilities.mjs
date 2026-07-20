import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  BrokerDenied,
  atomicWriteJson,
  capabilityStorePath,
  nowMs,
  randomHandle,
  randomId,
  readJsonIfExists,
  sha256,
  snapshotMeta,
  withDirLock,
} from "./common.mjs";

const STORE_VERSION = 1;

export async function mintCapability(home, opts) {
  const handle = randomHandle();
  const id = randomId("lcap");
  const expiresAt = opts.expiresAt || new Date(nowMs() + opts.ttlSeconds * 1000).toISOString();
  const record = {
    id,
    handleHash: hashHandle(handle),
    createdAt: new Date(nowMs()).toISOString(),
    expiresAt,
    taskId: opts.taskId,
    operation: opts.operation,
    sessionId: opts.sessionId || null,
    approvalId: opts.approvalId || null,
    transcriptPolicy: opts.transcriptPolicy || "redacted-pty-jsonl",
    taskMeta: snapshotMeta(opts.taskMeta),
    createdBy: "firstmate",
  };
  await withCapabilityStore(home, (store) => {
    store.records[id] = record;
    return store;
  });
  if (opts.outPath) writeHandleFile(opts.outPath, handle);
  return { record, handle };
}

export async function validateCapability(home, request, taskMeta) {
  const handle = request.handle || "";
  if (!handle) throw new BrokerDenied("missing-handle", "capability handle is required");
  const hashed = hashHandle(handle);
  const store = readCapabilityStore(home);
  const matches = Object.values(store.records).filter((record) => record.handleHash === hashed);
  if (matches.length !== 1) {
    throw new BrokerDenied("invalid-handle", "capability handle was not found");
  }
  const cap = matches[0];
  if (Date.parse(cap.expiresAt) <= nowMs()) {
    throw new BrokerDenied("expired-handle", "capability handle is expired", { capabilityId: cap.id });
  }
  if (cap.taskId !== request.taskId) {
    throw new BrokerDenied("capability-task-mismatch", "capability task id did not match request", {
      capabilityId: cap.id,
    });
  }
  if (cap.operation !== request.operation) {
    throw new BrokerDenied("capability-operation-mismatch", "capability operation did not match request", {
      capabilityId: cap.id,
    });
  }
  if (cap.taskMeta.kind !== taskMeta.kind || cap.taskMeta.project !== taskMeta.project || cap.taskMeta.worktree !== taskMeta.worktree) {
    throw new BrokerDenied("task-meta-changed", "task metadata changed since capability mint", {
      capabilityId: cap.id,
    });
  }
  if (cap.operation === "attach-existing") {
    const sessionId = request.args?.sessionId;
    if (!sessionId || cap.sessionId !== sessionId) {
      throw new BrokerDenied("capability-session-mismatch", "capability session id did not match request", {
        capabilityId: cap.id,
      });
    }
  }
  if (cap.operation !== "attach-existing" && request.args?.sessionId) {
    throw new BrokerDenied("capability-args-mismatch", "read-only capability must not include a session id", {
      capabilityId: cap.id,
    });
  }
  return cap;
}

export function hashHandle(handle) {
  return sha256(handle);
}

function readCapabilityStore(home) {
  const fallback = { version: STORE_VERSION, records: {} };
  const parsed = readJsonIfExists(capabilityStorePath(home), fallback);
  if (parsed.version !== STORE_VERSION || !parsed.records || typeof parsed.records !== "object") {
    throw new BrokerDenied("capability-store-corrupt", "capability store schema was invalid");
  }
  return parsed;
}

async function withCapabilityStore(home, update) {
  const path = capabilityStorePath(home);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  await withDirLock(join(dirname(path), ".lock"), async () => {
    const current = readCapabilityStore(home);
    const next = update(current);
    atomicWriteJson(path, next, 0o600);
  });
}

function writeHandleFile(path, handle) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, `${handle}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}
