import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { appendActivity, auditActivity } from './activity.mjs';
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

function actorId(actor) {
  return typeof actor?.id === 'string' && actor.id.length > 0 ? actor.id : null;
}

function validationRef(event) {
  return typeof event.validation?.ref === 'string' && event.validation.ref.length > 0 ? event.validation.ref : null;
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

const MUTABLE_FIELD_KEYS = new Set([
  'summary',
  'body',
  'source',
  'memoryType',
  'scope',
  'projects',
  'taskKinds',
  'keywords',
  'aliases',
  'entities',
  'commands',
  'failureModes',
  'relatedTerms',
  'validFrom',
  'validTo',
  'confidence',
  'contradicts',
  'guard',
  'riskClass'
]);

// Sparse field application: only known mutable record keys explicitly present
// (and not undefined) are written. This is what makes `mem update`
// non-destructive while keeping passthrough event fields from mutating lifecycle
// internals such as status, ids, sequence watermarks, or lineage.
function applyFields(record, fields = {}) {
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) continue;
    if (key === 'guard_linked') {
      record.guardLinked = Boolean(value);
      continue;
    }
    if (!MUTABLE_FIELD_KEYS.has(key)) continue;
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
    if (isHighImpact(record) && !actorId(event.actor)) {
      throw new Error(`high-impact proposal requires actor.id: ${event.memId}`);
    }
    record.status = 'candidate';
    record.proposedBy = { kind: event.actor?.kind, id: actorId(event.actor) };
    if (event.guard_linked !== undefined) record.guardLinked = Boolean(event.guard_linked);
    record.evidence = mergeEvidence(record.evidence, event.evidence || []);
    record.eventIds.push(event.eventId);
    records.set(event.memId, record);
    return;
  }
  if (!record) throw new Error(`unknown memory record: ${event.memId}`);
  assertTransition(record, event);
  const activationGovernanceRecord = event.event === 'activated'
    ? { ...record, taskKinds: [...(record.taskKinds || [])] }
    : null;
  applyFields(record, event.fields || {});

  if (event.event === 'activated' || event.event === 'revalidated') {
    if ((event.evidence || []).length === 0 || !event.validation?.method) {
      throw new Error(`${event.event} requires evidence and validation: ${event.memId}`);
    }
    if (event.event === 'activated' && (isHighImpact(activationGovernanceRecord) || isHighImpact(record))) {
      const captainAuthority = event.actor?.kind === 'captain' && Boolean(validationRef(event));
      const proposer = actorId(record.proposedBy);
      const activator = actorId(event.actor);
      if (!proposer) throw new Error(`high-impact activation requires proposer actor.id: ${event.memId}`);
      if (!activator) throw new Error(`high-impact activation requires activator actor.id: ${event.memId}`);
      if (!event.validation?.by) throw new Error(`high-impact activation requires validation.by: ${event.memId}`);
      if (event.actor?.kind === 'captain' && !validationRef(event)) {
        throw new Error(`captain-authorized high-impact activation requires an authorization reference: ${event.memId}`);
      }
      if (!captainAuthority && proposer === activator) {
        throw new Error(`high-impact activation requires an independent activator or captain authority: ${event.memId}`);
      }
    }
    record.status = 'active';
    record.verifiedAt = event.ts;
    record.confidence = event.fields?.confidence || record.confidence || 'observed';
    record.activatedBy = { kind: event.actor?.kind, id: actorId(event.actor), validationBy: event.validation?.by ?? null, authorizationRef: validationRef(event) };
    record.evidence = mergeEvidence(record.evidence, event.evidence);
  } else if (event.event === 'updated') {
    record.evidence = mergeEvidence(record.evidence, event.evidence || []);
  } else if (event.event === 'superseded') {
    const successorId = event.successor;
    if (successorId === event.memId) throw new Error(`memory record cannot supersede itself: ${event.memId}`);
    const successor = records.get(successorId);
    if (!successor) throw new Error(`supersession successor not found: ${successorId} for ${event.memId}`);
    if (successor.status !== 'active') throw new Error(`supersession successor must be active: ${successorId}`);
    let cursor = successorId;
    const seen = new Set();
    while (cursor) {
      if (cursor === event.memId) throw new Error(`supersession lineage cycle detected: ${event.memId} -> ${successorId}`);
      if (seen.has(cursor)) throw new Error(`supersession lineage cycle detected at ${cursor}`);
      seen.add(cursor);
      cursor = records.get(cursor)?.supersededBy ?? null;
    }
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
  if (process.env.MEM_ATOMIC_WRITE_FAIL_PATH && file.includes(process.env.MEM_ATOMIC_WRITE_FAIL_PATH)) {
    throw new Error(`injected atomic write failure for ${file}`);
  }
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
    const recovery = readRecoveryState(paths);
    if (recovery?.incomplete) throw new Error(`registry recovery is incomplete: run mem recover before mutating (${recovery.state?.currentStage || 'unknown'})`);
    if (snapshotReconciliationNeeded(paths, fold)) {
      reconcileBoundarySnapshotObligations(paths, fold, { repair: true, sourceCommand: 'mem append repair' });
    }
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
    maybeAutoSnapshot(paths, newFold, { sourceCommand: 'mem append' });
    return { event, skipped: false, fold: newFold };
  }, options.lock);
}

function contentFields(record) {
  return {
    id: record.id,
    summary: record.summary,
    body: record.body,
    source: record.source ?? null,
    memoryType: record.memoryType,
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

const REQUIRED_PROJECTED_FIELDS = [
  'id', 'summary', 'body', 'source', 'memoryType', 'scope', 'projects', 'taskKinds',
  'keywords', 'aliases', 'entities', 'commands', 'failureModes', 'relatedTerms',
  'confidence', 'guard', 'guardLinked', 'riskClass', 'status', 'validFrom',
  'validTo', 'recordedAt', 'verifiedAt', 'supersedes', 'supersededBy',
  'contradicts', 'evidence', 'proposedBy', 'activatedBy', 'generation',
  'eventIds', 'contentHash'
];

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
  const recovery = readRecoveryState(paths);
  if (recovery?.incomplete) throw new Error(`registry recovery is incomplete: run mem recover before rebuilding (${recovery.state?.currentStage || 'unknown'})`);
  reconcileBoundarySnapshotObligations(paths, fold, { repair: true, sourceCommand: 'mem index rebuild repair' });
  snapshotFromFold(paths, fold, { reason: 'pre-index-rebuild', sourceCommand: 'mem index rebuild' });
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
  if (!installed || typeof installed !== 'object' || Array.isArray(installed)) {
    return { status: 'invalid', issues: ['index document is not an object'] };
  }
  if (installed.schema !== ACTIVE_INDEX_SCHEMA) issues.push('index schema mismatch');
  if (typeof installed.generatedAt !== 'string') issues.push('index generatedAt missing or invalid');
  if (!installed.registry || typeof installed.registry !== 'object') issues.push('index registry watermark missing');
  const w = installed.registry || {};
  if (Number(w.seq) !== fold.watermark.seq) issues.push('watermark seq mismatch');
  if ((w.eventId ?? null) !== fold.watermark.eventId) issues.push('watermark eventId mismatch');
  if (w.registryHash !== fold.watermark.registryHash) issues.push('watermark registryHash mismatch');

  const expected = activeRecords(fold);
  const expectedById = new Map(expected.map((rec) => [rec.id, rec]));
  const activeIds = new Set(expected.map((rec) => rec.id));
  const installedIds = new Set();
  const installedIdCounts = new Map();
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
      installedIdCounts.set(rec.id, (installedIdCounts.get(rec.id) || 0) + 1);
      if (installedIdCounts.get(rec.id) > 1) issues.push(`duplicate active index id: ${rec.id}`);
      installedIds.add(rec.id);
      if (!activeIds.has(rec.id)) {
        issues.push(`inactive or unknown record in active index: ${rec.id}`);
        continue;
      }
      const exp = expectedById.get(rec.id);
      for (const field of REQUIRED_PROJECTED_FIELDS) {
        if (!Object.prototype.hasOwnProperty.call(rec, field)) issues.push(`required projected field missing: ${rec.id}.${field}`);
      }
      const installedContent = contentFields(rec);
      const recomputed = contentHash(installedContent);
      if (rec.contentHash !== exp.contentHash) issues.push(`content hash mismatch: ${rec.id}`);
      if (recomputed !== rec.contentHash) issues.push(`installed content hash not self-consistent: ${rec.id}`);
      if (stableJson(installedContent) !== stableJson(contentFields(exp))) issues.push(`record content mismatch: ${rec.id}`);
      if (Number(rec.generation ?? -1) !== Number(exp.generation ?? -1)) issues.push(`generation watermark mismatch: ${rec.id}`);
      if (stableJson(rec) !== stableJson(exp)) issues.push(`projected record mismatch: ${rec.id}`);
    }
    for (const id of activeIds) {
      if (!installedIds.has(id)) issues.push(`missing active record in active index: ${id}`);
    }
    for (const id of installedIds) {
      if (!activeIds.has(id)) issues.push(`extra active index record id: ${id}`);
    }
  }
  return { status: issues.length ? 'stale' : 'current', issues };
}

function readRecoveryState(paths) {
  const file = path.join(paths.recovery, 'recovery-state.json');
  if (!fs.existsSync(file)) return null;
  try {
    const state = JSON.parse(fs.readFileSync(file, 'utf8'));
    return { file, state, incomplete: !state.completedAt };
  } catch (error) {
    return { file, state: null, incomplete: true, error: error.message };
  }
}

export function auditRegistry(dir, options = {}) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  const recovery = readRecoveryState(paths);
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
  const activity = auditActivity(dir);
  const snapshots = inspectBoundarySnapshotObligations(paths, fold);
  if (recovery?.incomplete && !options.ignoreRecovery) {
    verification.issues = [...verification.issues, 'recovery incomplete'];
    if (verification.status === 'current') verification.status = 'stale';
  }
  const statusCounts = {};
  for (const record of fold.records.values()) statusCounts[record.status] = (statusCounts[record.status] || 0) + 1;
  return {
    ok: fold.health !== 'critical' && verification.status === 'current' && activity.health === 'ok' && snapshots.health === 'ok' && (!recovery?.incomplete || options.ignoreRecovery),
    registry: {
      path: paths.registry,
      health: recovery?.incomplete && !options.ignoreRecovery ? 'recovery_incomplete' : fold.health,
      watermark: fold.watermark,
      corrupt: fold.corrupt ? { line: fold.corrupt.line, reason: fold.corrupt.reason, byteOffset: fold.corrupt.byteOffset, bytes: fold.corrupt.bytes.length } : null,
      recovery: recovery ? {
        path: recovery.file,
        incomplete: recovery.incomplete,
        stage: recovery.state?.currentStage || null,
        recoveryId: recovery.state?.recoveryId || null,
        error: recovery.error || recovery.state?.lastError || null
      } : null
    },
    records: { total: fold.records.size, active: activeRecords(fold).length, statusCounts },
    duplicates: fold.duplicates,
    activeIndex: { path: paths.index, status: verification.status, issues: verification.issues, watermark: installed?.registry || null },
    snapshots,
    activity
  };
}

// Snapshot filenames are built only from the numeric sequence and a hash of the
// event ID. A raw (possibly hostile) event ID never enters the filesystem path,
// so a `../../../evil` event ID cannot traverse out of the snapshots directory.
function safeSnapshotReason(reason) {
  return String(reason).replace(/[^a-z0-9._-]/gi, '-').slice(0, 48) || 'snapshot';
}

function boundarySnapshotReason(seq) {
  return `automatic-${seq}-event-boundary`;
}

function snapshotFileForFold(paths, fold, reason) {
  const tag = sha256(String(fold.watermark.eventId || 'empty')).slice(0, 16);
  return path.join(paths.snapshots, `registry-${Number(fold.watermark.seq)}-${safeSnapshotReason(reason)}-${tag}.json`);
}

function snapshotPayload(fold, reason, sourceCommand) {
  const base = {
    schema: 'kraken-memory/registry-snapshot/v1',
    createdAt: new Date().toISOString(),
    reason,
    sourceCommand,
    registry: fold.watermark,
    registryHash: fold.watermark.registryHash,
    records: [...fold.records.values()].map((record) => ({ ...record }))
  };
  return { ...base, snapshotHash: sha256(stableJson(base)) };
}

function validateSnapshotPayload(snapshot, fold, reason) {
  const issues = [];
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) return ['snapshot document is not an object'];
  for (const field of ['schema', 'createdAt', 'reason', 'sourceCommand', 'registry', 'registryHash', 'records', 'snapshotHash']) {
    if (!Object.prototype.hasOwnProperty.call(snapshot, field)) issues.push(`snapshot required field missing: ${field}`);
  }
  if (snapshot.schema !== 'kraken-memory/registry-snapshot/v1') issues.push('snapshot schema mismatch');
  if (typeof snapshot.createdAt !== 'string' || !snapshot.createdAt) issues.push('snapshot createdAt missing or invalid');
  if (typeof snapshot.sourceCommand !== 'string' || !snapshot.sourceCommand) issues.push('snapshot sourceCommand missing or invalid');
  if (snapshot.reason !== reason) issues.push('snapshot reason mismatch');
  if (!snapshot.registry || typeof snapshot.registry !== 'object' || Array.isArray(snapshot.registry)) {
    issues.push('snapshot registry watermark missing');
  }
  if (Number(snapshot.registry?.seq) !== Number(fold.watermark.seq)) issues.push('snapshot registry seq mismatch');
  if ((snapshot.registry?.eventId ?? null) !== (fold.watermark.eventId ?? null)) issues.push('snapshot registry eventId mismatch');
  if (snapshot.registry?.registryHash !== fold.watermark.registryHash) issues.push('snapshot registry hash mismatch');
  if (snapshot.registryHash !== fold.watermark.registryHash) issues.push('snapshot registryHash mismatch');
  const expectedRecords = [...fold.records.values()].map((record) => ({ ...record }));
  if (!Array.isArray(snapshot.records)) {
    issues.push('snapshot records is not an array');
  } else if (stableJson(snapshot.records) !== stableJson(expectedRecords)) {
    issues.push('snapshot records do not match boundary fold');
  }
  const { snapshotHash, ...base } = snapshot;
  if (snapshotHash !== sha256(stableJson(base))) issues.push('snapshot hash mismatch');
  return issues;
}

function readValidSnapshot(file, fold, reason) {
  const resolvedFile = path.resolve(file);
  const resolvedSnapshots = path.resolve(fold.paths.snapshots);
  const relative = path.relative(resolvedSnapshots, resolvedFile);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
    return { file, valid: false, issue: 'snapshot file is outside the snapshots directory' };
  }
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    return { file, valid: false, issue: `snapshot file is not readable: ${error.message}` };
  }
  if (!stat.isFile()) return { file, valid: false, issue: 'snapshot file is not a regular file' };
  try {
    const realFile = fs.realpathSync(file);
    const realRelative = path.relative(resolvedSnapshots, realFile);
    if (!realRelative || realRelative.startsWith('..') || path.isAbsolute(realRelative)) {
      return { file, valid: false, issue: 'snapshot file resolves outside the snapshots directory' };
    }
  } catch (error) {
    return { file, valid: false, issue: `snapshot file is not readable: ${error.message}` };
  }
  if ((stat.mode & 0o777) !== 0o600) return { file, valid: false, issue: 'snapshot file mode must be 600' };
  try {
    const snapshot = JSON.parse(fs.readFileSync(file, 'utf8'));
    const issues = validateSnapshotPayload(snapshot, fold, reason);
    return issues.length ? { file, valid: false, issue: issues.join('; ') } : { file, valid: true, snapshot };
  } catch (error) {
    return { file, valid: false, issue: `snapshot is not valid JSON: ${error.message}` };
  }
}

function snapshotFromFold(paths, fold, { reason = 'manual', sourceCommand = 'mem snapshot' } = {}) {
  if (process.env.MEM_SNAPSHOT_FAIL === '1') throw new Error('injected snapshot failure');
  fs.mkdirSync(paths.snapshots, { recursive: true, mode: 0o755 });
  const file = snapshotFileForFold(paths, fold, reason);
  if (path.dirname(path.resolve(file)) !== path.resolve(paths.snapshots)) {
    throw new Error('refusing to write snapshot outside the snapshots directory');
  }
  if (fs.existsSync(file)) {
    const existing = readValidSnapshot(file, fold, reason);
    if (!existing.valid) throw new Error(`invalid existing snapshot ${path.basename(file)}: ${existing.issue}`);
    return { file, snapshot: existing.snapshot, created: false };
  }
  const payload = snapshotPayload(fold, reason, sourceCommand);
  atomicWrite(file, `${JSON.stringify(payload, null, 2)}\n`);
  return { file, snapshot: payload, created: true };
}

function registryPrefixBytesForSequence(paths, seq) {
  if (seq === 0) return Buffer.alloc(0);
  const buffer = fs.existsSync(paths.registry) ? fs.readFileSync(paths.registry) : Buffer.alloc(0);
  const { rows } = splitRowsBytes(buffer);
  const seen = new Set();
  let accepted = 0;
  for (const row of rows) {
    const line = row.bytes.toString('utf8');
    if (line.trim() === '') continue;
    const parsed = validateRegistryEvent(JSON.parse(line));
    if (seen.has(parsed.eventId)) continue;
    seen.add(parsed.eventId);
    accepted += 1;
    if (accepted === seq) return buffer.subarray(0, row.end);
  }
  throw new Error(`registry sequence ${seq} is not present`);
}

function foldAtSequence(paths, fullFold, seq) {
  if (Number(seq) === Number(fullFold.watermark.seq)) return fullFold;
  if (seq < 0 || seq > fullFold.events.length) throw new Error(`registry sequence ${seq} is outside current watermark ${fullFold.events.length}`);
  const fold = emptyFold(paths);
  for (const row of fullFold.events.slice(0, seq)) {
    applyEvent(fold.records, row);
    fold.events.push(row);
    const rec = fold.records.get(row.memId);
    if (rec) rec.lastEventSeq = fold.events.length;
  }
  const validPrefix = registryPrefixBytesForSequence(paths, seq);
  const last = fold.events.at(-1);
  fold.watermark = { seq: fold.events.length, eventId: last?.eventId || null, registryHash: sha256(validPrefix) };
  fold.validPrefixBytes = validPrefix;
  return fold;
}

function readSnapshotState(paths) {
  if (!fs.existsSync(paths.snapshotState)) return { schema: 'kraken-memory/snapshot-obligations/v1', updatedAt: null, obligations: [] };
  try {
    const state = JSON.parse(fs.readFileSync(paths.snapshotState, 'utf8'));
    return {
      schema: state.schema || 'kraken-memory/snapshot-obligations/v1',
      updatedAt: state.updatedAt || null,
      obligations: Array.isArray(state.obligations) ? state.obligations : []
    };
  } catch (error) {
    return { schema: 'kraken-memory/snapshot-obligations/v1', updatedAt: null, obligations: [], corrupt: error.message };
  }
}

function writeSnapshotState(paths, state) {
  atomicWrite(paths.snapshotState, `${JSON.stringify({ ...state, schema: 'kraken-memory/snapshot-obligations/v1', updatedAt: new Date().toISOString() }, null, 2)}\n`);
}

function obligationBase(paths, fold) {
  const reason = boundarySnapshotReason(fold.watermark.seq);
  return {
    boundarySeq: fold.watermark.seq,
    registry: fold.watermark,
    expectedSnapshot: path.basename(snapshotFileForFold(paths, fold, reason)),
    reason
  };
}

function validateSnapshotObligation(stored, boundaryFold, validSnapshot) {
  if (!stored) return ['snapshot obligation missing'];
  const issues = [];
  const base = obligationBase(boundaryFold.paths, boundaryFold);
  const expectedPath = typeof stored.expectedSnapshot === 'string'
    ? path.resolve(boundaryFold.paths.snapshots, stored.expectedSnapshot)
    : null;
  if (stored.status !== 'complete') issues.push('snapshot obligation is not complete');
  if (Number(stored.boundarySeq) !== Number(base.boundarySeq)) issues.push('snapshot obligation boundarySeq mismatch');
  if (stored.reason !== base.reason) issues.push('snapshot obligation reason mismatch');
  if (stored.expectedSnapshot !== base.expectedSnapshot) issues.push('snapshot obligation expectedSnapshot mismatch');
  if (!expectedPath) {
    issues.push('snapshot obligation expectedSnapshot missing');
  } else {
    const resolvedSnapshots = path.resolve(boundaryFold.paths.snapshots);
    const relative = path.relative(resolvedSnapshots, expectedPath);
    if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) issues.push('snapshot obligation expectedSnapshot escapes snapshots directory');
  }
  if (stored.file !== base.expectedSnapshot) issues.push('snapshot obligation file mismatch');
  if (Number(stored.registry?.seq) !== Number(boundaryFold.watermark.seq)) issues.push('snapshot obligation registry seq mismatch');
  if ((stored.registry?.eventId ?? null) !== (boundaryFold.watermark.eventId ?? null)) issues.push('snapshot obligation registry eventId mismatch');
  if (stored.registry?.registryHash !== boundaryFold.watermark.registryHash) issues.push('snapshot obligation registry hash mismatch');
  if (validSnapshot && stored.snapshotHash !== validSnapshot.snapshot.snapshotHash) issues.push('snapshot obligation hash mismatch');
  return issues;
}

function updateSnapshotObligation(paths, boundaryFold, patch) {
  const state = readSnapshotState(paths);
  if (state.corrupt) throw new Error(`snapshot obligation state is corrupt: ${state.corrupt}`);
  const base = obligationBase(paths, boundaryFold);
  const existing = state.obligations.find((item) => Number(item.boundarySeq) === Number(base.boundarySeq)) || {};
  const obligations = state.obligations.filter((item) => Number(item.boundarySeq) !== Number(base.boundarySeq));
  obligations.push({ ...existing, ...base, ...patch, updatedAt: new Date().toISOString() });
  obligations.sort((a, b) => Number(a.boundarySeq) - Number(b.boundarySeq));
  writeSnapshotState(paths, { ...state, obligations });
}

function boundarySnapshotFiles(paths, boundaryFold) {
  const reason = boundarySnapshotReason(boundaryFold.watermark.seq);
  const prefix = `registry-${Number(boundaryFold.watermark.seq)}-${safeSnapshotReason(reason)}-`;
  if (!fs.existsSync(paths.snapshots)) return { reason, files: [] };
  return {
    reason,
    files: fs.readdirSync(paths.snapshots)
      .filter((name) => name.startsWith(prefix) && name.endsWith('.json'))
      .map((name) => path.join(paths.snapshots, name))
      .sort()
  };
}

function inspectBoundarySnapshot(paths, boundaryFold) {
  const { reason, files } = boundarySnapshotFiles(paths, boundaryFold);
  const checked = files.map((file) => readValidSnapshot(file, boundaryFold, reason));
  const valid = checked.filter((item) => item.valid);
  const invalid = checked.filter((item) => !item.valid);
  return { reason, valid, invalid };
}

function boundarySequences(watermark) {
  const out = [];
  for (let seq = 500; seq <= Number(watermark.seq); seq += 500) out.push(seq);
  return out;
}

function snapshotReconciliationNeeded(paths, fold) {
  return inspectBoundarySnapshotObligations(paths, fold).health !== 'ok';
}

function inspectBoundarySnapshotObligations(paths, fold) {
  const state = readSnapshotState(paths);
  const issues = [];
  if (state.corrupt) issues.push(`snapshot obligation state is corrupt: ${state.corrupt}`);
  const obligations = [];
  for (const seq of boundarySequences(fold.watermark)) {
    const boundaryFold = foldAtSequence(paths, fold, seq);
    const base = obligationBase(paths, boundaryFold);
    const stored = state.obligations.find((item) => Number(item.boundarySeq) === seq);
    const inspected = inspectBoundarySnapshot(paths, boundaryFold);
    const invalidIssues = inspected.invalid.map((item) => `${path.basename(item.file)}: ${item.issue}`);
    if (inspected.valid.length > 1) issues.push(`duplicate valid boundary snapshots for sequence ${seq}`);
    issues.push(...invalidIssues.map((issue) => `invalid boundary snapshot for sequence ${seq}: ${issue}`));
    const complete = inspected.valid.length === 1;
    const metadataIssues = validateSnapshotObligation(stored, boundaryFold, complete ? inspected.valid[0] : null);
    if (complete) issues.push(...metadataIssues.map((issue) => `invalid boundary snapshot obligation for sequence ${seq}: ${issue}`));
    if (!complete) issues.push(`required boundary snapshot missing for sequence ${seq}`);
    obligations.push({
      ...base,
      status: complete && metadataIssues.length === 0 ? 'complete' : (stored?.status || 'missing'),
      file: complete ? path.basename(inspected.valid[0].file) : null,
      attempts: stored?.attempts || 0,
      lastFailure: stored?.lastFailure || null,
      outstanding: !complete || metadataIssues.length > 0,
      invalid: invalidIssues,
      metadataIssues
    });
  }
  return {
    path: paths.snapshotState,
    health: issues.length ? 'degraded' : 'ok',
    issues,
    obligations,
    outstanding: obligations.filter((item) => item.outstanding)
  };
}

function quarantineSnapshotArtifact(paths, file, issue) {
  const corruptDir = path.join(paths.snapshots, 'corrupt');
  fs.mkdirSync(corruptDir, { recursive: true, mode: 0o700 });
  let stat = null;
  let corruptHash = null;
  try {
    stat = fs.lstatSync(file);
    if (stat.isFile()) {
      const bytes = fs.readFileSync(file);
      corruptHash = sha256(bytes);
      fsyncFile(file);
    }
  } catch {
    // Preserve by rename even when metadata or bytes cannot be fully inspected.
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const suffix = corruptHash ? corruptHash.slice(0, 16) : crypto.randomBytes(8).toString('hex');
  let quarantine = path.join(corruptDir, `${path.basename(file)}.corrupt-${stamp}-${suffix}`);
  while (fs.existsSync(quarantine)) quarantine = `${quarantine}-${crypto.randomBytes(2).toString('hex')}`;
  fs.renameSync(file, quarantine);
  if (stat?.isFile() && corruptHash) fsyncFile(quarantine);
  fsyncDir(corruptDir);
  fsyncDir(path.dirname(file));
  return {
    original: path.basename(file),
    quarantine: path.relative(paths.snapshots, quarantine),
    corruptHash,
    issue
  };
}

function quarantineInvalidBoundarySnapshots(paths, inspected) {
  const quarantined = [];
  for (const item of inspected.invalid) {
    if (!fs.existsSync(item.file)) continue;
    quarantined.push(quarantineSnapshotArtifact(paths, item.file, item.issue));
  }
  return quarantined;
}

function reconcileBoundarySnapshotObligations(paths, fold, { repair = false, sourceCommand = 'mem append' } = {}) {
  if (fold.health === 'critical') return inspectBoundarySnapshotObligations(paths, fold);
  for (const seq of boundarySequences(fold.watermark)) {
    const boundaryFold = foldAtSequence(paths, fold, seq);
    const inspected = inspectBoundarySnapshot(paths, boundaryFold);
    if (inspected.valid.length > 1) throw new Error(`duplicate valid boundary snapshots for sequence ${seq}`);
    if (inspected.invalid.length > 0 && !repair) throw new Error(`invalid boundary snapshot for sequence ${seq}: ${inspected.invalid[0].issue}`);
    if (inspected.valid.length === 1) {
      const state = readSnapshotState(paths);
      const existing = state.obligations.find((item) => Number(item.boundarySeq) === seq);
      const metadataIssues = validateSnapshotObligation(existing, boundaryFold, inspected.valid[0]);
      const quarantined = repair ? quarantineInvalidBoundarySnapshots(paths, inspected) : [];
      if (repair) {
        updateSnapshotObligation(paths, boundaryFold, {
          status: 'complete',
          file: path.basename(inspected.valid[0].file),
          snapshotHash: inspected.valid[0].snapshot.snapshotHash,
          completedAt: new Date().toISOString(),
          lastFailure: null,
          repairs: [...(existing?.repairs || []), ...quarantined],
          metadataRepair: metadataIssues.length ? metadataIssues : existing?.metadataRepair || null
        });
      }
      continue;
    }
    if (!repair) continue;
    const state = readSnapshotState(paths);
    const existing = state.obligations.find((item) => Number(item.boundarySeq) === seq);
    const quarantined = quarantineInvalidBoundarySnapshots(paths, inspected);
    updateSnapshotObligation(paths, boundaryFold, {
      status: 'pending',
      attempts: existing?.attempts || 0,
      firstRequiredAt: existing?.firstRequiredAt || new Date().toISOString(),
      lastFailure: existing?.lastFailure || null,
      repairs: [...(existing?.repairs || []), ...quarantined]
    });
    try {
      const made = snapshotFromFold(paths, boundaryFold, { reason: inspected.reason, sourceCommand });
      const replacement = readValidSnapshot(made.file, boundaryFold, inspected.reason);
      if (!replacement.valid) throw new Error(`replacement snapshot failed validation: ${replacement.issue}`);
      updateSnapshotObligation(paths, boundaryFold, {
        status: 'complete',
        file: path.basename(made.file),
        snapshotHash: made.snapshot.snapshotHash,
        completedAt: new Date().toISOString(),
        lastFailure: null,
        attempts: existing?.attempts || 0
      });
    } catch (error) {
      updateSnapshotObligation(paths, boundaryFold, {
        status: 'failed',
        attempts: (existing?.attempts || 0) + 1,
        firstRequiredAt: existing?.firstRequiredAt || new Date().toISOString(),
        lastFailure: error.message,
        completedAt: null
      });
      throw error;
    }
  }
  return inspectBoundarySnapshotObligations(paths, fold);
}

function maybeAutoSnapshot(paths, fold, options = {}) {
  if (fold.watermark.seq > 0 && fold.watermark.seq % 500 === 0) {
    return reconcileBoundarySnapshotObligations(paths, fold, { repair: true, sourceCommand: options.sourceCommand || 'mem append' });
  }
  return null;
}

export function snapshotRegistry(dir, options = {}) {
  const paths = registryPaths(dir);
  const fold = foldRegistry(paths);
  if (fold.health === 'critical') throw new Error(`registry is CRITICAL: ${fold.corrupt?.reason}`);
  reconcileBoundarySnapshotObligations(paths, fold, { repair: true, sourceCommand: 'mem snapshot repair' });
  return snapshotFromFold(paths, fold, { reason: options.reason || 'manual', sourceCommand: options.sourceCommand || 'mem snapshot' });
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

function recoveryStateFile(paths) {
  return path.join(paths.recovery, 'recovery-state.json');
}

function writeRecoveryState(paths, state) {
  atomicWrite(recoveryStateFile(paths), `${JSON.stringify(state, null, 2)}\n`);
  return state;
}

function loadRecoveryState(paths) {
  const found = readRecoveryState(paths);
  return found?.state && !found.state.completedAt ? found.state : null;
}

function verifyHash(file, expected, label) {
  const actual = sha256(fs.readFileSync(file));
  if (actual !== expected) throw new Error(`${label} hash verification failed: expected ${expected}, got ${actual}`);
  return actual;
}

function updateRecovery(paths, state, patch) {
  return writeRecoveryState(paths, { ...state, ...patch, updatedAt: new Date().toISOString(), lastError: null });
}

function readSourceForRecovery(paths, state) {
  const buffer = fs.readFileSync(paths.registry);
  const fold = foldRegistry(paths);
  if (fold.health !== 'critical') {
    return { buffer, fold, repaired: true };
  }
  if (sha256(buffer) !== state.originalRegistryHash) {
    throw new Error('canonical registry hash changed during incomplete recovery');
  }
  return { buffer, fold, repaired: false };
}

async function runRecoveryState(dir, paths, state, fail) {
  let source = readSourceForRecovery(paths, state);

  if (!state.backupHash) {
    fail('before-backup');
    atomicWrite(state.backupPath, source.buffer);
    state = updateRecovery(paths, state, { backupHash: verifyHash(state.backupPath, state.originalRegistryHash, 'backup'), currentStage: 'backup-written' });
    fail('after-backup');
  } else {
    verifyHash(state.backupPath, state.originalRegistryHash, 'backup');
  }

  if (!state.sidecarHash) {
    if (source.fold.health !== 'critical') throw new Error('cannot create recovery sidecar after canonical repair without sidecar hash');
    const corruptBytes = source.fold.corrupt.bytes;
    atomicWrite(state.sidecarPath, corruptBytes);
    const sidecarHash = sha256(corruptBytes);
    state = updateRecovery(paths, state, { sidecarHash, currentStage: 'sidecar-written' });
    fail('after-sidecar');
  } else {
    verifyHash(state.sidecarPath, state.sidecarHash, 'sidecar');
  }

  if (!state.repairedHash) {
    if (source.fold.health !== 'critical') throw new Error('cannot create repaired registry after canonical repair without repaired hash');
    const repairedBytes = source.buffer.subarray(0, source.fold.corrupt.byteOffset);
    atomicWrite(state.repairedPath, repairedBytes);
    const repairedHash = sha256(repairedBytes);
    state = updateRecovery(paths, state, { repairedHash, currentStage: 'repaired-written' });
    fail('after-repaired-write');
  } else {
    verifyHash(state.repairedPath, state.repairedHash, 'repaired registry');
  }

  fail('before-validation');
  const repairedFold = foldRegistry({ ...paths, registry: state.repairedPath });
  if (repairedFold.health === 'critical') throw new Error(`repaired registry failed validation: ${repairedFold.corrupt?.reason}`);
  state = updateRecovery(paths, state, { currentStage: 'repaired-validated', validPrefixWatermark: state.validPrefixWatermark || repairedFold.watermark });

  if (!state.installedRegistryHash) {
    fail('before-rename');
    const replaceTmp = `${paths.registry}.recover-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
    fs.copyFileSync(state.repairedPath, replaceTmp);
    fsyncFile(replaceTmp);
    fs.renameSync(replaceTmp, paths.registry);
    fsyncDir(paths.dir);
    const installedRegistryHash = verifyHash(paths.registry, state.repairedHash, 'installed registry');
    state = updateRecovery(paths, state, { installedRegistryHash, currentStage: 'registry-installed' });
    fail('after-rename');
  } else {
    verifyHash(paths.registry, state.installedRegistryHash, 'installed registry');
  }

  if (!state.recoveryEventId) {
    fail('before-recovery-event');
    const recoveryEvent = await appendActivity(dir, {
      event: 'registry_recovered',
      actor: state.actor || { kind: 'mem', id: 'memory-cli' },
      detail: {
        recoveryId: state.recoveryId,
        originalHash: state.originalRegistryHash,
        sidecarHash: state.sidecarHash,
        repairedHash: state.repairedHash,
        installedRegistryHash: state.installedRegistryHash,
        backup: state.backupPath,
        sidecar: state.sidecarPath,
        repaired: state.repairedPath,
        lastValidPreRecoveryWatermark: state.lastValidPreRecoveryWatermark,
        postRecoveryWatermark: repairedFold.watermark
      }
    });
    state = updateRecovery(paths, state, { recoveryEventId: recoveryEvent.eventId, currentStage: 'recovery-event-written' });
    fail('after-recovery-activity');
  }

  if (!state.activeIndexWatermark) {
    fail('before-index-rebuild');
    const index = installIndexFromFold(paths, foldRegistry(paths), { force: true });
    state = updateRecovery(paths, state, { activeIndexWatermark: index.registry, currentStage: 'index-rebuilt' });
    fail('after-index-rebuild');
  }

  if (!state.finalAuditOk) {
    fail('before-final-audit');
    verifyHash(state.backupPath, state.originalRegistryHash, 'backup');
    verifyHash(state.sidecarPath, state.sidecarHash, 'sidecar');
    verifyHash(state.repairedPath, state.repairedHash, 'repaired registry');
    verifyHash(paths.registry, state.installedRegistryHash, 'installed registry');
    const finalAudit = auditRegistry(dir, { ignoreRecovery: true });
    if (!finalAudit.ok) {
      throw new Error(`recovery final audit failed: ${JSON.stringify(finalAudit.activeIndex?.issues || finalAudit.registry?.corrupt || finalAudit.activity?.issues)}`);
    }
    state = updateRecovery(paths, state, { finalAuditOk: true, finalAuditWatermark: finalAudit.registry.watermark, currentStage: 'final-audit-complete' });
  }

  state = writeRecoveryState(paths, { ...state, currentStage: 'completed', completedAt: new Date().toISOString(), updatedAt: new Date().toISOString(), lastError: null });
  return {
    backup: state.backupPath,
    sidecar: state.sidecarPath,
    repaired: state.repairedPath,
    originalHash: state.originalRegistryHash,
    sidecarHash: state.sidecarHash,
    repairedHash: state.repairedHash,
    installedRegistryHash: state.installedRegistryHash,
    lastValidPreRecoveryWatermark: state.lastValidPreRecoveryWatermark,
    postRecoveryWatermark: state.validPrefixWatermark,
    activeIndexWatermark: state.activeIndexWatermark,
    audit: auditRegistry(dir),
    recoveryEvent: { event: 'registry_recovered', eventId: state.recoveryEventId },
    recoveryState: state,
    recoveryStateFile: recoveryStateFile(paths)
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
    fs.mkdirSync(paths.recovery, { recursive: true, mode: 0o700 });
    let state = loadRecoveryState(paths);
    if (!state) {
      const before = fs.existsSync(paths.registry) ? fs.readFileSync(paths.registry) : Buffer.alloc(0);
      const originalHash = sha256(before);
      const fold = foldRegistry(paths);
      if (fold.health !== 'critical') throw new Error('registry is not CRITICAL; recovery refused');
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      const recoveryId = `rec-${crypto.randomBytes(8).toString('hex')}`;
      state = {
        schema: 'kraken-memory/recovery-state/v1',
        recoveryId,
        originalRegistryHash: originalHash,
        lastValidPreRecoveryWatermark: fold.watermark,
        validPrefixWatermark: null,
        backupPath: path.join(paths.recovery, `memory-registry.${stamp}.${recoveryId}.backup.jsonl`),
        backupHash: null,
        sidecarPath: path.join(paths.recovery, `memory-registry.${stamp}.${recoveryId}.corrupt-bytes`),
        sidecarHash: null,
        repairedPath: path.join(paths.recovery, `memory-registry.${stamp}.${recoveryId}.repaired.jsonl`),
        repairedHash: null,
        installedRegistryHash: null,
        currentStage: 'started',
        startedAt: new Date().toISOString(),
        completedAt: null,
        updatedAt: new Date().toISOString(),
        actor: options.actor || { kind: 'mem', id: 'memory-cli' },
        lastError: null
      };
      writeRecoveryState(paths, state);
    }
    try {
      return await runRecoveryState(dir, paths, state, fail);
    } catch (error) {
      const latest = loadRecoveryState(paths);
      if (latest) writeRecoveryState(paths, { ...latest, lastError: error.message, updatedAt: new Date().toISOString() });
      throw error;
    }
  }, options.lock);
}
