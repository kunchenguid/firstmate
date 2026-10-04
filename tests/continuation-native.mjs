// Real installed SessionManager, isolated home, and public compact native tool.
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { EventEmitter } from 'node:events';
import { spawnSync } from 'node:child_process';

const { SessionManager } = await import(pathToFileURL(process.env.FM_NATIVE_SDK + '/dist/index.js'));
const { validateToolArguments } = await import(pathToFileURL(process.env.FM_NATIVE_SDK +
  '/node_modules/@earendil-works/pi-ai/dist/index.js'));
const { installTaskContinuation } = await import(pathToFileURL(process.env.PLUGIN));
const watch = (await import(pathToFileURL(process.env.FM_NATIVE_WATCH_PLUGIN))).default;
const periodic = (await import(pathToFileURL(process.env.FM_ROOT_OVERRIDE + '/.pi/extensions/fm-periodic-stow.ts'))).default;
const home = process.env.FM_HOME;

mkdirSync(home + '/sessions', { recursive: true });
mkdirSync(home + '/state', { recursive: true });
mkdirSync(home + '/data/task', { recursive: true });
mkdirSync(home + '/project', { recursive: true });
writeFileSync(home + '/state/.lock', process.pid + '\n');
writeFileSync(home + '/data/task/brief.md', "# Task\n## Captain's intent\nDeliver the requested behavior\n\n## Firstmate spec\nVerify the public fixture\n");
writeFileSync(home + '/state/task.meta', `spawn_gen=g1\nkind=ship\nexecutor=local-agent\nproject=${home}/project\nworktree=${home}/project\nbackend=herdr\nwindow=fixture-session:fixture-pane\nherdr_session=fixture-session\nherdr_workspace_id=fixture-workspace\nherdr_tab_id=fixture-tab\nherdr_pane_id=fixture-pane\nharness=pi\nendpoint_task_id=task\n`);
writeFileSync(home + '/state/task.busy-gen', 'g1\n');
writeFileSync(home + '/state/task.busy-state', 'v1 gen=g1 seq=1 state=idle source=pi-ext event=turn-end ts=1\n');
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

function command(name, args, env = {}) {
  const result = spawnSync(process.env.REAL_ROOT + '/bin/' + name, args, {
    encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
      FM_STATE_OVERRIDE: home + '/state', ...env },
  });
  assert.equal(result.status, 0, result.stderr);
  return result;
}

command('fm-tasks-axi.sh', ['add', 'task', 'Deliver compact continuation', '--kind', 'ship',
  '--body', 'Original task details remain authoritative.', '--start']);

let session = SessionManager.create(home, home + '/sessions');
session.appendMessage({ role: 'assistant', content: [{ type: 'text', text: 'Fixture session' }],
  api: 'openai-completions', provider: 'fixture', model: 'fixture', timestamp: Date.now(), stopReason: 'stop',
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });

let tools;
let hooks;
let offerHandler;
function context() { return { sessionManager: session, hasPendingMessages: () => false,
  isIdle: () => true, hasUI: false, ui: { getEditorText: () => '' } }; }
async function fire(name, event = {}) {
  const results = [];
  for (const callback of hooks.get(name) || []) results.push(await callback(event, context()));
  return results;
}
async function install() {
  tools = new Map();
  hooks = new Map();
  const bus = new EventEmitter();
  const pi = {
    registerTool: value => tools.set(value.name, value), registerCommand() {}, sendUserMessage() {},
    sendMessage() {}, on: (name, callback) => hooks.set(name, [...(hooks.get(name) || []), callback]),
    events: bus, appendEntry: (name, value) => session.appendCustomEntry(name, value),
  };
  watch(pi);
  periodic(pi);
  const continuation = installTaskContinuation(pi, { root: process.env.FM_ROOT_OVERRIDE, home,
    state: home + '/state', owns: () => true,
    offer: offer => offerHandler ? offerHandler(offer) : false });
  await fire('session_start');
  return continuation;
}
async function rawTool(params) {
  return tools.get('fm_task_continuation').execute('call', params, undefined, undefined, context());
}
async function tool(params, ok = true) {
  const result = await rawTool(params);
  assert.equal(Boolean(result.isError), !ok, JSON.stringify(result));
  return ok ? JSON.parse(result.content[0].text) : result.content[0].text;
}
async function validatedTool(params, ok = true) {
  const registered = tools.get('fm_task_continuation');
  let validated;
  try {
    validated = validateToolArguments({ name: registered.name, description: registered.description,
      parameters: registered.parameters },
    { type: 'toolCall', id: 'validated-call', name: registered.name, arguments: params });
  } catch (error) {
    assert.equal(ok, false, String(error));
    return String(error);
  }
  assert.equal(ok, true, 'installed Pi argument validation accepted an invalid call');
  return tool(validated);
}

let continuation = await install();
const mainSchema = tools.get('fm_task_continuation').parameters;
assert.match(tools.get('fm_task_continuation').description,/resource cleanup remain with their existing owners/,
  'the public continuation tool invites cleanup-only business gaps');
assert.deepEqual(Object.keys(mainSchema.properties).sort(), ['action', 'progress', 'task']);
assert.deepEqual(mainSchema.properties.action.anyOf.map(value => value.const), ['read', 'update']);
assert.equal(mainSchema.additionalProperties, false, 'continuation schema accepts removed arguments');
assert.equal(mainSchema.properties.progress.additionalProperties, false,
  'continuation progress schema accepts unknown fields');
assert.equal(tools.has('fm_task_intent_update'), false, 'removed intent-update tool remained registered');
assert.deepEqual(JSON.parse(command('fm-task-state.sh', ['progress-list']).stdout).tasks, ['task']);
const taskRecord = home + '/data/task/task.json';
const beforeRemovedToken = readFileSync(taskRecord);
const removedToken = await validatedTool({ action: 'update', task: 'task', record_token: 'legacy-token',
  progress: { acceptance: 'should not write', current_state: 'should not write',
    remaining_gap: 'should not write', next_step: 'should not write' } }, false);
assert.match(removedToken, /record_token/);
assert.deepEqual(readFileSync(taskRecord), beforeRemovedToken,
  'rejected record_token update changed the canonical task record');
const empty = await tool({ action: 'read', task: 'task' });
assert.equal(empty.goal, 'Deliver compact continuation');
assert.equal(empty.recorded, false);
assert.equal('evidence' in empty, false);
assert.equal('authority_ref' in empty, false);

const progress = {
  acceptance: 'The public fixture passes and the compact task row survives restart',
  current_state: 'Implementation returned an intermediate result',
  remaining_gap: 'The restart check and final behavior review remain',
  next_step: 'Restart the session, read the task row, and run the final checks',
};
const updated = await validatedTool({ action: 'update', task: 'task', progress });
assert.deepEqual({ goal: updated.goal, acceptance: updated.acceptance, current_state: updated.current_state,
  remaining_gap: updated.remaining_gap, next_step: updated.next_step },
{ goal: 'Deliver compact continuation', ...progress });
assert.equal(existsSync(home + '/data/task/lifecycle.json'), false, 'ordinary progress created lifecycle state');

await fire('session_shutdown', { reason: 'topic-switch' });
session = SessionManager.open(session.getSessionFile());
continuation = await install();
const resumed = await tool({ action: 'read', task: 'task' });
assert.equal(resumed.next_step, progress.next_step, 'restart lost the authorized next step');

// A genuine captain hold changes task disposition, not the descriptive
// progress. Reads remain useful while the continuation consumer waits instead
// of manufacturing a stale-context reconciliation action.
command('fm-tasks-axi.sh', ['hold', 'task', '--kind', 'captain', '--reason', 'Await publication authority']);
const held = await tool({ action: 'read', task: 'task' });
assert.equal(held.recorded, true, 'captain hold hid canonical descriptive progress');
assert.equal(held.context_relation, 'disposition_only');
assert.equal(held.task_held, 'yes');
assert.equal(held.remaining_gap, progress.remaining_gap);
assert.equal(held.next_step, progress.next_step);
const heldSettle = await fire('agent_before_settle');
assert.equal(heldSettle.some(value => value?.entries?.some(entry =>
  ['fm-task-continuation', 'fm-task-continuation-escalation'].includes(entry.customType))), false,
'captain hold manufactured a continuation or reconciliation action');
command('fm-tasks-axi.sh', ['unhold', 'task']);
assert.equal((await tool({ action: 'read', task: 'task' })).context_relation, 'exact');

const recordBefore = readFileSync(taskRecord);
const mtimeBefore = statSync(taskRecord).mtimeMs;
const unchanged = await tool({ action: 'update', task: 'task', progress });
assert.deepEqual(readFileSync(taskRecord), recordBefore, 'unchanged update rewrote progress');
assert.equal(statSync(taskRecord).mtimeMs, mtimeBefore, 'unchanged update replaced the task record');
assert.equal(unchanged.record_token, resumed.record_token);

const branch = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-progress', 'task',
  '--progress', JSON.stringify(progress)], {
  encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
    FM_STATE_OVERRIDE: home + '/state', FM_SUPERVISION_ACTOR: 'branch' },
});
assert.equal(branch.status, 6);
assert.match(branch.stderr, /progress belongs to MAIN/);

// Runtime completion is intermediate evidence, not semantic task acceptance.
// The canonical business task remains in flight with exactly one identity.
writeFileSync(home + '/state/task.status', 'done: worker returned an intermediate result\n');
assert.match(command('fm-task-state.sh', ['--durable-only', 'task']).stdout, /^state: done /,
  'fixture did not expose terminal runtime evidence');
const settle = await fire('agent_before_settle');
const reminder = settle.flatMap(value => value?.entries || []).find(entry => entry.customType === 'fm-task-continuation');
assert.ok(reminder, 'unfinished intermediate result did not remind MAIN');
assert.match(reminder.content, /task: goal: Deliver compact continuation/);
assert.match(reminder.content, /acceptance: The public fixture passes/);
assert.match(reminder.content, /next step: Restart the session, read the task row, and run the final checks/);
assert.match(reminder.content,/resource cleanup in their existing owners instead of recording them as a new goal gap/,
  'the runtime continuation reminder invites cleanup-only business gaps');
assert.doesNotMatch(reminder.content, /backend-endpoint-not-task-id/);
const afterRestartInventory = JSON.parse(command('fm-tasks-axi.sh', ['inventory']).stdout);
assert.deepEqual(afterRestartInventory.tasks.map(item => item.id), ['task'],
  'restart continuation created a duplicate business task');

// A delivered reminder is pacing evidence, never a finite admission budget.
// Keep advancing the public receiver clock without changing the task row and
// prove that reminders beyond the former two-attempt boundary remain routable.
const firstAdmission = reminder.details.admissions[0];
session.appendCustomEntry('fm-continuation-branch-delivery', {
  admissions: [firstAdmission], sessionFile: session.getSessionFile(), entryId: 'fixture-first', generation: 1,
});
const offered = [];
offerHandler = offer => {
  offered.push(offer.admission);
  offer.delivered({ sessionFile: session.getSessionFile(), entryId: `fixture-${offered.length + 1}`, generation: 1 });
  return true;
};
const realDateNow = Date.now;
let fixtureNow = realDateNow();
Date.now = () => fixtureNow;
try {
  for (let attempt = 0; attempt < 4; attempt++) {
    fixtureNow += 60 * 60 * 1000;
    const result = await fire('agent_before_settle');
    assert.equal(result.some(value => value?.entries?.some(entry =>
      entry.customType === 'fm-task-continuation-escalation')), false,
    'unchanged open progress exhausted a finite continuation budget');
  }
} finally {
  Date.now = realDateNow;
  offerHandler = undefined;
}
assert.equal(offered.length, 4, 'open progress stopped routing after a finite number of reminders');
assert.equal(new Set(offered).size, offered.length, 'continued reminders reused an admission identity');
assert.ok(offered.at(-1).endsWith('.5'), 'continued reminders did not advance past the former attempt limit');

const finalProgress = { ...progress, current_state: 'Requested behavior verified', remaining_gap: '', next_step: '' };
const completed = await tool({ action: 'update', task: 'task', progress: finalProgress });
assert.equal(completed.remaining_gap, '');
assert.equal(completed.next_step, '');
assert.equal((await fire('agent_before_settle')).some(value => value?.continue), false,
  'accepted compact result remained an active reminder');

const compactRead = await rawTool({ action: 'read', task: 'task' });
const compactResponseBytes = Buffer.byteLength(compactRead.content[0].text);
assert.equal(existsSync(home + '/data/task/lifecycle.json'), false,
  'compact continuation created rich lifecycle state');
assert.equal((await tool({ action: 'read', task: 'task' })).current_state, finalProgress.current_state,
  'final compact read lost the active progress');

// Archive is an explicit terminal boundary and must prevent later revival,
// even if historical status and progress evidence remain on disk.
command('fm-tasks-axi.sh', ['archive', 'task']);
assert.deepEqual(JSON.parse(command('fm-task-state.sh', ['progress-list']).stdout).tasks, []);
await fire('session_shutdown', { reason: 'archive-restart' });
session = SessionManager.open(session.getSessionFile());
continuation = await install();
assert.equal((await fire('agent_before_settle')).some(value => value?.continue), false,
  'explicitly archived task revived after restart');
assert.equal(JSON.parse(command('fm-tasks-axi.sh', ['inventory']).stdout).tasks.length, 1,
  'archive recovery duplicated or deleted the canonical task record');

await fire('session_shutdown', { reason: 'quit' });
console.log('evidence - task continuation IO ' + JSON.stringify({
  richLifecycleCalls: 0,
  compactResumeCalls: 1,
  compactReadResponseBytes: compactResponseBytes,
  continuedReminderAdmissions: offered.length + 1,
  progressWritesForUnchangedUpdate: 0,
}));
console.log('ok - installed Pi SDK canonical workflow: intermediate runtime completion remains discoverable after restart, routes the exact next step without duplication, and stops only after MAIN acceptance or explicit archive');
