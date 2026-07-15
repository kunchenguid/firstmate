import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendActivity, activityFile, foldActivity } from '../lib/activity.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { ACTIVITY_MANIFEST_SCHEMA } from '../lib/schema.mjs';
import { tmpRegistry } from './helpers.mjs';

test('activity append is concurrency-safe and updates the segment manifest with counts + hashes', async () => {
  const dir = tmpRegistry();
  const N = 20;
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
  assert.equal(Buffer.compare(before, after.subarray(0, before.length)), 0, 'telemetry file is not repaired by a fold');
});
