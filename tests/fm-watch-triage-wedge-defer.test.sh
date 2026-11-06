#!/usr/bin/env bash
# Behavior tests for watcher wedge-threshold deferrals to declared waits,
# captain holds, parked gates, worker blockers, and validation runs
# (bin/fm-watch.sh). Shared fixtures live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-wedge-defer-tests)

# Arm the opt-in parked-gate wait evidence for a fixture built above.
arm_parked_gate() {  # <case-dir>
  : > "$1/config/wedge-defer-parked-gate"
}

# The wait age the deferral PUBLISHES to the captain, read back off the wake it
# emitted. The wake reason is the watcher's supervisor-facing output contract, so
# the number in it is the thing under test: it must describe the wait that is
# actually holding the lane, not whatever unrelated record happened to be handy.
wedge_reported_wait_secs() {  # <watch-out>
  sed -n 's/.*waiting \([0-9][0-9]*\)s.*/\1/p' "$1" | head -1
}

test_wedge_threshold_defers_to_a_declared_wait_under_a_working_verdict() {
  local dir state fakebin out capture window key n past reported
  local working='state: working · source: run-step · ci running'

  dir=$(wedge_threshold_fixture declared-wait-working \
    'paused: final validation at step 6/6 - clean whole-assembly baseline (~20 min)' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a declared wait wedge-escalated at threshold $n under a working verdict: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a declared wait queued a wedge wake under a working verdict: $(cat "$state/.wake-queue")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a declared wait was reported as a possible wedge"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a declared wait counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # The declared half keeps the status-file anchor, because for a declaration
  # that file IS the record: its mtime is the moment the worker wrote the wait
  # down. So the recheck is governed by how old the declaration is, and the age
  # it publishes is that declaration's age, named as the declaration it is.
  dir=$(wedge_threshold_fixture declared-wait-aged \
    'paused: waiting on the upstream release cut' 2000)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a declaration older than the recheck cadence was never rechecked: $(cat "$out")"
  reported=$(wedge_reported_wait_secs "$out")
  [ -n "$reported" ] && [ "$reported" -ge 1900 ] \
    || fail "the declared-wait recheck reported '${reported}'s rather than the age of the declaration itself: $(cat "$out")"
  grep -F 'declared wait' "$out" >/dev/null \
    || fail "the declared-wait recheck did not name its evidence as declared: $(cat "$out")"
  # A `paused:` declaration names an external dependency the worker chose, so its
  # recheck asks the reader to confirm that dependency - never to answer or
  # release a hold, which is a different human and a different action.
  grep -F 'awaiting external' "$out" >/dev/null \
    || fail "the declared-wait recheck did not name the human the wait is on: $(cat "$out")"
  grep -F 'confirm the wait still holds' "$out" >/dev/null \
    || fail "the declared-wait recheck lost its external-wait action: $(cat "$out")"
  grep -F 'release the hold' "$out" >/dev/null \
    && fail "a declared external wait borrowed the captain-held release action: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the declared-wait recheck was worded as a possible wedge"
  ack_stopped_cycle "$state" || fail "could not acknowledge the declared-wait recheck"

  # A wait the worker said would already be over stops explaining the silence,
  # so the exemption ends exactly where the declaration does - as long as nothing
  # ELSE accounts for the quiet.
  past=$(iso_utc_at "$(( $(date +%s) - 7200 ))")
  dir=$(wedge_threshold_fixture declared-wait-elapsed "paused: waiting on the build queue until $past" 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a declared wait whose own clearing time had passed stayed silent"
  grep -F "possible wedge, escalation 1" "$out" >/dev/null \
    || fail "an elapsed declared wait did not keep the unchanged wedge wording: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the elapsed-declaration escalation"

  # The other direction: the same working verdict with no declaration at all
  # keeps the unchanged ladder.
  dir=$(wedge_threshold_fixture declared-wait-control 'working: validation under way' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an undeclared working lane stopped escalating at threshold $n"
    ack_stopped_cycle "$state" || fail "could not acknowledge undeclared escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "an undeclared working lane did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "an undeclared working lane lost the demand-deep-inspection wording: $(cat "$out")"
  pass "a declared wait is not wedge-escalated by a working verdict, while an elapsed declaration and an undeclared lane both keep the unchanged ladder"
}

# `fm-send --resolve-key default` answers a keyless decision by appending a
# stated default-key resolved line after whatever the worker wrote last. When
# that is a keyless pause the worker is still waiting, so the answer must not
# put the lane back on the wedge ladder. The worker's own keyless resolved line
# is the retraction that does.
test_wedge_threshold_keeps_a_wait_past_a_default_key_answer() {
  local dir state fakebin out capture window key n
  local working='state: working · source: run-step · ci running'

  dir=$(wedge_threshold_fixture default-answer-after-wait \
    "$(printf 'needs-decision: which color\npaused: waiting on the vendor release\nresolved [key=default]: answered: blue')" 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a default-key answer put a waiting lane on the wedge ladder at threshold $n: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a default-key answer let a waiting lane queue a wedge wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a default-key answer let a waiting lane count $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  dir=$(wedge_threshold_fixture keyless-retraction \
    "$(printf 'paused: waiting on the vendor release\nresolved: the vendor shipped')" 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a worker's own keyless resolved line did not retract its wait: $(cat "$out")"
  grep -F "possible wedge, escalation 1" "$out" >/dev/null \
    || fail "a retracted wait did not return to the wedge ladder: $(cat "$out")"
  pass "a default-key answer leaves a keyless wait standing, while the worker's own keyless resolved line retracts it"
}

# The other status-line record. A verified `captain-held:` transfer also reaches
# this deferral - the mate has an active run attributed to it, so pause_state_class
# reports working and the stable hash is handed to the wedge timer - but it blocks
# on a DIFFERENT human than a `paused:` declaration does. The captain reading the
# recheck is the one who can clear it, so wording it as an external dependency to
# confirm points them away from the only action that ends the wait. The sibling
# absorber makes exactly this distinction, and a lane routed here must not lose it.
test_wedge_threshold_recheck_names_the_captain_for_a_held_lane() {
  local dir state fakebin out capture window key n armed_timer
  local working='state: working · source: run-step · ci running'

  dir=$(wedge_threshold_fixture captain-held-wait \
    'captain-held: which retention window wins' 2000)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a captain-held lane older than the recheck cadence was never rechecked: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    || fail "the captain-held recheck did not name the captain as the human the wait is on: $(cat "$out")"
  grep -F 'answer the held decision or release the hold' "$out" >/dev/null \
    || fail "the captain-held recheck did not name the action that clears the hold: $(cat "$out")"
  grep -F 'awaiting external' "$out" >/dev/null \
    && fail "a captain-held transfer was published as a wait on an external dependency: $(cat "$out")"
  grep -F 'confirm the wait still holds' "$out" >/dev/null \
    && fail "a captain-held transfer borrowed the external-wait action: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a captain-held transfer was reported as a possible wedge: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the captain-held recheck"

  # The quiet direction is unchanged from a declared pause: inside the cadence the
  # hold is absorbed whole, with no escalation counted.
  dir=$(wedge_threshold_fixture captain-held-quiet \
    'captain-held: which retention window wins' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a captain-held lane wedge-escalated at threshold $n under a working verdict: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a captain-held lane queued a wedge wake inside its recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a captain-held lane counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # While the away-posture record exists there is nobody to answer the hold, so
  # this path absorbs it in silence like every other captain-held path in the
  # watcher. The recheck is not merely delayed but not owed at all: no wake, and
  # no throttle armed, so the moment the record is archived the hold is rechecked
  # at once rather than waiting out a cadence that started while the captain was
  # away. Same fixture and same age as the attended leg above, which is what makes
  # the difference attributable to the record alone.
  # The idle timer is pre-armed well past the threshold, so every round below
  # reaches the absorb with the same timer value and a restart would be visible.
  dir=$(wedge_threshold_fixture captain-held-away \
    'captain-held: which retention window wins' 2000 2000)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  armed_timer=$(cat "$state/.stale-since-$key")
  write_away_record "$state"
  n=1
  while [ "$n" -le 3 ]; do
    FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a captain-held lane was rechecked at threshold $n while the away-posture record existed: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a captain-held lane woke the away captain: $(cat "$state/.wake-queue")"
  [ ! -s "$out" ] \
    || fail "a captain-held lane printed a recheck while the away-posture record existed: $(cat "$out")"
  [ ! -e "$state/.waiting-resurfaced-$key" ] \
    || fail "an away-silenced hold armed the recheck throttle, so the recheck owed on return would be delayed a full cadence"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an away-silenced hold counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"
  grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null \
    || fail "the away-silenced hold was not recorded in the triage log: $(cat "$state/.watch-triage.log")"
  [ "$(cat "$state/.stale-since-$key")" = "$armed_timer" ] \
    || fail "an away-silenced hold restarted the idle timer, so part of the away window would be spent against the cadence the recheck owed on return uses"

  # And the recheck is owed in full the moment the captain is back: the absorb
  # above leaves the idle timer alone, so no part of the away window is spent
  # against the cadence the hold is rechecked on.
  archive_away_record "$state"
  : > "$out"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a captain-held lane was never rechecked after the away-posture record was archived: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    || fail "the recheck owed on return did not name the captain: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the on-return captain-held recheck"
  pass "a captain-held lane is rechecked as a hold on the captain, never as an external wait, and never at all while the captain is away"
}

# The backlog record of the same hold. Once firstmate hands a decision to the
# captain through bin/fm-captain-hold.sh, the worker's own line stays whatever it
# was, so a stuck worker on a stable pane reaches the wedge timer with nothing in
# its status log that reads as a wait. The open captain call must bound the wedge
# ladder exactly as a `captain-held:` line does.
backlog_hold_wedge_fixture() {  # <name> <status-age-secs> [<wedge-timer-age-secs>] [<status-log>]
  local dir
  dir=$(wedge_threshold_fixture "$1" "${4:-working: answering the dialog}" "$2" "${3-}") || return 1
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add wedge 'stuck at a captain-only dialog' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  run_hold "$dir" hold wedge --reason 'awaiting the captain on the dialog' || return 1
  printf '%s\n' "$dir"
}

test_wedge_threshold_defers_to_a_backlog_captain_hold() {
  local dir state fakebin out capture window key n queued armed_timer past
  local working='state: working · source: run-step · ci running'
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (backlog captain hold wedge bound)"; return 0; }
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  # A fresh status line is no record of when the hold began, so the first
  # threshold rechecks it once, as a wait on the captain with no wait age.
  dir=$(backlog_hold_wedge_fixture backlog-hold-quiet 0) \
    || fail "could not build a backlog captain-hold wedge fixture"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a backlog-held lane was never rechecked at the threshold: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    || fail "the backlog-hold recheck did not name the captain: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a backlog-held lane was reported as a possible wedge: $(cat "$out")"
  grep -E ', waiting [0-9]+s' "$out" >/dev/null \
    && fail "the backlog-hold recheck published the status line's age as the hold's: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the backlog-hold recheck"

  # Inside the recheck cadence the hold is absorbed whole, threshold after threshold.
  queued=$(wedge_stale_wakes "$state" "$window")
  n=1
  while [ "$n" -le 3 ]; do
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a backlog-held lane wedge-escalated at threshold $n: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq "$queued" ] \
    || fail "a backlog-held lane queued a further wake inside its recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a backlog-held lane counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # A paused line whose own clearing time has passed explains nothing, so the
  # hold the worker's line never shows still bounds the ladder.
  past=$(iso_utc_at "$(( $(date +%s) - 7200 ))")
  dir=$(backlog_hold_wedge_fixture backlog-hold-elapsed-pause 0 '' \
    "paused: waiting on the build queue until $past") \
    || fail "could not build a backlog captain-hold wedge fixture"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a backlog-held lane behind an elapsed pause was never rechecked: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    || fail "a backlog-held lane behind an elapsed pause was not rechecked as a wait on the captain: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a backlog-held lane behind an elapsed pause was reported as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a backlog-held lane behind an elapsed pause counted a wedge escalation"
  ack_stopped_cycle "$state" || fail "could not acknowledge the elapsed-pause backlog-hold recheck"

  # While the away-posture record exists it is never rechecked, and the backlog
  # read that proves the hold is paced by the idle timer rather than every poll.
  dir=$(backlog_hold_wedge_fixture backlog-hold-away 2000 2000) \
    || fail "could not build a backlog captain-hold wedge fixture"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  armed_timer=$(cat "$state/.stale-since-$key")
  write_away_record "$state"
  n=1
  while [ "$n" -le 3 ]; do
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_TEST_PAUSE_RESURFACE=240 \
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a backlog-held lane was rechecked at threshold $n while the away-posture record existed: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a backlog-held lane woke the away captain: $(cat "$state/.wake-queue")"
  [ ! -s "$out" ] \
    || fail "a backlog-held lane printed a recheck while the away-posture record existed: $(cat "$out")"
  [ "$(cat "$state/.stale-since-$key")" != "$armed_timer" ] \
    || fail "an away-silenced backlog hold left the idle timer expired, so its backlog read repeats on every poll"
  pass "a backlog captain hold bounds the wedge ladder like a captain-held line, and stays silent while the captain is away"
}

# --- the wedge threshold reads the crew's own parked-gate state --------------
# Upstream kunchenguid/firstmate#3055: a lane parked at a validation gate that is
# waiting on a HUMAN is correctly quiet, but nothing in the status LINE says so -
# the evidence is the pipeline's gate state, not anything the worker wrote. One
# such lane reached 671 consecutive escalations on a single home. Neither landed
# mitigation covers it: a declared `paused:` does nothing because a live ordinary
# crewmate's absorb class never reads paused, and raising the threshold delays
# genuine wedge detection for every lane equally.
#
# The distinction that makes this safe is between the two gates the crew state
# both reports as `parked`: one owed a HUMAN, and one owed the CREWMATE's own
# answer. Only the first may go quiet - a crewmate that wedges before answering
# its own gate is exactly the failure this ladder exists to catch - so both
# directions are pinned here, and the crewmate direction is written so that a
# consumer which merely searched the verdict for the token would fail it.
# The second half of that evidence - that the human was actually asked and has
# not answered - is pinned in the test below this one.
test_wedge_threshold_defers_to_a_parked_gate_awaiting_a_human() {
  local dir state fakebin out capture window key n queued
  # The gate's own findings table said a human owes this answer, so
  # bin/fm-crew-state.sh minted the human-decision component (its derivation from
  # the `action` column by position is pinned in tests/fm-crew-state.test.sh).
  local human='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision · run: 01RUNGATE'
  # The same gate with no run component: nothing can tie a decision to it.
  local runless='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision'
  # The same shape owed the crewmate itself. The gate name is free text carried
  # out of the run payload, so this one spells the whole marker inside it: a
  # consumer that searched the verdict for those words instead of comparing a
  # whole component for equality would read this lane as human-owed and take its
  # ladder away.
  local crewmate='state: parked · source: run-step · parked at fix_review (ask-user: authority decision follow-up): 2 finding(s) · run: 01RUNGATE'

  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  # The log every case here shares: the crew escalated the gate's question and
  # nobody has answered it yet, so its decision fold still holds one open
  # `needs-decision`. That is the record of who was TOLD; the crew-state verdict
  # above is the record of who OWES the answer, and the deferral needs both.
  # The trailing `working:` note is what a crew appends next and does not close a
  # decision, so it leaves the fold open while keeping the LAST line
  # non-captain-relevant - the plain route into the wedge timer these cases want.
  # The file is backdated well past the recheck cadence, and it is still not the
  # record of when this wait began, so nothing about the recheck may be computed
  # from its mtime.
  local escalated='needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
working: still parked at that gate'
  # An open decision too, but under a key that names no run: an unrelated
  # question raised earlier in the same task and never closed. It says nothing
  # about whether anyone was told about THIS gate.
  local unrelated='needs-decision [key=earlier-question]: which changelog section fits
working: still parked at that gate'

  dir=$(wedge_threshold_fixture parked-gate-human "$escalated" 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "a gate awaiting a human was never rechecked at the threshold: $(cat "$out")"
  grep -F 'verified wait at a parked gate' "$out" >/dev/null \
    || fail "the parked-gate recheck did not name its evidence: $(cat "$out")"
  grep -F "awaiting firstmate's ask-user decision" "$out" >/dev/null \
    || fail "the parked-gate recheck did not name firstmate as the one the wait is on: $(cat "$out")"
  grep -F "decide the gate's ask-user finding and relay the decision to the crewmate" "$out" >/dev/null \
    || fail "the parked-gate recheck did not name the action that clears the lane: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    && fail "the parked-gate recheck named the captain for a decision firstmate owns: $(cat "$out")"
  grep -F 'confirm the wait still holds' "$out" >/dev/null \
    && fail "a parked gate borrowed the external-wait action, which does not clear it: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a gate awaiting a human was reported as a possible wedge: $(cat "$out")"
  # No wait age is published, because no record of when this wait began exists:
  # the status file is an unrelated line, and the idle window this deferral
  # resets every pass would report the same small number forever.
  grep -E ', waiting [0-9]+s' "$out" >/dev/null \
    && fail "the parked-gate recheck published a wait age it has no record for: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the parked-gate recheck"

  # Long cadence, not a ladder: every further threshold inside the cadence is
  # absorbed whole, with no escalation counted and nothing queued.
  queued=$(wedge_stale_wakes "$state" "$window")
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" absorb \
      || fail "a gate awaiting a human wedge-escalated at threshold $n: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq "$queued" ] \
    || fail "a gate awaiting a human queued a further wake inside its recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a gate awaiting a human counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # The other direction, and the whole reason the distinction is drawn: a gate
  # the crewmate itself must answer keeps the unchanged schedule, reason and
  # demand-deep-inspection wording.
  dir=$(wedge_threshold_fixture parked-gate-crewmate "$escalated" 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$crewmate" exit \
      || fail "a gate awaiting the crewmate stopped escalating at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge crewmate-gate escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "a gate awaiting the crewmate did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "a gate awaiting the crewmate lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'verified wait at a parked gate' "$out" >/dev/null \
    && fail "a gate awaiting the crewmate was deferred as a wait on a human: $(cat "$out")"

  # The wait is owed by firstmate, not the captain, so the captain-away silence
  # does not apply: under away posture the supervision branch is the actor
  # allowed to answer it, and it keeps the long recheck cadence throughout.
  dir=$(wedge_threshold_fixture parked-gate-away "$escalated" 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  write_away_record "$state"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "a parked gate owed firstmate's decision was silenced while the away-posture record existed: $(cat "$out")"
  grep -F "awaiting firstmate's ask-user decision" "$out" >/dev/null \
    || fail "the away-posture parked-gate recheck did not name firstmate: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "an away-posture parked gate was reported as a possible wedge: $(cat "$out")"
  grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null \
    && fail "a parked gate owed firstmate took the captain-away silence: $(cat "$state/.watch-triage.log")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the away-posture parked-gate recheck"
  queued=$(wedge_stale_wakes "$state" "$window")
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" absorb \
      || fail "an away-posture parked gate wedge-escalated at threshold $n: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq "$queued" ] \
    || fail "an away-posture parked gate queued a further wake inside its recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an away-posture parked gate counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # An open decision under an unrelated key does not bind to this gate, so the
  # lane keeps the unchanged ladder: nothing says anyone was told about it.
  dir=$(wedge_threshold_fixture parked-gate-unrelated-key "$unrelated" 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
      || fail "a gate with only an unrelated open decision stopped escalating at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unrelated-key escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "a gate with only an unrelated open decision did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "a gate with only an unrelated open decision lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'verified wait at a parked gate' "$out" >/dev/null \
    && fail "an unrelated open decision was read as this gate's wait: $(cat "$out")"

  # A verdict naming no run cannot be bound to any decision, so it keeps the
  # ladder even with the run-shaped key open.
  dir=$(wedge_threshold_fixture parked-gate-runless "$escalated" 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$runless" exit \
    || fail "a runless human-owed gate never escalated: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the runless-gate escalation"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
    || fail "a runless human-owed gate did not take the unchanged ladder: $(cat "$out")"
  pass "a gate awaiting firstmate's decision for its own run is rechecked on the long cadence in either posture, while a crewmate-owed gate, an unrelated open decision and a runless verdict keep the unchanged ladder"
}

# --- an unconfigured home behaves exactly as it did before this evidence -----
# The parked-gate record is the one wait here that is not the worker's own
# declaration about its own silence: it is derived from a pipeline's gate state,
# so a home decides for itself whether a lane may give up the escalation ladder
# for it. Absent `config/wedge-defer-parked-gate` the lane this whole file
# otherwise defers - human-owed gate, open decision keyed to that run, every
# signal the armed cases assert on - must escalate on the unchanged schedule
# with the unchanged reason and demand-deep-inspection wording, and the evidence
# arm must not even be reached: no current-state read is spent and no recheck
# throttle is written. The fixture is byte-identical to the armed case above
# except for the flag, so the difference is attributable to the flag alone.
test_wedge_threshold_parked_gate_is_off_until_armed() {
  local dir state fakebin out capture window key n unarmed_probes armed_probes
  local human='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision · run: 01RUNGATE'
  local escalated='needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
working: still parked at that gate'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  dir=$(wedge_threshold_fixture parked-gate-unarmed "$escalated" 2000)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-parked-gate" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  export FM_FAKE_CREW_STATE_LOG="$dir/crew-state.calls"
  : > "$FM_FAKE_CREW_STATE_LOG"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
      || fail "an unarmed home stopped escalating a parked gate at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unarmed-gate escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "an unarmed home did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "an unarmed home lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'verified wait at a parked gate' "$out" >/dev/null \
    && fail "an unarmed home deferred a parked gate: $(cat "$out")"
  [ ! -e "$state/.waiting-resurfaced-$key" ] \
    || fail "an unarmed home wrote the parked-gate recheck throttle"
  unarmed_probes=$(wc -l < "$FM_FAKE_CREW_STATE_LOG" | tr -d ' ')
  unset FM_FAKE_CREW_STATE_LOG

  [ "$unarmed_probes" -eq 0 ] \
    || fail "an unarmed home spent $unarmed_probes current-state read(s) on a parked gate over three thresholds"

  # The same fixture with only the flag added, counted the same way, so the
  # zero above is the flag's doing rather than a fixture that could never have
  # reached the reader: one armed threshold must spend a read. A guard placed
  # after the consult instead of before it would make both counts nonzero.
  dir=$(wedge_threshold_fixture parked-gate-armed-probe-count "$escalated" 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  export FM_FAKE_CREW_STATE_LOG="$dir/crew-state.calls"
  : > "$FM_FAKE_CREW_STATE_LOG"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "the armed control was never rechecked: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the armed control recheck"
  armed_probes=$(wc -l < "$FM_FAKE_CREW_STATE_LOG" | tr -d ' ')
  unset FM_FAKE_CREW_STATE_LOG
  [ "$armed_probes" -gt 0 ] \
    || fail "the armed control spent no current-state read, so the probe count proves nothing"
  pass "with config/wedge-defer-parked-gate absent a parked gate keeps the unchanged ladder, wording and reads"
}

# --- a parked human-owed gate also needs the human to still owe an answer ----
# The gate's findings table says who the answer is owed BY. It does not say the
# human was ever asked, and it does not stop saying `ask-user` once they answer:
# the run stays parked, and the row stays in the table, until the CREWMATE relays
# the decision with `axi respond`. So a lane that is quiet because the crewmate
# wedged before relaying an answer it already has would read exactly like a lane
# waiting on firstmate - and would lose the ladder for the one failure the
# ladder exists to catch.
# The task's own decision fold is the record that closes that hole, because it is
# written at ANSWER time rather than at relay time: `fm-send --resolve-key`
# appends the closing `resolved` line the moment the decision is answered. An open
# `needs-decision` therefore means the human was told and has not answered; its
# absence means the outstanding move belongs to the crewmate, or that nobody was
# ever told at all. Each of those keeps the unchanged schedule below.
test_wedge_threshold_parked_gate_needs_an_unanswered_decision() {
  local dir state fakebin out capture window key n
  local human='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision · run: 01RUNGATE'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  # Answered, not yet relayed. The gate verdict is byte-identical to the one the
  # test above defers on; only the closing `resolved` line differs, and the
  # `resolved:` verb is not captain-relevant, so this lane takes the same plain
  # non-terminal route into the wedge timer as that one.
  dir=$(wedge_threshold_fixture parked-gate-decided \
    'needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
resolved [key=nm-01RUNGATE-review]: firstmate chose the second fix' 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
      || fail "a decided-but-unrelayed gate stopped escalating at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge decided-gate escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "a decided-but-unrelayed gate did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "a decided-but-unrelayed gate lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'verified wait at a parked gate' "$out" >/dev/null \
    && fail "a gate whose decision was already answered was deferred as a wait on the captain: $(cat "$out")"

  # Parked at a human-owed gate, quiet, and the crewmate never escalated it: no
  # human has been told, so there is no wait to defer to.
  dir=$(wedge_threshold_fixture parked-gate-unescalated 'working: validation under way' 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "a human-owed gate nobody was told about never escalated: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unescalated-gate escalation"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
    || fail "a human-owed gate nobody was told about did not take the unchanged ladder: $(cat "$out")"

  # An open `blocked` record is not an unanswered question: it is an obstacle the
  # crew reported, and a different action clears it. A `blocked:` last line is
  # captain-relevant, so this lane reaches the wedge timer through the
  # overridden-terminal-status branch instead, which only ever sees a hash whose
  # timer is already running - hence the fixture's fourth argument.
  dir=$(wedge_threshold_fixture parked-gate-blocked \
    'blocked [key=nm-01RUNGATE-review]: the fixture cannot reach its dependency' 2000 600)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "a human-owed gate with only a blocker open never escalated: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the blocked-gate escalation"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
    || fail "an open blocker was accepted as an unanswered gate decision: $(cat "$out")"
  pass "a parked human-owed gate is deferred only while its decision is still open, so an answered-but-unrelayed gate, an unescalated one, and one holding only a blocker all keep the unchanged ladder"
}

# --- a worker's own newest blocker or decision, behind its opt-in flag -------
# Upstream kunchenguid/firstmate#6899: a lane whose newest line is the worker's
# own `blocked:` or `needs-decision:` already woke firstmate, so in a home that
# armed config/wedge-defer-worker-wait the wedge timer defers it to the bounded
# recheck instead of climbing the ladder. `blocked:` is the verb pinned here
# because the parked-gate evidence above deliberately refuses it. A `blocked:`
# last line is captain-relevant, so every fixture arms the wedge timer (the
# fourth argument) to reach it through the overridden-terminal-status branch.
arm_worker_wait() {  # <case-dir>
  : > "$1/config/wedge-defer-worker-wait"
}

test_wedge_threshold_defers_to_a_worker_blocker() {
  local dir state fakebin out capture window key n reported case_log
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  dir=$(wedge_threshold_fixture worker-blocker-fresh \
    'working: wiring the client
blocked: need the API key for the staging account' 0 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a worker blocker wedge-escalated at threshold $n in an armed home: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a worker blocker queued a wake inside the recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a worker blocker counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # The deferral is bounded: once the blocker is older than the cadence it
  # re-surfaces once, aged from the line, naming firstmate and the clearing action.
  dir=$(wedge_threshold_fixture worker-blocker-aged 'blocked: need the API key for the staging account' 2000 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a worker blocker older than the recheck cadence was never rechecked: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the worker-blocker recheck"
  reported=$(wedge_reported_wait_secs "$out")
  [ -n "$reported" ] && [ "$reported" -ge 1900 ] \
    || fail "the worker-blocker recheck reported '${reported}'s rather than the blocker's age: $(cat "$out")"
  grep -F 'declared blocker, awaiting firstmate' "$out" >/dev/null \
    || fail "the worker-blocker recheck did not name its evidence and firstmate: $(cat "$out")"
  grep -F 'clear the reported blocker' "$out" >/dev/null \
    || fail "the worker-blocker recheck lost its blocker-specific action: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the worker-blocker recheck was worded as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the worker-blocker recheck raised the escalation count"

  dir=$(wedge_threshold_fixture worker-decision-aged 'needs-decision [key=scope]: ship the narrow fix or the broad one' 2000 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a worker decision older than the recheck cadence was never rechecked: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the worker-decision recheck"
  grep -F 'declared decision, awaiting firstmate' "$out" >/dev/null \
    || fail "the worker-decision recheck did not name its evidence and firstmate: $(cat "$out")"
  grep -F 'answer the reported decision' "$out" >/dev/null \
    || fail "the worker-decision recheck lost its decision-specific action: $(cat "$out")"

  # Each of these ends or never starts the deferral, so the lane keeps the ladder:
  # a newer worker line, a resolved line, a supervisor-reserved key, and an inbox
  # record the worker acknowledged after writing the blocker.
  for case_log in \
    'blocked: need the API key for the staging account
working: resumed without it' \
    'blocked: need the API key for the staging account
resolved: firstmate supplied the key' \
    'blocked [key=remote-reply-continuity-mate1]: the remote reply mirror stopped' \
    'blocked: need the API key for the staging account|handled'; do
    dir=$(wedge_threshold_fixture worker-blocker-ended "${case_log%|handled}" 2000 600)
    arm_worker_wait "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    case "$case_log" in
      *'|handled')
        mkdir -p "$state/wedge.inbox/handled"
        printf 'schema=fm-task-inbox.v1\n--\nthe key is in the vault\n' > "$state/wedge.inbox/handled/001.msg"
        ;;
    esac
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an ended or supervisor-owned blocker never escalated: ${case_log}: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the ended-blocker escalation"
    grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
      || fail "an ended or supervisor-owned blocker did not keep the ladder: ${case_log}: $(cat "$out")"
  done
  pass "in an armed home a worker's own open newest blocker or decision is deferred to the bounded recheck, and a newer line, a resolved line, a reserved key, or a newer acknowledged inbox record keeps the ladder"
}

# Absent config/wedge-defer-worker-wait the same aged blocker escalates with the
# byte-identical reason it had before this evidence existed, and writes no
# recheck throttle.
test_wedge_threshold_worker_wait_is_off_until_armed() {
  local dir state fakebin out capture window key
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture worker-blocker-unarmed 'blocked: need the API key for the staging account' 2000 600)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-worker-wait" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "an unarmed home stopped escalating a worker blocker: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unarmed worker-blocker escalation"
  grep -Ex 'stale: test:fm-wedge \(idle [0-9]+s, possible wedge, escalation 1\)' "$out" >/dev/null \
    || fail "an unarmed home changed the wedge reason for a worker blocker: $(cat "$out")"
  grep -F 'declared blocker' "$out" >/dev/null \
    && fail "an unarmed home deferred a worker blocker: $(cat "$out")"
  [ ! -e "$state/.waiting-resurfaced-$key" ] \
    || fail "an unarmed home wrote the worker-wait recheck throttle"
  pass "with config/wedge-defer-worker-wait absent a worker blocker keeps the byte-identical wedge reason"
}

# --- a wait record that does not carry every field is refused ----------------
# wait_record joins its five fields with US and wedge_defer_wait parses them with
# `IFS=<us> read`, so consecutive delimiters yield genuinely EMPTY fields and no
# field can shift left into another's position. That is what makes the deferral's
# guard able to enforce the whole contract rather than a position-specific slice
# of it: each field the recheck prints must be present, and a record carrying
# more than its four delimiters is refused too, since `read` puts any surplus
# into the final variable. Deferring on a record that is not what it claims is
# what takes the ladder away, so every one of these must fall back to the
# escalation the caller was about to make instead.
# No shipped evidence producer can emit a malformed record, which is precisely
# the invariant under test, so this loads the real bin/fm-watch.sh through its
# own source guard in a child shell (the entry tests/fm-supervision-events.test.sh
# uses) and drives the real wedge_timer_check. The assertion is on the durable
# wake queue the watcher actually wrote.

# One wedge_timer_check round against a malformed record. <evidence-body> is the
# body of a wedge_wait_evidence override, so a case supplies exactly the record
# under test. Publishes the state directory it ran in as MALFORMED_STATE rather
# than on stdout, because fail() exits the shell it runs in and a command
# substitution would swallow a setup failure here.
run_malformed_wait_record_round() {  # <name> <evidence-body>
  local name=$1 body=$2 dir state out
  dir=$(make_case "$name"); state="$dir/state"
  printf 'working: validation under way\n' > "$state/wedge.status"
  printf '%s\n' "$(( $(date +%s) - 600 ))" > "$state/.stale-since-test_fm-wedge"

  out="$dir/defer.out"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 \
    bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      wake() { :; }
      # A live agent, so the dead-record probe that runs after a refused
      # deferral keeps the unchanged ladder rather than reading a backend this
      # child shell has none of.
      fm_backend_agent_state() { printf alive; }
      eval "wedge_wait_evidence() { $2 ; }"
      wedge_timer_check "test:fm-wedge" "$FM_STATE_OVERRIDE/.stale-since-test_fm-wedge" \
        "non-terminal stale" "$FM_STATE_OVERRIDE/.wedge-escalations-test_fm-wedge" wedge \
        malformed-record-pane
    ' _ "$WATCH" "$body" > "$out" 2>&1 \
    || fail "the wedge timer failed on a malformed wait record ($name): $(cat "$out")"
  MALFORMED_STATE=$state
}

assert_malformed_record_kept_the_ladder() {  # <state> <what>
  local state=$1 what=$2
  grep -F 'possible wedge, escalation 1' "$state/.wake-queue" >/dev/null \
    || fail "$what did not keep the unchanged ladder: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F 'rechecked on a long cadence not a wedge' "$state/.wake-queue" >/dev/null \
    && fail "$what was deferred on a record that is not what it claims: $(cat "$state/.wake-queue")"
  [ "$(cat "$state/.wedge-escalations-test_fm-wedge" 2>/dev/null || echo 0)" -eq 1 ] \
    || fail "$what did not count its escalation"
}

test_wedge_defer_refuses_a_half_filled_wait_record() {
  # An empty subject - the field whose loss used to shift the prose action into
  # `whom` and print an action that clears nothing.
  run_malformed_wait_record_round malformed-wait-record \
    'wait_record "declared wait" "" external "confirm the wait still holds" ""'
  assert_malformed_record_kept_the_ladder "$MALFORMED_STATE" "a wait record with no subject"

  # An empty ACTION with a non-empty anchor. Under the old TAB join this parsed
  # as a valid record: the doubled tab collapsed, the anchor path slid into
  # `action`, and the recheck published a status-file path as the one thing that
  # clears the lane while silently losing the wait-age anchor.
  run_malformed_wait_record_round malformed-wait-record-no-action \
    "wait_record 'declared wait' 'awaiting external' external '' '$TMP_ROOT/anchor.status'"
  assert_malformed_record_kept_the_ladder "$MALFORMED_STATE" "a wait record with no action"

  # A record carrying a surplus delimiter: `read` puts everything past the last
  # field into `anchor`, so the fields after the extra one are not the fields
  # they are read as.
  run_malformed_wait_record_round malformed-wait-record-surplus \
    'printf "%s\\037%s\\037%s\\037%s\\037%s\\037%s" "declared wait" "awaiting external" external "confirm the wait still holds" "" extra'
  assert_malformed_record_kept_the_ladder "$MALFORMED_STATE" "a wait record with a surplus field"

  pass "a wait record missing a field the recheck must print, or carrying one it must not, is refused and the lane escalates exactly as it would have"
}

# --- an executing no-mistakes run is liveness, not a wedge candidate ---------
# While the pipeline runs or fixes a round the worker is idle behind its own
# blocking drive call, so a static pane is exactly what a healthy lane looks
# like. The attributed run step says so, and in a home that armed
# config/wedge-defer-validating the wedge timer defers to it on the same long
# recheck cadence as every other deferral instead of re-escalating a possible
# wedge each FM_STALE_ESCALATE_SECS.
arm_validating() {  # <case-dir>
  : > "$1/config/wedge-defer-validating"
}

test_wedge_threshold_defers_to_an_executing_validation_run() {
  local dir state fakebin out capture window key n verdict step queued
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  for step in running fixing; do
    verdict="state: working · source: run-step · validating ($step) · run: 01RUNLIVE"
    dir=$(wedge_threshold_fixture "validating-$step" 'working: handed to validation' 0)
    arm_validating "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    n=1
    while [ "$n" -le 3 ]; do
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
        || fail "a $step validation run wedge-escalated at threshold $n: $(cat "$out")"
      n=$((n + 1))
    done
    [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
      || fail "a $step validation run queued a stale wake: $(cat "$state/.wake-queue")"
    grep -F 'possible wedge' "$out" >/dev/null \
      && fail "a $step validation run was reported as a possible wedge: $(cat "$out")"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "a $step validation run counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"
    [ "$(cat "$state/.validating-since-$key" 2>/dev/null || true)" = 01RUNLIVE ] \
      || fail "the $step deferral chain was not bound to its run"
  done

  # The deferral is bounded, not a cancellation: a run record that keeps saying
  # running for longer than the recheck cadence is rechecked once, worded as the
  # validating run it is rather than as a wedge, and then quiet again.
  # The wedge timer is pre-armed so the first poll is already at the threshold
  # rather than a timer repair, which would restart the chain under test.
  verdict='state: working · source: run-step · validating (running) · run: 01RUNLIVE'
  dir=$(wedge_threshold_fixture validating-aged 'working: handed to validation' 0 5)
  arm_validating "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf '01RUNLIVE' > "$state/.validating-since-$key"
  set_mtime "$(( $(date +%s) - 2000 ))" "$state/.validating-since-$key"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
    || fail "a validation run older than the recheck cadence was never rechecked: $(cat "$out")"
  grep -F 'no-mistakes run 01RUNLIVE validating (running)' "$out" >/dev/null \
    || fail "the validating recheck did not name its run: $(cat "$out")"
  grep -F 'rechecked on a long cadence not a wedge; confirm the run is still progressing' "$out" >/dev/null \
    || fail "the validating recheck lost its action: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the validating recheck was worded as a possible wedge: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the validating recheck"
  queued=$(wedge_stale_wakes "$state" "$window")
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
    || fail "the validating recheck repeated inside its cadence: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq "$queued" ] \
    || fail "the validating recheck queued a further wake inside its cadence"

  # A replacement run starts its own chain, so an old run's age cannot make the
  # new one re-surface at once.
  dir=$(wedge_threshold_fixture validating-new-run 'working: handed to validation' 0 5)
  arm_validating "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf '01RUNOLD' > "$state/.validating-since-$key"
  set_mtime "$(( $(date +%s) - 2000 ))" "$state/.validating-since-$key"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
    || fail "a replacement run inherited the previous run's recheck age: $(cat "$out")"
  [ "$(cat "$state/.validating-since-$key")" = 01RUNLIVE ] \
    || fail "a replacement run did not rebind the deferral chain"
  pass "a running or fixing validation run is deferred on the long recheck cadence rather than wedge-escalated"
}

# Every run state that does not prove a round is executing keeps the unchanged
# ladder even where the flag is armed: a parked gate, a terminal run, a ci
# monitor, a coarse ledger row, a verdict naming no run, no run at all, and an
# unreadable verdict.
test_wedge_threshold_escalates_when_no_run_is_executing() {
  local dir state fakebin out capture window key n spec name verdict
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in \
    'parked|state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · run: 01RUNLIVE' \
    'failed|state: failed · source: run-step · run failed · run: 01RUNLIVE' \
    'done|state: done · source: run-step · checks green: PR ready for review · run: 01RUNLIVE' \
    'ci|state: working · source: run-step · ci running · run: 01RUNLIVE' \
    'coarse|state: working · source: run-step · validating (background run)' \
    'runless|state: working · source: run-step · validating (running)' \
    'absent|state: working · source: pane · busy' \
    'unreadable|error: no-mistakes status timed out'; do
    name=${spec%%|*}; verdict=${spec#*|}
    dir=$(wedge_threshold_fixture "not-executing-$name" 'working: handed to validation' 0)
    arm_validating "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    n=1
    while [ "$n" -le 3 ]; do
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
        || fail "a $name run stopped escalating at threshold $n: $(cat "$out")"
      ack_stopped_cycle "$state" || fail "could not acknowledge $name escalation $n"
      grep -F "possible wedge, escalation $n" "$out" >/dev/null \
        || fail "a $name run did not reach escalation $n: $(cat "$out")"
      n=$((n + 1))
    done
    grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
      || fail "a $name run lost the demand-deep-inspection wording: $(cat "$out")"
    [ ! -e "$state/.validating-since-$key" ] \
      || fail "a $name run started a validating deferral chain"
  done
  pass "parked, terminal, ci-monitoring, coarse, runless, absent and unreadable runs keep the unchanged wedge ladder"
}

# Absent config/wedge-defer-validating an executing run is no deferral at all:
# the lane escalates on the unchanged schedule and wording, and the consult is
# never reached, so no current-state read is spent and no chain is started.
test_wedge_threshold_validating_run_is_off_until_armed() {
  local dir state fakebin out capture window key n probes
  local verdict='state: working · source: run-step · validating (running) · run: 01RUNLIVE'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture validating-unarmed 'working: handed to validation' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-validating" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  export FM_FAKE_CREW_STATE_LOG="$dir/crew-state.calls"
  : > "$FM_FAKE_CREW_STATE_LOG"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
      || fail "an unarmed home stopped escalating a running validation at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unarmed validating escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "an unarmed home did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  probes=$(wc -l < "$FM_FAKE_CREW_STATE_LOG" | tr -d ' ')
  unset FM_FAKE_CREW_STATE_LOG
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "an unarmed home lost the demand-deep-inspection wording: $(cat "$out")"
  [ "$probes" -eq 0 ] \
    || fail "an unarmed home spent $probes current-state read(s) on a running validation over three thresholds"
  [ ! -e "$state/.validating-since-$key" ] \
    || fail "an unarmed home started a validating deferral chain"
  pass "with config/wedge-defer-validating absent a running validation keeps the unchanged ladder, wording and reads"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_wedge_threshold_defers_to_a_declared_wait_under_a_working_verdict \
  test_wedge_threshold_keeps_a_wait_past_a_default_key_answer \
  test_wedge_threshold_recheck_names_the_captain_for_a_held_lane \
  test_wedge_threshold_defers_to_a_backlog_captain_hold \
  test_wedge_threshold_defers_to_a_parked_gate_awaiting_a_human \
  test_wedge_threshold_parked_gate_needs_an_unanswered_decision \
  test_wedge_threshold_parked_gate_is_off_until_armed \
  test_wedge_threshold_defers_to_a_worker_blocker \
  test_wedge_threshold_worker_wait_is_off_until_armed \
  test_wedge_defer_refuses_a_half_filled_wait_record \
  test_wedge_threshold_defers_to_an_executing_validation_run \
  test_wedge_threshold_escalates_when_no_run_is_executing \
  test_wedge_threshold_validating_run_is_off_until_armed
