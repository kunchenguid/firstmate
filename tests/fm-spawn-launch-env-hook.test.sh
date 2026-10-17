#!/usr/bin/env bash
# tests/fm-spawn-launch-env-hook.test.sh - config/launch-env-hook adds
# environment to a launch before the AI-trailer step.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received, with the harness binary replaced by a probe that
# prints the GIT_CONFIG_* entries it was started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-env-hook)

# make_case <name> <id>: sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  fm_test_spawn_brief "$HOME_DIR" "$2"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
n=${GIT_CONFIG_COUNT:-0}
eval "last=\${GIT_CONFIG_KEY_$((n - 1))-none}"
printf '%s %s %s\n' "$n" "${GIT_CONFIG_KEY_0-none}" "$last"
SH
  chmod +x "$FAKEBIN_DIR/codex"
}

# write_hook <exit-code>: a hook that appends probe.key after the inherited entries.
write_hook() {
  cat > "$HOME_DIR/config/launch-env-hook" <<SH
#!/bin/sh
c=\${GIT_CONFIG_COUNT:-0}
printf 'export GIT_CONFIG_KEY_%s=probe.key GIT_CONFIG_VALUE_%s=1 GIT_CONFIG_COUNT=%s\n' "\$c" "\$c" "\$((c + 1))" > "\$1"
exit $1
SH
  chmod +x "$HOME_DIR/config/launch-env-hook"
}

SPAWN_OUT='' # the spawn's merged output, set by spawn_and_run for warning assertions

spawn_and_run() {  # <id>; prints the probe output, returns the launch status
  local out status
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$1" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  SPAWN_OUT=$out
  expect_code 0 "$status" "spawn $1 should succeed: $out"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(grep '^export ' "$PANE_LOG")
$(cat "$LAUNCH_LOG")" 2>/dev/null
}

test_absent_hook_changes_nothing() {
  local seen
  make_case absent absent-a1
  seen=$(spawn_and_run absent-a1) || fail "absent hook: the launch failed: $seen"
  assert_equals "1 core.hooksPath core.hooksPath" "$seen" "an absent hook leaves only the trailer entry"
  pass "an absent launch-env hook changes nothing"
}

test_hook_entries_precede_the_trailer_entry() {
  local setting seen
  for setting in absent enabled; do
    make_case "hook-$setting" "hook-$setting-a1"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    write_hook 0
    seen=$(spawn_and_run "hook-$setting-a1") || fail "allowlist=$setting: the launch failed: $seen"
    assert_equals "2 probe.key core.hooksPath" "$seen" \
      "allowlist=$setting: the hook's entry comes first and the trailer hooks dir is appended after it"
  done
  pass "the launch-env hook's export reaches the worker ahead of the trailer entry in both allowlist postures"
}

test_hook_without_trailer_strip() {
  local seen
  make_case keep keep-a1
  touch "$HOME_DIR/config/keep-ai-trailers"
  write_hook 0
  seen=$(spawn_and_run keep-a1) || fail "keep-ai-trailers: the launch failed: $seen"
  assert_equals "1 probe.key probe.key" "$seen" "with trailers kept, the hook's entry is the only one"
  pass "the launch-env hook runs when the home keeps AI trailers"
}

test_failing_hook_stops_the_launch() {
  local seen status
  make_case fail fail-a1
  write_hook 3
  seen=$(spawn_and_run fail-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a failing hook must stop the launch, got status 0"
  assert_equals "" "$seen" "a failing hook must stop the launch before the worker starts"
  pass "a failing launch-env hook stops the launch before the worker runs"
}

test_nonexecutable_hook_warns_and_launch_proceeds() {
  local seen
  make_case noexec noexec-a1
  write_hook 0
  chmod -x "$HOME_DIR/config/launch-env-hook"
  spawn_and_run noexec-a1 >"$TMP_ROOT/noexec-probe.out" || fail "non-executable hook: the launch failed: $SPAWN_OUT"
  printf '%s\n' "$SPAWN_OUT" | grep -q "warning: config/launch-env-hook exists but is not executable" \
    || fail "a present non-executable hook must print a warning naming the file: $SPAWN_OUT"
  seen=$(cat "$TMP_ROOT/noexec-probe.out")
  assert_equals "1 core.hooksPath core.hooksPath" "$seen" "a non-executable hook leaves only the trailer entry"
  pass "a present non-executable launch-env hook warns and the launch proceeds without it"
}

test_absent_hook_changes_nothing
test_hook_entries_precede_the_trailer_entry
test_hook_without_trailer_strip
test_failing_hook_stops_the_launch
test_nonexecutable_hook_warns_and_launch_proceeds
