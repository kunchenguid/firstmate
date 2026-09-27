#!/usr/bin/env bash
# tests/fm-jev-worktree-sync.test.sh - Regression test suite for Pattern 15
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_ENGINE="${FM_ROOT}/bin/fm-jev-worktree-sync.py"

echo "=== Running fm-jev-worktree-sync test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${SYNC_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-worktree-sync.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test git convergence calculation
python3 -c '
import sys
import tempfile
import subprocess
from pathlib import Path
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("ws", "'"${SYNC_ENGINE}"'")
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

with tempfile.TemporaryDirectory() as td:
    p = Path(td)
    # Init git repo
    subprocess.run(["git", "init", "-b", "main"], cwd=str(p), check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=str(p), check=True)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=str(p), check=True)
    
    # Initial commit
    f = p / "README.md"
    f.write_text("# Test Repo\n")
    subprocess.run(["git", "add", "."], cwd=str(p), check=True)
    subprocess.run(["git", "commit", "-m", "initial commit"], cwd=str(p), check=True, stdout=subprocess.DEVNULL)
    
    res = ws.inspect_worktree(p)
    assert res["is_clean"] is True
    assert res["branch"] == "main"
    assert res["state"] == "UNKNOWN"
    assert res["ahead"] is None and res["behind"] is None
    cli = subprocess.run([sys.executable, str(ws.__file__), "--worktree", str(p), "--json"], capture_output=True, text=True)
    assert cli.returncode == 1

    remote = p / "remote.git"
    subprocess.run(["git", "init", "--bare", str(remote)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "remote", "add", "origin", str(remote)], cwd=p, check=True)
    subprocess.run(["git", "push", "-u", "origin", "main"], cwd=p, check=True, capture_output=True)
    res = ws.inspect_worktree(p)
    assert res["state"] == "CONVERGED"
    assert res["ahead"] == 0 and res["behind"] == 0

    from unittest.mock import patch
    real_run_git = ws.run_git
    def failed_comparison(args, cwd):
        if args[0] == "rev-list":
            return 1, "", "comparison unavailable"
        return real_run_git(args, cwd)
    with patch.object(ws, "run_git", side_effect=failed_comparison):
        res = ws.inspect_worktree(p, auto_sync=True)
        assert res["state"] == "UNKNOWN" and not res["synced"]

    subprocess.run(["git", "remote", "set-url", "origin", str(p / "missing.git")], cwd=p, check=True)
    res = ws.inspect_worktree(p, auto_sync=True)
    assert res["state"] == "UNKNOWN" and not res["synced"]
    assert "fetch failed" in res["error"]
    cli = subprocess.run([sys.executable, str(ws.__file__), "--worktree", str(p), "--json"], capture_output=True, text=True)
    assert cli.returncode == 1

print("PASS: Worktree convergence and unknown states verified")
'
