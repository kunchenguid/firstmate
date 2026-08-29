#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# tests/fm-watch-pause-absorb.test.sh - a DECLARED pause must be honoured on its
# own evidence, independent of what the crewmate's terminal or its attributed
# review run happens to be doing.
#
# The 2026-08-03 incident this suite pins down: lane priors-882-rebase-c8 declared
# `paused: work complete and verified; waiting on the merge of PR 882` with its one
# keyed decision opened AND explicitly resolved, yet wedge-escalated eight times in
# a row as a suspected wedge and never once created state/.paused-<key>. The
# supervisor's hypothesis was pane liveness (its agent was alive and idle at the
# composer, while a comparison lane whose agent was quota-dead did absorb). That was
# WRONG, and this suite encodes the refutation: absorption never consulted pane
# liveness at all. crew_absorb_class asked fm-crew-state.sh for one authoritative
# verdict and admitted the declared pause only when that verdict was exactly `done`
# (bin/fm-classify-lib.sh, the `done`-only carve-out added in #53). Any other verdict
# - `parked` (c8: its recycled worktree had been re-checked-out onto ANOTHER lane's
# branch, so a foreign parked run was attributed to it), `failed` (a routinely
# CANCELLED run maps here too), or `unknown` (backend target gone, i.e. a genuinely
# DEAD pane) - discarded the pause and returned `none`, so the watcher took
# surface_nonterminal_stale and emitted a bare `stale: <window>`.
#
# The dead-pane branch is the direct refutation: a gone pane classified `unknown` and
# was surfaced, so "only a dead pane reaches the pause path" had the truth backwards.
# The comparison lane absorbed because a quota-dead agent has no attributed run at
# all, which routes fm-crew-state.sh to its status-log fallback and reports `paused` -
# an absence-of-run effect, not a pane-liveness effect.
#
# Four branches, one per row of the truth table, driven through a REAL fm-watch.sh:
#   live-idle paused           run-step `parked`, pane alive and idle -> ABSORB
#   dead paused                pane gone, verdict `unknown`           -> ABSORB
#   paused + OPEN decision     an unanswered question                 -> SURFACE
#   paused + CLOSED decision   opened then resolved (the c8 shape)    -> ABSORB
#
# The third row is the safety boundary and the reason this is not simply "absorb
# every pause": a lane with an unanswered captain question must never go quiet, so
# the open/resolved fold (status_open_decisions) gates absorption independently of
# the pause verb. Run this file on demand to reproduce the incident.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

fm_test_tmproot_into TMP_ROOT fm-watch-pause-absorb-tests

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

kill_tree() {  # <pid>
  local child
  kill -STOP "$1" 2>/dev/null || true
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -9 "$1" 2>/dev/null || true
}
reap() {
  kill_tree "$1"
  wait "$1" 2>/dev/null || true
}

wait_live() {
  local pid=$1 limit i=0
  limit=$(fm_test_liveness_iterations "${2:-30}" 0.1)
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Drive one real fm-watch.sh poll cycle over a single stale, idle, paused pane and
# report what triage did with it. Sets four globals rather than echoing, so a case
# can assert on the durable artifacts as well as the outcome: TRIAGE (absorbed or
# surfaced), PAUSE_FLAG, WAKE_QUEUE, WATCH_OUT. Call it directly, never in a command
# substitution, or the globals are lost with the subshell.
#
# <verdict> is the canned fm-crew-state.sh answer - the ONE input the old
# implementation keyed its whole decision on, which is why each branch below differs
# only in that string and in the status stream. The pane is primed as already-stale
# (.hash/.count pre-seeded) so the poll reaches stale triage immediately, and
# .seen-* is primed so the signal scan does not pre-empt it. A generous
# FM_PAUSE_RESURFACE_SECS keeps a legitimate absorb silent, so any wake at all is a
# genuine surface rather than the hourly pause recheck.
# PRESEED_PAUSED=1 makes the case start from an already-absorbed pause: the
# .paused-<key> flag plus a fresh .paused-rechecked-<key> marker, as a lane that
# absorbed on an earlier poll would carry. Used to prove the cached verdict cannot
# outlive the status stream it was proven from.
PRESEED_PAUSED=0
run_pause_case() {  # <case-name> <status-stream> <crew-state-verdict>
  local name=$1 stream=$2 verdict=$3
  local dir state fakebin out capture window key pane_hash sig pid
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-$name"
  printf 'idle at the composer' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$name.meta"
  printf '%s' "$stream" > "$state/$name.status"
  sig=$(seen_sig "$state/$name.status"); printf '%s' "$sig" > "$state/.seen-${name}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at the composer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  if [ "$PRESEED_PAUSED" = 1 ]; then
    # A stale cache: flagged paused, rechecked seconds ago, but proven against a
    # DIFFERENT (earlier) status stream than the one on disk now.
    : > "$state/.paused-$key"
    printf 'stale-signature-from-an-earlier-stream' > "$state/.paused-rechecked-$key"
  fi

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$verdict" FM_PAUSE_RESURFACE_SECS=999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  if wait_live "$pid" 30; then TRIAGE=absorbed; else TRIAGE=surfaced; fi
  reap "$pid"

  # Cross-check the outcome against the durable artifacts triage leaves behind, so a
  # case can never pass on liveness timing alone.
  PAUSE_FLAG=absent; [ -e "$state/.paused-$key" ] && PAUSE_FLAG=present
  WAKE_QUEUE=$(cat "$state/.wake-queue" 2>/dev/null || true)
  WATCH_OUT=$(cat "$out" 2>/dev/null || true)
}

# --- branch 1: live-but-idle paused pane -----------------------------------------
# The exact c8 shape. Its worktree had been recycled onto another lane's branch, so
# fm-crew-state.sh attributed that foreign run and answered `parked`. The pane was
# alive and idle at the composer the whole time. A pause is a statement about the
# WORK, so a run-step that is merely parked must not veto it.
test_live_idle_paused_pane_absorbed() {
  run_pause_case live-idle-paused \
    'paused: work complete and verified; waiting on the merge of PR 882 by the main firstmate
' \
    'state: parked · source: run-step · parked at ci: 1 finding(s)'
  [ "$TRIAGE" = absorbed ] \
    || fail "live-but-idle declared pause was surfaced as a suspected wedge: $WATCH_OUT"
  [ "$PAUSE_FLAG" = present ] \
    || fail "live-but-idle declared pause never recorded .paused-<key> (handle_paused_stale did not run)"
  [ -z "$WAKE_QUEUE" ] || fail "live-but-idle declared pause enqueued a wake: $WAKE_QUEUE"
  pass "live-but-idle paused pane: a parked run-step no longer vetoes a declared pause"
}

# --- branch 2: dead paused pane --------------------------------------------------
# The refutation of the pane-liveness hypothesis. A gone backend target makes
# fm-crew-state.sh answer `unknown · source: none`, which the old carve-out treated
# exactly like `parked` - discarded. So a DEAD pane was surfaced too, and pane
# liveness was never the discriminator in either direction.
test_dead_paused_pane_absorbed() {
  run_pause_case dead-paused \
    'paused: agent is quota-dead, work preserved and verified; waiting on the account reset
' \
    'state: unknown · source: none · backend target gone: test:fm-dead-paused'
  [ "$TRIAGE" = absorbed ] \
    || fail "declared pause with a gone pane was surfaced as a suspected wedge: $WATCH_OUT"
  [ "$PAUSE_FLAG" = present ] \
    || fail "declared pause with a gone pane never recorded .paused-<key>"
  [ -z "$WAKE_QUEUE" ] || fail "declared pause with a gone pane enqueued a wake: $WAKE_QUEUE"
  pass "dead paused pane: a declared pause is honoured with no readable terminal at all"
}

# --- branch 3: paused with an OPEN decision --------------------------------------
# The safety boundary. The pause verb is the LAST line, so a last-line read alone
# says "absorb"; only the durable open/resolved fold sees the still-unanswered
# question underneath it. That lane must keep surfacing.
test_paused_with_open_decision_surfaced() {
  run_pause_case paused-open-decision \
    'needs-decision [key=rollback-empty-pointer]: merge as-is, or fix the empty-pointer refusal here?
paused: standing by for the decision on the rollback gap
' \
    'state: unknown · source: none · backend target gone: test:fm-paused-open-decision'
  [ "$TRIAGE" = surfaced ] \
    || fail "a pause masking an UNANSWERED decision was absorbed and went quiet"
  [ "$PAUSE_FLAG" = absent ] \
    || fail "a pause masking an unanswered decision was flagged .paused-<key>"
  printf '%s' "$WAKE_QUEUE" | grep -q 'stale' \
    || fail "a pause masking an unanswered decision did not enqueue a stale wake: $WAKE_QUEUE"
  pass "paused with an OPEN decision: an unanswered question still surfaces, pause verb notwithstanding"
}

# --- branch 4: paused with a CLOSED decision -------------------------------------
# c8's real status stream: working -> done -> needs-decision[key] -> resolved[key] ->
# paused. The keyed decision was explicitly closed, so nothing is outstanding and the
# pause is the lane's current, honest statement about its work.
test_paused_with_closed_decision_absorbed() {
  run_pause_case paused-closed-decision \
    'working: rebased PR 882 onto current main, pushed 590fe3ff7, awaiting fresh CI
done: PR https://github.com/Ruby-Labs/relvino/pull/882 checks green; NOT merged
needs-decision [key=rollback-empty-pointer]: merge as-is, or fix the empty-pointer refusal here?
resolved [key=rollback-empty-pointer]: option (a) approved - merge this rebase as-is
paused: work complete and verified; waiting on the merge of PR 882 by the main firstmate
' \
    'state: parked · source: run-step · parked at ci: 1 finding(s)'
  [ "$TRIAGE" = absorbed ] \
    || fail "a pause whose only decision was explicitly resolved was surfaced: $WATCH_OUT"
  [ "$PAUSE_FLAG" = present ] \
    || fail "a pause whose only decision was explicitly resolved never recorded .paused-<key>"
  [ -z "$WAKE_QUEUE" ] || fail "a resolved-then-paused lane enqueued a wake: $WAKE_QUEUE"
  pass "paused with a CLOSED decision: the resolved-then-paused c8 shape absorbs"
}

# --- the same four branches at the classifier level -------------------------------
# The behavioral cases above prove the watcher wires this correctly; this matrix pins
# the decision itself, including the run-step verdicts that used to veto a pause and
# the `working` verdict that legitimately still does.
test_crew_absorb_class_pause_matrix() {
  local dir state fakebin
  dir=$(make_case absorb-pause-matrix); state="$dir/state"; fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE FM_STATE_OVERRIDE="$state"

  local paused='paused: waiting on the merge of PR 882'
  printf '%s\n' "$paused" > "$state/a.status"

  # Every non-working verdict must yield to the declared pause, including the three
  # that used to veto it.
  local v
  for v in 'state: parked · source: run-step · parked at ci: 1 finding(s)' \
           'state: failed · source: run-step · run cancelled' \
           'state: unknown · source: none · backend target gone' \
           'state: done · source: run-step · run passed: PR merged (verified)' \
           'state: paused · source: status-log · waiting on the merge'; do
    FM_FAKE_CREW_STATE="$v"
    [ "$(crew_absorb_class a "$paused")" = paused ] \
      || fail "declared pause not honoured over verdict [$v]"
    crew_is_paused a || fail "crew_is_paused disagreed with the class for verdict [$v]"
  done

  # A crewmate that appended a pause and then STARTED working is working, not paused:
  # active work supersedes the stale declaration. This precedence is unchanged.
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a "$paused")" = working ] \
    || fail "an active run-step did not outrank a stale pause declaration"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a "$paused")" = working ] \
    || fail "a busy pane did not outrank a stale pause declaration"

  # The pause must be read from the durable stream even when no caller passes it,
  # so the two call sites in bin/fm-watch.sh cannot disagree.
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at ci: 1 finding(s)'
  [ "$(crew_absorb_class a)" = paused ] \
    || fail "the declared pause was not read from the status stream when unspecified"

  # An open keyed decision blocks absorption on every verdict.
  printf 'needs-decision [key=api-shape]: which shape?\n%s\n' "$paused" > "$state/a.status"
  for v in 'state: parked · source: run-step · parked at ci: 1 finding(s)' \
           'state: unknown · source: none · backend target gone' \
           'state: done · source: run-step · run passed: PR merged (verified)' \
           'state: paused · source: status-log · waiting on the merge'; do
    FM_FAKE_CREW_STATE="$v"
    [ "$(crew_absorb_class a "$paused")" = none ] \
      || fail "an OPEN decision failed to block absorption under verdict [$v]"
  done
  # ...and stops blocking once it is explicitly resolved.
  printf 'needs-decision [key=api-shape]: which shape?\nresolved [key=api-shape]: option (a)\n%s\n' "$paused" > "$state/a.status"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at ci: 1 finding(s)'
  [ "$(crew_absorb_class a "$paused")" = paused ] \
    || fail "a resolved decision still blocked absorption"

  # A FAILURE reported under the pause verb is not a wait and must never absorb.
  local failpause='paused: error: drive run: reconcile run: read response: i/o timeout'
  printf '%s\n' "$failpause" > "$state/a.status"
  FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone'
  [ "$(crew_absorb_class a "$failpause")" = none ] \
    || fail "a failure reported under the pause verb was absorbed as a declared wait"

  # No pause at all is never inferred: absence of a signal is not evidence of a pause.
  printf 'working: still going\n' > "$state/a.status"
  FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone'
  [ "$(crew_absorb_class a)" = none ] || fail "a lane with no pause was absorbed"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a declared pause outranks every verdict but working, and an open decision blocks it"
}

# --- a cached pause verdict cannot outlive the stream it was proven from ----------
# pause_state_class skips the authoritative re-read while a recent recheck marker
# stands, so that cache is the one way an open decision could still slip past the
# boundary: a lane absorbs cleanly, THEN appends needs-decision and re-declares its
# pause, leaving the pause verb on the last line again. The marker carries the status
# signature it was proven against, so any append invalidates it and forces a fresh
# proof instead of riding out the age window.
test_cached_pause_verdict_reproven_when_stream_changes() {
  PRESEED_PAUSED=1
  run_pause_case cached-pause-stale-proof \
    'paused: waiting on the merge of PR 882
needs-decision [key=rollback-empty-pointer]: merge as-is, or fix the empty-pointer refusal here?
paused: standing by for the decision on the rollback gap
' \
    'state: unknown · source: none · backend target gone: test:fm-cached-pause-stale-proof'
  PRESEED_PAUSED=0
  [ "$TRIAGE" = surfaced ] \
    || fail "a decision opened after the pause flag rode out the cache window and went quiet"
  printf '%s' "$WAKE_QUEUE" | grep -q 'stale' \
    || fail "the re-proven pause did not enqueue a stale wake: $WAKE_QUEUE"
  pass "a cached pause verdict is re-proven whenever the status stream changes under it"
}

test_pause_moving_during_pipeline_read_refused() {
  export FM_FAKE_CREW_STATE_APPEND_STATUS='blocked: stream advanced during pipeline state read'
  run_pause_case pause-moved-during-proof \
    'paused: awaiting ordered PR merges
' \
    'state: parked · source: run-step · parked at ci: 1 finding(s)'
  unset FM_FAKE_CREW_STATE_APPEND_STATUS
  [ "$TRIAGE" = surfaced ] \
    || fail "a pause invalidated during the crew-state read was absorbed"
  [ "$PAUSE_FLAG" = absent ] \
    || fail "a pause invalidated during the crew-state read wrote .paused-<key>"
  pass "a pause invalidated during pipeline-state validation fails closed"
}

# A busy fleet can present one changed blocked status before a sibling's changed
# paused status in the same signal scan. The actionable status makes wake() exit,
# so pause registration must happen in the pre-wake reconciliation phase rather
# than waiting for the later pane sweep.
test_busy_fleet_registers_pause_before_actionable_signal_exit() {
  local dir state fakebin out action_window pause_window pause_key pid
  dir=$(make_case busy-fleet-pause-registration); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  action_window="default:wA:pAA"
  pause_window="default:wF:pGY"
  pause_key=$(printf '%s' "$pause_window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\n' "$action_window" > "$state/a-action.meta"
  printf 'blocked: needs supervisor attention\n' > "$state/a-action.status"
  printf 'window=%s\nkind=ship\n' "$pause_window" > "$state/z-paused.meta"
  printf 'paused: awaiting external PR review and green rollout\n' > "$state/z-paused.status"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { reap "$pid"; fail "watcher did not surface the actionable busy-fleet signal"; }

  grep -F "signal:" "$out" >/dev/null \
    || fail "busy-fleet fixture did not exit through the signal path: $(cat "$out")"
  [ -e "$state/.paused-$pause_key" ] \
    || fail "actionable sibling signal exited before the declared pause was registered"
  [ -e "$state/.paused-rechecked-$pause_key" ] \
    || fail "busy-fleet pause registration did not retain its authoritative proof"
  [ ! -e "$state/.paused-resurfaced-$pause_key" ] \
    || fail "active work was pause-rechecked while registering the declaration"
  [ ! -e "$state/.stale-since-$pause_key" ] \
    || fail "registered pause retained the shorter wedge timer"
  pass "busy fleet: a declared pause is registered before an actionable sibling signal exits the watcher"
}

# Registration must not become permanent suppression. Start from the busy-fleet
# shape above, age the declared pause past its configured window, and leave another
# actionable sibling signal pending. The pre-wake phase must surface the pause on
# its bounded cadence instead of letting the sibling starve rechecks indefinitely.
test_busy_fleet_registered_pause_still_resurfaces() {
  local dir state fakebin out action_window pause_window pause_key statusf sig back pid
  dir=$(make_case busy-fleet-pause-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  action_window="default:wA:pAB"
  pause_window="default:wF:pGZ"
  pause_key=$(printf '%s' "$pause_window" | tr ':/.' '___')
  statusf="$state/z-paused.status"
  printf 'window=%s\nkind=ship\n' "$action_window" > "$state/a-action.meta"
  printf 'blocked: fresh sibling wake must not starve pause cadence\n' > "$state/a-action.status"
  printf 'window=%s\nkind=ship\n' "$pause_window" > "$state/z-paused.meta"
  printf 'paused: awaiting external PR review and green rollout\n' > "$statusf"
  back=$(( $(date +%s) - 10 ))
  if [ "$(uname)" = Darwin ]; then
    touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else
    touch -m -d "@$back" "$statusf"
  fi
  sig=$(seen_sig "$statusf")
  : > "$state/.paused-$pause_key"
  printf '%s' "$sig" > "$state/.paused-rechecked-$pause_key"
  printf '%s' "$sig" > "$state/.seen-z-paused_status"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { reap "$pid"; fail "registered pause did not re-surface on its bounded cadence"; }

  grep -F "stale: $pause_window" "$out" >/dev/null \
    || fail "bounded pause recheck was starved by the actionable sibling: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null \
    || fail "bounded recheck was not identified as a declared external wait"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "bounded pause recheck was mislabeled as a possible wedge"
  [ -e "$state/.paused-$pause_key" ] \
    || fail "bounded recheck removed the durable pause registration"
  [ -e "$state/.paused-resurfaced-$pause_key" ] \
    || fail "bounded recheck did not persist its throttle marker"
  [ ! -e "$state/.stale-since-$pause_key" ] \
    || fail "bounded pause recheck started the wedge timer"
  pass "busy fleet: a registered pause still re-surfaces on its bounded long cadence"
}

test_cached_pause_does_not_outrank_new_active_run() {
  local dir state fakebin out window key statusf back pid i
  dir=$(make_case cached-pause-active-run); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="default:wF:pHA"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  statusf="$state/cached-pause-active-run.status"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/cached-pause-active-run.meta"
  printf 'paused: awaiting external PR review and green rollout\n' > "$statusf"
  back=$(( $(date +%s) - 10 ))
  if [ "$(uname)" = Darwin ]; then
    touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else
    touch -m -d "@$back" "$statusf"
  fi

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone' \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt "$(fm_test_liveness_iterations 30 0.1)" ] && [ ! -e "$state/.paused-$key" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.paused-$key" ] \
    || { reap "$pid"; fail "cycle 1 did not prove and register the declared pause"; }
  [ -e "$state/.paused-rechecked-$key" ] \
    || { reap "$pid"; fail "cycle 1 did not cache its durable pause proof"; }
  reap "$pid"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_PAUSE_RESURFACE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_live "$pid" 30 \
    || { reap "$pid"; fail "cached pause surfaced after the lane started active work: $(cat "$out")"; }
  reap "$pid"

  [ -e "$state/.paused-$key" ] \
    || fail "active work erased the independently proven pause registration"
  [ ! -e "$state/.paused-resurfaced-$key" ] \
    || fail "active work emitted the due pause recheck"
  [ ! -s "$state/.wake-queue" ] \
    || fail "active work was absorbed as an idle pause: $(cat "$state/.wake-queue")"
  pass "cached pause: a newly active run outranks unchanged durable pause status"
}

test_live_idle_paused_pane_absorbed
test_dead_paused_pane_absorbed
test_paused_with_open_decision_surfaced
test_paused_with_closed_decision_absorbed
test_cached_pause_verdict_reproven_when_stream_changes
test_pause_moving_during_pipeline_read_refused
test_busy_fleet_registers_pause_before_actionable_signal_exit
test_busy_fleet_registered_pause_still_resurfaces
test_cached_pause_does_not_outrank_new_active_run
test_crew_absorb_class_pause_matrix
