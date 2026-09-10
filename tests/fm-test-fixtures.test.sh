#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_tmux_and_fakebin() {
  local fakebin out log
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  log="$TMP_ROOT/spawn/launch.log"
  : > "$log"
  out=$(FM_FAKE_PANE_PATH=/tmp/wt "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ "$out" = /tmp/wt ] || fail "spawn tmux pane path should be FM_FAKE_PANE_PATH, got '$out'"
  out=$(unset FM_FAKE_PANE_PATH; "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ -z "$out" ] || fail "spawn tmux pane path should default to empty, got '$out'"
  out=$("$fakebin/tmux" display-message -p '#S')
  [ "$out" = firstmate ] || fail "spawn tmux session name should be firstmate, got '$out'"
  FM_FAKE_LAUNCH_LOG="$log" "$fakebin/tmux" send-keys -t @w -l 'codex --yolo'
  assert_grep 'codex --yolo' "$log" "send-keys -l payload was not logged"
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  pass "spawn fakebin answers pane path, logs -l payloads, and installs extra tools"
}

test_send_stubs_and_ssh() {
  local fakebin log ssh_log out
  fakebin=$(make_stubs "$TMP_ROOT/send")
  log="$TMP_ROOT/send/send.log"
  ssh_log="$TMP_ROOT/send/ssh.log"
  : > "$log"
  fm_test_fake_ssh "$fakebin"
  FM_SEND_LOG="$log" "$fakebin/tmux" send-keys -t sess:w -l 'hello steer'
  assert_grep 'hello steer' "$log" "send stubs did not log the -l payload"
  out=$("$fakebin/tmux" display-message -p '#{cursor_y}')
  [ "$out" = 1 ] || fail "send tmux cursor_y should be 1, got '$out'"
  out=$("$fakebin/tmux" capture-pane -p)
  case "$out" in
    *'╭────╮'*) ;;
    *) fail "send tmux capture-pane should render an empty composer, got '$out'" ;;
  esac
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs log typed text and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

test_touch_epoch_preserves_repeated_dst_hour
test_fake_gh_and_gh_axi
test_spawn_tmux_and_fakebin
test_send_stubs_and_ssh
test_spawn_home_layout
