import test from 'node:test';
import assert from 'node:assert/strict';
import { inspect } from '../src/usecases/inspect.mjs';
import { config, moduleRoot } from '../src/adapters/config.mjs';
import { json } from '../src/adapters/journal.mjs';
import { validate } from '../src/core/config.mjs';
import { fakes } from './fakes.mjs';
import { fakeMessages } from '../../fm-state-reader/tests/fake-messages.mjs';
const reading = { workers: [], pools: [], beaconAt: 1000, beaconAge: 1000, wake: null };
const request = (text, kind = 'request') => ({ name: '001.msg', message: { schema: 'fm-message.v1', id: 'msg-' + '1'.repeat(32), from: 'main', to: ['moiras'], kind, thread: 'topic', ref: null, at: '2026-09-11', text } });
test('fake-backed observation survives capture-before-marker interruption without re-publication', async () => {
  const p = fakes(reading), c = config();
  const first = await inspect(p, c, 2000); assert.equal(first.snapshot.findings.length, 1); assert.equal(p.published.length, 1);
  p.records.delete(`events/${p.published[0]}.json.sent`);
  await inspect(p, c, 3000); assert.equal(p.published.length, 1);
  assert.ok(p.logs.some(r => r.event === 'event.publish.exit' && r.outcome === 'accepted'));
  assert.ok(p.logs.every(r => r.cost === null && r.counters.adapterCalls >= 0));
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
  await inspect(p, c, 2000); assert.ok(!p.messages.calls.some(call => call.method === 'send'));
  p.messages = fakeMessages([request('ask missing')]); let calls = 0;
  p.messages.send = async () => { calls++; throw Error('timeout'); };
  await assert.rejects(inspect(p, c, 2001), /timeout/);
  await assert.rejects(inspect(p, c, 2002), /delivery uncertain/); assert.equal(calls, 1);
});
test('schema-backed config rejects unknown fields, invalid paths and non-finite thresholds', () => {
  const c = config(), schema = json(`${moduleRoot}/config.schema.json`);
  assert.equal(c.loopAttempts, 2); assert.equal(c.roles.clotho.harness, 'pi');
  for (const patch of [{ extra: true }, { beaconSeconds: Infinity }, { loopAttempts: 2.5 }, { repositories: ['../escape'] }, { poolFiles: [''] }]) assert.throws(() => validate({ ...c, ...patch }, schema), /Invalid/);
  const altered = structuredClone(c); altered.roles.clotho.persona = '../secret.md'; assert.throws(() => validate(altered, schema), /Invalid/);
});
