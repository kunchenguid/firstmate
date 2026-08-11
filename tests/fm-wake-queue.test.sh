#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, signal catch-up while no watcher runs, stale/check
# enqueue-before-suppressor ordering, atomic double-drain, duplicate collapse,
# and the drain-time watcher-liveness assertion.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

# Concurrency contract: keep all 40 queue-safety append records and assertions,
# but cap append workers at three regardless of input size. Every submission at
# the limit blocks while the pool waits for its oldest PID, making the cap
# absolute rather than a proportional reduction from the incident's 62
# processes. The bounded path starts one unpooled drain helper, so the effective
# background ceiling is three append workers plus that constant helper: four
# background processes, or five test-script processes including this root.
# The concurrency-bound probe simulates a slow host, continuously records every
# process transition under a serialized counter, and measures the historical
# 10-process sample against the bounded 5-process sample.
WAKE_QUEUE_TEST_PROCESS_BOUND=5
WAKE_QUEUE_TEST_APPEND_WORKERS=$((WAKE_QUEUE_TEST_PROCESS_BOUND - 2))

fm_test_tmproot_into TMP_ROOT fm-wake-tests


wake_process_counter_change() {  # <counter-dir> <delta> <bound> <ready-at>
  local counter_dir=$1 delta=$2 bound=$3 ready_at=$4 active peak
  while ! mkdir "$counter_dir/lock" 2>/dev/null; do
    sleep 0.01
  done
  active=$(cat "$counter_dir/active")
  peak=$(cat "$counter_dir/peak")
  active=$((active + delta))
  printf '%s\n' "$active" > "$counter_dir/active"
  if [ "$active" -gt "$peak" ]; then
    peak=$active
    printf '%s\n' "$peak" > "$counter_dir/peak"
  fi
  if [ "$active" -gt "$bound" ]; then
    printf '%s > %s\n' "$active" "$bound" > "$counter_dir/violation"
  fi
  if [ "$ready_at" -gt 0 ] && [ "$active" -eq "$ready_at" ]; then
    : > "$counter_dir/ready"
  fi
  rmdir "$counter_dir/lock"
}

wake_slow_host_process() {  # <counter-dir> <bound> <ready-at> <gate> <command> [args...]
  local counter_dir=$1 bound=$2 ready_at=$3 gate=$4 status
  shift 4
  wake_process_counter_change "$counter_dir" 1 "$bound" "$ready_at" || return 1
  if [ -n "$gate" ]; then
    if ! fm_test_wait_for_file "$gate"; then
      wake_process_counter_change "$counter_dir" -1 "$bound" 0 || true
      return 1
    fi
  fi
  # This injected residence time simulates operations progressing slowly on a
  # saturated host without creating synthetic CPU or memory pressure.
  sleep 0.20
  if "$@"; then status=0; else status=$?; fi
  wake_process_counter_change "$counter_dir" -1 "$bound" 0 || true
  return "$status"
}

wake_probe_drain() {  # <state> <output>
  FM_STATE_OVERRIDE="$1" "$DRAIN" > "$2"
}

run_slow_host_process_probe() {  # <unbounded|bounded> <peak-var>
  local mode=$1 peak_var=$2 dir state counter gate drain_out final_out pids pid i peak count process_bound ready_at drain_pid
  dir=$(make_case "slow-host-$mode")
  state="$dir/state"
  counter="$dir/counter"
  gate="$dir/release"
  drain_out="$dir/drain.out"
  final_out="$dir/final.out"
  mkdir -p "$counter"
  # Count the suite's root process from the outset, then have every background
  # test-script process register its exact enter/exit transitions under a lock.
  printf '1\n' > "$counter/active"
  printf '1\n' > "$counter/peak"
  pids=

  case "$mode" in
    unbounded)
      process_bound=10
      ready_at=10
      i=1
      while [ "$i" -le 8 ]; do
        wake_slow_host_process "$counter" "$process_bound" "$ready_at" "$gate" \
          append_wake "$state" signal "probe-$i" "signal: $state/probe-$i.status" &
        pids="${pids:+$pids }$!"
        i=$((i + 1))
      done
      wake_slow_host_process "$counter" "$process_bound" "$ready_at" "$gate" \
        wake_probe_drain "$state" "$drain_out" &
      pids="${pids:+$pids }$!"
      fm_test_wait_for_file "$counter/ready" || fail "unbounded slow-host workers did not reach their historical peak"
      : > "$gate"
      for pid in $pids; do
        wait "$pid" || fail "unbounded slow-host probe subprocess failed"
      done
      ;;
    bounded)
      process_bound=$WAKE_QUEUE_TEST_PROCESS_BOUND
      ready_at=$WAKE_QUEUE_TEST_PROCESS_BOUND
      wake_test_pool_start "$WAKE_QUEUE_TEST_APPEND_WORKERS" \
        || fail "could not initialize the bounded wake-test worker pool"
      i=1
      while [ "$i" -le "$WAKE_QUEUE_TEST_APPEND_WORKERS" ]; do
        wake_test_pool_submit wake_slow_host_process "$counter" "$process_bound" "$ready_at" "$gate" \
          append_wake "$state" signal "probe-$i" "signal: $state/probe-$i.status"
        i=$((i + 1))
      done
      wake_slow_host_process "$counter" "$process_bound" "$ready_at" "$gate" \
        wake_probe_drain "$state" "$drain_out" &
      drain_pid=$!
      fm_test_wait_for_file "$counter/ready" "$drain_pid" \
        || fail "bounded slow-host workers did not fill the declared process bound"
      : > "$gate"
      while [ "$i" -le 8 ]; do
        wake_test_pool_submit wake_slow_host_process "$counter" "$process_bound" 0 "" \
          append_wake "$state" signal "probe-$i" "signal: $state/probe-$i.status"
        i=$((i + 1))
      done
      wake_test_pool_finish || fail "bounded slow-host append subprocess failed"
      wait "$drain_pid" || fail "bounded slow-host drain subprocess failed"
      ;;
    *) fail "unknown slow-host process-probe mode: $mode" ;;
  esac

  [ ! -e "$counter/violation" ] \
    || fail "$mode slow-host process bound was exceeded: $(cat "$counter/violation")"
  [ "$(cat "$counter/active")" -eq 1 ] \
    || fail "$mode slow-host process counter did not return to the root process"
  peak=$(cat "$counter/peak")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$final_out" || fail "$mode slow-host final drain failed"
  count=$(cat "$drain_out" "$final_out" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 8 ] || fail "$mode slow-host probe lost wake coverage; expected 8 records, got $count"
  printf -v "$peak_var" '%s' "$peak"
}

test_process_bound_under_simulated_slow_host() {
  local unbounded_peak bounded_peak
  run_slow_host_process_probe unbounded unbounded_peak
  run_slow_host_process_probe bounded bounded_peak
  [ "$unbounded_peak" -eq 10 ] \
    || fail "historical slow-host process peak was $unbounded_peak instead of 10"
  [ "$bounded_peak" -eq "$WAKE_QUEUE_TEST_PROCESS_BOUND" ] \
    || fail "bounded slow-host process peak was $bounded_peak instead of $WAKE_QUEUE_TEST_PROCESS_BOUND"
  pass "simulated slow-host process peak: unbounded=$unbounded_peak bounded=$bounded_peak"
}


test_concurrent_append_and_drain() {
  local dir state out1 out2 all i drain_pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  wake_test_pool_start "$WAKE_QUEUE_TEST_APPEND_WORKERS" \
    || fail "could not initialize the bounded wake-test worker pool"
  i=1
  while [ "$i" -le "$WAKE_QUEUE_TEST_APPEND_WORKERS" ]; do
    wake_test_pool_submit append_wake "$state" signal "status-$i" "signal: $state/status-$i.status"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  drain_pid=$!
  while [ "$i" -le 40 ]; do
    wake_test_pool_submit append_wake "$state" signal "status-$i" "signal: $state/status-$i.status"
    i=$((i + 1))
  done
  wake_test_pool_finish || fail "concurrent append subprocess failed"
  wait "$drain_pid" || fail "concurrent drain subprocess failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crewmate is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crewmate
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%s:%Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crewmate is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%s:%Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_keeps_exclusive_staging_reserved_until_rename() {
  local dir state fakebin out real_mv
  dir=$(make_case reserved-drain)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/drain.out"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
[ -f "$2" ] && [ ! -L "$2" ] || exit 92
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  append_wake "$state" signal task "signal: $state/task.status" || fail "reserved staging append failed"
  PATH="$fakebin:$PATH" FM_REAL_MV="$real_mv" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain released its exclusive staging path before rename"
  grep "$(printf '\tsignal\ttask\t')" "$out" >/dev/null \
    || fail "reserved staging drain lost its wake record"
  pass "wake drain keeps exclusive staging reserved through rename"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire (a fresh beacon within grace), so it never false-alarms every wake.
test_drain_asserts_watcher_liveness() {
  local dir state err
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  touch "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" || fail "drain failed with a fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed right after a normal fire (fresh beacon within grace)"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent right after a fire"
}

if [ "${FM_TEST_FOCUSED:-}" = reserved-staging ]; then
  test_drain_keeps_exclusive_staging_reserved_until_rename
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = concurrency-bound ]; then
  test_process_bound_under_simulated_slow_host
  exit 0
fi

test_process_bound_under_simulated_slow_host
test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_keeps_exclusive_staging_reserved_until_rename
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
