#!/usr/bin/env bash
# Persistent bridge: actual subprocess lifecycle, session binding, failure and cancellation.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, signal, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-bridge-test-') as temp:
    base = pathlib.Path(temp)
    fake = base / 'bin'; fake.mkdir()
    for name in ('agy', 'hermes', 'herdr'):
        binary = fake / name
        binary.write_text('''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
with open(os.environ['BRIDGE_CALLS'], 'a') as log: log.write(json.dumps(sys.argv) + '\\n')
if sys.argv[0].endswith('herdr') and os.environ.get('BRIDGE_HERDR_FAIL') in sys.argv:
    print('herdr refused the publication', file=sys.stderr); sys.exit(3)
if os.environ.get('BRIDGE_CHILD_PID'):
    with open(os.environ['BRIDGE_CHILD_PID'], 'w') as marker: marker.write(str(os.getpid()))
if os.environ.get('BRIDGE_DESCENDANT'):
    subprocess.Popen([sys.executable, '-c', "import os,signal,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(os.environ['BRIDGE_DESCENDANT'],'w').write(str(os.getpid())); time.sleep(30)"])
    while not os.path.exists(os.environ['BRIDGE_DESCENDANT']): time.sleep(.01)
if os.environ.get('BRIDGE_IGNORE_SIGINT'): signal.signal(signal.SIGINT, signal.SIG_IGN)
if os.environ.get('BRIDGE_SLEEP'): time.sleep(30)
if os.environ.get('BRIDGE_FAIL'): sys.exit(7)
if os.environ.get('BRIDGE_HUGE'):
    if sys.argv[0].endswith('hermes'): print('session_id: exact-hermes-session', file=sys.stderr)
    sys.stdout.buffer.write(json.dumps({'conversation_id':'conversation-exact','status':'SUCCESS','response':'\\u754c'*700000}, ensure_ascii=False).encode())
    sys.exit(0)
if os.environ.get('BRIDGE_BANNER'): print('Antigravity update available')
if os.environ.get('BRIDGE_TRUNCATED'): print('error: print timeout expired (response may be truncated)', file=sys.stderr)
if os.environ.get('BRIDGE_STDERR_NOISE'): print('error: benign diagnostic', file=sys.stderr)
if '--print' in sys.argv and sys.argv[sys.argv.index('--print')+1].endswith('fail-json'):
    print(json.dumps({'status':'FAILURE','response':'failed without id'})); sys.exit(0)
if sys.argv[0].endswith('hermes'): print('session_id: exact-hermes-session', file=sys.stderr)
print(json.dumps({'conversation_id':'conversation-exact','status':'SUCCESS','response':'BRIDGE_OK'}))
''')
        binary.chmod(0o755)
    clock = fake / 'date'
    clock.write_text('#!/bin/sh\n[ -z "$BRIDGE_SLOW_CLOCK" ] || sleep 0.4\nexec /bin/date "$@"\n')
    clock.chmod(0o755)
    env = dict(os.environ, PATH=str(fake)+os.pathsep+os.environ['PATH'], BRIDGE_CALLS=str(base/'calls'))
    def envelope(body):
        return subprocess.run([str(root/'bin/fm-operational-input.sh'),'encode','launch-brief'],
            input=body,text=True,capture_output=True,check=True).stdout
    for harness in ('antigravity', 'hermes'):
        state = base / harness; state.mkdir()
        brief = state / 'brief'; brief.write_text('literal $HOME `no-exec`')
        gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm',str(state),'probe'], text=True).strip()
        command = [sys.executable,str(root/'bin/fm-worker-bridge.py'),'--harness',harness,'--state',str(state),'--id','probe','--gen',gen,'--brief',str(brief)]
        herdr_env = dict(env, HERDR_ENV='1', HERDR_PANE_ID='w1:p2', HERDR_SESSION='fm-lab-portable', HERDR_BIN_PATH=str(fake/'herdr'))
        result = subprocess.run(command + ['--backend','herdr'],input='/exit\n',capture_output=True,text=True,env=herdr_env,timeout=20)
        assert result.returncode == 0, result.stderr
        lifecycle = [json.loads(line) for line in (base/'calls').read_text().splitlines() if json.loads(line)[0].endswith('/herdr')]
        assert any('--state' in call and call[call.index('--state')+1] == 'working' for call in lifecycle)
        assert any('--state' in call and call[call.index('--state')+1] == 'idle' for call in lifecycle)
        assert lifecycle[-1][2] == 'release-agent'
        assert all(call[call.index('--session')+1] == 'fm-lab-portable' for call in lifecycle)
        (base/'calls').write_text('')
        result = subprocess.run(command, input='follow up\n/exit\n',capture_output=True,text=True,env=env,timeout=20)
        assert result.returncode == 0, result.stderr
        assert result.stdout.count('BRIDGE_OK') == 2, result.stdout
        calls = [json.loads(line) for line in (base/'calls').read_text().splitlines()[-2:]]
        if harness == 'antigravity':
            assert '--conversation' not in calls[0]
            assert calls[0][calls[0].index('--print')+1] == envelope('literal $HOME `no-exec`'), calls[0]
            assert calls[0][calls[0].index('--print-timeout')+1] == '24h', calls[0]
            assert calls[1][calls[1].index('--conversation')+1] == 'conversation-exact'
        else:
            assert calls[0][calls[0].index('--continue')+1] == calls[1][calls[1].index('--continue')+1]
        assert 'state=idle' in (state/'probe.busy-state').read_text()
        assert (state/'probe.turn-ended').exists()
        huge = subprocess.run(command,input='/exit\n',capture_output=True,text=True,env=dict(env,BRIDGE_HUGE='1'),timeout=30)
        assert huge.returncode == 0, huge.stderr[:400]
        assert 'exceeded the 1 MiB protocol limit' in huge.stdout, huge.stdout[:400]
        assert 'turn failed' in huge.stdout, huge.stdout[:400]
        if harness == 'antigravity':
            result = subprocess.run(command,input='fail-json\nretry\n/exit\n',capture_output=True,text=True,env=env,timeout=20)
            assert result.returncode == 0, result.stderr
            calls = [json.loads(line) for line in (base/'calls').read_text().splitlines()[-3:]]
            assert calls[2][calls[2].index('--conversation')+1] == 'conversation-exact'
            assert 'turn failed' in result.stdout
            unbound = state/'unbound-brief'; unbound.write_text('fail-json')
            result = subprocess.run(command[:-1]+[str(unbound)],input='retry\n/exit\n',capture_output=True,text=True,env=env,timeout=20)
            assert result.returncode == 0, result.stderr
            calls = [json.loads(line) for line in (base/'calls').read_text().splitlines()[-2:]]
            assert '--conversation' not in calls[1], calls[1]
            assert calls[1][calls[1].index('--print')+1] == envelope('fail-json') + '\n\nretry', calls[1]
            truncated = subprocess.run(command,input='again\n/exit\n',capture_output=True,text=True,env=dict(env,BRIDGE_TRUNCATED='1'),timeout=20)
            assert truncated.returncode == 0, truncated.stderr
            assert truncated.stdout.count('turn failed') == 2, truncated.stdout
            calls = [json.loads(line) for line in (base/'calls').read_text().splitlines()[-2:]]
            assert calls[1][calls[1].index('--conversation')+1] == 'conversation-exact', calls[1]
            noise = subprocess.run(command,input='/exit\n',capture_output=True,text=True,env=dict(env,BRIDGE_STDERR_NOISE='1'),timeout=20)
            assert noise.returncode == 0, noise.stderr
            assert 'turn failed' not in noise.stdout, noise.stdout
            banner = subprocess.run(command,input='again\n/exit\n',capture_output=True,text=True,env=dict(env,BRIDGE_BANNER='1'),timeout=20)
            assert banner.returncode == 0, banner.stderr
            assert banner.stdout.count('turn failed') == 2, banner.stdout
        result = subprocess.run(command,input='/exit\n',capture_output=True,text=True,env=dict(env,BRIDGE_FAIL='1'),timeout=20)
        assert 'turn failed' in result.stdout
        assert 'blocked:' in (state/'probe.status').read_text()
        process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_SLEEP='1',BRIDGE_CHILD_PID=str(state/'child.pid')))
        for _ in range(100):
            if 'state=busy' in (state/'probe.busy-state').read_text() and (state/'child.pid').exists(): break
            time.sleep(.05)
        else: raise AssertionError('never busy')
        time.sleep(.2)
        process.send_signal(signal.SIGINT)
        output,error = process.communicate('/exit\n',timeout=12)
        assert process.returncode == 0, error
        assert 'cancelled' in output, output
        assert 'state=idle' in (state/'probe.busy-state').read_text()
        child_pid = int((state/'child.pid').read_text())
        try: os.kill(child_pid, 0)
        except ProcessLookupError: pass
        else: raise AssertionError('cancel left a child alive')
        (state/'probe.turn-ended').unlink()
        process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_SLEEP='1',BRIDGE_IGNORE_SIGINT='1',BRIDGE_CHILD_PID=str(state/'double.pid')))
        for _ in range(200):
            if 'state=busy' in (state/'probe.busy-state').read_text() and (state/'double.pid').exists(): break
            time.sleep(.05)
        else: raise AssertionError('never busy before the double interrupt')
        time.sleep(.2)
        process.send_signal(signal.SIGINT)
        time.sleep(.5)
        process.send_signal(signal.SIGINT)
        output,error = process.communicate('/exit\n',timeout=30)
        assert process.returncode == 0, error
        assert 'cancelled' in output, output
        assert 'state=idle' in (state/'probe.busy-state').read_text()
        assert (state/'probe.turn-ended').exists()
        process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_SLEEP='1',BRIDGE_CHILD_PID=str(state/'term-child.pid')))
        for _ in range(100):
            if (state/'term-child.pid').exists(): break
            time.sleep(.05)
        else: raise AssertionError('termination child never started')
        child_pid = int((state/'term-child.pid').read_text())
        process.terminate()
        process.communicate(timeout=12)
        try: os.kill(child_pid, 0)
        except ProcessLookupError: pass
        else: raise AssertionError('termination left a child alive')
        descendant = state/'descendant.pid'
        process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_SLEEP='1',BRIDGE_DESCENDANT=str(descendant)))
        for _ in range(100):
            if descendant.exists(): break
            time.sleep(.05)
        else: raise AssertionError('descendant never started')
        descendant_pid = int(descendant.read_text())
        process.send_signal(signal.SIGINT)
        output,error = process.communicate('/exit\n',timeout=15)
        assert process.returncode == 0, error
        status = subprocess.run(['ps','-p',str(descendant_pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
        assert not status or status.startswith('Z'), 'live descendant survived cancellation: '+status
        if harness == 'antigravity':
            (state/'probe.turn-ended').unlink()
            late = state/'late.pid'
            process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_DESCENDANT=str(late)))
            for _ in range(200):
                if late.exists(): break
                time.sleep(.05)
            else: raise AssertionError('late-interrupt descendant never started')
            late_pid = int(late.read_text())
            time.sleep(.3)
            process.send_signal(signal.SIGINT)
            output,error = process.communicate('/exit\n',timeout=25)
            assert process.returncode == 0, error
            assert 'BRIDGE_OK' in output, output
            assert 'cancelled' not in output, output
            assert 'state=idle' in (state/'probe.busy-state').read_text()
            assert (state/'probe.turn-ended').exists()
            status = subprocess.run(['ps','-p',str(late_pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
            assert not status or status.startswith('Z'), 'live descendant survived a completed turn: '+status
            orphan = state/'orphan.pid'
            process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_DESCENDANT=str(orphan)))
            for _ in range(200):
                if orphan.exists(): break
                time.sleep(.05)
            else: raise AssertionError('interrupted-drain descendant never started')
            orphan_pid = int(orphan.read_text())
            time.sleep(.3)
            process.terminate()
            process.communicate(timeout=25)
            status = subprocess.run(['ps','-p',str(orphan_pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
            assert not status or status.startswith('Z'), 'interrupted drain left a live descendant: '+status
            (state/'probe.turn-ended').unlink()
            unreported = subprocess.run(command + ['--backend','herdr'],input='/exit\n',capture_output=True,text=True,env=dict(herdr_env,BRIDGE_HERDR_FAIL='idle'),timeout=20)
            assert unreported.returncode == 0, unreported.stderr
            assert 'BRIDGE_OK' in unreported.stdout, unreported.stdout
            assert 'Herdr lifecycle publication failed' in unreported.stdout, unreported.stdout
            assert 'state=idle' in (state/'probe.busy-state').read_text()
            assert (state/'probe.turn-ended').exists()
            (state/'probe.turn-ended').unlink()
            unregistered = subprocess.run(command + ['--backend','herdr'],input='/exit\n',capture_output=True,text=True,env=dict(herdr_env,BRIDGE_HERDR_FAIL='working'),timeout=20)
            assert unregistered.returncode != 0, unregistered.stdout
            assert 'Herdr agent registration failed' in unregistered.stderr, unregistered.stderr
            assert 'BRIDGE_OK' not in unregistered.stdout, unregistered.stdout
            assert not (state/'probe.turn-ended').exists()
            lock = state/'probe.busy-state.lock'
            process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(env,BRIDGE_SLOW_CLOCK='1',FM_BUSY_LOCK_STALE_SECS='60'))
            for _ in range(400):
                if lock.exists(): break
                time.sleep(.01)
            else: raise AssertionError('the turn-start writer never took the busy lock')
            process.send_signal(signal.SIGINT)
            output,error = process.communicate('/exit\n',timeout=30)
            assert process.returncode == 0, error
            assert 'cancelled' in output, output
            assert 'state=idle' in (state/'probe.busy-state').read_text()
            assert (state/'probe.turn-ended').exists()
            assert not lock.exists(), 'the busy-state lock outlived the interrupted publication'
    print('PASS: both bridges preserve session identity, turn state, failures, cancellation and exit')
PY
