import test from 'node:test';
import assert from 'node:assert/strict';
import { pace, classify } from '../src/core/quota.mjs';

test('linear window compares remaining quota with remaining time', () => {
  const row = pace({ percentRemaining: 36, resetsAt: '2026-09-12T00:00:00Z', windowSeconds: 172800 }, Date.parse('2026-09-11T00:00:00Z'));
  assert.equal(row.idealPercent, 50);
  assert.equal(row.delta, -14);
  assert.equal(row.status, 'HOT');
  assert.equal(row.resetsIn, 86400);
});

test('classification retains independent identity, duplicate and availability warnings', () => {
  const provider = { provider: 'codex', account: { email: 'actual@example.test' }, windows: [
    { id: 'weekly', percentRemaining: 70, windowSeconds: 172800, resetsAt: '2026-09-12T00:00:00Z' },
  ] };
  const pools = [{ id: 'one', expectedEmail: 'expected@example.test', data: provider },
    { id: 'two', data: provider }, { id: 'missing', data: { provider: 'kimi', windows: [] } }];
  const result = classify(pools, Date.parse('2026-09-11T00:00:00Z'));
  assert.deepEqual(result.pools[0].tags, ['UNDER', 'DUPLICATE ACCOUNT', 'IDENTITY MISMATCH']);
  assert.ok(result.pools[1].tags.includes('DUPLICATE ACCOUNT'));
  assert.deepEqual(result.pools[2].tags, ['UNAVAILABLE']);
  assert.deepEqual(result.counts, { agents: 2, accounts: 3, hot: 0, unavailable: 1, mismatch: 1, duplicate: 2 });
});

test('pace handles explicit start, override, boundaries, malformed percentages and unknown windows', () => {
  const now = Date.parse('2026-09-11T00:00:00Z');
  const window = { id: 'monthly', percentUsed: 20, startsAt: '2026-09-10T00:00:00Z', resetsAt: '2026-09-12T00:00:00Z' };
  assert.equal(pace(window, now).delta, 30);
  assert.equal(pace(window, now, 86400).status, 'HOT');
  assert.equal(pace({ ...window, percentUsed: 50 }, now).status, 'ON PACE');
  assert.equal(pace(window, now + 86400000).status, 'UNAVAILABLE');
  assert.equal(pace(window, now + 86400000).resetsIn, 0);
  assert.equal(pace(window, now - 172800000).idealPercent, null);
  assert.equal(pace({ percentRemaining: 101 }, now).status, 'UNAVAILABLE');
  assert.equal(pace({ percentRemaining: 0 }, now).status, 'PACE UNKNOWN');
  assert.equal(pace({ percentRemaining: 0 }, now).remaining, 0);
  assert.equal(pace({ percentRemaining: NaN }, now).remaining, null);
  assert.equal(pace({ percentRemaining: 100, resetsAt: 'invalid' }, now).idealPercent, null);
});

test('stale data is unavailable; unknown identities never imply duplication or mismatch', () => {
  const data = { provider: 'kimi', state: { stale: true }, windows: [{ id: 'weekly', percentRemaining: 70 }] };
  const frame = classify([{ id: 'a', data, expectedEmail: 'missing@example.test' }, { id: 'b', data }], Date.now());
  assert.equal(frame.counts.unavailable, 2);
  assert.equal(frame.counts.mismatch, 0);
  assert.equal(frame.counts.duplicate, 0);
  assert.equal(frame.pools[0].remaining, null);
  for (const state of [{ status: 'rate_limited' }, { status: 'stale' }, { status: 'fresh', untrustedWindowIds: ['weekly'] }]) {
    assert.equal(classify([{ id: 'a', data: { ...data, state } }], Date.now()).counts.unavailable, 1);
  }
});

test('all-model gauge uses source semantics instead of a model-only bound', () => {
  const data = { provider: 'claude', windows: [{ id: 'model', percentRemaining: 2 }], quotaSemantics: {
    effectiveAvailability: [{ scope: 'all_models', status: 'known', effectivePercentRemaining: 36 }] } };
  assert.equal(classify([{ id: 'a', data }], Date.now()).pools[0].remaining, 36);
});
