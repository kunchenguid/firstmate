import assert from 'node:assert/strict';
import { summarize } from '../src/core/stats.mjs';

const base = { schemaVersion: 1, ts: '2026-09-11T10:00:00Z', module: 'tachikoma', requestId: 'r1' };
const events = [
  { ...base, event: 'request.received' },
  { ...base, event: 'port.exit', inputs: { port: 'quota' }, stepsMs: { quota: 25 }, outcome: 'accepted' },
  { ...base, event: 'decision', decision: { model: 'subscription/a' }, outcome: 'accepted' },
  { ...base, event: 'request.completed', outcome: 'accepted', model: 'subscription/a', tokens: { inputTokens: 0, outputTokens: 0 }, cost: { amount: 0, currency: 'USD' }, counters: { candidates: 2, refusals: 0 } },
  { ...base, requestId: 'r2', event: 'request.completed', outcome: 'rejected', tokens: null, cost: null, counters: { candidates: 2, refusals: 2 } },
  { ...base, requestId: 'r3', event: 'port.exit', inputs: { port: 'quota' }, stepsMs: { quota: 4 }, outcome: 'error' },
  { ...base, requestId: 'r3', event: 'request.completed', outcome: 'error' },
  { ...base, requestId: 'r4', event: 'request.received' },
  { ...base, requestId: 'elsewhere', module: 'moiras', event: 'request.completed', outcome: 'accepted' },
  { ...base, requestId: 'yesterday', ts: '2026-09-10T23:59:59Z', event: 'request.completed', outcome: 'accepted' },
];
const before = structuredClone(events);
const result = summarize(events, '2026-09-11');
assert.equal(result.requests, 4);
assert.equal(result.pending, 1);
assert.deepEqual(result.outcomes, { accepted: 1, rejected: 1, error: 1 });
assert.deepEqual(result.ports.quota, { calls: 2, errors: 1, durationMs: 29 });
assert.deepEqual(result.counters, { candidates: 4, refusals: 2 });
assert.deepEqual(result.usage, { observations: 1, inputTokens: 0, outputTokens: 0, costByCurrency: { USD: 0 } });
assert.deepEqual(events, before);
assert.deepEqual(summarize([...events, events[3]], '2026-09-11'), result);
assert.deepEqual(summarize([], '2026-09-11').usage, { observations: 0, inputTokens: null, outputTokens: null, costByCurrency: {} });
console.log('ok - daily stats count requests, not intermediate decisions; ports, unknowns, and observed zeros stay distinct');
