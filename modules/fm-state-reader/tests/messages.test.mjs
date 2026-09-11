import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { messages } from '../src/index.mjs';
import { fakeMessages } from './fake-messages.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const request = { schema: 'fm-message.v1', id: `msg-${'1'.repeat(32)}`, thread: null, at: '2026-09-11T00:00:00Z', from: 'recipient', to: ['supervisor'], kind: 'request', ref: null, text: 'check the result' };

test('application message use case uses one fake port and acknowledges only after replying', async () => {
  const port = fakeMessages([{ name: '001.msg', message: request }]);
  const [entry] = await port.receive();
  entry.message.text = 'mutated local copy';
  assert.equal((await port.receive())[0].message.text, request.text);
  await port.reply(entry.message.id, 'checked');
  assert.equal((await port.receive()).length, 1);
  await port.acknowledge(entry.name);
  assert.deepEqual(await port.receive(), []);
  assert.deepEqual(port.calls, [{ method: 'reply', ref: request.id, text: 'checked' }, { method: 'acknowledge', name: '001.msg' }]);
});

test('real message adapter composes with send, receive, reply and guarded acknowledgement', async () => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fm-message-port-')));
  const previousCwd = process.cwd(), previousTask = process.env.FM_TASK_ID, previousPath = process.env.PATH;
  try {
    fs.mkdirSync(path.join(home, 'state'));
    fs.mkdirSync(path.join(home, 'fakebin'));
    fs.mkdirSync(path.join(home, 'worktree'));
    fs.writeFileSync(path.join(home, 'fakebin/tmux'), `#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-recipient\\n' ;;
  display-message) case "$*" in *pane_current_command*) printf claude ;; *cursor_y*) printf 1 ;; *) printf fakepane ;; esac ;;
  capture-pane) printf '╭────╮\\n│    │\\n╰────╯\\n' ;;
esac
exit 0
`, { mode: 0o755 });
    fs.writeFileSync(path.join(home, 'state/recipient.meta'), `kind=ship\nbackend=tmux\nwindow=fixture:fm-recipient\nendpoint_task_id=recipient\nworktree=${home}/worktree\nproject=${home}/worktree\nharness=claude\n`);
    delete process.env.FM_TASK_ID;
    process.env.PATH = `${home}/fakebin:${previousPath}`;
    process.chdir(home);
    const port = messages({ home, root });
    const receipt = await port.send(['recipient'], 'héllo', { thread: 'adapter-case', kind: 'request' });
    assert.deepEqual(receipt.delivered, ['recipient']);
    assert.equal(receipt.partial, false);
    const output = execFileSync(path.join(root, 'bin/fm-message.sh'), ['read', path.join(home, 'state/recipient.inbox/001.msg')], { encoding: 'utf8' });
    const received = JSON.parse(output);
    assert.equal(received.text, 'héllo');
    assert.equal(received.id, receipt.id);
    assert.deepEqual(received.to, ['recipient']);
    execFileSync('/bin/bash', ['-c', '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_deliver_message "$2/state" supervisor "$3"', '_', root, home, JSON.stringify(request)], { env: { ...process.env, FM_HOME: home } });
    assert.deepEqual(await port.receive(), [{ name: '001.msg', message: request }]);
    const reply = await port.reply(request.id, 'checked');
    assert.deepEqual(reply.delivered, ['recipient']);
    assert.equal(fs.existsSync(path.join(home, 'state/supervisor.inbox/001.msg')), true);
    await port.acknowledge('001.msg');
    await port.acknowledge('001.msg');
    assert.deepEqual(await port.receive(), []);
    assert.equal(fs.existsSync(path.join(home, 'state/supervisor.inbox/handled/001.msg')), true);
    await assert.rejects(port.acknowledge('../recipient.inbox/001.msg'), /Invalid/);
    await assert.rejects(port.send(['recipient,unintended'], 'no'), /Invalid/);
    await assert.rejects(port.send(['recipient'], 'no', { from: 'forged' }), /Invalid/);
    await assert.rejects(port.send(['missing'], 'no'), /Message send failed/);
    await assert.rejects(port.send(['_missing'], 'no'), /Message send failed/);
    const replay = await port.retry(receipt.id, receipt.thread);
    assert.equal(replay.id, receipt.id);
    assert.equal(fs.readdirSync(path.join(home, 'state/recipient.inbox')).filter(name => name.endsWith('.msg')).length, 2);
  } finally {
    process.chdir(previousCwd);
    if (previousTask === undefined) delete process.env.FM_TASK_ID; else process.env.FM_TASK_ID = previousTask;
    process.env.PATH = previousPath;
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('root and leaf command help works without a configured home and has no side effects', () => {
  const env = { ...process.env, FM_HOME: '', FM_TASK_ID: '' };
  for (const verb of ['', 'send', 'receive', 'ack', 'read', 'validate', 'stats']) {
    for (const flag of ['-h', '--help']) {
      const output = execFileSync(path.join(root, 'bin/fm-message.sh'), [...(verb ? [verb] : []), flag], { env, encoding: 'utf8' });
      assert.match(output, /Usage: fm-message/);
      assert.match(output, /--thread/);
      assert.match(output, /Example:/);
    }
  }
  assert.match(execFileSync(path.join(root, 'bin/fm-send.sh'), ['peer', '-h'], { env, encoding: 'utf8' }), /Usage: fm-message/);
});
