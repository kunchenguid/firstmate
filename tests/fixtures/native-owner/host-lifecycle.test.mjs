import test from 'node:test';
import assert from 'node:assert/strict';
import {createHostLifecycle,reconciliationWarning} from '../../../bin/native-owner/host-lifecycle.mjs';
function setup(overrides = {}) {
  const events = [];
  const lifecycle = createHostLifecycle({
    gate: {close: () => events.push('revoke')},
    interrupt: async () => events.push('interrupt'),
    stopOperations: async () => { events.push('operations'); return true; },
    closeInput: () => events.push('eof'),
    waitForExit: async () => { events.push('exited'); return true; },
    terminate: () => events.push('terminate'), graceMs: 25, ...overrides,
  });
  return {lifecycle, events};
}
test('shutdown revokes synchronously and is single-flight', async () => {
  const {lifecycle, events} = setup();
  const first = lifecycle.shutdown(), second = lifecycle.shutdown();
  assert.equal(first, second);
  assert.deepEqual(events, ['revoke']);
  const result = await first;
  assert.deepEqual(events, ['revoke', 'interrupt', 'operations', 'eof', 'exited']);
  assert.deepEqual(result, {stopped:true, operationsStopped:true, reconciliationRequired:false, exited:true, forced:false, errors:[]});
});
test('shutdown preserves a reconciliation requirement after operations stop', async () => {
  const {lifecycle} = setup({stopOperations: async () => ({stopped:true,reconciliationRequired:true})});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, true);
  assert.equal(result.reconciliationRequired, true);
  assert.match(reconciliationWarning('C:\\home\\owner-receipts.jsonl'), /completion is unconfirmed.*preserved.*require reconciliation/);
});
test('unconfirmed operation shutdown is not reported as success', async () => {
  const {lifecycle, events} = setup({stopOperations: async () => false});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, false);
  assert.equal(result.exited, true);
  assert(events.includes('eof'));
});
test('failed interruption does not prevent cleanup', async () => {
  const {lifecycle, events} = setup({interrupt: async () => { throw Error('interrupt unavailable'); }});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, true);
  assert.deepEqual(result.errors, ['interrupt unavailable']);
  assert(events.includes('operations'));
});
test('operation timeout aborts its request and still closes app-server', async () => {
  let aborted = false;
  const {lifecycle, events} = setup({stopOperations: signal => new Promise(() => { signal.addEventListener('abort', () => { aborted = true; }); })});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, false);
  assert.equal(aborted, true);
  assert(events.includes('eof'));
});
test('grace timeout terminates only through supplied retained-process action', async () => {
  let waits = 0;
  const {lifecycle, events} = setup({waitForExit: () => ++waits === 1 ? new Promise(() => {}) : Promise.resolve(true)});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, true);
  assert.equal(result.forced, true);
  assert.equal(events.filter(value => value === 'terminate').length, 1);
});
test('unconfirmed process exit remains a failure after termination', async () => {
  const {lifecycle, events} = setup({waitForExit: async () => false});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, false);
  assert.equal(result.exited, false);
  assert(events.includes('terminate'));
});
test('termination error is retained and not mistaken for exit', async () => {
  const {lifecycle} = setup({waitForExit: async () => false, terminate: () => { throw Error('termination denied'); }});
  const result = await lifecycle.shutdown();
  assert.equal(result.stopped, false);
  assert(result.errors.includes('termination denied'));
});
test('invalid bounds are refused before lifecycle effects', () => {
  for (const graceMs of [0, -1, 10001, Infinity, 1.5]) assert.throws(() => setup({graceMs}));
});
