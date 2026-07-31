#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh `id=repo` compatibility dispatch.
#
# These exercise argument routing only.
# A single pair reaches the ordinary missing-brief check before any backend effect.
# Multiple legacy pairs must fail before the first task because unbound tasks are broadly exclusive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-batch)
mkdir -p "$TMP_ROOT/config"
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE="$TMP_ROOT/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Multiple unbound pairs are rejected before any single-task re-exec.
test_multi_pair_legacy_batch_is_rejected_atomically() {
  local out status
  out=$(run_spawn nope-batch-a-z1=projects/none-a nope-batch-b-z2=projects/none-b)
  status=$?
  expect_code 1 "$status" "multi-pair legacy dispatch should fail"
  assert_contains "$out" "multi-task legacy batch is broadly exclusive" \
    "legacy batch refusal did not explain the WorkGraph boundary"
  assert_not_contains "$out" "error: no brief at" \
    "legacy batch dispatched a task before completing preflight"
  pass "multi-pair legacy dispatch is rejected atomically before the first spawn"
}

# Boundary cases for batch detection. Each row:
#   <label>|<batch yes/no>|<expect substring>|<args>
# alias=yes -> the single-pair re-exec or batch preflight diagnostic must appear.
test_batch_mode_boundaries() {
  local label alias expect args out status
  while IFS='|' read -r label alias expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
    if [ -n "$expect" ]; then
      printf '%s\n' "$out" | grep -F "$expect" >/dev/null || fail "$label: missing '$expect'"
    fi
    case "$alias" in
      yes) : ;;
      no) assert_not_contains "$out" "batch dispatch expects" "$label: wrongly entered id=repo dispatch" ;;
    esac
  done <<'ROWS'
single id=repo pair routes through ordinary spawn|yes|projects/none-solo: No such file or directory|nope-batch-solo-z3=projects/none-solo
non-pair arg in batch is rejected|yes|batch dispatch expects every argument as id=repo; got 'bogus-no-equals'|nope-batch-mix-z5=projects/none-mix bogus-no-equals
plain '<id> <repo>' is single-task|no||nope-single-z4 projects/none-single
id part containing '/' is not a pair|no||weird/id-z6=projects/none projects/none
ROWS
  pass "id=repo detection: single alias works, malformed pairs reject, and ordinary syntax stays ordinary"
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
        "$SPAWN" "$id" projects/alpha codex 2>&1)
    else
      mkdir -p "$home/projects/alpha"
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" projects/alpha codex 2>&1)
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

test_multi_pair_legacy_batch_is_rejected_atomically
test_batch_mode_boundaries
test_projects_path_scoping
