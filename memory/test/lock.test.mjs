import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, foldRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { withRegistryLock } from '../lib/lock.mjs';
import { tmpRegistry } from './helpers.mjs';

test('concurrent in-process writers serialize without losing events', async () => {
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

test('init-race: a freshly created lock whose owner is not yet visible is BUSY, never stale', async () => {
  // Reproduces the QA lock race: an old build treated a lock directory with no
  // owner.json as immediately stale and removed a live lock. Even with staleMs=1,
  // a lock younger than the init grace must be waited on, not stolen.
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  fs.mkdirSync(paths.lock, { recursive: true }); // created, owner.json not written yet
  await assert.rejects(
    withRegistryLock(paths.lock, async () => {}, { waitMs: 150, staleMs: 1 }),
    /registry lock is held/
  );
  // The lock we refused to steal is still there.
  assert.equal(fs.existsSync(paths.lock), true);
});

test('stale reclaim removes a lock owned by a provably dead process', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  fs.mkdirSync(paths.lock, { recursive: true });
  fs.writeFileSync(path.join(paths.lock, 'owner.json'), JSON.stringify({ token: 'dead', pid: 999999, host: os.hostname(), ts: new Date(Date.now() - 60_000).toISOString() }));
  await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'stale lock recovered' }
  }, { lock: { staleMs: 1, waitMs: 200 } });
  assert.equal(foldRegistry(dir).events.length, 1);
});

test('stale reclaim does NOT remove a lock owned by a live process', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  fs.mkdirSync(paths.lock, { recursive: true });
  // Owner is this (alive) process, timestamp far in the past.
  fs.writeFileSync(path.join(paths.lock, 'owner.json'), JSON.stringify({ token: 'live', pid: process.pid, host: os.hostname(), ts: new Date(Date.now() - 60_000).toISOString() }));
  await assert.rejects(
    withRegistryLock(paths.lock, async () => {}, { waitMs: 150, staleMs: 1 }),
    /registry lock is held/
  );
  assert.equal(fs.existsSync(paths.lock), true);
});

test('release verifies the ownership token and never deletes a reclaimed lock', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await withRegistryLock(paths.lock, async () => {
    // Simulate our lock being stale-reclaimed and re-acquired by another owner
    // while we were running: owner.json now carries a different token.
    fs.writeFileSync(path.join(paths.lock, 'owner.json'), JSON.stringify({ token: 'other-owner', pid: process.pid, host: os.hostname(), ts: new Date().toISOString() }));
  });
  // Our release must NOT have deleted the other owner's live lock.
  assert.equal(fs.existsSync(paths.lock), true);
  assert.equal(JSON.parse(fs.readFileSync(path.join(paths.lock, 'owner.json'), 'utf8')).token, 'other-owner');
});

test('release refuses to delete a lock when owner metadata is missing', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await withRegistryLock(paths.lock, async () => {
    fs.rmSync(path.join(paths.lock, 'owner.json'), { force: true });
  });
  assert.equal(fs.existsSync(paths.lock), true);
});

test('active lock refuses a competing writer after the wait timeout', async () => {
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
