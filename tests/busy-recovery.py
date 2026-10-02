#!/usr/bin/env python3
"""Recovery regressions with real kernel processes and a fixture Herdr transport.
Vendor evidence lives in the opt-in real Herdr guard, not in this fixture.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root, base = map(Path, sys.argv[1:3])
harness = sys.argv[3] if len(sys.argv) > 3 else 'traex'
versions = {'codex': '0.156.1', 'traex': '0.207.1'}
assert harness in versions
if sys.platform != 'linux':
    print('skip: Linux /proc required for the narrowly supported in-place recovery')
    sys.exit(0)
base.mkdir(parents=True)
home = base / 'home'
state = home / 'state'
state.mkdir(parents=True)
(home / 'data').mkdir()
(home / 'config').mkdir()
(home / 'config/backlog-backend').write_text('manual\n')
cwd = base / 'project'
cwd.mkdir()
logs = base / 'sessions/2026/09/25'
logs.mkdir(parents=True)
wrap = base / 'wrap'
wrap.mkdir()
reader = root / 'bin/fm-busy-transcript.py'
event = root / 'bin/fm-busy-event.sh'
env = dict(os.environ, FM_HOME=str(home), PATH=str(wrap) + ':' + os.environ['PATH'])
env['FM_BUSY_RECOVERY_LOCK_WAIT_SECS'] = '1'
for name in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_ROOT_OVERRIDE'):
    env.pop(name, None)

def call(*args, ok=True):
    result = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result.stdout.strip()

def snapshot_files():
    return {str(p.relative_to(state)): p.read_bytes() for p in state.rglob('*') if p.is_file()}

# A native executable with an exact launch argv and a real kernel lifetime.
# The fake backend reports only its transport snapshot; recovery still reads
# the executable, argv, env, cwd, ancestry, pgrp and start tick from /proc.
native = base / harness
shutil.copy2(sys.executable, native)
gen = call(event, 'arm', state, 'worker', '--state', 'unknown')
meta = (f'harness={harness}\nkind=scout\nworktree={cwd}\nproject={cwd}\n'
        f'backend=herdr\nwindow=fm-lab-fixture:w1:p2\nbusy_gen={gen}\nspawn_gen=s-original\n'
        'launch_state=unconfirmed\n'
        'herdr_session=fm-lab-fixture\nherdr_workspace_id=w1\nherdr_tab_id=w1:t2\nherdr_pane_id=w1:p2\n')
meta = (('# previous completion: decisions_reviewed=1\n'
         '# previous completion: decision_keys=older\n') * 2
        + (' \t# busy_gen=historical\n' * 2)
        + ('\t# window=old:w9:p9\n' * 2)
        + meta
        + 'decisions_reviewed=1\ndecision_keys=current\n')
(state / 'worker.meta').write_text(meta)
call('python3', reader, 'init', state, 'worker', harness, cwd, base / 'sessions', 'herdr', 'fm-lab-fixture:w1:p2')
call('python3', reader, 'activate', state, 'worker')
binding = (state / 'worker.busy-session').read_bytes()
records = [
    {'type': 'session_meta', 'payload': {'id': 'session', 'session_id': 'session', 'cwd': str(cwd),
        'source': 'cli', 'thread_source': 'user', 'originator': harness + '-tui', 'cli_version': versions[harness]}},
    {'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': 'turn', 'root_turn_id': 'turn'}},
    {'type': 'event_msg', 'payload': {'type': 'item_completed', 'thread_id': 'session', 'turn_id': 'turn',
        'item': {'type': 'UserMessage', 'id': 'initial-user', 'content': [{'type': 'text', 'text': 'brief\nFIRSTMATE_BUSY_GENERATION=' + gen}]}}},
    {'type': 'event_msg', 'payload': {'type': 'task_complete', 'turn_id': 'turn'}},
]
log = logs / 'rollout-worker.jsonl'
log.write_text(''.join(json.dumps(dict(row, ordinal=i)) + '\n' for i, row in enumerate(records)))
prompt = '\u2063FIRSTMATE_OP: v1 launch-brief: lab\nFIRSTMATE_BUSY_GENERATION=' + gen
argv = [str(native), '-c', 'import time; time.sleep(180)', prompt]
worker_env = dict(env, FM_TASK_ID='worker', GOTMPDIR='/tmp/fm-worker/gotmp')
process = subprocess.Popen(argv, cwd=cwd, env=worker_env)
daemon_argv = [str(native), '-c', 'import time; time.sleep(180)', 'app-server']
daemon = subprocess.Popen(daemon_argv, cwd=cwd, env=worker_env)
try:
    pane = {'pane_id': 'w1:p2', 'tab_id': 'w1:t2', 'workspace_id': 'w1', 'agent': harness,
            'foreground_cwd': str(cwd), 'terminal_id': 'term_original'}
    info = {'pane_id': 'w1:p2', 'shell_pid': os.getpid(), 'foreground_process_group_id': os.getpgid(process.pid),
            'foreground_processes': [{'pid': process.pid, 'name': harness, 'argv': argv},
                                     {'pid': daemon.pid, 'name': harness, 'argv': daemon_argv}]}
    transport = base / 'transport.json'
    send_log = base / 'send.log'
    def set_transport(p=pane, i=info):
        transport.write_text(json.dumps({'pane': p, 'process_info': i}))
    set_transport()
    shim = wrap / 'herdr'
    shim.write_text('#!/usr/bin/env python3\nimport json,sys,time,os\nfrom pathlib import Path\n'
                   'dump=lambda obj: json.dumps(obj, indent=2 if os.environ.get("FM_TEST_JSON_PRETTY") else None)\n'
                   f'data=json.loads(Path({str(transport)!r}).read_text())\n'
                   f'hold=Path({str(base / "hold")!r})\n'
                   f'send_log=Path({str(send_log)!r})\n'
                   'if hold.exists():\n hold.with_suffix(".entered").touch(); time.sleep(4)\n'
                   'args=sys.argv[1:]\n'
                   'if args[:2]==["pane","get"]:\n print(dump({"result":{"pane":data["pane"]}}))\n'
                   'elif args[:2]==["pane","process-info"]:\n print(dump({"result":{"type":"pane_process_info","process_info":data["process_info"]}}))\n'
                   'elif args[:2]==["agent","get"]:\n print(json.dumps({"result":{"agent":{"agent":data["pane"]["agent"],"agent_status":"idle","pane_id":data["pane"]["pane_id"],"cwd":data["pane"]["foreground_cwd"],"foreground_cwd":data["pane"]["foreground_cwd"]}}}))\n'
                   'elif args[:2]==["pane","read"]:\n print("╭────╮\\n│    │\\n╰────╯")\n'
                   'elif args[:2]==["pane","send-text"]:\n send_log.write_text(send_log.read_text() + args[3] + "\\n" if send_log.exists() else args[3] + "\\n")\n'
                   'elif args[:2]==["pane","send-keys"]:\n pass\n'
                   'elif args and args[0]=="status":\n print(json.dumps({"server":{"running":True}}))\n'
                   'else:\n sys.exit(1)\n'
                   'if os.environ.get("FM_TEST_JSON_EXTRA"): print("{}")\n')
    shim.chmod(0o755)
    def reset():
        (state / 'worker.meta').write_text(meta)
        (state / 'worker.busy-session').write_bytes(binding)
        (state / 'worker.busy-gen').unlink(missing_ok=True)
        (state / 'worker.busy-state').unlink(missing_ok=True)
        set_transport()
    def check(ok=True):
        return call(event, 'recover', state, 'worker', '--check', '--terminal', 'term_original', '--pid', process.pid, ok=ok)
    def check_apply(ok=True):
        script = ('set -eu\nreceipt=$("$1" recover "$2" "$3" --check --terminal "$4" --pid "$5")\n'
                  '"$1" recover "$2" "$3" --apply "$receipt"\n')
        result = subprocess.run(['bash', '-c', script, '_', str(event), str(state), 'worker',
                                 'term_original', str(process.pid)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
        return result.stdout.strip()
    def apply(receipt=None, ok=True):
        return call(event, 'recover', state, 'worker', '--apply', proof if receipt is None else receipt, ok=ok)
    reset()
    (state / 'worker.inbox').mkdir()
    (state / 'worker.inbox/001.msg').write_text('unchanged durable instruction\n')
    (state / 'worker.inbox/.ring-state').write_text('001.msg\t3\t1\n')
    (state / 'worker.inbox/.escalated').write_text('001.msg\n')
    before = snapshot_files()
    env['FM_TEST_JSON_PRETTY'] = '1'
    pretty_proof = check()
    env.pop('FM_TEST_JSON_PRETTY')
    assert pretty_proof == check(), 'JSON formatting changed the exact recovery identity'
    env['FM_TEST_JSON_EXTRA'] = '1'
    check(ok=False)
    env.pop('FM_TEST_JSON_EXTRA')
    print('ok - pretty and compact Herdr JSON preserve the same recovery proof')
    proof = check()
    assert snapshot_files() == before, 'preflight changed records'
    stale_lock = state / 'worker.busy-state.lock'
    stale_lock.mkdir()
    (stale_lock / 'pid').write_text('999999999\n')
    assert check() == proof, 'stale writer lock changed the read-only receipt'
    check_apply()
    assert not stale_lock.is_dir() and stale_lock.is_symlink() is False, 'recovered lock was not released'
    assert (state / 'worker.busy-gen').read_text().strip() == gen
    assert 'spawn_gen=s-original' in (state / 'worker.meta').read_text()
    assert (state / 'worker.inbox/001.msg').read_text() == 'unchanged durable instruction\n'
    assert (state / 'worker.inbox/.rearm').read_text().strip() == '001.msg'
    watcher_env = dict(env, FM_STATE_OVERRIDE=str(state), FM_POLL='1', FM_SIGNAL_GRACE='1',
                       FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999',
                       FM_TASK_INBOX_GRACE_SECS='0')
    watcher = subprocess.Popen([str(root / 'bin/fm-watch.sh')], env=watcher_env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if (send_log.exists() and 'Firstmate instruction waiting' in send_log.read_text()
                and (state / 'worker.inbox/.ring-state').exists()): break
        if watcher.poll() is not None: break
        time.sleep(.1)
    watcher.terminate()
    watcher.communicate(timeout=12)
    assert send_log.exists() and 'Firstmate instruction waiting' in send_log.read_text()
    assert not (state / 'worker.inbox/.escalated').exists()
    assert not (state / 'worker.inbox/.rearm').exists()
    ring_after_watcher = (state / 'worker.inbox/.ring-state').read_bytes()
    apply()
    assert (state / 'worker.inbox/.ring-state').read_bytes() == ring_after_watcher
    assert not (state / 'worker.inbox/.rearm').exists()
    call('python3', reader, 'fence-target', state, 'herdr', 'fm-lab-fixture:w1:p2')
    print('ok - escalated inbox recovery returns delivery to the watcher and repeated recovery stays idempotent')
    print('ok - read-only legacy preflight, original-generation restore and ordinary input fence')
    print('ok - a real same-name daemon does not replace exact root launch-argument provenance')
    reset()
    live_holder = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
    try:
        stale_lock.mkdir()
        (stale_lock / 'pid').write_text(str(live_holder.pid) + '\n')
        assert check() == proof, 'live writer lock changed the read-only receipt'
        apply(ok=False)
        assert stale_lock.is_dir() and (stale_lock / 'pid').read_text().strip() == str(live_holder.pid)
        assert not (state / 'worker.busy-gen').exists()
    finally:
        live_holder.terminate(); live_holder.wait()
    apply()
    print('ok - recovery reclaims a dead transcript lock but never steals a live owner')
    reset()
    duplicate = subprocess.Popen(argv, cwd=cwd, env=worker_env)
    try:
        ambiguous = copy.deepcopy(info)
        ambiguous['foreground_processes'].append({'pid': duplicate.pid, 'name': harness, 'argv': argv})
        set_transport(i=ambiguous)
        check(ok=False)
    finally:
        duplicate.terminate(); duplicate.wait()
    reset(); (state / 'worker.meta').write_text(meta.replace('fm-lab-fixture:w1:p2', 'fm-lab-fixture:w1:p3'))
    call('python3', reader, 'fence-target', state, 'herdr', 'fm-lab-fixture:w1:p3', ok=False)
    print('ok - duplicate launch identities and contradictory endpoint metadata refuse input')
    # Replacement terminal, wrong live PID, stale gen, missing evidence.
    reset(); changed = copy.deepcopy(pane); changed['terminal_id'] = 'term_reused'; set_transport(changed)
    apply(ok=False); assert not (state / 'worker.busy-gen').exists()
    for key, value in (('task', 'other-task'), ('state', str(base / 'other-home/state')), ('gen', 'g-other')):
        reset(); changed_proof = json.loads(proof); changed_proof[key] = value
        refused_before = snapshot_files(); apply(json.dumps(changed_proof), ok=False)
        assert snapshot_files() == refused_before, 'changed ' + key + ' receipt changed protected state'
    for key, value in (('terminal', 'term_other'), ('pid', os.getpid())):
        reset(); changed_proof = json.loads(proof); changed_proof['process'][key] = value
        refused_before = snapshot_files(); apply(json.dumps(changed_proof), ok=False)
        assert snapshot_files() == refused_before, 'changed process ' + key + ' receipt changed protected state'
    reset(); refused_before = snapshot_files(); apply('{malformed', ok=False)
    assert snapshot_files() == refused_before, 'malformed inline receipt changed protected state'
    reset(); refused_before = snapshot_files(); apply(json.dumps(['not', 'a', 'receipt']), ok=False)
    assert snapshot_files() == refused_before, 'non-object inline receipt changed protected state'
    receipt_file = base / 'proof.json'
    receipt_file.write_text(proof)
    reset(); apply(receipt_file)
    assert (state / 'worker.busy-gen').read_text().strip() == gen
    print('ok - malformed inline receipts refuse without effects and file receipts remain supported')
    reset(); changed_info = copy.deepcopy(info); changed_info['foreground_processes'][0]['pid'] = os.getpid(); set_transport(i=changed_info)
    check(ok=False)
    reset(); (state / 'worker.busy-gen').write_text('g-replacement\n'); apply(ok=False)
    reset(); (state / 'worker.meta').write_text(meta.replace(gen, 'g-other')); check(ok=False)
    reset(); (state / 'worker.busy-session').unlink(); check(ok=False)
    reset(); (state / 'worker.meta').write_text(meta.replace('spawn_gen=s-original', 'spawn_gen=new-spawn')); apply(ok=False)
    reset(); data = json.loads(binding); data['unaccounted_input'] = True
    (state / 'worker.busy-session').write_text(json.dumps(data)); check(ok=False)
    reset(); changed = copy.deepcopy(pane); changed['foreground_cwd'] = str(base); set_transport(changed); check(ok=False)
    print('ok - missing, conflicting, stale and reused endpoint evidence refuses without restoring a generation')
    # Interrupted verification under the busy lock must release it and allow
    # the same original receipt to converge; no new incarnation is created.
    reset(); (base / 'hold').touch()
    child = subprocess.Popen([str(event), 'recover', str(state), 'worker', '--apply', proof],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if (base / 'hold.entered').exists(): break
        time.sleep(.05)
    else: raise AssertionError('interruption did not reach verification')
    children = Path('/proc') / str(child.pid) / 'task' / str(child.pid) / 'children'
    # Signal the verification process first, then its waiting owner: both have
    # normal signal cleanup. This is an interrupted recovery, not a fake exit.
    for pid in children.read_text().split(): os.kill(int(pid), signal.SIGTERM)
    child.send_signal(signal.SIGTERM)
    child.communicate(timeout=12)
    (base / 'hold').unlink()
    assert not (state / 'worker.busy-state.lock').exists()
    apply()
    print('ok - interrupted recovery releases ownership and repeated apply converges')
    reset()
    # Interrupt after the proof and generation publish, at the final metadata
    # rename. Retrying must finish the same incarnation, not arm another one.
    move = wrap / 'mv'
    real_move = shutil.which('mv')
    move.write_text('#!/usr/bin/env python3\nimport os,signal,sys\n'
                    f'if {str(state / "worker.meta")!r} in sys.argv[1:]:\n'
                    ' os.kill(os.getppid(),signal.SIGTERM); sys.exit(1)\n'
                    f'os.execv({real_move!r},[{real_move!r}]+sys.argv[1:])\n')
    move.chmod(0o755)
    apply(ok=False)
    assert (state / 'worker.busy-gen').read_text().strip() == gen
    assert 'process_binding' in json.loads((state / 'worker.busy-session').read_text())
    assert 'launch_state=confirmed' not in (state / 'worker.meta').read_text()
    move.unlink()
    apply()
    print('ok - interruption after restoring the original generation converges without losing the process seal')
    reset()
    next_ordinal = len(records)
    padding = 'x' * 65536
    with log.open('a') as stream:
        while stream.tell() <= 32 * 1024 * 1024 + 65536:
            stream.write(json.dumps({'type': 'response_item', 'ordinal': next_ordinal,
                'payload': {'type': 'reasoning', 'summary': [{'type': 'summary_text', 'text': padding}]}}) + '\n')
            next_ordinal += 1
    assert log.stat().st_size > 32 * 1024 * 1024
    long_proof = json.loads(check())
    assert long_proof['process']['terminal'] == 'term_original'
    assert long_proof['process']['pid'] == process.pid
    print('ok - legitimate long transcript recovery retains original terminal and native PID provenance')
    log.write_text(''.join(json.dumps(dict(row, ordinal=i)) + '\n' for i, row in enumerate(records)))
    # A later replacement may preserve all disk evidence. Input still rechecks
    # the actual process and terminal immediately before ordinary transport.
    process.terminate(); process.wait()
    replacement = subprocess.Popen(argv, cwd=cwd, env=worker_env)
    try:
        info['foreground_processes'][0]['pid'] = replacement.pid
        set_transport()
        call('python3', reader, 'fence-target', state, 'herdr', 'fm-lab-fixture:w1:p2', ok=False)
        call('python3', reader, 'check-target', state, 'herdr', 'fm-lab-fixture:w1:p2', ok=False)
        (state / 'worker.busy-session').unlink()
        call('python3', reader, 'fence-target', state, 'herdr', 'fm-lab-fixture:w1:p2', ok=False)
    finally:
        replacement.terminate(); replacement.wait()
    print('ok - even copied launch argv cannot make a replacement accept recovered text or keys; missing sidecar refuses')
finally:
    daemon.terminate(); daemon.wait()
    if process.poll() is None:
        process.terminate(); process.wait()
