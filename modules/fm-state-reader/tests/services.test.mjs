import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fork, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { messages } from '../src/index.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const fixture = fileURLToPath(new URL('./service-worker.mjs', import.meta.url));

test('real standalone services use their own inboxes and retain request/reply correlation', { timeout: 180000 }, async t => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fm-services-')));
  fs.mkdirSync(path.join(home, 'state'));
  const cwd = process.cwd(), task = process.env.FM_TASK_ID, previousPath = process.env.PATH, children = [];
  t.after(async () => {
    process.chdir(cwd); process.env.PATH = previousPath;
    if (task === undefined) delete process.env.FM_TASK_ID; else process.env.FM_TASK_ID = task;
    for (const child of children) if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit'); child.kill(); await exited;
    }
    fs.rmSync(home, { recursive: true, force: true });
  });
  delete process.env.FM_TASK_ID; process.chdir(home);
  const start = async name => {
    const child = fork(fixture, [name], { cwd: home, env: { ...process.env, FM_HOME: home, FM_TEST_ROOT: root, FM_TASK_ID: 'must-not-be-borrowed', PATH: `${home}/fakebin:${previousPath}`, FM_WAKE_QUEUE: `${home}/wrong-queue`, FM_WAKE_QUEUE_LOCK: `${home}/wrong-queue.lock` }, silent: true });
    children.push(child);
    let stderr = ''; child.stderr.on('data', chunk => { stderr += chunk; });
    await new Promise((resolve, reject) => {
      child.once('message', value => value.ready ? resolve() : reject(Error('service did not register')));
      child.once('exit', () => reject(Error(`service exited before readiness: ${stderr}`)));
    });
    let sequence = 0;
    const call = (method, ...args) => new Promise((resolve, reject) => {
      const id = ++sequence;
      const listener = value => {
        if (value.id !== id) return;
        child.off('message', listener);
        value.error ? reject(Error(value.error)) : resolve(value.result);
      };
      child.on('message', listener); child.send({ id, method, args });
    });
    return { child, call };
  };
  const a = await start('fm-moiras'), b = await start('fm-robin'), owner = messages({ home, root });
  const registration = JSON.parse(fs.readFileSync(path.join(home, 'state/services/fm-moiras.json')));
  assert.equal(registration.pid, a.child.pid); assert.equal(registration.home, home);
  assert.equal(registration.name, 'fm-moiras'); assert.match(registration.started_at, /^\d{4}-/);
  assert.equal(fs.existsSync(path.join(home, 'state/fm-moiras.meta')), false);
  await assert.rejects(start('fm-moiras'), /service exited before readiness/);
  await assert.rejects(start('supervisor'), /Invalid service name/);
  await assert.rejects(start('--reply'), /Invalid service name/);
  await assert.rejects(a.call('unmarked'), /Message receive failed/);
  await assert.rejects(a.call('unmarked-control'), /requires its explicit FM_SERVICE_ID/);
  const cli = (...args) => execFileSync(path.join(root, 'bin/fm-message.sh'), args, { env: { ...process.env, FM_HOME: home }, stdio: 'pipe' });
  assert.throws(() => cli('service', 'register', 'impostor', String(a.child.pid)));
  assert.equal(fs.existsSync(path.join(home, 'state/services/impostor.json')), false);
  fs.writeFileSync(path.join(home, 'state/occupied.meta'), 'kind=ship\n');
  assert.throws(() => cli('service', 'register', 'occupied', String(process.pid)));
  assert.equal(fs.existsSync(path.join(home, 'state/services/occupied.json')), false);
  fs.unlinkSync(path.join(home, 'state/occupied.meta'));
  const file = path.join(home, 'state/services/fm-moiras.json');
  for (const changed of [{ ...registration, fingerprint: '0'.repeat(64) }, { ...registration, home: `${home}/other` }]) {
    fs.writeFileSync(file, JSON.stringify(changed));
    await assert.rejects(owner.send(['fm-moiras'], 'invalid identity'), /failed/);
    await assert.rejects(start('fm-moiras'), /service exited before readiness/);
    assert.deepEqual(JSON.parse(fs.readFileSync(file)), changed);
    fs.writeFileSync(file, JSON.stringify(registration));
  }
  fs.writeFileSync(path.join(home, 'state/fm-moiras.meta'), 'kind=ship\n');
  await assert.rejects(owner.send(['fm-moiras'], 'ambiguous identity'), /failed/);
  fs.unlinkSync(path.join(home, 'state/fm-moiras.meta'));
  fs.symlinkSync(file, path.join(home, 'state/services/linked.json'));
  await assert.rejects(owner.send(['linked'], 'symlink identity'), /failed/);
  fs.unlinkSync(path.join(home, 'state/services/linked.json'));
  const request = await owner.send(['fm-moiras'], 'check status', { kind: 'request' });
  const [entry] = await a.call('receive');
  assert.equal(entry.message.id, request.id); assert.equal(entry.message.from, 'supervisor');
  assert.deepEqual(await owner.receive(), []); assert.deepEqual(await b.call('receive'), []);
  await a.call('reply', request.id, 'checked');
  const [reply] = await owner.receive();
  assert.equal(reply.message.from, 'fm-moiras'); assert.equal(reply.message.ref, request.id);
  assert.equal(fs.existsSync(path.join(home, 'state/.wake-queue')), true);
  assert.equal(fs.existsSync(path.join(home, 'wrong-queue')), false);
  await a.call('acknowledge', entry.name); assert.deepEqual(await a.call('receive'), []);
  assert.match(cli('send', 'fm-moiras', 'plain note').toString(), /delivered=fm-moiras/);
  const [plain] = await a.call('receive'); assert.equal(plain.message.text, 'plain note');
  await a.call('acknowledge', plain.name);
  const peer = await a.call('send', ['fm-robin'], 'peer check', { kind: 'request' });
  const [received] = await b.call('receive'); assert.equal(received.message.id, peer.id);
  await b.call('reply', peer.id, 'peer result');
  assert.equal((await a.call('receive'))[0].message.ref, peer.id);
  assert.equal((await owner.receive()).length, 1);
  // The service-only round trip above uses real processes; this task endpoint is a fake.
  fs.mkdirSync(path.join(home, 'fakebin')); fs.mkdirSync(path.join(home, 'worktree'));
  fs.writeFileSync(path.join(home, 'fakebin/tmux'), `#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-task\\n' ;;
  display-message) case "$*" in *pane_current_command*) printf claude ;; *cursor_y*) printf 1 ;; *) printf fakepane ;; esac ;;
  capture-pane) printf '╭────╮\\n│    │\\n╰────╯\\n' ;;
esac
exit 0
`, { mode: 0o755 });
  fs.writeFileSync(path.join(home, 'state/task.meta'), `kind=ship\nbackend=tmux\nwindow=fixture:fm-task\nendpoint_task_id=task\nworktree=${home}/worktree\nproject=${home}/worktree\nharness=claude\n`);
  process.chdir(path.join(home, 'worktree')); process.env.FM_TASK_ID = 'task'; process.env.PATH = `${home}/fakebin:${previousPath}`;
  const worker = messages({ home, root });
  process.chdir(home); delete process.env.FM_TASK_ID; process.env.PATH = previousPath;
  const taskRequest = await worker.send(['fm-moiras'], 'task request', { kind: 'request' });
  const taskEntry = (await a.call('receive')).find(value => value.message.id === taskRequest.id);
  assert.equal(taskEntry.message.from, 'task');
  await a.call('reply', taskRequest.id, 'task result');
  assert.equal((await worker.receive())[0].message.ref, taskRequest.id);
  await assert.rejects(messages({ home, root, service: 'fm-moiras' }).receive(), /failed/);
  assert.throws(() => execFileSync(path.join(root, 'bin/fm-message.sh'), ['service', 'deregister', 'fm-moiras', String(a.child.pid)], { env: { ...process.env, FM_HOME: home }, stdio: 'pipe' }));
  await a.call('close');
  assert.equal(fs.existsSync(path.join(home, 'state/services/fm-moiras.json')), false);
  await assert.rejects(owner.send(['fm-moiras'], 'not supervisor'), /failed/);
  const exited = once(b.child, 'exit'); b.child.kill('SIGKILL'); await exited;
  await assert.rejects(owner.send(['fm-robin'], 'dead service'), /failed/);
  assert.equal((await owner.receive()).length, 1);
  const replacement = await start('fm-robin');
  assert.equal((await replacement.call('receive'))[0].message.id, peer.id);
  const stopped = once(replacement.child, 'exit');
  await replacement.call('finish'); await stopped;
  assert.equal(fs.existsSync(path.join(home, 'state/services/fm-robin.json')), false);
  const telemetry = fs.readdirSync(path.join(home, 'state/fm-message/telemetry')).filter(name => name.endsWith('.jsonl')).flatMap(name => fs.readFileSync(path.join(home, 'state/fm-message/telemetry', name), 'utf8').trim().split('\n').map(JSON.parse));
  assert(telemetry.some(row => row.actor === 'fm-robin' && row.decision === 'service_deregister' && row.outcome === 'accepted'));
  assert(telemetry.some(row => row.actor === 'fm-moiras' && row.event === 'finished' && row.counters.delivered === 1));
  assert(!JSON.stringify(telemetry).includes('peer check'));
});
