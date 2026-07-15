import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, snapshotRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { sha256 } from '../lib/hash.mjs';
import { tmpRegistry } from './helpers.mjs';

async function propose(dir, memId, fields, extra = {}) {
  return appendRegistryEvent(dir, { event: 'proposed', memId, actor: { kind: 'firstmate', id: 'proposer' }, fields, ...extra });
}

async function activate(dir, memId, extra = {}) {
  return appendRegistryEvent(dir, {
    event: 'activated',
    memId,
    actor: { kind: 'captain', id: 'captain' },
    evidence: [{ type: 'test', ref: memId }],
    validation: { method: 'test', by: 'captain', ref: `auth-${memId}` },
    ...extra
  });
}

test('append/fold validates schema, idempotency, and A7 watermark', async () => {
  const dir = tmpRegistry();
  const first = await appendRegistryEvent(dir, {
    eventId: 'evt-1',
    event: 'proposed',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: {
      summary: 'Idle done crew panes re-fire stale watcher alarms',
      body: 'Fold or land the work, then run teardown.',
      scope: 'fleet',
      projects: ['*'],
      taskKinds: ['dispatch'],
      keywords: ['idle', 'done', 'stale', 'watcher'],
      riskClass: 'critical'
    },
    evidence: [{ type: 'report', ref: 'data/memory-loop-audit-m4/report.md' }]
  });
  assert.equal(first.skipped, false);
  const duplicate = await appendRegistryEvent(dir, {
    eventId: 'evt-1',
    event: 'proposed',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'duplicate' }
  });
  assert.equal(duplicate.skipped, true);
  await appendRegistryEvent(dir, {
    eventId: 'evt-2',
    event: 'activated',
    memId: 'MEM-0001',
    actor: { kind: 'captain', id: 'test' },
    evidence: [{ type: 'test', ref: 'memory/test/registry.test.mjs' }],
    validation: { method: 'test', by: 'captain', ref: 'captain-auth-evt-2' }
  });
  const index = buildActiveIndex(dir);
  assert.equal(index.recordCount, 1);
  assert.equal(index.registry.seq, 2);
  assert.equal(index.registry.eventId, 'evt-2');
  assert.match(index.records[0].contentHash, /^[0-9a-f]{64}$/);
  assert.equal(index.records[0].memoryType, 'factual'); // required projected memory type
  assert.equal(index.records[0].generation, 2); // per-record generation watermark
  const audit = auditRegistry(dir);
  assert.equal(audit.registry.watermark.eventId, audit.activeIndex.watermark.eventId);
  assert.equal(audit.activeIndex.status, 'current');
  assert.equal(audit.records.statusCounts.active, 1);
});

test('m7 fixture tests 3-6, 8: only active records enter the active index (with valid supersession)', async () => {
  const dir = tmpRegistry();
  // MEM-0001 active; MEM-0002 superseded by an active MEM-0005; MEM-0003 retired;
  // MEM-0004 quarantined. Only MEM-0001 and MEM-0005 are active.
  await propose(dir, 'MEM-0001', { summary: 'active record one', keywords: ['fixture'] });
  await activate(dir, 'MEM-0001');
  await propose(dir, 'MEM-0002', { summary: 'to be superseded' });
  await activate(dir, 'MEM-0002');
  await propose(dir, 'MEM-0003', { summary: 'to be retired' });
  await activate(dir, 'MEM-0003');
  await appendRegistryEvent(dir, { event: 'retired', memId: 'MEM-0003', actor: { kind: 'firstmate', id: 'x' }, reason: 'fixture' });
  await propose(dir, 'MEM-0004', { summary: 'to be quarantined' });
  await appendRegistryEvent(dir, { event: 'quarantined', memId: 'MEM-0004', actor: { kind: 'firstmate', id: 'x' }, reason: 'fixture' });
  await propose(dir, 'MEM-0005', { summary: 'successor record' });
  await activate(dir, 'MEM-0005');
  await appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0002', successor: 'MEM-0005', actor: { kind: 'firstmate', id: 'x' }, reason: 'fixture' });

  const index = buildActiveIndex(dir);
  assert.deepEqual(index.records.map((row) => row.id).sort(), ['MEM-0001', 'MEM-0005']);
  // No superseded/retired/quarantined record is projected as an active record.
  const activeIds = new Set(index.records.map((row) => row.id));
  for (const excluded of ['MEM-0002', 'MEM-0003', 'MEM-0004']) {
    assert.equal(activeIds.has(excluded), false, `${excluded} must not be an active record`);
  }

  // Supersession lineage is non-dangling and updated on both sides.
  const fold = foldRegistry(dir);
  assert.equal(fold.records.get('MEM-0002').supersededBy, 'MEM-0005');
  assert.ok(fold.records.get('MEM-0005').supersedes.includes('MEM-0002'));
});

test('passthrough fields cannot override lifecycle internals or active-index filtering', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001', { summary: 'hostile fields fixture' });
  await activate(dir, 'MEM-0001');
  await appendRegistryEvent(dir, {
    event: 'retired',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    reason: 'hostile passthrough fixture',
    fields: {
      status: 'active',
      id: 'MEM-9999',
      lastEventSeq: 999,
      eventIds: ['evil'],
      supersededBy: 'MEM-9998',
      validTo: null
    }
  });

  const fold = foldRegistry(dir);
  const record = fold.records.get('MEM-0001');
  assert.equal(record.id, 'MEM-0001');
  assert.equal(record.status, 'retired');
  assert.equal(record.lastEventSeq, 3);
  assert.deepEqual(record.eventIds, fold.events.map((event) => event.eventId));
  assert.equal(record.supersededBy, null);
  assert.match(record.validTo, /^\d{4}-\d{2}-\d{2}T/);

  const index = buildActiveIndex(dir);
  assert.equal(index.recordCount, 0);
  assert.deepEqual(index.records, []);
  const audit = auditRegistry(dir);
  assert.equal(audit.records.statusCounts.retired, 1);
  assert.equal(audit.records.active, 0);
  assert.equal(audit.activeIndex.status, 'current');
});

test('A11 index rebuild and snapshot preserve canonical registry bytes', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, {
    event: 'proposed',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'Patch equivalence requires current-code verification' }
  });
  const paths = registryPaths(dir);
  const before = sha256(fs.readFileSync(paths.registry));
  buildActiveIndex(dir);
  snapshotRegistry(dir);
  const after = sha256(fs.readFileSync(paths.registry));
  assert.equal(after, before);
});

test('sparse update preserves every omitted field (destructive-reset regression)', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, {
    event: 'proposed',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: {
      summary: 'original summary',
      body: 'original body',
      memoryType: 'procedural',
      scope: 'project',
      projects: ['firstmate'],
      taskKinds: ['dispatch'],
      keywords: ['recovery'],
      aliases: ['a1'],
      entities: ['e1'],
      commands: ['c1'],
      failureModes: ['f1'],
      relatedTerms: ['r1'],
      confidence: 'observed',
      riskClass: 'critical'
    },
    guard_linked: true
  });
  const before = { ...foldRegistry(dir).records.get('MEM-0001') };
  // summary-only update
  await appendRegistryEvent(dir, { event: 'updated', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'updated summary only' } });
  const after = foldRegistry(dir).records.get('MEM-0001');
  assert.equal(after.summary, 'updated summary only');
  for (const field of ['body', 'memoryType', 'scope', 'projects', 'taskKinds', 'keywords', 'aliases', 'entities', 'commands', 'failureModes', 'relatedTerms', 'confidence', 'riskClass', 'guardLinked']) {
    assert.deepEqual(after[field], before[field], `field ${field} must be preserved on a sparse update`);
  }
});

test('active index projection does not regress behind a newer installed index', async () => {
  const dir = tmpRegistry();
  const paths = registryPaths(dir);
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'firstmate', id: 'test' }, fields: { summary: 'r1' } });
  await activate(dir, 'MEM-0001');
  buildActiveIndex(dir);
  // Install a fake NEWER index (seq far ahead). A rebuild from the older registry
  // must not overwrite it.
  const fake = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
  fake.registry = { ...fake.registry, seq: 999 };
  fs.writeFileSync(paths.index, `${JSON.stringify(fake, null, 2)}\n`);
  buildActiveIndex(dir);
  const stillInstalled = JSON.parse(fs.readFileSync(paths.index, 'utf8'));
  assert.equal(stillInstalled.registry.seq, 999, 'older projection must not overwrite a newer installed index');
});

test('read-back mismatch is detected and surfaces a loud failure', async () => {
  const dir = tmpRegistry();
  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'proposed',
      actor: { kind: 'firstmate', id: 'test' },
      fields: { summary: 'read-back mismatch fixture' }
    }, { injectReadBackMismatch: true }),
    /read-back validation failed/
  );
});

test('permission failure surfaces as an append error', async (t) => {
  if (process.getuid?.() === 0) {
    t.skip('root can write through chmod fixtures');
    return;
  }
  const dir = tmpRegistry();
  fs.mkdirSync(dir, { recursive: true });
  fs.chmodSync(dir, 0o500);
  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'proposed',
      actor: { kind: 'firstmate', id: 'test' },
      fields: { summary: 'permission fixture' }
    })
  );
  fs.chmodSync(dir, 0o700);
});
