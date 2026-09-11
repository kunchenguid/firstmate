#!/usr/bin/env bash
# Credentialed live bridge guard: both installed tools, real tmux, follow-up and exit.
# FM_WORKER_BRIDGE_LIVE=1 opts in; FM_BRIDGE_HARNESSES can narrow a diagnostic run.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_WORKER_BRIDGE_LIVE python3 tmux
python3 - "$ROOT" <<'PY'
import os, pathlib, shlex, shutil, subprocess, sys, tempfile, time, uuid
root = pathlib.Path(sys.argv[1])
selected = os.environ.get('FM_BRIDGE_HARNESSES','hermes antigravity').split()
checked = 0
for harness in selected:
    binary = 'hermes' if harness == 'hermes' else 'agy'
    if harness not in ('hermes','antigravity'): raise SystemExit('unknown harness: '+harness)
    if not shutil.which(binary):
        raise SystemExit('ABSENT: '+harness+' (explicit live guard requires every selected harness)')
    checked += 1
    with tempfile.TemporaryDirectory(prefix='fm-bridge-live-') as temporary:
        home = pathlib.Path(temporary)
        state = home/'state';state.mkdir()
        data = home/'data'/'probe';data.mkdir(parents=True)
        workspace = home/'workspace';workspace.mkdir()
        brief = data/'brief.md'
        brief.write_text('Remember the code word sailboat. Reply exactly FIRST_TURN_OK. Do not use tools.')
        gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'),'arm',str(state),'probe'],text=True).strip()
        session = 'fm-bridge-live-'+uuid.uuid4().hex[:10]
        target = session+':fm-probe'
        launch = [str(root/'bin/fm-worker-bridge.sh'),'--harness',harness,'--state',str(state),'--id','probe','--gen',gen,'--brief',str(brief)]
        shell = shlex.join(launch)
        subprocess.run(['tmux','new-session','-d','-s',session,'-n','fm-probe','-c',str(workspace)],check=True)
        (state/'probe.meta').write_text(f'window={target}\nendpoint_task_id=probe\nworktree={workspace}\nproject={workspace}\nharness={harness}\nkind=scout\nmodel=default\neffort=default\n')
        env = dict(os.environ,FM_HOME=str(home))
        def capture():
            return subprocess.check_output(['tmux','capture-pane','-p','-t',target,'-S','-100'],text=True)
        def wait(text):
            for _ in range(600):
                screen = capture()
                if text in screen and 'state=idle' in (state/'probe.busy-state').read_text(): return screen
                if 'worker turn failed' in screen or 'worker error:' in screen:
                    raise AssertionError(harness+': '+screen)
                time.sleep(.1)
            raise AssertionError(harness+' timed out: '+capture())
        try:
            subprocess.run(['tmux','send-keys','-t',target,'-l','bash -c '+shlex.quote(shell)],check=True)
            subprocess.run(['tmux','send-keys','-t',target,'Enter'],check=True)
            wait('FIRST_TURN_OK')
            alive = subprocess.check_output(['bash','-c','source "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"','bridge',str(root),target],text=True)
            assert alive.strip() == 'alive', (harness,alive,capture())
            subprocess.run([str(root/'bin/fm-send.sh'),'probe','Read and acknowledge the Firstmate inbox as needed. Reverse the remembered code word and reply only with the reversed word.'],env=env,check=True,timeout=30)
            wait('taoblias')
            assert list((state/'probe.inbox'/'handled').glob('*.msg')), 'steering inbox was not acknowledged'
            subprocess.run([str(root/'bin/fm-send.sh'),'probe','Spend a full minute considering the previous answer before replying.'],env=env,check=True,timeout=30)
            for _ in range(200):
                if 'state=busy' in (state/'probe.busy-state').read_text(): break
                time.sleep(.05)
            else: raise AssertionError('cancellation turn never entered busy state')
            subprocess.run([str(root/'bin/fm-control.sh'),'probe','interrupt'],env=env,check=True,timeout=30)
            wait('Firstmate worker cancelled')
            subprocess.run([str(root/'bin/fm-control.sh'),'probe','exit'],env=env,check=True,timeout=30)
            print('PASS: '+harness+' real CLI initial turn, exact conversation follow-up, tmux liveness, inbox acknowledgement, fm-send, fm-control interrupt and exit')
        finally:
            subprocess.run(['tmux','kill-session','-t',session],check=False)
if not checked: raise SystemExit('FAIL: no installed harness was checked')
PY
