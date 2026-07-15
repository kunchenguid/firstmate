import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, buildActiveIndex, foldRegistry, snapshotRegistry } from '../lib/registry.mjs';
import { sha256 } from '../lib/hash.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { tmpRegistry } from './helpers.mjs';

test('snapshot filename is derived from seq + hash and stays inside the snapshots dir', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'snapshot me' } });
  const { file } = snapshotRegistry(dir);
  const resolved = path.resolve(file);
  assert.equal(path.dirname(resolved), path.resolve(paths.snapshots));
  assert.match(path.basename(resolved), /^registry-\d+-manual-[0-9a-f]{16}\.json$/);
  assert.ok(fs.existsSync(resolved));
  assert.equal(fs.statSync(resolved).mode & 0o777, 0o600);
  const snapshot = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  assert.equal(snapshot.reason, 'manual');
  assert.equal(snapshot.registryHash, snapshot.registry.registryHash);
  assert.match(snapshot.snapshotHash, /^[0-9a-f]{64}$/);
});

test('a hostile event ID cannot traverse out of the snapshots directory', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  // Inject a malicious event ID directly into the ledger.
  await appendRegistryEvent(dir, {
    event: 'proposed',
    eventId: '../../../../tmp/evil-snapshot',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'path traversal fixture' }
  });
  const { file } = snapshotRegistry(dir);
  const resolved = path.resolve(file);
  assert.ok(resolved.startsWith(path.resolve(paths.snapshots) + path.sep), 'snapshot must resolve inside the snapshots dir');
  assert.equal(fs.existsSync('/tmp/evil-snapshot.json'), false);
  assert.match(path.basename(resolved), /^registry-\d+-manual-[0-9a-f]{16}\.json$/);
});

test('snapshot is written atomically (no leftover temp files)', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'atomic snapshot' } });
  snapshotRegistry(dir);
  const leftovers = fs.readdirSync(paths.snapshots).filter((name) => name.includes('.tmp-'));
  assert.deepEqual(leftovers, []);
});

async function appendMany(dir, start, end) {
  for (let i = start; i <= end; i += 1) {
    await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: `snapshot boundary ${i}` } });
  }
}

test('automatic snapshots are created once at every 500-event boundary', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendMany(dir, 1, 499);
  assert.deepEqual(fs.existsSync(paths.snapshots) ? fs.readdirSync(paths.snapshots) : [], []);

  await appendMany(dir, 500, 500);
  const at500 = fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary'));
  assert.equal(at500.length, 1);
  const afterFold = foldRegistry(dir);
  assert.equal(afterFold.watermark.seq, 500);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 1);

  await appendMany(dir, 501, 1000);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-500-event-boundary')).length, 1);
  assert.equal(fs.readdirSync(paths.snapshots).filter((name) => name.includes('automatic-1000-event-boundary')).length, 1);
});

test('explicit index rebuild creates a pre-rebuild snapshot and preserves canonical bytes', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'pre rebuild' } });
  const before = sha256(fs.readFileSync(paths.registry));
  buildActiveIndex(dir);
  const names = fs.readdirSync(paths.snapshots);
  assert.equal(names.filter((name) => name.includes('pre-index-rebuild')).length, 1);
  assert.equal(sha256(fs.readFileSync(paths.registry)), before);
});

test('snapshot-write failure blocks explicit index rebuild', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'snap-test' }, fields: { summary: 'blocked rebuild' } });
  const beforeIndex = fs.existsSync(paths.index) ? fs.readFileSync(paths.index, 'utf8') : null;
  const old = process.env.MEM_SNAPSHOT_FAIL;
  process.env.MEM_SNAPSHOT_FAIL = '1';
  try {
    assert.throws(() => buildActiveIndex(dir), /snapshot failure/);
  } finally {
    if (old === undefined) delete process.env.MEM_SNAPSHOT_FAIL;
    else process.env.MEM_SNAPSHOT_FAIL = old;
  }
  const afterIndex = fs.existsSync(paths.index) ? fs.readFileSync(paths.index, 'utf8') : null;
  assert.equal(afterIndex, beforeIndex);
});
