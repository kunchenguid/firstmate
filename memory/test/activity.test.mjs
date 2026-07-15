import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendActivity, activityFile, auditActivity, foldActivity } from '../lib/activity.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { ACTIVITY_MANIFEST_SCHEMA } from '../lib/schema.mjs';
import { tmpRegistry } from './helpers.mjs';

test('activity append is concurrency-safe and updates the segment manifest with counts + hashes', async () => {
  const dir = tmpRegistry();
  const N = 40;
  await Promise.all(Array.from({ length: N }, (_, i) => appendActivity(dir, { event: 'test_event', detail: { i } })));
  const file = activityFile(dir);
  const fold = foldActivity(file);
  assert.equal(fold.rows, N, 'every concurrent activity append is recorded');
  assert.equal(fold.health, 'ok');

  const manifest = JSON.parse(fs.readFileSync(registryPaths(dir).manifest, 'utf8'));
  assert.equal(manifest.schema, ACTIVITY_MANIFEST_SCHEMA);
  const segment = manifest.segments.find((s) => s.segment === path.basename(file));
  assert.ok(segment, 'manifest must record the monthly segment');
  assert.equal(segment.rows, N);
  assert.match(segment.contentHash, /^[0-9a-f]{64}$/);
  assert.ok(segment.firstTs);
  assert.ok(segment.lastTs);
  assert.equal(segment.schemaVersion, 1);
  assert.equal(auditActivity(dir).health, 'ok');
});

test('activity segment naming is monthly', () => {
  const dir = tmpRegistry();
  const file = activityFile(dir, new Date('2026-03-15T00:00:00.000Z'));
  assert.equal(path.basename(file), 'memory-activity-2026-03.jsonl');
});

test('activity fold reports a corrupt trailing row without mutating the telemetry file', async () => {
  const dir = tmpRegistry();
  await appendActivity(dir, { event: 'ok_event', detail: {} });
  const file = activityFile(dir);
  const before = fs.readFileSync(file);
  fs.appendFileSync(file, '{partial-activity');
  const after = fs.readFileSync(file);
  const fold = foldActivity(file);
  assert.equal(fold.rows, 1, 'valid rows still counted');
  assert.equal(fold.health, 'degraded');
  assert.ok(fold.corrupt);
  assert.equal(auditActivity(dir).health, 'degraded');
  assert.equal(Buffer.compare(before, after.subarray(0, before.length)), 0, 'telemetry file is not repaired by a fold');
});

test('activity fold rejects well-formed JSON that violates the activity schema', () => {
  const dir = tmpRegistry();
  const file = activityFile(dir);
  fs.writeFileSync(file, '{"not":"an activity event"}\n');
  const fold = foldActivity(file);
  assert.equal(fold.rows, 0);
  assert.equal(fold.health, 'degraded');
  assert.match(fold.corrupt.reason, /schema|required|Invalid literal|eventId/i);
});

test('activity fold rejects missing fields, unsupported schema versions, invalid actors, and duplicate IDs', () => {
  const dir = tmpRegistry();
  const file = activityFile(dir);
  const base = { schema: 'kraken-memory/activity-event/v1', schemaVersion: 1, eventId: 'dup', ts: '2026-01-01T00:00:00.000Z', event: 'ok', actor: { kind: 'mem', id: 'a' }, detail: {} };
  fs.writeFileSync(file, `${JSON.stringify(base)}\n${JSON.stringify({ ...base })}\n`);
  assert.match(foldActivity(file).corrupt.reason, /duplicate activity event ID/);

  fs.writeFileSync(file, `${JSON.stringify({ ...base, schemaVersion: 99, eventId: 'bad-version' })}\n`);
  assert.match(foldActivity(file).corrupt.reason, /unsupported activity schemaVersion/);

  fs.writeFileSync(file, `${JSON.stringify({ ...base, eventId: 'missing-event' })}\n`.replace('"event":"ok",', ''));
  assert.equal(foldActivity(file).health, 'degraded');

  fs.writeFileSync(file, `${JSON.stringify({ ...base, eventId: 'bad-actor', actor: { kind: '' } })}\n`);
  assert.equal(foldActivity(file).health, 'degraded');
});

test('activity audit detects manifest row count, hash, schema, and missing-segment tampering', async () => {
  const dir = tmpRegistry();
  await appendActivity(dir, { event: 'ok_event', detail: {} });
  const manifestPath = registryPaths(dir).manifest;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

  const rowTamper = structuredClone(manifest);
  rowTamper.segments[0].rows += 1;
  fs.writeFileSync(manifestPath, `${JSON.stringify(rowTamper, null, 2)}\n`);
  assert.ok(auditActivity(dir).issues.some((issue) => issue.includes('row count mismatch')));

  const hashTamper = structuredClone(manifest);
  hashTamper.segments[0].contentHash = '0'.repeat(64);
  fs.writeFileSync(manifestPath, `${JSON.stringify(hashTamper, null, 2)}\n`);
  assert.ok(auditActivity(dir).issues.some((issue) => issue.includes('hash mismatch')));

  const schemaTamper = structuredClone(manifest);
  schemaTamper.segments[0].schemaVersion = 99;
  fs.writeFileSync(manifestPath, `${JSON.stringify(schemaTamper, null, 2)}\n`);
  assert.ok(auditActivity(dir).issues.some((issue) => issue.includes('schemaVersion mismatch')));

  const missing = structuredClone(manifest);
  missing.segments[0].segment = 'memory-activity-2099-01.jsonl';
  fs.writeFileSync(manifestPath, `${JSON.stringify(missing, null, 2)}\n`);
  assert.ok(auditActivity(dir).issues.some((issue) => issue.includes('activity segment missing')));
});
