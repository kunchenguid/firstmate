#!/usr/bin/env bash
# tests/fm-classify-routing-promotion.test.sh - the routing-promotion verb in the
# open-decisions fold and the captain-relevance classifier (bin/fm-classify-lib.sh).
# A task's effective tier is the higher of both resolution passes, but the second
# pass runs inside the crewmate AFTER firstmate has frozen every tier-dependent
# dispatch decision. `promoted` is how the crewmate reports that upward re-resolve,
# and it must behave like an OPEN keyed record (so the re-staff obligation survives a
# restart and an unhandled promotion is detectable) while staying NONTERMINAL (the
# crewmate keeps working) and always surfaced (never absorbed as routine progress).
# These tests drive the REAL status_open_decisions / status_open_decisions_incremental
# / status_is_captain_relevant / status_is_terminal_verb functions over crafted status
# files and assert their behavior, never the library's own source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-routing-promotion-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold equals <expected> and that the incremental fold agrees
# with it: the two consumption strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_promotion_opens_a_durable_record() {
  local d f
  d=$(case_dir opens); f="$d/t.status"
  {
    printf 'working: implementing the bounded change\n'
    printf 'promoted [key=tier]: tier-2 blast-radius - diff reaches the auth policy path\n'
  } > "$f"
  assert_fold "$f" \
    "$(printf 'tier\tpromoted\ttier-2 blast-radius - diff reaches the auth policy path')" \
    "a promotion opens a keyed record"
  pass "a promotion opens a durable keyed open record"
}

test_keyed_resolved_closes_the_promotion() {
  local d f
  d=$(case_dir closes); f="$d/t.status"
  {
    printf 'promoted [key=tier]: tier-2 blast-radius - diff reaches the auth policy path\n'
    printf 'resolved [key=tier]: firstmate re-staffed to two lenses at deep strength\n'
  } > "$f"
  assert_fold "$f" "" "a keyed resolved line closes the promotion"
  pass "a keyed resolved line closes an open promotion"
}

# The whole point of the gate: work continuing past a promotion must NOT clear it.
# Only firstmate's keyed answer does.
test_later_progress_does_not_close_the_promotion() {
  local d f
  d=$(case_dir survives); f="$d/t.status"
  {
    printf 'promoted [key=tier]: tier-2 blast-radius - diff reaches the auth policy path\n'
    printf 'working: continuing implementation while firstmate re-staffs\n'
    printf 'done: PR https://example.invalid/pr/1 checks green\n'
  } > "$f"
  assert_fold "$f" \
    "$(printf 'tier\tpromoted\ttier-2 blast-radius - diff reaches the auth policy path')" \
    "later working and done lines never close an open promotion"
  pass "later working and done lines never close an open promotion"
}

# A two-step rise must behave like a one-step rise: the fold carries whatever tier the
# crewmate reported, and a second promotion supersedes the first under one key.
test_successive_promotions_supersede_under_one_key() {
  local d f
  d=$(case_dir successive); f="$d/t.status"
  {
    printf 'promoted [key=tier]: tier-2 blast-radius - several consumers\n'
    printf 'promoted [key=tier]: tier-3 consequence - migration touches real user data\n'
  } > "$f"
  assert_fold "$f" \
    "$(printf 'tier\tpromoted\ttier-3 consequence - migration touches real user data')" \
    "a second promotion supersedes the first under the same key"
  pass "successive promotions supersede under one key"
}

# Distinct keys are distinct records, exactly as for needs-decision and blocked, so a
# promotion never silently closes an unrelated open decision.
test_promotion_and_decision_are_independent_records() {
  local d f
  d=$(case_dir independent); f="$d/t.status"
  {
    printf 'needs-decision [key=schema]: additive column or a new table\n'
    printf 'promoted [key=tier]: tier-2 novelty - new policy boundary\n'
    printf 'resolved [key=tier]: firstmate re-staffed the review\n'
  } > "$f"
  assert_fold "$f" \
    "$(printf 'schema\tneeds-decision\tadditive column or a new table')" \
    "resolving the promotion leaves an unrelated decision open"
  pass "a promotion and a decision stay independent records"
}

# Keys identify the route used to close a record, but a worker can independently
# promote while an ordinary decision or blocker with that key is still open. The
# promotion must remain gate-visible without allowing its later resolution to erase
# that prior obligation.
test_promotion_collision_preserves_the_existing_obligation() {
  local d f
  d=$(case_dir collision); f="$d/t.status"
  {
    printf 'blocked [key=tier]: wait for the rollback plan\n'
    printf 'promoted [key=tier]: tier-2 auth boundary - new policy path\n'
  } > "$f"
  assert_fold "$f" \
    "$(printf 'tier\tblocked\twait for the rollback plan\ntier\tpromoted\ttier-2 auth boundary - new policy path')" \
    "a promotion preserves an earlier ordinary record with its key"

  printf 'resolved [key=tier]: re-staffed to the stronger runtime\n' >> "$f"
  assert_fold "$f" \
    "$(printf 'tier\tblocked\twait for the rollback plan')" \
    "closing the promotion leaves the prior ordinary record open"
  pass "a colliding promotion cannot erase an earlier open obligation"
}

test_promotion_is_surfaced_not_absorbed() {
  status_is_captain_relevant 'promoted [key=tier]: tier-2 blast-radius - auth policy path' \
    || fail "a promotion line must be surfaced, never absorbed as routine progress"
  status_is_captain_relevant 'working: ordinary progress' \
    && fail "an ordinary working line must not be surfaced"
  # "Always" has to mean always. FM_CAPTAIN_RE lets a home retune what counts as
  # captain-relevant, and every other verb defers to it. A promotion must not,
  # because a home that tuned that regex without knowing this verb existed would
  # silence the one event firstmate is obliged to act on, and would meet it later
  # as a landing refusal it has no context for.
  FM_CAPTAIN_RE='only-this-token' \
    status_is_captain_relevant 'promoted [key=tier]: tier-2 blast-radius - auth policy path' \
    || fail "a promotion must stay surfaced even under a custom captain-relevance regex"
  # That same custom regex still governs the verbs that do defer to it.
  FM_CAPTAIN_RE='only-this-token' \
    status_is_captain_relevant 'done: shipped it' \
    && fail "a custom captain-relevance regex must still govern the ordinary verbs"
  pass "a promotion is always surfaced, never absorbed"
  return 0
}

# Nonterminal: the crewmate keeps working through a promotion, so the stale/terminal
# paths must not treat it as an ended task.
test_promotion_is_not_terminal() {
  status_is_terminal_verb 'promoted [key=tier]: tier-2 blast-radius - auth policy path' \
    && fail "a promotion must not be classified as a terminal verb"
  status_is_terminal_verb 'done: shipped' \
    || fail "done must remain a terminal verb"
  pass "a promotion is nonterminal so the crewmate keeps working"
  return 0
}

# A promotion is not a declared external wait; it must never be absorbed by the
# pause path, which exists to stop wedge-nagging an intentionally idle pane.
test_promotion_is_not_a_pause() {
  status_is_paused 'promoted [key=tier]: tier-2 blast-radius - auth policy path' \
    && fail "a promotion must not classify as a declared pause"
  pass "a promotion never classifies as a declared pause"
  return 0
}

test_promotion_opens_a_durable_record
test_keyed_resolved_closes_the_promotion
test_later_progress_does_not_close_the_promotion
test_successive_promotions_supersede_under_one_key
test_promotion_and_decision_are_independent_records
test_promotion_collision_preserves_the_existing_obligation
test_promotion_is_surfaced_not_absorbed
test_promotion_is_not_terminal
test_promotion_is_not_a_pause
