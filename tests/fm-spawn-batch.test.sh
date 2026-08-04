#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh batch dispatch (`id=repo` pairs).
#
# These exercise argument routing only: each spawn attempt fails fast at the
# missing-brief check, which is reached before any tmux/treehouse side effect, so
# the tests create no windows or worktrees. FM_SPAWN_NO_GUARD=1 keeps them off the
# live watcher guard / state. Parser and path-scoping cases are table-driven; the
# only behavior asserted on its own is "a multi-pair batch does not stop after the
# first failure".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-batch)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); the
# batch path takes one shared pair of flags for every pair.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# Every pair in a batch is dispatched even though the first one fails; the loop
# must not stop early. This is the load-bearing batch guarantee, kept explicit.
test_batch_dispatches_every_pair() {
  local out status
  out=$(run_ship_spawn nope-batch-a-z1=projects/none-a nope-batch-b-z2=projects/none-b)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with missing briefs should exit non-zero"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-a-z1 (projects/none-a)' >/dev/null \
    || fail "first pair was not dispatched/reported"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-b-z2 (projects/none-b)' >/dev/null \
    || fail "second pair was not dispatched/reported (loop stopped early?)"
  pass "batch dispatch re-execs and reports every id=repo pair"
}

# Boundary cases for batch detection. Each row:
#   <label>|<batch yes/no>|<expect substring>|<args>
# batch=yes -> a 'batch:' line must appear; batch=no -> it must not.
test_batch_mode_boundaries() {
  local label batch expect args out status
  while IFS='|' read -r label batch expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_ship_spawn $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
    if [ -n "$expect" ]; then
      printf '%s\n' "$out" | grep -F "$expect" >/dev/null || fail "$label: missing '$expect'"
    fi
    case "$batch" in
      yes) printf '%s\n' "$out" | grep -F 'batch:' >/dev/null || fail "$label: did not enter batch dispatch" ;;
      no)  printf '%s\n' "$out" | grep -F 'batch:' >/dev/null && fail "$label: wrongly entered batch dispatch" ;;
    esac
  done <<'ROWS'
single id=repo pair routes through batch|yes|batch: FAILED to spawn nope-batch-solo-z3 (projects/none-solo)|nope-batch-solo-z3=projects/none-solo
non-pair arg in batch is rejected|yes|batch dispatch expects every argument as id=repo; got 'bogus-no-equals'|nope-batch-mix-z5=projects/none-mix bogus-no-equals
plain '<id> <repo>' is single-task|no||nope-single-z4 projects/none-single
id part containing '/' is not a pair|no||weird/id-z6=projects/none projects/none
ROWS
  pass "batch detection: single pair batches, non-pair rejected, single-task and slash-id stay single"
}

# A projects/ path is resolved through the firstmate home, never the caller cwd,
# before the missing-brief check. One row per home-scoping override.
test_projects_path_scoping() {
  local label use_override id home projects out status expected
  while IFS='|' read -r label use_override id; do
    [ -n "$label" ] || continue
    home="$TMP_ROOT/$id home"
    projects="$TMP_ROOT/$id projects"
    mkdir -p "$home/data" "$projects/alpha"
    if [ "$use_override" = yes ]; then
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_PROJECTS_OVERRIDE="$projects" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" projects/alpha codex --mode no-mistakes --yolo off 2>&1)
    else
      mkdir -p "$home/projects/alpha"
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" projects/alpha codex --mode no-mistakes --yolo off 2>&1)
    fi
    status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn with missing brief should fail"
    expected="error: no brief at $home/data/$id/brief.md"
    printf '%s\n' "$out" | grep -F "$expected" >/dev/null \
      || fail "$label: projects/alpha was not resolved through the home before the brief check"
    printf '%s\n' "$out" | grep -F 'cd: projects/alpha' >/dev/null \
      && fail "$label: spawn resolved projects/alpha from the caller cwd"
  done <<'ROWS'
FM_HOME scopes projects/|no|nope-home-z7
FM_PROJECTS_OVERRIDE scopes projects/|yes|nope-override-z8
ROWS
  pass "projects/ paths are scoped through the firstmate home for single-task spawn"
}

# A ship batch carries one shared delivery contract. Missing flags must stop the
# whole batch before any pair is dispatched, so a batch can never launch workers
# whose delivery posture was never decided.
test_batch_requires_the_shared_delivery_contract() {
  local out status
  out=$(run_spawn nope-batch-nomode-z9=projects/none-a nope-batch-nomode-z10=projects/none-b)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship batch without --mode should exit non-zero"
  printf '%s\n' "$out" | grep -F 'ship spawns require --mode' >/dev/null \
    || fail "batch refusal did not name the missing delivery mode"
  printf '%s\n' "$out" | grep -F 'batch:' >/dev/null \
    && fail "batch dispatched pairs despite an undecided delivery contract"

  out=$(run_spawn nope-batch-noyolo-z11=projects/none-a --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship batch without --yolo should exit non-zero"
  printf '%s\n' "$out" | grep -F 'ship spawns require --yolo' >/dev/null \
    || fail "batch refusal did not name the missing approval posture"
  pass "batch dispatch requires the shared ship delivery contract before any pair runs"
}

# A scout batch has no delivery contract to share, so the flags are refused rather
# than accepted and ignored.
test_scout_batch_refuses_delivery_flags() {
  local out status
  out=$(run_spawn nope-batch-scout-z12=projects/none-a --scout --mode direct-PR --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout batch carrying delivery flags should exit non-zero"
  printf '%s\n' "$out" | grep -F 'applies only to ship spawns' >/dev/null \
    || fail "scout batch did not refuse the delivery flags"
  pass "scout batch refuses ship delivery flags instead of ignoring them"
}

test_batch_dispatches_every_pair
test_batch_mode_boundaries
test_batch_requires_the_shared_delivery_contract
test_scout_batch_refuses_delivery_flags
test_projects_path_scoping
