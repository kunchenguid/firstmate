// Real installed SessionManager, isolated home, and public native tool callbacks.
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { EventEmitter } from 'node:events';
import { spawnSync } from 'node:child_process';
const { SessionManager } = await import(pathToFileURL(process.env.FM_NATIVE_SDK + '/dist/index.js'));
const { installTaskContinuation } = await import(pathToFileURL(process.env.PLUGIN));
const watch = (await import(pathToFileURL(process.env.FM_NATIVE_WATCH_PLUGIN))).default;
const home = process.env.FM_HOME;
mkdirSync(home + '/sessions', { recursive: true });
mkdirSync(home + '/state', { recursive: true });
mkdirSync(home + '/data/task', { recursive: true });
writeFileSync(home + '/state/.lock', process.pid + '\n');
writeFileSync(home + '/state/task.meta', `spawn_gen=g1\nkind=ship\nexecutor=local-agent\nproject=${home}/project\nbackend=herdr\nwindow=fixture:w1:p-task\nharness=pi\nendpoint_task_id=task\n`);
mkdirSync(home + '/fakebin');
writeFileSync(home + '/fakebin/herdr', `#!/bin/sh
case "$1 $2" in
  'status --json') echo '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}' ;;
  'pane read') printf '╭────╮\\n│    │\\n╰────╯\\n' ;;
  *) echo '{}' ;;
esac
`);
chmodSync(home + '/fakebin/herdr', 0o755);
process.env.PATH = home + '/fakebin:' + process.env.PATH;
writeFileSync(home + '/data/task/brief.md', "# Task\n## Captain's intent\nOriginal request\n\n## Firstmate spec\nVerify behavior\n");
let session = SessionManager.create(home, home + '/sessions');
session.appendMessage({ role: 'assistant', content: [{ type: 'text', text: 'Isolated SDK fixture' }],
  api: 'openai-completions', provider: 'fixture', model: 'fixture', timestamp: Date.now(), stopReason: 'stop',
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
let tools, hooks;
const ctx = () => ({ sessionManager: session });
async function fire(name, event = {}) {
  for (const fn of hooks.get(name) || []) await fn(event, ctx());
}
function command(name, args, env = {}) {
  const p = spawnSync(process.env.REAL_ROOT + '/bin/' + name, args, {
    encoding: 'utf8', env: { ...process.env, FM_STATE_OVERRIDE: home + '/state', ...env } });
  assert.equal(p.status, 0, p.stderr);
  return p;
}
async function install() {
  tools = new Map(); hooks = new Map();
  const bus = new EventEmitter();
  const pi = { registerTool: t => tools.set(t.name, t),
    registerCommand() {}, sendUserMessage() {},
    on: (name, fn) => hooks.set(name, [...(hooks.get(name) || []), fn]), events: bus,
    appendEntry: (name, value) => session.appendCustomEntry(name, value) };
  watch(pi);
  // Deterministic routine judgment, through the real grant/drain/outcome owners.
  bus.on('fm-branch-supervision:dispatch', offer => {
    assert.deepEqual(offer.eligibleSeqs, ['1']);
    offer.accept((async () => {
      const generation = 'fixture-operation-order';
      command('fm-wake-grant.sh', ['activate', String(process.pid), generation]);
      command('fm-wake-grant.sh', ['publish', generation, ...offer.eligibleSeqs]);
      const env = { FM_SUPERVISION_ACTOR: 'branch', FM_LEASE_HOLDER_PID: String(process.pid),
        FM_BRANCH_GENERATION: generation, PI_CODING_AGENT: 'true' };
      const drained = command('fm-wake-drain.sh', [], env);
      assert.match(drained.stdout, /routine progress/);
      command('fm-branch-outcome.sh', ['append', '--task', 'task', '--verdict', 'routine', '--summary', 'Fixture routine progress verified'], env);
      const ack = drained.stderr.match(/--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)/);
      assert.ok(ack, drained.stderr);
      command('fm-wake-drain.sh', ['--ack-through', ack[1], '--recovery-generation', ack[2]], env);
      command('fm-wake-grant.sh', ['release', generation]);
      command('fm-wake-grant.sh', ['deactivate', String(process.pid), generation]);
      assert.equal(readFileSync(home + '/data/task/brief.md', 'utf8').includes('Add condition A.'), false);
    })());
  });
  const owner = installTaskContinuation(pi, { root: process.env.REAL_ROOT, home,
    state: home + '/state', owns: () => true });
  await fire('session_start');
  return owner;
}
let owner = await install();
async function tool(params, ok = true) {
  await fire('tool_call', { type: 'tool_call', toolName: 'fm_task_continuation', input: params });
  const result = await tools.get('fm_task_continuation').execute('call', params, undefined, undefined, ctx());
  assert.equal(Boolean(result.isError), !ok, JSON.stringify(result));
  return ok ? JSON.parse(result.content[0].text) : result.content[0].text;
}
await tool({ action: 'enroll', task: 'task' });
const a = owner.capture('Add condition A.', 'a');
const b = owner.capture('Add condition B.', 'b');
writeFileSync(home + '/state/task.status', 'working: routine progress\n');
writeFileSync(home + '/state/.wake-queue', '1\t1\tsignal\ttask.status\tsignal: routine progress\n2\t2\tcheck\tpermission\tcheck: MAIN-only permission decision\n');
await tool({ action: 'route', task: 'task', input: a, update_brief: true });
command('fm-send.sh', ['task', 'Add condition A.']);
const messages = readdirSync(home + '/state/task.inbox').filter(name => name.endsWith('.msg'));
assert.equal(messages.length, 1);
assert.ok(readFileSync(home + '/state/task.inbox/' + messages[0], 'utf8').endsWith('Add condition A.'));
assert.equal(readFileSync(home + '/state/.wake-queue', 'utf8'), '2\t2\tcheck\tpermission\tcheck: MAIN-only permission decision\n');
await fire('session_shutdown', { reason: 'reload' });
session = SessionManager.open(session.getSessionFile());
owner = await install();
await tool({ action: 'route', task: 'task', input: a, update_brief: true });
await tool({ action: 'route', task: 'task', input: b, update_brief: true });
const brief = readFileSync(home + '/data/task/brief.md', 'utf8');
assert.equal(brief.split('Add condition A.').length, 2);
assert.equal(brief.split('Add condition B.').length, 2);
assert.equal(owner.inputBarrier(), false);
const evidence = 'data/task/brief.md';
const inspected = await tool({ action: 'inspect', task: 'task', evidence: [evidence] });
assert.match(inspected.assessment.remaining_gap, /a/);
assert.match(inspected.assessment.remaining_gap, /b/);
const judgment = { disposition: 'accepted', outcome: 'Verified both conditions', remaining_gap: '',
  authority_ref: evidence, evidence: [evidence] };
const accepted = await tool({ action: 'assess', task: 'task', basis: inspected.basis, judgment });
assert.equal(accepted.disposition, 'accepted');
assert.equal('coordination' in accepted, false);
await tool({ action: 'assess', task: 'task', basis: inspected.basis, judgment }, false);
await fire('session_shutdown', { reason: 'quit' });
console.log('ok - installed Pi SDK native workflow: routine event handled before authenticated update; MAIN-only event retained; two inputs, reload, retry and inspect/assess CAS without lifecycle JSON or hashes');
console.log('operator workflow: authenticated update + successful send = 2 calls; evidence inspection + semantic acceptance = 2 calls (setup, recovery probes and automatic event-owner commands excluded)');
