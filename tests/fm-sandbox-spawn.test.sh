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

test_filtering_preserves_runtime_transport_environment() {
  local setting rec out status launch result expected
  for setting in absent empty; do
    rec=$(make_case "transport-$setting" "sp-transport-$setting")
    read_case "$rec"
    enable_sandbox "$HOME_DIR"
    [ "$setting" != empty ] || : > "$HOME_DIR/config/launch-env-allowlist"
    fm_test_fake_srt "$FAKEBIN_DIR"
    mv "$FAKEBIN_DIR/srt" "$FAKEBIN_DIR/srt-inner"
    cat > "$FAKEBIN_DIR/srt" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${FM_TEST_AMBIENT-unset}" > '$CASE_DIR/runtime-env'
export HTTP_PROXY=http://sandbox-proxy.invalid:8888
export HTTPS_PROXY=http://sandbox-proxy.invalid:8888
export ALL_PROXY=socks5://sandbox-proxy.invalid:8889
exec '$FAKEBIN_DIR/srt-inner' "\$@"
SH
    chmod +x "$FAKEBIN_DIR/srt"
    cat > "$CASE_DIR/probe.sh" <<'SH'
#!/bin/sh
printf '%s\n' "${HTTP_PROXY-unset}" "${HTTPS_PROXY-unset}" "${ALL_PROXY-unset}" "${FM_TEST_AMBIENT-unset}"
SH
    out=$(run_spawn "sp-transport-$setting" "$PROJ_DIR" --mode no-mistakes --yolo off --harness "/bin/sh '$CASE_DIR/probe.sh'")
    status=$?
    expect_code 0 "$status" "sandbox transport fixture must spawn: $out"
    launch=$(cat "$LAUNCH_LOG")
    result=$(env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:/usr/bin:/bin" FM_TEST_AMBIENT=synthetic /bin/sh -c "$launch") ||
      fail "the emitted sandbox transport launch must execute"
    expected=synthetic
    [ "$setting" != empty ] || expected='unset'
    assert_equals "$expected" "$(cat "$CASE_DIR/runtime-env")" "filtering must happen before entering the runtime"
    assert_equals "$(printf '%s\n' http://sandbox-proxy.invalid:8888 http://sandbox-proxy.invalid:8888 socks5://sandbox-proxy.invalid:8889 "$expected")" \
      "$result" "runtime transport must survive while ambient values follow the allowlist"
  done
  pass "environment filtering precedes sandboxing and preserves generated transport variables"
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

assert_inherited_sandbox() {  # <primary> <secondmate> <srt>
  local primary=$1 second=$2 srt=$3 out
  cmp -s "$primary/config/worker-sandbox" "$second/config/worker-sandbox" ||
    fail "secondmate did not inherit the sandbox flag bytes"
  cmp -s "$primary/config/worker-sandbox-settings.json" "$second/config/worker-sandbox-settings.json" ||
    fail "secondmate did not inherit the sandbox settings bytes"
  out=$(FM_CONFIG_OVERRIDE='' FM_SANDBOX_SETTINGS='' FM_HOME="$second" \
    FM_SANDBOX_SRT_BIN="$srt" "$ROOT/bin/fm-sandbox.sh" prefix) ||
    fail "secondmate could not resolve its inherited sandbox: $out"
  assert_contains "$out" "$second/config/worker-sandbox-settings.json" \
    "secondmate must resolve settings from its own home"
}

test_secondmate_sandbox_inheritance() {
  local rec second out
  rec=$(make_case inheritance sp-inherit)
  read_case "$rec"
  second="$CASE_DIR/second"
  # Provision a project-less home, then exercise the launch convergence that
  # publishes inherited local material into the newly provisioned home.
  fm_git_init_commit "$second"
  printf 'config/\ndata/\nstate/\nprojects/\n.fm-secondmate-*\n' > "$second/.gitignore"
  mkdir -p "$second/bin"
  cp "$ROOT/AGENTS.md" "$second/AGENTS.md"
  rm "$HOME_DIR/data/sp-inherit/brief.md"
  enable_sandbox "$HOME_DIR"
  fm_test_fake_srt "$FAKEBIN_DIR"
  out=$(FM_HOME="$HOME_DIR" FM_SECONDMATE_CHARTER='Sandbox inheritance fixture.' \
    "$ROOT/bin/fm-home-seed.sh" sp-inherit "$second" --no-projects 2>&1) ||
    fail "secondmate provisioning failed: $out"
  out=$(run_spawn sp-inherit "$second" --secondmate --backend tmux) ||
    fail "provisioned secondmate launch failed: $out"
  assert_inherited_sandbox "$HOME_DIR" "$second" "$FAKEBIN_DIR/srt"

  # A normal primary edit replaces an untouched inherited generation. The
  # same config-push also replaces a locally edited destination, by contract.
  printf 'enabled-v2\n' > "$HOME_DIR/config/worker-sandbox"
  printf '\n' >> "$HOME_DIR/config/worker-sandbox-settings.json"
  printf 'local edit\n' > "$second/config/worker-sandbox"
  out=$(FM_HOME="$HOME_DIR" FM_BACKEND=tmux PATH="$FAKEBIN_DIR:$PATH" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1) ||
    fail "mid-session sandbox propagation failed: $out"
  assert_inherited_sandbox "$HOME_DIR" "$second" "$FAKEBIN_DIR/srt"
  assert_contains "$out" 'worker-sandbox-settings.json: pushed' "settings update must be reported"
  out=$(FM_HOME="$HOME_DIR" FM_BACKEND=tmux PATH="$FAKEBIN_DIR:$PATH" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1) || fail "repeat propagation failed: $out"
  assert_contains "$out" 'worker-sandbox: unchanged' "repeat push must be idempotent"
  printf 'enabled-v3\n' > "$HOME_DIR/config/worker-sandbox"
  printf '\n' >> "$HOME_DIR/config/worker-sandbox-settings.json"
  fm_fake_exit0 "$FAKEBIN_DIR" gh
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJ_DIR" FM_BACKEND=tmux \
    FM_BOOTSTRAP_NETWORK=only PATH="$FAKEBIN_DIR:$PATH" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || fail "bootstrap sync failed: $out"
  assert_inherited_sandbox "$HOME_DIR" "$second" "$FAKEBIN_DIR/srt"
  rm "$HOME_DIR/config/worker-sandbox" "$HOME_DIR/config/worker-sandbox-settings.json"
  out=$(FM_HOME="$HOME_DIR" FM_BACKEND=tmux PATH="$FAKEBIN_DIR:$PATH" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1) || fail "absent-file propagation failed: $out"
  assert_absent "$second/config/worker-sandbox" "primary absence must remove the inherited flag"
  assert_absent "$second/config/worker-sandbox-settings.json" "primary absence must remove inherited settings"
  out=$(FM_HOME="$second" FM_CONFIG_OVERRIDE='' "$ROOT/bin/fm-sandbox.sh" prefix) || fail "disabled secondmate prefix failed"
  assert_equals '' "$out" "secondmate must resolve absent sandbox as disabled"
  pass "provisioned secondmate inherits sandbox on launch, bootstrap sync and config-push, including updates and absence"
}

test_remote_secondmate_sandbox_inheritance() {
  local rec second generation out
  rec=$(make_case remote-inheritance sp-remote)
  read_case "$rec"
  second="$CASE_DIR/remote-second"
  mkdir -p "$second/config" "$second/state"
  printf -- '- sandbox-mate - fixture (host: sandbox-host; root: %s; home: %s; scope: fixture; projects: ; added 2026-10-02)\n' \
    "$ROOT" "$second" > "$HOME_DIR/data/secondmates.md"
  # Replace SSH transport only: decode the real sender's protocol and execute
  # the real receiver with an empty environment, as the remote worker does.
  cat > "$FAKEBIN_DIR/inherit-ssh" <<'SH'
#!/usr/bin/env python3
import base64
import os
import sys
args = sys.argv[1:]
while args[0] == '-o':
    args = args[2:]
assert args[:4] == ['--', 'sandbox-host', 'fm-remote-entrypoint.sh', '1']
root, home = [base64.b64decode(x).decode() for x in args[4:6]]
command = [x.decode() for x in base64.b64decode(args[6]).split(b'\0')[:-1]]
assert command[0] == 'fm-remote-inherit.sh'
os.execve(root + '/bin/' + command[0], command,
          {'PATH': os.environ['PATH'], 'FM_HOME': home, 'FM_STATE_OVERRIDE': home + '/state'})
SH
  chmod +x "$FAKEBIN_DIR/inherit-ssh"
  fm_test_fake_srt "$FAKEBIN_DIR"
  for generation in 1 2 3 4; do
    case "$generation" in
      1) enable_sandbox "$HOME_DIR" ;;
      2) printf 'enabled-v2\n' > "$HOME_DIR/config/worker-sandbox"
         printf '\n' >> "$HOME_DIR/config/worker-sandbox-settings.json" ;;
      4) rm "$HOME_DIR/config/worker-sandbox" "$HOME_DIR/config/worker-sandbox-settings.json" ;;
    esac
    out=$(FM_HOME="$HOME_DIR" FM_CONFIG_INHERIT_LIVE=1 \
      FM_SSH_BIN="$FAKEBIN_DIR/inherit-ssh" "$ROOT/bin/fm-remote-inherit-push.sh" sandbox-mate "$generation" 2>&1) ||
      fail "remote inheritance generation $generation failed: $out"
    if [ "$generation" -lt 4 ]; then
      assert_inherited_sandbox "$HOME_DIR" "$second" "$FAKEBIN_DIR/srt"
    else
      assert_absent "$second/config/worker-sandbox" "remote primary absence must remove flag"
      assert_absent "$second/config/worker-sandbox-settings.json" "remote primary absence must remove settings"
    fi
    [ "$generation" != 3 ] || assert_contains "$out" 'unchanged: config/worker-sandbox-settings.json' "remote repeat must be idempotent"
  done
  pass "remote sender and receiver propagate sandbox files, updates and absence using the shared declaration"
}

test_secondmate_sandbox_inheritance
test_remote_secondmate_sandbox_inheritance
test_absent_flag_leaves_the_launch_unchanged
test_enabled_flag_wraps_the_launch_in_the_pinned_runtime
test_unusable_runtime_refuses_before_launching
test_filtering_preserves_runtime_transport_environment
test_cleanup_never_routes_through_the_sandbox
