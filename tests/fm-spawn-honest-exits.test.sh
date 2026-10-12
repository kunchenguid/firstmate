#!/usr/bin/env bash
# tests/fm-spawn-honest-exits.test.sh - regression coverage ensuring bin/fm-spawn.sh
# exits with honest error messages naming the failing stage rather than silent exit 1.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-honest-exits)

test_spawn_refuses_invalid_fm_home_with_error() {
  local out rc=0
  out=$(cd "$TMP_ROOT" && FM_SPAWN_NO_GUARD=1 FM_HOME="does-not-exist-$$" "$SPAWN" --secondmate sm1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn without valid FM_HOME should exit non-zero"
  assert_contains "$out" "error: failed to resolve FM_HOME directory" "spawn must print an honest error on invalid FM_HOME"
  pass "spawn: invalid FM_HOME exits non-zero with honest error message"
}

test_spawn_refuses_unknown_backend_with_error() {
  local w out rc=0
  w="$TMP_ROOT/bad-backend"
  mkdir -p "$w/state" "$w/data" "$w/config"
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$w" "$SPAWN" --secondmate sm1 --backend bogus 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn with unknown backend should exit non-zero"
  assert_contains "$out" "error: unknown backend 'bogus'" "spawn must name the unknown backend error"
  pass "spawn: unknown backend exits non-zero with honest error message"
}

test_spawn_lock_contention_names_in_progress() {
  local w out rc=0
  w="$TMP_ROOT/lock-contention"
  mkdir -p "$w/state" "$w/data" "$w/config"
  # Hold the spawn task lock
  ( STATE="$w/state" bash -c \
      '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$w/state/.spawn-sm1.lock" ) &
  local holder=$! i=0
  while [ ! -d "$w/state/.spawn-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$w/state/.spawn-sm1.lock" ] || fail "failed to acquire spawn lock"

  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$w" "$SPAWN" --secondmate sm1 2>&1) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -ne 0 ] || fail "spawn under lock contention should exit non-zero"
  assert_contains "$out" "error: another spawn is already creating task sm1" \
    "spawn lock contention must print honest error message"
  pass "spawn: lock contention exits non-zero with honest error message"
}

test_spawn_refuses_invalid_effort_with_error() {
  local w out rc=0
  w="$TMP_ROOT/bad-effort"
  mkdir -p "$w/state" "$w/data" "$w/config"
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$w" "$SPAWN" --secondmate sm1 --harness claude --effort ultra 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn with ultra effort on non-pi harness should exit non-zero"
  assert_contains "$out" "error: " "spawn must report error on invalid effort"
  pass "spawn: invalid effort exits non-zero with honest error message"
}

test_spawn_refuses_refused_relaunch_with_error() {
  local w out rc=0
  w="$TMP_ROOT/relaunch-no-meta"
  mkdir -p "$w/state" "$w/data" "$w/config"
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$w" "$SPAWN" sm1 --relaunch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "relaunch without meta should exit non-zero"
  assert_contains "$out" "error: --relaunch needs an existing task record" \
    "relaunch without meta must print honest error message"
  pass "spawn: relaunch without existing meta exits non-zero with honest error message"
}

test_spawn_refuses_invalid_fm_home_with_error
test_spawn_refuses_unknown_backend_with_error
test_spawn_lock_contention_names_in_progress
test_spawn_refuses_invalid_effort_with_error
test_spawn_refuses_refused_relaunch_with_error

echo "# all fm-spawn-honest-exits tests passed"
