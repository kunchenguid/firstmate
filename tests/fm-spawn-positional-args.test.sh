#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh positional-argument guards.
#
# Omitting <task-id> or <project-dir> used to fall through to an unguarded
# array read and die with a raw shell error (`POS[1]: unbound variable`), and
# a bare project NAME (instead of a path) leaked a raw `cd ... No such file`
# with an internal line number. Both are usage errors and must read like the
# script's existing --mode refusal: a clear message naming what to resolve, a
# non-zero exit, and nothing spawned. A raw launch-command harness keeps these
# cases off any installed-harness validation; every case below fails before
# the missing-brief check, so no windows or worktrees are created.
# FM_SPAWN_NO_GUARD=1 keeps them off the live watcher guard / state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-positional-args)
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

expect_refusal() {  # <label> <expected-substring> <command...>: non-zero exit, message present, no raw shell crash
  local label=$1 expected=$2 out status
  shift 2
  out=$("$@" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
  printf '%s\n' "$out" | grep -F "$expected" >/dev/null \
    || fail "$label: missing '$expected' (got: $out)"
  printf '%s\n' "$out" | grep -F 'unbound variable' >/dev/null \
    && fail "$label: leaked a raw unbound-variable crash"
  printf '%s\n' "$out" | grep -F 'fm-spawn.sh: line' >/dev/null \
    && fail "$label: leaked an internal line number"
}

test_missing_project_dir() {
  local out status
  out=$(run_spawn nope-missing-proj-z1 --mode direct-PR --yolo on --harness 'sleep 60')
  status=$?
  [ "$status" -ne 0 ] || fail "missing project-dir: expected non-zero exit"
  printf '%s\n' "$out" | grep -F 'missing <project-dir>' >/dev/null \
    || fail "missing project-dir: refusal did not name the missing argument (got: $out)"
  printf '%s\n' "$out" | grep -F 'unbound variable' >/dev/null \
    && fail "missing project-dir: leaked a raw unbound-variable crash"
  pass "missing project-dir is refused with a usage error naming the argument"
}

test_missing_task_id() {
  expect_refusal "missing task-id" "missing <task-id>" \
    run_spawn --mode direct-PR --yolo on --harness 'sleep 60'
  pass "missing task-id is refused with a usage error naming the argument"
}

test_scout_missing_project_dir() {
  expect_refusal "scout missing project-dir" "missing <project-dir>" \
    run_spawn nope-scout-proj-z2 --scout --harness 'sleep 60'
  pass "scout missing project-dir is refused with the same usage error"
}

test_bare_project_name_is_not_a_path() {
  local out status
  out=$(run_spawn nope-bare-name-z3 video-editing-pilot --mode direct-PR --yolo on --harness 'sleep 60')
  status=$?
  [ "$status" -ne 0 ] || fail "bare project name: expected non-zero exit"
  printf '%s\n' "$out" | grep -F 'is not a directory path' >/dev/null \
    || fail "bare project name: refusal did not say a path is required (got: $out)"
  printf '%s\n' "$out" | grep -F 'No such file' >/dev/null \
    && fail "bare project name: leaked a raw cd failure"
  printf '%s\n' "$out" | grep -F 'fm-spawn.sh: line' >/dev/null \
    && fail "bare project name: leaked an internal line number"
  pass "bare project name is refused with a message saying a path is required"
}

test_unresolvable_path_is_refused_clearly() {
  expect_refusal "unresolvable project path" "project directory cannot be resolved" \
    run_spawn nope-bad-path-z4 ./no-such-dir-here --mode direct-PR --yolo on --harness 'sleep 60'
  pass "unresolvable project path is refused without a raw cd error"
}

# A refused spawn must leave no trace: no lock, no meta, no state at all in
# the home it ran against. Failing before backend selection, locks, and the
# state-directory creation is what makes that true.
test_refused_spawn_leaves_no_state() {
  local home="$TMP_ROOT/empty-home" id=nope-no-state-z5 out status
  mkdir -p "$home/data"
  out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --mode direct-PR --yolo on --harness 'sleep 60' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "refused spawn: expected non-zero exit"
  [ ! -e "$home/state" ] || [ -z "$(ls -A "$home/state")" ] \
    || fail "refused spawn: left state behind ($(ls -A "$home/state"))"
  pass "refused spawn leaves no state behind"
}

# The secondmate branch reads its optional home positionally with a default,
# so a missing home must still reach that branch's own refusal rather than a
# crash. This pins the rest of the sweep: every other positional read in the
# script is either count-gated or default-guarded. The harness is explicit (a
# raw launch command skips template lookup) because harness *detection* walks
# the live process ancestry: under a harness-named parent it resolves and the
# home refusal follows, while on a bare CI runner it yields 'unknown' and its
# own refusal fires first. Depending on detection here would make this case
# pass on one machine and fail on another.
test_secondmate_without_home_reaches_its_own_refusal() {
  expect_refusal "secondmate without home" "no firstmate home supplied or registered" \
    run_spawn nope-secondmate-z6 --secondmate --harness 'sleep 60'
  pass "secondmate without a home reaches its own refusal, not a crash"
}

test_missing_project_dir
test_missing_task_id
test_scout_missing_project_dir
test_bare_project_name_is_not_a_path
test_unresolvable_path_is_refused_clearly
test_refused_spawn_leaves_no_state
test_secondmate_without_home_reaches_its_own_refusal
