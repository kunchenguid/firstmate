#!/usr/bin/env bash
# tests/fm-sandbox-spawn.test.sh - launch-boundary coverage for the opt-in
# worker command sandbox (bin/fm-spawn.sh + bin/fm-sandbox.sh).
#
# Drives the real spawn against a fake pane and a real isolated git worktree,
# with a canned `srt` on PATH: the absent flag leaves the launch unchanged, the
# flag wraps the launch in the pinned runtime, and an unusable runtime refuses
# the spawn instead of launching unsandboxed. It also proves cleanup is not
# routed through the sandbox, so an enabled sandbox never changes what cleanup
# does to the task's worktree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-sandbox-spawn)

# make_case <name> <id> -> echoes
# "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>"
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {  # [fm-spawn args...] using the globals from read_case
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

enable_sandbox() {  # <home>
  mkdir -p "$1/config"
  : > "$1/config/worker-sandbox"
  printf '%s\n' \
    '{"filesystem":{"denyRead":[],"allowRead":[],"allowWrite":["."],"denyWrite":[]},"network":{"allowedDomains":[],"deniedDomains":[]}}' \
    > "$1/config/worker-sandbox-settings.json"
}

run_teardown() {  # <home> <fakebin> <id>
  local home=$1 fakebin=$2 id=$3
  mkdir -p "$home/user-home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" TMUX="${TMUX:-fake,1,0}" \
    "$TEARDOWN" "$id" 2>&1
}

test_absent_flag_leaves_the_launch_unchanged() {
  local rec out status launch
  rec=$(make_case off sp-off)
  read_case "$rec"
  out=$(run_spawn sp-off "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn without the sandbox flag should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--settings" "an absent flag must not add a sandbox prefix"
  pass "spawn without config/worker-sandbox: the launch command is unchanged"
}

test_enabled_flag_wraps_the_launch_in_the_pinned_runtime() {
  local rec out status launch
  rec=$(make_case on sp-on)
  read_case "$rec"
  enable_sandbox "$HOME_DIR"
  fm_test_fake_srt "$FAKEBIN_DIR"
  out=$(run_spawn sp-on "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn under an enabled sandbox should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$FAKEBIN_DIR/srt" \
    "an enabled sandbox must launch the agent through the pinned runtime"
  assert_contains "$launch" "$HOME_DIR/config/worker-sandbox-settings.json" \
    "an enabled sandbox must pass the home's settings to the runtime"
  assert_contains "$launch" " -c " "an enabled sandbox must use the runtime's command-string form"
  pass "spawn with config/worker-sandbox: the launch runs through the pinned runtime"
}

test_unusable_runtime_refuses_before_launching() {
  local rec out status before after
  rec=$(make_case failclosed sp-fc)
  read_case "$rec"
  enable_sandbox "$HOME_DIR"
  before=$(git -C "$PROJ_DIR" worktree list --porcelain)
  out=$(FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" FM_SANDBOX_SRT_BIN="$CASE_DIR/no-such-srt" run_spawn sp-fc "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn under an enabled sandbox with no runtime must refuse, got: $out"
  assert_contains "$out" "not an executable file" "the refusal must name the unusable runtime"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused sandboxed spawn must not stage or send a launch command"
  after=$(git -C "$PROJ_DIR" worktree list --porcelain)
  assert_equals "$before" "$after" "sandbox refusal must not create a worktree"
  assert_absent "$HOME_DIR/state/sp-fc.meta" "sandbox refusal must not publish a task record"
  assert_absent "$HOME_DIR/state/sp-fc.inbox" "sandbox refusal must not arm task wiring"
  assert_absent "$CASE_DIR/tmux.log" "sandbox refusal must precede endpoint operations"
  pass "spawn with config/worker-sandbox and no runtime: refused before any launch"
}

test_cleanup_never_routes_through_the_sandbox() {
  local rec rec2 out_off out_on status_off status_on srtlog
  rec=$(make_case cleanup-off sp-co)
  read_case "$rec"
  out_off=$(run_spawn sp-co "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "the flag-off fixture should spawn: $out_off"
  status_off=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" sp-co)
  local rc_off=$?
  read_case "$rec"

  rec2=$(make_case cleanup-on sp-con)
  read_case "$rec2"
  enable_sandbox "$HOME_DIR"
  fm_test_fake_srt "$FAKEBIN_DIR"
  srtlog="$CASE_DIR/srt.log"
  out_on=$(FM_FAKE_SRT_LOG="$srtlog" run_spawn sp-con "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "the flag-on fixture should spawn: $out_on"
  assert_present "$srtlog" "the flag-on spawn should have invoked the runtime"
  : > "$srtlog"
  status_on=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" sp-con)
  local rc_on=$?
  [ "$rc_off" = "$rc_on" ] ||
    fail "cleanup must behave identically with the sandbox on and off (off rc=$rc_off, on rc=$rc_on)"$'\n'"off: $status_off"$'\n'"on: $status_on"
  [ ! -s "$srtlog" ] || fail "cleanup must not invoke the sandbox runtime"
  pass "cleanup with the sandbox enabled: identical result, and no runtime invocation"
}

test_absent_flag_leaves_the_launch_unchanged
test_enabled_flag_wraps_the_launch_in_the_pinned_runtime
test_unusable_runtime_refuses_before_launching
test_cleanup_never_routes_through_the_sandbox
