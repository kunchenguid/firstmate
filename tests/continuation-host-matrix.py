#!/usr/bin/env python3
"""Additional public-owner acceptance while the candidate runs in a real Pi lab.

Invoked by fm-periodic-stow-herdr-live-e2e.test.sh, never a standalone lifecycle
launcher. All Herdr calls, including nested backend reads, use its lab helper.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

root, home, pi_dir, capture, helper, session = map(str, sys.argv[1:])
root, home, pi_dir, capture = map(Path, (root, home, pi_dir, capture))
env = dict(os.environ, FM_HOME=str(home), FM_SUPERVISION_ACTOR='main', PI_CODING_AGENT='true', PATH=os.environ['FM_FIXTURE_GUARDBIN']+os.pathsep+os.environ['PATH'])
report = home / 'data/host-matrix.json'
results = []


def log(case, **details):
    results.append(dict(case=case, at=time.time(), **details))
    report.write_text(json.dumps(results, indent=2))


def call(script, *args, ok=True):
    p = subprocess.run([str(root / 'bin' / script), *map(str, args)], env=env, text=True, capture_output=True, timeout=20)
    assert (p.returncode == 0) == ok, (script, args, p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout) if ok and p.stdout.strip().startswith(('{', '[')) else p.stdout


def state(op, task, *args, **kw):
    return call('fm-task-state.sh', op, task, *args, **kw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def wait(predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError('host matrix condition timed out')


def enroll(task):
    folder = home / 'data' / task
    folder.mkdir(exist_ok=True)
    (folder / 'brief.md').write_text('Apply the authorized fixture operation and verify its result.\n')
    (home / 'state' / (task + '.meta')).write_text('spawn_gen=g1\nkind=ship\nexecutor=local-agent\n')
    return state('enroll', task)


def reconcile(task, edit):
    for _ in range(5):
        r = state('lifecycle', task)
        edit(r)
        proposal = home / 'data/proposal.json'
        proposal.write_text(json.dumps(r)); proposal.chmod(0o600)
        p = subprocess.run([str(root / 'bin/fm-task-state.sh'), 'reconcile', task, '--expected-revision', str(r['revision']), '--record', str(proposal)], env=env, text=True, capture_output=True)
        if p.returncode == 0:
            return json.loads(p.stdout)
        assert 'revision conflict' in p.stderr, p.stderr
    raise AssertionError('CAS retries exhausted')


def action(task, continuation, kind='wait'):
    def edit(r):
        r['next_action_seq'] = 2
        r['next_action'] = dict(id=task+'.g1.a1', kind=kind, phase='prepared', expected_execution_generation='g1', attempts=0, attempt_limit=2, recheck_at='2026-01-01T00:00:00Z', deadline='2099-01-01T00:00:00Z', payload_ref='data/payload', payload_sha256=sha(home/'data/payload'), receipt_ref=None, continuation=continuation)
    return reconcile(task, edit)


def phase(task, value):
    return state('action', task, '--action-id', task+'.g1.a1', '--phase', value, '--receipt-ref', 'data/readback', '--receipt-sha256', sha(home/'data/readback'))


def offered(task):
    return [r for r in map(json.loads, capture.read_text().splitlines()) if r.get('event') == 'provider_call' and task+': pending:' in r.get('last', '')]


(home/'config/periodic-stow.json').write_text('{"version":1,"enabled":false,"interval_seconds":3600,"min_interval_seconds":3600}')
(home/'data/payload').write_text('Exact immutable operation payload, separate from release evidence.\n')
(home/'data/release').write_text('Fixture dependency owner has not released the dependency.\n')
(home/'data/readback').write_text('Fixture owner read back the operation and evidence.\n')
(home/'data/effect-count').write_text('1')
# A fixture owner publishes a real dependency before the next asynchronous scan.
enroll('matrix-blocker')
action('matrix-blocker', dict(type='blocker', owner='fixture-dependency-owner', dependency='release of fixture dependency', release_ref='data/release', release_sha256=sha(home/'data/release'), recovery_trigger='evidence-change'))
assert state('observe', 'matrix-blocker')['state'] == 'blocked'
initial = len(offered('matrix-blocker'))
time.sleep(2)
assert len(offered('matrix-blocker')) == initial
log('genuine-blocker', state='blocked', fixture_dependency=True)
(home/'data/release').write_text('Fixture dependency owner released the exact dependency.\n')
wait(lambda: len(offered('matrix-blocker')) > initial)
count = len(offered('matrix-blocker')); time.sleep(2)
assert len(offered('matrix-blocker')) == count
assert state('observe', 'matrix-blocker')['state'] == 'pending'
phase('matrix-blocker', 'refused')

def accept(r):
    r['disposition'] = 'accepted'
    r['assessment'].update(remaining_gap='', outcome='Fixture result checked against acceptance.', evidence=[dict(ref='data/readback', sha256=sha(home/'data/readback'))])
reconcile('matrix-blocker', accept)
assert state('observe', 'matrix-blocker')['state'] == 'accepted'
log('release-and-acceptance', requests=count-initial, state='accepted')
# An uncertain effect remains exactly the same action and counter after readback.
enroll('matrix-target')
reconcile('matrix-target', accept)
enroll('matrix-uncertain')
action('matrix-uncertain', dict(type='executor', task_id='matrix-target', execution_generation='g1', inbox_id='000001', sha256='a'*64), 'steer')
phase('matrix-uncertain', 'attempted')
for pending_phase in ('attempted', 'uncertain'):
    if pending_phase == 'uncertain':
        phase('matrix-uncertain', pending_phase)
    guard = subprocess.run(['bash', '-c', '. "$1"; fm_task_lifecycle_execution_guard matrix-uncertain',
                            '_', str(root/'bin/fm-task-lifecycle-lib.sh')], env=env, capture_output=True, text=True)
    assert guard.returncode != 0, (pending_phase, guard.stdout, guard.stderr)
    assert (home/'data/effect-count').read_text() == '1'
    log('effect-readback-guard', phase=pending_phase, refused=True, external_effects=1)
retained = state('lifecycle', 'matrix-uncertain')['next_action']
wait(lambda: any('read back before any retry' in x.get('last', '') for x in offered('matrix-uncertain')))
assert state('lifecycle', 'matrix-uncertain')['next_action'] == retained
assert (home/'data/effect-count').read_text() == '1'
log('uncertain-effect', counter=1, action=retained['id'], phase=retained['phase'])
# More than one scan batch, with the last task pending and all others accepted.
for index in range(9):
    task = f'matrix-fair-{index}'
    enroll(task)
    if index < 8:
        reconcile(task, accept)
wait(lambda: offered('matrix-fair-8'))
assert all(state('observe', f'matrix-fair-{i}')['state'] == 'accepted' for i in range(8))
log('batch-fairness-maintenance-off', tasks=9, tail_pending=True)
# No executor or action is invented when the model ignores both requests.
# The existing session visibly escalates that real coordination failure,
# without spending another request or misclassifying the task as blocked.
def escalation_record():
    record = state('lifecycle', 'matrix-fair-8')
    budgets = record.get('coordination', {}).get('budgets', {}).values()
    return record if any(b.get('escalated_at_ms') for b in budgets) else None
def visible_escalations():
    entries = [json.loads(line) for file in (pi_dir/'sessions').rglob('*.jsonl') for line in file.read_text().splitlines()]
    return [e for e in entries if e.get('customType') == 'fm-task-continuation-escalation'
            and e.get('details', {}).get('task') == 'matrix-fair-8']
visible = wait(visible_escalations, seconds=50)
# Delivery is bounded above; canonical acknowledgement is the next bounded
# round-robin readback, not the same operation as appending the native entry.
exhausted = wait(escalation_record, seconds=30)
assert exhausted['disposition'] == 'open' and exhausted['next_action'] is None
assert len(offered('matrix-fair-8')) == 2
visible = visible_escalations()
assert len(visible) == 1 and visible[0]['display'] is True
log('maintenance-off-exhaustion-escalated', task='matrix-fair-8', requests=2,
    native_entry=visible[0]['id'], displayed=True, disposition='open', next_action=None)
# Stopped work remains archived and cannot be relaunched by another tick.
(home/'data/stop').write_text('Fixture authority stops this goal; retain existing work.\n')
enroll('matrix-stopped')
def archive(r):
    r['disposition'] = 'archived'; r['assessment']['authority_ref'] = 'data/stop'
reconcile('matrix-stopped', archive)
start = len(offered('matrix-stopped')); time.sleep(2)
assert state('observe', 'matrix-stopped')['state'] == 'archived'
assert len(offered('matrix-stopped')) == start
log('stopped-archived', state='archived')
print('ok - real Pi matrix: blocker/release/acceptance, uncertain effect, maintenance-off batch fairness, stopped work')

# A distinct real Pi executor acknowledges the existing durable handoff, then
# stays active inside its deterministic provider until the controller releases it.
def herdr(*args):
    p = subprocess.run([helper, 'run', session, *map(str, args)], text=True, capture_output=True, timeout=20)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return json.loads(p.stdout) if p.stdout.strip().startswith('{') else p.stdout

executor_dir = home.parent/'executor-project'; executor_dir.mkdir()
extension = executor_dir/'executor.ts'
extension.write_text(r'''
import {createAssistantMessageEventStream} from '@earendil-works/pi-ai';
import {existsSync,readdirSync,readFileSync,renameSync,writeFileSync,mkdirSync,appendFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
export default function(pi) {
 const home=process.env.FM_HOME, root=process.env.FM_ROOT_OVERRIDE;
 const state=home+'/state', task='matrix-executor';
 const busy=(value,event)=>execFileSync(root+'/bin/fm-busy-event.sh',['apply',state,task,value,'--gen',process.env.FM_EXECUTOR_GEN,'--source','pi-ext','--event',event]);
 pi.on('project_trust',()=>({trusted:'yes',remember:false}));
 pi.on('session_start',()=>{writeFileSync(home+'/data/executor-ready','ready');busy('idle','session_start')});
 pi.on('agent_start',()=>busy('busy','agent_start'));
 pi.on('agent_settled',()=>busy('idle','agent_settled'));
 pi.on('before_agent_start',()=>{
   const inbox=state+'/'+task+'.inbox';mkdirSync(inbox+'/handled',{recursive:true});
   for(const name of readdirSync(inbox).filter(x=>x.endsWith('.msg'))) {
     const raw=readFileSync(inbox+'/'+name,'utf8');
     if(!raw.includes('handoff=matrix-handoff'))throw Error('unexpected handoff');
     renameSync(inbox+'/'+name,inbox+'/handled/'+name);
     appendFileSync(home+'/data/executor-effects',name+'\n');
   }
 });
 pi.registerProvider('fixture-executor',{baseUrl:'http://127.0.0.1/unused',apiKey:'offline',api:'fixture-executor-api',models:[{id:'deterministic',name:'Fixture executor',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:16384,maxTokens:128}],
 streamSimple(model){
   const stream=createAssistantMessageEventStream();
   const output={role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:Date.now()};
   const poll=()=>{
     if(!existsSync(home+'/data/executor-release')){setTimeout(poll,100);return;}
     output.content.push({type:'text',text:'Fixture operation verified.'});
     stream.push({type:'done',reason:'stop',message:output});stream.end();
   };setTimeout(poll,100);return stream;
 }});
}
''')
created = herdr('workspace', 'create', '--cwd', executor_dir, '--label', 'matrix-executor', '--no-focus')
pane = created['result']['root_pane']['pane_id']
pane_info = herdr('pane','get',pane)['result']['pane']
(home/'data/matrix-executor').mkdir()
(home/'data/matrix-executor/brief.md').write_text('Execute the exact handled fixture handoff and retain its evidence.\n')
(home/'state/matrix-executor.meta').write_text('spawn_gen=g1\nkind=ship\nexecutor=local-agent\n')
meta = home/'state/matrix-executor.meta'
with meta.open('a') as f:
    f.write(f"backend=herdr\nherdr_session={session}\nherdr_workspace_id={pane_info['workspace_id']}\nherdr_tab_id={pane_info['tab_id']}\nherdr_pane_id={pane}\nwindow={session}:{pane}\nharness=pi\nendpoint_task_id=matrix-executor\nworktree={executor_dir}\n")
gen = call('fm-busy-event.sh', 'arm', home/'state', 'matrix-executor').strip()
command = 'exec env ' + ' '.join(shlex.quote(k+'='+v) for k,v in dict(PI_CODING_AGENT_DIR=str(pi_dir), FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root), FM_EXECUTOR_GEN=gen, PATH=env['PATH']).items())
command += ' pi -e '+shlex.quote(str(extension))+' --model fixture-executor/deterministic --no-context-files --session-dir '+shlex.quote(str(pi_dir/'executor-sessions'))
herdr('pane', 'run', pane, 'zsh'); time.sleep(1)
herdr('pane', 'run', pane, command)
wait(lambda: (home/'data/executor-ready').exists())
time.sleep(2)
# Main resumes the exact exhausted/escalated task through the existing handoff owner.
exhausted_key = exhausted['coordination']['observation_key']
# A branch lease proves queueing cannot be mistaken for executor start.
branch_env = dict(env, FM_SUPERVISION_ACTOR='branch', FM_LEASE_HOLDER_PID=(home/'state/.lock').read_text().strip())
p = subprocess.run([str(root/'bin/fm-lease.sh'),'claim','matrix-executor','--actor','branch'],env=branch_env,text=True,capture_output=True)
assert p.returncode == 0, p.stderr
p = subprocess.run([str(root/'bin/fm-task-handoff.sh'),'send','matrix-fair-8','matrix-executor','--id','matrix-handoff','Perform the exact fixture operation once, acknowledging this inbox record.'],env=env,text=True,capture_output=True)
assert p.returncode == 6 and 'not started' in p.stderr+p.stdout, (p.returncode,p.stdout,p.stderr)
log('lease-refusal', exit_code=p.returncode, diagnostic=p.stdout+p.stderr, handoff=call('fm-task-handoff.sh','inspect','matrix-handoff'))
action('matrix-fair-8', dict(type='executor', task_id='matrix-executor', execution_generation='g1', handoff_id='matrix-handoff'), 'steer')
assert state('observe','matrix-fair-8')['state'] == 'pending'
p = subprocess.run([str(root/'bin/fm-lease.sh'),'release','matrix-executor','--actor','branch'],env=branch_env,text=True,capture_output=True)
assert p.returncode == 0, p.stderr
wait(lambda: (home/'data/executor-effects').exists(), 30)
observed = wait(lambda: (r if (r := state('observe','matrix-fair-8'))['state']=='running' else None))
provider = call('fm-task-state.sh','matrix-executor')
assert 'harness busy (pi-ext)' in provider, provider
phase('matrix-fair-8','attempted'); phase('matrix-fair-8','confirmed')
call('fm-task-handoff.sh','retry','matrix-handoff')
messages = list((home/'state/matrix-executor.inbox').rglob('*.msg'))
assert len(messages)==1 and messages[0].parent.name=='handled'
assert len((home/'data/executor-effects').read_text().splitlines())==1
start=len(offered('matrix-fair-8'));time.sleep(2)
assert len(offered('matrix-fair-8'))==start
log('actual-executor-handoff', observed=observed, provider=provider, receipt=str(messages[0]), effects=1, lease_conflict_exit=6)
(home/'data/executor-release').write_text('Fixture operation may finish.')
wait(lambda: 'state: working' not in call('fm-task-state.sh','matrix-executor'))
reconcile('matrix-fair-8',accept)
assert state('observe','matrix-fair-8')['state']=='accepted'
retained_budget = state('lifecycle','matrix-fair-8')['coordination']['budgets'][exhausted_key]
assert retained_budget['attempts'] == 2 and retained_budget.get('escalated_at_ms')
log('executor-acceptance', state='accepted', resumed_escalated_task='matrix-fair-8', original_budget_retained=True)
herdr('pane','send-text',pane,'/quit');herdr('pane','send-keys',pane,'Enter')
print('ok - real executor: lease refusal retained, handled once, actual Pi busy, confirmed readback, semantic acceptance')
