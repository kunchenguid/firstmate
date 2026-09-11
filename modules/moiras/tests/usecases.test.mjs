import test from 'node:test';
import assert from 'node:assert/strict';
import { inspect } from '../src/usecases/inspect.mjs';
import { explain } from '../src/usecases/explain.mjs';
import { config, moduleRoot } from '../src/adapters/config.mjs';
import { json } from '../src/adapters/journal.mjs';
import { validate } from '../src/core/config.mjs';
import { fakes } from './fakes.mjs';
import { fakeMessages } from '../../fm-state-reader/tests/fake-messages.mjs';
const reading = { workers: [], pools: [], beaconAt: 1000, beaconAge: 1000, wake: null };
const request = (text, kind = 'request') => ({ name: '001.msg', message: { schema: 'fm-message.v1', id: 'msg-' + '1'.repeat(32), from: 'main', to: ['fm-moiras'], kind, thread: 'topic', ref: null, at: '2026-09-11', text } });
test('fake-backed observation survives capture-before-marker interruption without re-publication', async () => {
  const p = fakes(reading), c = config();
  const first = await inspect(p, c, 2000); assert.equal(first.snapshot.findings.length, 1); assert.equal(p.published.length, 1);
  p.records.delete(`events/${p.published[0]}.json.sent`);
  await inspect(p, c, 3000); assert.equal(p.published.length, 1);
  assert.ok(p.logs.some(r => r.event === 'event.publish.exit' && r.outcome === 'accepted'));
  assert.ok(p.logs.every(r => r.cost === null && r.counters.adapterCalls >= 0));
});
test('proposals use the supervisor channel once; uncertain delivery never mints a replacement', async () => {
  const p = fakes(reading), c = config();
  const first = await inspect(p, c, 2000), id = first.snapshot.findings[0].id;
  const sent = p.messages.calls.find(call => call.method === 'send');
  assert.deepEqual(sent.to, ['supervisor']); assert.equal(sent.options.kind, 'note'); assert.ok(sent.text.includes(id)); assert.doesNotMatch(sent.text, /[\r\n\t]/);
  p.records.delete(`events/${id}.json.sent`);
  await inspect(p, c, 3000); assert.equal(p.messages.calls.filter(call => call.method === 'send').length, 1);
  const uncertain = fakes(reading); let sends = 0;
  uncertain.messages.send = async () => { sends++; throw Error('timeout'); };
  await assert.rejects(inspect(uncertain, c, 2000), /timeout/);
  await assert.rejects(inspect(uncertain, c, 3000), /delivery uncertain/); assert.equal(sends, 1);
  const partial = fakes(reading), send = partial.messages.send;
  partial.messages.send = async (...args) => ({ ...await send(...args), partial: true });
  await assert.rejects(inspect(partial, c, 2000), /partial/);
  const receipt = partial.records.get(`events/${id}.json.delivery`).receipt;
  await inspect(partial, c, 2001);
  assert.equal(partial.messages.calls.filter(call => call.method === 'send').length, 1);
  assert.deepEqual(partial.messages.calls.find(call => call.method === 'retry'), { method: 'retry', id: receipt.id, thread: receipt.thread });
});
test('fresh observation is available before slow delivery, and notices stream after capture', async () => {
  const p = fakes(reading), order = []; let release, entered;
  const held = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  p.publisher.publish = async id => { entered(); await held; p.captures.add(id); };
  p.onSnapshot = data => { assert.equal(data.findings.length, 1); order.push('snapshot'); };
  p.onNotice = () => order.push('notice');
  const pending = inspect(p, config(), 2000);
  await started;
  try { assert.ok(p.records.has('snapshot.json'), 'readiness waited for delivery'); assert.deepEqual(order, ['snapshot']); }
  finally { release(); await pending; }
  assert.deepEqual(order, ['snapshot', 'notice']);
});
test('canonical messages reply only to requester, preserve correlation, and acknowledge last', async () => {
  const p = fakes(reading), c = config(), first = await inspect(p, c, 2000);
  p.messages = fakeMessages([request(`confirm ${first.snapshot.findings[0].id}`)]);
  await inspect(p, c, 2001);
  const sent = p.messages.calls.find(call => call.method === 'send');
  assert.deepEqual(sent.to, ['main']); assert.equal(sent.options.ref, request('').message.id); assert.equal(sent.options.thread, 'topic');
  assert.match(sent.text, /confirm recorded.*no task action/); assert.equal(p.messages.calls.at(-1).method, 'acknowledge');
  assert.ok(p.logs.some(r => r.requestId === request('').message.id && r.threadId === 'topic' && r.event === 'message.send.exit'));
  p.messages = fakeMessages([request(`confirm ${first.snapshot.findings[0].id}`)]);
  await inspect(p, c, 2002); assert.ok(!p.messages.calls.some(call => call.method === 'send'));
});
test('notes never cause reply loops; uncertain delivery never sends a replacement', async () => {
  const p = fakes(reading, [request('hi', 'note')]), c = config();
  await inspect(p, c, 2000); assert.ok(!p.messages.calls.some(call => call.method === 'send' && call.options.kind === 'reply'));
  p.messages = fakeMessages([request('ask missing')]); let calls = 0;
  p.messages.send = async () => { calls++; throw Error('timeout'); };
  await assert.rejects(inspect(p, c, 2001), /timeout/);
  await assert.rejects(inspect(p, c, 2002), /delivery uncertain/); assert.equal(calls, 1);
});
test('explicit reasoning carries evidence and measured telemetry, never invokes unknown requests', async () => {
  const p = fakes(reading), c = config(), calls = [];
  p.reasoner = { read: async (role, packet) => { calls.push({ role, packet }); return { text: 'MOIRAS|observe|sample is busy', tokens: 10, cost: .01, model: 'reported' }; } };
  const snapshot = { now: 2000, findings: [], workers: [{ id: 'sample', age: 15, busy: 'busy', last: 'working: tests', lines: ['working: tests'] }] };
  const before = structuredClone(snapshot);
  assert.match((await explain(p, c.roles, 'clotho', 'sample', snapshot)).text, /sample is busy/);
  assert.equal(calls[0].packet.statusAgeSeconds, 15); assert.equal(calls[0].packet.generationMatched, true);
  assert.deepEqual(snapshot, before); assert.equal(p.published.length, 0);
  assert.ok(p.logs.some(row => row.event === 'reason.exit' && row.tokens === 10 && row.cost === .01));
  await assert.rejects(explain(p, c.roles, 'clotho', 'absent', snapshot), /Unknown task/);
  await assert.rejects(explain(p, c.roles, 'unknown', 'sample', snapshot), /Unknown Fate/);
  assert.equal(calls.length, 1);
});
test('schema-backed config rejects unknown fields, invalid paths and non-finite thresholds', () => {
  const c = config(), schema = json(`${moduleRoot}/config.schema.json`);
  assert.equal(c.loopAttempts, 2); assert.equal(c.roles.clotho.harness, 'pi');
  for (const patch of [{ extra: true }, { beaconSeconds: Infinity }, { loopAttempts: 2.5 }, { repositories: ['../escape'] }, { poolFiles: [''] }]) assert.throws(() => validate({ ...c, ...patch }, schema), /Invalid/);
  const altered = structuredClone(c); altered.roles.clotho.persona = '../secret.md'; assert.throws(() => validate(altered, schema), /Invalid/);
  for (const harness of ['codex', 'default']) {
    const invalid = structuredClone(c); invalid.roles.atropos.harness = harness;
    assert.throws(() => validate(invalid, schema), /Invalid/);
  }
});
