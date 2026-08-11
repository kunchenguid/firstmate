#!/usr/bin/env bash
# tests/fm-classify.test.sh - the shared triage policy in bin/fm-classify-lib.sh,
# colocated with the library that owns it.
#
# Two properties live here because both were re-created by a fix for the other,
# and each is a whole-alarm property rather than a watcher or daemon detail:
#
#   1. A LIVE SHELL IS NOT A LIVE AGENT. A busy turn record is trusted for up to
#      FM_BUSY_MAX_BUSY_AGE_SECS (default 3600s) from a timestamp stamped when
#      the turn OPENED, so a worker killed mid-turn behind a surviving shell
#      keeps reading busy for up to an hour. Absorbing a wedge on that record
#      alone answers could-not-observe with silence, on exactly the lane the
#      alarm exists for, so the record must be corroborated by a reading that
#      RE-DERIVES per call.
#   2. The absorb-class vocabulary has one owner, and a consumer applying a
#      policy to "nothing absorbed this wake" must ask that owner rather than
#      naming a class. Naming `none` is how the fifth class, `unobserved`,
#      silently opted out of the watcher's dead-agent pause recovery and started
#      spending an extra wake per distinct pane hash on every declared-pause and
#      captain-held lane.
#
# The reader half of (1) - that bin/fm-crew-state.sh actually measures and
# reports agent liveness beside the turn signal - is owned by
# tests/fm-crew-state.test.sh. This file owns what the pair MEANS, and drives the
# real bin/fm-backend.sh probe so the value it feeds the policy is the value the
# reader would have recorded rather than one this test invented.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-tests)

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if
# it died. A watcher that absorbed the wake is one that is still running.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on a pre-existing status line (mirrors fm-watch.sh's stat_sig). The
# lane under test is a STALE-path classification, so its status line must already
# be seen or an unrelated signal wake would decide the run.
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# The measured lane, one layer above where it was measured: a run left `failed`
# by an earlier session-limit kill, a busy turn record still inside its trust
# window, and a pane holding nothing but the shell the agent left behind.
test_dead_agent_behind_live_shell_escalates() {
  local dir state fakebin window probe verdict
  dir=$(make_case dead-agent-live-shell); state="$dir/state"; fakebin="$dir/fakebin"
  window="test:fm-deadagent"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE FM_FAKE_CREW_BUSY FM_FAKE_CREW_AGENT
  printf 'working: driving the gate\n' > "$state/a.status"

  # What the REAL probe says about each pane, so the policy below is fed the
  # reader's own vocabulary rather than a value this test chose. The probe is
  # backend-native and target-bound; nothing here searches process names across
  # the machine, which has twice matched the wrong process in this fleet.
  probe=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude fm_backend_agent_state tmux "$window")
  [ "$probe" = alive ] || fail "the backend probe did not report a harness pane alive, got '$probe'"
  probe=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh fm_backend_agent_state tmux "$window")
  [ "$probe" = dead ] || fail "the backend probe did not report a shell-only pane agent-free, got '$probe'"

  for verdict in failed aborted interrupted; do
    FM_FAKE_CREW_STATE="state: $verdict · source: run-step · killed mid-step by a session-limit wall"
    # The record is identical in every leg below. Only who is still there to be
    # taking that turn changes, which is the entire point.
    FM_FAKE_CREW_BUSY='busy claude-hook'

    # Control: the agent is established alive, so the busy record is corroborated
    # and the lane the alarm kept firing on is absorbed.
    FM_FAKE_CREW_AGENT=alive
    [ "$(crew_absorb_class a)" = working ] \
      || fail "a corroborated live turn after a $verdict run was not classed working"

    # The lane this case exists for: same busy record, agent established gone.
    # This is an OBSERVATION that the crew is not working, so it escalates on the
    # unchanged schedule rather than waiting out the record's trust window.
    for FM_FAKE_CREW_AGENT in dead missing; do
      [ "$(crew_absorb_class a)" = none ] \
        || fail "a busy record behind a '$FM_FAKE_CREW_AGENT' agent after a $verdict run was absorbed"
      ! crew_is_provably_working a \
        || fail "a busy record behind a '$FM_FAKE_CREW_AGENT' agent was called provably working"
    done

    # And the third value, which is where an hour-long trust window actually
    # belongs: liveness that could not be established is cannot-tell, never
    # working. It escalates and says so.
    for FM_FAKE_CREW_AGENT in ambiguous unreadable unverified ''; do
      [ "$(crew_absorb_class a)" = unobserved ] \
        || fail "an uncorroborated busy record ('${FM_FAKE_CREW_AGENT:-unmeasured}') after a $verdict run did not report itself unobserved"
      ! crew_is_provably_working a \
        || fail "an uncorroborated busy record ('${FM_FAKE_CREW_AGENT:-unmeasured}') was called provably working"
    done
  done

  # A verdict that DID observe the crew is untouched by either reading: this
  # corroboration widens no absorb, it only bounds one.
  FM_FAKE_CREW_BUSY='busy claude-hook'
  FM_FAKE_CREW_AGENT=alive
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  [ "$(crew_absorb_class a)" = none ] || fail "agent liveness talked a gate-parked run into absorbing"
  FM_FAKE_CREW_AGENT=dead
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "a dead agent overrode an actively-running run step"

  unset FM_FAKE_CREW_STATE FM_FAKE_CREW_BUSY FM_FAKE_CREW_AGENT FM_CREW_STATE_BIN FM_STATE_OVERRIDE
  pass "a dead agent behind a live shell escalates rather than being absorbed"
}

# The consumer side of the one-owner rule, end to end through the real watcher.
# The lane: a captain-held task whose run ended, whose agent is confidently dead,
# and whose turn evidence was never written - so crew_absorb_class reports
# `unobserved`. That must enter the bounded pause cadence exactly as `none` does,
# because the recovery is about a dead agent under a declared hold, not about
# which non-absorbing token the crew read produced.
test_unobserved_is_subject_to_dead_agent_pause_recovery() {
  local dir state fakebin window key capture statusf pid stale_wakes

  # The membership this rests on, asked of its owner: every class that must
  # surface is covered, and no class that absorbs is.
  for key in none unobserved; do
    crew_absorb_class_surfaces "$key" || fail "crew_absorb_class_surfaces did not cover the surfacing class '$key'"
  done
  for key in working paused settled; do
    ! crew_absorb_class_surfaces "$key" \
      || fail "crew_absorb_class_surfaces reported the absorbing class '$key' as surfacing"
  done

  dir=$(make_case unobserved-pause-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  window="test:fm-classifyheld"
  capture="$dir/pane.txt"; statusf="$state/classifyheld.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'idle bare shell after the agent exited\n' > "$capture"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/classifyheld.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-classifyheld_status"
  # Already stably stale on this hash, so the first poll reaches stale triage.
  printf '%s' "$(hash_text "idle bare shell after the agent exited")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # The crew read: a run that ended, and no turn signal measured for it at all.
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · killed mid-step by a session-limit wall'
  export FM_STATE_OVERRIDE="$state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  [ "$(crew_absorb_class classifyheld "$state")" = unobserved ] \
    || fail "the fixture does not produce an unobserved class, so it proves nothing about it"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  pid=$!
  fm_test_reap "$pid"
  if ! wait_live "$pid" 40; then
    fail "an unobserved crew under a captain hold with a dead agent surfaced instead of entering the pause cadence: $(cat "$dir/watch.out")"
  fi
  [ ! -s "$dir/watch.out" ] \
    || fail "the unobserved captain-held lane printed a wake reason: $(cat "$dir/watch.out")"
  [ -e "$state/.paused-$key" ] \
    || { reap "$pid"; fail "the unobserved captain-held lane did not record the bounded pause cadence marker"; }
  reap "$pid"
  stale_wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || printf 0)
  [ "$stale_wakes" -eq 0 ] \
    || fail "the unobserved captain-held lane queued $stale_wakes stale wakes instead of absorbing on the pause cadence"

  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN FM_STATE_OVERRIDE
  pass "the unobserved class is subject to dead-agent pause recovery"
}

# The other half of the one-owner rule: which semantic classes may be answered by
# a process-liveness reading is a single list, asked by both the watcher's stale
# DETECTION gate and crew_absorb_class. Restating it in either place is how the
# two modes would come to absorb the same crew at different layers.
test_liveness_open_membership_has_one_owner() {
  local class
  for class in $FM_CLASSIFY_LIVENESS_OPEN_CLASSES; do
    crew_semantic_class_leaves_liveness_open "$class" \
      || fail "the declared liveness-open class '$class' was not recognized by its own predicate"
  done
  for class in working paused definite '' not-a-class; do
    ! crew_semantic_class_leaves_liveness_open "$class" \
      || fail "'${class:-empty}' was treated as leaving the crew's own liveness open"
  done
  pass "one owner decides which semantic classes a liveness reading may answer for"
}

# Agent liveness is reduced to three answers, and an unknown reading defaults to
# the one that ESCALATES. A backend that grows a new state must never be able to
# widen an absorb by accident.
test_agent_liveness_verdict_is_fail_safe() {
  local word
  [ "$(crew_agent_liveness_verdict alive)" = alive ] || fail "a verified agent was not reported alive"
  for word in dead missing; do
    [ "$(crew_agent_liveness_verdict "$word")" = gone ] \
      || fail "'$word' was not reported as an established absence"
  done
  for word in ambiguous unreadable unverified unmeasured '' a-state-nobody-taught; do
    [ "$(crew_agent_liveness_verdict "$word")" = unestablished ] \
      || fail "'${word:-empty}' was narrowed to a verdict this reading cannot support"
  done
  pass "agent liveness keeps three values and defaults an untaught state to escalate"
}

test_dead_agent_behind_live_shell_escalates
test_unobserved_is_subject_to_dead_agent_pause_recovery
test_liveness_open_membership_has_one_owner
test_agent_liveness_verdict_is_fail_safe

echo "all fm-classify tests passed"
