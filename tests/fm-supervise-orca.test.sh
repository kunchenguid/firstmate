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
  local case_dir home fakebin out
  case_dir="$TMP_ROOT/status-fm-home"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.orca-supervisor.pid"
  cat > "$fakebin/fmod" <<'SH'
#!/usr/bin/env bash
printf '{"daemon_reachable":true,"daemon_pong":{"pong":true}}\n'
exit 0
SH
  chmod +x "$fakebin/fmod"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fakebin/fmod" "$SUPERVISOR" status)
  assert_contains "$out" "supervisor: live pid=$$" "status should read pidfile from FM_HOME/state"
  assert_contains "$out" "daemon:     reachable" "status should report reachable daemon"
  pass "fm-supervise-orca status: pidfile is scoped by FM_HOME"
}

test_reap_scopes_orca_ide_pkill_to_user() {
  assert_contains "$(sed -n '55,67p' "$SUPERVISOR")" "pkill -TERM -u \"\$USER\" -x 'orca-ide'" "TERM pkill for orca-ide should be user-scoped"
  assert_contains "$(sed -n '55,67p' "$SUPERVISOR")" "pkill -KILL -u \"\$USER\" -x 'orca-ide'" "KILL pkill for orca-ide should be user-scoped"
  pass "fm-supervise-orca reap: orca-ide pkill is scoped to current user"
}

run_test() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep ^test_); do
    "$t"
  done
}

run_test
