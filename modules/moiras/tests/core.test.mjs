import test from 'node:test';
import assert from 'node:assert/strict';
import { measure, thread, answer } from '../src/core/findings.mjs';
const c = { beaconSeconds: 300, poolRatio: .9, idleSeconds: 900, busySilentSeconds: 3600, loopSeconds: 5400, loopAttempts: 2 };
const worker = { id: 'sample', last: 'working: waiting', lines: [], changed: 1000, age: 9000, busy: 'idle', idleAt: 1000 };
const pr = { url: 'https://github.com/example/repo/pull/1', head: 'fm/sample', state: 'open', proof: true };
const state = { workers: [], prs: [], beaconAge: 0, beaconAt: 10000, used: 0, capacity: 10, now: 10000 };
const rules = s => measure({ ...state, ...s }, c).map(f => f.rule);
for (const [rule, positive, contrary] of [
  ['stale-beacon', { beaconAge: 301 }, { beaconAge: 300 }],
  ['pool-near-cap', { used: 9 }, { used: 8 }],
  ['silent-idle', { workers: [worker] }, { workers: [{ ...worker, busy: 'unknown' }] }],
  ['busy-but-silent', { workers: [{ ...worker, busy: 'busy' }] }, { workers: [{ ...worker, busy: 'idle' }] }],
  ['repeat-failure', { workers: [{ ...worker, lines: Array(3).fill('blocked: FAIL alpha') }] }, { workers: [{ ...worker, lines: ['FAIL alpha', 'FAIL beta', 'FAIL alpha'] }] }],
  ['missing-pr-proof', { workers: [{ ...worker, last: `done: PR ${pr.url}`, pr: { ...pr, proof: false } }] }, { workers: [{ ...worker, last: `done: PR ${pr.url}`, pr }] }],
  ['ownerless-pr', { prs: [pr] }, { prs: [pr], workers: [{ ...worker, pr }] }],
  ['retire-merged', { workers: [{ ...worker, last: 'done: ready', pr: { ...pr, merged: '2026-09-11' } }] }, { workers: [{ ...worker, last: 'done: ready', pr }] }],
  ['stop-loop', { workers: [{ ...worker, lines: ['FAIL alpha', 'FAIL alpha'] }] }, { workers: [{ ...worker, lines: ['FAIL alpha'] }] }],
]) test(`${rule} has positive and disconfirming plain-data fixtures`, () => { assert.ok(rules(positive).includes(rule)); assert.ok(!rules(contrary).includes(rule)); });
test('unknown, held, truncated or newly idle evidence never becomes an idle cut', () => {
  for (const patch of [{ busy: 'busy' }, { busy: 'unknown' }, { idleAt: null }, { idleAt: state.now }, { truncated: true }, ...['paused [key=x]: wait', 'needs-decision: choice', 'done: ready', 'parked: hold'].map(last => ({ last }))]) assert.ok(!rules({ workers: [{ ...worker, ...patch }] }).includes('silent-idle'));
  assert.ok(!rules({ beaconAge: null, poolComplete: false, used: 10 }).includes('pool-near-cap'));
  for (const last of ['blocked [key=stalled]: old', 'blocked [key=stalled-after-interrupt]: inspect']) assert.ok(!rules({ workers: [{ ...worker, busy: 'busy', last }] }).includes('busy-but-silent'));
});
test('age of the last status is not evidence of a 90-minute loop', () => {
  const w = { ...worker, lines: ['FAIL alpha', 'FAIL alpha'] };
  assert.ok(!measure({ ...state, workers: [w] }, { ...c, loopAttempts: 3 }).some(f => f.rule === 'stop-loop'));
  assert.ok(measure({ ...state, workers: [{ ...w, loopSince: 1000 }] }, { ...c, loopAttempts: 3 }).some(f => f.rule === 'stop-loop'));
  assert.equal(measure({ ...state, workers: [worker] }, c)[0].id, measure({ ...state, now: 10050, workers: [worker] }, c)[0].id);
});
test('forge failure withholds PR claims, and URL 1 cannot bind URL 10', () => {
  assert.deepEqual(rules({ prs: [pr], forgeError: 'unavailable' }), []);
  const data = thread({ ...state, pools: [], workers: [{ ...worker, id: 'other', lines: ['done: PR https://github.com/example/repo/pull/10'] }] }, [pr]);
  assert.equal(data.workers[0].pr, undefined);
});
test('message meaning is pure and confirmation requires current evidence', () => {
  const findings = measure({ ...state, workers: [worker] }, c), id = findings[0].id;
  const message = { schema: 'fm-message.v1', id: 'msg-test', thread: 'test', at: '2026-09-11', from: 'main', to: ['fm-moiras'], kind: 'request', ref: null, text: `confirm ${id}` };
  assert.match(answer(message, { ...state, findings }), /confirm recorded.*no task action/);
  assert.throws(() => answer(message, { ...state, findings: [] }), /evidence changed/);
  assert.throws(() => answer({ ...message, to: 'other' }, { ...state, findings }), /Not a Moiras request/);
});
