import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, foldRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { withRegistryLock } from '../lib/lock.mjs';
import { tmpRegistry } from './helpers.mjs';

test('concurrent writers serialize without losing events', async () => {
  const dir = tmpRegistry();
  await Promise.all(Array.from({ length: 10 }, (_, i) => appendRegistryEvent(dir, {
    eventId: `concurrent-${i}`,
    event: 'proposed',
    actor: { kind: 'firstmate', id: `writer-${i}` },
    fields: { summary: `concurrent writer ${i}` }
  })));
  const fold = foldRegistry(dir);
  assert.equal(fold.events.length, 10);
  assert.equal(fold.records.size, 10);
});

test('stale lock recovery reclaims dead owner lock', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  fs.mkdirSync(paths.lock, { recursive: true });
  fs.writeFileSync(path.join(paths.lock, 'owner.json'), JSON.stringify({ pid: 999999, host: os.hostname(), ts: new Date(Date.now() - 60_000).toISOString() }));
  await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'stale lock recovered' }
  }, { lock: { staleMs: 1, waitMs: 100 } });
  assert.equal(foldRegistry(dir).events.length, 1);
});

test('active lock refuses competing writer after timeout', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await assert.rejects(
    withRegistryLock(paths.lock, async () => {
      await appendRegistryEvent(dir, {
        event: 'proposed',
        actor: { kind: 'firstmate', id: 'test' },
        fields: { summary: 'competing writer' }
      }, { lock: { waitMs: 50 } });
    }),
    /registry lock is held/
  );
});
