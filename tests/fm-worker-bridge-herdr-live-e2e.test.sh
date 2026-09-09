#!/usr/bin/env bash
# Real Firstmate spawn, native Antigravity, and Herdr in a guarded isolated lab.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
fm_live_gate opt-in FM_WORKER_BRIDGE_HERDR_LIVE python3 herdr agy treehouse jq
herdr_forget_inherited_pane
python3 - "$ROOT" <<'PY'
import os, pathlib, subprocess, sys, tempfile, time
root=pathlib.Path(sys.argv[1]); lab=root/'bin/fm-herdr-lab.sh'
session=subprocess.check_output([str(lab),'name','bridge'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='fm-bridge-herdr-') as temporary:
    home=pathlib.Path(temporary).resolve()
    for name in ('state','data','config','projects/probe'): (home/name).mkdir(parents=True,exist_ok=True)
    project=home/'projects/probe'
    subprocess.run(['git','init','-b','main',str(project)],check=True,stdout=subprocess.DEVNULL)
    (project/'README.md').write_text('Temporary bridge verification.\n')
    subprocess.run(['git','-C',str(project),'add','README.md'],check=True)
    subprocess.run(['git','-C',str(project),'commit','-m','initialize test workspace'],check=True,stdout=subprocess.DEVNULL)
    env=dict(os.environ,FM_HOME=str(home),HERDR_SESSION=session,FM_GATE_REFUSE_BYPASS='1')
    subprocess.run([str(root/'bin/fm-brief.sh'),'probe','probe','--scout'],env=env,check=True)
    brief=home/'data/probe/brief.md'
    brief.write_text(brief.read_text().replace('{TASK}','Verify the adapter by writing HERDR_BRIDGE_OK into the scout report.').replace('{FIRSTMATE_SPEC}','Write the report immediately and signal done. Do not modify the project.'))
    def run(*args): return subprocess.check_output([str(lab),'run',session,*args],text=True)
    def wait(predicate):
        for _ in range(900):
            if predicate(): return
            time.sleep(.1)
        raise AssertionError('timeout: '+run('pane','read',pane,'--source','recent-unwrapped','--lines','80'))
    def idle(): return 'state=idle' in (home/'state/probe.busy-state').read_text()
    subprocess.run([str(lab),'provision',session],check=True)
    try:
        subprocess.run([str(root/'bin/fm-spawn.sh'),'probe',str(project),'--scout','--harness','antigravity','--backend','herdr'],env=env,check=True,timeout=60)
        meta=dict(line.split('=',1) for line in (home/'state/probe.meta').read_text().splitlines() if '=' in line)
        pane=meta['herdr_pane_id'];report=home/'data/probe/report.md'
        wait(lambda: idle() and report.exists() and 'HERDR_BRIDGE_OK' in report.read_text())
        print(run('agent','get',pane))
        subprocess.run([str(root/'bin/fm-send.sh'),'probe','Append HERDR_FOLLOWUP_OK to the scout report, acknowledge this inbox message, then stop.'],env=env,check=True,timeout=30)
        wait(lambda: idle() and 'HERDR_FOLLOWUP_OK' in report.read_text() and bool(list((home/'state/probe.inbox/handled').glob('*.msg'))))
        subprocess.run([str(root/'bin/fm-control.sh'),'probe','exit'],env=env,check=True,timeout=30)
        subprocess.run([str(root/'bin/fm-teardown.sh'),'probe'],env=env,check=True,timeout=30)
        print('PASS: real Herdr fm-spawn Antigravity scout, report, busy/idle lifecycle, acknowledged follow-up, control exit and teardown')
    finally:
        subprocess.run([str(lab),'teardown',session],check=True)
PY
