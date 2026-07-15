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
  if (!fs.existsSync(file)) return { rows: 0, health: 'ok', corrupt: null, contentHash: sha256(Buffer.alloc(0)) };
  const buffer = fs.readFileSync(file);
  let start = 0;
  let rows = 0;
  let corrupt = null;
  let validEnd = 0;
  for (let i = 0; i < buffer.length; i += 1) {
    if (buffer[i] !== 0x0a) continue;
    const line = buffer.subarray(start, i + 1).toString('utf8');
    if (line.trim() !== '') {
      try {
        JSON.parse(line);
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
    contentHash: sha256(buffer.subarray(0, corrupt ? corrupt.byteOffset : validEnd))
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
  const entry = { segment: name, rows: fold.rows, contentHash: fold.contentHash, health: fold.health, updatedAt: new Date().toISOString() };
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
