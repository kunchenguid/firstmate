import assert from 'node:assert/strict';
import test from 'node:test';
import { appendRegistryEvent, foldRegistry } from '../lib/registry.mjs';
import { tmpRegistry } from './helpers.mjs';

const firstmate = { kind: 'firstmate', id: 'fm' };
const captain = { kind: 'captain', id: 'captain' };

async function propose(dir, memId, fields = {}, extra = {}) {
  return appendRegistryEvent(dir, { event: 'proposed', memId, actor: firstmate, fields: { summary: `${memId} summary`, ...fields }, ...extra });
}
async function activate(dir, memId, actor = captain, extra = {}) {
  return appendRegistryEvent(dir, { event: 'activated', memId, actor, evidence: [{ type: 'test', ref: memId }], validation: { method: 'test' }, ...extra });
}

test('m7-17 independent high-impact activation: proposer cannot self-activate dispatch guidance', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, fields: { summary: 'dispatch guidance', taskKinds: ['dispatch'] } });
  // Same actor, high-impact task kind, no captain authority -> refused.
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: { kind: 'agent', id: 'same-agent' }, evidence: [{ type: 'test', ref: 'self' }], validation: { method: 'qa' } }),
    /high-impact activation requires an independent activator or captain authority/
  );
  // An independent activator succeeds.
  await activate(dir, 'MEM-0001', { kind: 'agent', id: 'other-agent' });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('captain authority may activate high-impact memory even as the proposer', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: captain, fields: { summary: 'governance rule', taskKinds: ['governance'] } });
  await activate(dir, 'MEM-0001', captain);
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('non-high-impact memory may be activated by its proposer', async () => {
  const dir = tmpRegistry();
  await appendRegistryEvent(dir, { event: 'proposed', memId: 'MEM-0001', actor: { kind: 'agent', id: 'a' }, fields: { summary: 'ordinary note' } });
  await activate(dir, 'MEM-0001', { kind: 'agent', id: 'a' });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('quarantined -> active only via revalidate with evidence, never via ordinary activate', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  await appendRegistryEvent(dir, { event: 'quarantined', memId: 'MEM-0001', actor: firstmate, reason: 'suspect' });
  await assert.rejects(activate(dir, 'MEM-0001'), /illegal transition: quarantined --activated/);
  // revalidate requires evidence + validation
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'revalidated', memId: 'MEM-0001', actor: captain, validation: { method: 'test' } }),
    /requires.*evidence/i
  );
  await appendRegistryEvent(dir, { event: 'revalidated', memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 're' }], validation: { method: 'test' } });
  assert.equal(foldRegistry(dir).records.get('MEM-0001').status, 'active');
});

test('supersession requires an existing active successor and is non-dangling', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  // No successor supplied -> refused at schema level.
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', actor: firstmate }),
    /superseded event requires a successor/
  );
  // Successor does not exist -> refused.
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-9999', actor: firstmate }),
    /successor not found/
  );
  // Successor exists but is only a candidate -> refused.
  await propose(dir, 'MEM-0002');
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0002', actor: firstmate }),
    /successor must be active/
  );
  // Valid supersession updates both sides.
  await activate(dir, 'MEM-0002');
  await appendRegistryEvent(dir, { event: 'superseded', memId: 'MEM-0001', successor: 'MEM-0002', actor: firstmate });
  const fold = foldRegistry(dir);
  assert.equal(fold.records.get('MEM-0001').status, 'superseded');
  assert.equal(fold.records.get('MEM-0001').supersededBy, 'MEM-0002');
  assert.ok(fold.records.get('MEM-0002').supersedes.includes('MEM-0001'));
});

test('candidate cannot self-activate without validation evidence', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'activated', memId: 'MEM-0001', actor: firstmate, validation: { method: 'test' } }),
    /requires.*evidence/i
  );
});

test('terminal states are terminal: no ordinary transition revives them, canonical state unchanged', async () => {
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await activate(dir, 'MEM-0001');
  await appendRegistryEvent(dir, { event: 'retired', memId: 'MEM-0001', actor: firstmate, reason: 'done' });

  const seqBefore = foldRegistry(dir).watermark.seq;
  for (const event of ['activated', 'updated', 'quarantined', 'revalidated']) {
    await assert.rejects(
      appendRegistryEvent(dir, { event, memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 'x' }], validation: { method: 'test' }, fields: { summary: 'noop' } }),
      /illegal transition|requires/
    );
  }
  const foldAfter = foldRegistry(dir);
  assert.equal(foldAfter.watermark.seq, seqBefore, 'illegal transitions must not alter canonical state');
  assert.equal(foldAfter.records.get('MEM-0001').status, 'retired');
});

test('every illegal (status, event) edge is refused', async () => {
  // candidate cannot be revalidated (only quarantined can); rejected is terminal.
  const dir = tmpRegistry();
  await propose(dir, 'MEM-0001');
  await assert.rejects(
    appendRegistryEvent(dir, { event: 'revalidated', memId: 'MEM-0001', actor: captain, evidence: [{ type: 'test', ref: 'x' }], validation: { method: 'test' } }),
    /illegal transition: candidate --revalidated/
  );
  await appendRegistryEvent(dir, { event: 'rejected', memId: 'MEM-0001', actor: firstmate, reason: 'no' });
  await assert.rejects(activate(dir, 'MEM-0001'), /illegal transition: rejected --activated/);
});
