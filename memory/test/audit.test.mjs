import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { appendRegistryEvent, auditRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { tmpRegistry } from './helpers.mjs';

async function seedActive(dir) {
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'p' }, fields: { summary: 'real summary', body: 'real body' } });
  await appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: { kind: 'captain', id: 'c' }, evidence: [{ type: 'test', ref: 'x' }], validation: { method: 'test' } });
}

function readIndex(dir) {
  return JSON.parse(fs.readFileSync(registryPaths(dir).index, 'utf8'));
}
function writeIndex(dir, index) {
  fs.writeFileSync(registryPaths(dir).index, `${JSON.stringify(index, null, 2)}\n`);
}

test('healthy registry with a matching index audits green', async () => {
  const dir = tmpRegistry();
  await seedActive(dir);
  const audit = auditRegistry(dir);
  assert.equal(audit.ok, true);
  assert.equal(audit.activeIndex.status, 'current');
  assert.deepEqual(audit.activeIndex.issues, []);
});

// Every tamper below must cause audit failure + a diagnostic issue.
const tampers = {
  'registry hash': (idx) => { idx.registry.registryHash = '0'.repeat(64); },
  'record summary content': (idx) => { idx.records[0].summary = 'TAMPERED'; },
  'per-record content hash': (idx) => { idx.records[0].contentHash = 'f'.repeat(64); },
  'record count': (idx) => { idx.recordCount = 99; },
  'watermark seq': (idx) => { idx.registry.seq = 999; },
  'inactive record injected': (idx) => { idx.records.push({ id: 'MEM-9999', summary: 'ghost', contentHash: 'a'.repeat(64) }); idx.recordCount = idx.records.length; },
  'index schema': (idx) => { idx.schema = 'evil/schema/v1'; }
};

for (const [name, mutate] of Object.entries(tampers)) {
  test(`tampering with ${name} fails audit with a nonzero-worthy diagnostic`, async () => {
    const dir = tmpRegistry();
    await seedActive(dir);
    const idx = readIndex(dir);
    mutate(idx);
    writeIndex(dir, idx);
    const audit = auditRegistry(dir);
    assert.equal(audit.ok, false, `audit must fail for tampered ${name}`);
    assert.notEqual(audit.activeIndex.status, 'current');
    assert.ok(audit.activeIndex.issues.length > 0, 'a diagnostic issue must be reported');
  });
}

test('a removed record ID set mismatch fails audit', async () => {
  const dir = tmpRegistry();
  await seedActive(dir);
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0002', actor: { kind: 'firstmate', id: 'p' }, fields: { summary: 'second' } });
  await appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0002', actor: { kind: 'captain', id: 'c' }, evidence: [{ type: 'test', ref: 'y' }], validation: { method: 'test' } });
  const idx = readIndex(dir);
  idx.records = idx.records.filter((r) => r.id !== 'MEM-0002'); // drop a real active record
  // keep recordCount honest to isolate the ID-set / length check
  idx.recordCount = idx.records.length;
  writeIndex(dir, idx);
  const audit = auditRegistry(dir);
  assert.equal(audit.ok, false);
});

test('an invalid (non-JSON) index audits as invalid, not current', async () => {
  const dir = tmpRegistry();
  await seedActive(dir);
  fs.writeFileSync(registryPaths(dir).index, 'not json{');
  const audit = auditRegistry(dir);
  assert.equal(audit.ok, false);
  assert.equal(audit.activeIndex.status, 'invalid');
});
