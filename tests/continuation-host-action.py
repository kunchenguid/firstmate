#!/usr/bin/env python3
"""Deterministic model tool body in the real Pi fixture, never controller-run.

Only existing public owners perform effects. The host controller prepares the
executor and releases its fixture lease; the product schedules this tool call.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

home = Path(os.environ['FM_HOME'])
root = Path(os.environ['FM_ROOT_OVERRIDE'])
task = 'matrix-fair-8'


def call(script, *args, allowed=(0,)):
    p = subprocess.run([str(root/'bin'/script), *map(str, args)], text=True, capture_output=True, timeout=20)
    assert p.returncode in allowed, (script, args, p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout) if p.stdout.strip().startswith(('{', '[')) else p.stdout


def state(op, *args):
    return call('fm-task-state.sh', op, task, *args)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reconcile(edit):
    for _ in range(8):
        r = state('lifecycle')
        edit(r)
        proposal = home/'data/model-proposal.json'
        proposal.write_text(json.dumps(r)); proposal.chmod(0o600)
        p = subprocess.run([str(root/'bin/fm-task-state.sh'), 'reconcile', task, '--expected-revision', str(r['revision']), '--record', str(proposal)], text=True, capture_output=True)
        if p.returncode == 0:
            return json.loads(p.stdout)
        assert 'revision conflict' in p.stderr, p.stderr
    raise AssertionError('CAS retries exhausted')


if len(sys.argv) > 1 and sys.argv[1] == 'heartbeat':
    r = call('fm-stow-run.sh', 'status'); active = r['active']
    assert active['attempts'] == 3 and active['recovery_attempts'] >= 1
    run, gen = active['run_id'], active['offered_generation']
    base = ('--run-id', run, '--generation', gen)
    call('fm-stow-run.sh', 'recover' if active['generation'] else 'begin', *base,
         '--session-id', active['session_id'], '--target-entry-id', active['cutoff_entry_id'],
         '--branch-fingerprint', active['branch_fingerprint'], '--expected-revision', r['revision'])
    folder = home/'data/stow-runs'/run; folder.mkdir(parents=True, exist_ok=True)
    evidence = folder/'continuation-readback.json'
    observation = call('fm-task-state.sh', 'observe', 'live-prerequisite')
    evidence.write_text(json.dumps(observation))
    # Archival/knowledge fixtures contain no eligible completed work or memory.
    # Unfinished continuation retains the run as partial, never fake acceptance.
    receipt = folder/'receipt.json'
    receipt.write_text(json.dumps(dict(version=1,run_id=run,generation=gen,outcome='partial',
        continuation=dict(status='pending',evidence_ref=str(evidence.relative_to(home)),sha256=sha(evidence)))))
    r = call('fm-stow-run.sh', 'status')
    call('fm-stow-run.sh', 'finish', *base, '--receipt-ref', receipt.relative_to(home),
         '--interval-seconds', 3600, '--expected-revision', r['revision'])
    print('Heartbeat executed canonical readback; real unfinished duty remains partial.')
    sys.exit(0)


record = state('lifecycle')
if record['disposition'] == 'accepted':
    print('Previously accepted evidence retained; no operation replay.')
elif record['next_action'] is None:
    budget = record['coordination']['budgets'][record['coordination']['observation_key']]
    assert budget['attempts'] == 2 and budget['recovery_attempts'] >= 1
    call('fm-task-handoff.sh', 'send', task, 'matrix-executor', '--id', 'matrix-handoff',
         'Perform the exact fixture operation once, acknowledging this inbox record.', allowed=(0, 6))
    def prepare(r):
        r['next_action_seq'] = 2
        r['next_action'] = dict(id=task+'.g1.a1', kind='steer', phase='prepared', expected_execution_generation='g1', attempts=0, attempt_limit=2, recheck_at='2026-01-01T00:00:00Z', deadline='2099-01-01T00:00:00Z', payload_ref='data/payload', payload_sha256=sha(home/'data/payload'), receipt_ref=None, continuation=dict(type='executor',task_id='matrix-executor',execution_generation='g1',handoff_id='matrix-handoff'))
    reconcile(prepare)
    (home/'data/model-handoff-created').write_text(json.dumps(dict(at=time.time(), budget=budget)))
    deadline = time.monotonic()+40
    while time.monotonic() < deadline:
        # Exact retry identity; the existing handoff owner deduplicates delivery.
        call('fm-task-handoff.sh', 'retry', 'matrix-handoff', allowed=(0, 6))
        if state('observe')['state'] == 'running':
            break
        time.sleep(.2)
    else:
        raise AssertionError('executor did not acknowledge/start')
    for phase in ('attempted', 'confirmed'):
        state('action', '--action-id', task+'.g1.a1', '--phase', phase, '--receipt-ref', 'data/readback', '--receipt-sha256', sha(home/'data/readback'))
    (home/'data/model-confirmed').write_text(json.dumps(state('lifecycle')))
    print('Exact executor handled receipt and live activity confirmed.')
else:
    assert record['next_action']['phase'] == 'confirmed', record
    assert (home/'data/executor-release').exists()
    effects = (home/'data/executor-effects').read_text().splitlines()
    assert len(effects) == 1
    def accept(r):
        r['disposition'] = 'accepted'
        r['assessment'].update(remaining_gap='', outcome='Exact fixture operation received, started, finished and read back once.', evidence=[dict(ref='data/executor-effects',sha256=sha(home/'data/executor-effects'))])
    reconcile(accept)
    (home/'data/model-accepted').write_text(json.dumps(state('lifecycle')))
    print('Fixture acceptance readback complete.')
