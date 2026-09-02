#!/usr/bin/env bash
# GATE w6 - a crewmate awaiting its Quarterdeck verdict is not stale.
#
# THE DEFECT. Supervision had no "awaiting verification" state, so a crewmate
# that appended `done:` and then sat waiting on the verifier was indistinguishable
# from one that had wedged. That produced FOUR false reports across
# 2026-08-28..31, including firstmate telling the captain a branch was stalled
# while its fix was already committed and mutation-tested. It is the same root
# cause as the herdr blindness this branch fixes: supervision INFERRED state from
# the pane instead of READING it.
#
# WHERE THE BALL IS, is the whole rule. A `done:` claim with a verify cycle
# running, an approve, an escalate, or an attempt cap reached means firstmate or
# the captain owes the next move - the crewmate is correctly idle. A `reject:`
# hands the ball back: the findings were relayed, the crewmate is expected to be
# working, and an idle pane there is exactly the signal stale detection exists to
# raise. Both directions are pinned here, in one file, so neither can be "fixed"
# by breaking the other.
#
# SUPPRESSION IS NOT MEMOISED. Nothing is written to .stale-* while the wake is
# held back, so the moment the ball returns to the crewmate the very next cycle
# wakes on the unchanged pane. The reject case below is what proves it.
#
# Mutation (LEDGER_MUTATE=1): remove the awaiting condition by leaving the
# verdict file empty and no verify running - a correct watcher then wakes, and
# the silence assertion fails.
set -u

# shellcheck source=tests/watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-w6)

# The wake path needs the status file's signal already consumed, or the watcher
# reports `signal:` before it ever reaches the stale sense. Seeding .seen-* is
# what a watcher that already reported that status line would have left behind.
seed_status() {  # <state> <id> <line>
  local state=$1 id=$2 line=$3 f="$1/$2.status" sf sig
  printf '%s\n' "$line" > "$f"
  sf="$state/.seen-$(basename "$f" | tr '.' '_')"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$f"); else sig=$(stat -c '%s:%Y' "$f"); fi
  printf '%s' "$sig" > "$sf"
}

arrange() {  # <name> <status-line> -> case dir with one idle herdr crewmate
  local dir state
  dir=$(fm_watch_case "$TMP_ROOT" "$1"); state="$dir/state"
  fm_watch_meta "$state" claimer wZ:p1 herdr ship
  fm_watch_prime "$state" wZ:p1 unknown
  seed_status "$state" claimer "$2"
  printf '%s\n' "$dir"
}

run_it() { HERDR_SNAPSHOT_AGENTS='wZ:p1=unknown' fm_watch_run "$@"; }

# Every held case below asserts the watcher actually REACHED its stale decision
# and chose not to wake. Without that, a slow box that never got there would
# read as a correctly-held wake, and the gate would go green on nothing.
held() {  # <case-dir> <out> <what>
  case "$2" in *stale*) fail "$3: $2" ;; esac
  fm_watch_assert_sensed "$1/state" wZ:p1 2 "the watcher never weighed the held case"
}

test_a_running_verify_cycle_holds_the_stale_wake() {
  local dir out
  dir=$(arrange verifying 'done: fix implemented and gates green')
  [ "${LEDGER_MUTATE:-}" = 1 ] || : > "$dir/state/claimer.verifying"
  out=$(run_it "$dir" 40)
  held "$dir" "$out" "a crewmate under an in-flight verify was reported stale"
  pass "w6: a done: claim with a verify cycle running raises no stale wake"
}

test_an_approved_claim_holds_the_stale_wake() {
  local dir out
  dir=$(arrange approved 'done: fix implemented and gates green')
  [ "${LEDGER_MUTATE:-}" = 1 ] || printf 'approve: verifier approve (lens=fugu)\n' > "$dir/state/claimer.verdict"
  out=$(run_it "$dir" 40)
  held "$dir" "$out" "an approved claim awaiting firstmate's next instruction was reported stale"
  pass "w6: an approved done: claim raises no stale wake"
}

# The cap-blocked case: the captain owns it, and the crewmate is told to stop.
test_a_cap_blocked_verdict_holds_the_stale_wake() {
  local dir out
  dir=$(arrange capped 'done: third attempt')
  if [ "${LEDGER_MUTATE:-}" != 1 ]; then
    { printf 'reject: (attempt 1 of 3) x\nreject: (attempt 2 of 3) y\n'
      printf 'reject: (attempt 3 of 3) z\nescalate: attempt cap reached (3 rejects)\n'; } \
      > "$dir/state/claimer.verdict"
  fi
  out=$(run_it "$dir" 40)
  held "$dir" "$out" "a cap-blocked claim waiting on the captain was reported stale"
  pass "w6: a cap-blocked verdict raises no stale wake"
}

# THE OTHER DIRECTION. A reject puts the ball back; an idle pane is then real.
test_a_rejected_claim_still_wakes() {
  local dir out
  dir=$(arrange rejected 'done: first attempt')
  printf 'lens: fugu no blocking findings\nreject: (attempt 1 of 3) the gate ledger is red\n' \
    > "$dir/state/claimer.verdict"
  out=$(run_it "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "a crewmate that went idle after a reject was not reported (got: ${out:-<nothing>})"
  pass "w6: a rejected claim's idle pane still raises a stale wake"
}

# A crewmate that never claimed anything is the ordinary wedged case, and the new
# state must not swallow it.
test_a_working_crewmate_still_wakes() {
  local dir out
  dir=$(arrange working 'working: setup done')
  : > "$dir/state/claimer.verifying"   # even a stray marker must not save it
  out=$(run_it "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "a crewmate wedged mid-work was not reported (got: ${out:-<nothing>})"
  pass "w6: a crewmate that never claimed done still raises a stale wake"
}

# SUPPRESSION LEAVES NO MEMO. Hold the wake, then hand the ball back without
# touching the pane: the next watcher must wake on the identical observation.
test_suppression_does_not_consume_the_wake() {
  local dir out
  dir=$(arrange handback 'done: fix implemented')
  : > "$dir/state/claimer.verifying"
  out=$(run_it "$dir" 40)
  held "$dir" "$out" "the held case woke early"
  [ -e "$dir/state/.stale-wZ_p1" ] \
    && fail "suppression wrote the stale suppressor; the wake can never fire again"
  rm -f "$dir/state/claimer.verifying"
  printf 'reject: (attempt 1 of 3) findings relayed\n' > "$dir/state/claimer.verdict"
  out=$(run_it "$dir")
  printf '%s\n' "$out" | grep -Fx "stale: wZ:p1" >/dev/null \
    || fail "the wake never fired after the ball came back (got: ${out:-<nothing>})"
  pass "w6: holding a wake does not consume it - the same pane wakes once the ball returns"
}

test_a_running_verify_cycle_holds_the_stale_wake
test_an_approved_claim_holds_the_stale_wake
test_a_cap_blocked_verdict_holds_the_stale_wake
test_a_rejected_claim_still_wakes
test_a_working_crewmate_still_wakes
test_suppression_does_not_consume_the_wake
