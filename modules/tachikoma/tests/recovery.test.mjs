import assert from 'node:assert/strict';
import { test } from 'node:test';
import { poolRecovery, latestPoolRecovery, recoveryCounters, withDailyCaps } from '../src/core/recovery.mjs';
import { jsonQuota } from '../src/adapters/evidence.mjs';

const now = '2026-09-11T10:00:00Z';
const binding = { harness: 'pi', model: 'cursor/grok-4.6', effort: 'high', pool: 'cursor', provider: 'cursor', quotaProvider: 'cursor', modelFamily: 'grok', quotaScopes: ['all_models'] };
const policy = { bindings: [binding] };
const snapshot = { quota: [{ provider: 'cursor', scope: 'all_models', effectivePercentRemaining: 0, runway: 'exhausted_now', spendPriority: -2, resetsAt: '2026-09-11T11:00:00Z' }] };

test('pool recovery counters retain exact provider and family scope and never clear gates', () => {
  const cooldowns = [
    { scope: { kind: 'provider', provider: 'CURSOR' }, expires_at: '2026-09-11T10:30:00Z' },
    { scope: { kind: 'model-family', provider: 'cursor', harness: 'pi', model_family: 'grok' }, expires_at: '2026-09-11T12:00:00Z' },
    { scope: { kind: 'model-family', provider: 'cursor', harness: 'pi', model_family: 'other' }, expires_at: '2099-01-01T00:00:00Z' },
    { scope: { kind: 'provider', provider: 'grok' }, expires_at: '2099-01-01T00:00:00Z' },
  ];
  const rows = poolRecovery(policy, [binding], snapshot, cooldowns, now);
  assert.equal(rows[0].recheckAt, '2026-09-11T12:00:00Z');
  assert.equal(rows[0].quotaResetAt, '2026-09-11T11:00:00Z');
  assert.equal(rows[0].pacingRecoveryAt, null);
  assert.equal(rows[0].quota[0].spendPriority, -2);
  assert.equal(recoveryCounters(rows, Date.parse(now))[0].secondsUntilRecheck, 7200);
  assert.equal(recoveryCounters(rows, Date.parse('2026-09-11T13:00:00Z'))[0].recheckDue, true);
  assert.equal(cooldowns.length, 4);
  const unknown = poolRecovery(policy, [binding], { quota: [] }, [], now)[0];
  assert.equal(unknown.recoveryUnmeasured, true); assert.equal(unknown.recheckAt, null);
  const recovered = poolRecovery(policy, [binding], { quota: [{ ...snapshot.quota[0], effectivePercentRemaining: 90, runway: 'through_reset' }] }, cooldowns, '2026-09-11T13:00:00Z');
  assert.equal(recovered[0].cooldownUntil, null); assert.equal(recovered[0].recheckAt, null);
  assert.deepEqual(latestPoolRecovery([{ poolRecovery: recovered }, { poolRecovery: rows }]), recovered);
});

test('the pick consuming the unmeasured allowance records its next UTC reset immediately', () => {
  const rows = poolRecovery(policy, [binding], { quota: [] }, [], now);
  const decision = { ...binding, selection: { unmeasuredDailyCap: 1, weights: [{ ...binding, runway: 'unmeasured', dailyPicks: 0 }] } };
  assert.equal(withDailyCaps(rows, decision, now)[0].unmeasuredCapResetAt, '2026-09-12T00:00:00.000Z');
  decision.model = 'different';
  assert.equal(withDailyCaps(rows, decision, now)[0].unmeasuredCapResetAt, null);
});

test('permitted JSON quota fallback preserves producer reset evidence without reconstructing pacing', () => {
  const value = { generatedAt: now, providers: [{ provider: 'cursor', state: { status: 'fresh', stale: false }, windows: [{ id: 'api', resetsAt: '2026-09-16T00:00:00Z' }, { id: 'unrelated', resetsAt: '2099-01-01T00:00:00Z' }], quotaSemantics: { effectiveAvailability: [{ scope: 'all_models', boundedBy: ['api'], effectivePercentRemaining: 44, selection: { spendPriority: 2.66 }, runway: { status: 'through_reset' } }] } }] };
  const row = jsonQuota(value, Date.parse(now)).quota[0];
  assert.equal(row.resetsAt, '2026-09-16T00:00:00Z'); assert.equal(row.spendPriority, 2.66);
  value.providers[0].state.stale = true;
  assert.equal(jsonQuota(value, Date.parse(now)).quota[0].effectivePercentRemaining, null);
});
