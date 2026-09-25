#!/usr/bin/env bash
# tests/fm-spawn-treehouse-root.test.sh - a secondmate home's Treehouse pool
# root must be its own, not the primary's.
#
# Treehouse pools a project by its origin URL under one machine-wide root
# (TREEHOUSE_ROOT, or its own default when unset), so two homes cloning the
# same origin land in the same pool and `treehouse get` hands back a worktree
# bound to whichever clone created it first. bin/fm-spawn.sh must export a
# distinct TREEHOUSE_ROOT into the pane before sending `treehouse get` for a
# secondmate home, and leave a primary home's pane untouched, and it must record
# the root it leased from in the task record fm-teardown.sh reads back. This
# drives the real spawn against a fake pane and asserts the pane-export log
# (tests/fixtures.sh's FM_FAKE_PANE_LOG) and the published state/<id>.meta,
# never the source of fm-spawn.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-root)

# make_case <name> <id>...
# Echoes "<home>|<project>|<worktree>|<fakebin>|<pane-log>".
make_case() {
  local name=$1 case_dir home proj wt fakebin panelog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin|$panelog"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$PANE_LOG"
  FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

treehouse_root_export_lines() {
  grep -c '^export TREEHOUSE_ROOT=' "$1" || true
}

# The treehouse_root= this spawn recorded in its own task record, which is what
# bin/fm-teardown.sh reads back to return the slot to the pool it was leased
# from. Empty means the record carries no override: the default pool.
recorded_treehouse_root() {  # <id>
  sed -n 's/^treehouse_root=//p' "$HOME_DIR/state/$1.meta"
}

test_primary_home_gets_no_override() {
  local rec out status
  rec=$(make_case primary primary-a1)
  read_case "$rec"
  out=$(run_case_spawn primary-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "primary-home spawn should succeed: $out"
  [ "$(treehouse_root_export_lines "$PANE_LOG")" = 0 ] \
    || fail "a primary home's pane should never receive a TREEHOUSE_ROOT export, got $(treehouse_root_export_lines "$PANE_LOG")"
  grep -qx 'treehouse get' "$PANE_LOG" \
    || fail "primary-home spawn should still send the bare treehouse get"
  assert_equals "" "$(recorded_treehouse_root primary-a1)" \
    "a primary home's task record should carry no Treehouse pool root override"
  pass "a primary home's spawn leaves the pane's Treehouse pool root at the default"
}

test_secondmate_home_gets_its_own_root() {
  local rec out status exported expected_root export_line get_line
  rec=$(make_case secondmate secondmate-a1)
  read_case "$rec"
  printf '%s\n' secondmate-a1-home > "$HOME_DIR/.fm-secondmate-home"
  out=$(run_case_spawn secondmate-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "secondmate-home spawn should succeed: $out"
  [ "$(treehouse_root_export_lines "$PANE_LOG")" = 1 ] \
    || fail "a secondmate home's pane should receive exactly one TREEHOUSE_ROOT export, got $(treehouse_root_export_lines "$PANE_LOG")"
  expected_root="export TREEHOUSE_ROOT='$HOME_DIR/state/treehouse-root'"
  exported=$(grep '^export TREEHOUSE_ROOT=' "$PANE_LOG")
  assert_equals "$expected_root" "$exported" \
    "a secondmate home's own state dir should own its Treehouse pool root"
  export_line=$(grep -n '^export TREEHOUSE_ROOT=' "$PANE_LOG" | cut -d: -f1)
  get_line=$(grep -nx 'treehouse get' "$PANE_LOG" | cut -d: -f1)
  [ -n "$export_line" ] && [ -n "$get_line" ] \
    || fail "the pane log is missing the export or the treehouse get line"
  [ "$export_line" -lt "$get_line" ] \
    || fail "the TREEHOUSE_ROOT export must reach the pane before treehouse get is sent (export=$export_line get=$get_line)"
  assert_equals "$HOME_DIR/state/treehouse-root" "$(recorded_treehouse_root secondmate-a1)" \
    "the leased pool root must be recorded in the task record for teardown to return the slot to it"
  pass "a secondmate home's spawn exports its own Treehouse pool root before treehouse get"
}

test_two_secondmate_homes_get_different_roots() {
  local rec_a rec_b root_a root_b
  rec_a=$(make_case secondmate-a sm-a-a1)
  read_case "$rec_a"
  printf '%s\n' sm-a > "$HOME_DIR/.fm-secondmate-home"
  run_case_spawn sm-a-a1 "$PROJ_DIR" --mode no-mistakes --yolo off >/dev/null
  root_a=$(grep '^export TREEHOUSE_ROOT=' "$PANE_LOG")

  rec_b=$(make_case secondmate-b sm-b-a1)
  read_case "$rec_b"
  printf '%s\n' sm-b > "$HOME_DIR/.fm-secondmate-home"
  run_case_spawn sm-b-a1 "$PROJ_DIR" --mode no-mistakes --yolo off >/dev/null
  root_b=$(grep '^export TREEHOUSE_ROOT=' "$PANE_LOG")

  [ -n "$root_a" ] && [ -n "$root_b" ] || fail "both secondmate homes should export a Treehouse pool root"
  [ "$root_a" != "$root_b" ] \
    || fail "two distinct secondmate homes must not share a Treehouse pool root: $root_a"
  pass "distinct secondmate homes get distinct Treehouse pool roots"
}

test_primary_home_gets_no_override
test_secondmate_home_gets_its_own_root
test_two_secondmate_homes_get_different_roots
