#!/usr/bin/env bash
# tests/fm-spawn-shell-history-ignorespace.test.sh - config/shell-history-ignorespace
# makes spawn prefix every line it types into the pane shell with a space, so
# ignorespace-aware history (zsh, bash, atuin) skips them; without the file the
# lines are sent unchanged.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-shell-history-ignorespace)

# run_spawn <name> <flag:0|1> - leaves the pane and launch logs in $TMP_ROOT/<name>.
run_spawn() {
  local name=$1 flag=$2 case_dir home proj wt fakebin out
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-a1"
  [ "$flag" = 0 ] || : > "$home/config/shell-history-ignorespace"
  : > "$case_dir/pane.log"
  : > "$case_dir/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$name-a1" "$proj" --mode no-mistakes --yolo off) \
    || fail "$name: spawn should succeed: $out"
  [ -s "$case_dir/pane.log" ] || fail "$name: spawn typed no pane setup lines"
  [ -s "$case_dir/launch.log" ] || fail "$name: spawn typed no launch line"
}

test_flag_on() {
  run_spawn on 1
  ! grep -q '^[^ ]' "$TMP_ROOT/on/pane.log" \
    || fail "every pane setup line should start with a space:"$'\n'"$(cat "$TMP_ROOT/on/pane.log")"
  grep -q "^ \. '" "$TMP_ROOT/on/launch.log" \
    || fail "the launch source line should start with a space:"$'\n'"$(cat "$TMP_ROOT/on/launch.log")"
  pass "shell-history-ignorespace prefixes pane setup and launch lines with a space"
}

test_flag_off() {
  run_spawn off 0
  ! grep -q '^ ' "$TMP_ROOT/off/pane.log" \
    || fail "without the flag no pane line should gain a space:"$'\n'"$(cat "$TMP_ROOT/off/pane.log")"
  grep -q '^export GOTMPDIR=' "$TMP_ROOT/off/pane.log" \
    || fail "without the flag the GOTMPDIR export should be sent unchanged"
  pass "without shell-history-ignorespace pane lines are sent unchanged"
}

test_flag_on
test_flag_off
