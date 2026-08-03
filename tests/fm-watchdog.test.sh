#!/usr/bin/env bash
# tests/fm-watchdog.test.sh - external cron-level watchdog: healthy silence,
# stale-beacon and dead-daemon alarms, dedupe window, idle-home indifference,
# marker cleanup on recovery, channel-order fallback, and idempotent cron
# install. All visible-alert channels are stubbed (FM_WATCHDOG_ALERT_EXEC seam
# or fakebin PATH shims); no test can raise a real popup or touch a real
# crontab.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-watchdog.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-tests)

# make_home <name>: fresh fake FM_HOME with a state dir; echoes the home path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# recorder <dir>: drop an alert-seam recorder appending "<condition>\t<summary>"
# to $dir/alerts.log; echoes the recorder path.
make_recorder() {
  local dir=$1
  cat > "$dir/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "$(dirname "${BASH_SOURCE[0]}")/alerts.log"
exit 0
REC
  chmod +x "$dir/rec"
  printf '%s\n' "$dir/rec"
}

run_wd() {  # <home> [env overrides...] -- runs one watchdog pass, captures rc
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$WATCHDOG"
}

test_healthy_home_is_silent() {
  local home rec out rc=0
  home=$(make_home healthy)
  rec=$(make_recorder "$home")
  printf 'window=w1\n' > "$home/state/live-task.meta"
  touch "$home/state/.last-watcher-beat"
  out=$(run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "healthy home exited $rc: $out"
  [ -z "$out" ] || fail "healthy home was not silent: $out"
  [ ! -e "$home/state/.watchdog-alarm" ] || fail "healthy home wrote an alarm file"
  [ ! -e "$home/alerts.log" ] || fail "healthy home fired a visible alert"
  pass "healthy home: silent, exit 0, no alarm record"
}

test_stale_beacon_with_work_alarms() {
  local home rec rc=0
  home=$(make_home stale-beacon)
  rec=$(make_recorder "$home")
  printf 'window=w1\n' > "$home/state/live-task.meta"
  touch -d '@1' "$home/state/.last-watcher-beat"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "stale beacon with work exited $rc, want 1"
  grep -q 'watcher-stale' "$home/state/.watchdog-alarm" || fail "no watcher-stale alarm line"
  grep -q $'^watcher-stale\t' "$home/alerts.log" || fail "no visible watcher-stale alert"
  pass "stale beacon with recorded work: alarm line + visible alert + exit 1"
}

test_missing_beacon_with_work_alarms() {
  local home rec rc=0
  home=$(make_home missing-beacon)
  rec=$(make_recorder "$home")
  printf 'window=w1\n' > "$home/state/live-task.meta"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "missing beacon with work exited $rc, want 1"
  grep -q 'watcher-stale' "$home/state/.watchdog-alarm" || fail "no watcher-stale alarm line"
  pass "missing beacon with recorded work alarms"
}

test_afk_dead_daemon_alarms() {
  local home rec dead_pid rc=0
  home=$(make_home afk-dead-daemon)
  rec=$(make_recorder "$home")
  touch "$home/state/.afk"
  touch "$home/state/.last-watcher-beat"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  printf '%s\n' "$dead_pid" > "$home/state/.supervise-daemon.pid"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "afk + dead daemon exited $rc, want 1"
  grep -q 'daemon-dead' "$home/state/.watchdog-alarm" || fail "no daemon-dead alarm line"
  grep -q $'^daemon-dead\t' "$home/alerts.log" || fail "no visible daemon-dead alert"
  pass "afk with dead daemon pid: daemon-dead alarm"
}

test_afk_missing_pidfile_alarms() {
  local home rec rc=0
  home=$(make_home afk-no-pidfile)
  rec=$(make_recorder "$home")
  touch "$home/state/.afk"
  touch "$home/state/.last-watcher-beat"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "afk + missing pidfile exited $rc, want 1"
  grep -q 'daemon-dead' "$home/state/.watchdog-alarm" || fail "no daemon-dead alarm line"
  pass "afk with missing daemon pidfile: daemon-dead alarm"
}

test_afk_live_daemon_is_healthy() {
  local home rec rc=0
  home=$(make_home afk-live-daemon)
  rec=$(make_recorder "$home")
  touch "$home/state/.afk"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$$" > "$home/state/.supervise-daemon.pid"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "afk + live daemon exited $rc, want 0"
  [ ! -e "$home/state/.watchdog-alarm" ] || fail "live daemon produced an alarm"
  pass "afk with live daemon pid: healthy"
}

test_dedupe_window_suppresses_second_alert() {
  local home rec rc=0
  home=$(make_home dedupe)
  rec=$(make_recorder "$home")
  printf 'window=w1\n' > "$home/state/live-task.meta"
  touch -d '@1' "$home/state/.last-watcher-beat"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || true
  rc=0
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "deduped failing pass exited $rc, want 1"
  [ "$(wc -l < "$home/state/.watchdog-alarm")" -eq 1 ] || fail "dedupe window appended a second alarm line"
  [ "$(wc -l < "$home/alerts.log")" -eq 1 ] || fail "dedupe window fired a second visible alert"
  pass "second failing pass inside dedupe window: quiet but still exit 1"
}

test_realert_after_window_elapses() {
  local home rec
  home=$(make_home realert)
  rec=$(make_recorder "$home")
  printf 'window=w1\n' > "$home/state/live-task.meta"
  touch -d '@1' "$home/state/.last-watcher-beat"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || true
  touch -d '@1' "$home/state/.watchdog-alerted-watcher-stale"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || true
  [ "$(wc -l < "$home/state/.watchdog-alarm")" -eq 2 ] || fail "elapsed re-alert window did not re-alert"
  pass "re-alert fires again after FM_WATCHDOG_REALERT elapses"
}

test_recovery_clears_marker() {
  local home rec rc=0
  home=$(make_home recovery)
  rec=$(make_recorder "$home")
  printf 'window=w1\n' > "$home/state/live-task.meta"
  touch -d '@1' "$home/state/.last-watcher-beat"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || true
  [ -e "$home/state/.watchdog-alerted-watcher-stale" ] || fail "failing pass left no dedupe marker"
  touch "$home/state/.last-watcher-beat"
  run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "recovered home exited $rc, want 0"
  [ ! -e "$home/state/.watchdog-alerted-watcher-stale" ] || fail "recovery did not clear the dedupe marker"
  pass "recovered condition clears its dedupe marker"
}

test_idle_home_ignores_beacon() {
  local home rec out rc=0
  home=$(make_home idle)
  rec=$(make_recorder "$home")
  out=$(run_wd "$home" FM_WATCHDOG_ALERT_EXEC="$rec" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "idle home (no metas, no afk, no beacon) exited $rc: $out"
  [ -z "$out" ] || fail "idle home was not silent: $out"
  pass "idle home: missing beacon is healthy with no work recorded"
}

test_channel_order_prefers_powershell() {
  local home fakebin rc=0
  home=$(make_home channels)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/powershell.exe" <<SH
#!/usr/bin/env bash
echo "ps-invoked \$*" >> "$home/ps.log"
exit 0
SH
  chmod +x "$fakebin/powershell.exe"
  cat > "$fakebin/notify-send" <<SH
#!/usr/bin/env bash
echo "ns-invoked" >> "$home/ns.log"
exit 0
SH
  chmod +x "$fakebin/notify-send"
  printf 'window=w1\n' > "$home/state/live-task.meta"
  touch -d '@1' "$home/state/.last-watcher-beat"
  PATH="$fakebin:$PATH" run_wd "$home" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "channel-order pass exited $rc, want 1"
  [ -e "$home/ps.log" ] || fail "powershell.exe channel was not used"
  [ ! -e "$home/ns.log" ] || fail "notify-send fired although powershell.exe was available"
  pass "alert channel order: powershell.exe wins when present"
}

test_missing_fm_home_fails_closed() {
  local rc=0
  env -u FM_HOME "$WATCHDOG" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "missing FM_HOME exited $rc, want 2"
  pass "missing FM_HOME refuses with exit 2"
}

test_install_cron_idempotent() {
  local home fakebin crontab_store out
  home=$(make_home cron-install)
  fakebin=$(fm_fakebin "$home")
  crontab_store="$home/crontab.store"
  : > "$crontab_store"
  cat > "$fakebin/crontab" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then cat "$crontab_store"; exit 0; fi
cat "\$1" > "$crontab_store"
SH
  chmod +x "$fakebin/crontab"
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/pgrep"
  out=$(PATH="$fakebin:$PATH" env FM_HOME="$home" "$WATCHDOG" --install-cron 2>&1) || fail "install-cron failed: $out"
  out=$(PATH="$fakebin:$PATH" env FM_HOME="$home" "$WATCHDOG" --install-cron 2>&1) || fail "second install-cron failed: $out"
  [ "$(grep -c "fm-watchdog:$home" "$crontab_store")" -eq 1 ] || fail "install-cron stacked duplicate entries"
  grep -q '\*/10 \* \* \* \*' "$crontab_store" || fail "installed entry is not every-10-minutes"
  pass "install-cron is idempotent for the same home"
}

test_install_cron_without_crontab_instructs() {
  local home fakebin out rc=0
  home=$(make_home cron-missing)
  fakebin=$(fm_fakebin "$home")
  # Restrict PATH to the fakebin plus core utils so `crontab` is absent.
  cat > "$fakebin/runner" <<SH
#!/usr/bin/env bash
export PATH="/usr/bin:/bin"
command -v crontab >/dev/null 2>&1 && exit 77
FM_HOME="$home" "$WATCHDOG" --install-cron
SH
  chmod +x "$fakebin/runner"
  out=$("$fakebin/runner" 2>&1) || rc=$?
  if [ "$rc" -eq 77 ]; then
    pass "install-cron missing-crontab case skipped (host has crontab in /usr/bin)"
    return 0
  fi
  [ "$rc" -eq 1 ] || fail "install-cron without crontab exited $rc, want 1"
  printf '%s' "$out" | grep -q 'schtasks.exe' || fail "manual instructions lack the schtasks.exe alternative"
  pass "install-cron without crontab prints manual + schtasks instructions"
}

test_healthy_home_is_silent
test_stale_beacon_with_work_alarms
test_missing_beacon_with_work_alarms
test_afk_dead_daemon_alarms
test_afk_missing_pidfile_alarms
test_afk_live_daemon_is_healthy
test_dedupe_window_suppresses_second_alert
test_realert_after_window_elapses
test_recovery_clears_marker
test_idle_home_ignores_beacon
test_channel_order_prefers_powershell
test_missing_fm_home_fails_closed
test_install_cron_idempotent
test_install_cron_without_crontab_instructs
