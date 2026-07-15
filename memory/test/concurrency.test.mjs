import assert from 'node:assert/strict';
import test from 'node:test';
import { auditRegistry, foldRegistry } from '../lib/registry.mjs';
import { spawnMemIn, tmpRegistry } from './helpers.mjs';

// True cross-process stress: launch many INDEPENDENT `mem` OS processes that all
// contend for the registry lock. This is the reproduction the QA report used
// (40 processes -> 13 succeeded, registry CRITICAL). With the hardened lock it
// must fold healthy with every command succeeding and every ID unique.
test('subprocess concurrency: 40 independent mem processes all succeed and fold healthy', async () => {
  const dir = tmpRegistry();
  const N = 40;
  const results = await Promise.all(
    Array.from({ length: N }, (_, i) => spawnMemIn(dir, ['propose', '--summary', `stress ${i}`, '--json']))
  );

  const succeeded = results.filter((r) => r.code === 0).length;
  assert.equal(succeeded, N, `every requested command must succeed (got ${succeeded}/${N})`);

  const fold = foldRegistry(dir);
  assert.equal(fold.health, 'ok', 'registry must fold healthy');
  assert.equal(fold.events.length, N, 'physical event count equals requested writes');
  assert.equal(new Set(fold.events.map((e) => e.eventId)).size, N, 'all event IDs are unique');
  assert.equal(new Set([...fold.records.keys()]).size, N, 'all memory IDs are unique');

  const audit = auditRegistry(dir);
  assert.equal(audit.registry.watermark.seq, N, 'watermark seq matches complete registry');
  assert.equal(audit.activeIndex.status, 'current', 'final active index matches the full registry watermark and hash');
  assert.deepEqual(audit.activeIndex.issues, []);
});
