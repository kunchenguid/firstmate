#!/usr/bin/env python3
"""Real fm-spawn trust failure and in-place steering recovery in a guarded lab."""
import json, os, shlex, shutil, subprocess, sys, time
from pathlib import Path
root, lab_arg, helper, session = sys.argv[1:5]
normal = sys.argv[5:] == ["normal"]
root=Path(root)
lab=Path(lab_arg)/('launch-normal' if normal else 'launch-recovery')
lab.mkdir()
def run(*args, **kw):
    return subprocess.check_output(list(map(str,args)),text=True,**kw).strip()
def h(*args):return run(helper,'run',session,*args)
real_home=Path.home().resolve()
binary=Path(shutil.which('traex')).resolve()
for p in ('home/data/traex','home/state','home/config','home/projects','repo','wrap','traex-home/cli'):(lab/p).mkdir(parents=True,exist_ok=True)
repo=lab/'repo'; wt=lab/'traex-project'; home=lab/'home'
run('git','-C',repo,'init','-q','-b','main')
run('git','-C',repo,'config','user.name','lab')
run('git','-C',repo,'config','user.email','lab@example.invalid')
(repo/'README.md').write_text('Disposable lab\n')
run('git','-C',repo,'add','README.md');run('git','-C',repo,'commit','-qm','init')
run('git','-C',repo,'worktree','add','-qb','lab',wt)
(home/'config/herdr-presentation-spaces').write_text('off\n')
(home/'config/backlog-backend').write_text('manual\n')
(home/'data/traex/brief.md').write_text("# Task\n\n## Captain's intent\n\nReply FM_LIVE_OK. This is a disposable lab. Do not edit files or delegate.\n\n## Firstmate spec\n\nOnly reply.\n")
provider=root/'tests/busy-transcript-live.py'
if not normal: (lab/'enable-hooks').touch()
(lab/'binaries.json').write_text(json.dumps({'traex':str(binary)}))
(lab/'traex-mode').write_text('launch')
# Harmless private hook, deliberately requiring fresh approval.
(lab/'traex-home/cli/hooks.json').write_text(json.dumps({'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':'true'}]}]}}))
mounts=['bwrap','--die-with-parent','--unshare-user','--unshare-pid','--unshare-net','--ro-bind','/','/','--tmpfs',str(real_home),'--tmpfs','/tmp','--proc','/proc','--dev','/dev','--ro-bind',str(binary.parent),str(binary.parent),'--bind',str(root),str(root),'--bind',str(lab),str(lab),'--tmpfs','/run/user/'+str(os.getuid()),'--chdir',str(wt),'--setenv','HOME',str(lab/'traex-home'),'--setenv','TRAE_HOME',str(lab/'traex-home')]
for key in ('CODEX_THREAD_ID','CODEX_SESSION_ID','HERDR_SOCKET_PATH','HERDR_ENV','TRAE_SESSION_ID'):mounts+=['--unsetenv',key]
wrap=lab/'wrap/traex';wrap.write_text('#!/bin/sh\nexec '+shlex.join(mounts+['--','python3',str(provider),'serve',str(root),str(lab),'traex'])+' "$@"\n');wrap.chmod(0o755)
# Guarded backend wrapper changes only allocation and the executable PATH;
# all actual lifecycle, rendering, process and input operations are real Herdr.
wrapper=lab/'wrap/herdr'
wrapper.write_text('''#!/usr/bin/env python3
import os,subprocess,sys
args=sys.argv[1:]
lab=%r; helper=%r; session=%r
if os.environ.get('LAB_INSIDE')=='1':os.execv(%r,[%r]+args)
if '--session' in args:
 i=args.index('--session');assert args[i+1]==session;del args[i:i+2]
if args[:2]==['pane','run'] and args[3]=='treehouse get':
 args[3]='cd '+%r+'; export PATH='+%r+':"$PATH"'
env=dict(os.environ,LAB_INSIDE='1')
sys.exit(subprocess.call([helper,'run',session]+args,env=env))
''' % (str(lab), helper, session, shutil.which('herdr'), shutil.which('herdr'),
       shlex.quote(str(wt)), shlex.quote(str(lab/'wrap'))))
wrapper.chmod(0o755)
env=dict(os.environ,PATH=str(lab/'wrap')+':'+os.environ['PATH'],FM_HOME=str(home),FM_BACKEND='herdr',HERDR_SESSION=session,FM_SPAWN_NO_GUARD='1',TRAE_HOME=str(lab/'traex-home'),FM_BACKEND_HERDR_TRAEX_START_POLLS='40')
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','HERDR_PANE_ID','HERDR_SOCKET_PATH','HERDR_ENV','HERDR_WORKSPACE_ID','HERDR_TAB_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
print('versions: '+run(binary,'--version')+'; '+h('status','--json'),flush=True)
if not normal: run(helper,'viewer','start',session)
log=open(lab/'spawn.log','w')
p=subprocess.Popen([str(root/'bin/fm-spawn.sh'),'traex',str(repo),'--scout','--harness','traex','--model','gpt-6-astra','--effort','low'],env=env,stdout=log,stderr=log)
try:p.wait(timeout=100)
except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=15)
log.close()
if normal:
    assert p.returncode == 0, (lab/'spawn.log').read_text()
    assert 'launch_state=confirmed' in (home/'state/traex.meta').read_text()
    print('ok - real normal fm-spawn launch confirmed without requiring recovery',flush=True)
    sys.exit(0)
assert p.returncode != 0, 'unapproved hook trust unexpectedly succeeded'
pane=dict(line.split('=',1) for line in (home/'state/traex.meta').read_text().splitlines())['herdr_pane_id']
(lab/'pane').write_text(pane)
(lab/'screen-before.txt').write_text(h('pane','read',pane,'--source','recent','--lines','100'))
(lab/'process-before.json').write_text(h('pane','process-info','--pane',pane))
(lab/'pane-before.json').write_text(h('pane','get',pane))

state=home/'state'
meta=state/'traex.meta'
assert meta.exists() and (state/'traex.busy-gen').exists(), 'failed launch discarded live ownership'
original_meta=meta.read_text()
assert 'launch_state=unconfirmed' in original_meta
original_gen=(state/'traex.busy-gen').read_text()
(wt/'committed-work.txt').write_text('preserve this commit\n')
run('git','-C',wt,'add','committed-work.txt');run('git','-C',wt,'commit','-qm','preserved worker work')
head_before=run('git','-C',wt,'rev-parse','HEAD')
(wt/'uncommitted-work.txt').write_text('preserve unfinished work\n')
work_before=run('git','-C',wt,'status','--porcelain')
screen=(lab/'screen-before.txt').read_text()
assert 'Hooks need review' in screen and 'Trust all and continue' in screen, screen
terminal=json.loads((lab/'pane-before.json').read_text())['result']['pane']['terminal_id']
original_pid=[p['pid'] for p in json.loads((lab/'process-before.json').read_text())['result']['process_info']['foreground_processes'] if p['name']=='traex' and any(arg.startswith('\u2063FIRSTMATE_OP: v1 launch-brief:') for arg in p.get('argv',[]))][0]
def action(*args, ok=True):
    result=subprocess.run(list(map(str,args)),env=env,capture_output=True,text=True,timeout=60)
    assert (result.returncode==0)==ok, (args,result.stdout,result.stderr)
    return result.stdout.strip(), result.stderr
recover=[root/'bin/fm-busy-event.sh','recover',state,'traex']
action(*recover,'--check','--terminal',terminal,'--pid',original_pid,ok=False)
(state/'.last-watcher-beat').touch()
_, before_send=action(root/'bin/fm-send.sh','traex','Read and acknowledge this lab instruction.')
assert 'doorbell did not reach' in before_send or 'doorbell skipped' in before_send, before_send
record=state/'traex.inbox/001.msg'
assert record.exists()
inbox_bytes=record.read_bytes()
assert 'Hooks need review' in h('pane','read',pane,'--source','recent','--lines','60')
print('ok - real hook trust is not accepted; failed spawn preserves original records and durable instruction',flush=True)
# Approve only the generated private hook `true`, after exact screen evidence.
h('pane','send-keys',pane,'enter')
proof_path=lab/'proof.json'
for _ in range(100):
    result=subprocess.run(list(map(str,recover+['--check','--terminal',terminal,'--pid',original_pid])),env=env,capture_output=True,text=True)
    if result.returncode==0:break
    time.sleep(.15)
else:raise AssertionError('late trust never produced recovery provenance: '+result.stderr)
proof_path.write_text(result.stdout)
action(*recover,'--apply',proof_path)
action(*recover,'--apply',proof_path)
assert (state/'traex.busy-gen').read_text()==original_gen
assert record.read_bytes()==inbox_bytes
# Wait for the first real vendor turn to settle, then use the ordinary doorbell
# owner on the existing record without re-enqueueing it.
def wait_idle():
    for _ in range(100):
        value,_=action('python3',root/'bin/fm-busy-transcript.py','read',state,'traex','traex','herdr',session+':'+pane)
        if value=='idle traex-transcript':return
        time.sleep(.15)
    raise AssertionError('initial real TUI turn did not settle')
wait_idle()
(lab/'traex-mode').write_text('ack')
ring_script='set -eu\nsource "$1/bin/fm-backend.sh"\nsource "$1/bin/fm-task-inbox-lib.sh"\nfm_task_inbox_ring herdr "$2" "$3" fm-traex\n'
action('bash','-c',ring_script,'_',root,session+':'+pane,record)
for _ in range(100):
    if (state/'traex.inbox/handled/001.msg').exists():break
    time.sleep(.2)
else:raise AssertionError('ordinary doorbell did not cause the native tool to acknowledge the original inbox record')
assert (state/'traex.inbox/handled/001.msg').read_bytes()==inbox_bytes
print('ok - late trust, same-process recovery and ordinary re-ring executed the original durable instruction',flush=True)
wait_idle()
# Reproduce the legacy disk gap without changing the live lab process: retire
# sidecar, retain original transcript, omit unrecoverable historical spawn_gen.
meta.write_text(''.join(line+'\n' for line in meta.read_text().splitlines() if not line.startswith(('spawn_gen=','launch_state='))))
data=json.loads((state/'traex.busy-session').read_text());data.pop('process_binding',None)
(state/'traex.busy-session').write_text(json.dumps(data)+'\n')
action(root/'bin/fm-busy-event.sh','retire',state,'traex','--gen',original_gen.strip())
proof,_=action(*recover,'--check','--terminal',terminal,'--pid',original_pid);proof_path.write_text(proof)
action(*recover,'--apply',proof_path);action(*recover,'--apply',proof_path)
assert 'spawn_gen=' not in meta.read_text()
assert (state/'traex.busy-gen').read_text()==original_gen
before=json.loads((state/'traex.busy-session').read_text())['bound']['size']
action(root/'bin/fm-send.sh','traex','Reply LEGACY_RECOVERY_OK')
wait_idle()
bound=json.loads((state/'traex.busy-session').read_text())['bound']
assert bound['size']>before
assert 'Firstmate instruction waiting:' in Path(bound['path']).read_text()
print('ok - real legacy missing-generation recovery preserves absent spawn_gen and ordinary fm-send reaches another vendor turn',flush=True)
# Preserve vendor-derived evidence in test stdout without the full prompt.
print('evidence - '+json.dumps({'terminal':terminal,'generation':original_gen.strip(),'session_id':bound['sid'],'recovered_pid':json.loads(proof)['process']['pid']}),flush=True)
assert run('git','-C',wt,'rev-parse','HEAD') == head_before
assert run('git','-C',wt,'status','--porcelain') == work_before
print('ok - recovery preserves the worker commit and unfinished work',flush=True)
# Retire only this lab-created workspace before the independent normal-launch
# scenario uses the same task label. Its filesystem evidence remains intact.
h('workspace','close',pane.split(':')[0])
