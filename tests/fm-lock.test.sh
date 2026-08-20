#!/usr/bin/env bash
# Characterization coverage for fm-lock's read-only status contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)
STATE="$TMP_ROOT/state"

test_status_reports_free_and_stale_locks() {
  local out

  out=$(FM_STATE_OVERRIDE="$STATE" "$LOCK" status 2>&1) \
    || fail "status should succeed when no lock exists: $out"
  assert_contains "$out" "lock: free" \
    "status should report a missing lock as free"
  pass "status reports a missing lock as free"

  printf '%s\n' 999999 > "$STATE/.lock"
  out=$(FM_STATE_OVERRIDE="$STATE" "$LOCK" status 2>&1) \
    || fail "status should succeed for a stale lock: $out"
  assert_contains "$out" "lock: stale (pid 999999 dead or not a harness)" \
    "status should report a dead lock holder as stale"
  pass "status reports a dead lock holder as stale"
}

test_status_reports_free_and_stale_locks
