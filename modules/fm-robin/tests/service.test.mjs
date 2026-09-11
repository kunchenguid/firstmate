import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { messages } from '../../fm-state-reader/src/index.mjs';
import { payload } from './fakes.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');

test('real service serializes requests and preserves message -> report -> reply -> wake -> acknowledgement', { timeout: 180000 }, async t => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'robin-service-')));
  const cwd = process.cwd(), task = process.env.FM_TASK_ID;
  delete process.env.FM_TASK_ID; process.chdir(home);
  const owner = messages({ home, root });
  process.chdir(cwd); if (task !== undefined) process.env.FM_TASK_ID = task;
  const child = fork(fileURLToPath(new URL('./service-worker.mjs', import.meta.url)), [], {
    cwd: home, env: { ...process.env, FM_HOME: home, FM_TEST_ROOT: root, FM_TASK_ID: 'must-not-be-borrowed', FM_PROCEVENT_CLAIM_ROOT: path.join(home, 'claims') }, silent: true,
  });
  let stderr = '', stopped, retrieving;
  child.stderr.on('data', chunk => { stderr += chunk; });
  const startedRetrieval = new Promise(resolve => { retrieving = resolve; });
  const ready = new Promise((resolve, reject) => {
    child.on('message', value => { if (value.ready) resolve(); if (value.retrieving) retrieving(); if (value.stopped) stopped = value; });
    child.once('exit', () => reject(Error(`Service exited before readiness: ${stderr}`)));
  });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      // Release only this test's synthetic barrier, then shut down its owned process.
      child.send('continue'); const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited;
    }
    fs.rmSync(home, { recursive: true, force: true });
  });
  await ready;
  const registered = JSON.parse(fs.readFileSync(path.join(home, 'state/services/robin.json')));
  assert.equal(registered.pid, child.pid);
  assert.equal(fs.existsSync(path.join(home, 'state/robin.meta')), false);
  const text = JSON.stringify({ ...payload, deadline: new Date(Date.now() + 120000).toISOString() });
  const first = await owner.send(['robin'], text, { kind: 'request' });
  await startedRetrieval;
  const second = await owner.send(['robin'], text, { kind: 'request' });
  // The second request is durably queued while the first retrieval is still held.
  assert.equal(fs.readdirSync(path.join(home, 'state/robin.inbox')).filter(name => name.endsWith('.msg')).length, 2);
  assert.equal(fs.existsSync(path.join(home, 'data/knowledge/documentation')), false);
  child.send('continue');
  const deadline = Date.now() + 90000;
  while (!fs.existsSync(path.join(home, 'state/robin.inbox/handled/002.msg'))) {
    assert.equal(child.exitCode, null, stderr); assert.ok(Date.now() < deadline, 'both requests must finish'); await sleep(1000);
  }
  const replies = await owner.receive();
  assert.equal(replies.length, 2);
  assert.deepEqual(replies.map(entry => entry.message.ref), [first.id, second.id]);
  assert.ok(replies.every(entry => entry.message.from === 'robin' && entry.message.kind === 'reply'));
  for (const receipt of [first, second]) {
    const record = JSON.parse(fs.readFileSync(path.join(home, `state/robin/requests/${receipt.id}.json`)));
    assert.equal(record.verdict, 'supported'); assert.equal(record.notified, true); assert.equal(record.receipt.partial, false);
    assert.match(fs.readFileSync(path.join(home, record.report), 'utf8'), /^# Verdict: supported/);
    const result = JSON.parse(fs.readFileSync(path.join(home, `state/procevent-inbox/robin-${record.eventId}.1.result`)));
    assert.equal(result.requester, 'supervisor'); assert.equal(result.report, record.report);
    assert.match(fs.readFileSync(path.join(home, 'state/.wake-queue'), 'utf8'), new RegExp(`procevent fm-state-reader robin-${record.eventId}`));
  }
  const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited;
  assert.equal(child.exitCode, 0, stderr);
  assert.deepEqual(stopped.calls, ['fetch', 'scrapling', 'fetch', 'scrapling']); assert.equal(stopped.reasons, 2);
  for (const file of ['services/robin.json', 'robin/run.lock', 'robin/resources.owner', 'robin/resources.json']) assert.ok(!fs.existsSync(path.join(home, 'state', file)));
  assert.equal(fs.readdirSync(path.join(home, 'state/robin.inbox/handled')).length, 2);
});
