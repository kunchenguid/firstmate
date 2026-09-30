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
const beforeChat = session.getBranch().length;
for (const text of ['你好', '怎样配置工作目录？', '谢谢', '继续', '批准合并', '停止这个任务']) owner.capture(text);
assert.equal(session.getBranch().length, beforeChat, 'chat capture created durable message goals');
session.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Add condition A.' }], timestamp: Date.now() });
const a = session.getLeafId();
session.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Add condition B.' }], timestamp: Date.now() });
const b = session.getLeafId();
assert.match(await tool({ action: 'route', input: a, update_brief: true }, false), /explicit existing task/);
assert.deepEqual((await tool({ action: 'list' })).pending_updates, []);
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
// A prepared observation can become stale after handled task instructions.
// Reconcile it explicitly with new authority; no effect is executed or replayed.
const waitEvidence = 'data/task/wait.txt';
writeFileSync(home + '/' + waitEvidence, 'Previous delivery wait; read exact current delivery before continuing.');
let current = await tool({ action: 'inspect', task: 'task', evidence: [waitEvidence, 'data/task/brief.md'] });
await tool({ action: 'assess', task: 'task', basis: current.basis, judgment: {
  disposition: 'open', outcome: 'Waiting on previous delivery', remaining_gap: 'Corrected work still required; previously persisted input ' + a, 
  authority_ref: 'data/task/brief.md', evidence: [waitEvidence, 'data/task/brief.md'],
  next_action: { kind: 'wait', payload_ref: waitEvidence, recheck_at: '2000-01-01T00:00:00Z', deadline: '2099-01-01T00:00:00Z' }
} });
assert.match(await tool({ action: 'route', task: 'task', input: b, update_brief: true }, false), /outstanding action/);
writeFileSync(home + '/data/task/correction.txt', 'The old wait is superseded by the acknowledged correction; continue the same task.');
current = await tool({ action: 'inspect', task: 'task', evidence: [waitEvidence, 'data/task/correction.txt'] });
await tool({ action: 'assess', task: 'task', basis: current.basis, judgment: {
  disposition: 'open', outcome: 'Old prepared wait reconciled', remaining_gap: 'Corrected work still required; previously persisted input ' + a, 
  authority_ref: 'data/task/correction.txt', evidence: [waitEvidence, 'data/task/correction.txt'],
  next_action: null, supersede_prepared: true
} });
assert.equal((await tool({ action: 'inspect', task: 'task' })).next_action, null);
// An unrelated large output transcript used to make all routing fail at 16 MiB.
session.appendMessage({ role: 'user', content: [{ type: 'text', text: 'X'.repeat(9 * 1024 * 1024) }], timestamp: Date.now() });
session.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Y'.repeat(9 * 1024 * 1024) }], timestamp: Date.now() });
// Crash after canonical commit but before native presentation acknowledges it.
const append = session.appendCustomEntry.bind(session);
let failPresentation = true;
session.appendCustomEntry = (name, value) => {
  if (name === 'fm-continuation-input' && value.pending === false && failPresentation) {
    failPresentation = false; throw Error('fixture: interrupted after canonical commit');
  }
  return append(name, value);
};
assert.match(await tool({ action: 'route', task: 'task', input: b, update_brief: true }, false), /interrupted/);
await fire('session_shutdown', { reason: 'reload' });
session = SessionManager.open(session.getSessionFile());
owner = await install();
assert.deepEqual((await tool({ action: 'list' })).pending_updates, []);
const stable = session.getBranch().length;
await tool({ action: 'list' });
await tool({ action: 'route', task: 'task', input: b, update_brief: true });
assert.equal(session.getBranch().length, stable, 'confirmed retry accumulated presentation evidence');
const brief = readFileSync(home + '/data/task/brief.md', 'utf8');
assert.equal(brief.split('Add condition A.').length, 2);
assert.equal(brief.split('Add condition B.').length, 2);
assert.equal(owner.inputBarrier(), false);
// Task intake and explicit updates use one ordinary task identity.
mkdirSync(home + '/data/separate-work', { recursive: true });
writeFileSync(home + '/data/separate-work/brief.md', "# Task\n## Captain's intent\nExplain the cause and implement the bounded change\n\n## Firstmate spec\nVerify the same task\n");
writeFileSync(home + '/.tasks.toml', 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n');
const intake = spawnSync('tasks-axi', ['add', 'separate-work', 'Separate actual work', '--kind', 'scout', '--file', home + '/data/backlog.md'], {
  cwd: home, encoding: 'utf8', env: { ...process.env, TASKS_AXI_FILE: home + '/data/backlog.md', TASKS_AXI_BACKEND: 'markdown' }
});
assert.equal(intake.status, 0, intake.stderr);
await tool({ action: 'enroll', task: 'separate-work' });
for (const text of ['Approve the bounded task scope.', 'Stop this task and preserve the report.']) {
  session.appendMessage({ role: 'user', content: [{ type: 'text', text }], timestamp: Date.now() });
  await tool({ action: 'route', task: 'separate-work', input: session.getLeafId(), update_brief: true });
}
const stopped = 'data/separate-work/stop.txt';
writeFileSync(home + '/' + stopped, 'Stop this task and preserve the report.');
const stopBasis = await tool({ action: 'inspect', task: 'separate-work', evidence: [stopped, 'data/separate-work/brief.md'] });
await tool({ action: 'assess', task: 'separate-work', basis: stopBasis.basis, judgment: {
  disposition: 'archived', outcome: 'Explicitly stopped', remaining_gap: 'Earlier requested implementation remains unfinished',
  authority_ref: stopped, evidence: [stopped, 'data/separate-work/brief.md']
} });
await fire('session_shutdown', { reason: 'reload' });
session = SessionManager.open(session.getSessionFile());
owner = await install();
const stoppedAgain = await tool({ action: 'inspect', task: 'separate-work' });
assert.equal(stoppedAgain.disposition, 'archived');
assert.match(stoppedAgain.assessment.remaining_gap, /unfinished/);
assert.equal(readFileSync(home + '/data/backlog.md', 'utf8').split('Separate actual work').length, 2);
// Four legacy assigned receipts may outlive their already confirmed appends.
// Recover their exact proofs without rewriting a private store or accepting work.
mkdirSync(home + '/data/legacy', { recursive: true });
writeFileSync(home + '/data/legacy/brief.md', "# Task\n## Captain's intent\nExisting legacy work\n\n## Firstmate spec\nKeep unfinished work\n");
await tool({ action: 'enroll', task: 'legacy' });
for (let index = 0; index < 4; index++) {
  const id = 'legacy-input-' + index, text = 'Exact original requirement ' + index;
  session.appendCustomEntry('fm-continuation-input', { id, text });
  const entryId = session.appendCustomEntry('fm-continuation-input', { id, text, task: 'legacy', pending: true, update_brief: true });
  command('fm-task-state.sh', ['update-brief', 'legacy', '--session-file', session.getSessionFile(), '--entry-id', entryId, '--input', id]);
}
await fire('session_shutdown', { reason: 'reload' });
session = SessionManager.open(session.getSessionFile());
owner = await install();
assert.deepEqual((await tool({ action: 'list' })).pending_updates, []);
const recoveredEntries = session.getBranch().length;
await tool({ action: 'list' });
await tool({ action: 'route', task: 'legacy', input: 'legacy-input-3', update_brief: true });
assert.equal(session.getBranch().length, recoveredEntries);
assert.equal((await tool({ action: 'inspect', task: 'legacy' })).disposition, 'open');
// A historical unassigned real ask remains selectable after ordinary task intake.
session.appendCustomEntry('fm-continuation-input', { id: 'old-unassigned', text: 'Also preserve the report summary.' });
await fire('session_tree');
assert.equal((await tool({ action: 'list' })).historical_intake_evidence.at(-1).id, 'old-unassigned');
await tool({ action: 'route', task: 'legacy', input: 'old-unassigned', update_brief: true });
assert.equal((await tool({ action: 'list' })).historical_intake_evidence.length, 0);
// Invalid Feishu authority must not silently select an earlier local request.
session.appendCustomMessageEntry('firstmate-feishu-inbound', 'Unverifiable latest message.', true,
  { schema: 'fm-feishu-pi-message.v1', deliveryRef: 'in_' + 'a'.repeat(24), bindingGeneration: 1 });
const beforeUntrusted = session.getBranch().length;
assert.match(await tool({ action: 'route', task: 'legacy', update_brief: true }, false), /immutable delivery proof/);
assert.equal(session.getBranch().length, beforeUntrusted);
// Original-message words, not just a selected receipt id, authenticate an update.
mkdirSync(home + '/data/auth-guard', { recursive: true });
writeFileSync(home + '/data/auth-guard/brief.md', "# Task\n## Captain's intent\nPreserve authority\n\n## Firstmate spec\nReject altered original words\n");
await tool({ action: 'enroll', task: 'auth-guard' });
session.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Actual original words.' }], timestamp: Date.now() });
const original = session.getLeafId();
const bad = session.appendCustomEntry('fm-continuation-input', { id: original, source_entry_id: original,
  text: 'Different substituted words.', task: 'auth-guard', pending: true, update_brief: true });
const rejected = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-brief', 'auth-guard',
  '--session-file', session.getSessionFile(), '--entry-id', bad, '--input', original], { encoding: 'utf8', env: process.env });
assert.notEqual(rejected.status, 0);
assert.match(rejected.stderr, /differ from original/);
assert.equal(readFileSync(home + '/data/auth-guard/brief.md', 'utf8').includes('substituted'), false);
const evidence = 'data/task/brief.md';
const inspected = await tool({ action: 'inspect', task: 'task', evidence: [evidence] });
assert.ok(inspected.assessment.remaining_gap.includes(a));
assert.ok(inspected.assessment.remaining_gap.includes(b));
const judgment = { disposition: 'accepted', outcome: 'Verified both conditions', remaining_gap: '',
  authority_ref: evidence, evidence: [evidence] };
const accepted = await tool({ action: 'assess', task: 'task', basis: inspected.basis, judgment });
assert.equal(accepted.disposition, 'accepted');
assert.equal('coordination' in accepted, false);
await tool({ action: 'assess', task: 'task', basis: inspected.basis, judgment }, false);
await fire('session_shutdown', { reason: 'quit' });
console.log('ok - installed Pi SDK native workflow: routine event handled before authenticated update; MAIN-only event retained; two inputs, reload, retry and inspect/assess CAS without lifecycle JSON or hashes');
console.log('operator workflow: authenticated update + successful send = 2 calls; evidence inspection + semantic acceptance = 2 calls (setup, recovery probes and automatic event-owner commands excluded)');
