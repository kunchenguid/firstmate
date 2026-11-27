#!/usr/bin/env bash
# tests/fm-watch-beacon-progress.test.sh - the watcher's liveness beacon ages
# with the longest step it is stuck in, not with the length of a whole cycle.
#
# A busy home (many workers, registered process-event sources, remote
# secondmates) legitimately spends longer in one cycle than the guard's grace
# while every step still returns. Before the fix the beacon was touched once, at
# the top of the cycle, so the guard printed "watcher still down" next to a live,
# progressing watcher. A watcher that is genuinely wedged inside one step must
# still read as down, because that step reaches no checkpoint.
#
# The slow step is the per-window pane capture: a fake tmux whose capture-pane
# sleeps, run against many windows. Both cases drive the real watcher and read
# the real guard output, the way an operator reaches them.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
GUARD="$ROOT/bin/fm-guard.sh"
# The fixture root for make_case, which reads TMP_ROOT at call time.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-watch-beacon-progress)

GRACE=6
CAPTURE_SECONDS=1

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# A tmux whose pane capture takes <seconds> and counts its calls. A capture
# beyond the Nth hangs for <hang-seconds> instead, to model a step that never
# returns within the observation.
install_slow_tmux() {  # <fakebin> <counter-file> <seconds> [hang-after-count] [hang-seconds]
  local fakebin=$1 counter=$2 seconds=$3 hang_after=${4:-} hang_seconds=${5:-0}
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) exit 0 ;;
  capture-pane)
    n=\$(cat "$counter" 2>/dev/null || echo 0)
    printf '%s\n' \$((n + 1)) > "$counter"
    if [ -n "$hang_after" ] && [ "\$n" -ge "$hang_after" ]; then
      sleep "$hang_seconds"
    else
      sleep "$seconds"
    fi
    echo "pane"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# Start a watcher over <windows> in-flight tasks. The guard and the watcher read
# one grace, and a checkpoint is allowed every second so the case runs in
# seconds instead of minutes.
start_case() {  # <name> <windows> <hang-after-count|"">
  local name=$1 windows=$2 hang_after=${3:-} dir state fakebin i
  dir=$(make_case "$name")
  state="$dir/state"
  fakebin="$dir/fakebin"
  install_slow_tmux "$fakebin" "$dir/captures" "$CAPTURE_SECONDS" "$hang_after" 30
  for i in $(seq 1 "$windows"); do
    printf 'window=sb:fm-w%s\nkind=ship\n' "$i" > "$state/w$i.meta"
  done
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_WATCHER_STALE_GRACE="$GRACE" FM_WATCHER_CHECKPOINT_SECS=1 "$WATCH" > "$dir/watch.out" 2>&1 &
  CASE_PID=$!
  CASE_DIR=$dir
}

stop_case() {
  kill "$CASE_PID" 2>/dev/null || true
  wait "$CASE_PID" 2>/dev/null || true
}

# What an operator sees: the guard, run against this home, naming the watcher.
guard_verdict() {  # <dir> -> "down" or "ok"
  local dir=$1 out
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_GUARD_GRACE="$GRACE" \
    FM_SUPERVISION_MODEL=persistent "$GUARD" 2>&1)
  case "$out" in
    *"WATCHER DOWN"*|*"watcher still down"*) printf 'down\n' ;;
    *) printf 'ok\n' ;;
  esac
}

# Observe for <seconds>, recording the oldest beacon age seen and whether the
# guard ever called the live watcher down. Starts only once a first beacon exists.
OBSERVED_MAX_AGE=0
OBSERVED_DOWN=0
observe() {  # <dir> <seconds>
  local dir=$1 seconds=$2 beat end m age
  beat="$dir/state/.last-watcher-beat"
  OBSERVED_MAX_AGE=0
  OBSERVED_DOWN=0
  end=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$end" ]; do
    kill -0 "$CASE_PID" 2>/dev/null || return 1
    m=$(file_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      [ "$age" -le "$OBSERVED_MAX_AGE" ] || OBSERVED_MAX_AGE=$age
      [ "$(guard_verdict "$dir")" != down ] || OBSERVED_DOWN=1
    fi
    sleep 1
  done
  return 0
}

# One cycle spends windows x CAPTURE_SECONDS = 14s in its window loop, well past
# the 6s grace, and every capture returns.
test_slow_cycle_keeps_beacon_fresh() {
  local captures
  start_case slow-cycle 14 ""
  observe "$CASE_DIR" 20 || { stop_case; fail "the watcher exited during a slow cycle: $(cat "$CASE_DIR/watch.out")"; }
  captures=$(cat "$CASE_DIR/captures" 2>/dev/null || echo 0)
  stop_case
  [ "$captures" -ge 14 ] \
    || fail "the observation never covered a whole slow cycle ($captures captures), so it proves nothing"
  [ "$OBSERVED_MAX_AGE" -lt "$GRACE" ] \
    || fail "the beacon aged ${OBSERVED_MAX_AGE}s (grace ${GRACE}s) while the watcher was progressing through a slow cycle"
  [ "$OBSERVED_DOWN" -eq 0 ] \
    || fail "the guard called a live, progressing watcher down during a slow cycle"
  pass "a slow cycle keeps the beacon under the grace and the guard quiet (max age ${OBSERVED_MAX_AGE}s)"
}

# The fifth capture never returns inside the observation, so no checkpoint is
# reached after it: the beacon must go stale and the guard must say so.
test_wedged_step_still_reads_down() {
  start_case wedged-step 14 4
  observe "$CASE_DIR" 18 || { stop_case; fail "the watcher exited before the wedge could be observed: $(cat "$CASE_DIR/watch.out")"; }
  kill -0 "$CASE_PID" 2>/dev/null || { stop_case; fail "the wedged watcher should still be alive"; }
  stop_case
  [ "$OBSERVED_MAX_AGE" -ge "$GRACE" ] \
    || fail "a watcher stuck inside one step kept a beacon younger than the grace (max age ${OBSERVED_MAX_AGE}s)"
  [ "$OBSERVED_DOWN" -eq 1 ] \
    || fail "the guard never reported a watcher stuck inside one step as down"
  pass "a watcher stuck inside one step still goes stale and reads down (max age ${OBSERVED_MAX_AGE}s)"
}

# Zero uses the default interval, so this short cycle keeps the cycle-top
# beacon semantics other suites wait on.
test_zero_checkpoint_uses_default() {
  local dir state fakebin beat first now i
  dir=$(make_case zero-checkpoint)
  state="$dir/state"
  fakebin="$dir/fakebin"
  # Three windows at 0.6s each make a 1.8s cycle: long enough that a checkpoint
  # taken at every window would move the beacon's one-second mtime, and shorter
  # than the 3s poll, so the next cycle top is not reached while this observes.
  install_slow_tmux "$fakebin" "$dir/captures" 0.6
  for i in 1 2 3; do printf 'window=sb:fm-w%s\nkind=ship\n' "$i" > "$state/w$i.meta"; done
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=3 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCHER_CHECKPOINT_SECS=0 "$WATCH" > "$dir/watch.out" 2>&1 &
  CASE_PID=$!
  beat="$state/.last-watcher-beat"
  first=
  i=0
  while [ "$i" -lt 100 ] && [ -z "$first" ]; do first=$(file_mtime "$beat"); sleep 0.1; i=$((i + 1)); done
  [ -n "$first" ] || { stop_case; fail "the watcher never wrote a beacon"; }
  sleep 2.5
  now=$(file_mtime "$beat")
  stop_case
  [ "$now" = "$first" ] \
    || fail "zero checkpoint touched the beacon inside the short cycle ($first -> $now)"
  pass "zero checkpoint preserves cycle-top-only beacon writes"
}

test_slow_cycle_keeps_beacon_fresh
test_wedged_step_still_reads_down
test_zero_checkpoint_uses_default
printf 'ok - all watcher beacon progress tests passed\n'
