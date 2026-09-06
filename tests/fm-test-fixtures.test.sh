#!/usr/bin/env bash
# Behavior tests for tests/fixtures.sh fake-toolchain and spawn-world builders.
#
# These cases drive the builders as a test would: they write stubs into a
# fakebin and exec those stubs. Assertions are on the binaries' observable
# output, exit status, and files they create - never on fixtures.sh source
# text. Migrated spawn suites cover fm_test_run_spawn through the real
# fm-spawn.sh; this file pins the stubs those suites now share.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "fake no-mistakes --version should default to the shared timestamped banner, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "banner override should round-trip, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  fm_test_fake_quota_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  out=$("$fakebin/quota-axi" --version)
  [ "$out" = "$FM_TEST_QUOTA_AXI_VERSION" ] || \
    fail "fake quota-axi --version should be $FM_TEST_QUOTA_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_QUOTA_AXI_VERSION=0.8.8 "$fakebin/quota-axi" --version)
  [ "$out" = 0.8.8 ] || fail "FM_FAKE_QUOTA_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates; fake gh-axi/quota-axi report the shared version"
}

test_fake_treehouse_and_tasks_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/caps")
  fm_test_fake_treehouse "$fakebin"
  out=$("$fakebin/treehouse" get --help)
  [ "$out" = 'Usage: treehouse get [--lease]' ] || \
    fail "default treehouse help should advertise the lease form, got '$out'"
  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$fakebin/treehouse" get --help)
  [ "$out" = 'Usage: treehouse get [--lease] [--lease-holder <holder>]' ] || \
    fail "FM_FAKE_TREEHOUSE_LEASE_HELP should switch the lease-holder form, got '$out'"
  out=$("$fakebin/treehouse" return --force /tmp/wt)
  expect_code 0 $? "fake treehouse other verbs should exit 0"
  fm_test_fake_treehouse "$fakebin" 'Usage: treehouse get'
  out=$("$fakebin/treehouse" get --help)
  [ "$out" = 'Usage: treehouse get' ] || \
    fail "a suite's non-lease default usage should be honored, got '$out'"
  fm_test_fake_tasks_axi "$fakebin"
  out=$("$fakebin/tasks-axi" --version)
  [ "$out" = "$FM_TEST_TASKS_AXI_VERSION" ] || \
    fail "fake tasks-axi --version should be $FM_TEST_TASKS_AXI_VERSION, got '$out'"
  out=$("$fakebin/tasks-axi" update --help)
  assert_contains "$out" '  --body-file <path>' "update help should advertise --body-file"
  assert_contains "$out" '  --archive-body' "update help should advertise --archive-body"
  out=$("$fakebin/tasks-axi" mv --help)
  assert_contains "$out" '[<id>...]' "mv help should advertise the multi-id form"
  fm_test_fake_tasks_axi "$fakebin" 9.9.9 no no
  out=$("$fakebin/tasks-axi" --version)
  [ "$out" = 9.9.9 ] || fail "version override should round-trip, got '$out'"
  out=$("$fakebin/tasks-axi" update --help)
  assert_not_contains "$out" '  --archive-body' "archive-body=no must drop the capability line"
  out=$("$fakebin/tasks-axi" mv --help)
  assert_not_contains "$out" '[<id>...]' "multi-id=no must drop the multi-id usage"
  "$fakebin/tasks-axi" hold t1
  expect_code 0 $? "fake tasks-axi other verbs should exit 0"
  pass "fake treehouse and tasks-axi answer the capability helps suites probe"
}

test_fake_uname_curl_hasher() {
  local fakebin out log rc
  fakebin=$(fm_fakebin "$TMP_ROOT/lint")
  fm_test_fake_uname "$fakebin"
  out=$("$fakebin/uname" -s)
  [ "$out" = Linux ] || fail "fake uname -s should default to Linux, got '$out'"
  out=$(FM_TEST_UNAME_M=arm64 "$fakebin/uname" -m)
  [ "$out" = arm64 ] || fail "FM_TEST_UNAME_M should override the machine, got '$out'"
  log="$TMP_ROOT/lint/curls"
  : > "$log"
  fm_test_fake_curl "$fakebin"
  CURL_COUNT="$log.count" CURL_URL_LOG="$log" "$fakebin/curl" -o "$TMP_ROOT/lint/dl" https://example.test/a
  expect_code 0 $? "fake curl should succeed by default"
  assert_grep 'https://example.test/a' "$log" "fake curl did not log its URL"
  [ "$(cat "$log.count")" = 1 ] || \
    fail "fake curl should have counted exactly 1 call, got '$(cat "$log.count")'"
  CURL_COUNT="$log.count" CURL_FAIL_UNTIL=2 "$fakebin/curl" -o "$TMP_ROOT/lint/dl" https://example.test/b; rc=$?
  expect_code 22 "$rc" "fake curl should fail while under CURL_FAIL_UNTIL"
  fm_test_fake_hasher "$fakebin" sha256sum
  out=$(SHA256_STUB_HASH=abc123 "$fakebin/sha256sum" "$log")
  case "$out" in 'abc123  '*) ;; *) fail "fake hasher should print <hash>  <file>, got '$out'" ;; esac
  fm_test_fake_hasher "$fakebin" shasum
  SHA256_STUB_HASH=abc123 "$fakebin/shasum" -a 256 "$log" >/dev/null
  expect_code 0 $? "fake shasum should accept -a 256"
  SHA256_STUB_HASH=abc123 "$fakebin/shasum" -a 1 "$log" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "fake shasum should refuse a non-256 algorithm"
  pass "fake uname/curl/hasher answer the installer suites' probes"
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

test_no_mistakes_version_constant
test_no_mistakes_init_doctor_markers
test_fake_gh_and_gh_axi
test_fake_treehouse_and_tasks_axi
test_fake_uname_curl_hasher
test_spawn_tmux_and_fakebin
test_send_stubs_and_ssh
test_spawn_home_layout
