#!/usr/bin/env bash
# tests/fm-jev-stall-guard.test.sh - Regression test suite for Pattern 14
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARD="${FM_ROOT}/bin/fm-jev-stall-guard.py"

echo "=== Running fm-jev-stall-guard test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${GUARD}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-stall-guard.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test activity evaluation logic
python3 -c '
import sys
import tempfile
import time
from pathlib import Path
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("sg", "'"${GUARD}"'")
sg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sg)

# Case 1: Active worktree with fresh file modification
with tempfile.TemporaryDirectory() as td:
    p = Path(td)
    test_file = p / "test.txt"
    test_file.write_text("active code")
    recent = sg.check_worktree_mtime(p, max_age_seconds=60)
    assert len(recent) == 1, f"Expected 1 recent file, got {recent}"

    # Case 2: Stale worktree (mtime simulated in past)
    old_time = time.time() - 1000
    import os
    os.utime(test_file, (old_time, old_time))
    stale = sg.check_worktree_mtime(p, max_age_seconds=60)
    assert len(stale) == 0, f"Expected 0 recent files, got {stale}"

print("PASS: Test 3 - Worktree mtime prober verified")
'

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" stall-guard
