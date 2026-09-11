import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { observe } from '../src/adapters/service.mjs';
import { defaultConfig, toolRoot } from '../src/adapters/config.mjs';
import { journal } from '../src/adapters/journal.mjs';
import { fakeMessages } from '../../fm-state-reader/tests/fake-messages.mjs';
const wait = async (check, attempts = 100) => { for (let i = 0; i < attempts; i++) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 50)); } throw Error('Observable update missing'); };
test('real state -> module rules -> registered capture; shared messaging is explicitly fake', { timeout: 90000 }, async () => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-service-'))), state = path.join(home, 'state');
  const prior = process.env.FM_PROCEVENT_CLAIM_ROOT; process.env.FM_PROCEVENT_CLAIM_ROOT = path.join(home, 'claims');
  fs.mkdirSync(state); let observer;
  const original = { 'sample.meta': 'harness=pi\nmodel=small\nbusy_gen=g1\n', 'sample.status': 'FAIL alpha\nFAIL alpha\n',
    'sample.busy-gen': 'g1', 'sample.busy-state': 'gen=g1 state=busy ts=1', '.last-watcher-beat': '' };
  for (const [name, text] of Object.entries(original)) fs.writeFileSync(path.join(state, name), text);
  let messages = fakeMessages([{ name: '001.msg', message: { schema: 'fm-message.v1', id: 'msg-' + '2'.repeat(32), thread: 'test', at: '2026-09-11', from: 'supervisor', to: ['moiras'], kind: 'request', ref: null, text: 'ask sample' } }]);
  const start = () => observe({ home, root: toolRoot, configFile: defaultConfig, messages });
  try {
    observer = await start();
    const event = observer.data().findings.find(f => f.rule === 'stop-loop'); assert.ok(event);
    const capture = path.join(state, `procevent-inbox/moiras-${event.id}.1.result`);
    await wait(() => fs.existsSync(capture) && messages.calls.some(c => c.method === 'acknowledge'), 1200);
    assert.equal(JSON.parse(fs.readFileSync(capture, 'utf8')).id, event.id);
    assert.match(fs.readFileSync(path.join(state, '.wake-queue'), 'utf8'), /procevent fm-state-reader moiras-/);
    assert.match(messages.calls.find(c => c.method === 'send').text, /sample: busy/);
    for (const [name, text] of Object.entries(original)) assert.equal(fs.readFileSync(path.join(state, name), 'utf8'), text);
    await observer.stop(); journal(home).set('quiet.json', {});
    fs.unlinkSync(path.join(state, `moiras/events/${event.id}.json.sent`));
    messages = fakeMessages([{ name: '002.msg', message: { schema: 'fm-message.v1', id: 'msg-' + '3'.repeat(32), thread: 'test', at: '2026-09-11', from: 'supervisor', to: ['moiras'], kind: 'request', ref: null, text: `confirm ${event.id}` } }]);
    observer = await start();
    await wait(() => messages.calls.some(c => c.method === 'acknowledge'), 1200);
    assert.ok(!fs.existsSync(path.join(state, `procevent-inbox/moiras-${event.id}.2.result`)));
    assert.match(messages.calls.find(c => c.method === 'send').text, /confirm recorded.*no task action/);
    for (const [name, text] of Object.entries(original)) assert.equal(fs.readFileSync(path.join(state, name), 'utf8'), text);
    fs.writeFileSync(path.join(state, 'sample.status'), 'working: fixed\n');
    await wait(() => !observer.data().findings.some(f => f.rule === 'stop-loop'));
    await observer.stop(); await observer.stop(); assert.ok(!fs.existsSync(path.join(state, 'moiras/running')));
    assert.equal(fs.readFileSync(path.join(state, 'sample.status'), 'utf8'), 'working: fixed\n');
    const snapshot = fs.readFileSync(path.join(state, 'moiras/snapshot.json'), 'utf8'), controller = new AbortController(); controller.abort();
    observer = await observe({ home, root: toolRoot, configFile: defaultConfig, signal: controller.signal });
    assert.equal(observer.data(), undefined); assert.equal(fs.readFileSync(path.join(state, 'moiras/snapshot.json'), 'utf8'), snapshot); await observer.stop();
  } finally {
    await observer?.stop(); if (prior === undefined) delete process.env.FM_PROCEVENT_CLAIM_ROOT; else process.env.FM_PROCEVENT_CLAIM_ROOT = prior;
    fs.rmSync(home, { recursive: true, force: true });
  }
});
