#!/usr/bin/env bash
# Behavior tests for the host memory guard (bin/fm-jev-mem-guard.sh): its
# verdicts and recorded samples against a fixture proc tree, the owner mapping
# that names the largest consumers by task, and the watcher tick that turns an
# ALERT into exactly one wake per episode.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GUARD="$ROOT/bin/fm-jev-mem-guard.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-mem-guard)
export FM_HOST_MEMORY_CGROUP_ROOT="$TMP_ROOT/no-cgroup"
export FM_ADDONS_DIR="${FM_ADDONS_DIR:-${FM_HOME:-$ROOT}/projects/firstmate-addons}"
APP_SLICE="user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"

# fake_host <proc> <available-gb> <pressure (both 10 s and 60 s averages)> [swap-used-gb]
fake_host() {
  local proc=$1 swap_used=${4:-0}
  mkdir -p "$proc/pressure"
  printf 'MemTotal:       67108864 kB\nMemAvailable:   %s kB\nSwapTotal:      33554432 kB\nSwapFree:       %s kB\n' \
    "$(($2 * 1048576))" "$((33554432 - swap_used * 1048576))" > "$proc/meminfo"
  printf 'some avg10=%s avg60=%s avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$3" "$3" \
    > "$proc/pressure/memory"
  mkdir -p "$(dirname "$proc")/cgroup/$APP_SLICE"
  printf 'some avg10=%s avg60=%s avg300=1.00 total=1\n' "$3" "$3" > "$(dirname "$proc")/cgroup/$APP_SLICE/memory.pressure"
}

# fake_pid <proc> <pid> <name> <rss-gb> <cwd> [FM_TASK_ID]
fake_pid() {
  local dir="$1/$2"
  mkdir -p "$dir"
  printf 'Name:\t%s\nVmRSS:\t%s kB\nVmSwap:\t0 kB\n' "$3" "$(($4 * 1048576))" > "$dir/status"
  ln -s "$5" "$dir/cwd"
  if [ -n "${6:-}" ]; then printf 'PATH=/bin\0FM_TASK_ID=%s\0' "$6" > "$dir/environ"; else printf 'PATH=/bin\0' > "$dir/environ"; fi
}

# A home with one ship task, one lead, and processes owned by the task (by
# working directory and a path-qualified FM_TASK_ID), by the lead,
# and by nothing Firstmate records.
make_fleet() {
  local case=$1
  mkdir -p "$case/state" "$case/wt/sub" "$case/mate/state"
  fm_write_meta "$case/state/big-build.meta" kind=ship "worktree=$case/wt"
  fm_write_meta "$case/state/sm1.meta" kind=secondmate "home=$case/mate"
  fake_pid "$case/proc" 101 node 9 "$case/wt/sub"
  fake_pid "$case/proc" 102 java 5 "$case/wt" big-build
  fake_pid "$case/proc" 103 claude 2 "$case/mate"
  fake_pid "$case/proc" 104 llama 6 /
}

test_verdicts_samples_and_owners() {
  local case=$TMP_ROOT/verdicts out rc tsv
  case=$TMP_ROOT/verdicts tsv=$case/state/host-memory.tsv
  make_fleet "$case"
  fake_host "$case/proc" 40 2.5 1
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --record "$tsv" --state-dir "$case" "$case/state")
  assert_equals $'OK\tpressure 2% (lower of 10 s and 60 s averages), 40.0 GB available, 1.0 GB swap used; host 2%, app.slice 2%' "$out" "calm host"
  fake_host "$case/proc" 30 24 3
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --record "$tsv" --state-dir "$case" "$case/state")
  assert_equals $'WAIT\tpressure 24% (lower of 10 s and 60 s averages), 30.0 GB available, 3.0 GB swap used; host 24%, app.slice 24%; pressure at or above 20%' "$out" \
    "pressure past the wait threshold makes new agents wait"
  fake_host "$case/proc" 5 41.2 16
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --record "$tsv" --state-dir "$case" "$case/state")
  assert_equals $'ALERT\tpressure 41% (lower of 10 s and 60 s averages), 5.0 GB available, 16.0 GB swap used; host 41%, app.slice 41%; pressure at or above 35%; available memory below 6 GB; largest: task big-build (main) 14.0 GB in 2 processes, llama pid 104 6.0 GB, lead sm1 2.0 GB' "$out" \
    "an alert names the largest consumers by task, lead, or process"
  [ "$(wc -l < "$tsv" | tr -d ' ')" -eq 3 ] || fail "three samples should be recorded: $(cat "$tsv")"
  assert_equals $'5242880\t16777216\t41.20\tALERT' "$(tail -n 1 "$tsv" | cut -f2-)" "the sample row carries available kB, swap kB, pressure, verdict"
  # Thresholds come from the one config file; a broken one is refused with its line.
  printf '# tighter host\nalert_pressure=50\nalert_available_gb=1\nwait_pressure = 10\n' > "$case/host-memory"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --config "$case/host-memory")
  assert_contains "$out" "pressure at or above 10%" "config thresholds replace the defaults"
  printf 'alert_pressure=lots\n' > "$case/host-memory"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --config "$case/host-memory" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an invalid config must exit 2, got $rc: $out"
  assert_contains "$out" "line 1: 'alert_pressure=lots'" "the invalid line is named"
  # Not measurable: no verdict is invented and nothing is recorded.
  out=$(FM_HOST_MEMORY_PROC="$case/none" "$GUARD" --record "$tsv")
  assert_contains "$out" "UNKNOWN" "an unmeasurable host reads unknown"
  [ "$(wc -l < "$tsv" | tr -d ' ')" -eq 3 ] || fail "an unmeasurable sample was recorded"
  pass "verdicts, recorded samples, and owner mapping follow the host"
}

# One watcher run against the case; legs that must wake exit on their own.
watch_leg() {
  local case=$1 tag=$2
  env PATH="$case/fakebin:$PATH" FM_HOME="$case" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="${5:-$case/state}" \
    FM_CREW_STATE_BIN="$case/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: working · source: run-step · fixture build' TMUX='' FM_BACKEND=tmux \
    FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" FM_HOST_MEMORY_SECS="${3:-1}" FM_SECONDMATE_LIVENESS_SECS="${4:-99999999}" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$case/watch-$tag.out" 2> "$case/watch-$tag.err" &
  LEG_PID=$!
}

drain_and_ack() {
  local state="$1/state" seq gen
  FM_HOME="$1" FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$1/drain.err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' "$1/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$1/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_HOME="$1" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2>&1 || true
}

# wait_rows <tsv> <n>: wait up to 30 s for the watcher to have recorded n samples.
wait_rows() {
  local i=0
  while [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -lt "$2" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(wc -l < "$1")" -ge "$2" ] || fail "the watcher did not record sample $2: $(cat "$1" "${1%/state/*}"/watch-*.out)"
}

wait_interrupt() {
  local state=$1 expected=${2:-1} i=0 count
  while [ "$i" -lt 100 ]; do
    count=$(grep -c 'automatically interrupted task big-build:' "$state/host-memory-interrupts.tsv" 2>/dev/null || true)
    [ "${count:-0}" -lt "$expected" ] || return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "automatic interrupt did not complete: $(cat "$state/host-memory-interrupts.tsv" "$state/.host-memory-sampler.log")"
}

prepare_control_task() {
  local case=$1
  fm_write_meta "$case/state/big-build.meta" kind=ship harness=pi window=firstmate:fm-big-build "worktree=$case/wt" "project=$case/wt"
  cat > "$case/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf '%s\n' fm-big-build fm-sm1 ;;
  display-message)
    case "$*" in *fm-sm1*pane_current_command*) printf 'zsh\n' ;; *pane_current_command*) printf 'pi\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'idle\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_HOME/keys" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case/fakebin/tmux"
}

test_watcher_wakes_once_per_alert_episode() {
  local case out
  case=$(make_case alert)
  make_fleet "$case"
  fake_host "$case/proc" 5 41.2 16
  prepare_control_task "$case"
  watch_leg "$case" alert default
  wait_for_exit "$LEG_PID" 50 || fail "the watcher did not wake on a memory alert: $(cat "$case/watch-alert.err")"
  wait_interrupt "$case/state"
  out=$(cat "$case/watch-alert.out")
  assert_contains "$out" "check: host memory ALERT: pressure 41% (lower of 10 s and 60 s averages)" "the alert wake names the pressure"
  assert_contains "$out" "largest: task big-build (main) 14.0 GB in 2 processes" "the alert wake names the largest task"
  [ "$(grep -c $'\tcheck\thost-memory\t' "$case/state/.wake-queue")" -eq 1 ] \
    || fail "the alert was not queued durably exactly once: $(cat "$case/state/.wake-queue")"
  [ -s "$case/state/host-memory.tsv" ] || fail "the watcher did not record the sample"
  assert_contains "$(cat "$case/keys")" 'send-keys -t firstmate:fm-big-build Escape' "the watcher uses the public control plane to interrupt"
  [ "$(wc -l < "$case/keys")" -eq 1 ] || fail "one interrupt key expected"
  assert_contains "$(cat "$case/state/host-memory-interrupts.tsv")" 'automatically interrupted task big-build' "the interrupt outcome is durable"
  assert_contains "$out" 'automatic interrupt attempted: task big-build' "Main receives the interrupt reason and task"

  # A handling successor starts BEFORE acknowledgement. The same queued alert
  # must not close it before its owner can establish continuity and drain it.
  FM_WATCH_HANDLING_SUCCESSOR=1 watch_leg "$case" successor
  wait_rows "$case/state/host-memory.tsv" 2
  is_live_non_zombie "$LEG_PID" || fail "unacknowledged alert killed the handling successor: $(cat "$case/watch-successor.out")"
  [ ! -s "$case/watch-successor.out" ] || fail "the handling successor re-delivered the queued alert"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true

  # Still under alert: the episode is latched, so the next watcher stays quiet.
  drain_and_ack "$case"
  watch_leg "$case" latched
  wait_rows "$case/state/host-memory.tsv" 3
  is_live_non_zombie "$LEG_PID" || fail "a latched alert woke again: $(cat "$case/watch-latched.out")"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  [ "$(wc -l < "$case/keys")" -eq 1 ] || fail "the latched episode interrupted again"

  # An OK sample ends the episode; the next alert wakes again.
  fake_host "$case/proc" 40 2
  drain_and_ack "$case"
  watch_leg "$case" calm
  wait_rows "$case/state/host-memory.tsv" "$(( $(wc -l < "$case/state/host-memory.tsv") + 1 ))"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  [ ! -e "$case/state/.host-memory-alerted" ] || fail "an OK sample did not clear the alert latch: $(tail -n 3 "$case/state/host-memory.tsv")"
  fake_host "$case/proc" 5 41.2 16
  drain_and_ack "$case"
  watch_leg "$case" again
  wait_for_exit "$LEG_PID" 300 || fail "a new alert episode did not wake"
  assert_contains "$(cat "$case/watch-again.out")" "check: host memory ALERT" "the second episode wakes"
  wait_interrupt "$case/state" 2
  [ "$(wc -l < "$case/keys")" -eq 2 ] || fail "the new episode did not interrupt once"
  fake_host "$case/proc" 40 2
  drain_and_ack "$case"
  watch_leg "$case" calm-foreign
  wait_rows "$case/state/host-memory.tsv" "$(( $(wc -l < "$case/state/host-memory.tsv") + 1 ))"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  fake_pid "$case/proc" 105 foreign 25 / big-build
  fake_host "$case/proc" 5 41
  drain_and_ack "$case"
  watch_leg "$case" foreign
  wait_for_exit "$LEG_PID" 300 || fail "a foreign top consumer did not wake Main"
  assert_contains "$(cat "$case/watch-foreign.out")" 'foreign pid 105 25.0 GB' "the skipped top consumer is named"
  assert_contains "$(cat "$case/watch-foreign.out")" 'automatic interrupt skipped' "foreign ownership is reported"
  [ "$(wc -l < "$case/keys")" -eq 2 ] || fail "a foreign top consumer caused an interrupt"
  pass "the watcher samples memory and interrupts once per alert episode, naming the largest task"
}

test_fast_spike_waits_without_alert() {
  local case out rc app
  app="user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"
  case=$(make_case fast-spike)
  make_fleet "$case"
  prepare_control_task "$case"
  fake_host "$case/proc" 20 2
  printf 'some avg10=40 avg60=10 avg300=2 total=1\n' > "$case/cgroup/$app/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 1 ] || fail "a 10 s spike with ample memory admitted work: $out"
  watch_leg "$case" fast-spike default
  wait_rows "$case/state/host-memory.tsv" 2
  is_live_non_zombie "$LEG_PID" || fail "a 10 s spike woke Main: $(cat "$case/watch-fast-spike.out")"
  assert_equals WAIT "$(cut -f5 "$case/state/host-memory.tsv" | sort -u)" "a 10 s spike records WAIT, not ALERT"
  [ ! -e "$case/keys" ] || fail "a 10 s spike interrupted a task: $(cat "$case/keys")"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  pass "a 10 s app.slice spike with ample memory waits without alerting or interrupting"
}

test_cgroup_pressure() {
  local case=$TMP_ROOT/cgroup out rc app
  app="user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"
  mkdir -p "$case/cgroup/$app" "$case/state"
  fake_host "$case/proc" 40 2
  # A 10 s spike that the sustained average has not caught up with holds admission as WAIT.
  printf 'some avg10=60 avg60=8 avg300=2 total=1\n' > "$case/cgroup/$app/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 1 ] || fail "a fast app.slice spike admitted work: $out"
  assert_contains "$out" '10 s pressure at or above 35%' "the fast spike names its reason"
  printf 'some avg10=24 avg60=30 avg300=0 total=1\n' > "$case/cgroup/$app/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD")
  assert_contains "$out" $'WAIT\tpressure 24%' "sustained app.slice pressure makes new agents wait"
  assert_contains "$out" 'host 2%, app.slice 24%' "host and app.slice are both visible"
  # A capped sibling slice thrashing (fm-heavy at its swap cap) is contained by design:
  # it must not reach the verdict while app.slice is calm.
  mkdir -p "$case/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/fm.slice/fm-heavy.slice"
  printf 'some avg10=95 avg60=90 avg300=50 total=1\n' > "$case/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/fm.slice/fm-heavy.slice/memory.pressure"
  printf 'some avg10=1 avg60=1 avg300=1 total=1\n' > "$case/cgroup/$app/memory.pressure"
  fake_host "$case/proc" 40 2
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 0 ] || fail "sibling heavy-slice thrash refused admission: $out"
  # Host-wide pressure with a calm app.slice holds nothing and interrupts nothing.
  fake_host "$case/proc" 40 48
  printf 'some avg10=1 avg60=1 avg300=1 total=1\n' > "$case/cgroup/$app/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 0 ] || fail "host-wide pressure refused admission with a calm app.slice: $out"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD")
  assert_contains "$out" $'OK\tpressure 1%' "host-wide pressure is not a verdict"
  assert_contains "$out" 'host 48%, app.slice 1%' "host-wide pressure stays visible as context"
  # Unreadable app.slice pressure is not judged, so host-wide pressure cannot hold a launch either.
  rm "$case/cgroup/$app/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 0 ] || fail "unreadable app.slice pressure held admission on host-wide pressure: $out"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD")
  assert_contains "$out" $'OK\tapp.slice pressure unreadable, not judged' "unreadable app.slice pressure is not judged"
  pass "app.slice pressure alone governs admission; host-wide pressure is context only"
}

test_host_pressure_neither_holds_nor_wakes() {
  local case out rc app
  app="user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"
  case=$(make_case host-only)
  make_fleet "$case"
  prepare_control_task "$case"
  fake_host "$case/proc" 40 48
  printf 'some avg10=3 avg60=3 avg300=1 total=1\n' > "$case/cgroup/$app/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 0 ] || fail "host-wide pressure held an admission with a calm app.slice: $out"
  watch_leg "$case" host-only default
  wait_rows "$case/state/host-memory.tsv" 2
  is_live_non_zombie "$LEG_PID" || fail "host-wide pressure woke Main: $(cat "$case/watch-host-only.out")"
  assert_equals OK "$(cut -f5 "$case/state/host-memory.tsv" | sort -u)" "host-wide samples record OK"
  [ ! -e "$case/keys" ] || fail "host-wide pressure interrupted a task: $(cat "$case/keys")"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  pass "host-wide pressure neither holds admission nor wakes Main or interrupts a task"
}

test_home_qualified_owners() {
  local case=$TMP_ROOT/owners out
  make_fleet "$case"
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 107 foreign 25 "$TMP_ROOT/independent-home/wt" big-build
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --owned-top-task "$case/state")
  assert_contains "$out" 'foreign pid 107 25.0 GB, task big-build (main) 14.0 GB in 2 processes' "a unique visible ID still requires recorded path ownership"
  assert_equals '' "${out##*$'\t'}" "an independent home's matching ID cannot authorize control"
  fm_write_meta "$case/state/big-build.meta" kind=ship "worktree=$case/wt" "tasktmp=${case}-tmp"
  rm "$case/proc/107/cwd"
  ln -s "${case}-tmp" "$case/proc/107/cwd"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --owned-top-task "$case/state")
  assert_contains "$out" "foreign pid 107 25.0 GB" "a temp path outside the explicit home is not a worktree"
  assert_equals '' "${out##*$'\t'}" "an external temp path cannot authorize control"
  rm -r "$case/proc/107"
  fm_write_meta "$case/mate/state/big-build.meta" kind=ship "worktree=$case/mate/wt"
  mkdir -p "$case/mate/wt"
  fake_pid "$case/proc" 105 java 20 "$case/mate/wt" big-build
  fake_pid "$case/proc" 106 node 10 "$case/mate" big-build
  rm "$case/proc/102/cwd"
  ln -s "$case/wt" "$case/proc/102/cwd"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
  assert_contains "$out" 'task big-build (sm1) 30.0 GB in 2 processes, task big-build (main) 14.0 GB in 2 processes' "equal task IDs remain separate owners"
  assert_equals '' "${out##*$'\t'}" "a foreign top task cannot be interrupted by this home"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/mate/state")
  assert_equals big-build "${out##*$'\t'}" "the owning home receives its exact task ID"
  printf 'Name:\tpi\nVmRSS:\t41943040 kB\nVmSwap:\t0 kB\n' > "$case/proc/103/status"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
  assert_equals sm1 "${out##*$'\t'}" "a lead is controlled only through its parent-owned task record"
  pass "task ownership stays home-qualified through grouping and control selection"
}

test_homes_without_ordinary_tasks() {
  local case=$TMP_ROOT/home-fallback mode out
  mkdir -p "$case/mate/state"
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 101 pi 9 "$case"
  fake_pid "$case/proc" 102 claude 9 "$case"
  fake_pid "$case/proc" 103 pi 10 "$case/mate"
  fake_pid "$case/proc" 104 claude 10 "$case/mate"
  fake_pid "$case/proc" 105 java 15 "$TMP_ROOT/unowned-a"
  fake_pid "$case/proc" 106 node 14 "$TMP_ROOT/unowned-b"
  for mode in missing empty secondmate remote; do
    case "$mode" in
      empty) mkdir -p "$case/state" ;;
      secondmate) fm_write_meta "$case/state/sm1.meta" kind=secondmate "home=$case/mate" ;;
      remote) fm_write_meta "$case/state/sm1.meta" kind=secondmate remote_host=other "home=$case/mate" ;;
    esac
    out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
    assert_contains "$out" 'lead main 18.0 GB in 2 processes' "$mode home aggregates supervisors into the top three"
    if [ "$mode" = secondmate ]; then
      assert_equals sm1 "${out##*$'\t'}" "secondmate-only state retains parent-owned control"
      out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case/mate" "$case/mate/state" --state-dir "$case" "$case/state" --owned-top-task "$case/mate/state")
      assert_contains "$out" 'largest: lead sm1 20.0 GB in 2 processes, lead main 18.0 GB in 2 processes' "empty child state preserves the parent owner"
      assert_equals '' "${out##*$'\t'}" "child fallback cannot authorize parent-owned control"
      out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
      assert_equals sm1 "${out##*$'\t'}" "parent ownership is independent of argument order"
    else
      assert_equals '' "${out##*$'\t'}" "$mode fallback does not authorize task control"
    fi
  done
  pass "explicit homes aggregate without ordinary tasks and preserve parent ownership"
}

test_remote_records_do_not_own_local_processes() {
  local case=$TMP_ROOT/remote-owners home wt out
  home=$case/main wt=$case/pool/build
  mkdir -p "$home/state" "$wt/sub"
  fm_write_meta "$home/state/big-build.meta" kind=ship "worktree=$wt"
  fm_write_meta "$home/state/a-remote.meta" kind=secondmate remote_host=other "home=$wt"
  fm_write_meta "$home/state/b-remote.meta" kind=ship remote_host=other "worktree=$wt"
  fm_write_meta "$home/state/c-remote.meta" kind=secondmate remote_host=other "home=$home"
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 101 node 9 "$wt/sub"
  fake_pid "$case/proc" 102 java 5 "$wt" big-build
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$home" "$home/state" --owned-top-task "$home/state")
  assert_contains "$out" 'largest: task big-build (main) 14.0 GB in 2 processes' \
    "remote task paths and lead homes cannot steal tagged or untagged local processes"
  assert_equals big-build "${out##*$'\t'}" "the local task remains the interrupt target"
  pass "remote records never own local processes or label local homes"
}

test_overridden_state_ownership() {
  local case state out
  case=$(make_case override/A)
  make_fleet "$case"
  prepare_control_task "$case"
  state="${case}-state"
  mv "$case/state" "$state"
  fm_test_track_watcher_state "$state"
  mkdir -p "$case/data" "$case/mate/wt"
  printf -- '- sm1 - mate (home: %s; scope: test; projects: demo; added 2026-01-01)\n' "$case/mate" > "$case/data/secondmates.md"
  fm_write_meta "$case/mate/state/big-build.meta" kind=ship "worktree=$case/mate/wt"
  fake_pid "$case/proc" 110 node 20 "$case/mate/wt" big-build
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 108 foreign 25 "$TMP_ROOT/override/B/wt" big-build
  watch_leg "$case" foreign-override 1 99999999 "$state"
  wait_for_exit "$LEG_PID" 100 || fail "the overridden-state alert did not wake"
  out=$(cat "$case/watch-foreign-override.out")
  assert_contains "$out" 'foreign pid 108 25.0 GB' "a sibling home remains an unowned consumer"
  assert_contains "$out" 'task big-build (sm1) 20.0 GB' "the sampler passes the registered secondmate home identity"
  assert_contains "$out" 'automatic interrupt skipped' "the foreign matching ID does not authorize control"
  [ ! -s "$case/keys" ] || fail "an overridden state caused the foreign process to interrupt a local task"
  rm -r "$case/proc/108"
  fake_pid "$case/proc" 109 shell 12 "$case" big-build
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --state-dir "$case" "$state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$state")
  assert_contains "$out" 'task big-build (main) 26.0 GB in 3 processes' "the explicit home and recorded worktree both qualify"
  assert_equals big-build "${out##*$'\t'}" "the selected state still authorizes its owned task"
  pass "overridden state paths never widen home ownership"
}

test_finite_thresholds() {
  local case=$TMP_ROOT/thresholds key value out rc
  fake_host "$case/proc" 30 25
  for key in wait_pressure alert_pressure wait_available_gb alert_available_gb; do
    for value in nan inf -inf; do
      printf '%s=%s\n' "$key" "$value" > "$case/config"
      out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --config "$case/config" 2>&1); rc=$?
      [ "$rc" -eq 2 ] || fail "$key=$value should be invalid, got $rc: $out"
    done
  done
  pass "all thresholds reject non-finite numbers"
}

test_alert_rearms_after_wait() {
  local case i=0 tsv
  case=$(make_case rearm)
  make_fleet "$case"
  prepare_control_task "$case"
  tsv=$case/state/host-memory.tsv
  fake_host "$case/proc" 5 41.2 16
  watch_leg "$case" first default
  wait_for_exit "$LEG_PID" 50 || fail "the first alert did not wake Main: $(cat "$case/watch-first.err")"
  wait_interrupt "$case/state"
  drain_and_ack "$case"
  fake_host "$case/proc" 30 24 3
  watch_leg "$case" wait default
  until [ "$(tail -n 1 "$tsv" 2>/dev/null | cut -f5)" = WAIT ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(tail -n 1 "$tsv" 2>/dev/null | cut -f5)" = WAIT ] || fail "the watcher did not record a WAIT sample"
  is_live_non_zombie "$LEG_PID" || fail "a WAIT sample woke Main: $(cat "$case/watch-wait.out")"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  fake_host "$case/proc" 5 41.2 16
  drain_and_ack "$case"
  watch_leg "$case" rearm default
  wait_for_exit "$LEG_PID" 100 || fail "an alert after a WAIT sample did not wake Main: $(cat "$case/watch-rearm.err")"
  wait_interrupt "$case/state" 2
  [ "$(wc -l < "$case/keys")" -eq 2 ] || fail "the re-armed alert did not interrupt once more: $(cat "$case/keys")"
  pass "a WAIT sample ends an alert episode so a later alert wakes and interrupts again"
}

test_benign_liveness_outcomes() {
  local case pid real_ln
  case=$(make_case deferred)
  make_fleet "$case"
  prepare_control_task "$case"
  mkdir -p "$case/config"
  printf 'pi\n' > "$case/config/secondmate-harness"
  fm_write_meta "$case/state/sm1.meta" kind=secondmate harness=pi window=firstmate:fm-sm1 "home=$case/mate"
  fake_host "$case/proc" 30 25
  # Publish the alert after the watcher's queue scan but before its recovery
  # check acquires the queue lock: a late memory row must keep its own reason.
  real_ln=$(command -v ln)
  cat > "$case/fakebin/ln" <<SH
#!/usr/bin/env bash
if [ "\${3:-}" = "\$FM_HOME/state/.wake-queue.lock" ] \\
  && [ "\$PPID" = "\$(cat "\$FM_HOME/state/.watch.lock/pid" 2>/dev/null)" ] \\
  && [ -e "\$FM_HOME/publish-alert" ]; then
  rm "\$FM_HOME/publish-alert"
  printf 'some avg10=41 avg60=41 avg300=1.00 total=1\\n' > "\$FM_HOME/proc/pressure/memory"
  printf 'some avg10=41 avg60=41 avg300=1.00 total=1\\n' > "\$FM_HOME/cgroup/$APP_SLICE/memory.pressure"
  for ((i=0; i<100; i++)); do
    grep -q \$'\\tcheck\\thost-memory\\t' "\$FM_HOME/state/.wake-queue" 2>/dev/null && break
    sleep 0.1
  done
fi
exec "$real_ln" "\$@"
SH
  chmod +x "$case/fakebin/ln"
  watch_leg "$case" wait 1 1
  pid=$LEG_PID
  wait_rows "$case/state/host-memory.tsv" 3
  is_live_non_zombie "$pid" || fail "memory deferral exited the watcher: $(cat "$case/watch-wait.err")"
  [ ! -e "$case/state/.secondmate-relaunch-sm1" ] || fail "a memory deferral consumed the retry budget"
  : > "$case/publish-alert"
  wait_for_exit "$pid" 150 || fail "ALERT did not wake while recovery was deferred"
  wait_interrupt "$case/state"
  assert_contains "$(cat "$case/watch-wait.out")" 'automatic interrupt attempted: task big-build' "deferred recovery does not suppress critical action"

  case=$(make_case endpoint-changed)
  mkdir -p "$case/config" "$case/mate/state"
  printf 'pi\n' > "$case/config/secondmate-harness"
  fm_write_meta "$case/state/sm1.meta" kind=secondmate harness=pi window=firstmate:fm-sm1 "home=$case/mate"
  fake_host "$case/proc" 40 2
  cat > "$case/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-sm1\n' ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        if [ -e "$FM_HOME/probed" ]; then printf 'pi\n'; else : > "$FM_HOME/probed"; printf 'zsh\n'; fi ;;
      *) printf '%%1\n' ;;
    esac ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case/fakebin/tmux"
  watch_leg "$case" changed 1 1
  wait_rows "$case/state/host-memory.tsv" 3
  is_live_non_zombie "$LEG_PID" || fail "an endpoint change exited the watcher"
  assert_contains "$(cat "$case/state/.watch-triage.log")" 'endpoint no longer relaunchable: alive' "the recovery race is classified as a benign deferral"
  kill -TERM "$LEG_PID"; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  pass "memory deferral and endpoint changes keep supervision polling"
}

test_default_home_interrupt() {
  local case state
  case=$(make_case default-home)
  make_fleet "$case"
  prepare_control_task "$case"
  state="$case/selected-state"
  mv "$case/state" "$state"
  fake_host "$case/proc" 5 41
  env -u FM_HOME PATH="$case/fakebin:$PATH" FM_ROOT_OVERRIDE="$case" FM_STATE_OVERRIDE="$state" \
    TMUX='' FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$case/default.out" 2> "$case/default.err" &
  LEG_PID=$!
  fm_test_track_watcher_state "$state"
  wait_for_exit "$LEG_PID" 100 || fail "default-home watcher did not deliver its memory wake"
  wait_interrupt "$state"
  assert_contains "$(cat "$case/default.out")" 'automatic interrupt attempted: task big-build' "the resolved default home reaches control"
  assert_contains "$(cat "$case/keys")" 'firstmate:fm-big-build Escape' "control resolves the selected state directory"
  pass "default-home automatic interrupts preserve the selected state"
}

test_independent_sampler_lifecycle() {
  local case other pid identity old new i=0 bystander
  case=$(make_case slow-check)
  make_fleet "$case"
  prepare_control_task "$case"
  fake_host "$case/proc" 40 2
  cat > "$case/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/check-entered"
while [ ! -e "$FM_HOME/check-release" ]; do sleep 0.1; done
SH
  chmod 700 "$case/state/slow.check.sh"
  FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" "$ROOT/bin/fm-check-register.sh" slow >/dev/null
  watch_leg "$case" slow default
  while [ ! -e "$case/check-entered" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case/check-entered" ] || fail "the custom check did not start: $(cat "$case/watch-slow.err")"
  wait_rows "$case/state/host-memory.tsv" 1
  fake_host "$case/proc" 5 41
  i=0
  while ! grep -q $'\tcheck\thost-memory\t' "$case/state/.wake-queue" 2>/dev/null && [ "$i" -lt 120 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$i" -lt 120 ] || fail "the default sampler missed critical pressure during a blocked check"
  is_live_non_zombie "$LEG_PID" || fail "the check was not still blocking supervision"
  wait_interrupt "$case/state"
  assert_contains "$(cat "$case/keys")" 'Escape' "critical action happens while the watcher is blocked"
  [ "$(wc -l < "$case/state/host-memory.tsv")" -ge 2 ] || fail "independent samples were not recorded"
  : > "$case/check-release"
  wait_for_exit "$LEG_PID" 100 || fail "the watcher did not surface the durable memory wake"

  case=$(make_case sampler-restart)
  fake_host "$case/proc" 40 2
  watch_leg "$case" restart
  pid=$LEG_PID
  wait_rows "$case/state/host-memory.tsv" 2
  IFS=$'\t' read -r old identity < "$case/state/.host-memory-sampler.pid"
  kill -TERM "$old"
  i=0 new=$old
  while [ "$new" = "$old" ] && [ "$i" -lt 100 ]; do
    sleep 0.1; IFS=$'\t' read -r new identity < "$case/state/.host-memory-sampler.pid" 2>/dev/null || new=$old
    i=$((i + 1))
  done
  [ "$new" != "$old" ] || fail "the watcher did not restart its dead sampler"
  wait_rows "$case/state/host-memory.tsv" 4
  other=$(make_case other-home)
  fake_host "$other/proc" 40 2
  watch_leg "$other" other
  wait_rows "$other/state/host-memory.tsv" 2
  IFS=$'\t' read -r old identity < "$other/state/.host-memory-sampler.pid"
  sleep 60 & bystander=$!
  identity=$(STATE="$case/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$bystander")
  printf '%s\t%s\n' "$bystander" "$identity" > "$case/state/.host-memory-sampler.pid"
  kill -TERM "$pid"; wait_for_exit "$pid" 50 >/dev/null || true
  is_live_non_zombie "$bystander" || fail "sampler cleanup signalled an unrelated recorded PID"
  is_live_non_zombie "$old" || fail "stopping one home killed another home's sampler"
  kill -TERM "$bystander" "$LEG_PID"; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  pass "independent sampling survives slow checks, restarts, and respects PID ownership"
}

test_atomic_admission_publication() {
  local case=$TMP_ROOT/concurrent-admission first second rc1 rc2
  fake_host "$case/proc" 30 25
  mkdir -p "$case/hook" "$case/barrier" "$case/state"
  cat > "$case/hook/sitecustomize.py" <<'PY'
import os
import time

original_replace = os.replace

def replace(src, dst, *args, **kwargs):
    if os.fspath(dst) == os.environ.get("FM_TEST_ADMISSION_DEST"):
        barrier = os.environ["FM_TEST_ADMISSION_BARRIER"]
        with open(os.path.join(barrier, str(os.getpid())), "w"):
            pass
        for _ in range(200):
            if len(os.listdir(barrier)) == 2:
                break
            time.sleep(0.01)
        else:
            raise TimeoutError("the parallel publisher did not reach replacement")
    return original_replace(src, dst, *args, **kwargs)

os.replace = replace
PY
  env PYTHONPATH="$case/hook" FM_TEST_ADMISSION_DEST="$case/state/admission-refused" FM_TEST_ADMISSION_BARRIER="$case/barrier" \
    FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build-a --state "$case/state" > "$case/a.out" 2> "$case/a.err" &
  first=$!
  env PYTHONPATH="$case/hook" FM_TEST_ADMISSION_DEST="$case/state/admission-refused" FM_TEST_ADMISSION_BARRIER="$case/barrier" \
    FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build-b --state "$case/state" > "$case/b.out" 2> "$case/b.err" &
  second=$!
  wait "$first"; rc1=$?
  wait "$second"; rc2=$?
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] || fail "parallel refusals lost their pressure result: $(cat "$case/"*.err)"
  [ ! -s "$case/a.err" ] && [ ! -s "$case/b.err" ] || fail "parallel refusals raised an error"
  assert_contains "$(cat "$case/a.out" "$case/b.out")" 'pressure at or above 20%' "both launches report pressure"
  python3 - "$case/state" <<'PY' || fail "the public refusal record was not published intact"
import os
import sys

state = sys.argv[1]
with open(os.path.join(state, "admission-refused")) as f:
    epoch, task, reason = f.read().rstrip("\n").split("\t")
assert epoch.isdigit() and task in ("build-a", "build-b")
assert reason.startswith("host memory under pressure:")
assert os.listdir(state) == ["admission-refused"]
PY
  fake_host "$case/proc" 40 2
  FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build-a --state "$case/state" & first=$!
  FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build-b --state "$case/state" & second=$!
  wait "$first"; rc1=$?
  wait "$second"; rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ ! -e "$case/state/admission-refused" ] || fail "parallel healthy admissions did not clear the refusal record"
  pass "parallel admission publications and clearing are independent"
}

test_failed_alert_publication() {
  local case attempt
  local -a tick
  case=$(make_case alert-publication-failure)
  make_fleet "$case"
  prepare_control_task "$case"
  fake_host "$case/proc" 5 41
  tick=(env PATH="$case/fakebin:$PATH" FM_HOME="$case" FM_STATE_OVERRIDE="$case/state"
    STATE="$case/state" CONFIG="$case/config" SAMPLER_DIR="$ROOT/bin" FM_BACKEND=tmux
    FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" bash -c "
      . \"\$1/bin/fm-wake-lib.sh\"
      . \"\$1/bin/fm-backend.sh\"
      . \"\$FM_ADDONS_DIR/host-memory/bin/fm-host-memory-lib.sh\"
      fm_memory_sampler_tick
      wait
    " _ "$ROOT")
  mkdir "$case/state/.wake-queue.seq"
  for ((attempt=1; attempt<=2; attempt++)); do
    "${tick[@]}" 2> "$case/tick.err" || fail "failed publication stopped sampling"
    [ ! -e "$case/state/.host-memory-alerted" ] || fail "failed wake publication latched the episode"
    [ ! -e "$case/keys" ] || fail "failed wake publication dispatched an interrupt"
  done
  rmdir "$case/state/.wake-queue.seq"
  "${tick[@]}" || fail "recovered publication stopped sampling"
  [ -s "$case/state/.host-memory-alerted" ] || fail "successful publication did not latch the episode"
  [ "$(grep -c $'\tcheck\thost-memory\t' "$case/state/.wake-queue")" -eq 1 ] || fail "recovery did not publish exactly one wake"
  [ "$(wc -l < "$case/keys")" -eq 1 ] || fail "recovery did not dispatch exactly one interrupt"
  "${tick[@]}" || fail "latched sampling failed"
  [ "$(wc -l < "$case/keys")" -eq 1 ] || fail "restart repeated the recovered interrupt"
  fake_host "$case/proc" 40 2
  "${tick[@]}" || fail "healthy sampling failed"
  [ ! -e "$case/state/.host-memory-alerted" ] || fail "healthy sample did not end the episode"
  fake_pid "$case/proc" 105 foreign 25 / big-build
  fake_host "$case/proc" 5 41
  "${tick[@]}" || fail "second episode sampling failed"
  [ "$(grep -c $'\tcheck\thost-memory\t' "$case/state/.wake-queue")" -eq 2 ] || fail "the old wake suppressed the new episode"
  FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" "$DRAIN" > "$case/drain.out" 2> "$case/drain.err" || fail "episode wakes could not be drained"
  assert_contains "$(cat "$case/drain.out")" "foreign pid 105 25.0 GB" "the new consumer reaches supervision"
  assert_contains "$(cat "$case/drain.out")" "automatic interrupt skipped" "the new episode action reaches supervision"
  watch_leg "$case" newest
  wait_for_exit "$LEG_PID" 100 || fail "pending episodes did not wake supervision"
  assert_contains "$(cat "$case/watch-newest.out")" "foreign pid 105 25.0 GB" "the watcher surfaces the current consumer"
  assert_contains "$(cat "$case/watch-newest.out")" "automatic interrupt skipped" "the watcher surfaces the current action"
  "${tick[@]}" || fail "second episode latched sampling failed"
  [ "$(grep -c $'\tcheck\thost-memory\t' "$case/state/.wake-queue")" -eq 2 ] || fail "the second episode repeated its wake"
  [ "$(wc -l < "$case/keys")" -eq 1 ] || fail "the foreign consumer caused an interrupt"
  drain_and_ack "$case"
  pass "alert publication retries across restart and preserves each pending episode"
}

test_shutdown_during_alert_publication() {
  local case real_mv sampler identity i=0
  case=$(make_case alert-stop)
  make_fleet "$case"
  prepare_control_task "$case"
  fake_host "$case/proc" 40 2
  cat > "$case/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/check-entered"
while [ ! -e "$FM_HOME/check-release" ]; do sleep 0.1; done
SH
  chmod 700 "$case/state/slow.check.sh"
  FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" "$ROOT/bin/fm-check-register.sh" slow >/dev/null
  real_mv=$(command -v mv)
  cat > "$case/fakebin/mv" <<SH
#!/usr/bin/env bash
"$real_mv" "\$@" || exit \$?
if [ "\${2:-}" = "\$FM_HOME/state/.host-memory-alerted" ] && mkdir "\$FM_HOME/term-sent" 2>/dev/null; then
  IFS=\$'\t' read -r pid identity < "\$FM_HOME/state/.host-memory-sampler.pid"
  kill -TERM "\$pid"
fi
SH
  chmod +x "$case/fakebin/mv"
  watch_leg "$case" stop
  while [ ! -e "$case/check-entered" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case/check-entered" ] || fail "the watcher did not enter its blocking check"
  IFS=$'\t' read -r sampler identity < "$case/state/.host-memory-sampler.pid"
  fake_host "$case/proc" 5 41
  wait_interrupt "$case/state"
  [ -d "$case/term-sent" ] || fail "termination was not injected during alert publication"
  i=0
  while is_live_non_zombie "$sampler" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  ! is_live_non_zombie "$sampler" || fail "the sampler did not honor deferred termination"
  assert_contains "$(cat "$case/state/.wake-queue")" 'automatic interrupt attempted: task big-build' "the scheduled interrupt has a durable wake"
  [ -e "$case/state/.host-memory-alerted" ] || fail "the dispatched episode was not latched"
  : > "$case/check-release"
  wait_for_exit "$LEG_PID" 100 || fail "the watcher did not surface the stopped sampler's wake"
  [ "$(wc -l < "$case/keys")" -eq 1 ] || fail "the episode interrupted more than once after restart"
  pass "termination cannot commit an alert without dispatching its interrupt"
}

# A host under memory pressure refuses every launch kind before anything is
# created, records why in state/admission-refused, and a calm host lets the same
# spawn through and clears the record.
test_spawn_memory_admission() {
  local home=$TMP_ROOT/spawn-admission out status
  local spawn_env=(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_HOST_MEMORY_PROC="$home/proc" FM_HOST_MEMORY_CGROUP_ROOT="$home/cgroup")
  mkdir -p "$home/data" "$home/config" "$home/projects/none"
  git -C "$home/projects/none" init -q || fail "could not initialize project fixture"
  fake_host "$home/proc" 30 42
  out=$(env "${spawn_env[@]}" "$ROOT/bin/fm-spawn.sh" nope-mem-z5 projects/none --scout --harness 'true worker' 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a spawn under memory pressure should be refused"
  assert_contains "$out" "host memory under pressure: pressure at or above 35%" "the refusal names the pressure"
  assert_contains "$out" "task nope-mem-z5 stays queued" "the refusal says the task stays queued"
  assert_contains "$(cat "$home/state/admission-refused")" $'\tnope-mem-z5\thost memory under pressure' \
    "the refusal is recorded for the queue views"
  [ ! -e "$home/state/nope-mem-z5.meta" ] || fail "a refused spawn created a task record"
  out=$(env "${spawn_env[@]}" "$ROOT/bin/fm-spawn.sh" mate-mem-z6 / --secondmate --harness 'true worker' 2>&1)
  assert_contains "$out" "task mate-mem-z6 stays queued" "a secondmate launch is refused too"
  fake_host "$home/proc" 30 1
  out=$(env "${spawn_env[@]}" "$ROOT/bin/fm-spawn.sh" nope-mem-z5 projects/none --scout --harness 'true worker' 2>&1)
  assert_contains "$out" "has no brief" "a calm host lets the spawn through"
  [ ! -e "$home/state/admission-refused" ] || fail "an admitted spawn left the refusal record behind"
  pass "spawn: host memory pressure refuses every launch kind and records why"
}

test_default_supervision_poll() {
  local case i=0 first second
  case=$(make_case default-poll)
  fake_host "$case/proc" 40 2
  cat > "$case/state/poll.check.sh" <<'SH'
#!/usr/bin/env bash
date +%s >> "$FM_HOME/poll-times"
SH
  chmod 700 "$case/state/poll.check.sh"
  FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" "$ROOT/bin/fm-check-register.sh" poll >/dev/null
  env -u FM_POLL PATH="$case/fakebin:$PATH" FM_HOME="$case" FM_ROOT_OVERRIDE="$ROOT" \
    TMUX='' FM_BACKEND=tmux FM_SIGNAL_GRACE=0 FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" FM_HOST_MEMORY_SECS=1 \
    FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$case/poll.out" 2> "$case/poll.err" &
  LEG_PID=$!
  while [ "$i" -lt 250 ]; do
    [ ! -f "$case/poll-times" ] || [ "$(wc -l < "$case/poll-times")" -lt 2 ] || break
    sleep 0.1; i=$((i + 1))
  done
  [ "$i" -lt 250 ] || fail "the default watcher did not perform two check cycles: $(cat "$case/poll.err")"
  { read -r first; read -r second; } < "$case/poll-times"
  [ "$((second - first))" -ge 15 ] || fail "general supervision was sped up to $((second - first)) seconds"
  [ "$(wc -l < "$case/state/host-memory.tsv")" -ge 10 ] || fail "sampling depended on the general supervision poll"
  kill -TERM "$LEG_PID"; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  pass "general supervision retains its independent 15-second default"
}

test_verdicts_samples_and_owners
test_cgroup_pressure
test_home_qualified_owners
test_homes_without_ordinary_tasks
test_remote_records_do_not_own_local_processes
test_finite_thresholds
test_atomic_admission_publication
test_spawn_memory_admission

# The sampler ships in the optional host-memory add-on; without it the watcher runs no sampler.
watcher_sampler_tests=(
  test_fast_spike_waits_without_alert
  test_host_pressure_neither_holds_nor_wakes
  test_overridden_state_ownership
  test_watcher_wakes_once_per_alert_episode
  test_alert_rearms_after_wait
  test_benign_liveness_outcomes
  test_default_home_interrupt
  test_independent_sampler_lifecycle
  test_failed_alert_publication
  test_shutdown_during_alert_publication
  test_default_supervision_poll
)
if [ ! -f "$FM_ADDONS_DIR/host-memory/bin/fm-host-memory-lib.sh" ]; then
  echo "skip: host-memory add-on absent, ${#watcher_sampler_tests[@]} watcher sampler tests not run"
  exit 0
fi
for watcher_sampler_test in "${watcher_sampler_tests[@]}"; do
  "$watcher_sampler_test"
done
