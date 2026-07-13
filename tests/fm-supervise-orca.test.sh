#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervise-orca-tests)
SUPERVISOR="$ROOT/bin/fm-supervise-orca.sh"

test_once_is_read_only_when_daemon_unreachable() {
  local case_dir fakebin log out status
  case_dir="$TMP_ROOT/once-read-only"
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/log"
  cat > "$fakebin/fmod" <<'SH'
#!/usr/bin/env bash
printf 'fmod %s\n' "$*" >> "$FM_TEST_LOG"
printf '{"daemon_reachable":false,"daemon_pong":{}}\n'
exit 0
SH
  chmod +x "$fakebin/fmod"
  cat > "$fakebin/pkill" <<'SH'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >> "$FM_TEST_LOG"
exit 0
SH
  chmod +x "$fakebin/pkill"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
printf 'setsid %s\n' "$*" >> "$FM_TEST_LOG"
exit 0
SH
  chmod +x "$fakebin/setsid"

  out=$(PATH="$fakebin:$PATH" FM_TEST_LOG="$log" FM_ORCA_FMOD="$fakebin/fmod" "$SUPERVISOR" once 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "once should fail when daemon is unreachable"
  [ -z "$out" ] || fail "once should stay quiet, got: $out"
  assert_contains "$(cat "$log")" "fmod info" "once should probe fmod info"
  assert_not_contains "$(cat "$log")" "pkill" "once should not reap processes"
  assert_not_contains "$(cat "$log")" "setsid" "once should not relaunch Orca"
  pass "fm-supervise-orca once: unreachable daemon is read-only"
}

test_status_pidfile_uses_active_fm_home() {
  local case_dir home fakebin out pid identity
  case_dir="$TMP_ROOT/status-fm-home"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state"
  bash -c 'exec -a "fm-supervise-orca.sh --follow" sleep 60' &
  pid=$!
  identity=$(ps -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//') || fail "could not read fake supervisor identity"
  printf '%s\n' "$pid" > "$home/state/.orca-supervisor.pid"
  printf '%s\n' "$identity" > "$home/state/.orca-supervisor.pid.identity"
  cat > "$fakebin/fmod" <<'SH'
#!/usr/bin/env bash
printf '{"daemon_reachable":true,"daemon_pong":{"pong":true}}\n'
exit 0
SH
  chmod +x "$fakebin/fmod"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fakebin/fmod" "$SUPERVISOR" status)
  kill "$pid" 2>/dev/null || true
  assert_contains "$out" "supervisor: live pid=$pid" "status should read pidfile from FM_HOME/state"
  assert_contains "$out" "daemon:     reachable" "status should report reachable daemon"
  pass "fm-supervise-orca status: pidfile is scoped by FM_HOME"
}

test_status_rejects_stale_reused_pidfile() {
  local case_dir home fakebin out
  case_dir="$TMP_ROOT/status-stale-pid"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.orca-supervisor.pid"
  printf 'old identity\n' > "$home/state/.orca-supervisor.pid.identity"
  cat > "$fakebin/fmod" <<'SH'
#!/usr/bin/env bash
printf '{"daemon_reachable":true,"daemon_pong":{"pong":true}}\n'
exit 0
SH
  chmod +x "$fakebin/fmod"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fakebin/fmod" "$SUPERVISOR" status)
  assert_contains "$out" "supervisor: not running" "status should reject a live pid with the wrong identity"
  assert_contains "$out" "daemon:     reachable" "status should still report daemon health"
  pass "fm-supervise-orca status: rejects stale reused pidfile"
}

test_reap_scopes_orca_ide_pkill_to_user() {
  assert_contains "$(sed -n '/reap_orca_user_procs()/,/^}/p' "$SUPERVISOR")" "pkill -TERM -u \"\$USER\" -x 'orca-ide'" "TERM pkill for orca-ide should be user-scoped"
  assert_contains "$(sed -n '/reap_orca_user_procs()/,/^}/p' "$SUPERVISOR")" "pkill -KILL -u \"\$USER\" -x 'orca-ide'" "KILL pkill for orca-ide should be user-scoped"
  pass "fm-supervise-orca reap: orca-ide pkill is scoped to current user"
}

test_reap_stale_state_honors_xdg_config_home() {
  local case_dir home xdg fakebin output status
  case_dir="$TMP_ROOT/reap-xdg-config-home"
  home="$case_dir/home"
  xdg="$case_dir/xdg"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/.config/orca/daemon" "$xdg/orca/daemon"
  printf 'runtime\n' > "$xdg/orca/orca-runtime.json"
  printf 'lock\n' > "$xdg/orca/single-instance.lock"
  printf 'sock\n' > "$xdg/orca/daemon/daemon-v21.sock"
  printf 'pid\n' > "$xdg/orca/daemon/daemon-v21.pid"
  printf 'token\n' > "$xdg/orca/daemon/daemon-v21.token"
  printf 'home-runtime\n' > "$home/.config/orca/orca-runtime.json"
  printf 'home-lock\n' > "$home/.config/orca/single-instance.lock"
  printf 'home-sock\n' > "$home/.config/orca/daemon/daemon-v21.sock"

  cat > "$fakebin/fmod" <<'SH'
#!/usr/bin/env bash
printf '{"daemon_reachable":false,"daemon_pong":{}}\n'
exit 0
SH
  chmod +x "$fakebin/fmod"
  cat > "$fakebin/pkill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/pkill"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/setsid"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/orca"

  output=$(PATH="$fakebin:$PATH" HOME="$home" FM_HOME="$home" XDG_CONFIG_HOME="$xdg" FM_ORCA_BIN="$fakebin/orca" FM_ORCA_FMOD="$fakebin/fmod" "$SUPERVISOR" start 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "start should fail after fake relaunch stays unreachable, got $status: $output"
  [ ! -e "$xdg/orca/orca-runtime.json" ] || fail "runtime file under XDG_CONFIG_HOME should be removed"
  [ ! -e "$xdg/orca/single-instance.lock" ] || fail "single-instance lock under XDG_CONFIG_HOME should be removed"
  [ ! -e "$xdg/orca/daemon/daemon-v21.sock" ] || fail "daemon socket under XDG_CONFIG_HOME should be removed"
  [ ! -e "$xdg/orca/daemon/daemon-v21.pid" ] || fail "daemon pid under XDG_CONFIG_HOME should be removed"
  [ ! -e "$xdg/orca/daemon/daemon-v21.token" ] || fail "daemon token under XDG_CONFIG_HOME should be removed"
  [ -e "$home/.config/orca/orca-runtime.json" ] || fail "default-home runtime should not be touched when XDG_CONFIG_HOME is set"
  [ -e "$home/.config/orca/single-instance.lock" ] || fail "default-home lock should not be touched when XDG_CONFIG_HOME is set"
  [ -e "$home/.config/orca/daemon/daemon-v21.sock" ] || fail "default-home socket should not be touched when XDG_CONFIG_HOME is set"
  pass "fm-supervise-orca reap: honors XDG_CONFIG_HOME"
}

test_start_lets_follow_process_own_pidfile() {
  local case_dir home fakebin pidfile pid out stop_out
  case_dir="$TMP_ROOT/start-pidfile"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state"
  pidfile="$home/state/.orca-supervisor.pid"
  cat > "$fakebin/fmod" <<'SH'
#!/usr/bin/env bash
printf '{"daemon_reachable":true,"daemon_pong":{"pong":true}}\n'
exit 0
SH
  chmod +x "$fakebin/fmod"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--fork" ] && shift
"$@" &
exit 0
SH
  chmod +x "$fakebin/setsid"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fakebin/fmod" FM_ORCA_CHECK_INTERVAL=60 "$SUPERVISOR" start)
  assert_contains "$out" "supervisor: started pid=" "start should confirm the pid written by --follow"
  [ -s "$pidfile" ] || fail "start should wait for --follow to write a pidfile"
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || fail "pidfile should point at the live --follow process, got $pid"
  stop_out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fakebin/fmod" "$SUPERVISOR" stop)
  assert_contains "$stop_out" "supervisor: stopped (pid=$pid)" "stop should use the --follow pid"
  pass "fm-supervise-orca start: --follow owns the pidfile"
}

run_test() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep ^test_); do
    "$t"
  done
}

run_test
