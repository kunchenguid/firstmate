#!/usr/bin/env bash
# fm-orchestrator.sh: recurring watchdog that fires bin/fm-relaunch.sh run only
# when no session already holds the lock AND real pending work exists, then
# self-throttles. Every test runs against fake HOME/launchctl/id/uname and
# stub fm-lock.sh/fm-relaunch.sh/fm-backend.sh so it never touches the real
# machine's launchd namespace, session lock, or a real backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-orchestrator.sh"

assert_present "$BIN" "bin/fm-orchestrator.sh is missing"
[ -x "$BIN" ] || fail "bin/fm-orchestrator.sh must be executable"

# fm_orch_case <name> <lock-output> -> sets up a fake HOME/FM_HOME/fakebin
# world with a stub fm-lock.sh that always prints <lock-output>, and echoes
# "<dir>\t<fm_home>\t<home>\t<fakebin>".
fm_orch_case() {
  local name=$1 lock_out=$2 dir fakebin home fm_home
  dir=$(fm_test_tmproot "fm-orch-$name")
  fakebin="$dir/fakebin"
  home="$dir/home"
  fm_home="$dir/fmhome"
  mkdir -p "$fakebin" "$home/Library/LaunchAgents" "$fm_home/state" "$fm_home/data"

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Darwin
SH

  cat > "$fakebin/id" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 501
SH

  cat > "$fakebin/launchctl" <<SH
#!/usr/bin/env bash
LOADED_DIR="\${FM_ORCH_TEST_LOADED_DIR:?}"
mkdir -p "\$LOADED_DIR"
case "\$1" in
  bootstrap)
    label=\$(awk '/<key>Label<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' "\$3")
    : > "\$LOADED_DIR/\$label"
    exit 0
    ;;
  bootout)
    label=\${2##*/}
    rm -f -- "\$LOADED_DIR/\$label"
    exit 0
    ;;
  print)
    label=\${2##*/}
    [ -f "\$LOADED_DIR/\$label" ] && exit 0
    exit 1
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/id" "$fakebin/launchctl"

  cat > "$dir/fm-lock.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$lock_out"
SH
  chmod +x "$dir/fm-lock.sh"

  cat > "$dir/fm-relaunch.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "relaunch-\$1" >> "\${FM_ORCH_TEST_FIRE_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$dir/fm-relaunch.sh"

  printf '%s\t%s\t%s\t%s\n' "$dir" "$fm_home" "$home" "$fakebin"
}

# fm_orch_run <dir> <fm_home> <home> <fakebin> <args...>
fm_orch_run() {
  local dir=$1 fm_home=$2 home=$3 fakebin=$4
  shift 4
  FM_ORCH_TEST_LOADED_DIR="$dir/loaded" \
    FM_ORCH_TEST_FIRE_LOG="$dir/fire.log" \
    FM_ORCHESTRATOR_LOCK_BIN="$dir/fm-lock.sh" \
    FM_ORCHESTRATOR_RELAUNCH_BIN="$dir/fm-relaunch.sh" \
    FM_ORCHESTRATOR_BACKEND_SH="$dir/no-such-fm-backend.sh" \
    FM_ORCHESTRATOR_COOLDOWN_SECS="${FM_ORCH_TEST_COOLDOWN:-1800}" \
    FM_ROOT_OVERRIDE="$fm_home" FM_HOME="$fm_home" HOME="$home" PATH="$fakebin:$PATH" \
    "$BIN" "$@"
}

test_help_lists_subcommands() {
  local out
  out=$(FM_HOME=/nonexistent "$BIN" --help)
  assert_contains "$out" "install" "help must list install"
  assert_contains "$out" "status" "help must list status"
  assert_contains "$out" "uninstall" "help must list uninstall"
  assert_contains "$out" "check" "help must list check"
  pass "help lists install/status/uninstall/check"
}

test_unknown_subcommand_fails() {
  local rc=0
  FM_HOME=/nonexistent "$BIN" bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown subcommand must exit 2 (got $rc)"
  pass "unknown subcommand exits 2"
}

test_non_macos_fails_closed() {
  local case_out dir fm_home home fakebin rc=0
  case_out=$(fm_orch_case nonmac "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "install on a non-macOS platform must fail closed (got $rc)"
  pass "non-macOS platform fails closed"
}

test_install_declares_a_real_recurring_interval() {
  local case_out dir fm_home home fakebin plist
  case_out=$(fm_orch_case interval "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "install failed"
  plist="$home/Library/LaunchAgents/dev.firstmate.orchestrator.plist"
  assert_present "$plist" "install must write a plist at the default label path"
  assert_grep '<key>StartInterval</key>' "$plist" \
    "orchestrator plist MUST declare StartInterval - unlike fm-relaunch.sh, this tool is meant to self-schedule"
  pass "generated plist declares a real recurring StartInterval"
}

test_install_is_idempotent() {
  local case_out dir fm_home home fakebin plist sum1 sum2
  case_out=$(fm_orch_case idempotent "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  plist="$home/Library/LaunchAgents/dev.firstmate.orchestrator.plist"
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null || fail "first install failed"
  sum1=$(cksum < "$plist")
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null || fail "second install failed"
  sum2=$(cksum < "$plist")
  [ "$sum1" = "$sum2" ] || fail "repeated install must converge to the same plist bytes"
  pass "install run twice converges safely"
}

test_uninstall_removes_plist_and_unloads() {
  local case_out dir fm_home home fakebin plist
  case_out=$(fm_orch_case uninstall "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  plist="$home/Library/LaunchAgents/dev.firstmate.orchestrator.plist"
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null || fail "install failed"
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" uninstall >/dev/null || fail "uninstall failed"
  assert_absent "$plist" "uninstall must remove the plist"
  [ ! -f "$dir/loaded/dev.firstmate.orchestrator" ] || fail "uninstall must unload the job"
  pass "uninstall unloads and removes the plist cleanly"
}

test_status_before_install_reports_not_installed() {
  local case_out dir fm_home home fakebin rc=0
  case_out=$(fm_orch_case statusmissing "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" status >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "status must fail when nothing is installed"
  pass "status reports failure when not yet installed"
}

test_check_does_nothing_when_session_already_alive() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case alivesession "lock: held by live harness pid 123")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  # Plenty of pending work present - must still not fire, because a session is alive.
  printf '1\tsig\tk\tv\n' > "$fm_home/state/.wake-queue"
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "session already alive" "check must report the live-session short-circuit"
  [ ! -f "$dir/fire.log" ] || fail "check must never fire fm-relaunch.sh when a session is already alive"
  pass "check never fires a second session when one is already alive"
}

test_check_does_nothing_when_nothing_pending() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case idle "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  # No wake queue, no meta files, no backlog file at all: nothing pending.
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "no pending work" "check must report the no-pending-work short-circuit"
  [ ! -f "$dir/fire.log" ] || fail "check must never fire when an idle fleet has nothing pending"
  pass "check never fires on an idle, fully-caught-up fleet"
}

test_check_fires_on_nonempty_wake_queue() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case wakequeue "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  printf '1\tsig\tk\tv\n' > "$fm_home/state/.wake-queue"
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "fired session resume" "check must report firing"
  assert_grep 'relaunch-run' "$dir/fire.log" "check must invoke fm-relaunch.sh run"
  pass "check fires fm-relaunch.sh run on a non-empty wake queue"
}

test_check_fires_on_queued_backlog_item() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case backlogqueued "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  cat > "$fm_home/data/backlog.md" <<'MD'
# Backlog

## Queued
- some-task: do the thing

## Done
- old-task: finished already
MD
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "fired session resume" "check must report firing"
  pass "check fires on a queued backlog item with no blocker"
}

test_check_skips_blocked_backlog_item() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case backlogblocked "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  cat > "$fm_home/data/backlog.md" <<'MD'
# Backlog

## Queued
- some-task: do the thing [blocked-by:other-task]
MD
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "no pending work" "a fully blocked queued item must not count as pending work"
  pass "check does not fire on a queued backlog item whose blocker has not cleared"
}

test_check_fires_on_stalled_task_with_dead_backend() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case stalledtask "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  cat > "$fm_home/state/some-id.meta" <<'META'
window=win1
worktree=/tmp/wt
project=demo
harness=claude
model=
effort=
kind=ship
mode=no-mistakes
yolo=false
backend=tmux
META
  cat > "$dir/no-such-fm-backend.sh" <<'SH'
fm_backend_agent_alive() { printf 'dead'; }
SH
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "fired session resume" "check must report firing"
  pass "check fires when an in-flight task's backend endpoint is not alive"
}

test_check_ignores_task_with_terminal_status() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_orch_case terminaltask "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  cat > "$fm_home/state/some-id.meta" <<'META'
window=win1
kind=ship
backend=tmux
META
  printf 'working: doing stuff\ndone: shipped\n' > "$fm_home/state/some-id.status"
  cat > "$dir/no-such-fm-backend.sh" <<'SH'
fm_backend_agent_alive() { printf 'dead'; }
SH
  out=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) || fail "check must exit 0"
  assert_contains "$out" "no pending work" "a task already reported done must not count as a stall even with a dead endpoint"
  pass "check does not treat a terminal (done/failed) task as a stall"
}

test_check_cooldown_throttles_repeated_fires() {
  local case_out dir fm_home home fakebin out1 out2
  case_out=$(fm_orch_case cooldown "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  printf '1\tsig\tk\tv\n' > "$fm_home/state/.wake-queue"
  FM_ORCH_TEST_COOLDOWN=1800 out1=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) \
    || fail "first check must exit 0"
  assert_contains "$out1" "fired session resume" "first check must fire"
  FM_ORCH_TEST_COOLDOWN=1800 out2=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) \
    || fail "second check must exit 0"
  assert_contains "$out2" "cooldown active" "a second check inside the cooldown window must not fire again"
  [ "$(grep -c 'relaunch-run' "$dir/fire.log")" -eq 1 ] \
    || fail "fm-relaunch.sh run must be invoked exactly once across both checks"
  pass "cooldown throttles a second fire within the cooldown window"
}

test_check_fires_again_after_cooldown_elapses() {
  local case_out dir fm_home home fakebin out1 out2
  case_out=$(fm_orch_case cooldownelapsed "lock: free")
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  printf '1\tsig\tk\tv\n' > "$fm_home/state/.wake-queue"
  FM_ORCH_TEST_COOLDOWN=1 out1=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) \
    || fail "first check must exit 0"
  assert_contains "$out1" "fired session resume" "first check must fire"
  sleep 2
  FM_ORCH_TEST_COOLDOWN=1 out2=$(fm_orch_run "$dir" "$fm_home" "$home" "$fakebin" check) \
    || fail "second check must exit 0"
  assert_contains "$out2" "fired session resume" "check must fire again once the cooldown window elapses"
  [ "$(grep -c 'relaunch-run' "$dir/fire.log")" -eq 2 ] \
    || fail "fm-relaunch.sh run must be invoked twice once cooldown elapsed"
  pass "check fires again once the cooldown window has elapsed"
}

test_help_lists_subcommands
test_unknown_subcommand_fails
test_non_macos_fails_closed
test_install_declares_a_real_recurring_interval
test_install_is_idempotent
test_uninstall_removes_plist_and_unloads
test_status_before_install_reports_not_installed
test_check_does_nothing_when_session_already_alive
test_check_does_nothing_when_nothing_pending
test_check_fires_on_nonempty_wake_queue
test_check_fires_on_queued_backlog_item
test_check_skips_blocked_backlog_item
test_check_fires_on_stalled_task_with_dead_backend
test_check_ignores_task_with_terminal_status
test_check_cooldown_throttles_repeated_fires
test_check_fires_again_after_cooldown_elapses
