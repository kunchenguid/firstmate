#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh missing mandatory positionals.
#
# A spawn missing its task id or project directory must exit with a one-line
# usage error naming the missing piece. Under set -u these used to die as
# "POS[0]/POS[1]: unbound variable" deep in the launch path, so every case also
# asserts the crash signature stays gone. Each case fails fast at argument
# validation or a later brief/registry check, before any tmux/treehouse side
# effect; FM_SPAWN_NO_GUARD=1 keeps them off the live watcher guard / state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-missing-positional)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so the behavior test owns its environment,
# and point FM_HOME at a private temp home so nothing touches the caller's home.
run_spawn() {
  local home="$TMP_ROOT/home"
  mkdir -p "$home/state" "$home/data"
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Every row: <label>|<expect substring>|<args>. Every case must exit non-zero
# with the expected guided message and never the unbound-variable crash.
test_missing_positionals_exit_with_guided_usage() {
  local label expect args out status
  while IFS='|' read -r label expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
    printf '%s\n' "$out" | grep -F 'unbound variable' >/dev/null \
      && fail "$label: still crashes with an unbound-variable trace"
    printf '%s\n' "$out" | grep -Fe "$expect" >/dev/null || fail "$label: missing '$expect'"
  done <<'ROWS'
scout spawn with no positionals names the missing task id|error: missing task id|--scout
ship spawn with no positionals names the missing task id|error: missing task id|--mode no-mistakes --yolo off
scout spawn without a project dir names the missing piece|error: missing project directory; scout spawn 'nope-pos-z1'|nope-pos-z1 --scout
ship spawn without a project dir names the missing piece|error: missing project directory; ship spawn 'nope-pos-z2'|nope-pos-z2 --mode no-mistakes --yolo off
relaunch takes the id only and reads the rest from the record|--relaunch needs an existing task record|nope-pos-z3 --relaunch
secondmate keeps its optional home positional|no firstmate home supplied or registered for nope-pos-z4|nope-pos-z4 --secondmate
ROWS
  pass "missing mandatory positionals exit with a guided usage error and no unbound-variable trace"
}

# The guard sits after batch routing, so a single-pair batch (one positional)
# must still dispatch through the batch path instead of being caught as a
# missing project directory.
test_single_pair_batch_still_dispatches() {
  local out status
  out=$(run_spawn nope-pos-batch-z5=projects/none-a --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "single-pair batch should still fail on its missing repo"
  printf '%s\n' "$out" | grep -F 'missing project directory' >/dev/null \
    && fail "single-pair batch was wrongly caught by the ship positional guard"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-pos-batch-z5 (projects/none-a)' >/dev/null \
    || fail "single-pair batch no longer routes through batch dispatch"
  pass "a single id=repo pair still dispatches through batch routing past the guard"
}

test_missing_positionals_exit_with_guided_usage
test_single_pair_batch_still_dispatches
