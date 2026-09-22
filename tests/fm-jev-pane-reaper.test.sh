#!/usr/bin/env bash
# tests/fm-jev-pane-reaper.test.sh - Regression test suite for Pattern 20
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAPER_ENGINE="${FM_ROOT}/bin/fm-jev-pane-reaper.py"
REAPER_WRAPPER="${FM_ROOT}/bin/fm-jev-pane-reaper.sh"

echo "=== Running fm-jev-pane-reaper test suite ==="

# Test 1: Python syntax compilation
python3 -m py_compile "${REAPER_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${REAPER_WRAPPER}"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Safety filter unit test in python
python3 -c "
import sys
sys.path.insert(0, '${FM_ROOT}/bin')
import importlib.util
spec = importlib.util.spec_from_file_location('reaper', '${REAPER_ENGINE}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Test supervisor protection
assert mod.is_protected_pane({'pane_id': 'w1:pA', 'terminal_title': 'π - firstmate'}) == True, 'Supervisor must be protected'

# Test active worker protection
assert mod.is_protected_pane({'pane_id': 'w95:p1', 'agent_status': 'working'}) == True, 'Working agent must be protected'

# Test focused pane protection
assert mod.is_protected_pane({'pane_id': 'w21:p2', 'focused': True}) == True, 'Focused pane must be protected'

# Test daemon protection
assert mod.is_protected_pane({'pane_id': 'w3T:p2', 'terminal_title': 'Stack Monitor SRE'}) == True, 'Stack monitor daemon must be protected'

# Test completed PR babysitter is eligible
p = {'pane_id': 'w92:p1', 'terminal_title': 'Portal prior-auth blueprint and chart UI - grok', 'agent_status': 'done', 'focused': False}
assert mod.is_protected_pane(p) == False, 'Completed prior-auth pane should not be protected'
"
echo "PASS: Test 3 - Protection safety predicates verified"

# Test 4: Live dry-run executes cleanly and outputs tag
DRY_OUT=$("${REAPER_WRAPPER}" --dry-run)
echo "${DRY_OUT}" | grep -q "\[DRY_RUN\]"
echo "PASS: Test 4 - Dry run mode runs cleanly with zero side-effects"

# Test 5: JSON output telemetry schema
JSON_OUT=$("${REAPER_WRAPPER}" --dry-run --json)
python3 -c "
import json
data = json.loads('''${JSON_OUT}''')
assert 'total_panes' in data, 'total_panes missing'
assert 'preserved_protected' in data, 'preserved_protected missing'
assert 'reaped_panes' in data, 'reaped_panes missing'
assert data['dry_run'] == True, 'dry_run must be True'
"
echo "PASS: Test 5 - JSON telemetry schema validated"

# Test 6: Herdr is optional on portable CI hosts. The executable interface must
# still return an empty dry-run report when no Herdr executable can be resolved.
NO_HERDR_OUT=$(PATH=/usr/bin:/bin /usr/bin/python3 "${REAPER_ENGINE}" --dry-run --json 2>/dev/null)
python3 -c "
import json
data = json.loads('''${NO_HERDR_OUT}''')
assert data['total_panes'] == 0, 'missing Herdr must produce an empty pane inventory'
assert data['reaped_panes'] == [], 'missing Herdr must never report a reap'
"
echo "PASS: Test 6 - missing Herdr degrades to an empty dry-run report"

echo "=== All 6 fm-jev-pane-reaper tests passed successfully! ==="
