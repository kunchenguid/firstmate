#!/usr/bin/env bash
# tests/fm-watch-wedge-episode-bound.test.sh - one episode, one alarm.
#
# A wedged pane used to publish one escalation every STALE_ESCALATE_SECS for as
# long as it sat still, so one panel produced twelve identical alarms in a
# night. The ladder is now bounded per EPISODE, where an episode is one pane
# state: the window plus the exact render it is stuck on. One episode publishes
# its first alarm, at most one more, and then stays quiet until that pane
# renders something different - which is what "the pane changes state" means
# here, because the stale hash is the only per-poll evidence the watcher has.
# A FLAPPING pane (one that flips busy and back to the same idle frame) keeps
# the same render, so it keeps the same spent budget: still one episode.
#
# FM_WEDGE_ALARM_MAX owns the bound (default 2) and applies to the unconfigured
# ladder. A home that configures FM_WEDGE_MAX_ESCALATIONS has asked for that
# explicit window-scoped ceiling instead and keeps its own ladder;
# tests/fm-watch-wedge-cap.test.sh owns that contract.
#
# This file also retires the former unconfigured-parity harness. It compared the
# unconfigured ladder byte for byte against upstream main, which by definition
# cannot survive an intentional change to that ladder - the twelve-alarm
# behaviour it pinned IS the defect. What that harness still proves here is the
# bound itself, driven the same way: one fixture, successive wedge polls.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
# The fixture root for make_case, which reads TMP_ROOT at call time.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-watch-wedge-episode-bound)

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A wedged pane absorbed as provably working: the state that arms the wedge
# timer. The status log is written and marked seen so this fixture's own line
# never raises a status signal that would mask which route the pane took.
make_wedged_case() {  # <name> -> echoes the case dir
  local name=$1 dir state window
  dir=$(make_case "$name")
  state="$dir/state"
  window="test:fm-episode-bound-$name"
  printf 'idle wedged content' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$name.meta"
  printf 'working: still wedged\n' > "$state/$name.status"
  prime_status_seen "$state" "$state/$name.status" || fail "could not adopt the fixture status log"
  printf '%s' "$(hash_text 'idle wedged content')" > "$state/.hash-$(watch_window_key "$window")"
  printf '1\n' > "$state/.count-$(watch_window_key "$window")"
  printf '%s\n' "$dir"
}

# One wedge poll. With the idle timer aged past STALE_ESCALATE_SECS a round
# either publishes an alarm (the watcher exits on its wake) or is absorbed by
# the bound (the watcher keeps polling, and the caller reaps it). Prints the
# watcher's pid and writes the reason to <dir>/watch.out.
# Started in THIS shell (never a command substitution) so reap and the wait
# helpers really own the watcher process.
ROUND_PID=
start_round() {  # <dir> [extra-env...]
  local dir=$1
  shift
  : > "$dir/watch.out"
  env PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_WINDOW="$FM_EPISODE_WINDOW" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    "$WATCH" > "$dir/watch.out" &
  ROUND_PID=$!
}

age_wedge_timer() {  # <dir>
  echo $(( $(date +%s) - 500 )) > "$dir/state/.stale-since-$FM_EPISODE_KEY"
}

# prime_fixture <dir>: one long-timer poll so the first sight is absorbed and
# the wedge timer is armed, then acknowledge the stopped cycle.
prime_fixture() {  # <dir>
  local dir=$1 pid
  start_round "$dir" FM_STALE_ESCALATE_SECS=999
  pid=$ROUND_PID
  wait_poll_cycle "$dir/state" "$pid" || { reap "$pid"; fail "priming the fixture failed: $(cat "$dir/watch.out")"; }
  reap "$pid"
  ack_stopped_cycle "$dir/state" || fail "priming ack failed"
}

# expect_alarm <dir> <alarm-number>: one aged poll must publish an alarm.
expect_alarm() {  # <dir> <n>
  local dir=$1 n=$2 pid
  : > "$dir/watch.out"
  age_wedge_timer "$dir"
  start_round "$dir"
  pid=$ROUND_PID
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "alarm round $n did not publish a wake: $(cat "$dir/watch.out")"; }
  grep -F "possible wedge, escalation $n" "$dir/watch.out" >/dev/null \
    || fail "alarm round $n did not report escalation $n: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$dir/state" || fail "alarm round $n ack failed"
}

# expect_quiet <dir>: one aged poll must publish nothing and keep polling.
expect_quiet() {  # <dir> <label> [extra-env...]
  local dir=$1 label=$2 pid
  shift 2
  : > "$dir/watch.out"
  age_wedge_timer "$dir"
  start_round "$dir" "$@"
  pid=$ROUND_PID
  if ! wait_poll_cycle "$dir/state" "$pid"; then
    reap "$pid"
    fail "$label: the bound did not absorb the poll (the watcher exited): $(cat "$dir/watch.out")"
  fi
  reap "$pid"
  [ ! -s "$dir/watch.out" ] || fail "$label: a poll past the episode bound still alarmed: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$dir/state" || fail "$label: ack failed"
}

# 1. The default bound: one episode publishes two alarms - the second naming
# itself as the last for this pane state - and every later poll of the same
# render stays quiet. The escalation count stops growing with the alarms.
test_default_episode_bound() {
  local dir state key pid
  dir=$(make_wedged_case default-bound)
  state="$dir/state"; key=$(watch_window_key "test:fm-episode-bound-default-bound")
  export FM_EPISODE_WINDOW="test:fm-episode-bound-default-bound" FM_EPISODE_KEY="$key"
  prime_fixture "$dir"
  expect_alarm "$dir" 1
  # The second alarm is the last one this pane state will get, and says so.
  : > "$dir/watch.out"
  age_wedge_timer "$dir"
  start_round "$dir"
  pid=$ROUND_PID
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "second alarm round did not publish a wake: $(cat "$dir/watch.out")"; }
  grep -F 'possible wedge, escalation 2' "$dir/watch.out" >/dev/null \
    || fail "the second round did not report escalation 2: $(cat "$dir/watch.out")"
  grep -F 'last alarm for this pane state' "$dir/watch.out" >/dev/null \
    || fail "the final alarm did not say it was the last for this pane state: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$state" || fail "second alarm ack failed"
  expect_quiet "$dir" "default bound round 3"
  expect_quiet "$dir" "default bound round 4"
  [ "$(cat "$state/.wedge-escalations-$key")" = 2 ] \
    || fail "the escalation count grew past the episode bound: $(cat "$state/.wedge-escalations-$key")"
  grep -F 'escalation bound 2 already published' "$state/.watch-triage.log" >/dev/null \
    || fail "the absorbed rounds were not recorded in the triage log"
  unset FM_EPISODE_WINDOW FM_EPISODE_KEY
  pass "an unconfigured ladder publishes two alarms for one pane state and then stays quiet, and the count stops growing"
}

# 2. A flapping pane is still ONE episode: a busy frame between two identical
# idle renders re-ends the episode through the ordinary choke point, and the
# bound must survive that end - otherwise a flapping pane re-alarms forever.
test_flapping_pane_is_one_episode() {
  local dir state key window pid
  dir=$(make_wedged_case flapping)
  state="$dir/state"; window="test:fm-episode-bound-flapping"
  key=$(watch_window_key "$window")
  export FM_EPISODE_WINDOW="$window" FM_EPISODE_KEY="$key"
  # A pi harness whose semantic busy record is the pane's state source.
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/flapping.meta"
  printf 'working: still wedged\n' > "$state/flapping.status"
  prime_status_seen "$state" "$state/flapping.status" || fail "could not adopt the fixture status log"
  prime_fixture "$dir"
  expect_alarm "$dir" 1
  expect_alarm "$dir" 2
  # The flap: the worker starts a turn (busy) and comes back to the SAME idle
  # render. The recorded generation makes this the same incarnation.
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" flapping)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" flapping busy --gen "$gen" \
    --source pi-ext --event agent-start >/dev/null || fail "could not arm the busy record"
  : > "$dir/watch.out"
  start_round "$dir"
  pid=$ROUND_PID
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "the busy flap round did not poll: $(cat "$dir/watch.out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "busy flap ack failed"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" flapping idle --gen "$gen" \
    --source pi-ext --event agent-end >/dev/null || fail "could not clear the busy record"
  printf '%s' "$(hash_text 'idle wedged content')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  expect_quiet "$dir" "flapping re-wedge"
  unset FM_EPISODE_WINDOW FM_EPISODE_KEY
  pass "a pane that flaps busy and back to the same render stays one episode and stays quiet"
}

# 3. A pane that renders something NEW has changed state, so the next wedge is
# a fresh episode and may alarm again.
test_state_change_starts_a_fresh_episode() {
  local dir state key window
  dir=$(make_wedged_case fresh-episode)
  state="$dir/state"; window="test:fm-episode-bound-fresh-episode"
  key=$(watch_window_key "$window")
  export FM_EPISODE_WINDOW="$window" FM_EPISODE_KEY="$key"
  prime_fixture "$dir"
  expect_alarm "$dir" 1
  expect_alarm "$dir" 2
  expect_quiet "$dir" "fresh-episode round before the state change"
  # The pane renders a different idle frame: a new episode. The watcher needs
  # two identical new frames before it treats the render as stably stale again
  # (that is the staleness backbone), and the first sight is then absorbed as
  # provably working - exactly like the fixture's own first sight.
  printf 'a different idle render' > "$dir/pane.txt"
  # Three settles: the new render must first become stable (two identical
  # frames), then take its own first sight, which is absorbed as provably
  # working exactly like the fixture's original first sight.
  expect_quiet "$dir" "state-change settle 1"
  expect_quiet "$dir" "state-change settle 2"
  expect_quiet "$dir" "state-change settle 3"
  : > "$dir/watch.out"
  age_wedge_timer "$dir"
  start_round "$dir"
  pid=$ROUND_PID
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the new pane state did not alarm: $(cat "$dir/watch.out")"; }
  grep -F 'possible wedge' "$dir/watch.out" >/dev/null \
    || fail "the new pane state did not publish an escalation: $(cat "$dir/watch.out")"
  unset FM_EPISODE_WINDOW FM_EPISODE_KEY
  pass "a pane that renders something new starts a fresh episode and escalates again"
}

# 4. FM_WEDGE_ALARM_MAX validates: 1 bounds an episode at one alarm, and every
# value bash cannot count falls back to the documented default of 2.
test_alarm_bound_validation() {
  local raw expected name dir pid n
  for spec in '1:1' 'garbage:2' '0:2' '-3:2' ':2'; do
    raw=${spec%:*}; expected=${spec#*:}
    name="validate-$(printf '%s' "${raw:-empty}" | tr -cd 'A-Za-z0-9')"
    dir=$(make_wedged_case "$name")
    export FM_EPISODE_WINDOW="test:fm-episode-bound-$name" FM_EPISODE_KEY
    FM_EPISODE_KEY=$(watch_window_key "$FM_EPISODE_WINDOW")
    prime_fixture "$dir"
    n=1
    while [ "$n" -le "$expected" ]; do
      : > "$dir/watch.out"
      age_wedge_timer "$dir"
      if [ -n "$raw" ]; then
        start_round "$dir" "FM_WEDGE_ALARM_MAX=$raw"
      else
        start_round "$dir" "FM_WEDGE_ALARM_MAX="
      fi
      pid=$ROUND_PID
      wait_for_exit "$pid" 100 || { reap "$pid"; fail "FM_WEDGE_ALARM_MAX='$raw' round $n did not alarm: $(cat "$dir/watch.out")"; }
      ack_stopped_cycle "$dir/state" || fail "FM_WEDGE_ALARM_MAX='$raw' round $n ack failed"
      n=$((n + 1))
    done
    if [ -n "$raw" ]; then
      expect_quiet "$dir" "FM_WEDGE_ALARM_MAX='$raw' past its bound" "FM_WEDGE_ALARM_MAX=$raw"
    else
      expect_quiet "$dir" "FM_WEDGE_ALARM_MAX='$raw' past its bound" "FM_WEDGE_ALARM_MAX="
    fi
    unset FM_EPISODE_WINDOW FM_EPISODE_KEY
  done
  pass "FM_WEDGE_ALARM_MAX bounds an episode at its value, and a value bash cannot count falls back to 2"
}

test_default_episode_bound
test_flapping_pane_is_one_episode
test_state_change_starts_a_fresh_episode
test_alarm_bound_validation
