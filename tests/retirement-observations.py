"""Public lifecycle/scan/ack regression, using only disposable task state."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root, home = map(Path, sys.argv[1:])
for directory in ('data', 'state', 'config'):
    (home / directory).mkdir(parents=True, exist_ok=True)
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root))
for name in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
    env.pop(name, None)
cli, lib, scan = root / 'bin/fm-task-state.sh', root / 'bin/fm-task-lifecycle.py', root / 'bin/fm-inactive-reconcile.sh'


def run(*args, ok=True):
    result = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True, check=False)
    assert (result.returncode == 0) == ok, result.stderr or result.stdout
    return result.stdout


def call(task, operation, *args):
    return json.loads(run(cli, operation, task, *args))


def due(task):
    return json.loads(run(sys.executable, lib, 'due', task))


def assess(task, **changes):
    judgment = dict(disposition='accepted', outcome='Delivered', remaining_gap='',
                    authority_ref=f'data/{task}/brief.md', evidence=[f'data/{task}/report.md'])
    judgment.update(changes)
    refs = judgment['evidence'] + [judgment['authority_ref']]
    action = judgment.get('next_action')
    if action:
        refs += [action['payload_ref'], action['blocker']['release_ref']]
    basis = call(task, 'inspect', *[arg for ref in refs for arg in ('--evidence', ref)])['basis']
    return call(task, 'assess', '--basis', basis, '--judgment', json.dumps(judgment))


def setup(task, accepted=True, kind='scout'):
    folder = home / 'data' / task
    folder.mkdir()
    (folder / 'brief.md').write_text('Complete the requested result\n')
    (folder / 'report.md').write_text('Preserved delivered report\n')
    (home / 'state' / f'{task}.meta').write_text(f'kind={kind}\nspawn_gen=g1\n')
    call(task, 'enroll')
    if accepted:
        assess(task)


def wait(task, release, recheck='2099-01-01T00:00:00Z', deadline='2099-02-01T00:00:00Z'):
    return assess(task, next_action=dict(kind='wait', payload_ref=f'data/{task}/brief.md',
        recheck_at=recheck, deadline=deadline, blocker=dict(owner='repair',
        dependency='confirmed cleanup correction delivery', release_ref=release)))


def pending(task):
    return [p for p in (home / 'state/terminal-outcomes').glob('*.pending')
            if f'task_id={task}\n' in p.read_text()]


def receipts():
    # Detect same-byte rewrites as well as accumulated evidence files.
    return {str(p): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_ino, p.stat().st_mtime_ns)
            for p in (home / 'state/terminal-outcomes').glob('*') if p.is_file()}


def scan_and_ack(task):
    run(scan, 'scan', '--startup')
    paths = pending(task)
    assert len(paths) == 1, paths
    before = call(task, 'lifecycle')['revision']
    run(scan, 'acknowledge', paths[0].stem)
    assert call(task, 'lifecycle')['revision'] == before, 'presentation fabricated a task assessment'


for task in ('repair', 'retained', 'counterfactual'):
    setup(task)
wait('retained', 'data/repair/lifecycle.json')
wait('counterfactual', 'data/repair/report.md')
# A terminal dependency without resources is not itself in the scan inventory.
(home / 'state/repair.meta').unlink()
parent_before = (home / 'data/retained/lifecycle.json').read_bytes()
for iteration in range(4):
    assess('repair', outcome=f'Delivered; unrelated readback note {iteration}')
    assert not due('retained')['due'], 'assessment bookkeeping released cleanup wait'
    assert not due('counterfactual')['due'], 'unchanged report released counterfactual wait'
    run(scan, 'scan', '--startup')
assert not receipts(), 'unchanged scans wrote artificial outcome receipts'
assert (home / 'data/retained/lifecycle.json').read_bytes() == parent_before
print('ok - four bookkeeping-only dependency changes: model-facing wakes=0 task/outcome writes=0')

# The narrower terminal projection must not hide an open goal's dependency
# readback. Its original byte-bound observation remains actionable.
setup('open-dependency', accepted=False)
assess('open-dependency', disposition='open', remaining_gap='Await required result',
       next_action=dict(kind='wait', payload_ref='data/open-dependency/brief.md',
           recheck_at='2099-01-01T00:00:00Z', deadline='2099-02-01T00:00:00Z',
           blocker=dict(owner='repair', dependency='required result', release_ref='data/repair/lifecycle.json')))
assert 'release_projection' not in call('open-dependency', 'lifecycle')['next_action']['continuation']
assert call('open-dependency', 'observe')['state'] == 'blocked'
assess('repair', outcome='Delivered; open dependency readback')
assert call('open-dependency', 'observe')['state'] == 'pending'
# Keep this independent open-goal proof outside the resource scan measurements.
(home / 'state/open-dependency.meta').unlink()

# Presentation changes while a cleanup wait is still quiet must not create
# even a first wake or force the cleanup owner to refresh its lifecycle link.
setup('quiet-receipt')
quiet_path = home / 'state/quiet-receipt.cleanup.json'
quiet = dict(schema='fm-task-cleanup.v1', task_id='quiet-receipt', spawn_gen='g1', goal_revision=1,
             phases=dict(directory_return=dict(state='retained', reason_code='dirty-unlanded')))
quiet_path.write_text(json.dumps(quiet)); quiet_path.chmod(0o600)
run(sys.executable, lib, 'link-cleanup', 'quiet-receipt')
wait('quiet-receipt', 'data/repair/report.md')
quiet_record = (home / 'data/quiet-receipt/lifecycle.json').read_bytes()
for iteration in range(4):
    quiet['presented_at'] = iteration
    quiet['phases']['directory_return']['presented_at'] = iteration
    quiet_path.write_text(json.dumps(quiet, indent=iteration + 1))
    run(sys.executable, lib, 'link-cleanup', 'quiet-receipt')
    assert not due('quiet-receipt')['due']
    run(scan, 'scan', '--startup')
assert not receipts() and (home / 'data/quiet-receipt/lifecycle.json').read_bytes() == quiet_record
print('ok - quiet wait receipt timestamps/presentation: wakes=0 link/assessment writes=0')

# A completed cleanup is also insensitive to a linked receipt's presentation;
# changed resource phases still request one readback rather than being hidden.
setup('completed-receipt')
completed_path = home / 'state/completed-receipt.cleanup.json'
completed = dict(schema='fm-task-cleanup.v1', task_id='completed-receipt', spawn_gen='g1', goal_revision=1,
                 phases=dict(directory_return=dict(state='confirmed', reason_code='returned')))
completed_path.write_text(json.dumps(completed)); completed_path.chmod(0o600)
run(sys.executable, lib, 'link-cleanup', 'completed-receipt')
(home / 'state/completed-receipt.meta').unlink()
run(sys.executable, lib, 'owner-receipt', 'completed-receipt', '--kind', 'cleanup',
    '--execution-generation', 'g1', '--facts', json.dumps(dict(taskRecordRemoved=True,
        endpointConfirmedGone=True, bookkeepingComplete=True, copyDisposition='returned-or-already-absent')))
completed['presented_at'] = 1
completed_path.write_text(json.dumps(completed, indent=2))
assert not due('completed-receipt')['due'], 'completed receipt presentation revived reconciliation'
completed['phases']['directory_return']['reason_code'] = 'late-resource-conflict'
completed_path.write_text(json.dumps(completed))
assert due('completed-receipt')['due'], 'changed completed-resource facts were suppressed'
scan_and_ack('completed-receipt')

report = home / 'data/repair/report.md'
report.write_text('Reassessed final scout report\n')
assess('repair', outcome='Delivered after final report revision')
assert due('retained')['due']
released = due('retained')['reconciliation_key']
run(scan, 'scan', '--startup')
unhandled = receipts()
run(sys.executable, lib, 'owner-receipt', 'repair', '--kind', 'merge', '--execution-generation', 'g1',
    '--facts', json.dumps(dict(url='local:/fixture#main', head='a' * 40)))
assert due('retained')['reconciliation_key'] == released, 'incidental scout merge receipt changed delivery evidence'
for _ in range(4):
    call('retained', 'refresh')
    run(scan, 'scan', '--startup')
assert receipts() == unhandled and len(pending('retained')) == 1, 'unhandled release scan rewrote/repeated observation'
scan_and_ack('retained')
first = receipts()
for _ in range(4):
    run(scan, 'scan', '--startup')
assert receipts() == first and not pending('retained'), 'release replayed after reload/ack'
assert (home / 'data/retained/lifecycle.json').read_bytes() == parent_before
print('ok - reassessed scout report releases once; incidental merge and reloads add no observation')

# The same observation remains stable across assessment text and receipt presentation.
receipt = home / 'state/retained.cleanup.json'
cleanup = dict(schema='fm-task-cleanup.v1', task_id='retained', spawn_gen='g1', goal_revision=1,
               phases=dict(directory_return=dict(state='retained', reason_code='dirty-unlanded')))
receipt.write_text(json.dumps(cleanup)); receipt.chmod(0o600)
run(sys.executable, lib, 'link-cleanup', 'retained')
scan_and_ack('retained')
retained_before = (home / 'data/retained/lifecycle.json').read_bytes()
first = receipts()
for iteration in range(4):
    cleanup['presented_at'] = iteration
    receipt.write_text(json.dumps(cleanup, indent=iteration + 1))
    run(scan, 'scan', '--startup')
assert receipts() == first and not pending('retained'), 'receipt formatting/presentation caused a new wake'
assert (home / 'data/retained/lifecycle.json').read_bytes() == retained_before
print('ok - receipt presentation and formatting cause zero additional model admissions or task writes')

# A changed retained-resource reason is one new observation; no effect is replayed.
cleanup['phases']['directory_return']['reason_code'] = 'shared-with-live-sibling'
receipt.write_text(json.dumps(cleanup))
scan_and_ack('retained')
first = receipts()
for _ in range(3):
    run(scan, 'scan', '--startup')
assert receipts() == first
assert json.loads(receipt.read_text())['phases']['directory_return']['state'] == 'retained'

setup('deadline')
wait('deadline', 'data/repair/report.md', '2000-01-01T00:00:00Z', '2000-01-02T00:00:00Z')
assert due('deadline')['due'] and due('deadline')['expired']
scan_and_ack('deadline')
first = receipts()
for _ in range(4):
    run(scan, 'scan', '--startup')
assert receipts() == first
print('ok - reached deadline: one actionable observation, retained after interruption and restart')

# Explicit archive never resumes business actions; late output is preserved once.
setup('archived')
(home / 'data/archived/stop.txt').write_text('Explicitly stop this business goal\n')
assess('archived', disposition='archived', authority_ref='data/archived/stop.txt')
scan_and_ack('archived')
(home / 'data/archived/report.md').write_text('Late result preserved without reopening\n')
scan_and_ack('archived')
first = receipts()
for _ in range(3):
    run(scan, 'scan', '--startup')
assert receipts() == first
assert call('archived', 'lifecycle')['disposition'] == 'archived'
assert (home / 'data/archived/report.md').read_text().startswith('Late result')
print('ok - archived late output remains terminal and preserved without repeated readback or replay')

setup('ship-dependency', accepted=False, kind='ship')
run(sys.executable, lib, 'owner-receipt', 'ship-dependency', '--kind', 'merge', '--execution-generation', 'g1',
    '--facts', json.dumps(dict(url='local:/fixture#old', head='b' * 40)))
ship = home / 'data/ship-dependency'
(ship / 'authority-2.md').write_text('Authorize the replacement execution\n')
(ship / 'brief.md').write_text('Complete the replacement execution\n')
(home / 'state/ship-dependency.meta').write_text('kind=ship\nspawn_gen=g2\n')
assess('ship-dependency', disposition='open', outcome='Replacement execution authorized',
       remaining_gap='Complete replacement delivery', intent_changed=True,
       authority_ref='data/ship-dependency/authority-2.md')
assess('ship-dependency', authority_ref='data/ship-dependency/authority-2.md')
setup('ship-parent')
wait('ship-parent', 'data/ship-dependency/lifecycle.json')
assert not due('ship-parent')['due'], 'stale-generation merge receipt released ship dependency'
run(sys.executable, lib, 'owner-receipt', 'ship-dependency', '--kind', 'merge', '--execution-generation', 'g2',
    '--facts', json.dumps(dict(url='local:/fixture#current', head='c' * 40)))
assert due('ship-parent')['due'], 'current-generation merge receipt did not release ship dependency'
print('ok - ship release ignores historical merge and observes current execution delivery')

setup('captain-gate-dependency')
setup('captain-gate-parent')
wait('captain-gate-parent', 'data/captain-gate-dependency/lifecycle.json')
assert not due('captain-gate-parent')['due'], 'unreviewed captain-call inventory released scout dependency'
(home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
(home / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
captain_hold = root / 'bin/fm-captain-hold.sh'
run(captain_hold, 'hold', 'captain-gate-call', '--title', 'Choose the gated result',
    '--reason', 'captain choice pending', '--repo', 'sample', '--origin', 'captain-gate-dependency')
(home / 'state/captain-gate-dependency.status').write_text(
    'needs-decision [key=gate]: choose the gated result\n')
real_mv = shutil.which('mv')
assert real_mv
fakebin = home / 'gate-fakebin'
fakebin.mkdir()
wrapper = fakebin / 'mv'
wrapper.write_text('#!/bin/sh\n"$FM_TEST_REAL_MV" "$@"\nrc=$?\n'
                   '[ "$rc" -ne 0 ] || kill -STOP "$PPID"\nexit "$rc"\n')
wrapper.chmod(0o755)
gate_env = dict(env, PATH=str(fakebin) + os.pathsep + env['PATH'], FM_TEST_REAL_MV=real_mv)
process = subprocess.Popen([captain_hold, 'complete', 'captain-gate-dependency', 'captain-gate-call'],
                           env=gate_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
meta = home / 'state/captain-gate-dependency.meta'
deadline = time.monotonic() + 10
while time.monotonic() < deadline and 'decision_keys=captain-gate-call\n' not in meta.read_text():
    assert process.poll() is None, process.stderr.read()
    time.sleep(0.01)
observed = 'decision_keys=captain-gate-call\n' in meta.read_text()
intermediate_quiet = observed and not due('captain-gate-parent')['due']
if process.poll() is None:
    os.kill(process.pid, signal.SIGCONT)
stdout, stderr = process.communicate(timeout=10)
assert observed and intermediate_quiet, 'incomplete captain-call verification released scout dependency'
assert process.returncode == 0, stderr or stdout
assert due('captain-gate-parent')['due'], 'completed captain-call inventory did not release scout dependency'
run(scan, 'scan', '--startup')
gate_release = receipts()
for _ in range(4):
    run(scan, 'scan', '--startup')
assert receipts() == gate_release and len(pending('captain-gate-parent')) == 1
scan_and_ack('captain-gate-parent')
gate_release = receipts()
for _ in range(4):
    run(scan, 'scan', '--startup')
assert receipts() == gate_release and not pending('captain-gate-parent')
print('ok - scout captain-call completion gate releases once and unchanged scans stay quiet')
