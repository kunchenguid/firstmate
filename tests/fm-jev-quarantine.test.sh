#!/usr/bin/env bash
# tests/fm-jev-quarantine.test.sh - Regression test suite for Pattern 17
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUARANTINE_ENGINE="${FM_ROOT}/bin/fm-jev-quarantine.py"

echo "=== Running fm-jev-quarantine test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${QUARANTINE_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-quarantine.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test quarantine classification logic
QUARANTINE_ENGINE="$QUARANTINE_ENGINE" FM_ROOT="$FM_ROOT" python3 <<'PY'
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ["FM_ROOT"]) / "bin"))
import importlib.util
spec = importlib.util.spec_from_file_location("jq", os.environ["QUARANTINE_ENGINE"])
jq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jq)

# Mock checks
mock_checks = [
    {"name": "Journeys", "bucket": "fail", "state": "FAILURE", "description": "locator timeout in test_j7_visit_lifecycle"},
    {"name": "Lint & Format", "bucket": "pass", "state": "SUCCESS"},
    {"name": "Test Suite (1/12)", "bucket": "pass", "state": "SUCCESS"},
]
# Mock diff files that do not touch journeys or visit lifecycle
mock_diff = {"src/ui/header.tsx", "styles/theme.css"}

res = jq.analyze_failures("9999", repo="test/repo", custom_checks=mock_checks, custom_diff_files=mock_diff)
assert res["quarantined_flakes_count"] == 1, f"Expected 1 quarantined flake, got {res['quarantined_flakes_count']}"
assert res["real_regressions_count"] == 0, f"Expected 0 regressions, got {res['real_regressions_count']}"
assert res["safe_to_rerun_or_waive"] is True, "Expected safe to rerun"
assert res["findings"][0]["verdict"] == "QUARANTINE_ELIGIBLE_FLAKE"

print("PASS: Test 3 - Quarantine classification logic verified")
PY

# Test 4: Live quarantine analysis on Portal PR #1783
"${FM_ROOT}/bin/fm-jev-quarantine.sh" --pr 1783 --repo ArcsHealth/Portal
echo "PASS: Test 4 - Live audit on Portal PR #1783 verified"

# Test 5: JSON output schema validation
"${FM_ROOT}/bin/fm-jev-quarantine.sh" --pr 1783 --repo ArcsHealth/Portal --json | grep -q '"overall_verdict"'
echo "PASS: Test 5 - JSON output verified"

echo "=== All 5/5 fm-jev-quarantine tests PASSED (100%) ==="
