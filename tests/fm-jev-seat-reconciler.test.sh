#!/usr/bin/env bash
# tests/fm-jev-seat-reconciler.test.sh - Test suite for Pattern 11 Seat Reconciler.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECONCILER="$FM_ROOT/bin/fm-jev-seat-reconciler.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

printf '1. Verify help flag...\n'
"$RECONCILER" --help >/dev/null 2>&1 || fail "reconciler --help failed"
ok "help flag works"

printf '2. Verify dry-run output against live Herdr session...\n'
out=$("$RECONCILER" --dry-run) || fail "reconciler --dry-run failed"
printf '%s\n' "$out" | grep -q "Jev Seat Reconciler" || fail "missing header in output"
ok "dry-run produces structured summary"

printf '3. Verify --json output schema...\n'
json_out=$("$RECONCILER" --dry-run --json) || fail "reconciler --dry-run --json failed"
echo "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert "total_agents" in data
assert "reconcilable_count" in data
assert "candidates" in data
assert isinstance(data["candidates"], list)
' || fail "malformed json schema"
ok "json output format verified"

printf '4. Verify candidate detection logic unit tests...\n'
python3 -c '
import json
from pathlib import Path
import sys

import importlib.util
spec = importlib.util.spec_from_file_location("fm_jev_seat_reconciler", "'"$FM_ROOT"'/bin/fm-jev-seat-reconciler.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
identify_reconcilable_seats = mod.identify_reconcilable_seats

# Test mock agents
mock_agents = [
    {
        "pane_id": "w1:pA",
        "terminal_title": "π - firstmate",
        "agent_status": "working",
        "cwd": "/opt/ra/firstmate",
        "agent": "pi"
    },
    {
        "pane_id": "w81:p2",
        "terminal_title": "Babysit Jev router PR until Claude reset - grok",
        "agent_status": "done",
        "cwd": "/home/jon/.treehouse/firstmate-8bf1b0/25/firstmate",
        "agent": "grok"
    },
    {
        "pane_id": "w91:p1",
        "terminal_title": "Portal CI self-hosted runner pool workflow - grok",
        "agent_status": "working",
        "cwd": "/home/jon/git/wt-portal-runner-ci",
        "agent": "grok"
    }
]

candidates = identify_reconcilable_seats(mock_agents)
assert len(candidates) == 1, "Expected 1 candidate, got " + str(len(candidates))
assert candidates[0]["pane_id"] == "w81:p2"
assert "done" in candidates[0]["reason"]
' || fail "unit tests failed"
ok "unit tests passed for candidate detection"

printf 'ok - all fm-jev-seat-reconciler tests passed\n'

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" seat-reconciler
