import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { appendActivity } from './activity.mjs';
import { contentHash, sha256, stableJson } from './hash.mjs';
import { registryPaths } from './paths.mjs';
import { ACTIVE_INDEX_SCHEMA, REGISTRY_SCHEMA, validateRegistryEvent } from './schema.mjs';
import { withRegistryLock } from './lock.mjs';

// Explicit status transition table. Every legal (event -> allowed source status)
// edge is listed here; anything not listed is an illegal transition and is
// refused without altering canonical state. Terminal states (superseded,
// retired, rejected) appear in no source list, so they are truly terminal and
// cannot be revived through ordinary activation.
const TRANSITIONS = {
  activated: ['candidate'],
  updated: ['candidate', 'active', 'quarantined'],
  superseded: ['candidate', 'active'],
  retired: ['candidate', 'active', 'quarantined'],
  quarantined: ['candidate', 'active'],
  revalidated: ['quarantined'],
  rejected: ['candidate', 'quarantined']
};

// A memory is high-impact (independent activation required) when its governance
// footprint is large: critical risk, guard-linked, or a high-impact task kind.
const HIGH_IMPACT_KINDS = new Set(['dispatch', 'landing', 'qa', 'governance']);

function isHighImpact(record) {
  if (record.riskClass === 'critical') return true;
  if (record.guardLinked) return true;
  return (record.taskKinds || []).some((kind) => HIGH_IMPACT_KINDS.has(kind));
}

export function emptyFold(paths = registryPaths()) {
  return {
    health: 'ok',
    records: new Map(),
    events: [],
    duplicates: [],
    corrupt: null,
    watermark: { seq: 0, eventId: null, registryHash: sha256(Buffer.alloc(0)) },
    validPrefixBytes: Buffer.alloc(0),
    paths
  };
}

// Byte-oriented row split. Rows are delimited by the newline byte (0x0a); each
// complete row keeps its exact byte range and the trailing partial (if any) is
// preserved as raw bytes. Never decode the whole buffer as UTF-8 first: doing so
// destroys invalid-UTF-8 / NUL corruption we are required to preserve verbatim.
function splitRowsBytes(buffer) {
  const rows = [];
  let start = 0;
  for (let i = 0; i < buffer.length; i += 1) {
    if (buffer[i] === 0x0a) {
      rows.push({ bytes: buffer.subarray(start, i + 1), start, end: i + 1 });
      start = i + 1;
    }
  }
  return { rows, trailing: buffer.subarray(start), trailingStart: start };
}

function defaultRecord(memId, event) {
  return {
    id: memId,
    summary: '',
    body: '',
    source: null,
    memoryType: 'factual',
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
    guardLinked: false,
    riskClass: event.fields?.riskClass || 'standard',
    proposedBy: null,
    activatedBy: null,
    lastEventSeq: 0,
    eventIds: []
  };
}

// Sparse field application: only keys explicitly present (and not undefined) are
// written. This is what makes `mem update` non-destructive - omitted fields are
// never reset to a default.
function applyFields(record, fields = {}) {
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) continue;
    if (key === 'guard_linked') {
      record.guardLinked = Boolean(value);
      continue;
    }
    record[key] = value;
  }
}

function assertTransition(record, event) {
  const allowed = TRANSITIONS[event.event];
  if (!allowed || !allowed.includes(record.status)) {
    throw new Error(`illegal transition: ${record.status} --${event.event}--> for ${event.memId}`);
  }
}

function applyEvent(records, event) {
  let record = records.get(event.memId);
  if (event.event === 'proposed') {
    if (record) throw new Error(`record already exists: ${event.memId}`);
    record = defaultRecord(event.memId, event);
    applyFields(record, event.fields || {});
    record.status = 'candidate';
    record.proposedBy = { kind: event.actor?.kind, id: event.actor?.id ?? null };
    if (event.guard_linked !== undefined) record.guardLinked = Boolean(event.guard_linked);
    record.evidence = mergeEvidence(record.evidence, event.evidence || []);
    record.eventIds.push(event.eventId);
    records.set(event.memId, record);
    return;
  }
  if (!record) throw new Error(`unknown memory record: ${event.memId}`);
  assertTransition(record, event);

  if (event.event === 'activated' || event.event === 'revalidated') {
    if ((event.evidence || []).length === 0 || !event.validation?.method) {
      throw new Error(`${event.event} requires evidence and validation: ${event.memId}`);
    }
    if (event.event === 'activated' && isHighImpact(record)) {
      const captainAuthority = event.actor?.kind === 'captain';
      const proposer = record.proposedBy?.id ?? null;
      const activator = event.actor?.id ?? null;
      if (!captainAuthority && proposer !== null && activator !== null && proposer === activator) {
        throw new Error(`high-impact activation requires an independent activator or captain authority: ${event.memId}`);
      }
    }
    record.status = 'active';
    record.verifiedAt = event.ts;
    record.confidence = event.fields?.confidence || record.confidence || 'observed';
    record.activatedBy = { kind: event.actor?.kind, id: event.actor?.id ?? null };
    record.evidence = mergeEvidence(record.evidence, event.evidence);
  } else if (event.event === 'updated') {
    record.evidence = mergeEvidence(record.evidence, event.evidence || []);
  } else if (event.event === 'superseded') {
    const successorId = event.successor;
    const successor = records.get(successorId);
    if (!successor) throw new Error(`supersession successor not found: ${successorId} for ${event.memId}`);
    if (successor.status !== 'active') throw new Error(`supersession successor must be active: ${successorId}`);
    // Update both sides of the lineage atomically within this one fold event.
    record.status = 'superseded';
    record.validTo = event.ts;
    record.supersededBy = successorId;
    successor.supersedes = [...new Set([...(successor.supersedes || []), event.memId])];
  } else if (event.event === 'retired') {
    record.status = 'retired';
    record.validTo = event.ts;
  } else if (event.event === 'quarantined') {
    record.status = 'quarantined';
  } else if (event.event === 'rejected') {
    record.status = 'rejected';
    record.validTo = event.ts;
  }

  if (event.guard_linked !== undefined) record.guardLinked = Boolean(event.guard_linked);
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
  const { rows, trailing, trailingStart } = splitRowsBytes(buffer);
  const fold = emptyFold(paths);
  const seen = new Set();
  let validPrefixEnd = 0;
  let corruptOffset = null;

  for (let i = 0; i < rows.length; i += 1) {
    const row = rows[i];
    const line = row.bytes.toString('utf8');
    if (line.trim() === '') {
      validPrefixEnd = row.end;
      continue;
    }
    try {
      const parsed = validateRegistryEvent(JSON.parse(line));
      if (seen.has(parsed.eventId)) {
        fold.duplicates.push({ eventId: parsed.eventId, line: i + 1 });
        validPrefixEnd = row.end;
        continue;
      }
      applyEvent(fold.records, parsed);
      fold.events.push(parsed);
      const rec = fold.records.get(parsed.memId);
      if (rec) rec.lastEventSeq = fold.events.length;
      seen.add(parsed.eventId);
      validPrefixEnd = row.end;
    } catch (error) {
      fold.health = 'critical';
      corruptOffset = row.start;
      fold.corrupt = { line: i + 1, reason: error.message, byteOffset: row.start, bytes: buffer.subarray(row.start) };
      break;
    }
  }
  if (fold.health !== 'critical' && trailing.length > 0) {
    fold.health = 'critical';
    corruptOffset = trailingStart;
    fold.corrupt = { line: rows.length + 1, reason: 'unterminated trailing registry row', byteOffset: trailingStart, bytes: buffer.subarray(trailingStart) };
  }

  const prefixEnd = fold.health === 'critical' ? corruptOffset : validPrefixEnd;
  const validPrefix = buffer.subarray(0, prefixEnd);
  const last = fold.events.at(-1);
  fold.watermark = { seq: fold.events.length, eventId: last?.eventId || null, registryHash: sha256(validPrefix) };
  fold.validPrefixBytes = validPrefix;
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

function fsyncFile(file) {
  const fd = fs.openSync(file, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

// Durable write: temp file in the destination directory, fsync the file, atomic
// rename, then fsync the containing directory so the rename itself is durable.
function atomicWrite(file, data, mode = 0o600) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
  const tmp = path.join(dir, `.${path.basename(file)}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
  const fd = fs.openSync(tmp, 'w', mode);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
  fsyncDir(dir);
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
// serialize under a cross-process lock, validate before append, fsync, idempotently
// skip duplicate event IDs, and read back. The active-index projection is refreshed
// under the SAME mutation lock so a slower writer can never install an older index.
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
    // Dry-run the full transition against a fresh fold to reject illegal state
    // changes BEFORE any bytes touch the canonical file.
    const testFold = emptyFold(paths);
    for (const row of fold.events) applyEvent(testFold.records, row);
    applyEvent(testFold.records, event);
    const line = `${JSON.stringify(event)}\n`;
    appendLine(paths.registry, line, options.injectReadBackMismatch || process.env.MEM_INJECT_READBACK_MISMATCH === '1');
    const newFold = foldRegistry(paths);
    installIndexFromFold(paths, newFold);
    return { event, skipped: false, fold: newFold };
  }, options.lock);
}

function contentFields(record) {
  return {
    id: record.id,
    summary: record.summary,
    body: record.body,
    source: record.source ?? null,
    memoryType: record.memoryType ?? 'factual',
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
    guard: record.guard ?? null,
    guardLinked: Boolean(record.guardLinked),
    riskClass: record.riskClass
  };
}

function projectRecord(record) {
  const content = contentFields(record);
  return {
    ...content,
    status: record.status,
    validFrom: record.validFrom,
    validTo: record.validTo,
    recordedAt: record.recordedAt,
    verifiedAt: record.verifiedAt,
    supersedes: record.supersedes || [],
    supersededBy: record.supersededBy ?? null,
    contradicts: record.contradicts || [],
    evidence: record.evidence || [],
    proposedBy: record.proposedBy ?? null,
    activatedBy: record.activatedBy ?? null,
    generation: record.lastEventSeq || 0,
    eventIds: record.eventIds || [],
    contentHash: contentHash(content)
  };
}

export function activeRecords(fold) {
  return [...fold.records.values()].filter((record) => record.status === 'active').map(projectRecord);
}

function buildIndexObject(fold) {
  const records = activeRecords(fold);
  return {
    schema: ACTIVE_INDEX_SCHEMA,
    generatedAt: new Date().toISOString(),
    registry: fold.watermark,
    recordCount: records.length,
    records
  };
}

// Install a freshly projected index with a monotonic guard: if an index with a
// strictly newer registry watermark is already installed, keep it rather than
// regressing to an older projection. In the mutation path this runs under the
// registry lock, so installs are serialized; the guard defends the standalone
// `mem project` path against a concurrent write.
function installIndexFromFold(paths, fold, options = {}) {
  const index = buildIndexObject(fold);
  if (!options.force) {
    let installed = null;
    try {
      installed = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
    } catch {
      installed = null;
    }
    if (installed && Number(installed.registry?.seq) > Number(index.registry.seq)) {
      return installed;
    }
  }
  atomicWrite(paths.index, `${JSON.stringify(index, null, 2)}\n`);
  return index;
}

export function buildActiveIndex(dir) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  if (fold.health === 'critical') throw new Error(`registry is CRITICAL: ${fold.corrupt?.reason}`);
  return installIndexFromFold(paths, fold);
}

// Full projection verification: schema, complete watermark (seq + eventId +
// registryHash), active ID set, count, per-record content and content hash, and
// absence of any inactive record. Any tamper of the installed index against the
// canonical registry is reported as stale/invalid, never green.
function verifyActiveIndex(fold, installed) {
  if (installed === undefined) return { status: 'missing', issues: ['index file missing'] };
  if (installed === null) return { status: 'invalid', issues: ['index file is not valid JSON'] };
  const issues = [];
  if (installed.schema !== ACTIVE_INDEX_SCHEMA) issues.push('index schema mismatch');
  const w = installed.registry || {};
  if (Number(w.seq) !== fold.watermark.seq) issues.push('watermark seq mismatch');
  if ((w.eventId ?? null) !== fold.watermark.eventId) issues.push('watermark eventId mismatch');
  if (w.registryHash !== fold.watermark.registryHash) issues.push('watermark registryHash mismatch');

  const expected = activeRecords(fold);
  const expectedById = new Map(expected.map((rec) => [rec.id, rec]));
  const activeIds = new Set(expected.map((rec) => rec.id));
  if (Number(installed.recordCount) !== expected.length) issues.push('recordCount mismatch');
  if (!Array.isArray(installed.records)) {
    issues.push('index records is not an array');
  } else {
    if (installed.records.length !== expected.length) issues.push('record array length mismatch');
    for (const rec of installed.records) {
      if (!rec || typeof rec.id !== 'string') {
        issues.push('index record missing id');
        continue;
      }
      if (!activeIds.has(rec.id)) {
        issues.push(`inactive or unknown record in active index: ${rec.id}`);
        continue;
      }
      const exp = expectedById.get(rec.id);
      const installedContent = contentFields(rec);
      const recomputed = contentHash(installedContent);
      if (rec.contentHash !== exp.contentHash) issues.push(`content hash mismatch: ${rec.id}`);
      if (recomputed !== rec.contentHash) issues.push(`installed content hash not self-consistent: ${rec.id}`);
      if (stableJson(installedContent) !== stableJson(contentFields(exp))) issues.push(`record content mismatch: ${rec.id}`);
      if (Number(rec.generation ?? -1) !== Number(exp.generation ?? -1)) issues.push(`generation watermark mismatch: ${rec.id}`);
    }
  }
  return { status: issues.length ? 'stale' : 'current', issues };
}

export function auditRegistry(dir) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  let installed;
  if (!fs.existsSync(paths.index)) {
    installed = undefined;
  } else {
    try {
      installed = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
    } catch {
      installed = null;
    }
  }
  const verification = fold.health === 'critical'
    ? { status: installed === undefined ? 'missing' : 'unknown', issues: ['registry CRITICAL: projection not verified'] }
    : verifyActiveIndex(fold, installed);
  const statusCounts = {};
  for (const record of fold.records.values()) statusCounts[record.status] = (statusCounts[record.status] || 0) + 1;
  return {
    ok: fold.health !== 'critical' && verification.status === 'current',
    registry: {
      path: paths.registry,
      health: fold.health,
      watermark: fold.watermark,
      corrupt: fold.corrupt ? { line: fold.corrupt.line, reason: fold.corrupt.reason, byteOffset: fold.corrupt.byteOffset, bytes: fold.corrupt.bytes.length } : null
    },
    records: { total: fold.records.size, active: activeRecords(fold).length, statusCounts },
    duplicates: fold.duplicates,
    activeIndex: { path: paths.index, status: verification.status, issues: verification.issues, watermark: installed?.registry || null }
  };
}

// Snapshot filenames are built only from the numeric sequence and a hash of the
// event ID. A raw (possibly hostile) event ID never enters the filesystem path,
// so a `../../../evil` event ID cannot traverse out of the snapshots directory.
export function snapshotRegistry(dir) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  if (fold.health === 'critical') throw new Error(`registry is CRITICAL: ${fold.corrupt?.reason}`);
  fs.mkdirSync(paths.snapshots, { recursive: true, mode: 0o755 });
  const tag = sha256(String(fold.watermark.eventId || 'empty')).slice(0, 16);
  const file = path.join(paths.snapshots, `registry-${Number(fold.watermark.seq)}-${tag}.json`);
  if (path.dirname(path.resolve(file)) !== path.resolve(paths.snapshots)) {
    throw new Error('refusing to write snapshot outside the snapshots directory');
  }
  const payload = {
    schema: 'kraken-memory/registry-snapshot/v1',
    createdAt: new Date().toISOString(),
    registry: fold.watermark,
    records: [...fold.records.values()].map((record) => ({ ...record }))
  };
  atomicWrite(file, `${JSON.stringify(payload, null, 2)}\n`);
  return { file, snapshot: payload };
}

function makeFailpoint(failpoints) {
  const set = new Set(Array.isArray(failpoints) ? failpoints : failpoints ? [failpoints] : []);
  const envRaw = process.env.MEM_RECOVERY_FAILPOINT;
  if (envRaw) for (const stage of envRaw.split(',')) set.add(stage.trim());
  return (stage) => {
    if (set.has(stage)) {
      const error = new Error(`recovery failpoint: ${stage}`);
      error.code = 'MEM_RECOVERY_FAILPOINT';
      error.stage = stage;
      throw error;
    }
  };
}

// Provenance: original FirstMate Runtime recovery core (not ported from Fleet
// Bridge), implementing the amendment's strict CRITICAL + explicit `mem recover`
// model. Reuses this package's withRegistryLock and atomicWrite discipline.
//
// Byte-faithful, crash-durable canonical recovery. Operates on raw bytes so
// invalid-UTF-8 / NUL corruption is preserved exactly in the sidecar; the valid
// prefix is copied verbatim (never re-serialized); every artifact is fsynced;
// the canonical file is atomically replaced only after the repaired file folds
// clean; and success is returned only after a green final audit.
export async function recoverRegistry(dir, options = {}) {
  const paths = registryPaths(dir);
  const fail = makeFailpoint(options.failpoints);
  return withRegistryLock(paths.lock, async () => {
    const before = fs.existsSync(paths.registry) ? fs.readFileSync(paths.registry) : Buffer.alloc(0);
    const originalHash = sha256(before);
    const fold = foldRegistry(paths);
    if (fold.health !== 'critical') throw new Error('registry is not CRITICAL; recovery refused');
    fs.mkdirSync(paths.recovery, { recursive: true, mode: 0o700 });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backup = path.join(paths.recovery, `memory-registry.${stamp}.backup.jsonl`);
    const sidecar = path.join(paths.recovery, `memory-registry.${stamp}.corrupt-bytes`);
    const repaired = path.join(paths.recovery, `memory-registry.${stamp}.repaired.jsonl`);

    fail('before-backup');
    atomicWrite(backup, before);
    fail('after-backup');

    const corruptBytes = fold.corrupt.bytes; // raw suffix, byte-for-byte
    atomicWrite(sidecar, corruptBytes);
    const sidecarHash = sha256(corruptBytes);
    fail('after-sidecar');

    const repairedBytes = before.subarray(0, fold.corrupt.byteOffset); // exact valid prefix
    const repairedHash = sha256(repairedBytes);
    atomicWrite(repaired, repairedBytes);
    fail('after-repaired-write');

    fail('before-validation');
    const repairedFold = foldRegistry({ ...paths, registry: repaired });
    if (repairedFold.health === 'critical') throw new Error(`repaired registry failed validation: ${repairedFold.corrupt?.reason}`);
    const lastValidPreRecoveryWatermark = fold.watermark;

    fail('before-rename');
    const replaceTmp = `${paths.registry}.recover-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
    fs.copyFileSync(repaired, replaceTmp);
    fsyncFile(replaceTmp);
    fs.renameSync(replaceTmp, paths.registry);
    fsyncDir(paths.dir);
    fail('after-rename');

    fail('before-recovery-event');
    const recoveryEvent = await appendActivity(dir, {
      event: 'registry_recovered',
      detail: {
        originalHash,
        sidecarHash,
        repairedHash,
        backup,
        sidecar,
        lastValidPreRecoveryWatermark,
        postRecoveryWatermark: repairedFold.watermark
      }
    });

    fail('before-index-rebuild');
    const index = installIndexFromFold(paths, foldRegistry(paths), { force: true });

    fail('before-final-audit');
    const finalAudit = auditRegistry(dir);
    if (!finalAudit.ok) {
      throw new Error(`recovery final audit failed: ${JSON.stringify(finalAudit.activeIndex?.issues || finalAudit.registry?.corrupt)}`);
    }

    return {
      backup,
      sidecar,
      repaired,
      originalHash,
      sidecarHash,
      repairedHash,
      lastValidPreRecoveryWatermark,
      postRecoveryWatermark: repairedFold.watermark,
      activeIndexWatermark: index.registry,
      audit: finalAudit,
      recoveryEvent
    };
  }, options.lock);
}
