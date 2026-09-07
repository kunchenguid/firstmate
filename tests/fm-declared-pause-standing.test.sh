#!/usr/bin/env bash
# tests/fm-declared-pause-standing.test.sh - a declared external wait is a
# STANDING intent, not the status log's newest event.
#
# THE DEFECT THIS PINS. state/<id>.status is an append-only event log, and every
# pause gate used to read it last-event-wins. So a crew that appended
#   paused: waiting on the upstream maintainer
# kept its wedge-alarm suppression only until the NEXT line landed - from anyone.
# The crew's own armed background reporter, a pipeline step notice, a firstmate
# note: any of them became the newest event, current state flipped away from the
# declaration, the possible-wedge ladder restarted from zero, and nothing reported
# that the suppression had been voided. Measured independently twice in the live
# fleet: 73% of possible-wedge wakes named a crew that had ALREADY declared a
# wait, and one crew was escalated thirty times over four days while declaring,
# each time, that it was waiting on something external.
#
# bin/fm-classify-lib.sh's status_standing_wait_line is the fix, and its header
# owns the retraction rule and the reasoning behind it. This suite is that
# function's own contract, driven through the real library.
#
# THE RISK HERE RUNS THE WRONG WAY, so these cases defend both directions with
# equal weight. Erring noisy costs model requests; erring quiet means a genuinely
# wedged crew sits unnoticed, which is the exact failure the alarm exists to
# prevent. Every case that widens suppression is therefore paired with one that
# proves suppression did not widen further than intended.
#
# The rest of the contract lives with the surfaces that own it:
#   - tests/fm-crew-state.test.sh: what bin/fm-crew-state.sh reports under a
#     masked declaration, and that crew_absorb_class still reads `paused`.
#   - tests/fm-watch-triage.test.sh: the watcher end to end - a masked pause
#     absorbed instead of wedge-escalated, still re-surfaced on its bounded
#     cadence, and an undeclared idle pane escalating exactly as before.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-declared-pause-standing)

# Write <lines...> as a status log and echo its path.
status_log() {  # <name> <line>...
  local name=$1 dir f
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  f="$dir/task.status"
  : > "$f"
  printf '%s\n' "$@" >> "$f"
  printf '%s\n' "$f"
}

# Assert the fold's verdict over one log.
assert_standing() {  # <file> <expected-line> <why>
  local got; got=$(status_standing_wait_line "$1")
  [ "$got" = "$2" ] || fail "$3 (standing=[$got], expected=[$2])"
}
assert_no_standing() {  # <file> <why>
  local got; got=$(status_standing_wait_line "$1")
  [ -z "$got" ] || fail "$2 (standing=[$got], expected none)"
}

PAUSE='paused: waiting on the upstream maintainer'
HELD='captain-held [key=route]: tracked by task-decision-route'

# --- the defect itself -------------------------------------------------------

# The exact live sequence from state/firstmate-attest-upstream-pr3753.status: a
# declared wait, then an automatic append from a step reporter the crew had armed
# itself, which had been running nearly eighteen hours and appended on any step
# change. There is no producer attribution in a status log, so the fold cannot ask
# WHO wrote a line - it asks whether the line SAYS the wait ended. A `working:`
# line does not; it is this repo's nonterminal progress verb, excluded from
# captain relevance for the same reason.
test_the_reported_masking_sequence_keeps_the_declaration() {
  local f
  f=$(status_log reported-sequence \
    "$PAUSE" \
    'working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,failed')
  assert_standing "$f" "$PAUSE" "the reporter's automatic append cancelled the declared wait"

  # And it keeps standing however many more of them land: the reporter kept
  # appending for as long as it ran, so a fold that survived only one append
  # would still have restarted the ladder on the second.
  f=$(status_log reported-sequence-repeated \
    "$PAUSE" \
    'working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step review,running' \
    'working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,running' \
    'working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,failed')
  assert_standing "$f" "$PAUSE" "a run of automatic appends cancelled the declared wait"
  pass "the live masking sequence leaves the declaration standing, however many appends follow"
}

# The other producers that reach a status log. None of them states that an
# external wait ended, so none of them may retract one.
test_non_declaring_producers_never_retract() {
  local f
  f=$(status_log producer-note "$PAUSE" 'note: firstmate confirmed the upstream ticket')
  assert_standing "$f" "$PAUSE" "a firstmate note cancelled the declared wait"

  # A worker's own progress line. This is THE masking line, and the one case where
  # the ambiguity is real: a status log carries no producer attribution, so this is
  # byte-identical whether the worker wrote it or a reporter it armed did.
  # test_the_resolution_verb_retracts_without_ending_the_task owns the other half -
  # the explicit verb a worker uses to say the wait is over.
  f=$(status_log producer-working "$PAUSE" 'working: still churning through the audit')
  assert_standing "$f" "$PAUSE" "a progress line cancelled the declared wait"

  # Legacy bare prose with no leading verb. It matches no verb at all, so it can
  # neither declare nor retract.
  f=$(status_log producer-prose "$PAUSE" 'still nothing from upstream')
  assert_standing "$f" "$PAUSE" "free-text prose cancelled the declared wait"

  # A line whose PROSE mentions a terminal word but whose verb is not terminal.
  # The fold reads the verb, exactly as status_is_terminal_verb does.
  f=$(status_log producer-prose-terminal "$PAUSE" 'working: the upstream build is blocked')
  assert_standing "$f" "$PAUSE" "prose mentioning a terminal word cancelled the declared wait"
  pass "notes, progress lines, and free-text prose leave a declaration standing"
}

# --- retraction, the direction that must not get quieter ---------------------

# The retraction set is the terminal captain verbs plus `resolved:`. The terminal
# ones cost no wedge coverage because each is captain-relevant on its own, so the
# event surfaces whether or not it also retracts.
test_every_terminal_verb_retracts() {
  local verb f
  for verb in 'done' failed blocked needs-decision; do
    f=$(status_log "retract-$verb" "$PAUSE" "$verb: the wait is over")
    assert_no_standing "$f" "a '$verb:' line did not retract the declared wait"
    status_is_terminal_verb "$verb: the wait is over" \
      || fail "'$verb:' is not in status_is_terminal_verb, so the two verb sets have drifted"

    # UNCONDITIONALLY, whatever key the terminal line carries. Each of these verbs
    # says the crew is no longer in an external wait at all, so retraction here
    # must not depend on a busy worker keying its terminal line to match the pause
    # it wrote hours earlier. If it did, a crew that declared itself BLOCKED would
    # keep reading back as `paused` to bin/fm-crew-state.sh and the daemon's stale
    # classifier would self-handle it on the hour cadence.
    f=$(status_log "retract-$verb-keyed-over-unkeyed" "$PAUSE" "$verb [key=route]: the wait is over")
    assert_no_standing "$f" "a keyed '$verb:' line did not retract an unkeyed declared wait"

    f=$(status_log "retract-$verb-unkeyed-over-keyed" \
      'paused [key=vendor]: waiting on the vendor rate-limit reset' \
      "$verb: the wait is over")
    assert_no_standing "$f" "an unkeyed '$verb:' line did not retract a keyed declared wait"

    f=$(status_log "retract-$verb-other-key" \
      'paused [key=vendor]: waiting on the vendor rate-limit reset' \
      "$verb [key=route]: the wait is over")
    assert_no_standing "$f" "a differently-keyed '$verb:' line did not retract the declared wait"
  done
  pass "every terminal captain verb retracts a standing declaration whatever key it carries, and the retraction set contains that same set"
}

# `resolved:` is the retraction that matters most, because it is the only one that
# lifts a wait WITHOUT ending the task - and bin/fm-brief.sh already tells a worker
# to append it when a blocker or wait clears with no firstmate reply. Without it a
# worker still waiting and a worker that resumed would be indistinguishable, since
# `working:` cannot be told apart from the same line emitted by a reporter the
# worker armed.
test_the_resolution_verb_retracts_without_ending_the_task() {
  local f
  f=$(status_log retract-resolved "$PAUSE" 'resolved: the upstream release landed')
  assert_no_standing "$f" "a 'resolved:' line did not retract the declared wait"

  # Keyed too, since that is the form a worker answering its own blocker writes.
  # Resolution is key-scoped, so the keyed form clears the declaration that
  # states the SAME key; test_only_the_resolution_verb_is_key_scoped below owns
  # the other half.
  f=$(status_log retract-resolved-keyed \
    'paused [key=release]: waiting on the vendor release' \
    'resolved [key=release]: access arrived')
  assert_no_standing "$f" "a keyed 'resolved:' line did not retract its own declared wait"

  # And the worker can then keep working without re-declaring anything.
  f=$(status_log retract-resolved-resume "$PAUSE" 'resolved: access arrived' 'working: resumed the sweep')
  assert_no_standing "$f" "a retracted wait came back when the worker resumed"

  # The boundary this pins in the other direction: `working:` ALONE never retracts.
  # If this ever flips, the masking defect is back.
  f=$(status_log retract-working-alone "$PAUSE" 'working: resumed after access arrived')
  assert_standing "$f" "$PAUSE" "a bare 'working:' line retracted the declared wait - the masking defect is back"

  # The two folds must agree on what closes a declared phase, or a supervisor and
  # the fleet snapshot would disagree about whether the same wait ended.
  case "$(printf '%s\n' "$PAUSE" 'resolved: the upstream release landed' | status_open_activities -)" in
    '') : ;;
    *) fail "status_open_activities still holds a phase 'resolved:' closed, so the two folds disagree" ;;
  esac
  pass "the resolution verb retracts a wait without ending the task, a bare working: line still does not, and the two folds agree"
}

# The masking defect, reached by a producer the `working:` rule does not cover.
# Firstmate answering an UNRELATED decision writes `resolved [key=<other>]`
# straight into the WORKER's own status log (bin/fm-send.sh --resolve-key), and
# bin/fm-pending-reply-lib.sh writes the same close line automatically when a
# pending reply is consumed. A keyless retraction rule would let either one cancel
# a wait about something else and restart the possible-wedge ladder - the same
# masking this fold exists to stop, one producer over. So `resolved:` - and ONLY
# `resolved:`, the one retraction verb another producer writes into this log -
# must carry the declaration's own key to retract it. The terminal captain verbs
# stay unconditional; test_every_terminal_verb_retracts above owns that half.
test_only_the_resolution_verb_is_key_scoped() {
  local f
  # The live shape: an open keyed decision, a separate unkeyed wait, firstmate
  # answering the decision through fm-send --resolve-key.
  f=$(status_log key-scope-foreign-resolve \
    'needs-decision [key=route]: north or south?' \
    "$PAUSE" \
    'resolved [key=route]: north')
  assert_standing "$f" "$PAUSE" \
    "answering an unrelated keyed decision cancelled a live declared wait"

  # And the reverse direction: an unkeyed resolution cannot clear a KEYED wait,
  # because a bare `resolved:` states the "default" key, not "every key".
  f=$(status_log key-scope-bare-vs-keyed \
    'paused [key=vendor]: waiting on the vendor rate-limit reset' \
    'resolved: some other thing cleared')
  assert_standing "$f" 'paused [key=vendor]: waiting on the vendor rate-limit reset' \
    "a bare 'resolved:' cancelled a keyed declared wait it does not name"

  # The resolutions that DO hold, so the scoping did not turn into a mute: same
  # key both sides, and unkeyed both sides (both being the "default" key).
  f=$(status_log key-scope-matching-key \
    'paused [key=vendor]: waiting on the vendor rate-limit reset' \
    'resolved [key=vendor]: the vendor window opened')
  assert_no_standing "$f" "a resolution carrying the declaration's own key did not retract it"

  f=$(status_log key-scope-both-unkeyed "$PAUSE" 'resolved: the upstream release landed')
  assert_no_standing "$f" "an unkeyed resolution did not retract an unkeyed declaration"

  # The stated key may sit in either documented position (_fm_decision_key owns
  # that grammar), so the two positions must scope identically.
  f=$(status_log key-scope-note-head-position \
    'paused: [key=vendor] waiting on the vendor rate-limit reset' \
    'resolved [key=vendor]: the vendor window opened')
  assert_no_standing "$f" "a note-head key position did not scope the resolution the same way"
  pass "only the resolution verb is key-scoped, so answering another decision cannot cancel a live wait"
}

# A key the crew chose that is not a strict slug - a branch-shaped `fm/feat-x`,
# or one with a space - must never cost the crew its suppression. bin/fm-brief.sh
# tells crews to carry `[key=<work-slug>]` across their paused/done/blocked lines,
# so unparsable keys are realistic worker output, and a declaration that silently
# vanishes because of one is exactly the failure this whole fold exists to remove.
test_an_unparsable_key_never_drops_the_declaration() {
  local f decl
  for decl in \
    'paused [key=fm/feat-x]: waiting on the upstream maintainer' \
    'paused [key=two words]: waiting on the upstream maintainer' \
    'captain-held [key=fm/feat-x]: awaiting the captain on the routing call'
  do
    f=$(status_log "unparsable-key-$RANDOM" "$decl" 'working: reporter tick')
    assert_standing "$f" "$decl" "an unparsable key dropped the declaration entirely"
  done

  # Both sides falling back to the shared `default` bucket, so a resolution
  # naming the same unparsable key still retracts rather than sticking forever.
  f=$(status_log unparsable-key-resolved \
    'paused [key=fm/feat-x]: waiting on the upstream maintainer' \
    'resolved [key=fm/feat-x]: the upstream release landed')
  assert_no_standing "$f" "a resolution naming the declaration's own unparsable key did not retract it"
  pass "an unparsable key leaves the declaration standing instead of silently dropping it"
}

# A retracted declaration stays retracted through later non-declaring lines: the
# fold must not resurrect it from the earlier pause line.
test_a_retracted_declaration_stays_retracted() {
  local f
  f=$(status_log retract-then-work \
    "$PAUSE" \
    'done: the upstream release landed' \
    'working: back on the fix' \
    'note: rebased onto the new base')
  assert_no_standing "$f" "a retracted declaration was resurrected by later non-declaring lines"
  pass "a retracted declaration is not resurrected by later working/note lines"
}

# And re-declaring after a retraction works, so a crew that resumes and then hits
# a second external wait gets the suppression again.
test_a_new_declaration_after_a_retraction_stands() {
  local f second='paused: waiting on the vendor rate-limit reset'
  f=$(status_log redeclare "$PAUSE" 'done: the upstream release landed' 'working: back on the fix' "$second")
  assert_standing "$f" "$second" "a crew could not declare a second wait after retracting the first"
  pass "a crew can declare a new wait after retracting an earlier one"
}

# The newest declaration wins, so a recheck reports the wait that is actually
# current rather than a superseded one.
test_a_later_declaration_replaces_an_earlier_one() {
  local f second='paused: waiting on the vendor rate-limit reset'
  f=$(status_log replace "$PAUSE" 'working: still holding' "$second")
  assert_standing "$f" "$second" "the newest declaration did not replace the earlier one"
  pass "a later declaration replaces an earlier one, so a recheck names the current wait"
}

# --- the disconfirming cases -------------------------------------------------
#
# A crew that never declared anything must fold to nothing, because that empty
# result is what routes an idle pane to the possible-wedge ladder. If this ever
# starts returning a line, every undeclared wedge in the fleet goes quiet.
test_an_undeclared_log_folds_to_nothing() {
  local f
  f=$(status_log undeclared 'working: implementing the fix' 'note: rebased' 'working: tests green')
  assert_no_standing "$f" "an undeclared crew produced a standing declaration"

  f=$(status_log undeclared-terminal 'working: implementing the fix' 'blocked: cannot reach the release host')
  assert_no_standing "$f" "a blocked crew produced a standing declaration"

  # Prose that merely mentions pausing is not a declaration - the verb owns it.
  f=$(status_log undeclared-prose 'working: paused the animation loop' 'note: the build is paused upstream')
  assert_no_standing "$f" "prose mentioning 'paused' was read as a declaration"
  pass "an undeclared log folds to nothing, so the possible-wedge ladder is unchanged for it"
}

test_absent_and_empty_logs_fold_to_nothing() {
  local dir f
  dir="$TMP_ROOT/absent"; mkdir -p "$dir"
  assert_no_standing "$dir/missing.status" "a missing status file produced a standing declaration"
  status_standing_wait_line "$dir/missing.status" \
    || fail "a missing status file made the fold fail rather than fold to nothing"

  f=$(status_log empty-log)
  assert_no_standing "$f" "an empty status file produced a standing declaration"
  pass "a missing or empty status log folds to nothing without failing"
}

# Blank and whitespace-only lines are ordinary log noise and must not disturb the
# fold in either direction.
test_blank_lines_do_not_disturb_the_fold() {
  local f
  f=$(status_log blank-lines "$PAUSE" '' '   ' 'working: reporter tick' '')
  assert_standing "$f" "$PAUSE" "blank lines cancelled the declared wait"

  f=$(status_log blank-lines-retract "$PAUSE" '' 'done: shipped' '  ')
  assert_no_standing "$f" "blank lines after a terminal line resurrected the declaration"
  pass "blank and whitespace-only lines disturb the fold in neither direction"
}

# --- the second declaring verb -----------------------------------------------
#
# captain-held: is the other declaration that leaves a pane idle by design, and it
# blocks on a DIFFERENT human. It gets the same standing treatment and must stay
# distinguishable, or a recheck would point the captain at an external dependency
# for a decision only they can release.
test_a_captain_held_transfer_stands_the_same_way() {
  local f
  f=$(status_log held-masked "$HELD" 'working: run 01ABC step ci,running')
  assert_standing "$f" "$HELD" "a foreign append cancelled a verified captain hold"
  status_is_captain_held "$(status_standing_wait_line "$f")" \
    || fail "the standing captain hold is no longer distinguishable from an external-wait pause"
  status_is_paused "$(status_standing_wait_line "$f")" \
    && fail "a captain hold was read as an external-wait pause, so a recheck would name the wrong human"

  f=$(status_log held-retracted "$HELD" 'needs-decision [key=route]: the captain must choose')
  assert_no_standing "$f" "a terminal line did not retract a captain hold"
  pass "a captain hold stands and retracts exactly like a pause, and stays distinguishable from one"
}

# --- vocabulary has one owner ------------------------------------------------
#
# The pause verb is configurable (FM_CLASSIFY_PAUSED_VERB) so the two supervisors
# cannot drift. The fold must read that override rather than the literal, or a
# home that renamed the verb would silently lose every declaration.
test_the_configured_pause_verb_is_honored() {
  local f got custom='holding: waiting on the upstream maintainer'
  f=$(status_log custom-verb "$custom" 'working: reporter tick')
  assert_no_standing "$f" "an unconfigured verb was read as a declaration"
  got=$(FM_CLASSIFY_PAUSED_VERB=holding status_standing_wait_line "$f")
  [ "$got" = "$custom" ] || fail "the configured pause verb was not honored (standing=[$got])"
  pass "the fold reads the configured pause verb, so the vocabulary keeps one owner"
}

# A declaration may carry the correlation token a marked request echoes back
# (bin/fm-pending-reply-lib.sh). The verb parse reads through it everywhere else,
# and it must here too, or a correlated declaration would never suppress.
test_a_correlated_declaration_is_read_through() {
  local f corr=c44897ee2db4326b decl
  decl="paused corr=$corr: waiting on the upstream maintainer"
  f=$(status_log correlated "$decl" 'working: reporter tick')
  assert_standing "$f" "$decl" "a correlated declaration was not recognized"

  f=$(status_log correlated-retract "$decl" "done corr=$corr: shipped")
  assert_no_standing "$f" "a correlated terminal line did not retract the declaration"
  pass "a correlation token is read through in both directions of the fold"
}

# --- the fold must stay cheap ------------------------------------------------
#
# This gate runs for every window on every watcher poll, so its cost is paid on
# the same cadence the wake cost this change removes was paid on. The hazard is
# specific and easy to reintroduce: the LINE-taking predicates
# (status_is_paused_or_captain_held, status_is_terminal_verb) each capture the
# verb through a `$(...)` substitution, which forks. Folding those over a whole
# log costs a fork per predicate per line. Measured on this repo's own machine:
# 20 folds of a 500-line log took 41s with the line-taking predicates and 0.34s
# with the verb-taking ones the fold actually uses - a factor of about 120.
#
# The bound below sits between those two numbers with a wide margin on both
# sides (about 40x above the fork-free cost, about 3x below the forking one), so
# it is a regression guard rather than a benchmark: it fails only if per-line
# forking comes back, and a merely slow or loaded machine still passes.
test_the_fold_stays_cheap_over_a_long_log() {
  local dir f i elapsed started ended
  dir="$TMP_ROOT/cost"; mkdir -p "$dir"
  f="$dir/task.status"
  # A declaration buried under a long run of appends: the worst realistic shape,
  # and the shape the incident actually produced (an armed reporter that appended
  # for nearly eighteen hours).
  printf 'paused: waiting on the upstream maintainer\n' > "$f"
  i=0
  while [ "$i" -lt 500 ]; do
    printf 'working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,running %s\n' "$i" >> "$f"
    i=$((i + 1))
  done

  started=$(date +%s)
  i=0
  while [ "$i" -lt 20 ]; do
    status_standing_wait_line "$f" > /dev/null
    i=$((i + 1))
  done
  ended=$(date +%s)
  elapsed=$(( ended - started ))
  [ "$elapsed" -le 15 ] \
    || fail "20 folds of a 500-line log took ${elapsed}s (bound 15s) - the fold is forking per line again"

  # And it still answers correctly at that length, so the guard cannot pass by
  # folding nothing.
  assert_standing "$f" 'paused: waiting on the upstream maintainer' \
    "the fold lost the declaration under 500 appends"
  pass "the fold stays cheap over a long log (${elapsed}s for 20 folds of 500 lines) and still answers correctly"
}

test_the_reported_masking_sequence_keeps_the_declaration
test_non_declaring_producers_never_retract
test_every_terminal_verb_retracts
test_the_resolution_verb_retracts_without_ending_the_task
test_only_the_resolution_verb_is_key_scoped
test_an_unparsable_key_never_drops_the_declaration
test_a_retracted_declaration_stays_retracted
test_a_new_declaration_after_a_retraction_stands
test_a_later_declaration_replaces_an_earlier_one
test_an_undeclared_log_folds_to_nothing
test_absent_and_empty_logs_fold_to_nothing
test_blank_lines_do_not_disturb_the_fold
test_a_captain_held_transfer_stands_the_same_way
test_the_configured_pause_verb_is_honored
test_a_correlated_declaration_is_read_through
test_the_fold_stays_cheap_over_a_long_log

echo "all fm-declared-pause-standing tests passed"
