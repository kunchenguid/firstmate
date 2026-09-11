import assert from 'node:assert/strict';
import { test } from 'node:test';
import { routeTask, learn } from '../src/usecases/routing.mjs';
import { fakeJournal, fakeEvidence, fakeTelemetry, fakeModelTelemetry } from './fakes.mjs';

const profiles = ['a', 'b'].map(model => ({ harness: 'pi', model: `subscription/${model}`, effort: 'high' }));
const request = { requestId: 'request-1', task: 'task-1', class: 'bounded', repo: 'example' };
const context = {
  stamp: { requestId: request.requestId, decisionId: 'decision-1', recordedAt: '2026-09-11T10:00:00Z', task: request.task, taskClass: request.class, repo: request.repo, briefSha256: 'brief-hash', policySha256: 'policy-hash' },
  input: { policy: { allowedHarnesses: ['pi'], disabledPools: [], maxLoadPerCpu: 2, explorationRate: 0.1, bindings: profiles.map((profile, i) => ({ ...profile, pool: ['a', 'b'][i], quotaProvider: ['a', 'b'][i], modelFamily: ['a', 'b'][i], quotaScopes: ['all_models'], strongest: true, qualityPrior: 0.7 })) }, rule: { matchedRule: 'default', horizonSeconds: 60, strongestOnly: false, selectionStrategy: 'quota-weighted' }, candidates: profiles, snapshot: { ageSeconds: 0, quota: [{ provider: 'a', scope: 'all_models', effectivePercentRemaining:80,spendPriority:4,runway:'through_reset' }, { provider: 'b', scope:'all_models', effectivePercentRemaining:null,spendPriority:null,runway:'unknown' }], exhaustion: [] }, machine: {loadAverage1m:1,logicalCpuCount:4},cooldowns:{},repo:'example',seed:0xffffffff },
};

test('route persists before returning, replays identical request identity, and refuses a changed request', async () => {
  const ports = { journal: fakeJournal(), evidence: fakeEvidence(context), telemetry: fakeTelemetry() };
  const decision = await routeTask(request, ports);
  assert.equal(decision.model, 'subscription/b');
  assert.deepEqual(ports.journal.trace, ['read-decisions', 'read-cards', 'append-decision']);
  assert.equal(ports.journal.decisions.length, 1);
  assert.equal(ports.telemetry.events[0].event, 'decision');
  assert.deepEqual(await routeTask(request, ports), decision);
  assert.equal(ports.journal.decisions.length, 1);
  await assert.rejects(routeTask({ ...request, task: 'changed' }, ports), /identity conflicts/);
});

test('sampling and append share the transaction, so concurrent requests cannot both spend one unmeasured-pool allowance', async () => {
  const journal = fakeJournal(); const telemetry = fakeTelemetry();
  const a = routeTask(request, { journal, evidence: fakeEvidence(context), telemetry });
  const next = structuredClone(context); next.stamp.requestId = 'request-2'; next.stamp.decisionId = 'decision-2';
  const b = routeTask({ ...request, requestId: 'request-2' }, { journal, evidence: fakeEvidence(next), telemetry });
  const results = await Promise.all([a, b]);
  assert.equal(results.filter(row => row.model === 'subscription/b').length, 1);
  assert.equal(journal.decisions.length, 2);
});

test('an append refusal never returns a successful recommendation', async () => {
  const journal = fakeJournal(); journal.appendDecision = async () => { throw new Error('disk unavailable'); };
  await assert.rejects(routeTask(request, { journal, evidence: fakeEvidence(context), telemetry: fakeTelemetry() }), /disk unavailable/);
  assert.equal(journal.decisions.length, 0);
});

test('learn uses the model telemetry port, ignores open attempts, and writes only derived cards', async () => {
  const journal = fakeJournal(); const telemetry = fakeTelemetry();
  const attempts = [{ ...profiles[0], recordType:'attempt',state:'terminal',attemptClass:'real',taskClass:'bounded',modelVersion:'v1',cliVersion:'cli-1',classification:'accepted',attemptId:'a',taskRootId:'root' }, { ...profiles[0], recordType:'attempt',state:'open',attemptClass:'real' }];
  const ports = { journal, telemetry, modelTelemetry: fakeModelTelemetry(attempts) };
  const receipt = await learn(ports, '2026-09-11T10:00:00Z');
  assert.equal(receipt.sealedAttempts, 1); assert.equal(journal.cards.length, 1);
  const before = structuredClone(journal.cards); await learn(ports, '2026-09-11T10:01:00Z'); assert.deepEqual(journal.cards, before);
  assert.equal(attempts[1].state, 'open');
});
