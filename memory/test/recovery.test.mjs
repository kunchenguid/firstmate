import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, recoverRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { sha256 } from '../lib/hash.mjs';
import { withRegistryLock } from '../lib/lock.mjs';
import { tmpRegistry } from './helpers.mjs';

test('rewritten A20: canonical corruption blocks mutations but reads through last valid event', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, {
    event: 'proposed',
    eventId: 'valid-1',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'valid event before corrupt tail' }
  });
  const originalValid = fs.readFileSync(paths.registry);
  fs.appendFileSync(paths.registry, '{"schema":"kraken-memory/registry-event/v1","eventId":"partial"');
  const originalCorrupt = fs.readFileSync(paths.registry);
  const fold = foldRegistry(dir);
  assert.equal(fold.health, 'critical');
  assert.equal(fold.events.length, 1);
  assert.equal(fold.records.get('MEM-0001').summary, 'valid event before corrupt tail');
  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'proposed',
      actor: { kind: 'firstmate', id: 'test' },
      fields: { summary: 'must not append while critical' }
    }),
    /CRITICAL/
  );
  assert.equal(sha256(fs.readFileSync(paths.registry)), sha256(originalCorrupt));
  const result = await recoverRegistry(dir);
  assert.ok(fs.existsSync(result.backup));
  assert.ok(fs.existsSync(result.sidecar));
  assert.equal(sha256(fs.readFileSync(result.backup)), sha256(originalCorrupt));
  assert.equal(fs.readFileSync(result.sidecar, 'utf8'), '{"schema":"kraken-memory/registry-event/v1","eventId":"partial"');
  assert.equal(fs.readFileSync(paths.registry, 'utf8'), originalValid.toString('utf8'));
  assert.equal(auditRegistry(dir).registry.health, 'ok');
  assert.equal(auditRegistry(dir).activeIndex.status, 'current');
  assert.equal(result.recoveryEvent.event, 'registry_recovered');
});

test('recovery refuses when registry is healthy', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'healthy registry' }
  });
  await assert.rejects(recoverRegistry(dir), /not CRITICAL/);
});

test('recovery refuses while another writer owns the lock', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'valid event before active lock' }
  });
  fs.appendFileSync(paths.registry, '{bad');
  await assert.rejects(
    withRegistryLock(paths.lock, async () => {
      await recoverRegistry(dir, { lock: { waitMs: 100 } });
    }),
    /registry lock is held/
  );
});

test('index rebuild refuses critical registry and never repairs canonical bytes', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'valid before index refusal' }
  });
  fs.appendFileSync(paths.registry, '{bad');
  const before = sha256(fs.readFileSync(paths.registry));
  assert.throws(() => buildActiveIndex(dir), /CRITICAL/);
  assert.equal(sha256(fs.readFileSync(paths.registry)), before);
});
