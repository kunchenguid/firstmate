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

# Every pair in a batch is dispatched even though the first one fails; the loop
# must not stop early. This is the load-bearing batch guarantee, kept explicit.
test_batch_dispatches_every_pair() {
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

# Boundary cases for batch detection. Each row:
#   <label>|<batch yes/no>|<expect substring>|<args>
# batch=yes -> a 'batch:' line must appear; batch=no -> it must not.
test_batch_mode_boundaries() {
  local label batch expect args out status
  while IFS='|' read -r label batch expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn $args)
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

# Pre-launch PWD hygiene: fm-spawn.sh must normalize the crewmate pane's PWD to
# an absolute path before the harness launches, or a relative PWD=. inherited
# from the spawn environment reaches no-mistakes' git-push gate hook as
# `--gate .` and the daemon silently rejects the run (data/nm-gatepath-g2). This
# guards both that the normalization is wired in ahead of the launch send, and
# that the normalization primitive actually defends a poisoned PWD=..
test_launch_pwd_normalization() {
  local norm_ln launch_ln absdir baseline sh_child bash_parent
  # Static: the `export PWD="$(/bin/pwd)"` send exists and precedes the launch.
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source strings to match
  norm_ln=$(grep -nF 'export PWD="$(/bin/pwd)"' "$SPAWN" | head -1 | cut -d: -f1)
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string to match
  launch_ln=$(grep -nF 'spawn_send_literal "$T" "$LAUNCH"' "$SPAWN" | head -1 | cut -d: -f1)
  [ -n "$norm_ln" ] || fail "fm-spawn.sh no longer normalizes PWD before launch (missing export PWD=\"\$(/bin/pwd)\" send)"
  [ -n "$launch_ln" ] || fail "could not locate the harness launch send (spawn_send_literal) in fm-spawn.sh"
  [ "$norm_ln" -lt "$launch_ln" ] || fail "PWD normalization (line $norm_ln) must precede the harness launch (line $launch_ln)"

  # Behavioral: reproduce the poisoned condition and prove the fix defends it.
  # macOS /bin/sh (bash 3.2) trusts a relative $PWD and echoes '.' verbatim - the
  # gate-breaking case; other /bin/sh (dash) call getcwd() and never exhibit it,
  # so assert the reproduction only where the platform actually shows it.
  absdir=$ROOT
  baseline=$(cd "$absdir" && PWD=. /bin/sh -c 'pwd' 2>/dev/null)
  if [ "$baseline" = "." ]; then
    pass "reproduces the macOS /bin/sh relative-PWD bug (baseline /bin/sh pwd is '.')"
  else
    printf 'note: /bin/sh does not trust a relative PWD here (baseline %s); the gate bug is macOS-specific, checking the normalization postcondition only\n' "${baseline:-empty}" >&2
  fi
  # After the exact normalization fm-spawn.sh sends, a /bin/sh grandchild (the
  # gate hook's own shell) computes an absolute path, never '.'.
  sh_child=$(cd "$absdir" && PWD=. /bin/sh -c 'export PWD="$(/bin/pwd)"; /bin/sh -c pwd')
  case "$sh_child" in
    /*) : ;;
    *) fail "after PWD normalization, a /bin/sh child's pwd must be absolute, got '$sh_child'" ;;
  esac
  [ "$sh_child" != "." ] || fail "after PWD normalization, a /bin/sh child's pwd must never be '.'"
  # A bash parent poisoned the same way (a harness tool subprocess) also ends up
  # with an absolute PWD after normalization, so its own children inherit it.
  bash_parent=$(cd "$absdir" && PWD=. bash -c 'export PWD="$(/bin/pwd)"; printf %s "$PWD"')
  case "$bash_parent" in
    /*) : ;;
    *) fail "after PWD normalization, a poisoned bash shell's PWD must be absolute, got '$bash_parent'" ;;
  esac
  pass "fm-spawn PWD normalization turns a poisoned PWD=. into an absolute PWD for /bin/sh and bash crewmate processes"
}

test_batch_dispatches_every_pair
test_batch_mode_boundaries
test_projects_path_scoping
test_launch_pwd_normalization
