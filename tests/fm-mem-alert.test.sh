#!/usr/bin/env bash
# Behavior tests for bin/fm-mem-alert.sh.
#
# The alert is the one-minute check that names the top memory consumer once the
# host passes the threshold. These drive it with a fixture meminfo and a fixture
# proc mount so the crossing, re-arming, and the top-process naming are all
# deterministic and independent of the host's real memory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALERT="$ROOT/bin/fm-mem-alert.sh"

make_meminfo() {  # <file> <memtotal-kb> <memavailable-kb>
  printf 'MemTotal:       %s kB\nMemFree: 1 kB\nMemAvailable:   %s kB\nSwapTotal: 1 kB\nSwapFree: 0 kB\n' \
    "$2" "$3" > "$1"
}

make_proc() {  # <dir>
  mkdir -p "$1/100" "$1/200"
  printf 'Name: small\nVmRSS:   %s kB\n' 1000 > "$1/100/status"
  printf 'small\n' > "$1/100/comm"
  printf 'Name: big\nVmRSS:   %s kB\n' 500000 > "$1/200/status"
  printf 'big\n' > "$1/200/comm"
}

# run_check <state> <meminfo> <proc> <alert-out> [extra args...]
run_check() {
  local state=$1 meminfo=$2 proc=$3 out=$4
  shift 4
  FM_CONFIG_OVERRIDE="$CFG" FM_MEM_ALERT_STATE="$state" \
    "$ALERT" check --meminfo "$meminfo" --procfs "$proc" \
    --emit "printf '%s' \"\$1\" > $out" "$@"
}

setup() {
  ROOT_DIR=$(fm_test_tmproot fm-mem-alert)
  CFG="$ROOT_DIR/config"
  PROC="$ROOT_DIR/proc"
  mkdir -p "$CFG"
  make_proc "$PROC"
  HIGH="$ROOT_DIR/meminfo-high"
  LOW="$ROOT_DIR/meminfo-low"
  make_meminfo "$HIGH" 100000 10000 # 90% used
  make_meminfo "$LOW" 100000 40000  # 60% used
  STATE="$ROOT_DIR/state/mem-alert.state"
  OUT="$ROOT_DIR/alert.txt"
}

test_below_threshold_does_not_alert() {
  setup
  run_check "$STATE" "$LOW" "$PROC" "$OUT" || fail "check exited non-zero below threshold"
  [ ! -e "$OUT" ] || fail "no alert should be emitted below the threshold"
  pass "below-threshold sample emits nothing"
}

test_crossing_alerts_once_and_names_the_top_process() {
  setup
  run_check "$STATE" "$HIGH" "$PROC" "$OUT" || fail "check exited non-zero above threshold"
  [ -f "$OUT" ] || fail "crossing should emit an alert"
  local body
  body=$(cat "$OUT")
  case "$body" in *"90%"*) ;; *) fail "alert did not report the used percent: $body" ;; esac
  case "$body" in *"top process big pid=200"*) ;; *) fail "alert did not name the top process: $body" ;; esac
  [ "$(cat "$STATE")" = fired ] || fail "state should be fired after alerting"
  # A second sample while still above the threshold must not alert again.
  rm -f "$OUT"
  run_check "$STATE" "$HIGH" "$PROC" "$OUT" || fail "second check exited non-zero"
  [ ! -e "$OUT" ] || fail "a sustained high sample must not re-alert"
  pass "one alert per crossing, naming the top process"
}

test_rearms_below_threshold_and_alerts_again() {
  setup
  run_check "$STATE" "$HIGH" "$PROC" "$OUT" || fail "first crossing failed"
  [ "$(cat "$STATE")" = fired ] || fail "state should be fired"
  rm -f "$OUT"
  make_meminfo "$LOW" 100000 20000
  run_check "$STATE" "$LOW" "$PROC" "$OUT" || fail "clear check exited non-zero"
  [ ! -e "$OUT" ] || fail "clearing must not alert"
  [ "$(cat "$STATE")" = armed ] || fail "state should re-arm below the threshold"
  run_check "$STATE" "$HIGH" "$PROC" "$OUT" || fail "second crossing failed"
  [ -f "$OUT" ] || fail "a re-armed host should alert on the next crossing"
  pass "crossing re-arms below the threshold and alerts again"
}

test_regular_scan_finds_the_largest_process() {
  setup
  make_proc "$PROC"
  # Add a larger process that must win over pid 200.
  mkdir -p "$PROC/300"
  printf 'Name: huge\nVmRSS:   %s kB\n' 900000 > "$PROC/300/status"
  printf 'huge\n' > "$PROC/300/comm"
  run_check "$STATE" "$HIGH" "$PROC" "$OUT" || fail "check exited non-zero"
  case "$(cat "$OUT")" in
    *"top process huge pid=300"*) ;;
    *) fail "the largest RSS process should be named: $(cat "$OUT")" ;;
  esac
  pass "top process is the largest resident set, not the first seen"
}

test_status_reports_thresholds_and_state() {
  setup
  local out
  out=$(FM_CONFIG_OVERRIDE="$CFG" FM_MEM_ALERT_MEMINFO="$HIGH" FM_MEM_ALERT_STATE="$STATE" "$ALERT" status) \
    || fail "status exited non-zero"
  case "$out" in *"threshold-percent=85"*) ;; *) fail "status did not report the threshold: $out" ;; esac
  case "$out" in *"used-percent=90"*) ;; *) fail "status did not report the sample: $out" ;; esac
  case "$out" in *"state=armed"*) ;; *) fail "status did not report the state: $out" ;; esac
  pass "status reports thresholds, sample, and state"
}

test_below_threshold_does_not_alert
test_crossing_alerts_once_and_names_the_top_process
test_rearms_below_threshold_and_alerts_again
test_regular_scan_finds_the_largest_process
test_status_reports_thresholds_and_state
