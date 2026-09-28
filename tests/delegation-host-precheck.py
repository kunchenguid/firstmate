#!/usr/bin/env python3
"""Real Pi host fixture tool body; only candidate public owners mutate state."""
import json
import os
from pathlib import Path
import subprocess
import sys

home = Path(os.environ['FM_HOME'])
root = Path(os.environ['FM_ROOT_OVERRIDE'])

def state(*args):
    result = subprocess.run(['bash', str(root / 'bin/fm-task-state.sh'), *args], text=True, capture_output=True, timeout=15)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)

if '--main' in sys.argv:
    print(json.dumps(state('observe', 'routine')))
else:
    for attempt in range(4):
        record = state('lifecycle', 'routine')
        observation = state('observe', 'routine')
        revision = record['delegation']['revision']
        patch = dict(delegation_revision=revision, precheck=dict(
            delegation_revision=revision, basis_key=observation['basis_key'],
            conclusion='needs-evidence', checks=[dict(criterion='brief: progress evidence', result='missing', evidence=[])],
            summary='Current brief read; final evidence still belongs to MAIN assessment.'))
        proposal = home / 'data/host-precheck.json'
        proposal.write_text(json.dumps(patch)); proposal.chmod(0o600)
        result = subprocess.run(['bash', str(root / 'bin/fm-task-state.sh'), 'branch-patch', 'routine',
                                 '--expected-revision', str(record['revision']), '--record', str(proposal)],
                                text=True, capture_output=True, timeout=15)
        if result.returncode == 0:
            print(result.stdout)
            break
        if 'revision conflict' not in result.stderr:
            raise RuntimeError(result.stderr)
    else:
        raise RuntimeError('bounded CAS retries exhausted')
