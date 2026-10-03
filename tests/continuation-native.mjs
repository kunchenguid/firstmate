// Real installed SessionManager, isolated home, and public compact native tool.
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { EventEmitter } from 'node:events';
import { spawnSync } from 'node:child_process';

const { SessionManager } = await import(pathToFileURL(process.env.FM_NATIVE_SDK + '/dist/index.js'));
const { installTaskContinuation } = await import(pathToFileURL(process.env.PLUGIN));
const watch = (await import(pathToFileURL(process.env.FM_NATIVE_WATCH_PLUGIN))).default;
const periodic = (await import(pathToFileURL(process.env.FM_ROOT_OVERRIDE + '/.pi/extensions/fm-periodic-stow.ts'))).default;
const home = process.env.FM_HOME;

mkdirSync(home + '/sessions', { recursive: true });
mkdirSync(home + '/state', { recursive: true });
mkdirSync(home + '/data/task', { recursive: true });
writeFileSync(home + '/state/.lock', process.pid + '\n');
writeFileSync(home + '/data/backlog.md', '## In flight\n\n## Queued\n\n## Done\n');
writeFileSync(home + '/.tasks.toml', 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n');
writeFileSync(home + '/data/task/brief.md', "# Task\n## Captain's intent\nDeliver the requested behavior\n\n## Firstmate spec\nVerify the public fixture\n");
writeFileSync(home + '/state/task.meta', `spawn_gen=g1\nkind=ship\nexecutor=local-agent\nproject=${home}/project\nbackend=herdr\nwindow=backend-endpoint-not-task-id\nharness=pi\nendpoint_task_id=task\n`);
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

let continuation = await install();
const mainSchema = tools.get('fm_task_continuation').parameters;
assert.deepEqual(Object.keys(mainSchema.properties).sort(), ['action', 'progress', 'record_token', 'task']);
assert.deepEqual(mainSchema.properties.action.anyOf.map(value => value.const), ['read', 'update']);
assert.equal(tools.has('fm_task_intent_update'), false, 'removed intent-update tool remained registered');
assert.deepEqual(JSON.parse(command('fm-task-state.sh', ['progress-list']).stdout).tasks, ['task']);
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
const updated = await tool({ action: 'update', task: 'task', record_token: empty.record_token, progress });
assert.deepEqual({ goal: updated.goal, acceptance: updated.acceptance, current_state: updated.current_state,
  remaining_gap: updated.remaining_gap, next_step: updated.next_step },
{ goal: 'Deliver compact continuation', ...progress });
assert.equal(existsSync(home + '/data/task/lifecycle.json'), false, 'ordinary progress created lifecycle state');

await fire('session_shutdown', { reason: 'topic-switch' });
session = SessionManager.open(session.getSessionFile());
continuation = await install();
const resumed = await tool({ action: 'read', task: 'task' });
assert.equal(resumed.next_step, progress.next_step, 'restart lost the authorized next step');

const backlogBefore = readFileSync(home + '/data/backlog.md');
const unchanged = await tool({ action: 'update', task: 'task', record_token: resumed.record_token, progress });
assert.deepEqual(readFileSync(home + '/data/backlog.md'), backlogBefore, 'unchanged update rewrote progress');
assert.equal(unchanged.record_token, resumed.record_token);

const branch = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-progress', 'task',
  '--expected-token', resumed.record_token, '--progress', JSON.stringify(progress)], {
  encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
    FM_STATE_OVERRIDE: home + '/state', FM_SUPERVISION_ACTOR: 'branch' },
});
assert.equal(branch.status, 6);
assert.match(branch.stderr, /progress belongs to MAIN/);

const settle = await fire('agent_before_settle');
const reminder = settle.flatMap(value => value?.entries || []).find(entry => entry.customType === 'fm-task-continuation');
assert.ok(reminder, 'unfinished intermediate result did not remind MAIN');
assert.match(reminder.content, /task: goal: Deliver compact continuation/);
assert.match(reminder.content, /acceptance: The public fixture passes/);
assert.doesNotMatch(reminder.content, /backend-endpoint-not-task-id/);

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
const completed = await tool({ action: 'update', task: 'task', record_token: unchanged.record_token,
  progress: finalProgress });
assert.equal(completed.remaining_gap, '');
assert.equal(completed.next_step, '');
assert.equal((await fire('agent_before_settle')).some(value => value?.continue), false,
  'accepted compact result remained an active reminder');

const processedRequirement = '确认不要通过枚举逐项覆盖这些场景。\n\n### 验收\n使用行为测试证明开放式分类仍然成立。';
const briefBeforeEdit = readFileSync(home + '/data/task/brief.md', 'utf8');
const backlogBeforeBriefEdit = readFileSync(home + '/data/backlog.md');
writeFileSync(home + '/data/task/brief.md', `# Task\n## Captain's intent\n${processedRequirement}\n\n## Firstmate spec\nVerify the public fixture\n`);
const processedBrief = readFileSync(home + '/data/task/brief.md', 'utf8');
assert.notEqual(processedBrief, briefBeforeEdit, 'ordinary brief edit did not change the task contract');
assert.equal(processedBrief.split(processedRequirement).length, 2,
  'ordinary brief edit did not store literal Chinese multiline processed requirements exactly once');
assert.match(processedBrief, /## Firstmate spec\nVerify the public fixture/,
  'ordinary brief edit lost the existing Firstmate specification');
assert.deepEqual(readFileSync(home + '/data/backlog.md'), backlogBeforeBriefEdit,
  'ordinary brief edit wrote task progress or lifecycle state');
assert.equal(existsSync(home + '/data/task/lifecycle.json'), false,
  'ordinary brief edit created a rich lifecycle record');
const extractedIntent = spawnSync('bash', ['-c', '. "$1/bin/fm-dod-lib.sh"; fm_brief_task_heading_body "$2" "## Captain\'s intent"',
  '_', process.env.REAL_ROOT, home + '/data/task/brief.md'], { encoding: 'utf8' });
assert.equal(extractedIntent.status, 0, extractedIntent.stderr);
assert.match(extractedIntent.stdout, /确认不要通过枚举逐项覆盖这些场景/,
  'downstream review intent extraction did not see the processed requirement');
await fire('session_shutdown', { reason: 'intent-recovery' });
session = SessionManager.open(session.getSessionFile());
continuation = await install();
const correctedRead = await tool({ action: 'read', task: 'task' });
assert.notEqual(correctedRead.record_token, completed.record_token,
  'ordinary brief edit did not invalidate the old progress scope');
assert.equal(correctedRead.recorded, false, 'ordinary brief edit left old progress active');
assert.equal(correctedRead.context_relation, 'mismatch',
  'ordinary brief edit did not expose the stale compact scope');
assert.deepEqual({ acceptance: correctedRead.acceptance, current_state: correctedRead.current_state,
  remaining_gap: correctedRead.remaining_gap, next_step: correctedRead.next_step },
{ acceptance: finalProgress.acceptance, current_state: finalProgress.current_state,
  remaining_gap: '', next_step: '' });
const staleScope = await rawTool({ action: 'update', task: 'task', record_token: completed.record_token,
  progress: { ...progress, current_state: 'Old scope attempted to continue',
    remaining_gap: 'Old scope must remain refused', next_step: 'Do not execute this stale step' } });
assert.equal(staleScope.isError, true, 'old progress scope remained writable after intent changed');
assert.match(staleScope.content[0].text, /task record changed/);
const correctedProgress = { ...progress, current_state: 'The ordinary brief correction is recorded',
  remaining_gap: 'The clarified acceptance check remains', next_step: 'Run the explicitly permitted clarified check' };
const repermitted = await tool({ action: 'update', task: 'task', record_token: correctedRead.record_token,
  progress: correctedProgress });
assert.equal(repermitted.next_step, correctedProgress.next_step,
  'fresh MAIN scope did not permit the revised next step');
assert.equal(repermitted.recorded, true, 'fresh MAIN progress did not restore the edited brief scope');
assert.equal(repermitted.context_relation, 'exact', 'fresh MAIN progress did not bind the edited brief exactly');

const compactRead = await rawTool({ action: 'read', task: 'task' });
const compactResponseBytes = Buffer.byteLength(compactRead.content[0].text);
assert.equal(existsSync(home + '/data/task/lifecycle.json'), false,
  'fresh compact continuation created rich lifecycle state');
assert.equal((await tool({ action: 'read', task: 'task' })).current_state, correctedProgress.current_state,
  'final compact read lost the active progress');

await fire('session_shutdown', { reason: 'quit' });
console.log('evidence - task continuation IO ' + JSON.stringify({
  richLifecycleCalls: 0,
  compactResumeCalls: 1,
  compactReadResponseBytes: compactResponseBytes,
  continuedReminderAdmissions: offered.length + 1,
  progressWritesForUnchangedUpdate: 0,
}));
console.log('ok - installed Pi SDK compact workflow: original-row goal and acceptance survive restart; MAIN receives a canonical-id actionable reminder and accepts only after the gap is cleared');
