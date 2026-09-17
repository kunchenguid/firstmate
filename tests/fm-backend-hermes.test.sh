#!/usr/bin/env bash
# tests/fm-backend-hermes.test.sh - unit tests for the Hermes session-provider
# adapter (bin/backends/hermes.sh). Exercises the state/target_exists helpers
# that depend on PID file contents, without launching a live Hermes process.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-backend-hermes-tests)

# Source the hermes backend adapter. It sources fm-backend.sh itself to
# get the shared dispatch helpers.
# shellcheck source=/dev/null
. "$ROOT/bin/backends/hermes.sh"

state="$TMP_ROOT/state"
mkdir -p "$state"

# --- fm_backend_hermes_pid_path ----------------------------------------------

pidfile=$(fm_backend_hermes_pid_path "$state" "task1")
[ "$pidfile" = "$state/task1.hermes-pid" ] \
  || fail "pid_path: expected $state/task1.hermes-pid, got $pidfile"
pass "fm_backend_hermes_pid_path returns <state>/<id>.hermes-pid"

# --- fm_backend_hermes_agent_state ------------------------------------------

# No pidfile → missing.
state_missing=$(fm_backend_hermes_agent_state "hermes:$state/does-not-exist.hermes-pid")
[ "$state_missing" = "missing" ] \
  || fail "agent_state: expected missing, got $state_missing"
pass "fm_backend_hermes_agent_state: missing when pidfile absent"

# Invalid target (no colon) → unreadable.
state_invalid=$(fm_backend_hermes_agent_state "not-a-valid-target")
[ "$state_invalid" = "unreadable" ] \
  || fail "agent_state: expected unreadable, got $state_invalid"
pass "fm_backend_hermes_agent_state: unreadable for malformed target"

# Empty pidfile → unreadable.
printf '' > "$state/empty.hermes-pid"
state_empty=$(fm_backend_hermes_agent_state "hermes:$state/empty.hermes-pid")
[ "$state_empty" = "unreadable" ] \
  || fail "agent_state: expected unreadable for empty pidfile, got $state_empty"
pass "fm_backend_hermes_agent_state: unreadable for empty pidfile"

# Non-numeric pidfile → unreadable.
printf 'not-a-pid\n' > "$state/garbage.hermes-pid"
state_garbage=$(fm_backend_hermes_agent_state "hermes:$state/garbage.hermes-pid")
[ "$state_garbage" = "unreadable" ] \
  || fail "agent_state: expected unreadable for non-numeric pid, got $state_garbage"
pass "fm_backend_hermes_agent_state: unreadable for non-numeric pid"

# Numeric but dead pid → dead.
printf '999999\n' > "$state/dead.hermes-pid"
state_dead=$(fm_backend_hermes_agent_state "hermes:$state/dead.hermes-pid")
[ "$state_dead" = "dead" ] \
  || fail "agent_state: expected dead for nonexistent pid, got $state_dead"
pass "fm_backend_hermes_agent_state: dead for nonexistent pid"

# --- fm_backend_hermes_target_exists -----------------------------------------

# No pidfile → false (exit 1).
if fm_backend_hermes_target_exists "hermes:$state/does-not-exist.hermes-pid" 2>/dev/null; then
  fail "target_exists: should return false when pidfile absent"
fi
pass "fm_backend_hermes_target_exists: false when pidfile absent"

# Dead pid → false (exit 1).
if fm_backend_hermes_target_exists "hermes:$state/dead.hermes-pid" 2>/dev/null; then
  fail "target_exists: should return false for dead pid"
fi
pass "fm_backend_hermes_target_exists: false for dead pid"

# --- dispatch wiring ---------------------------------------------------------

# Verify hermes is recognized by fm_backend_agent_state dispatch.
agent_state_hermes=$(fm_backend_agent_state hermes "hermes:$state/dead.hermes-pid")
[ "$agent_state_hermes" = "dead" ] \
  || fail "fm_backend_agent_state hermes dispatch: expected dead, got $agent_state_hermes"
pass "fm_backend_agent_state dispatches hermes to fm_backend_hermes_agent_state"

# Unknown backend → unverified.
state_unknown=$(fm_backend_agent_state notabackend "x")
[ "$state_unknown" = "unverified" ] \
  || fail "fm_backend_agent_state unknown: expected unverified, got $state_unknown"
pass "fm_backend_agent_state returns unverified for unknown backend"

printf 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0\n'
