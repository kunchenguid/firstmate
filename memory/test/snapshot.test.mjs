import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, snapshotRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { tmpRegistry } from './helpers.mjs';

test('snapshot filename is derived from seq + hash and stays inside the snapshots dir', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'snapshot me' } });
  const { file } = snapshotRegistry(dir);
  const resolved = path.resolve(file);
  assert.equal(path.dirname(resolved), path.resolve(paths.snapshots));
  assert.match(path.basename(resolved), /^registry-\d+-[0-9a-f]{16}\.json$/);
  assert.ok(fs.existsSync(resolved));
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
  assert.match(path.basename(resolved), /^registry-\d+-[0-9a-f]{16}\.json$/);
});

test('snapshot is written atomically (no leftover temp files)', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'atomic snapshot' } });
  snapshotRegistry(dir);
  const leftovers = fs.readdirSync(paths.snapshots).filter((name) => name.includes('.tmp-'));
  assert.deepEqual(leftovers, []);
});
