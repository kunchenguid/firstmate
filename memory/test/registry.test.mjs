import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, snapshotRegistry } from '../lib/registry.mjs';
import { registryPaths } from '../lib/paths.mjs';
import { sha256 } from '../lib/hash.mjs';
import { tmpRegistry } from './helpers.mjs';

test('append/fold validates schema, status state machine, idempotency, and A7 watermark', async () => {
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
    validation: { method: 'test', by: 'captain' }
  });
  const index = buildActiveIndex(dir);
  assert.equal(index.recordCount, 1);
  assert.equal(index.registry.seq, 2);
  assert.equal(index.registry.eventId, 'evt-2');
  assert.match(index.records[0].contentHash, /^[0-9a-f]{64}$/);
  const audit = auditRegistry(dir);
  assert.equal(audit.registry.watermark.eventId, audit.activeIndex.watermark.eventId);
  assert.equal(audit.records.statusCounts.active, 1);
});

test('m7 fixture tests 3-6 and 8: only active records enter active index and budget projection is bounded', async () => {
  const dir = tmpRegistry();
  for (const [n, finalEvent] of [['0001', null], ['0002', 'superseded'], ['0003', 'retired'], ['0004', 'quarantined']]) {
    await appendRegistryEvent(dir, {
      eventId: `p-${n}`,
      event: 'proposed',
      memId: `MEM-${n}`,
      actor: { kind: 'firstmate', id: 'test' },
      fields: { summary: `record ${n}`, keywords: ['fixture'] }
    });
    if (n !== '0004') {
      await appendRegistryEvent(dir, {
        eventId: `a-${n}`,
        event: 'activated',
        memId: `MEM-${n}`,
        actor: { kind: 'captain', id: 'test' },
        evidence: [{ type: 'test', ref: n }],
        validation: { method: 'test' }
      });
    }
    if (finalEvent) {
      await appendRegistryEvent(dir, {
        eventId: `f-${n}`,
        event: finalEvent,
        memId: `MEM-${n}`,
        actor: { kind: 'firstmate', id: 'test' },
        reason: 'fixture'
      });
    }
  }
  const index = buildActiveIndex(dir);
  assert.deepEqual(index.records.map((row) => row.id), ['MEM-0001']);
  assert.equal(JSON.stringify(index).includes('MEM-0002'), false);
  assert.equal(JSON.stringify(index).includes('MEM-0003'), false);
  assert.equal(JSON.stringify(index).includes('MEM-0004'), false);
  assert.ok(JSON.stringify(index).length < 12000);
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

test('invalid activation transition is refused', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, {
    event: 'proposed',
    memId: 'MEM-0001',
    actor: { kind: 'firstmate', id: 'test' },
    fields: { summary: 'candidate cannot self-activate without evidence' }
  });
  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'activated',
      memId: 'MEM-0001',
      actor: { kind: 'firstmate', id: 'test' },
      validation: { method: 'test' }
    }),
    /activation requires evidence/
  );
});

test('read-back mismatch is detected and leaves a loud failure', async () => {
  const dir = tmpRegistry();
  await assert.rejects(
    appendRegistryEvent(dir, {
      event: 'proposed',
      actor: { kind: 'firstmate', id: 'test' },
      fields: { summary: 'read-back mismatch fixture' }
    }, { injectReadBackMismatch: true }),
    /read-back validation failed/
  );
  assert.equal(foldRegistry(dir).health, 'ok');
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
