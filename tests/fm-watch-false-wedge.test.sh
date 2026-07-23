#!/usr/bin/env bash
# tests/fm-watch-false-wedge.test.sh - regression cover for the two ways
# bin/fm-watch.sh raised stale/possible-wedge wakes for crew that were healthy
# (observed live 2026-07-21 against one task, six false alarms in one session).
#
# Symptom A - a declared pause was not absorbed. A crew whose last status was
# `paused: ...` and whose authoritative state read back `paused` still produced a
# bare `stale: <window>` every couple of minutes, carrying none of the pause
# context. Cause: pause_state_class discarded the paused verdict for any ordinary
# crew whose agent was still alive, and the changed-hash branch then cleared the
# pause tracking outright - so the "surface a live pause once" rule introduced in
# #743 was anchored on the pane hash, and an idle harness pane repaints.
#
# Symptom B - a long quiet step was re-read as a wedge. A crew sitting on an
# actively-running single-command validation step (15-20 minutes with nothing
# rendered) was wedge-escalated every FM_STALE_ESCALATE_SECS, four times in a
# row, reaching demand-deep-inspection while it was healthy every time. Cause:
# the escalation ladder re-fired on elapsed time alone, so each repeat re-reported
# evidence the supervisor already had.
#
# The invariants these tests hold, in both directions:
#   - a declared pause behind a LIVE agent still surfaces (it may be a real
#     decision gate) but exactly once, labeled, however often the pane repaints;
#   - the FIRST wedge escalation still lands at exactly FM_STALE_ESCALATE_SECS;
#   - an unchanged, still-provably-working pane does not re-escalate on that same
#     fixed cadence;
#   - a pane that stops looking active escalates at once, inside the backed-off
#     window, so nothing is traded away for the quiet.
#
# The broader triage matrix lives in fm-watch-triage.test.sh; this file is only
# the two false-alarm regressions and the guards that keep their fixes honest.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-false-wedge-tests)

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
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

# How many absorb decisions the watcher has recorded for <window>. Every stale
# triage path that decides NOT to wake logs one naming the window, so a round can
# wait on the watcher having actually classified the pane.
decisions() {  # <state> <window>
  local n
  n=$(grep -c -F -- "$2" "$1/.watch-triage.log" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Stop <pid> as soon as it has classified <window> this round - it either exited,
# having queued an actionable wake, or logged a fresh absorb decision. Every round
# in this file must wait on that observable outcome rather than on a fixed number
# of seconds: a round that asserts while the watcher is still starting up reads
# the previous round's state, and one that keeps polling after its decision gives
# later polls a chance to churn the markers under the assertions. A round that
# produces neither outcome inside the bound is a failure, never a silent no-op.
settle_round() {  # <state> <window> <pid> <decisions-before> <what>
  local state=$1 window=$2 pid=$3 before=$4 what=$5 i=0
  while [ "$i" -lt 400 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    [ "$(decisions "$state" "$window")" -gt "$before" ] && { reap "$pid"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  fail "$what: the watcher neither woke nor recorded a triage decision for $window within 40s"
}

state_dump() {  # <state> <window>
  local state=$1 window=$2 key m out=""
  key=$(printf '%s' "$window" | tr ':/.' '___')
  for m in count stale-since wedge-escalations wedge-probe wedge-unreadable \
    wedge-unreadable-surfaced paused paused-resurfaced; do
    [ -e "$state/.$m-$key" ] || continue
    out="$out $m=$(tr -d '\n' < "$state/.$m-$key" 2>/dev/null)"
  done
  printf 'markers:%s | triage: %s' "$out" \
    "$(grep -F -- "$window" "$state/.watch-triage.log" 2>/dev/null | tail -4 | tr '\n' '|')"
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

backdate() {  # <file> <seconds-ago>
  local f=$1 secs=$2 when
  when=$(( $(date +%s) - secs ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$when" '+%Y%m%d%H%M.%S')" "$f"
  else touch -m -d "@$when" "$f"; fi
}

stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$1/.wake-queue" 2>/dev/null
}

bare_stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$1/.wake-queue" 2>/dev/null
}

# --- symptom A --------------------------------------------------------------
#
# One watcher run per round, exactly as the fleet behaves: every actionable wake
# exits the watcher and firstmate re-arms it a turn later. Between rounds the
# pane text changes by one character, which is all an idle harness pane does on
# its own (a context counter, a rotating hint) and is what used to re-arm the
# whole classification.

test_declared_pause_with_live_agent_surfaces_once_across_repaints() {
  local dir state fakebin out capture statusf window key round pid wakes bare before
  dir=$(make_case paused-live-repaint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; statusf="$state/paused-live.status"
  window="test:fm-paused-live"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/paused-live.meta"
  printf 'working: implementing\npaused: rebased on current base, awaiting pipeline go-ahead\n' > "$statusf"
  backdate "$statusf" 7200
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-paused-live_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  round=1
  while [ "$round" -le 6 ]; do
    printf 'idle grok prompt, waiting\ncontext left: %s%%\n' "$((90 - round))" > "$capture"
    before=$(decisions "$state" "$window")
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · rebased on current base, awaiting pipeline go-ahead' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
    pid=$!
    settle_round "$state" "$window" "$pid" "$before" "paused-live round $round"
    round=$((round + 1))
  done

  wakes=$(stale_wakes "$state" "$window")
  bare=$(bare_stale_wakes "$state" "$window")
  [ "$wakes" -eq 1 ] || fail "a live-agent declared pause woke firstmate $wakes times across six pane repaints (expected 1): $(cat "$out")"
  [ "$bare" -eq 0 ] || fail "the live-agent pause surfaced $bare bare stale wakes with no pause context"
  grep -F "declared pause" "$out" >/dev/null || fail "the surfaced pause wake did not say it was a declared pause: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was reported as a possible wedge"
  [ -e "$state/.paused-$key" ] || fail "the pause tracking marker did not survive the pane repaints"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a declared pause accumulated wedge escalations"
  pass "a declared pause with a live agent surfaces once, labeled, and stays absorbed across pane repaints"
}

# One watcher round against a paused crew, with the pane text the caller chose.
# The status file is left alone, so the caller owns which pause is declared.
run_paused_round() {  # <dir> <window> <pane-text> <crew-state> <what>
  local dir=$1 window=$2 text=$3 crew_state=$4 what=$5 pid before
  printf '%s\n' "$text" > "$dir/pane.txt"
  before=$(decisions "$dir/state" "$window")
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE="$crew_state" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$dir/watch.out" 2>&1 &
  pid=$!
  settle_round "$dir/state" "$window" "$pid" "$before" "$what"
}

# Declare <line> as <task>'s current pause and hide it from the per-poll signal
# scan, so the round under test exercises the stale path and nothing else.
declare_pause() {  # <state> <task> <line>
  local state=$1 task=$2 line=$3 statusf="$1/$2.status"
  printf '%s\n' "$line" > "$statusf"
  backdate "$statusf" 7200
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-${task}_status"
}

# The other half of symptom A's anchor: "already shown" belongs to the PAUSE
# INSTANCE, not to the window. A crew that declares one pause, is surfaced for
# it, then declares a genuinely DIFFERENT pause has raised a new external-decision
# gate - it must get its own single sighting, not inherit the previous pause's
# suppression and wait out the hour-long recheck cadence before firstmate ever
# hears about it.
test_a_different_declared_pause_gets_its_own_sighting() {
  local dir state window key first second
  dir=$(make_case paused-second-instance); state="$dir/state"
  window="test:fm-paused-two"
  first='paused: rebased on current base, awaiting pipeline go-ahead'
  second='paused: awaiting the captain answer on the schema choice'
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/paused-two.meta"
  declare_pause "$state" paused-two "$first"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  : > "$dir/watch.out"

  run_paused_round "$dir" "$window" 'idle grok prompt, waiting' \
    "state: paused · source: status-log · ${first#paused: }" 'first pause, first sighting'
  [ "$(stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the first declared pause did not surface exactly once: $(cat "$dir/watch.out")"
  [ "$(cat "$state/.paused-resurfaced-$key" 2>/dev/null || true)" = "$first" ] \
    || fail "the already-surfaced marker was not anchored on the pause that was surfaced"

  # Same pause, repainted pane: still absorbed, as symptom A requires.
  run_paused_round "$dir" "$window" 'idle grok prompt, waiting (context left: 88%)' \
    "state: paused · source: status-log · ${first#paused: }" 'first pause, repainted'
  [ "$(stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "a repaint of the SAME pause surfaced again: $(cat "$dir/watch.out")"

  # A different pause: a new gate, and the status file is fresh enough that the
  # hour-long recheck cadence would not have surfaced it for another hour.
  declare_pause "$state" paused-two "$second"
  run_paused_round "$dir" "$window" 'idle grok prompt, waiting (context left: 87%)' \
    "state: paused · source: status-log · ${second#paused: }" 'second pause, first sighting'
  [ "$(stale_wakes "$state" "$window")" -eq 2 ] \
    || fail "a genuinely different declared pause was absorbed silently under the previous pause's suppression: $(cat "$dir/watch.out")"
  [ "$(cat "$state/.paused-resurfaced-$key" 2>/dev/null || true)" = "$second" ] \
    || fail "the already-surfaced marker was not re-anchored on the new pause"
  [ "$(bare_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a declared pause surfaced as a bare stale with no pause context"

  # And the new pause is now the one that is absorbed, so it too surfaces once.
  run_paused_round "$dir" "$window" 'idle grok prompt, waiting (context left: 86%)' \
    "state: paused · source: status-log · ${second#paused: }" 'second pause, repainted'
  [ "$(stale_wakes "$state" "$window")" -eq 2 ] \
    || fail "the new pause did not settle onto the bounded cadence after its one sighting"
  pass "a different declared pause on the same window gets its own single sighting"
}

# The disconfirming half of symptom A: absorbing must be a property of the PAUSE,
# not of the pane. A crew that leaves the pause - here by resuming real work - has
# to lose the pause cadence again on the next reading.
test_pause_absorb_releases_when_the_crew_resumes() {
  local dir state fakebin out capture statusf window key pid
  dir=$(make_case paused-live-resume); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; statusf="$state/resumed.status"
  window="test:fm-resumed"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/resumed.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  backdate "$statusf" 7200
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-resumed_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'idle grok prompt\n' > "$capture"
  : > "$state/.paused-$key"
  : > "$state/.paused-resurfaced-$key"
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # The pause line is still the last status, but the authoritative reader now
  # reports an actively-running pipeline: the run outranks the declaration.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  settle_round "$state" "$window" "$pid" 0 "resumed crew behind a declared pause"
  [ ! -s "$out" ] || fail "an active run behind a declared pause woke firstmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || fail "an active run behind a declared pause kept the pause cadence: $(state_dump "$state" "$window")"
  [ -s "$state/.stale-since-$key" ] || fail "an active run behind a declared pause did not resume wedge tracking: $(state_dump "$state" "$window")"
  pass "an authoritative active run still releases a declared pause back to wedge tracking"
}

# --- symptom B --------------------------------------------------------------
#
# The wedge ladder is driven from the idle clock (.stale-since-<key>) and the
# evidence probe (.wedge-probe-<key>), so a test can place a crew at any point of
# a long quiet step by backdating those two files instead of genuinely sleeping
# out a 15-minute validation step.

# Priming round: first sighting of a stale hash classifies and absorbs it,
# recording the idle clock without going through the escalation path at all.
prime_working_stale() {  # <dir> <window> <task> <pane-text>
  local dir=$1 window=$2 task=$3 text=$4 state="$1/state" fakebin="$1/fakebin" pid before
  printf '%s' "$text" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$task.meta"
  printf 'working: running the suite\n' > "$state/$task.status"
  printf '%s' "$(seen_sig "$state/$task.status")" > "$state/.seen-${task}_status"
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$(printf '%s' "$window" | tr ':/.' '___')"
  printf '1\n' > "$state/.count-$(printf '%s' "$window" | tr ':/.' '___')"
  before=$(decisions "$state" "$window")
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/prime.out" 2>&1 &
  pid=$!
  settle_round "$state" "$window" "$pid" "$before" "priming round for $window"
  [ ! -s "$dir/prime.out" ] || fail "priming round woke firstmate instead of absorbing: $(cat "$dir/prime.out")"
  [ -s "$state/.stale-since-$(printf '%s' "$window" | tr ':/.' '___')" ] \
    || fail "priming round did not record the idle clock: $(state_dump "$state" "$window")"
}

# One watcher round against a crew that is quiet but provably working. <quiet> is
# how long the pane has been idle, <probe-age> how long since the last evidence
# read. Prints nothing; the caller inspects $dir/watch.out and the queue.
run_wedge_round() {  # <dir> <window> <quiet-secs> <probe-age-secs> <crew-state> <what>
  local dir=$1 window=$2 quiet=$3 probe_age=$4 crew_state=$5 what=$6
  local state="$dir/state" fakebin="$dir/fakebin" key pid before
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s\n' $(( $(date +%s) - quiet )) > "$state/.stale-since-$key"
  [ ! -e "$state/.wedge-probe-$key" ] || backdate "$state/.wedge-probe-$key" "$probe_age"
  : > "$dir/watch.out"
  before=$(decisions "$state" "$window")
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$crew_state" \
    FM_STALE_ESCALATE_SECS=240 FM_WEDGE_ESCALATE_MAX_SECS=900 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  settle_round "$state" "$window" "$pid" "$before" "$what"
}

test_long_quiet_step_stops_re_escalating_on_the_fixed_cadence() {
  local dir state window key working
  dir=$(make_case long-quiet-step); state="$dir/state"
  window="test:fm-suite"
  working='state: working · source: run-step · validating (running)'
  prime_working_stale "$dir" "$window" suite "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # The first escalation is the one that decides how fast a real wedge is caught:
  # it must still land the moment the pane has been quiet for the threshold.
  run_wedge_round "$dir" "$window" 245 0 "$working" 'first escalation'
  grep -F "escalation 1" "$dir/watch.out" >/dev/null \
    || fail "the first escalation did not land at the unchanged threshold: $(cat "$dir/watch.out")"
  grep -F "possible wedge" "$dir/watch.out" >/dev/null || fail "the first escalation was not reported as a possible wedge"

  # Four minutes later the suite is still running the same single command and the
  # evidence is identical. This is the false alarm: it must not re-escalate.
  run_wedge_round "$dir" "$window" 300 300 "$working" 'unchanged repeat inside the window'
  [ ! -s "$dir/watch.out" ] \
    || fail "an unchanged, still-working quiet pane re-escalated on the old fixed cadence: $(cat "$dir/watch.out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 1 ] \
    || fail "the escalation ladder advanced without new evidence"

  # Past the backed-off window it does escalate again, so the ladder is spaced,
  # never abandoned.
  run_wedge_round "$dir" "$window" 500 300 "$working" 'repeat past the backed-off window'
  grep -F "escalation 2" "$dir/watch.out" >/dev/null \
    || fail "the ladder did not escalate past its backed-off window: $(cat "$dir/watch.out")"
  pass "a long quiet step escalates once at the threshold, then only past the backed-off window"
}

# The guard that keeps the quiet honest: nothing is suppressed. The instant the
# crew stops looking active, that is new evidence and it surfaces at the next
# reading - inside the backed-off window, and without waiting it out.
test_lost_work_signal_escalates_inside_the_backoff_window() {
  local dir state window key
  dir=$(make_case lost-work-signal); state="$dir/state"
  window="test:fm-lost"
  prime_working_stale "$dir" "$window" lost "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  run_wedge_round "$dir" "$window" 245 0 'state: working · source: run-step · validating (running)' 'first escalation'
  grep -F "escalation 1" "$dir/watch.out" >/dev/null || fail "the first escalation did not land: $(cat "$dir/watch.out")"

  # 300s of quiet is inside the backed-off window (480s), so an unchanged verdict
  # would stay absorbed - but the run is gone now.
  run_wedge_round "$dir" "$window" 300 300 'state: unknown · source: none · no current-state source available' 'lost work signal'
  grep -F "escalation 2" "$dir/watch.out" >/dev/null \
    || fail "a crew whose work signal disappeared was held back by the backoff window: $(cat "$dir/watch.out")"
  grep -F "work signal is gone" "$dir/watch.out" >/dev/null \
    || fail "the escalation did not report WHY it fired (lost work signal): $(cat "$dir/watch.out")"
  pass "a pane that stops looking active escalates at once, inside the backed-off window"
}

# The evidence probe is only evidence when the read SUCCEEDED. A failed state read
# (timeout, contention, an unresolvable task id) says nothing about the crew, so it
# must not advance the ladder, must not shortcut the backed-off window the way a
# real verdict change does, and must never be reported as a lost work signal.
test_unreadable_state_read_is_not_a_lost_work_signal() {
  local dir state window key working
  dir=$(make_case unreadable-probe); state="$dir/state"
  window="test:fm-unreadable"
  working='state: working · source: run-step · validating (running)'
  prime_working_stale "$dir" "$window" unreadable "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  run_wedge_round "$dir" "$window" 245 0 "$working" 'first escalation'
  grep -F "escalation 1" "$dir/watch.out" >/dev/null || fail "the first escalation did not land: $(cat "$dir/watch.out")"

  # The reader now fails: its output carries no verdict line at all.
  run_wedge_round "$dir" "$window" 300 300 'fm-crew-state.sh: timed out resolving the task' 'unreadable probe 1'
  [ ! -s "$dir/watch.out" ] \
    || fail "a failed crew-state read woke firstmate as though the crew had stopped: $(cat "$dir/watch.out")"
  grep -F "work signal is gone" "$dir/watch.out" >/dev/null \
    && fail "a failed crew-state read was reported as a confirmed lost work signal"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 1 ] \
    || fail "an unreadable verdict advanced the escalation ladder"
  [ "$(cat "$state/.wedge-probe-$key" 2>/dev/null || true)" = working ] \
    || fail "an unreadable verdict overwrote the last evidence actually observed"
  [ "$(cat "$state/.wedge-unreadable-$key" 2>/dev/null || echo 0)" = 1 ] \
    || fail "the consecutive-unreadable count was not recorded: $(state_dump "$state" "$window")"

  # ... and it did not leave the next probe looking like a changed verdict, so an
  # unchanged, still-working crew stays inside its backed-off window.
  run_wedge_round "$dir" "$window" 360 300 "$working" 'probe after an unreadable read'
  [ ! -s "$dir/watch.out" ] \
    || fail "an unreadable read let the next probe bypass the backed-off window: $(cat "$dir/watch.out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 1 ] \
    || fail "the ladder advanced without new evidence after an unreadable read"
  [ ! -e "$state/.wedge-unreadable-$key" ] \
    || fail "a readable verdict did not drop the consecutive-unreadable count: $(state_dump "$state" "$window")"

  # Nothing is traded away: once the read recovers AND the verdict really changed,
  # the escalation lands at the next probe as before.
  run_wedge_round "$dir" "$window" 400 300 'state: unknown · source: none · no current-state source available' 'verdict change after an unreadable read'
  grep -F "escalation 2" "$dir/watch.out" >/dev/null \
    || fail "a genuine verdict change after an unreadable read did not escalate: $(cat "$dir/watch.out")"
  pass "a failed crew-state read is unknown evidence: no ladder advance, no backoff bypass, no lost-work-signal claim"
}

# The other direction of the same rule: "no evidence" must not become "no alarm,
# ever". A reader that is permanently broken would otherwise leave this window's
# wedge detector silent forever - a missed real wedge traded for the false ones
# this branch removes - so the failure itself surfaces on a bounded cadence, on
# its own terms: it names the reader and claims neither a wedge nor a stop.
test_permanently_failing_reader_still_surfaces_on_a_bounded_cadence() {
  local dir state window key broken
  dir=$(make_case unreadable-forever); state="$dir/state"
  window="test:fm-noreader"
  broken='fm-crew-state.sh: cannot resolve the task'
  prime_working_stale "$dir" "$window" noreader "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  run_wedge_round "$dir" "$window" 245 0 "$broken" 'unreadable probe 1'
  [ ! -s "$dir/watch.out" ] || fail "the first unreadable probe woke firstmate: $(cat "$dir/watch.out")"
  run_wedge_round "$dir" "$window" 300 300 "$broken" 'unreadable probe 2'
  [ ! -s "$dir/watch.out" ] || fail "the second unreadable probe woke firstmate: $(cat "$dir/watch.out")"

  run_wedge_round "$dir" "$window" 360 300 "$broken" 'unreadable probe 3'
  grep -F "UNREADABLE" "$dir/watch.out" >/dev/null \
    || fail "a permanently failing reader never surfaced: $(cat "$dir/watch.out") $(state_dump "$state" "$window")"
  grep -F "crew-state reader" "$dir/watch.out" >/dev/null \
    || fail "the wake did not name the reader failure: $(cat "$dir/watch.out")"
  grep -F "possible wedge" "$dir/watch.out" >/dev/null \
    && fail "an unreadable reader was reported as a confirmed wedge: $(cat "$dir/watch.out")"
  grep -F "work signal is gone" "$dir/watch.out" >/dev/null \
    && fail "an unreadable reader was reported as a confirmed stop: $(cat "$dir/watch.out")"
  grep -F "demand-deep-inspection" "$dir/watch.out" >/dev/null \
    && fail "an unreadable reader climbed the wedge ladder to demand-deep-inspection"
  [ "$(stale_wakes "$state" "$window")" -eq 1 ] || fail "the bounded unreadable surfacing did not queue exactly one wake"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an unreadable reader advanced the wedge escalation ladder: $(state_dump "$state" "$window")"

  [ "$(cat "$state/.wedge-unreadable-surfaced-$key" 2>/dev/null || echo 0)" = 1 ] \
    || fail "the unreadable surfacing was not counted: $(state_dump "$state" "$window")"

  # It neither spams nor falls silent again, and the repeats are SPACED by the
  # same doubling window the escalation ladder uses - not repeated every N probes.
  # Each round below backdates the last-surfacing marker to place the watcher at a
  # chosen point of that window, so the two cadences are told apart rather than
  # both being satisfied by "a wake happened eventually".
  backdate "$state/.wedge-unreadable-surfaced-$key" 300
  run_wedge_round "$dir" "$window" 420 300 "$broken" 'unreadable probe inside the 480s window'
  [ "$(stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the second unreadable surfacing fired inside its backed-off window: $(cat "$dir/watch.out")"

  backdate "$state/.wedge-unreadable-surfaced-$key" 500
  run_wedge_round "$dir" "$window" 480 300 "$broken" 'unreadable probe past the 480s window'
  [ "$(stale_wakes "$state" "$window")" -eq 2 ] \
    || fail "a reader that stayed broken fell silent instead of re-surfacing: $(state_dump "$state" "$window")"

  # ... and the window widened again, so what was long enough last time is not now.
  backdate "$state/.wedge-unreadable-surfaced-$key" 500
  run_wedge_round "$dir" "$window" 540 300 "$broken" 'unreadable probe inside the widened window'
  [ "$(stale_wakes "$state" "$window")" -eq 2 ] \
    || fail "the repeat interval did not widen after the second surfacing: $(state_dump "$state" "$window")"
  backdate "$state/.wedge-unreadable-surfaced-$key" 905
  run_wedge_round "$dir" "$window" 600 300 "$broken" 'unreadable probe past the widened window'
  [ "$(stale_wakes "$state" "$window")" -eq 3 ] \
    || fail "the backed-off repeat never arrived: $(state_dump "$state" "$window")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "repeat unreadable surfacings advanced the wedge escalation ladder: $(state_dump "$state" "$window")"

  # Any readable verdict drops both counts, so a recovered reader starts clean.
  run_wedge_round "$dir" "$window" 660 300 'state: working · source: run-step · validating (running)' 'reader recovers'
  [ ! -e "$state/.wedge-unreadable-$key" ] && [ ! -e "$state/.wedge-unreadable-surfaced-$key" ] \
    || fail "a readable verdict left the unreadable bookkeeping behind: $(state_dump "$state" "$window")"
  pass "a permanently failing crew-state reader surfaces, then backs off, never as a wedge or a stop"
}

# A crew that declares an external wait between the loop's status read and the
# probe is not a stopped crew: the probe hands it to the bounded pause cadence
# rather than escalating it with the lost-work-signal wording.
test_paused_probe_verdict_goes_to_the_pause_cadence() {
  local dir state window key
  dir=$(make_case probe-turns-paused); state="$dir/state"
  window="test:fm-probe-paused"
  prime_working_stale "$dir" "$window" probepaused "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  run_wedge_round "$dir" "$window" 245 0 'state: working · source: run-step · validating (running)' 'first escalation'
  grep -F "escalation 1" "$dir/watch.out" >/dev/null || fail "the first escalation did not land: $(cat "$dir/watch.out")"

  run_wedge_round "$dir" "$window" 300 300 'state: paused · source: status-log · awaiting the upstream release' 'probe reading back paused'
  grep -F "work signal is gone" "$dir/watch.out" >/dev/null \
    && fail "a declared external wait was reported as a stopped crew"
  grep -F "possible wedge" "$dir/watch.out" >/dev/null \
    && fail "a declared external wait was reported as a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 0 ] \
    || fail "a declared external wait kept climbing the wedge ladder"
  [ -e "$state/.paused-$key" ] \
    || fail "a paused probe verdict did not hand the pane to the bounded pause cadence"
  pass "a paused probe verdict is handed to the pause cadence, not escalated as a stopped crew"
}

test_demand_deep_inspection_still_reached_for_a_persistent_wedge() {
  local dir state window key n quiet
  dir=$(make_case persistent-wedge); state="$dir/state"
  window="test:fm-frozen"
  prime_working_stale "$dir" "$window" frozen "no-mistakes axi run: test step"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # Each round waits out that round's own (growing) window: 240, 480, then the
  # 900s cap. The ladder must still reach demand-deep-inspection.
  n=1
  for quiet in 245 485 905; do
    run_wedge_round "$dir" "$window" "$quiet" 905 'state: working · source: run-step · validating (running)' "backed-off round $n"
    grep -F "escalation $n" "$dir/watch.out" >/dev/null \
      || fail "round $n did not escalate after waiting out its window: $(cat "$dir/watch.out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$dir/watch.out" >/dev/null \
        && fail "round $n demanded deep inspection before the threshold: $(cat "$dir/watch.out")"
    else
      grep -F "demand-deep-inspection" "$dir/watch.out" >/dev/null \
        || fail "the ladder never reached demand-deep-inspection: $(cat "$dir/watch.out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] \
    || fail "the escalation counter did not persist across the backed-off rounds"
  pass "a genuinely persistent wedge still climbs the ladder to demand-deep-inspection"
}

test_declared_pause_with_live_agent_surfaces_once_across_repaints
test_a_different_declared_pause_gets_its_own_sighting
test_pause_absorb_releases_when_the_crew_resumes
test_long_quiet_step_stops_re_escalating_on_the_fixed_cadence
test_lost_work_signal_escalates_inside_the_backoff_window
test_unreadable_state_read_is_not_a_lost_work_signal
test_permanently_failing_reader_still_surfaces_on_a_bounded_cadence
test_paused_probe_verdict_goes_to_the_pause_cadence
test_demand_deep_inspection_still_reached_for_a_persistent_wedge
