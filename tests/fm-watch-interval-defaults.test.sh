#!/usr/bin/env bash
# tests/fm-watch-interval-defaults.test.sh - the watcher's unset-env defaults for
# FM_CHECK_INTERVAL (600s) and FM_HOME_SUMMARY_INTERVAL (900s), plus the invalid
# -value fallback for the latter. Each case ages the gated file to a point that
# was due under the OLD 300s default but is NOT due under the new default, so a
# regression back to 300 fails these tests instead of passing them silently.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-interval-defaults)

# Portable mtime read, matching bin/fm-watch.sh's own stat_mtime: branch on
# uname rather than a blind `||` fallback. On Linux, BSD's `-f %m` is parsed as
# --file-system plus a second bogus file argument ("%m"), so it fails on that
# argument but still prints the real file's verbose filesystem block to stdout
# before the fallback also runs - polluting the capture with disk-usage figures
# that drift between calls even though the real mtime never changed.
if [ "$(uname)" = Darwin ]; then
  mtime_of() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  mtime_of() { stat -c %Y "$1" 2>/dev/null; }
fi

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_test_track_watcher_state "$home/state"
  printf '%s\n' "$home"
}

seed_home_summary() {
  local home=$1
  printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$WRITER" \
    || fail "could not seed the home-summary ledger"
}

test_check_interval_default_is_600_not_300() {
  local home check_file out pid status
  home=$(make_home check-not-due)
  check_file="$home/state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'ready\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register custom check"
  # 550s old: due under the retired 300s default, not due under the new 600s one.
  fm_touch_epoch "$(( $(date +%s) - 550 ))" "$home/state/.last-check"
  out="$home/not-due.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  status=0
  wait_for_exit "$pid" 30 || status=$?
  [ "$status" -eq 124 ] \
    || fail "watcher fired the check sweep at 550s old; FM_CHECK_INTERVAL default is no longer >550s"
  grep -F "check: $check_file" "$out" >/dev/null \
    && fail "check sweep output appeared even though the watcher did not report an actionable wake"
  pass "550s-old .last-check does not trigger the default check sweep"

  home=$(make_home check-due)
  check_file="$home/state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'ready\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register custom check"
  # 610s old: due under the new 600s default.
  fm_touch_epoch "$(( $(date +%s) - 610 ))" "$home/state/.last-check"
  out="$home/due.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not fire the check sweep at 610s old"
  grep -F "check: $check_file: ready" "$out" >/dev/null \
    || fail "watcher exited without reporting the expected check wake"
  pass "610s-old .last-check triggers the default check sweep"
}

wait_for_summary_mtime_change() {
  local path=$1 before=$2 i=0 now
  while [ "$i" -lt 30 ]; do
    now=$(mtime_of "$path")
    [ "$now" = "$before" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_home_summary_interval_default_is_900_not_300() {
  local home before pid out i
  home=$(make_home summary-not-due)
  seed_home_summary "$home"
  # 650s old: due under the retired 300s default, not due under the new 900s one, with a wide margin against CI scheduling delay between seeding the mtime and the watcher's first cycle.
  fm_touch_epoch "$(( $(date +%s) - 650 ))" "$home/state/home-summary.json"
  before=$(mtime_of "$home/state/home-summary.json")
  out="$home/not-due.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$home/state/.last-watcher-beat" ] || fail "watcher did not complete its initial cycle"
  sleep 1
  wait_for_summary_mtime_change "$home/state/home-summary.json" "$before" \
    && fail "home-summary.json refreshed at 650s old; FM_HOME_SUMMARY_INTERVAL default is no longer >650s"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  pass "650s-old home-summary.json is not refreshed by the default cadence"

  home=$(make_home summary-due)
  seed_home_summary "$home"
  # 910s old: due under the new 900s default.
  fm_touch_epoch "$(( $(date +%s) - 910 ))" "$home/state/home-summary.json"
  before=$(mtime_of "$home/state/home-summary.json")
  out="$home/due.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_summary_mtime_change "$home/state/home-summary.json" "$before" \
    || fail "home-summary.json was not refreshed within the bounded wait at 910s old"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  pass "910s-old home-summary.json is refreshed by the default cadence"
}

test_home_summary_interval_invalid_value_falls_back_to_900_not_300() {
  local home before pid out i
  home=$(make_home summary-invalid-fallback)
  seed_home_summary "$home"
  # 650s old: due under the retired 300s fallback, not due under the new 900s one, with the same wide margin.
  fm_touch_epoch "$(( $(date +%s) - 650 ))" "$home/state/home-summary.json"
  before=$(mtime_of "$home/state/home-summary.json")
  out="$home/invalid.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=not-a-number \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$home/state/.last-watcher-beat" ] || fail "watcher did not complete its initial cycle"
  sleep 1
  wait_for_summary_mtime_change "$home/state/home-summary.json" "$before" \
    && fail "an invalid FM_HOME_SUMMARY_INTERVAL fell back to 300s instead of 900s"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  pass "an invalid FM_HOME_SUMMARY_INTERVAL falls back to the new 900s default"
}

test_check_interval_default_is_600_not_300
test_home_summary_interval_default_is_900_not_300
test_home_summary_interval_invalid_value_falls_back_to_900_not_300
