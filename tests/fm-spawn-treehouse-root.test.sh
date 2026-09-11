#!/usr/bin/env bash
# Regression test for the treehouse pool root a ship/scout spawn acquires from
# (bin/fm-spawn.sh's SPAWN_TREEHOUSE_ROOT, docs/configuration.md "Treehouse pool
# root").
#
# Treehouse names a pool from the remote URL alone, so every clone of one
# project on a machine resolves to the SAME pool while that pool's worktrees stay
# linked to whichever clone created them. Two firstmate homes each holding a
# clone of one project therefore collide: the second home's spawn is handed a
# worktree of the FIRST home's clone, and bin/fm-claude-trust.sh refuses it
# because that worktree does not share the spawning project's git common dir.
# Scoping the pool per home is what resolves it; relaxing that fence is not.
#
# The assertions read the command the spawn actually sends to the pane, which is
# the observable interface: whether `--root` is carried, and which value won.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-root)

# make_case <name> builds a home, a project with one real worktree for the pane
# to settle in, and a fakebin. Echoes "<home>|<proj>|<wt>|<fakebin>|<log>".
make_case() {
  local name=$1 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  log="$case_dir/typed-commands.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$log"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG <<EOF
$1
EOF
}

# run_case <id> [env-assignments...] runs one spawn and echoes its output.
run_spawn() {
  local id=$1
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise the treehouse pool root for $id."
  FM_FAKE_CMD_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# The shipped default: no root configured anywhere sends a bare `treehouse get`,
# exactly as every existing home already gets. A home that never opted in must
# see no change at all.
test_absent_root_sends_a_bare_treehouse_get() {
  local rec id out status
  id=th-root-absent-a1
  rec=$(make_case absent); read_case "$rec"

  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "spawn should succeed with no root configured"$'\n'"$out"
  assert_grep 'treehouse get' "$LAUNCH_LOG" \
    "an unconfigured home did not send 'treehouse get' at all"
  assert_no_grep '--root' "$LAUNCH_LOG" \
    "an unconfigured home wrongly carried a --root"
  pass "no configured root sends a bare treehouse get"
}

# The opt-in: an absolute path in config/treehouse-root is carried onto the
# acquire, so the pool this home takes worktrees from is its own.
test_configured_root_is_carried_onto_the_acquire() {
  local rec id out status root
  id=th-root-configured-a2
  rec=$(make_case configured); read_case "$rec"
  root="$TMP_ROOT/configured/pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "spawn should succeed with a configured root"$'\n'"$out"
  assert_grep "treehouse get --root '$root'" "$LAUNCH_LOG" \
    "the configured pool root was not carried onto the acquire"
  pass "a configured root is carried onto treehouse get"
}

# FM_TREEHOUSE_ROOT wins over the file, so one spawn can be aimed at another
# pool without editing this home's configuration.
test_environment_root_wins_over_the_file() {
  local rec id out status file_root env_root
  id=th-root-env-wins-a3
  rec=$(make_case envwins); read_case "$rec"
  file_root="$TMP_ROOT/envwins/from-file"
  env_root="$TMP_ROOT/envwins/from-env"
  printf '%s\n' "$file_root" > "$HOME_DIR/config/treehouse-root"

  out=$(FM_TREEHOUSE_ROOT="$env_root" run_spawn "$id"); status=$?
  expect_code 0 "$status" "spawn should succeed with an environment root"$'\n'"$out"
  assert_grep "treehouse get --root '$env_root'" "$LAUNCH_LOG" \
    "FM_TREEHOUSE_ROOT did not win over config/treehouse-root"
  assert_no_grep "$file_root" "$LAUNCH_LOG" \
    "the file root was used even though the environment named one"
  pass "FM_TREEHOUSE_ROOT wins over config/treehouse-root"
}

# A relative value is refused rather than accepted: treehouse resolves a relative
# --root from the REPOSITORY root, so it would put the pool inside the project
# clone - a write into a project, and a pool every home that clones it shares.
test_relative_root_is_refused() {
  local rec id out status
  id=th-root-relative-a4
  rec=$(make_case relative); read_case "$rec"
  printf '%s\n' 'pool' > "$HOME_DIR/config/treehouse-root"

  out=$(run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a relative treehouse root was accepted"$'\n'"$out"
  assert_contains "$out" "must be an absolute path" \
    "the refusal did not name the absolute-path requirement"
  pass "a relative treehouse root is refused"
}

# A present file naming no root refuses rather than falling through to the
# default: an emptied file must not silently return this home to the shared pool
# it was configured to leave.
test_present_but_empty_root_is_refused() {
  local rec id out status
  id=th-root-empty-a5
  rec=$(make_case empty); read_case "$rec"
  printf '# only a comment\n\n' > "$HOME_DIR/config/treehouse-root"

  out=$(run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "an empty treehouse-root file silently fell back to the default pool"$'\n'"$out"
  assert_contains "$out" "names no root" \
    "the refusal did not say the file names no root"
  pass "a present but empty treehouse-root file is refused"
}

test_absent_root_sends_a_bare_treehouse_get
test_configured_root_is_carried_onto_the_acquire
test_environment_root_wins_over_the_file
test_relative_root_is_refused
test_present_but_empty_root_is_refused
