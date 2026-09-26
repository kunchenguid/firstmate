#!/usr/bin/env bash
# Argument-validation tests for fm-spawn.sh single-task spawns: a ship or scout
# spawn missing its <project-dir> positional, and a project argument that does
# not resolve to a directory, must both print the usage block and exit 2
# instead of crashing on an unbound variable or failing downstream in `cd`.
#
# These exercise argument validation only: every failing case refuses before
# any tmux/treehouse side effect, and the valid-spawn case fails fast at the
# missing-brief check, which is reached before any window or worktree is
# created. FM_SPAWN_NO_GUARD=1 keeps them off the live watcher guard / state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-missing-arg)
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

USAGE_SYNOPSIS='Usage: fm-spawn.sh <task-id> <project-dir>'

# A ship or scout spawn without a <project-dir> positional used to crash with
# `POS[1]: unbound variable` under set -u instead of printing usage.
test_missing_project_dir_prints_usage_and_exits_2() {
  local out status
  out=$(run_spawn missing-z1 --mode direct-PR --yolo off --effort high)
  status=$?
  expect_code 2 "$status" "ship spawn without <project-dir>"
  assert_contains "$out" "error: a ship or scout spawn requires a <project-dir> positional after the task id" "ship: missing <project-dir> must be named in the error"
  assert_contains "$out" "$USAGE_SYNOPSIS" "ship: usage block must be printed"
  assert_not_contains "$out" "unbound variable" "ship: missing <project-dir> must not crash on an unbound variable"

  out=$(run_spawn missing-z2 --scout --effort high)
  status=$?
  expect_code 2 "$status" "scout spawn without <project-dir>"
  assert_contains "$out" "error: a ship or scout spawn requires a <project-dir> positional after the task id" "scout: missing <project-dir> must be named in the error"
  assert_contains "$out" "$USAGE_SYNOPSIS" "scout: usage block must be printed"
  assert_not_contains "$out" "unbound variable" "scout: missing <project-dir> must not crash on an unbound variable"
  pass "ship and scout spawns missing <project-dir> print usage and exit 2"
}

# A bare project name (spatialx instead of projects/spatialx) and a
# projects/<name> path with no directory used to fall through to a confusing
# `cd` failure; both must be usage-level errors naming the passed argument.
test_unresolvable_project_dir_prints_usage_and_exits_2() {
  local out status
  out=$(run_spawn bare-z3 spatialx --mode direct-PR --yolo off --effort high)
  status=$?
  expect_code 2 "$status" "bare project name"
  assert_contains "$out" "error: project directory 'spatialx' does not resolve to a directory" "bare name must be named in the error"
  assert_contains "$out" "$USAGE_SYNOPSIS" "bare name: usage block must be printed"
  assert_not_contains "$out" "cd: spatialx" "bare name must not fail downstream in cd"

  out=$(run_spawn nores-z4 projects/nowhere --mode direct-PR --yolo off --effort high)
  status=$?
  expect_code 2 "$status" "projects/<name> path with no directory"
  assert_contains "$out" "error: project directory 'projects/nowhere' does not resolve to a directory" "the passed argument must be named in the error"
  assert_contains "$out" "$USAGE_SYNOPSIS" "missing dir: usage block must be printed"
  assert_not_contains "$out" "cd: projects/nowhere" "missing dir must not fail downstream in cd"
  pass "unresolvable <project-dir> arguments print usage and exit 2"
}

# A valid project path must keep resolving through the firstmate home and
# reach the missing-brief check exactly as before the guards were added.
test_valid_project_dir_still_reaches_brief_check() {
  local home out status expected
  home="$TMP_ROOT/valid home"
  mkdir -p "$home/data" "$home/projects/alpha"
  git -C "$home/projects/alpha" init -q || fail "could not initialize project fixture"
  out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" valid-z5 projects/alpha --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "valid spawn with no brief"
  expected="error: task valid-z5 has no brief at inaccessible data path $home/data/valid-z5/brief.md"
  assert_contains "$out" "$expected" "valid <project-dir> must still resolve through the home before the brief check"
  assert_not_contains "$out" "$USAGE_SYNOPSIS" "a valid spawn must not print the usage block"
  pass "valid <project-dir> spawns reach the brief check unchanged"
}

# The missing-positional guard must stay scoped to ship and scout spawns: a
# secondmate spawn takes no project positional (its home comes later), and a
# relaunch takes the task id only.
test_other_kinds_do_not_require_project_dir() {
  local out status
  out=$(run_spawn sm-z6 --secondmate)
  status=$?
  expect_code 1 "$status" "secondmate spawn without a home"
  assert_not_contains "$out" "requires a <project-dir> positional" "secondmate spawn must not require the project positional"
  assert_contains "$out" "error: no firstmate home supplied or registered for sm-z6" "secondmate spawn must keep its own refusal"

  out=$(run_spawn rl-z7 --relaunch)
  status=$?
  expect_code 1 "$status" "relaunch with no task record"
  assert_not_contains "$out" "requires a <project-dir> positional" "relaunch takes the task id only"
  assert_contains "$out" "--relaunch needs an existing task record" "relaunch must keep its own refusal"
  pass "secondmate and relaunch spawns do not require the project positional"
}

test_missing_project_dir_prints_usage_and_exits_2
test_unresolvable_project_dir_prints_usage_and_exits_2
test_valid_project_dir_still_reaches_brief_check
test_other_kinds_do_not_require_project_dir
