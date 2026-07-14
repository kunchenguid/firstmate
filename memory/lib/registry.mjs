import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { appendActivity } from './activity.mjs';
import { contentHash, sha256, stableJson } from './hash.mjs';
import { registryPaths } from './paths.mjs';
import { REGISTRY_SCHEMA, validateRegistryEvent } from './schema.mjs';
import { withRegistryLock } from './lock.mjs';

const terminalStatuses = new Set(['superseded', 'retired', 'rejected']);

export function emptyFold(paths = registryPaths()) {
  return {
    health: 'ok',
    records: new Map(),
    events: [],
    duplicates: [],
    corrupt: null,
    watermark: { seq: 0, eventId: null, registryHash: sha256('') },
    paths
  };
}

function splitRows(buffer) {
  const text = buffer.toString('utf8');
  if (text.length === 0) return { complete: [], trailing: Buffer.alloc(0), text };
  const parts = text.split('\n');
  const complete = parts.slice(0, -1).map((line) => `${line}\n`);
  const last = parts.at(-1);
  const trailing = last ? Buffer.from(last, 'utf8') : Buffer.alloc(0);
  return { complete, trailing, text };
}

function defaultRecord(memId, event) {
  return {
    id: memId,
    summary: '',
    body: '',
    source: null,
    scope: 'fleet',
    projects: ['*'],
    taskKinds: ['*'],
    keywords: [],
    aliases: [],
    entities: [],
    commands: [],
    failureModes: [],
    relatedTerms: [],
    status: 'candidate',
    validFrom: event.ts.slice(0, 10),
    validTo: null,
    recordedAt: event.ts,
    verifiedAt: null,
    confidence: 'unverified',
    supersedes: [],
    supersededBy: null,
    contradicts: [],
    evidence: [],
    guard: null,
    riskClass: event.fields?.riskClass || 'standard',
    eventIds: []
  };
}

function applyFields(record, fields = {}) {
  for (const [key, value] of Object.entries(fields)) {
    if (value !== undefined) record[key] = value;
  }
}

function applyEvent(records, event) {
  let record = records.get(event.memId);
  if (event.event === 'proposed') {
    if (record) throw new Error(`record already exists: ${event.memId}`);
    record = defaultRecord(event.memId, event);
    applyFields(record, event.fields || {});
    record.status = 'candidate';
    record.evidence = [...(event.evidence || [])];
    record.eventIds.push(event.eventId);
    records.set(event.memId, record);
    return;
  }
  if (!record) throw new Error(`unknown memory record: ${event.memId}`);
  if (terminalStatuses.has(record.status) && !['updated', 'revalidated'].includes(event.event)) {
    throw new Error(`invalid transition from ${record.status} via ${event.event}`);
  }
  if (event.event === 'activated') {
    if ((event.evidence || []).length === 0 || !event.validation?.method) {
      throw new Error(`activation requires evidence and validation: ${event.memId}`);
    }
    record.status = 'active';
    record.verifiedAt = event.ts;
    record.confidence = event.fields?.confidence || record.confidence || 'observed';
    record.evidence = mergeEvidence(record.evidence, event.evidence);
  } else if (event.event === 'updated') {
    applyFields(record, event.fields || {});
    record.evidence = mergeEvidence(record.evidence, event.evidence || []);
  } else if (event.event === 'superseded') {
    record.status = 'superseded';
    record.validTo = event.ts;
    record.supersededBy = event.successor || null;
  } else if (event.event === 'retired') {
    record.status = 'retired';
    record.validTo = event.ts;
  } else if (event.event === 'quarantined') {
    record.status = 'quarantined';
  } else if (event.event === 'revalidated') {
    if ((event.evidence || []).length === 0 || !event.validation?.method) {
      throw new Error(`revalidation requires evidence and validation: ${event.memId}`);
    }
    record.verifiedAt = event.ts;
    record.evidence = mergeEvidence(record.evidence, event.evidence);
  } else if (event.event === 'rejected') {
    record.status = 'rejected';
    record.validTo = event.ts;
  }
  applyFields(record, event.fields || {});
  if (event.supersedes?.length) record.supersedes = [...new Set([...(record.supersedes || []), ...event.supersedes])];
  record.eventIds.push(event.eventId);
}

function mergeEvidence(existing = [], incoming = []) {
  const seen = new Set(existing.map((item) => stableJson(item)));
  const out = [...existing];
  for (const item of incoming) {
    const key = stableJson(item);
    if (!seen.has(key)) out.push(item);
  }
  return out;
}

export function foldRegistry(dirOrPaths = registryPaths()) {
  const paths = typeof dirOrPaths === 'string' ? registryPaths(dirOrPaths) : dirOrPaths;
  if (!fs.existsSync(paths.registry)) return emptyFold(paths);
  const buffer = fs.readFileSync(paths.registry);
  const { complete, trailing } = splitRows(buffer);
  const fold = emptyFold(paths);
  const seen = new Set();
  let consumed = '';

  for (let i = 0; i < complete.length; i += 1) {
    const line = complete[i];
    if (line.trim() === '') {
      consumed += line;
      continue;
    }
    let parsed;
    try {
      parsed = JSON.parse(line);
      parsed = validateRegistryEvent(parsed);
      if (seen.has(parsed.eventId)) {
        fold.duplicates.push({ eventId: parsed.eventId, line: i + 1 });
        consumed += line;
        continue;
      }
      applyEvent(fold.records, parsed);
      fold.events.push(parsed);
      seen.add(parsed.eventId);
      consumed += line;
    } catch (error) {
      fold.health = 'critical';
      fold.corrupt = { line: i + 1, reason: error.message, bytes: Buffer.concat([Buffer.from(line), ...complete.slice(i + 1).map((row) => Buffer.from(row)), trailing]) };
      break;
    }
  }
  if (fold.health !== 'critical' && trailing.length > 0) {
    fold.health = 'critical';
    fold.corrupt = { line: complete.length + 1, reason: 'unterminated trailing registry row', bytes: trailing };
  }
  const last = fold.events.at(-1);
  fold.watermark = { seq: fold.events.length, eventId: last?.eventId || null, registryHash: sha256(consumed) };
  return fold;
}

function nextMemId(fold) {
  let max = 0;
  for (const id of fold.records.keys()) {
    max = Math.max(max, Number(id.replace(/^MEM-/, '')));
  }
  return `MEM-${String(max + 1).padStart(4, '0')}`;
}

function fsyncDir(dir) {
  const fd = fs.openSync(dir, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function appendLine(file, line, injectMismatch = false) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o755 });
  const fd = fs.openSync(file, 'a', 0o600);
  try {
    fs.writeFileSync(fd, line);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  const readBack = fs.readFileSync(file, 'utf8');
  if (injectMismatch || !readBack.endsWith(line)) {
    throw new Error('registry append read-back validation failed');
  }
  fsyncDir(path.dirname(file));
}

// Ported from fleet-bridge lib/task-records.js appendTaskEvent discipline:
// serialize under a cross-process lock, validate before append, fsync, idempotently skip duplicate event IDs, and read back.
export async function appendRegistryEvent(dir, partial, options = {}) {
  const paths = registryPaths(dir);
  return withRegistryLock(paths.lock, async () => {
    const fold = foldRegistry(paths);
    if (fold.health === 'critical') throw new Error(`registry is CRITICAL: run mem recover before mutating (${fold.corrupt?.reason})`);
    const memId = partial.memId || nextMemId(fold);
    const event = validateRegistryEvent({
      schema: REGISTRY_SCHEMA,
      eventId: partial.eventId || crypto.randomUUID(),
      ts: partial.ts || new Date().toISOString(),
      actor: { kind: 'firstmate', id: 'mem-cli' },
      evidence: [],
      memId,
      ...partial
    });
    if (fold.events.some((row) => row.eventId === event.eventId)) {
      return { event, skipped: true, fold };
    }
    const testFold = emptyFold(paths);
    for (const row of fold.events) applyEvent(testFold.records, row);
    applyEvent(testFold.records, event);
    const line = `${JSON.stringify(event)}\n`;
    appendLine(paths.registry, line, options.injectReadBackMismatch || process.env.MEM_INJECT_READBACK_MISMATCH === '1');
    return { event, skipped: false, fold: foldRegistry(paths) };
  }, options.lock);
}

export function activeRecords(fold) {
  return [...fold.records.values()].filter((record) => record.status === 'active').map((record) => ({
    ...record,
    contentHash: contentHash({
      id: record.id,
      summary: record.summary,
      body: record.body,
      scope: record.scope,
      projects: record.projects,
      taskKinds: record.taskKinds,
      keywords: record.keywords,
      aliases: record.aliases,
      entities: record.entities,
      commands: record.commands,
      failureModes: record.failureModes,
      relatedTerms: record.relatedTerms,
      confidence: record.confidence,
      guard: record.guard,
      riskClass: record.riskClass
    })
  }));
}

export function buildActiveIndex(dir) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  if (fold.health === 'critical') throw new Error(`registry is CRITICAL: ${fold.corrupt?.reason}`);
  const index = {
    schema: 'kraken-memory/active-index/v1',
    generatedAt: new Date().toISOString(),
    registry: fold.watermark,
    recordCount: activeRecords(fold).length,
    records: activeRecords(fold)
  };
  fs.mkdirSync(paths.dir, { recursive: true, mode: 0o755 });
  const tmp = `${paths.index}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(index, null, 2)}\n`, { mode: 0o600 });
  const fd = fs.openSync(tmp, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, paths.index);
  fsyncDir(paths.dir);
  return index;
}

export function auditRegistry(dir) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  let index = null;
  let indexStatus = 'missing';
  if (fs.existsSync(paths.index)) {
    try {
      index = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
      indexStatus = index.registry?.eventId === fold.watermark.eventId && index.registry?.seq === fold.watermark.seq ? 'current' : 'stale';
    } catch {
      indexStatus = 'invalid';
    }
  }
  const statusCounts = {};
  for (const record of fold.records.values()) statusCounts[record.status] = (statusCounts[record.status] || 0) + 1;
  return {
    ok: fold.health !== 'critical' && indexStatus !== 'invalid',
    registry: { path: paths.registry, health: fold.health, watermark: fold.watermark, corrupt: fold.corrupt ? { line: fold.corrupt.line, reason: fold.corrupt.reason, bytes: fold.corrupt.bytes.length } : null },
    records: { total: fold.records.size, active: activeRecords(fold).length, statusCounts },
    duplicates: fold.duplicates,
    activeIndex: { path: paths.index, status: indexStatus, watermark: index?.registry || null }
  };
}

export function snapshotRegistry(dir) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  if (fold.health === 'critical') throw new Error(`registry is CRITICAL: ${fold.corrupt?.reason}`);
  fs.mkdirSync(paths.snapshots, { recursive: true, mode: 0o755 });
  const safe = `${fold.watermark.seq}-${fold.watermark.eventId || 'empty'}`;
  const file = path.join(paths.snapshots, `registry-${safe}.json`);
  const payload = { schema: 'kraken-memory/registry-snapshot/v1', createdAt: new Date().toISOString(), registry: fold.watermark, records: [...fold.records.values()] };
  fs.writeFileSync(file, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  return { file, snapshot: payload };
}

export async function recoverRegistry(dir, options = {}) {
  const paths = registryPaths(dir);
  return withRegistryLock(paths.lock, async () => {
    const before = fs.existsSync(paths.registry) ? fs.readFileSync(paths.registry) : Buffer.alloc(0);
    const originalHash = sha256(before);
    const fold = foldRegistry(paths);
    if (fold.health !== 'critical') throw new Error('registry is not CRITICAL; recovery refused');
    fs.mkdirSync(paths.recovery, { recursive: true, mode: 0o700 });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backup = path.join(paths.recovery, `memory-registry.${stamp}.backup.jsonl`);
    const sidecar = path.join(paths.recovery, `memory-registry.${stamp}.corrupt-bytes`);
    fs.writeFileSync(backup, before, { mode: 0o600 });
    fs.writeFileSync(sidecar, fold.corrupt.bytes, { mode: 0o600 });
    const repairedRows = fold.events.map((event) => `${JSON.stringify(event)}\n`).join('');
    const repairedHash = sha256(repairedRows);
    const tmp = path.join(paths.recovery, `memory-registry.${stamp}.repaired.jsonl`);
    fs.writeFileSync(tmp, repairedRows, { mode: 0o600 });
    const repairedFold = foldRegistry({ ...paths, registry: tmp });
    if (repairedFold.health === 'critical') throw new Error(`repaired registry failed validation: ${repairedFold.corrupt?.reason}`);
    const replaceTmp = `${paths.registry}.recover-${process.pid}`;
    fs.copyFileSync(tmp, replaceTmp);
    fs.renameSync(replaceTmp, paths.registry);
    fsyncDir(paths.dir);
    const index = buildActiveIndex(dir);
    const finalAudit = auditRegistry(dir);
    const event = appendActivity(dir, {
      event: 'registry_recovered',
      detail: {
        originalHash,
        sidecarHash: sha256(fold.corrupt.bytes),
        repairedHash,
        backup,
        sidecar,
        lastValidPreRecoveryWatermark: fold.watermark,
        postRecoveryWatermark: repairedFold.watermark,
        activeIndexWatermark: index.registry,
        finalAuditOk: finalAudit.ok
      }
    });
    return { backup, sidecar, originalHash, sidecarHash: sha256(fold.corrupt.bytes), repairedHash, lastValidPreRecoveryWatermark: fold.watermark, postRecoveryWatermark: repairedFold.watermark, audit: finalAudit, recoveryEvent: event };
  }, options.lock);
}
