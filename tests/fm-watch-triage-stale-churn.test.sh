#!/usr/bin/env bash
# tests/fm-watch-triage-stale-churn.test.sh - watcher triage: stale-pane churn
# bounded by an open captain call or an armed merge poll. The shared harness and
# the suite overview live in tests/fm-watch-triage-helpers.sh.
set -u

# shellcheck source=tests/fm-watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-helpers.sh"

# --- work the captain is already holding: pane churn must not re-alarm -------
# The other record of a legitimate wait. The declared-wait bound
# (tests/fm-watch-triage-declared-wait.test.sh) reads the
# status LINE, and a delivered task's line stays `done: PR ...` while the wait
# itself lives in the BACKLOG, written there by bin/fm-captain-hold.sh. No line
# predicate can see that record, so both stale alarms - the captain-relevant one
# and the inconclusive one - re-fired on every new pane hash for as long as the
# captain was deciding, which is the 2026-09 loop observed on delivered work
# awaiting their merge word.
# Pinned here, in both directions: while the call stands the first sight still
# alarms, further sights of the SAME call and status-log state are absorbed, and
# a new pane hash after the window's end alarms once more; and the identical
# fixture WITHOUT the hold keeps alarming on every hash, because a bound that
# swallowed an unheld delivery or blocker would be worse than the churn it removes.
#
# The backlog is real rather than a fixture file: bin/fm-captain-hold.sh is the
# only writer of a hold and tasks-axi the only reader, so a hand-written row
# would pin this test's idea of a hold instead of the one the watcher consults.
#
# Cost: every case below drives churn through ONE watcher process rather than
# relaunching per pane change. Watcher startup dominates a round here, and an
# absorbing watcher stays in its poll loop across churn in production anyway, so
# the cheaper shape is also the more faithful one.

# The window key every hold fixture uses, derived the way fm-watch.sh derives it.
hold_key() {
  printf '%s' test:fm-held-merge | tr ':/.' '___'
}

# Both status lines a held task really carries: the delivery that routes through
# the captain-relevant stale branch, and a worker line that routes through the
# inconclusive one. The hold is invisible to the status line in both, so both
# branches had the same blindness and both are covered.
test_open_captain_call_bounds_stale_churn() {
  local spec name line dir state out capture throttle wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (captain-hold stale bound)"; return 0; }
  for spec in \
    'held-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'held-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" hold) \
      || fail "[$name] could not build a captain-held backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    throttle="$state/.paused-resurfaced-$(hold_key)"

    # First sight still alarms: the call bounds repetition, never the first look.
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
      || fail "[$name] first sight of held work did not surface"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "[$name] first sight produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"

    # The pane churns while the SAME call stands. Every one of these alarmed.
    hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 2 \
      || fail "[$name] watcher exited during pane churn instead of supervising through it"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 0 ] \
      || fail "[$name] pane churn re-alarmed held work $wakes time(s) inside the re-surface window"

    # After the window ends, the next new pane hash re-surfaces held work exactly
    # once, so a forgotten call on a churning pane cannot hide behind the bound.
    [ -e "$throttle" ] || fail "[$name] the absorbed churn recorded no re-surface cadence to elapse"
    set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 9s' \
      || fail "[$name] held work did not re-surface once its re-surface window elapsed"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] \
      || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
  done
  pass "work under an open captain call surfaces once, absorbs pane churn, then re-surfaces when the window elapses"
}



# The other half of the same bound, and the one that decides whether widening the
# wait was safe: the identical fixtures with NO hold must keep alarming on every
# new hash, on both branches.
test_stale_churn_without_a_captain_call_still_alarms() {
  local spec name line dir state out capture round wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (unheld stale alarm)"; return 0; }
  for spec in \
    'unheld-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'unheld-blocker|blocked: cannot reach the release host' \
    'unheld-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" nohold) \
      || fail "[$name] could not build an unheld backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    round=1
    while [ "$round" -le 2 ]; do
      hold_watch_surface "$dir" "$out" "$capture" "idle, elapsed ${round}s" \
        || fail "[$name] an unheld stale window stopped alarming on round $round"
      wakes=$(hold_stale_wakes "$state")
      [ "$wakes" -eq 1 ] \
        || fail "[$name] round $round produced $wakes wakes instead of one"
      ack_stopped_cycle "$state" || fail "[$name] could not acknowledge round $round"
      round=$((round + 1))
    done
  done
  pass "a stale window with no open captain call keeps alarming on every new hash"
}


# The cadence marker may never outlive the wake it claims to record. Recording it
# before publishing the durable wake turned a delayed alarm into a lost one: the
# append fails, the watcher exits with nothing queued, and the next sighting
# reads that fresh marker and absorbs the retry. An unwritable queue is the real
# failure, so it is the one this drives.
test_failed_wake_append_does_not_arm_the_captain_hold_throttle() {
  local dir state out capture wakes rc
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (failed wake append)"; return 0; }
  dir=$(make_hold_home append-failure 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # A directory where the queue file belongs: every append fails, whatever the
  # caller does, so the watcher cannot publish the wake it just decided to send.
  # Its exit code is read directly here because a refusing watcher exits NON-zero,
  # which is the correct outcome and not the "surfaced" one hold_watch_surface means.
  rm -f "$state/.wake-queue"
  mkdir -p "$state/.wake-queue"
  printf 'idle, elapsed 1s\n' > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100
  rc=$?
  rmdir "$state/.wake-queue"
  [ "$rc" -ne 124 ] || fail "the watcher did not exit when its durable queue could not be written"
  [ "$rc" -ne 0 ] || fail "the watcher reported success despite an unwritable durable queue"
  [ -e "$state/.paused-resurfaced-$(hold_key)" ] \
    && fail "a wake that never reached the durable queue still armed the re-surface throttle"

  # The retry must alarm: nothing was ever delivered, so nothing may be absorbed.
  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 2s' \
    || fail "the retry after a failed wake append was absorbed instead of alarming"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the retry after a failed wake append produced $wakes wakes instead of one"
  pass "a wake that never reached the durable queue arms no re-surface throttle"
}

# The task id is not the captain call. A task can be answered with `--release`
# and held again as a genuinely different call with NO status append, and binding
# the throttle to the status-log signature alone let the second call inherit the
# first one's silence and absorbed its first sight. That is the one alarm this
# bound must never swallow: a delivery announced twice is noise, but a decision
# waiting on the captain that is never surfaced is invisible.
# Measured at base c499f84 this fixture alarms on every sighting, so the
# suppression was introduced by the bound itself rather than pre-existing.
test_reheld_captain_call_starts_its_own_resurface_window() {
  local dir state out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (re-held captain call)"; return 0; }
  dir=$(make_hold_home reheld-call 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
    || fail "first sight of the first captain call did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first call's surface"
  hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 1 \
    || fail "the first call's churn was not absorbed"
  [ "$(hold_stale_wakes "$state")" -eq 0 ] \
    || fail "the first call's churn re-alarmed inside its own window"

  # Answer and release, then re-hold: a second, distinct captain call on the same
  # task id, with no status append, so the status signature cannot tell them apart.
  printf 'go ahead\n' > "$dir/decision.txt"
  run_hold "$dir" answer held-merge --decision-file "$dir/decision.txt" --release \
    || fail "could not record the captain's answer"
  run_hold "$dir" hold held-merge --reason 'awaiting the captain a second time' \
    || fail "could not re-hold the task as a second captain call"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 3s' \
    || fail "the second captain call inherited the first call's silence"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the second captain call produced $wakes first wakes instead of one"
  pass "a released-then-re-held task is a distinct captain call whose first sight still alarms"
}



# --- delivered work whose PR merge poll is armed: pane churn must not re-alarm
# The third settled population, and the one with no wait record any status line
# or backlog row can carry. A `done: PR ...` task is FINISHED: its worker has
# exited, its pane will never move again on its own, and the armed merge poll is
# what is watching that PR. The captain-relevant stale branch nevertheless
# alarmed on every new pane hash, which on the observed one-minute cadence is one
# supervision turn a minute for as long as the PR stays open - reproduced live on
# 2026-08-17 and again on 2026-09-14, both times with the poll armed and firstmate
# holding nothing to do.
# Pinned here in all three directions: the first sight still alarms, further
# sights of the same delivery and armed poll are absorbed, and the window's end
# re-surfaces once, because the poll speaks only on a MERGE - a PR closed
# unmerged would otherwise leave the task silent forever.

merge_poll_key() {
  printf '%s' test:fm-merge-poll | tr ':/.' '___'
}

merge_poll_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-merge-poll" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# A delivered task, optionally with its merge poll actually armed by the only
# thing that arms one. bin/fm-pr-check.sh is run for real rather than a
# hand-written sidecar, because the watcher validates the whole published set -
# data, registration, check bytes and metadata identity - and a fixture that
# faked it would pin this test's idea of an armed poll instead of the real one.
make_merge_poll_home() {  # <name> <status-line> <arm|noarm>
  local name=$1 line=$2 arm=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  printf 'window=test:fm-merge-poll\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/merge-poll.meta"
  printf '%s\n' "$line" > "$state/merge-poll.status"
  printf '%s' "$(seen_sig "$state/merge-poll.status")" > "$state/.seen-merge-poll_status"
  if [ "$arm" = arm ]; then
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=999999 \
      "$ROOT/bin/fm-pr-check.sh" merge-poll https://github.com/example/repo/pull/1 \
      >/dev/null 2>&1 || return 1
    [ -f "$state/merge-poll.pr-poll" ] || return 1
  fi
  printf '%s\n' "$dir"
}

MERGE_POLL_WATCH_PID=
merge_poll_watch_launch() {  # <dir> <out> <capture>
  local dir=$1 out=$2 capture=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-merge-poll \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  MERGE_POLL_WATCH_PID=$!
}

merge_poll_watch_surface() {  # <dir> <out> <capture> <pane-text>
  local dir=$1 out=$2 capture=$3 text=$4
  printf '%s\n' "$text" > "$capture"
  merge_poll_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$MERGE_POLL_WATCH_PID" 100 || { reap "$MERGE_POLL_WATCH_PID"; return 1; }
  return 0
}

# <count> successive pane changes driven through ONE watcher, three poll cycles
# each: see the new hash, count it stable and classify, prove the classification
# held. The watcher must stay in its loop throughout.
merge_poll_watch_churn() {  # <dir> <out> <capture> <label> <count>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  merge_poll_watch_launch "$dir" "$out" "$capture"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$MERGE_POLL_WATCH_PID" 300 \
        || { reap "$MERGE_POLL_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$MERGE_POLL_WATCH_PID"
  return 0
}

test_armed_merge_poll_bounds_delivered_stale_churn() {
  local dir state out capture throttle wakes
  dir=$(make_merge_poll_home armed-delivery \
    'done: PR https://github.com/example/repo/pull/1 checks green' arm) \
    || fail "could not arm a real PR merge poll for a delivered task"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
  throttle="$state/.paused-resurfaced-$(merge_poll_key)"

  # First sight still alarms: the poll bounds repetition, never the first look.
  merge_poll_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
    || fail "first sight of delivered work did not surface"
  wakes=$(merge_poll_stale_wakes "$state")
  [ "$wakes" -eq 1 ] || fail "first sight produced $wakes wakes instead of one"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first surface"

  # The pane churns while the SAME delivery and armed poll stand. Every one of
  # these used to alarm, once a minute, for the whole life of the open PR.
  merge_poll_watch_churn "$dir" "$out" "$capture" 'idle, tick' 2 \
    || fail "watcher exited during pane churn instead of supervising through it"
  wakes=$(merge_poll_stale_wakes "$state")
  [ "$wakes" -eq 0 ] \
    || fail "pane churn re-alarmed delivered work $wakes time(s) while its merge poll was armed"

  # The poll only ever reports a MERGE, so the absorb stays bounded: after the
  # window ends the next new hash re-surfaces the finished task exactly once.
  [ -e "$throttle" ] || fail "the absorbed churn recorded no re-surface cadence to elapse"
  set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
  merge_poll_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 9s' \
    || fail "delivered work did not re-surface once its re-surface window elapsed"
  wakes=$(merge_poll_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "elapsed re-surface window produced $wakes wakes instead of one"
  pass "delivered work whose merge poll is armed surfaces once, absorbs pane churn, then re-surfaces when the window elapses"
}

# The other half of the bound. A settled delivery is the ONLY thing it may quiet:
# an unarmed delivery has nothing watching its PR, and a blocked or
# needs-decision line is firstmate's to act on whatever its PR is doing, so both
# must keep alarming on every new hash exactly as they do today.
test_stale_churn_without_an_armed_merge_poll_still_alarms() {
  local spec name line arm dir state out capture round wakes
  for spec in \
    'unarmed-delivery|done: PR https://github.com/example/repo/pull/1 checks green|noarm' \
    'armed-blocker|blocked: cannot reach the release host|arm' \
    'armed-decision|needs-decision: squash or rebase the branch|arm'
  do
    name=${spec%%|*}; line=${spec#*|}; arm=${line#*|}; line=${line%%|*}
    dir=$(make_merge_poll_home "$name" "$line" "$arm") \
      || fail "[$name] could not build a delivered-task fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    round=1
    while [ "$round" -le 2 ]; do
      merge_poll_watch_surface "$dir" "$out" "$capture" "idle, elapsed ${round}s" \
        || fail "[$name] an unbounded stale window stopped alarming on round $round"
      wakes=$(merge_poll_stale_wakes "$state")
      [ "$wakes" -eq 1 ] \
        || fail "[$name] round $round produced $wakes wakes instead of one"
      ack_stopped_cycle "$state" || fail "[$name] could not acknowledge round $round"
      round=$((round + 1))
    done
  done
  pass "a stale window with no armed merge poll, and a held-up delivery that has one, keep alarming on every new hash"
}

# FM_TEST_ONLY=<case> runs just that one case.
if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_open_captain_call_bounds_stale_churn
test_stale_churn_without_a_captain_call_still_alarms
test_failed_wake_append_does_not_arm_the_captain_hold_throttle
test_reheld_captain_call_starts_its_own_resurface_window
test_armed_merge_poll_bounds_delivered_stale_churn
test_stale_churn_without_an_armed_merge_poll_still_alarms
