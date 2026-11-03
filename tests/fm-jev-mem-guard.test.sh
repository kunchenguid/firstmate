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

# Exercise the public CLI on a simulated Darwin platform with real fake commands.
python3 - "$GUARD_PY" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(prefix="fm-macos-memory-") as tmp:
    root = Path(tmp)
    for name in ("sysctl", "vm_stat"):
        tool = root / name
        tool.write_text("#!/bin/bash\n"
                        'if [ "${SLOW_TELEMETRY:-}" = 1 ]; then sleep 1; fi\n'
                        'case "$*" in\n'
                        '  "-n hw.memsize") cat "$MEM_FIXTURE/total" ;;\n'
                        '  "vm.swapusage") cat "$MEM_FIXTURE/swap" ;;\n'
                        '  "") cat "$MEM_FIXTURE/pages" ;;\n'
                        '  *) exit 1 ;;\nesac\n')
        tool.chmod(0o700)
    env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"], MEM_FIXTURE=tmp)
    (root / "total").write_text(str(1024 ** 3))
    (root / "swap").write_text("vm.swapusage: total = 1.00G used = 0.00G free = 1.00G (encrypted)")

    def pages(available, page_size=4096):
        count = int(available * (1024 ** 3) / page_size)
        (root / "pages").write_text(
            f"Mach Virtual Memory Statistics: (page size of {page_size} bytes)\n"
            f"Pages free: {count}.\nPages inactive: 0.\nPages speculative: 0.\n"
            # These overlap other buckets and cannot be counted as available.
            "Pages purgeable: 999999.\nPages occupied by compressor: 999999.\n")

    def audit(*args, extra_env=None):
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, "-c", "import runpy,sys; sys.platform='darwin'; "
             "p=sys.argv.pop(1); runpy.run_path(p,run_name='__main__')",
             sys.argv[1], "--json", "--check", *args],
            env=dict(env, **(extra_env or {})), text=True, capture_output=True, timeout=3,
        )
        return result.returncode, json.loads(result.stdout), time.monotonic() - started

    for page_size in (4096, 16384):
        pages(0.5, page_size)
        rc, report, elapsed = audit()
        assert (rc, report["status"], report["summary"]["mem_used_pct"]) == (0, "OK", 50.0), report
        assert report["summary"]["swap_used_pct"] == 0.0, report
        assert report["top_processes"] == [], report

    pages(0.08)
    rc, report, _ = audit()
    assert (rc, report["status"]) == (1, "WARNING"), report
    pages(0.01)
    rc, report, _ = audit()
    assert (rc, report["status"]) == (1, "CRITICAL"), report
    pages(0.5)
    (root / "swap").write_text("vm.swapusage: total = 1024.00M used = 980.00M free = 44.00M")
    rc, report, _ = audit()
    assert (rc, report["status"]) == (1, "CRITICAL"), report
    (root / "swap").write_text("vm.swapusage: total = 0.00M used = 0.00M free = 0.00M")
    rc, report, _ = audit()
    assert (rc, report["summary"]["swap_used_pct"]) == (0, 0.0), report
    for swap in ("unavailable", "total = 1G used = 2G free = 0G"):
        (root / "swap").write_text(swap)
        rc, report, _ = audit()
        assert (rc, report["status"], report["summary"]["swap_used_pct"]) == (0, "OK", None), report
    for bad_pages in ("bad output", "Mach Virtual Memory Statistics: (page size of 4096 bytes)\nPages free: 1."):
        (root / "pages").write_text(bad_pages)
        rc, report, _ = audit("--crit-mem-pct", "0")
        assert (rc, report["status"], report["summary"]["mem_used_pct"]) == (0, "UNKNOWN", None), report
    pages(0.5)
    (root / "total").write_text("0")
    rc, report, _ = audit()
    assert (rc, report["status"]) == (0, "UNKNOWN"), report
    (root / "total").write_text(str(1024 ** 3))
    rc, report, elapsed = audit(extra_env={"SLOW_TELEMETRY": "1"})
    assert (rc, report["status"]) == (0, "UNKNOWN"), report
    assert elapsed < 0.9, elapsed
    (root / "sysctl").unlink()
    (root / "sysctl").symlink_to("/usr/bin/false")
    rc, report, _ = audit()
    assert (rc, report["status"]) == (0, "UNKNOWN"), report
print("ok - Darwin CLI fake-command cases: page sizes, thresholds, swap, invalid data, timeout, failure")
PYTEST

echo "ok - all Pattern 46 memory guard tests passed"
