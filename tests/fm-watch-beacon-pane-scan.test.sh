#!/usr/bin/env bash
# tests/fm-watch-beacon-pane-scan.test.sh - the watcher liveness beacon stays
# fresh as a slow-but-advancing pane scan completes work (firstmate #8095),
# while a single window whose current-state read hangs past the grace still
# reads stale. The beacon is progress-based, not timer-based: it moves once per
# completed window, so a scan that keeps finishing bounded reads never trips the
# stale grace even when the whole scan outlasts it, and a single read that
# outlasts the grace still does. A longer grace or a background ticker would
# hide a watcher hung inside one read, so neither is acceptable here.
#
# These cases drive a real fm-watch.sh subprocess with a fake tmux and a fake
# fm-crew-state.sh that sleeps a bounded number of seconds, then records the
# beacon's age at the moment it answers. Two windows with a first-sight stale
# pane each spend one such read; one window with an over-grace read does the
# hung direction.
#
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-beacon-pane-scan-tests)

# Replace make_case's canned fake fm-crew-state.sh with one that sleeps
# FM_FAKE_CREW_SLEEP seconds, records the beacon age (now - beacon mtime) to
# FM_FAKE_AGE_LOG as "<id>\t<age>", then answers a working run-step verdict so
# the stale path absorbs and keeps polling instead of surfacing a wake.
install_beacon_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
sleep "${FM_FAKE_CREW_SLEEP:-3}"
now=$(date +%s)
if [ "$(uname)" = Darwin ]; then
  mtime=$(/usr/bin/stat -f %m "${FM_FAKE_BEAT:?}" 2>/dev/null)
else
  mtime=$(stat -c %Y "${FM_FAKE_BEAT:?}" 2>/dev/null)
fi
printf '%s\t%s\n' "$id" "$(( now - mtime ))" >> "${FM_FAKE_AGE_LOG:?}"
printf 'state: working · source: run-step · repro\n'
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

# Record a window whose pane is already stably stale at <text>'s hash with a
# count of 1, so the very next scan sees it stale for the first time and spends
# one current-state read (the costly half of the stale path).
prime_stable_pane() {  # <state> <window> <task> <text>
  local state=$1 window=$2 task=$3 text=$4 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/$task.meta"
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}

# Launch the watcher against a case-local state/config with the fake tmux and
# fake crew-state on PATH. The pane capture serves one idle text for every
# window; the beacon path and age log are passed to the fake crew-state.
run_beacon_watcher() {  # <state> <fakebin> <out> <pane-file> <grace> <sleep> <age-log>
  local state=$1 fakebin=$2 out=$3 pane=$4 grace=$5 sleep_secs=$6 age_log=$7
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$(dirname "$state")/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_SLEEP="$sleep_secs" FM_FAKE_BEAT="$state/.last-watcher-beat" \
    FM_FAKE_AGE_LOG="$age_log" \
    FM_WATCHER_STALE_GRACE="$grace" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$out" 2>&1 &
}

# Wait until <log> holds at least <n> lines, or the watcher exited first.
wait_age_lines() {  # <log> <n> <pid>
  local log=$1 n=$2 pid=$3 i=0 lines
  while [ "$i" -lt 300 ]; do
    lines=0
    [ -f "$log" ] && lines=$(wc -l < "$log" | tr -d '[:space:]')
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    [ "$lines" -ge "$n" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The nth recorded age line, or nothing.
age_line_n() {  # <log> <n>
  awk -F '\t' -v n="$2" 'NR == n { print $2 }' "$1" 2>/dev/null
}

# A slow-but-advancing scan: two windows each spend a bounded current-state read
# (3s) on their first-sight stale poll. The second window's read must record a
# beacon age under the 5s grace, because the beacon moved after the first
# window's read completed. Before the fix the second read recorded ~7s and the
# live watcher read as stale.
test_slow_advancing_scan_keeps_beacon_fresh() {
  local dir state fakebin out pane pid second_age
  dir=$(make_case slow-advancing-scan); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  install_beacon_crew_state "$fakebin"
  pane="$dir/pane.txt"
  printf '%s' 'idle pane, nothing happening here' > "$pane"
  prime_stable_pane "$state" "test:winA" "a" "$(cat "$pane")"
  prime_stable_pane "$state" "test:winB" "b" "$(cat "$pane")"
  run_beacon_watcher "$state" "$fakebin" "$out" "$pane" 5 3 "$dir/ages.log"
  pid=$!
  if ! wait_age_lines "$dir/ages.log" 2 "$pid"; then
    reap "$pid"; fail "slow scan did not record two current-state reads: $(cat "$dir/ages.log" 2>/dev/null) out=$(cat "$out")"
  fi
  reap "$pid"
  second_age=$(age_line_n "$dir/ages.log" 2)
  case "$second_age" in
    ''|*[!0-9]*) fail "second window's beacon age was not a number: '$second_age'" ;;
  esac
  [ "$second_age" -lt 5 ] || fail "second window's read recorded beacon age ${second_age}s, expected under the 5s grace (ages: $(cat "$dir/ages.log"))"
  pass "a slow-but-advancing two-window scan keeps the beacon inside the grace"
}

# A single hung read: one window whose current-state read sleeps 6s, past the
# 5s grace. The beacon must still read stale, because nothing touches it until
# that read returns.
test_single_hung_read_still_reads_stale() {
  local dir state fakebin out pane pid first_age
  dir=$(make_case single-hung-read); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  install_beacon_crew_state "$fakebin"
  pane="$dir/pane.txt"
  printf '%s' 'idle pane, nothing happening here' > "$pane"
  prime_stable_pane "$state" "test:winA" "a" "$(cat "$pane")"
  run_beacon_watcher "$state" "$fakebin" "$out" "$pane" 5 6 "$dir/ages.log"
  pid=$!
  if ! wait_age_lines "$dir/ages.log" 1 "$pid"; then
    reap "$pid"; fail "hung read never recorded a beacon age: out=$(cat "$out")"
  fi
  reap "$pid"
  first_age=$(age_line_n "$dir/ages.log" 1)
  case "$first_age" in
    ''|*[!0-9]*) fail "hung window's beacon age was not a number: '$first_age'" ;;
  esac
  [ "$first_age" -ge 5 ] || fail "a single hung read recorded beacon age ${first_age}s, expected at least the 5s grace (ages: $(cat "$dir/ages.log"))"
  pass "a single window whose read hangs past the grace still reads stale"
}

# The helper wait_poll_cycle must wait a whole poll cycle, not a single
# per-window beacon advance. In a slow scan the liveness beacon moves once per
# window, so a wait keyed on it would return after the first window's read;
# the cycle marker moves once per poll, so wait_poll_cycle returns only after
# BOTH windows' reads complete.
test_wait_poll_cycle_waits_a_full_slow_scan_cycle() {
  local dir state fakebin out pane pid lines
  dir=$(make_case wait-poll-cycle-slow); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  install_beacon_crew_state "$fakebin"
  pane="$dir/pane.txt"
  printf '%s' 'idle pane, nothing happening here' > "$pane"
  prime_stable_pane "$state" "test:winA" "a" "$(cat "$pane")"
  prime_stable_pane "$state" "test:winB" "b" "$(cat "$pane")"
  run_beacon_watcher "$state" "$fakebin" "$out" "$pane" 5 3 "$dir/ages.log"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" 300; then
    reap "$pid"; fail "watcher did not complete a whole poll cycle: $(cat "$out")"
  fi
  reap "$pid"
  lines=$(wc -l < "$dir/ages.log" | tr -d '[:space:]')
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  [ "$lines" -ge 2 ] \
    || fail "wait_poll_cycle returned before the full slow scan finished: only $lines read(s) recorded (ages: $(cat "$dir/ages.log"))"
  pass "wait_poll_cycle waits a whole slow-scan cycle (both windows read), not a single per-window beacon advance"
}

# Optional function names allow focused regression verification without running
# unrelated watcher scenarios.
if [ "$#" -gt 0 ]; then
  for test_name in "$@"; do
    case "$test_name" in test_*) "$test_name" || exit 1 ;; *) exit 2 ;; esac
  done
  exit 0
fi

test_slow_advancing_scan_keeps_beacon_fresh || exit 1
test_single_hung_read_still_reads_stale
test_wait_poll_cycle_waits_a_full_slow_scan_cycle
