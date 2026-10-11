"""Real worker canary through FirstMate's production interfaces only."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from importlib.util import module_from_spec, spec_from_file_location

root = Path(sys.argv[1]).resolve()
plan_spec = spec_from_file_location('live_plan', root/'tests/fm-codex-appserver-live-plan.py')
plan = module_from_spec(plan_spec)
plan_spec.loader.exec_module(plan)
scenarios = plan.parse_scenarios(sys.argv[2:])
lab = Path(tempfile.mkdtemp(prefix='fm-as-canary-'))
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env['FM_HOME'] = str(lab)


def run(*args, check=True, timeout=60, cwd=root):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(' '.join(args)+': '+result.stdout+result.stderr)
    return result.stdout.strip() if check else result


def fm(script, *args, **kwargs):
    return run('bash',str(root/'bin'/script),*args,**kwargs)


def wait(predicate, description, seconds=150):
    deadline = time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate():
            print('ok - live '+description,flush=True)
            return
        time.sleep(.25)
    raise AssertionError(description)


def status(task):
    return fm('fm-crew-state.sh',task)


def log(task):
    path=lab/'state'/f'{task}.status'
    return path.read_text() if path.exists() else ''


def metadata(task):
    return dict(line.split('=',1) for line in (lab/'state'/f'{task}.meta').read_text().splitlines() if '=' in line)


def capture(task):
    return run('tmux','capture-pane','-p','-J','-t','firstmate:fm-'+task,'-S','-2000')


def spawn(task, instruction, model='', ship=False):
    if (lab/'config/backlog-backend').read_text().strip()=='markdown':
        fm('fm-tasks-axi.sh','add',task,'Disposable canary '+task,'--kind','ship' if ship else 'scout')
    folder=lab/'data'/task
    folder.mkdir()
    (folder/'brief.md').write_text("# Task\n## Captain's intent\nVerify the real supervised app-server worker.\n## Firstmate spec\n"+instruction+'\n')
    args=[task,str(project),*(['--mode','local-only','--yolo','off'] if ship else ['--scout']),'--harness','codex','--effort','low','--backend','tmux','--codex-appserver']
    if model:
        args+=['--model',model]
    print(fm('fm-spawn.sh',*args,timeout=120),flush=True)
    tasks.append(task)


def stop(task):
    result=fm('fm-control.sh',task,'exit',check=False)
    if result.returncode:
        raise RuntimeError(result.stdout+result.stderr)
    print(result.stdout.strip(),flush=True)
    match=re.search(r'pid=(\d+) exit=0',result.stdout)
    assert match, result.stdout
    assert not Path('/proc/'+match[1]).exists(), 'orphan app-server'
    wait(lambda:'already-stopped' in fm('fm-control.sh',task,'exit'), 'idempotent exit')


tasks=[]
network=socket.socket()
network.bind(('127.0.0.1',0))
network.listen(1)
try:
    fm('fm-lab-home.sh','create',str(lab))
    env['TMUX_TMPDIR']=fm('fm-lab-home.sh','tmux-dir',str(lab))
    shutil.copyfile(root/'.tasks.toml',lab/'.tasks.toml')
    (lab/'config/backlog-backend').write_text('manual\n')
    project=lab/'projects/canary'
    project.mkdir()
    run('git','init','-b','main',cwd=project)
    run('git','config','user.name','Canary',cwd=project)
    run('git','config','user.email','canary@example.invalid',cwd=project)
    (project/'README.md').write_text('Disposable app-server canary.\n')
    # Keep pool slots inside the disposable repository, never the shared pool.
    (project/'treehouse.toml').write_text('max_trees = 4\nroot = "."\n')
    run('git','add','README.md','treehouse.toml',cwd=project)
    run('git','-c','user.name=Canary','-c','user.email=canary@example.invalid','commit','-m','Initialize canary',cwd=project)
    (lab/'data/projects.md').write_text('- canary [local-only] - Disposable verification\n')
    sentinel=lab/'state/sibling.status'
    sentinel.write_text('PRESERVE\n')
    base=run('git','rev-parse','HEAD',cwd=project)
    sibling=lab/'sibling-worktree'
    run('git','worktree','add','-b','sibling',str(sibling),cwd=project)
    sibling_git=Path(run('git','rev-parse','--absolute-git-dir',cwd=sibling))
    sibling_report=lab/'data/sibling/report.md'
    sibling_report.parent.mkdir()
    sibling_report.write_text('PRESERVE REPORT\n')
    sibling_private=Path(tempfile.mkdtemp(prefix='fm-canary-sibling-',dir='/dev/shm'))
    run('git','init','--bare',str(sibling_private))
    probes={
        'fleet': sentinel,
        'canonical_ref': project/'.git/refs/heads/canary-denial',
        'canonical_object': project/'.git/objects/canary-denial',
        'sibling_metadata': sibling_git/'canary-denial',
        'sibling_worktree': sibling/'canary-denial',
        'sibling_report': sibling_report,
        'sibling_private_ref': sibling_private/'refs/heads/canary-denial',
        'sibling_private_object': sibling_private/'objects/canary-denial',
    }
    for name, path in probes.items():
        if name not in ('fleet','sibling_report'):
            path.write_text(base+'\n' if name.endswith('_ref') else 'PRESERVE\n')
    before={name:path.read_bytes() for name,path in probes.items()}
    command="""python3 - <<'PYSEC'
import glob,json,socket
from pathlib import Path
result={}
Path('positive-control').write_text('WORKSPACE_OK')
result['workspace']='WORKSPACE_OK'
for name,path in PROBES.items():
 try:
  Path(path).write_text('ATTACK')
  result[name]='WRITE_SUCCEEDED'
 except OSError as e:
  result[name]='DENIED:'+str(e.errno)
s=socket.socket(socket.AF_UNIX)
try:
 s.connect(glob.glob(SOCKETS)[0])
 result['socket']='CONNECTED'
except OSError as e:
 result['socket']='DENIED:'+str(e.errno)
finally:
 s.close()
s=socket.socket()
s.settimeout(2)
try:
 s.connect(('127.0.0.1',NETWORK_PORT))
 result['network']='CONNECTED'
except OSError as e:
 result['network']='DENIED:'+str(e.errno)
finally:
 s.close()
print(json.dumps(result))
Path('security-proof.json').write_text(json.dumps(result))
PYSEC""".replace('PROBES',repr({name:str(path) for name,path in probes.items()})).replace('SOCKETS',repr(str(lab/'state/.appserver-*.sock'))).replace('NETWORK_PORT',str(network.getsockname()[1]))
    if scenarios is None:
        spawn('success','Call firstmate_report progress CANARY_STARTED. Execute sleep 15 for an active steer. Then execute this exact harmless sandbox check:\n'+command+'\nWrite ship.txt with UNIQUE_SHIP_CONTENT, git add ship.txt positive-control security-proof.json, and git commit on the already provisioned branch. Write git rev-parse HEAD to the untracked file expected-head. Then call firstmate_report needs-decision CANARY_QUESTION and wait for the answer. Finally report result including the steer marker, answer, and security outcomes. Do not push, merge, create PRs or write FirstMate state.',ship=True)
        wait(lambda:'state: working' in status('success'),'working projection')
        steer=fm('fm-send.sh','success','Include UNIQUE_STEER_418 in the final result. Continue the brief.')
        turn=steer.split()[-1]
        print('ok - live steer '+turn,flush=True)
        wait(lambda:'needs-decision' in log('success'),'decision opens')
        assert 'state: parked' in status('success')
        assert 'done' not in log('success')
        key=re.search(r'\[key=([^]]+)\]',log('success')).group(1)
        assert fm('fm-send.sh','success','late ordinary steer',check=False).returncode!=0
        meta=dict(line.split('=',1) for line in (lab/'state/success.meta').read_text().splitlines() if '=' in line)
        work=Path(meta['worktree'])
        expected=(work/'expected-head').read_text().strip()
        assert re.fullmatch('[0-9a-f]{40,64}',expected) and expected!=base
        private=Path(run('git','rev-parse','--absolute-git-dir',cwd=work))
        assert os.stat(private).st_dev!=os.stat(project).st_dev
        assert run('git','rev-parse','HEAD',cwd=work)==expected
        assert run('git','cat-file','-e',expected,cwd=project,check=False).returncode!=0
        assert run('git','show-ref','--verify','refs/heads/'+meta['branch'],cwd=project,check=False).returncode!=0
        fm('fm-send.sh','success','--resolve-key',key,'UNIQUE_ANSWER_73921')
        assert fm('fm-send.sh','success','--resolve-key',key,'duplicate',check=False).returncode!=0
        wait(lambda:'state: done' in status('success'),'same-turn completion')
        assert 'UNIQUE_STEER_418' in log('success') and 'UNIQUE_ANSWER_73921' in log('success')
        trace=capture('success')
        assert '"id": "'+turn+'"' in trace and '"status": "completed"' in trace
        meta=dict(line.split('=',1) for line in (lab/'state/success.meta').read_text().splitlines() if '=' in line)
        proof=json.loads((Path(meta['worktree'])/'security-proof.json').read_text())
        assert proof['workspace']=='WORKSPACE_OK'
        assert all(proof[name] in ('DENIED:1','DENIED:13','DENIED:30') for name in probes)
        assert proof['socket'] in ('DENIED:1','DENIED:13')
        assert proof['network'] in ('DENIED:1','DENIED:13')
        assert all(path.read_bytes()==before[name] for name,path in probes.items())
        assert run('git','rev-parse',meta['branch'],cwd=project)==expected
        assert run('git','rev-parse','HEAD',cwd=work)==expected
        assert run('git','show',expected+':ship.txt',cwd=project)=='UNIQUE_SHIP_CONTENT'
        assert run('git','rev-parse','main',cwd=project)==base
        assert run('git','rev-parse','HEAD',cwd=sibling)==base
        assert sentinel.read_text()=='PRESERVE\n'
        assert 'commandExecution' in trace and 'DENIED' in trace
        assert fm('fm-send.sh','success','after completion',check=False).returncode!=0
        (lab/'success-trace.txt').write_text(trace)
        print('ok - live kernel sandbox denial '+json.dumps(proof),flush=True)
        stop('success')
        assert not private.exists()
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (lab/'config/backlog-backend').write_text('markdown\n')
    if plan.selected('scout-success', scenarios):
        spawn('scout','Call firstmate_report needs-decision SCOUT_HELD_QUESTION and wait for the answer. Then call firstmate_report result with message UNIQUE_SCOUT_RESULT and a complete Markdown report of at least 2000 characters containing UNIQUE_SCOUT_REPORT and the answer. Do not commit or write fleet files.')
        wait(lambda:'needs-decision' in log('scout'),'scout decision opens')
        key=re.search(r'\[key=([^]]+)\]',log('scout')).group(1)
        fm('fm-captain-hold.sh','hold',key,'--title','Canary decision','--reason','Choose','--origin','scout')
        fm('fm-captain-hold.sh','complete','scout',key)
        real_tasks=shutil.which('tasks-axi')
        assert real_tasks, 'tasks-axi is required for held-answer canary'
        fakebin=lab/'failure-bin'
        fakebin.mkdir()
        wrapper=fakebin/'tasks-axi'
        wrapper.write_text('#!/bin/sh\nfor arg do\n if [ "$arg" = done ]; then exit 42; fi\ndone\nexec '+shlex.quote(real_tasks)+' "$@"\n')
        wrapper.chmod(0o755)
        old_path=env['PATH']
        try:
            env['PATH']=str(fakebin)+':'+old_path
            assert fm('fm-send.sh','scout','--resolve-key',key,'UNIQUE_HELD_ANSWER',check=False).returncode!=0
        finally:
            env['PATH']=old_path
        time.sleep(1)
        assert 'state: done' not in status('scout')
        report=lab/'data/scout/report.md'
        assert not report.exists()
        fm('fm-captain-hold.sh','open',key)
        fm('fm-send.sh','scout','--resolve-key',key,'UNIQUE_HELD_ANSWER')
        assert fm('fm-captain-hold.sh','open',key,check=False).returncode in (1,3)
        assert fm('fm-send.sh','scout','--resolve-key',key,'duplicate',check=False).returncode!=0
        wait(lambda:'state: done' in status('scout'),'scout publication after held-answer retry')
        report_body=report.read_bytes()
        assert list(report.parent.glob('report.md'))==[report]
        assert len(report_body)>2000 and b'UNIQUE_SCOUT_REPORT' in report_body and b'UNIQUE_HELD_ANSWER' in report_body
        assert sibling_report.read_bytes()==before['sibling_report']
        scout_meta=metadata('scout')
        assert scout_meta['endpoint_task_id']=='scout' and scout_meta['kind']=='scout'
        assert scout_meta['busy_gen']==(lab/'state/scout.busy-gen').read_text().strip()
        (lab/'scout-trace.txt').write_text(capture('scout'))
        stop('scout')
        fm('fm-teardown.sh','scout',timeout=120)
        assert report.read_bytes()==report_body
        assert not (lab/'state/scout.meta').exists()
        assert re.search(r'^\s*state: done$',fm('fm-tasks-axi.sh','show','scout'),re.MULTILINE)
        print('ok - live scout report survives teardown and held-answer retry',flush=True)
    if plan.selected('scout-failure', scenarios):
        spawn('failure','Do not execute commands.','firstmate-deliberately-unavailable')
        wait(lambda:'state: failed' in status('failure'),'failed turn never complete')
        report=lab/'data/failure/report.md'
        assert not report.exists()
        assert 'done' not in log('failure')
        (lab/'failure-trace.txt').write_text(capture('failure'))
        stop('failure')
    if plan.selected('scout-interrupt', scenarios):
        spawn('cancel','Call firstmate_report result with message UNIQUE_INTERRUPT_RESULT and a complete Markdown report of at least 2000 characters containing UNIQUE_INTERRUPT_REPORT. Then execute touch cancel-report-submitted && sleep 60. Do not write fleet files.')
        work=Path(metadata('cancel')['worktree'])
        wait(lambda:(work/'cancel-report-submitted').exists(),'scout report submitted before interruption')
        report=lab/'data/cancel/report.md'
        assert not report.exists()
        stop('cancel')
        assert 'state: failed' in status('cancel') and 'done' not in log('cancel')
        assert not report.exists()
        (lab/'cancel-trace.txt').write_text(capture('cancel'))
        assert '"status": "interrupted"' in capture('cancel')
        assert not list((lab/'state').glob('*.sock'))
        print('ok - live scout interruption suppresses its submitted report and reaps app-server',flush=True)
    print('CANARY_PASS evidence='+str(lab),flush=True)
finally:
    network.close()
    for task in tasks:
        fm('fm-control.sh',task,'exit',check=False)
    if 'TMUX_TMPDIR' in env:
        run('tmux','kill-server',check=False)
        fm('fm-lab-home.sh','teardown',str(lab),check=False)
    print('Retained disposable task evidence: '+str(lab),flush=True)
    if 'sibling_private' in globals():
        shutil.rmtree(sibling_private)
