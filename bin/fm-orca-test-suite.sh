#!/usr/bin/env bash
# bin/fm-orca-test-suite.sh — comprehensive orca health check.
#
# Runs every orca-specific diagnostic in one command and reports a
# per-check status with a final pass/fail line. The captain runs this
# before any session start on an orca-backed home, or after a supervisor
# or daemon change, to confirm the pipeline is healthy.
#
# Checks performed:
#   1. orca binary on PATH
#   2. python3 on PATH (fmod/orca adapter JSON parsing)
#   3. setsid available (supervisor needs it for daemon relaunch)
#   4. config/backend = orca (or --expected-backend override)
#   5. config/crew-harness set (the spawn target)
#   6. orca daemon reachable (via bin/fmod ping)
#   7. PROTOCOL_VERSION match (no Protocol version mismatch on the wire)
#   8. supervisor running (live pid in state/.orca-supervisor.pid)
#   9. supervisor logs recent and error-free
#  10. fmod list (sanity: daemon actually owns live sessions)
#  11. spawn → turn-end → teardown full end-to-end (the real test)
#  12. tests/fm-backend-orca.test.sh (10 unit tests)
#  13. tests/fm-supervise-orca.test.sh (4 supervisor unit tests)
#  14. tests/fm-use-orca.test.sh (5 switcher unit tests, skip with --no-unit)
#  15. bin/fm-bootstrap.sh reports ORCA: daemon reachable
#
# Usage:
#   bin/fm-orca-test-suite.sh [--no-unit] [--no-spawn] [--expected-backend X]
#     --no-unit             skip the shell unit-test suites (12, 13, 14)
#     --no-spawn            skip the live end-to-end spawn check (11)
#     --expected-backend X  fail check 4 if config/backend is not X
#     --json                emit one JSON object per check; useful for
#                           programmatic consumption (e.g. watch.sh tests)
#
# Exit: 0 if every check passes; 1 if any fails. The final line is always
# a single "orca-test-suite: PASS" or "orca-test-suite: FAIL" so a tail -1
# in another script can do the yes/no read in one line.

set -u

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FMOD=${FM_ORCA_FMOD:-"$FM_ROOT/bin/fmod"}
SUPERVISOR="$FM_ROOT/bin/fm-supervise-orca.sh"
FM_BOOTSTRAP="$FM_ROOT/bin/fm-bootstrap.sh"
TESTS_DIR="$FM_ROOT/tests"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

NO_UNIT=0
NO_SPAWN=0
EXPECTED_BACKEND=
JSON_OUT=0
SUITE_TOTAL=0
SUITE_PASS=0
SUITE_FAIL=0
JSON_RESULTS="[]"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-unit) NO_UNIT=1 ;;
    --no-spawn) NO_SPAWN=1 ;;
    --expected-backend=*) EXPECTED_BACKEND=${1#--expected-backend=} ;;
    --expected-backend) shift; EXPECTED_BACKEND=${1:-} ;;
    --json) JSON_OUT=1 ;;
  esac
  shift || break
done

json_append_result() {
  local name=$1 passed=$2 log=$3
  printf '%s' "$JSON_RESULTS" | python3 -c '
import json
import sys

arr = json.load(sys.stdin)
arr.append({"name": sys.argv[1], "pass": sys.argv[2] == "1", "log": sys.argv[3]})
print(json.dumps(arr))
' "$name" "$passed" "$log"
}

# Run a check: $1 = name, $2 = expected pass condition (0/1), $3 = log
# Returns 0 if pass, 1 if fail; prints check line; updates counters.
run_check() {
  local name=$1 result=$2 log=$3
  SUITE_TOTAL=$((SUITE_TOTAL + 1))
  if [ "$result" -eq 0 ]; then
    SUITE_PASS=$((SUITE_PASS + 1))
    if [ "$JSON_OUT" -eq 1 ]; then
      JSON_RESULTS=$(json_append_result "$name" 1 "$log")
    else
      printf '  ✓ %-40s %s\n' "$name" "$log"
    fi
    return 0
  fi
  SUITE_FAIL=$((SUITE_FAIL + 1))
  if [ "$JSON_OUT" -eq 1 ]; then
    JSON_RESULTS=$(json_append_result "$name" 0 "$log")
  else
    printf '  ✗ %-40s %s\n' "$name" "$log" >&2
  fi
  return 1
}

# 1. orca binary
[ -x "$(command -v orca 2>/dev/null)" ] || true
run_check "orca-binary" $([ -x "$(command -v orca 2>/dev/null)" ] && echo 0 || echo 1) "$(command -v orca 2>/dev/null || echo 'missing')"

# 2. python3
run_check "python3-binary" $([ -x "$(command -v python3 2>/dev/null)" ] && echo 0 || echo 1) "$(command -v python3 2>/dev/null || echo 'missing')"

# 3. setsid
run_check "setsid-available" $([ -x "$(command -v setsid 2>/dev/null)" ] && echo 0 || echo 1) "$(command -v setsid 2>/dev/null || echo 'missing')"

# 4. config/backend
actual_backend=$(tr -d '[:space:]' < "$CONFIG/backend" 2>/dev/null || true)
if [ -n "$EXPECTED_BACKEND" ]; then
  if [ "$actual_backend" = "$EXPECTED_BACKEND" ]; then
    run_check "config-backend" 0 "$actual_backend (matches --expected-backend)"
  else
    run_check "config-backend" 1 "$actual_backend (expected $EXPECTED_BACKEND)"
  fi
else
  if [ "$actual_backend" = orca ]; then
    run_check "config-backend" 0 "$actual_backend"
  else
    run_check "config-backend" 1 "$actual_backend (run bin/fm-use-orca.sh to switch)"
  fi
fi

# 5. config/crew-harness
crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" 2>/dev/null || true)
if [ -n "$crew" ]; then
  run_check "config-crew-harness" 0 "$crew"
else
  run_check "config-crew-harness" 1 "unset (run bin/fm-use-orca.sh to set)"
fi

# 6. orca daemon reachable
if [ -x "$FMOD" ]; then
  reachable=0
  log=$(timeout 5 "$FMOD" ping 2>&1) || reachable=1
  run_check "fmod-ping" "$reachable" "$(printf '%s' "$log" | head -c 60)"
else
  run_check "fmod-ping" 1 "bin/fmod missing"
fi

# 7. PROTOCOL_VERSION match
if [ -x "$FMOD" ]; then
  info=$(timeout 5 "$FMOD" info 2>&1) || true
  if printf '%s' "$info" | grep -q '"daemon_reachable": *true'; then
    run_check "protocol-version" 0 "daemon reports reachable=true"
  else
    err=$(printf '%s' "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('daemon_error','unknown'))" 2>/dev/null || echo "unknown")
    run_check "protocol-version" 1 "$err"
  fi
else
  run_check "protocol-version" 1 "bin/fmod missing"
fi

# 8. supervisor running
supervisor_status=$("$SUPERVISOR" status 2>&1)
supervisor_line=$(printf '%s\n' "$supervisor_status" | sed -n '1p')
if printf '%s\n' "$supervisor_status" | grep -q '^supervisor: live pid='; then
  run_check "supervisor-live" 0 "${supervisor_line#supervisor: live }"
else
  run_check "supervisor-live" 1 "${supervisor_line:-no live pid (run bin/fm-supervise-orca.sh start)}"
fi

# 9. supervisor log fresh + no recent errors
log_file=/tmp/fm-supervise-orca.log
if [ -f "$log_file" ]; then
  age_s=$(( $(date +%s) - $(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0) ))
  if [ "$age_s" -lt 600 ]; then
    if grep -q -E "(error|fail|warn)" "$log_file" 2>/dev/null; then
      run_check "supervisor-log" 1 "recent errors in $log_file"
    else
      run_check "supervisor-log" 0 "fresh (${age_s}s old), no errors"
    fi
  else
    run_check "supervisor-log" 1 "stale (${age_s}s old, expected <600s)"
  fi
else
  run_check "supervisor-log" 1 "$log_file not present"
fi

# 10. fmod list sanity
if [ -x "$FMOD" ]; then
  if list=$(timeout 5 "$FMOD" list 2>&1); then
    if count=$(printf '%s' "$list" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null); then
      run_check "fmod-list" 0 "$count session(s) visible"
    else
      run_check "fmod-list" 1 "unparsable JSON: $(printf '%s' "$list" | head -c 80)"
    fi
  else
    run_check "fmod-list" 1 "$(printf '%s' "$list" | head -c 80)"
  fi
else
  run_check "fmod-list" 1 "bin/fmod missing"
fi

# 11. end-to-end spawn (the real test)
if [ "$NO_SPAWN" -eq 0 ]; then
  suite_id="fm-orca-test-$$"
  data_dir="$DATA/$suite_id"
  smoke_project=${FM_ORCA_SMOKE_PROJECT:-}
  if [ -z "$smoke_project" ] && [ -d "$FM_HOME/projects" ]; then
    for candidate in "$FM_HOME"/projects/*; do
      [ -d "$candidate/.git" ] || git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 || continue
      smoke_project=$candidate
      break
    done
  fi
  mkdir -p "$data_dir" 2>/dev/null || true
  printf '# %s\nFirstmate orca test-suite smoke. Confirm alive in one short sentence.\n' "$suite_id" > "$data_dir/brief.md"
  if [ -z "$smoke_project" ]; then
    run_check "spawn-turn-end" 1 "no smoke project found (set FM_ORCA_SMOKE_PROJECT)"
  elif out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-spawn.sh" "$suite_id" "$smoke_project" --backend orca --harness "$(printf '%s' "$crew" | tr -d '[:space:]')" 2>&1); then
    # Wait for turn-end. Pi on MiniMax-M3 is variable: 18s on a fast daemon,
    # 60-90s on a slow one. 120s is a comfortable bound for the daily-driver
    # check; the operator can override with --no-spawn for an instant verdict.
    waited=0
    while [ ! -f "$STATE/$suite_id.turn-ended" ] && [ "$waited" -lt 120 ]; do
      sleep 2
      waited=$((waited + 2))
    done
    if [ -f "$STATE/$suite_id.turn-ended" ]; then
      run_check "spawn-turn-end" 0 "fired after ${waited}s"
    else
      run_check "spawn-turn-end" 1 "did not fire within 120s"
    fi
    "$FM_ROOT/bin/fm-teardown.sh" "$suite_id" >/dev/null 2>&1 || true
  else
    run_check "spawn-turn-end" 1 "$(printf '%s' "$out" | head -c 80)"
  fi
  rm -rf "$data_dir" 2>/dev/null || true
else
  run_check "spawn-turn-end" 0 "skipped (--no-spawn)"
fi

# 12, 13, 14. unit tests
if [ "$NO_UNIT" -eq 0 ]; then
  for t in tests/fm-backend-orca.test.sh tests/fm-supervise-orca.test.sh tests/fm-use-orca.test.sh; do
    if [ -x "$FM_ROOT/$t" ]; then
      # shellcheck disable=SC2086
      if out=$(bash "$FM_ROOT/$t" 2>&1); then
        pass=$(printf '%s' "$out" | grep -c "^ok -")
        run_check "unit-$t" 0 "$pass test(s) passed"
      else
        run_check "unit-$t" 1 "$(printf '%s' "$out" | tail -1 | head -c 80)"
      fi
    fi
  done
else
  run_check "unit-tests" 0 "skipped (--no-unit)"
fi

# 15. bootstrap diagnostic
if [ -x "$FM_BOOTSTRAP" ]; then
  bootstrap_line=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_HOME="$FM_HOME" FM_BACKEND=orca "$FM_BOOTSTRAP" 2>&1 | grep "^ORCA:" | head -1)
  if printf '%s\n' "$bootstrap_line" | grep -Eq "^ORCA: daemon (reachable|recovered)$"; then
    run_check "bootstrap-ORCA-line" 0 "$bootstrap_line"
  else
    run_check "bootstrap-ORCA-line" 1 "$bootstrap_line"
  fi
else
  run_check "bootstrap-ORCA-line" 1 "bin/fm-bootstrap.sh missing"
fi

# Final summary
if [ "$JSON_OUT" -eq 1 ]; then
  printf '%s\n' "$JSON_RESULTS"
  [ "$SUITE_FAIL" -eq 0 ] && exit 0
  exit 1
else
  printf '\n'
  if [ "$SUITE_FAIL" -eq 0 ]; then
    printf 'orca-test-suite: PASS (%d/%d checks)\n' "$SUITE_PASS" "$SUITE_TOTAL"
    exit 0
  fi
  printf 'orca-test-suite: FAIL (%d/%d passed, %d failed)\n' "$SUITE_PASS" "$SUITE_TOTAL" "$SUITE_FAIL"
  exit 1
fi
