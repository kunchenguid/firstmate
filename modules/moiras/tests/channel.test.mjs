import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { messages } from '../../fm-state-reader/src/index.mjs';
import { journal } from '../src/adapters/journal.mjs';
import { toolRoot } from '../src/adapters/config.mjs';
const wait = async check => {
  for (let i = 0; i < 600; i++) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 100)); }
  throw Error('Shared channel did not complete the observed operation');
};
test('real CLI registers its own service and completes supervisor requests, proposals and restart dedup', { timeout: 210000 }, async () => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'moiras-channel-'))), state = path.join(home, 'state');
  fs.mkdirSync(state);
  fs.writeFileSync(path.join(state, 'sample.meta'), 'harness=pi\nmodel=sample\n');
  fs.writeFileSync(path.join(state, 'sample.status'), 'working: healthy\n');
  fs.writeFileSync(path.join(state, '.last-watcher-beat'), '');
  const cwd = process.cwd(), task = process.env.FM_TASK_ID;
  let owner;
  try { process.chdir(home); delete process.env.FM_TASK_ID; owner = messages({ home, root: toolRoot }); }
  finally { process.chdir(cwd); if (task !== undefined) process.env.FM_TASK_ID = task; }
  let child, output = '';
  const registration = path.join(state, 'services/fm-moiras.json'), store = journal(home);
  const start = async () => {
    child = spawn(process.execPath, [path.join(toolRoot, 'modules/moiras/src/adapters/cli.mjs'), 'start', '--no-ui', '--no-llm'], {
      cwd: home, env: { ...process.env, FM_HOME: home, FM_TASK_ID: 'must-not-be-borrowed', FM_PROCEVENT_CLAIM_ROOT: path.join(home, 'claims') }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', value => { output += value; }); child.stderr.on('data', value => { output += value; });
    await wait(() => { assert.equal(child.exitCode, null, output); return !!store.get('snapshot.json'); });
    assert.equal(store.get('snapshot.json').channel, 'connected', output);
    await wait(() => fs.existsSync(registration));
    assert.equal(JSON.parse(fs.readFileSync(registration)).pid, child.pid);
    assert.equal(fs.existsSync(path.join(state, 'fm-moiras.meta')), false);
  };
  const stop = async () => {
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    const exit = once(child, 'exit'); child.kill('SIGINT');
    const timeout = setTimeout(() => child.kill('SIGKILL'), 35000);
    try { const [code, signal] = await exit; assert.equal(code, 0, output); assert.equal(signal, null); }
    finally { clearTimeout(timeout); }
    assert.ok(!fs.existsSync(registration)); assert.ok(!fs.existsSync(path.join(state, 'moiras/running')));
  };
  const request = async (text, thread) => {
    const receipt = await owner.send(['fm-moiras'], text, { kind: 'request', ...(thread ? { thread } : {}) });
    await wait(() => fs.existsSync(path.join(state, 'fm-moiras.inbox/handled')) && fs.readdirSync(path.join(state, 'fm-moiras.inbox/handled'), { withFileTypes: true }).some(entry => entry.isFile() && fs.readFileSync(path.join(state, 'fm-moiras.inbox/handled', entry.name), 'utf8').includes(receipt.id)));
    const reply = (await owner.receive()).find(entry => entry.message.ref === receipt.id)?.message;
    assert.equal(reply?.from, 'fm-moiras', output); assert.equal(reply.thread, receipt.thread);
    return reply;
  };
  try {
    await start();
    assert.match((await request('ask sample')).text, /sample: unknown/);
    const failed = 'FAIL alpha\nFAIL alpha\n'; fs.writeFileSync(path.join(state, 'sample.status'), failed);
    await wait(() => store.get('snapshot.json').findings.some(f => f.rule === 'stop-loop'));
    const event = store.get('snapshot.json').findings.find(f => f.rule === 'stop-loop');
    await wait(() => !!store.get(`events/${event.id}.json.delivery`)?.receipt);
    const proposal = (await owner.receive()).find(entry => entry.message.kind === 'note' && entry.message.text.includes(event.id))?.message;
    assert.equal(proposal?.from, 'fm-moiras'); assert.match(proposal.text, /stop-loop/);
    assert.match((await request(`confirm ${event.id}`, proposal.thread)).text, /confirm recorded.*no task action/);
    assert.equal(fs.readFileSync(path.join(state, 'sample.status'), 'utf8'), failed);
    assert.equal(fs.readFileSync(path.join(state, 'sample.meta'), 'utf8'), 'harness=pi\nmodel=sample\n');
    await stop(); store.set('quiet.json', {}); fs.unlinkSync(path.join(state, `moiras/events/${event.id}.json.sent`));
    await start(); await request('ask sample');
    assert.equal((await owner.receive()).filter(entry => entry.message.kind === 'note' && entry.message.text.includes(event.id)).length, 1);
    assert.ok(!fs.existsSync(path.join(state, `procevent-inbox/moiras-${event.id}.2.result`)));
    await stop();
  } catch (error) {
    console.error(output);
    for (const module of ['moiras', 'fm-message']) {
      const dir = path.join(state, module, 'telemetry');
      if (fs.existsSync(dir)) for (const file of fs.readdirSync(dir)) {
        const rows = fs.readFileSync(path.join(dir, file), 'utf8').trim().split('\n').map(JSON.parse);
        console.error(JSON.stringify(rows.filter(row => ['error', 'rejected'].includes(row.outcome))));
      }
    }
    console.error(fs.readdirSync(path.join(state, 'moiras/events')));
    throw error;
  } finally { await stop(); fs.rmSync(home, { recursive: true, force: true }); }
});
