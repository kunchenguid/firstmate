import os, pathlib, subprocess, time, json

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/daddy/.no-mistakes-upstream-codex/evidence/01M6RXKB0R08340BE8CSAJ6QJ7')
lab = root / '.tmp-pr-base-test/deadline-home'
parent = root / '.tmp-pr-base-test/deadline-parent'
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'GIT_', 'GH_', 'GITHUB_')) or key in ('REX_SESSION', 'REX_BLOCK'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GH_CONFIG_DIR=str(lab/'gh'), GH_ENTERPRISE_TOKEN='synthetic-validation-token', GH_PROMPT_DISABLED='1', HTTPS_PROXY='http://127.0.0.1:1', HTTP_PROXY='http://127.0.0.1:1', NO_PROXY='', no_proxy='', FM_INACTIVE_RECONCILE_BUDGET_SECS='3', FM_INACTIVE_RECONCILE_SECS='60')
events=[]

def run(args, limit=20):
    start=time.monotonic()
    result=subprocess.run(args, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=limit)
    events.append(dict(command=args, exit=result.returncode, duration_seconds=round(time.monotonic()-start,3), output=result.stdout))
    return result

def require(value, message):
    if not value: raise AssertionError(message)

try:
    for home in (lab,parent):
        require(run(['bash','bin/fm-lab-home.sh','create',str(home)]).returncode==0,'lab creation failed')
    (lab/'gh').mkdir()
    (lab/'tmp').mkdir()
    env['TMPDIR']=str(lab/'tmp')
    (lab/'config/github-hosts').write_text('forge.invalid\n')
    (lab/'.fm-secondmate-home').write_text('synthetic-mate\n')
    (lab/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
    # A FIFO is adversarial local configuration for the real gh executable.
    # No writer exists, so opening it blocks without an API or forge emulator.
    os.mkfifo(lab/'gh/config.yml')
    probe=subprocess.Popen(['gh','pr','view','https://forge.invalid/synthetic/repo/pull/1','--json','baseRefName','-q','.baseRefName'],cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    try:
        output,_=probe.communicate(timeout=0.7)
        events.append(dict(probe_pid=probe.pid, exit=probe.returncode, output=output))
        require(False,'real gh did not stall on its isolated config FIFO')
    except subprocess.TimeoutExpired:
        probe.terminate()
        output,_=probe.communicate(timeout=3)
        events.append(dict(command='real gh config FIFO control', pid=probe.pid, stalled_for_seconds=0.7, exit=probe.returncode, output=output))
    project=root/'.tmp-pr-base-test/manual-home/projects/synthetic'
    for task, line, expected in [('a-stalled','done: PR https://forge.invalid/synthetic/repo/pull/1 checks green','expected_base=main\n'),('b-following','failed: synthetic child intentionally failed','')]:
        meta=lab/'state'/f'{task}.meta'
        meta.write_text(f'kind=ship\nmode=direct-PR\nharness=codex\nworktree={project}\nproject={project}\nwindow=fm-{task}\nspawn_gen=synthetic.{task}\n'+expected)
        status=lab/'state'/f'{task}.status'
        status.write_text(line+'\n')
        for path in (meta,status): os.utime(path,(time.time()-130,time.time()-130))
    # Exercise real readiness publication independently of any pane or model.
    result=run(['bash','bin/fm-inactive-reconcile.sh','report','a-stalled'])
    require(result.returncode==0,'unreadable readiness report failed unexpectedly')
    channel=parent/'state/synthetic-mate.status'
    text=channel.read_text() if channel.exists() else ''
    events.append(dict(parent_channel_after_unreadable_report=text))
    require('child a-stalled done:' not in text,'unreadable proof published readiness')
    # The real scan must finish within its unchanged budget plus cleanup reserve.
    result=run(['bash','bin/fm-inactive-reconcile.sh','scan'])
    require(result.returncode==0,'real bounded scan failed')
    require(events[-1]['duration_seconds']<5,'real bounded scan exceeded budget and cleanup reserve')
    result=run(['bash','bin/fm-inactive-reconcile.sh','scan'])
    require(result.returncode==0,'following scan failed')
    text=channel.read_text() if channel.exists() else ''
    events.append(dict(parent_channel_after_scans=text))
    require('child b-following failed:' in text,'stalled destination starved later child outcome')
    require('child a-stalled done:' not in text,'scan published unproved readiness')
    result=run(['ps','-axo','pid=,ppid=,command='])
    survivors=[line for line in result.stdout.splitlines() if 'gh pr view https://forge.invalid/synthetic/repo/pull/1' in line]
    # Keep only scoped process evidence, never retain other operator process rows.
    events[-1]['output']='\n'.join(survivors)
    require(not survivors,'real gh child survived destination timeout')
    remaining_locks=[path.name for path in (lab/'state').iterdir() if path.name.endswith('.lock')]
    events.append(dict(remaining_state_locks=remaining_locks))
    require(not remaining_locks,'state lock survived scan')
    events.append(dict(result='PASS',note='Real reconciliation refused readiness on a stalled real gh read, bounded the scan and delivered the later synthetic failed child. No forge or model was substituted.'))
finally:
    (evidence/'deadline-live.json').write_text(json.dumps(events,indent=2)+'\n')
