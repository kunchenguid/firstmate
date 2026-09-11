import test from 'node:test';
import assert from 'node:assert/strict';
import { telemetry } from '../src/adapters/telemetry.mjs';
test('telemetry preserves synchronous terminal writes, async results, redaction and counters', async () => {
  const rows = [], trace = telemetry({ append: row => rows.push(row) }, 'run');
  assert.equal(trace.step('terminal.write', () => 7, [], 10), 7);
  assert.equal(await trace.step('forge.read', async () => 8), 8);
  assert.throws(() => trace.step('journal.read', () => { throw Error('token=secret-value'); }), /secret-value/);
  assert.equal(rows.length, 6); assert.equal(rows[0].inputs.bytes, 10);
  assert.ok(!JSON.stringify(rows).includes('secret-value'));
  assert.equal(rows.at(-1).counters.adapterCalls, 3); assert.equal(rows.at(-1).counters.errors, 1);
  assert.equal(rows.at(-1).cost, null); assert.equal(rows.at(-1).outcome, 'error');
  trace.forRequest('request', 'thread').decision('reply', 'accepted');
  assert.equal(rows.at(-1).requestId, 'request'); assert.equal(rows.at(-1).threadId, 'thread');
});
