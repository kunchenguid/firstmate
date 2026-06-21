#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh batch dispatch (`id=repo` pairs).
# These exercise argument routing only: each spawn attempt fails fast at the missing-brief
# check, which is reached before any tmux/treehouse side effect, so the tests create no
# windows or worktrees. FM_SPAWN_NO_GUARD=1 keeps them off the live watcher guard / state.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# Run fm-spawn with the guard suppressed; capture combined output and exit status.
run_spawn() {
  FM_SPAWN_NO_GUARD=1 "$SPAWN" "$@" 2>&1
}

test_batch_dispatches_each_pair() {
  local out status
  out=$(run_spawn nope-batch-a-z1=projects/none-a nope-batch-b-z2=projects/none-b)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with missing briefs should exit non-zero"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-a-z1 (projects/none-a)' >/dev/null \
    || fail "first pair was not dispatched/reported"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-b-z2 (projects/none-b)' >/dev/null \
    || fail "second pair was not dispatched/reported (loop stopped early?)"
  pass "batch dispatch re-execs and reports every id=repo pair"
}

test_single_pair_is_batch() {
  local out status
  out=$(run_spawn nope-batch-solo-z3=projects/none-solo)
  status=$?
  [ "$status" -ne 0 ] || fail "single missing-brief pair should exit non-zero"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-solo-z3 (projects/none-solo)' >/dev/null \
    || fail "single id=repo pair was not treated as batch"
  pass "a single id=repo pair routes through batch dispatch"
}

test_single_mode_unaffected() {
  local out status
  out=$(run_spawn nope-single-z4 projects/none-single)
  status=$?
  [ "$status" -ne 0 ] || fail "single-task spawn with missing brief should exit non-zero"
  if printf '%s\n' "$out" | grep -F 'batch:' >/dev/null; then
    fail "plain '<id> <repo>' invocation wrongly entered batch dispatch"
  fi
  pass "single-task invocation (no '=') is untouched by batch detection"
}

test_batch_rejects_non_pair_argument() {
  local out status
  out=$(run_spawn nope-batch-mix-z5=projects/none-mix bogus-no-equals)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with a non-pair argument should exit non-zero"
  printf '%s\n' "$out" | grep -F "batch dispatch expects every argument as id=repo; got 'bogus-no-equals'" >/dev/null \
    || fail "non-pair argument in batch mode was not rejected"
  pass "batch dispatch rejects an argument that is not id=repo"
}

test_id_with_slash_is_not_batch() {
  local out status
  # A first arg whose pre-'=' part contains '/' is not a bare task id, so it must NOT be
  # treated as a batch pair (it falls through to single-task handling).
  out=$(run_spawn weird/id-z6=projects/none projects/none)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed single-task spawn should exit non-zero"
  if printf '%s\n' "$out" | grep -F 'batch:' >/dev/null; then
    fail "first arg with '/' before '=' wrongly entered batch dispatch"
  fi
  pass "an arg whose id part contains '/' is not treated as a batch pair"
}

test_batch_dispatches_each_pair
test_single_pair_is_batch
test_single_mode_unaffected
test_batch_rejects_non_pair_argument
test_id_with_slash_is_not_batch
