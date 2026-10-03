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
async function rawIntent(params) {
  return tools.get('fm_task_intent_update').execute('call', params, undefined, undefined, context());
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
assert.deepEqual(Object.keys(tools.get('fm_task_intent_update').parameters.properties).sort(), ['input', 'task']);
assert.match(tools.get('fm_task_intent_update').parameters.properties.input.description, /Complete processed requirement text/);
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

const beforeChat = session.getBranch().length;
for (const text of ['你好', '继续', '谢谢']) continuation.capture(text);
assert.equal(session.getBranch().length, beforeChat, 'ordinary chat created progress bookkeeping');
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

for (const [params, pattern] of [
  [{ task: 'task' }, /requires processed requirement text/],
  [{ task: 'task', input: '' }, /non-whitespace processed requirement text/],
  [{ task: 'task', input: ' \n\t ' }, /non-whitespace processed requirement text/],
  [{ task: 'task', input: 'invalid\0text' }, /must not contain NUL/],
  [{ task: 'task', input: 'x'.repeat(8193) }, /8192-character limit/],
  [{ task: 'task', input: 'Requirement summary\n## Acceptance\nMust pass.' }, /heading level 3 or deeper/],
]) {
  const invalid = await rawIntent(params);
  assert.equal(invalid.isError, true, `invalid intent input was accepted: ${JSON.stringify(params)}`);
  assert.match(invalid.content[0].text, pattern);
}

const processedRequirement = '确认不要通过枚举逐项覆盖这些场景。\n\n验收：使用行为测试证明开放式分类仍然成立。';
const intentEntriesBefore = session.getBranch().filter(entry =>
  entry.type === 'custom' && entry.customType === 'fm-continuation-input').length;
const processedResult = await rawIntent({ task: 'task', input: processedRequirement });
assert.equal(Boolean(processedResult.isError), false, JSON.stringify(processedResult));
const processedBrief = readFileSync(home + '/data/task/brief.md', 'utf8');
assert.equal(processedBrief.split(processedRequirement).length, 2,
  'literal Chinese multiline processed requirement was not stored exactly once');
assert.doesNotMatch(processedBrief, /Deliver the requested behavior/,
  'processed requirement was appended instead of replacing the final Intent');
assert.match(processedBrief, /## Firstmate spec\nVerify the public fixture/,
  'intent replacement changed another brief subsection');
assert.equal(session.getBranch().filter(entry =>
  entry.type === 'custom' && entry.customType === 'fm-continuation-input').length, intentEntriesBefore,
  'intent replacement created a source or transaction receipt');
assert.equal(existsSync(home + '/state/task-session-index'), false,
  'intent replacement created a session provenance index');
const retriedIntent = await rawIntent({ task: 'task', input: processedRequirement });
assert.equal(Boolean(retriedIntent.isError), false, JSON.stringify(retriedIntent));
assert.equal(readFileSync(home + '/data/task/brief.md', 'utf8'), processedBrief,
  'retry changed or duplicated the final Intent');
const optionRequirement = '--no-enum remains literal requirement text.\n\n### Acceptance\nUse an open-ended behavior test.';
const optionResult = await rawIntent({ task: 'task', input: optionRequirement });
assert.equal(Boolean(optionResult.isError), false, JSON.stringify(optionResult));
assert.match(readFileSync(home + '/data/task/brief.md', 'utf8'), /--no-enum remains literal requirement text/,
  'option-looking processed requirement was reclassified as a CLI option');
const restoreProcessed = await rawIntent({ task: 'task', input: processedRequirement });
assert.equal(Boolean(restoreProcessed.isError), false, JSON.stringify(restoreProcessed));
const extractedIntent = spawnSync('bash', ['-c', '. "$1/bin/fm-dod-lib.sh"; fm_brief_task_heading_body "$2" "## Captain\'s intent"',
  '_', process.env.REAL_ROOT, home + '/data/task/brief.md'], { encoding: 'utf8' });
assert.equal(extractedIntent.status, 0, extractedIntent.stderr);
assert.match(extractedIntent.stdout, /确认不要通过枚举逐项覆盖这些场景/,
  'downstream review intent extraction did not see the processed requirement');

command('fm-tasks-axi.sh', ['add', 'task-other', 'Keep task routing explicit', '--kind', 'ship',
  '--body', 'Another task must keep its own final Intent.', '--start']);
mkdirSync(home + '/data/task-other', { recursive: true });
writeFileSync(home + '/data/task-other/brief.md', "# Task\n## Captain's intent\nOther task intent\n\n## Firstmate spec\nStay isolated\n");
writeFileSync(home + '/state/task-other.meta', `spawn_gen=g1\nkind=ship\nexecutor=local-agent\nproject=${home}/project\nbackend=herdr\nwindow=other-endpoint\nharness=pi\nendpoint_task_id=task-other\n`);
const routedRequirement = 'Only task-other receives this complete processed requirement.';
const routedIntent = await rawIntent({ task: 'task-other', input: routedRequirement });
assert.equal(Boolean(routedIntent.isError), false, JSON.stringify(routedIntent));
assert.match(readFileSync(home + '/data/task-other/brief.md', 'utf8'), new RegExp(routedRequirement));
assert.equal(readFileSync(home + '/data/task/brief.md', 'utf8'), processedBrief,
  'explicit task routing changed a different task brief');
const missingTask = await rawIntent({ task: 'missing-task', input: 'Must not create a task.' });
assert.equal(missingTask.isError, true, 'intent update created or accepted an unknown task');
assert.match(missingTask.content[0].text, /missing or unsafe task data directory/);

const ownerEmpty = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-brief', 'task',
  '--requirement', '   '], {
  encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
    FM_STATE_OVERRIDE: home + '/state', FM_SUPERVISION_ACTOR: 'main' },
});
assert.equal(ownerEmpty.status, 6, 'intent owner accepted empty processed requirement text');
assert.match(ownerEmpty.stderr, /non-whitespace processed requirement text/);
const ownerAbsent = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-brief', 'task'], {
  encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
    FM_STATE_OVERRIDE: home + '/state', FM_SUPERVISION_ACTOR: 'main' },
});
assert.equal(ownerAbsent.status, 6, 'intent owner accepted absent processed requirement text');
assert.match(ownerAbsent.stderr, /requires --requirement TEXT/);
const ownerHeading = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-brief', 'task',
  '--requirement=Summary\n## Escaped section\nMust not escape.'], {
  encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
    FM_STATE_OVERRIDE: home + '/state', FM_SUPERVISION_ACTOR: 'main' },
});
assert.equal(ownerHeading.status, 6, 'intent owner accepted a heading that escapes the Intent subsection');
assert.match(ownerHeading.stderr, /heading level 3 or deeper/);
const unauthorized = spawnSync(process.env.REAL_ROOT + '/bin/fm-task-state.sh', ['update-brief', 'task',
  '--requirement', 'Unauthorized replacement'], {
  encoding: 'utf8', env: { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: home + '/data',
    FM_STATE_OVERRIDE: home + '/state', FM_SUPERVISION_ACTOR: 'branch' },
});
assert.equal(unauthorized.status, 6, 'non-MAIN actor reached the intent transaction owner');
assert.match(unauthorized.stderr, /intent updates belong to MAIN/);

const concurrentRequirements = [
  'Concurrent complete requirement A.\n\nKeep subsection A intact.',
  'Concurrent complete requirement B.\n\nKeep subsection B intact.',
];
const concurrentResults = await Promise.all(concurrentRequirements.map(input => rawIntent({ task: 'task', input })));
assert.equal(concurrentResults.every(result => !result.isError), true,
  `concurrent intent replacements did not serialize: ${JSON.stringify(concurrentResults)}`);
const concurrentIntent = spawnSync('bash', ['-c', '. "$1/bin/fm-dod-lib.sh"; fm_brief_task_heading_body "$2" "## Captain\'s intent"',
  '_', process.env.REAL_ROOT, home + '/data/task/brief.md'], { encoding: 'utf8' });
assert.equal(concurrentIntent.status, 0, concurrentIntent.stderr);
assert.ok(concurrentRequirements.includes(concurrentIntent.stdout.trim()),
  'concurrent intent replacement produced a partial or mixed body');
assert.match(readFileSync(home + '/data/task/brief.md', 'utf8'), /## Firstmate spec\nVerify the public fixture/,
  'concurrent intent replacement changed another brief subsection');

const correction = 'Clarify the processed acceptance wording without quoting the original message.';
await fire('session_shutdown', { reason: 'intent-recovery' });
session = SessionManager.open(session.getSessionFile());
continuation = await install();
const intentResult = await rawIntent({ task: 'task', input: correction });
assert.equal(Boolean(intentResult.isError), false, JSON.stringify(intentResult));
assert.equal(readFileSync(home + '/data/task/brief.md', 'utf8').split(correction).length, 2,
  'intent replacement after reload was not authoritative');
assert.doesNotMatch(readFileSync(home + '/data/task/brief.md', 'utf8'), /确认不要通过枚举/,
  'new processed requirement retained stale prior Intent text');
assert.equal(existsSync(home + '/data/task/lifecycle.json'), false,
  'intent replacement created a rich lifecycle record');
const correctedRead = await tool({ action: 'read', task: 'task' });
assert.notEqual(correctedRead.record_token, completed.record_token,
  'authenticated intent change did not invalidate the old progress scope');
assert.equal(correctedRead.recorded, false, 'authenticated intent change left old progress active');
assert.equal(correctedRead.context_relation, 'mismatch',
  'authenticated intent change did not expose the stale compact scope');
assert.deepEqual({ acceptance: correctedRead.acceptance, current_state: correctedRead.current_state,
  remaining_gap: correctedRead.remaining_gap, next_step: correctedRead.next_step },
{ acceptance: finalProgress.acceptance, current_state: finalProgress.current_state,
  remaining_gap: '', next_step: '' });
const staleScope = await rawTool({ action: 'update', task: 'task', record_token: completed.record_token,
  progress: { ...progress, current_state: 'Old scope attempted to continue',
    remaining_gap: 'Old scope must remain refused', next_step: 'Do not execute this stale step' } });
assert.equal(staleScope.isError, true, 'old progress scope remained writable after intent changed');
assert.match(staleScope.content[0].text, /task record changed/);
const correctedProgress = { ...progress, current_state: 'Authenticated correction is recorded',
  remaining_gap: 'The clarified acceptance check remains', next_step: 'Run the explicitly permitted clarified check' };
const repermitted = await tool({ action: 'update', task: 'task', record_token: correctedRead.record_token,
  progress: correctedProgress });
assert.equal(repermitted.next_step, correctedProgress.next_step,
  'fresh MAIN scope did not permit the revised next step');

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
  progressWritesForThreeOrdinaryChatTurns: 0,
  progressWritesForUnchangedUpdate: 0,
}));
console.log('ok - installed Pi SDK compact workflow: original-row goal and acceptance survive restart; MAIN receives a canonical-id actionable reminder and accepts only after the gap is cleared');
