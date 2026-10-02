#!/usr/bin/env bash
# tests/fm-watch-run-stall.test.sh - the run-stall alert (CI lead-time
# investigation, recommendation 6). A live worker's no-mistakes run can sit
# with NO step activity for hours - a provider error (pi/Fireworks "Retry
# failed after 3 attempts: Request timed out") leaves the worker idle
# mid-task while the run record still says running and no stale wake raised.
# fm-watch.sh's run_stall_tick fires the existing stale wake kind once per
# stall episode when a ship task's running run reports the client's own quiet
# last_activity past the threshold, pane-independently (a busy-looking pane
# cannot hide a stalled run), never for a run parked at a gate and never for
# a declared paused: wait; resumed activity clears the episode.
# The tick is driven in fm-watch.sh's supported sourced mode (sourcing loads
# the functions and returns before the singleton lock), through the real
# wake-queue append and the hermetic fake fm-crew-state.sh. The component
# minting behind the evidence is pinned in fm-crew-state.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

# The wake-helpers fixture harness reads TMP_ROOT for its case roots.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-watch-run-stall-tests)

# Set <file>'s mtime to exactly <epoch> seconds, for aging the tick's throttle
# marker past FM_RUN_STALL_CHECK_SECS without a real wait (touch -t takes a
# local-time stamp on both platforms, so convert via BSD `date -r` or GNU
# `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

make_stall_case() {  # <name> <verdict> -> echoes dir
  local dir state
  dir=$(make_case "$1"); state="$dir/state"
  printf 'window=test:fm-stall\nbackend=tmux\nharness=pi\nkind=ship\n' > "$state/stalltask.meta"
  printf 'working: implementing\n' > "$state/stalltask.status"
  printf '%s' "$2" > "$state/.crew-verdict"
  printf '%s\n' "$dir"
}

# Run one real run_stall_tick in a subshell over <dir>. Sourcing the watcher
# loads the functions and returns before the singleton lock; the tick's wake
# prints its reason and exits the subshell, exactly as the loop's wake exits a
# cycle. The fake fm-crew-state.sh serves the canned verdict, so no no-mistakes
# install or worktree is needed.
run_tick() {  # <dir> <verdict>
  (
    export FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
      FM_RUN_STALL_SECS=900 FM_RUN_STALL_CHECK_SECS=1 \
      FM_CREW_STATE_BIN="$1/fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE="$2"
    # shellcheck disable=SC1090
    . "$WATCH"
    run_stall_tick
  )
}

stall_rows() {  # <state> -> stall wake rows in the durable queue
  local n
  n=$(grep -c "run stalled" "$1/.wake-queue" 2>/dev/null) || n=0
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

# The tick's own throttle would mask the second tick's episode-dedup branch:
# age the marker past FM_RUN_STALL_CHECK_SECS so each run_tick reaches the
# crew-state read.
age_throttle() {  # <dir>
  set_mtime "$(( $(date +%s) - 10 ))" "$1/state/.run-stall-check-stalltask" 2>/dev/null \
    || touch -A -10 "$1/state/.run-stall-check-stalltask"
}

# --- pure classifier predicate (fm-classify-lib.sh) -------------------------

test_crew_run_stall_parses_evidence() {
  local dir state fakebin out
  dir=$(make_case stall-parse); state="$dir/state"; fakebin="$dir/fakebin"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running) · stall-secs: 1200 · stall-step: review · run: 01RUN' \
    crew_run_stall taskid)
  [ "$out" = "$(printf '1200\treview\t01RUN')" ] \
    || fail "crew_run_stall parsed '$out' instead of secs/step/run id"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running) · stall-secs: 60 · stall-step: test' \
    crew_run_stall taskid)
  [ "$out" = "$(printf '60\ttest\t')" ] \
    || fail "crew_run_stall without a run id parsed '$out' instead of empty run"
  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at fix_review · run: 01RUN' \
    crew_run_stall taskid \
    && fail "a parked gate minted stall evidence"
  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    crew_run_stall taskid \
    && fail "a pane verdict minted stall evidence"
  pass "crew_run_stall: quiet evidence parsed, waits and non-run sources return none"
}

# --- stalled run fires once per episode, with the run id, step, and minutes --

test_stalled_run_fires_once_per_episode() {
  local dir state out reason rows
  dir=$(make_stall_case stall-fires \
    'state: working · source: run-step · validating (running) · stall-secs: 1200 · stall-step: review · run: 01RUN')
  state="$dir/state"; out="$dir/tick.out"

  # Phase A: the tick fires the stale wake naming the evidence.
  reason=$(run_tick "$dir" "$(cat "$state/.crew-verdict")")
  grep -F "run stalled" <<< "$reason" >/dev/null || fail "the tick did not print a run-stalled wake: $reason"
  grep -F "01RUN" <<< "$reason" >/dev/null || fail "the stall wake did not name the run id: $reason"
  grep -F "review" <<< "$reason" >/dev/null || fail "the stall wake did not name the step: $reason"
  grep -F "20m" <<< "$reason" >/dev/null || fail "the stall wake did not name the quiet minutes: $reason"
  rows=$(stall_rows "$state")
  [ "$rows" = 1 ] || fail "expected exactly one stall wake row, found $rows"

  # Phase B: the same episode must not re-fire on a later cycle.
  age_throttle "$dir"
  reason=$(run_tick "$dir" "$(cat "$state/.crew-verdict")")
  [ -z "$reason" ] || fail "the same stall episode re-fired: $reason"
  rows=$(stall_rows "$state")
  [ "$rows" = 1 ] || fail "the same stall episode queued a second wake: $rows rows"

  # Phase C: resumed activity clears the episode...
  printf 'state: working · source: run-step · validating (running)' > "$state/.crew-verdict"
  age_throttle "$dir"
  reason=$(run_tick "$dir" "$(cat "$state/.crew-verdict")")
  [ -z "$reason" ] || fail "resumed activity fired a wake: $reason"
  [ ! -e "$state/.run-stall-stalltask" ] || fail "resumed activity did not clear the stall episode"
  rows=$(stall_rows "$state")
  [ "$rows" = 1 ] || fail "resumed activity queued a wake: $rows rows"

  # ...so a re-stall on a NEW run is a fresh episode that fires again.
  printf 'state: working · source: run-step · validating (fixing) · stall-secs: 1800 · stall-step: review · run: 01RUN2' \
    > "$state/.crew-verdict"
  age_throttle "$dir"
  reason=$(run_tick "$dir" "$(cat "$state/.crew-verdict")")
  grep -F "01RUN2" <<< "$reason" >/dev/null || fail "the fresh episode's wake did not name the new run id: $reason"
  rows=$(stall_rows "$state")
  [ "$rows" = 2 ] || fail "expected two stall wakes after the episode cleared, found $rows"
  pass "a stalled run fires once per episode with run id, step, and quiet minutes"
}

# --- a run parked at a gate is a wait, never a stall -------------------------

test_parked_gate_does_not_fire() {
  local dir state reason
  dir=$(make_stall_case stall-parked \
    'state: parked · source: run-step · parked at fix_review: 2 finding(s) · run: 01RUN')
  state="$dir/state"
  reason=$(run_tick "$dir" "$(cat "$state/.crew-verdict")")
  [ -z "$reason" ] || fail "a parked gate fired the stall alert: $reason"
  [ "$(stall_rows "$state")" = 0 ] || fail "a parked gate queued the stall alert"
  [ ! -e "$state/.run-stall-stalltask" ] || fail "a parked gate left stall episode state behind"
  pass "a run parked at a gate never fires the stall alert"
}

# --- a declared paused: wait never fires, even with quiet run activity -------

test_declared_pause_does_not_fire() {
  local dir state reason
  dir=$(make_stall_case stall-declared \
    'state: working · source: run-step · validating (running) · stall-secs: 1200 · stall-step: review · run: 01RUN')
  state="$dir/state"
  printf 'paused: waiting for the registry quota to reset\n' > "$state/stalltask.status"
  reason=$(run_tick "$dir" "$(cat "$state/.crew-verdict")")
  [ -z "$reason" ] || fail "a declared pause fired the stall alert: $reason"
  [ "$(stall_rows "$state")" = 0 ] || fail "a declared pause queued the stall alert"
  [ ! -e "$state/.run-stall-stalltask" ] || fail "a declared pause left stall episode state behind"
  pass "a declared paused: wait never fires the stall alert"
}

# --- a failed publication must not swallow the episode ------------------------

test_failed_append_leaves_episode_unmarked() {
  local dir state
  dir=$(make_stall_case stall-append-fails \
    'state: working · source: run-step · validating (running) · stall-secs: 1200 · stall-step: review · run: 01RUN')
  state="$dir/state"
  (
    export FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_RUN_STALL_SECS=900 FM_RUN_STALL_CHECK_SECS=1 \
      FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE="$(cat "$state/.crew-verdict")"
    # shellcheck disable=SC1090
    . "$WATCH"
    fm_wake_append() { return 1; }
    run_stall_tick
  ) >/dev/null 2>&1
  [ ! -e "$state/.run-stall-stalltask" ] || fail "a failed wake append still marked the episode"
  age_throttle "$dir"
  [ -n "$(run_tick "$dir" "$(cat "$state/.crew-verdict")")" ] \
    || fail "the stall was not re-surfaced after a failed publication"
  pass "a failed wake append leaves the episode unmarked so the next cycle retries"
}

# --- the fleet-wide tick is bounded ------------------------------------------

test_tick_bounds_crew_state_reads() {
  local dir state i n
  dir=$(make_stall_case stall-bounded 'state: working · source: run-step · validating (running)')
  state="$dir/state"
  for i in 1 2 3 4 5; do
    printf 'window=test:fm-t%s\nbackend=tmux\nharness=pi\nkind=ship\n' "$i" > "$state/t$i.meta"
  done
  rm -f "$state/stalltask.meta"
  tick() {
    (
      export FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
        FM_RUN_STALL_CHECK_SECS=300 FM_RUN_STALL_MAX_READS=2 \
        FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
        FM_FAKE_CREW_STATE="$(cat "$state/.crew-verdict")"
      # shellcheck disable=SC1090
      . "$WATCH"
      run_stall_tick
    )
  }
  tick
  n=$(ls "$state"/.run-stall-check-* 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 2 ] || fail "first tick read $n tasks instead of the cap of 2"
  tick
  n=$(ls "$state"/.run-stall-check-* 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 4 ] || fail "second tick did not continue with the unread tasks: $n read"
  pass "run_stall_tick caps crew-state reads per tick and continues next tick"
}

test_cap_reads_oldest_checked_first() {
  local dir state i
  dir=$(make_stall_case stall-oldest-first 'state: working · source: run-step · validating (running)')
  state="$dir/state"
  rm -f "$state/stalltask.meta"
  for i in 1 2 3 4 5; do
    printf 'window=test:fm-t%s\nbackend=tmux\nharness=pi\nkind=ship\n' "$i" > "$state/t$i.meta"
  done
  # t1-t4 were checked recently (t1 least recently); t5 never was. All are due,
  # and the cap of 2 must still reach t5 rather than re-reading t1/t2 forever.
  age_set "$state/.run-stall-check-t1" 14400
  age_set "$state/.run-stall-check-t2" 10800
  age_set "$state/.run-stall-check-t3" 7200
  age_set "$state/.run-stall-check-t4" 3600
  (
    export FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_RUN_STALL_CHECK_SECS=300 FM_RUN_STALL_MAX_READS=2 \
      FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE="$(cat "$state/.crew-verdict")"
    # shellcheck disable=SC1090
    . "$WATCH"
    run_stall_tick
  )
  [ "$(age_check "$state/.run-stall-check-t5")" = fresh ] || fail "never-checked t5 was starved by the read cap"
  [ "$(age_check "$state/.run-stall-check-t1")" = fresh ] || fail "oldest-checked t1 was not read"
  [ "$(age_check "$state/.run-stall-check-t4")" = old ] || fail "t4 was read ahead of older tasks"
  pass "read cap serves oldest-last-checked tasks first"
}
age_set() { python3 -c 'import os,sys,time; open(sys.argv[1],"w").close(); t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
age_check() { [ "$(find "$1" -mmin -5 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && echo fresh || echo old; }

test_crew_run_stall_parses_evidence
test_stalled_run_fires_once_per_episode
test_parked_gate_does_not_fire
test_declared_pause_does_not_fire
test_failed_append_leaves_episode_unmarked
test_tick_bounds_crew_state_reads
test_cap_reads_oldest_checked_first

echo "all fm-watch-run-stall tests passed"
