#!/usr/bin/env python3
"""Exercise scenario selection without starting workers."""
import importlib.util
from pathlib import Path
import subprocess
import sys

plan_path = Path(__file__).with_name('fm-codex-appserver-live-plan.py')
spec = importlib.util.spec_from_file_location('live_plan', plan_path)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)

full = ('scout-success', 'scout-failure', 'scout-interrupt')
assert plan.parse_scenarios([]) is None
assert all(plan.selected(name, None) for name in full)
assert plan.parse_scenarios(['--scenario', 'scout-failure']) == ('scout-failure',)
assert plan.parse_scenarios(['--scenario', 'scout-interrupt', '--scenario', 'scout-success',
                             '--scenario', 'scout-interrupt']) == ('scout-success', 'scout-interrupt')
try:
    plan.parse_scenarios(['--scenario', 'unknown'])
except SystemExit as error:
    assert error.code == 2
else:
    raise AssertionError('unknown scenario accepted')
entrypoint = Path(__file__).with_name('fm-codex-appserver-live.py')
invalid = subprocess.run([sys.executable, str(entrypoint), str(plan_path.parents[1]),
                          '--scenario', 'unknown'], text=True, capture_output=True)
assert invalid.returncode == 2
assert 'invalid choice' in invalid.stderr and 'spawned ' not in invalid.stdout
print('ok - live canary scenario selection')
