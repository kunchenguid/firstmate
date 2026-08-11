#!/usr/bin/env bash
# Behavioral coverage for the installed launchd deadman.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deadman)
NOTIFIER="$TMP_ROOT/notifier"
cat > "$NOTIFIER" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_TEST_NOTIFY_LOG"
[ "${FM_TEST_NOTIFY_FAIL:-0}" -eq 0 ]
SH
chmod +x "$NOTIFIER"

set_mtime() {
  local path=$1 epoch=$2 stamp
  if touch -d "@$epoch" "$path" 2>/dev/null; then
    return 0
  fi
  stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S) || return 1
  touch -t "$stamp" "$path"
}

new_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/install" "$dir/home/state"
  : > "$dir/home/state/.last-watcher-beat"
  cat > "$dir/install/deadman.env" <<EOF
FM_HOME=$dir/home
STALE_AFTER_SECS=600
SAMPLE_GAP_SECS=60
SAMPLE_MAX_GAP_SECS=120
FIRST_ARM_GRACE_SECS=660
WAKE_GRACE_SECS=300
SLEEP_GAP_DETECT_SECS=99999
COOLDOWN_SECS=1800
EOF
  printf 'command:true\n' > "$dir/install/deadman.conf"
  printf '0\n' > "$dir/install/installed-at"
  printf '0\n' > "$dir/install/armed"
  printf '%s\n' "$dir"
}

run_probe() {
  local dir=$1 now=$2
  FM_DEADMAN_INSTALL_DIR="$dir/install" \
    FM_DEADMAN_NOW="$now" \
    FM_DEADMAN_NOTIFY_EXEC="$NOTIFIER" \
    FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    FM_TEST_NOTIFY_FAIL=${FM_TEST_NOTIFY_FAIL:-0} \
    "$ROOT/bin/fm-deadman.sh"
}

notify_count() {
  local file=$1
  [ -f "$file" ] && wc -l < "$file" | tr -d ' ' || printf '0\n'
}

test_age_boundary_and_double_sample() {
  local dir
  dir=$(new_case ages)
  set_mtime "$dir/home/state/.last-watcher-beat" 400
  run_probe "$dir" 1000
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "age exactly N paged"
  set_mtime "$dir/home/state/.last-watcher-beat" 399
  run_probe "$dir" 1001
  run_probe "$dir" 1060
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "second sample before 60 seconds paged"
  run_probe "$dir" 1061
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "second stale sample at 60 seconds did not page"
  pass "staleness is age > N and requires two samples 60-120 seconds apart"
}

test_missing_future_and_unreadable() {
  local missing future unreadable fakebin
  missing=$(new_case missing)
  rm -rf "${missing:?}/home"
  run_probe "$missing" 1000
  run_probe "$missing" 1060
  [ "$(notify_count "$missing/notify.log")" -eq 1 ] || fail "missing FM_HOME did not page after confirmation"

  future=$(new_case future)
  set_mtime "$future/home/state/.last-watcher-beat" 1200
  run_probe "$future" 1000
  run_probe "$future" 1060
  [ "$(notify_count "$future/notify.log")" -eq 1 ] || fail "future beacon did not page after confirmation"

  unreadable=$(new_case unreadable)
  fakebin="$unreadable/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/stat"
  PATH="$fakebin:$PATH" run_probe "$unreadable" 1000
  PATH="$fakebin:$PATH" run_probe "$unreadable" 1060
  [ "$(notify_count "$unreadable/notify.log")" -eq 1 ] || fail "unreadable beacon mtime did not page after confirmation"
  pass "missing, unreadable, and future beacon inputs are unhealthy"
}

test_flap_resets_confirmation() {
  local dir
  dir=$(new_case flap)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  set_mtime "$dir/home/state/.last-watcher-beat" 1050
  run_probe "$dir" 1050
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1110
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "healthy flap did not reset stale confirmation"
  run_probe "$dir" 1170
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "post-flap second stale sample did not page"
  pass "a healthy flap resets stale confirmation"
}

test_cooldown_and_failed_delivery() {
  local dir
  dir=$(new_case cooldown)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  run_probe "$dir" 1060
  run_probe "$dir" 1120
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "successful page cooldown did not suppress a retry"
  [ "$(cat "$dir/install/last-success-at")" = 1060 ] || fail "successful cooldown marker is wrong"

  dir=$(new_case notify-failure)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  FM_TEST_NOTIFY_FAIL=1 run_probe "$dir" 1060
  [ ! -e "$dir/install/last-success-at" ] || fail "failed notification consumed successful-page cooldown"
  run_probe "$dir" 1120
  [ "$(notify_count "$dir/notify.log")" -eq 2 ] || fail "failed notification was not retried at the next confirmed sample"
  [ "$(cat "$dir/install/last-success-at")" = 1120 ] || fail "successful retry did not write cooldown marker"
  pass "only successful delivery consumes the page cooldown"
}

test_first_arm_and_sleep_wake_grace() {
  local dir
  dir=$(new_case grace)
  rm -f "$dir/install/armed"
  printf '1000\n' > "$dir/install/installed-at"
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  run_probe "$dir" 1060
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "first-arm grace paged during installation window"
  printf '0\n' > "$dir/install/armed"
  sed -i.bak 's/SLEEP_GAP_DETECT_SECS=99999/SLEEP_GAP_DETECT_SECS=180/' "$dir/install/deadman.env"
  rm -f "$dir/install/deadman.env.bak"
  printf '1000\n' > "$dir/install/last-run-at"
  run_probe "$dir" 1400
  run_probe "$dir" 1460
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "sleep/wake grace paged immediately after a run gap"
  pass "first-arm and inferred sleep/wake gaps defer pages"
}

test_hostile_config_is_data() {
  local dir marker rc
  dir=$(new_case hostile)
  marker="$dir/executed"
  # shellcheck disable=SC2016 # Literal command substitution is the hostile input under test.
  printf 'FM_HOME=$(touch %s)\n' "$marker" > "$dir/install/deadman.env"
  set +e
  run_probe "$dir" 1000 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "hostile config did not produce a self-fault"
  [ ! -e "$marker" ] || fail "hostile config executed shell syntax"
  pass "configuration is parsed as allowlisted data, never sourced"
}

test_corrupt_deadman_state_self_faults() {
  local dir rc before after

  # Corrupt installed-at must exit 2 during first-arm, not rewrite grace start.
  dir=$(new_case corrupt-installed-at)
  rm -f "$dir/install/armed"
  printf 'not-a-timestamp\n' > "$dir/install/installed-at"
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  set +e
  run_probe "$dir" 1000 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "corrupt installed-at exited $rc instead of 2"
  [ "$(cat "$dir/install/installed-at")" = "not-a-timestamp" ] \
    || fail "corrupt installed-at was rewritten instead of self-faulting"
  [ ! -e "$dir/install/armed" ] || fail "corrupt installed-at still armed the deadman"

  # Corrupt last-run-at must exit 2 before sleep/wake gap math runs.
  dir=$(new_case corrupt-last-run-at)
  printf 'bogus\n' > "$dir/install/last-run-at"
  set_mtime "$dir/home/state/.last-watcher-beat" 1000
  set +e
  run_probe "$dir" 1000 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "corrupt last-run-at exited $rc instead of 2"
  [ "$(cat "$dir/install/last-run-at")" = "bogus" ] \
    || fail "corrupt last-run-at was overwritten instead of self-faulting"
  [ ! -e "$dir/install/wake-grace-until" ] \
    || fail "corrupt last-run-at still started sleep/wake grace"

  # Corrupt wake-grace-until must exit 2, not treat grace as missing/expired.
  dir=$(new_case corrupt-wake-grace)
  printf '1000\n' > "$dir/install/last-run-at"
  printf 'not-unix\n' > "$dir/install/wake-grace-until"
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  set +e
  run_probe "$dir" 1060 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "corrupt wake-grace-until exited $rc instead of 2"
  [ "$(cat "$dir/install/wake-grace-until")" = "not-unix" ] \
    || fail "corrupt wake-grace-until was cleared instead of self-faulting"
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] \
    || fail "corrupt wake-grace-until continued into paging"

  # Corrupt last-success-at must exit 2 rather than skipping cooldown and re-paging.
  dir=$(new_case corrupt-last-success)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  printf 'xyz\n' > "$dir/install/last-success-at"
  before=$(notify_count "$dir/notify.log")
  set +e
  run_probe "$dir" 1060 >/dev/null 2>&1
  rc=$?
  set -e
  after=$(notify_count "$dir/notify.log")
  [ "$rc" -eq 2 ] || fail "corrupt last-success-at exited $rc instead of 2"
  [ "$after" -eq "$before" ] \
    || fail "corrupt last-success-at still delivered a page instead of self-faulting"
  [ "$(cat "$dir/install/last-success-at")" = "xyz" ] \
    || fail "corrupt last-success-at was rewritten instead of self-faulting"

  # Missing timestamps remain non-faulting (return 1 path).
  dir=$(new_case missing-timestamps)
  rm -f "$dir/install/armed" "$dir/install/installed-at"
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  set +e
  run_probe "$dir" 1000 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing installed-at exited $rc instead of 0"
  [ -f "$dir/install/installed-at" ] || fail "missing installed-at did not start first-arm grace"

  pass "corrupt deadman timestamps self-fault in the main shell"
}

test_notify_only_and_concurrent_lock() {
  local dir fakebin slow p1 p2 rc
  dir=$(new_case no-spawn)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for name in git launchctl fm-spawn.sh; do
    cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$FM_TEST_FORBIDDEN_LOG"
exit 97
SH
    chmod +x "$fakebin/$name"
  done
  FM_TEST_FORBIDDEN_LOG="$dir/forbidden.log" PATH="$fakebin:$PATH" run_probe "$dir" 1000
  FM_TEST_FORBIDDEN_LOG="$dir/forbidden.log" PATH="$fakebin:$PATH" run_probe "$dir" 1060
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "PATH mutation guards disrupted the notify-only probe"
  [ ! -s "$dir/forbidden.log" ] || fail "probe invoked a forbidden fleet mutation command"

  dir=$(new_case concurrent)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  slow="$dir/slow-notifier"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
sleep 1
printf '%s|%s\n' "$1" "$2" >> "$FM_TEST_NOTIFY_LOG"
SH
  chmod +x "$slow"
  FM_DEADMAN_INSTALL_DIR="$dir/install" FM_DEADMAN_NOW=1060 FM_DEADMAN_NOTIFY_EXEC="$slow" FM_TEST_NOTIFY_LOG="$dir/notify.log" "$ROOT/bin/fm-deadman.sh" & p1=$!
  FM_DEADMAN_INSTALL_DIR="$dir/install" FM_DEADMAN_NOW=1060 FM_DEADMAN_NOTIFY_EXEC="$slow" FM_TEST_NOTIFY_LOG="$dir/notify.log" "$ROOT/bin/fm-deadman.sh" & p2=$!
  wait "$p1"
  wait "$p2"
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "concurrent invocations delivered more than one page"

  dir=$(new_case canary-lock)
  mkdir "$dir/install/.probe.lock"
  set +e
  FM_DEADMAN_INSTALL_DIR="$dir/install" \
    FM_DEADMAN_NOW=1000 \
    FM_DEADMAN_NOTIFY_EXEC="$NOTIFIER" \
    FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    "$ROOT/bin/fm-deadman.sh" --canary
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "canary under lock contention exited $rc instead of 1"
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "canary under lock contention still delivered a notification"
  set +e
  run_probe "$dir" 1000
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "normal probe under lock contention exited $rc instead of 0"
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "normal probe under lock contention delivered a notification"
  pass "probe is notify-only; concurrent probes serialize; canary fails closed on lock"
}

test_term_reaps_notifier_and_releases_lock() {
  local dir slow pid rc notifier_pid i
  dir=$(new_case term-signal)
  set_mtime "$dir/home/state/.last-watcher-beat" 0
  run_probe "$dir" 1000
  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "setup first sample paged"

  slow="$dir/slow-notifier"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_TEST_NOTIFY_PID"
sleep 30
printf '%s|%s\n' "$1" "$2" >> "$FM_TEST_NOTIFY_LOG"
SH
  chmod +x "$slow"

  rm -f "$dir/notify.pid" "$dir/notify.log"
  FM_DEADMAN_INSTALL_DIR="$dir/install" \
    FM_DEADMAN_NOW=1060 \
    FM_DEADMAN_NOTIFY_EXEC="$slow" \
    FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    FM_TEST_NOTIFY_PID="$dir/notify.pid" \
    "$ROOT/bin/fm-deadman.sh" & pid=$!

  i=0
  while [ ! -f "$dir/notify.pid" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$dir/notify.pid" ] || fail "notifier did not start before TERM"
  notifier_pid=$(cat "$dir/notify.pid")

  kill -TERM "$pid"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "TERM probe exited 0 instead of nonzero"

  [ ! -d "$dir/install/.probe.lock" ] || fail "TERM left probe lock behind"

  i=0
  while kill -0 "$notifier_pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$notifier_pid" 2>/dev/null || fail "TERM left notifier process orphaned"

  [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "TERM allowed notifier to complete a page"

  run_probe "$dir" 1120
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "post-TERM probe did not deliver exactly one page"

  set_mtime "$dir/home/state/.last-watcher-beat" 2000
  set +e
  run_probe "$dir" 2000
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "healthy probe exited $rc"
  [ ! -d "$dir/install/.probe.lock" ] || fail "healthy probe left lock behind"

  pass "TERM cleanup reaps notifier, releases lock, exits nonzero; normal exit stays zero"
}

test_installer_and_plist() {
  local dir plist install program
  dir="$TMP_ROOT/installer"
  install="$dir/Application Support/Firstmate/deadman"
  plist="$dir/LaunchAgents/com.firstmate.deadman.plist"
  mkdir -p "$dir/home/state"
  : > "$dir/home/state/.last-watcher-beat"
  FM_DEADMAN_INSTALL_DIR="$install" FM_DEADMAN_PLIST="$plist" \
    FM_DEADMAN_NOTIFY_EXEC="$NOTIFIER" FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    "$ROOT/bin/fm-deadman-install.sh" --fm-home "$dir/home" --channel command:true >/dev/null
  [ -x "$install/fm-deadman.sh" ] || fail "installer did not create an executable stable probe copy"
  if command -v plutil >/dev/null 2>&1; then
    program=$(plutil -extract ProgramArguments.0 raw -o - "$plist") || fail "plist program argument could not be decoded"
    [ "$program" = "$install/fm-deadman.sh" ] || fail "plist does not run the installed probe copy"
  fi
  [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "installer did not send its mandatory canary"
  sed -i.bak 's/COOLDOWN_SECS=1800/COOLDOWN_SECS=42/' "$install/deadman.env"
  rm -f "$install/deadman.env.bak"
  FM_DEADMAN_INSTALL_DIR="$install" FM_DEADMAN_PLIST="$plist" \
    FM_DEADMAN_NOTIFY_EXEC="$NOTIFIER" FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    "$ROOT/bin/fm-deadman-install.sh" --channel command:true >/dev/null
  grep -Fx 'COOLDOWN_SECS=42' "$install/deadman.env" >/dev/null || fail "installer update replaced existing timing configuration"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail "installed plist failed plutil lint"
  fi
  pass "installer writes a valid stable-copy LaunchAgent and sends a canary"
}

test_installer_default_channel_and_path_parity() {
  local dir plist install path_value expected_path rc canary_bin
  dir="$TMP_ROOT/installer-default"
  install="$dir/Application Support/Firstmate/deadman"
  plist="$dir/LaunchAgents/com.firstmate.deadman.plist"
  canary_bin="$dir/pathbin"
  mkdir -p "$dir/home/state" "$canary_bin"
  : > "$dir/home/state/.last-watcher-beat"
  # Distinct PATH entry the LaunchAgent must inherit so non-absolute channel
  # commands resolve the same way the installer canary did.
  expected_path="$canary_bin:/usr/bin:/bin:/usr/sbin:/sbin"
  cat > "$canary_bin/herdr" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$canary_bin/herdr"

  set +e
  PATH="$expected_path" FM_DEADMAN_INSTALL_DIR="$install" FM_DEADMAN_PLIST="$plist" \
    FM_DEADMAN_NOTIFY_EXEC="$NOTIFIER" FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    /bin/bash "$ROOT/bin/fm-deadman-install.sh" --fm-home "$dir/home" >/dev/null
  rc=$?
  set -e
  if [ "$(uname)" = Darwin ]; then
    [ "$rc" -eq 0 ] || fail "default no-channel install exited $rc under /bin/bash on macOS"
    [ "$(notify_count "$dir/notify.log")" -eq 1 ] || fail "default install skipped mandatory canary"
  else
    [ "$rc" -eq 1 ] || fail "default no-channel install did not fail its unavailable-platform canary"
    [ "$(notify_count "$dir/notify.log")" -eq 0 ] || fail "unavailable-platform canary reported delivery"
  fi
  [ -x "$install/fm-deadman.sh" ] || fail "default install did not create stable probe copy"
  [ -f "$install/deadman.conf" ] || fail "default install did not write channel config"
  [ "$(cat "$install/deadman.conf")" = "auto" ] || fail "default install did not write auto channel"

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail "default-install plist failed plutil lint"
    path_value=$(plutil -extract EnvironmentVariables.PATH raw -o - "$plist") \
      || fail "plist PATH could not be decoded via plutil"
  else
    path_value=$(python3 - "$plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
print(data["EnvironmentVariables"]["PATH"])
PY
) || fail "plist PATH could not be decoded via plistlib"
  fi
  [ "$path_value" = "$expected_path" ] || fail "plist PATH does not match installer PATH"

  # The live LaunchAgent environment must retain the installer's PATH so an
  # explicitly configured non-absolute channel resolves predictably.
  PATH="$path_value" command -v herdr >/dev/null 2>&1 \
    || fail "LaunchAgent PATH cannot resolve herdr from the installer PATH"
  [ "$(PATH=$path_value command -v herdr)" = "$canary_bin/herdr" ] \
    || fail "LaunchAgent PATH resolved a different herdr than the pinned installer PATH"

  pass "default no-channel install writes auto and pins installer PATH in plist"
}

test_age_boundary_and_double_sample
test_missing_future_and_unreadable
test_flap_resets_confirmation
test_cooldown_and_failed_delivery
test_first_arm_and_sleep_wake_grace
test_hostile_config_is_data
test_corrupt_deadman_state_self_faults
test_notify_only_and_concurrent_lock
test_term_reaps_notifier_and_releases_lock
test_installer_and_plist
test_installer_default_channel_and_path_parity
