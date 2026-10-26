#!/usr/bin/env bash
# tests/fm-jev-mem-guard.test.sh - Regression tests for Pattern 46 (Jev Multi-Agent Memory RSS & Swap Thrashing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mem-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mem-guard.py"

echo "Running Pattern 46 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit; stdout is streamed to the parser as data
json_out="$("$GUARD_SH" --json)"
printf '%s\n' "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert isinstance(data.get("name"), str) and data["name"]
assert isinstance(data.get("checked_at"), str) and data["checked_at"]
assert data.get("status") in ("OK", "WARNING", "CRITICAL", "UNKNOWN")
assert isinstance(data.get("recommendation"), str) and data["recommendation"]
assert data.get("reason") is None or isinstance(data.get("reason"), str)
assert "summary" in data
assert "top_processes" in data
for key in ("mem_total_gb", "mem_available_gb", "mem_used_pct",
            "swap_total_gb", "swap_used_gb", "swap_used_pct"):
    val = data["summary"][key]
    assert val is None or isinstance(val, (int, float)), key
for p in data["top_processes"]:
    assert "pid" in p
    assert "comm" in p
    assert "rss_mb" in p
'
echo "ok - json audit schema valid"

# 5. --check exit-code contract, forced BOTH ways without consulting host state.
#    Utilization can never exceed 100%, so pass-forcing thresholds (1000%) must
#    classify OK and exit 0 on any host.
if ! "$GUARD_SH" --check --warn-mem-pct 1000 --crit-mem-pct 1000 --warn-swap-pct 1000 --crit-swap-pct 1000; then
  echo "FAIL: --check exited non-zero with pass-forcing thresholds" >&2
  exit 1
fi
echo "ok - --check exits 0 with pass-forcing thresholds"

#    Utilization can never be below 0%, so fail-forcing thresholds (0%) must
#    classify CRITICAL and exit 1 whenever the guard can assess the host. When
#    the guard's own status is UNKNOWN (unreadable meminfo), fail-open applies:
#    unknown must never alarm, so --check must exit 0 under the same thresholds.
audit_status="$(printf '%s\n' "$json_out" | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"])')"
if [ "$audit_status" = "UNKNOWN" ]; then
  set +e
  "$GUARD_SH" --check --warn-mem-pct 0 --crit-mem-pct 0 --warn-swap-pct 0 --crit-swap-pct 0
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: --check exited $rc under fail-forcing thresholds while status is UNKNOWN (fail-open violated)" >&2
    exit 1
  fi
  echo "ok - --check exits 0 under fail-forcing thresholds while status is UNKNOWN (fail-open)"
else
  set +e
  "$GUARD_SH" --check --warn-mem-pct 0 --crit-mem-pct 0 --warn-swap-pct 0 --crit-swap-pct 0
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "FAIL: --check exited $rc with fail-forcing thresholds (expected exactly 1)" >&2
    exit 1
  fi
  echo "ok - --check exits 1 with fail-forcing thresholds"
fi

# 6. Text output carries the documented contract fields
if ! text_out="$("$GUARD_SH")"; then
  echo "FAIL: text mode did not run cleanly" >&2
  exit 1
fi
if ! grep -Eq '^fm-jev-mem-guard .*[0-9]{4}-[0-9]{2}-[0-9]{2}T' <<<"$text_out"; then
  echo "FAIL: text output missing name/checked_at header" >&2
  exit 1
fi
if ! grep -Eq 'Status: (OK|WARNING|CRITICAL|UNKNOWN)' <<<"$text_out"; then
  echo "FAIL: text output missing a documented status" >&2
  exit 1
fi
if ! grep -q 'Recommendation:' <<<"$text_out"; then
  echo "FAIL: text output missing recommendation" >&2
  exit 1
fi
echo "ok - text mode runs cleanly"

echo "ok - all Pattern 46 memory guard tests passed"
