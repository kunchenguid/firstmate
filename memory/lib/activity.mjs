import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { ACTIVITY_MANIFEST_SCHEMA, ACTIVITY_SCHEMA, validateActivityEvent } from './schema.mjs';
import { registryPaths } from './paths.mjs';
import { sha256 } from './hash.mjs';
import { withRegistryLock } from './lock.mjs';

export function activityFile(dir, date = new Date()) {
  const ym = date.toISOString().slice(0, 7);
  return path.join(dir, `memory-activity-${ym}.jsonl`);
}

function fsyncDir(dir) {
  const fd = fs.openSync(dir, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

// Baseline activity-ledger fold. Activity is telemetry, so a corrupt trailing
// row is reported (rows/health/corrupt) but the file is left untouched - the
// lighter skip-and-sidecar posture the amendment reserves for telemetry.
export function foldActivity(file) {
  if (!fs.existsSync(file)) return { rows: 0, health: 'ok', corrupt: null, contentHash: sha256(Buffer.alloc(0)), firstTs: null, lastTs: null, schemaVersion: 1, eventIds: [] };
  const buffer = fs.readFileSync(file);
  let start = 0;
  let rows = 0;
  let corrupt = null;
  let validEnd = 0;
  let firstTs = null;
  let lastTs = null;
  let schemaVersion = null;
  const eventIds = [];
  const seen = new Set();
  for (let i = 0; i < buffer.length; i += 1) {
    if (buffer[i] !== 0x0a) continue;
    const line = buffer.subarray(start, i + 1).toString('utf8');
    if (line.trim() !== '') {
      try {
        const row = validateActivityEvent(JSON.parse(line));
        if (seen.has(row.eventId)) {
          corrupt = { line: rows + 1, reason: `duplicate activity event ID: ${row.eventId}`, byteOffset: start };
          break;
        }
        seen.add(row.eventId);
        eventIds.push(row.eventId);
        firstTs ??= row.ts;
        lastTs = row.ts;
        schemaVersion ??= row.schemaVersion;
        rows += 1;
      } catch (error) {
        corrupt = { line: rows + 1, reason: error.message, byteOffset: start };
        break;
      }
    }
    validEnd = i + 1;
    start = i + 1;
  }
  if (!corrupt && start < buffer.length) {
    corrupt = { line: rows + 1, reason: 'unterminated trailing activity row', byteOffset: start };
  }
  return {
    rows,
    health: corrupt ? 'degraded' : 'ok',
    corrupt,
    contentHash: sha256(buffer.subarray(0, corrupt ? corrupt.byteOffset : validEnd)),
    firstTs,
    lastTs,
    schemaVersion: schemaVersion ?? 1,
    eventIds
  };
}

function updateManifest(dir, file) {
  const paths = registryPaths(dir);
  let manifest = { schema: ACTIVITY_MANIFEST_SCHEMA, updatedAt: new Date().toISOString(), segments: [] };
  try {
    const existing = JSON.parse(fs.readFileSync(paths.manifest, 'utf8'));
    if (existing && Array.isArray(existing.segments)) manifest = existing;
  } catch {
    // absent or unreadable manifest is rebuilt from scratch
  }
  const name = path.basename(file);
  const fold = foldActivity(file);
  const entry = { segment: name, rows: fold.rows, contentHash: fold.contentHash, health: fold.health, firstTs: fold.firstTs, lastTs: fold.lastTs, schemaVersion: fold.schemaVersion, updatedAt: new Date().toISOString() };
  manifest.schema = ACTIVITY_MANIFEST_SCHEMA;
  manifest.updatedAt = entry.updatedAt;
  manifest.segments = [...manifest.segments.filter((seg) => seg.segment !== name), entry].sort((a, b) => a.segment.localeCompare(b.segment));
  const tmp = path.join(dir, `.activity-manifest.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
  const fd = fs.openSync(tmp, 'w', 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(manifest, null, 2)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, paths.manifest);
  fsyncDir(dir);
  return entry;
}

export function auditActivity(dir) {
  const paths = registryPaths(dir);
  const issues = [];
  let manifest = null;
  if (fs.existsSync(paths.manifest)) {
    try {
      manifest = JSON.parse(fs.readFileSync(paths.manifest, 'utf8'));
    } catch (error) {
      issues.push(`activity manifest is not valid JSON: ${error.message}`);
    }
  }
  const activityFiles = fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((name) => /^memory-activity-\d{4}-\d{2}\.jsonl$/.test(name)).sort()
    : [];
  const manifestSegments = manifest?.segments;
  if (manifest && manifest.schema !== ACTIVITY_MANIFEST_SCHEMA) issues.push('activity manifest schema mismatch');
  if (manifest && !Array.isArray(manifestSegments)) issues.push('activity manifest segments missing');
  if (!manifest && activityFiles.length > 0) issues.push('activity manifest missing');

  const byName = new Map(Array.isArray(manifestSegments) ? manifestSegments.map((entry) => [entry.segment, entry]) : []);
  const seenIds = new Set();
  const segments = [];
  for (const name of new Set([...activityFiles, ...byName.keys()])) {
    const file = path.join(dir, name);
    const entry = byName.get(name);
    if (!fs.existsSync(file)) {
      issues.push(`activity segment missing: ${name}`);
      segments.push({ segment: name, status: 'missing' });
      continue;
    }
    const fold = foldActivity(file);
    const segmentIssues = [];
    if (fold.health !== 'ok') segmentIssues.push(`activity segment degraded: ${fold.corrupt?.reason}`);
    for (const id of fold.eventIds) {
      if (seenIds.has(id)) segmentIssues.push(`duplicate activity event ID across segments: ${id}`);
      seenIds.add(id);
    }
    if (!entry) {
      segmentIssues.push(`activity segment absent from manifest: ${name}`);
    } else {
      if (entry.rows !== fold.rows) segmentIssues.push(`activity segment row count mismatch: ${name}`);
      if (entry.contentHash !== fold.contentHash) segmentIssues.push(`activity segment hash mismatch: ${name}`);
      if ((entry.firstTs ?? null) !== (fold.firstTs ?? null)) segmentIssues.push(`activity segment firstTs mismatch: ${name}`);
      if ((entry.lastTs ?? null) !== (fold.lastTs ?? null)) segmentIssues.push(`activity segment lastTs mismatch: ${name}`);
      if (Number(entry.schemaVersion) !== Number(fold.schemaVersion)) segmentIssues.push(`activity segment schemaVersion mismatch: ${name}`);
    }
    issues.push(...segmentIssues);
    segments.push({ segment: name, rows: fold.rows, health: fold.health, contentHash: fold.contentHash, firstTs: fold.firstTs, lastTs: fold.lastTs, schemaVersion: fold.schemaVersion, issues: segmentIssues });
  }
  return {
    path: paths.manifest,
    health: issues.length ? 'degraded' : 'ok',
    issues,
    segments
  };
}

// Provenance: this activity ledger is original FirstMate Runtime code (not ported
// from Fleet Bridge). It reuses this package's own withRegistryLock append/fsync
// discipline so its durability guarantees match the canonical registry writer.
//
// Cross-process append under a dedicated activity lock (separate from the
// registry mutation lock so activity telemetry never contends with canonical
// writes), fsync, then refresh the segment manifest with row count + content
// hash under the same lock.
export async function appendActivity(dir, event, options = {}) {
  const paths = registryPaths(dir);
  return withRegistryLock(paths.activityLock, async () => {
    fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
    const row = validateActivityEvent({
      schema: ACTIVITY_SCHEMA,
      schemaVersion: 1,
      eventId: event.eventId || crypto.randomUUID(),
      ts: event.ts || new Date().toISOString(),
      actor: { kind: 'mem', id: 'memory-cli' },
      detail: {},
      ...event
    });
    const file = activityFile(dir, new Date(row.ts));
    const line = `${JSON.stringify(row)}\n`;
    const fd = fs.openSync(file, 'a', 0o600);
    try {
      fs.writeFileSync(fd, line);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fsyncDir(dir);
    updateManifest(dir, file);
    return row;
  }, options.lock);
}
