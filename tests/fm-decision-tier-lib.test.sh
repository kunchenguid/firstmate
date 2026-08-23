#!/usr/bin/env bash
# tests/fm-decision-tier-lib.test.sh - unit tests for the decision-tiering
# classifier, the decision-record shape, the default-with-veto status
# derivation, and the report counters (bin/fm-decision-tier-lib.sh). Pure
# functions plus a private temp log file; no backend, no clock dependency
# (every time-sensitive function takes epoch seconds explicitly).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-decision-tier-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-tier-lib)
LOG="$TMP_ROOT/decisions.log"

# --- 1. the classification table --------------------------------------------

[ "$(fm_decision_tier_classify precedent-match)" = "auto" ] || fail "precedent-match must classify auto"
[ "$(fm_decision_tier_classify sibling-answer-reuse)" = "auto" ] || fail "sibling-answer-reuse must classify auto"
[ "$(fm_decision_tier_classify measurement-refuted-revert)" = "auto" ] || fail "measurement-refuted-revert must classify auto"
[ "$(fm_decision_tier_classify stale-comment-correction)" = "auto" ] || fail "stale-comment-correction must classify auto"
[ "$(fm_decision_tier_classify followup-routing)" = "auto" ] || fail "followup-routing must classify auto"
pass "every documented auto category classifies auto"

[ "$(fm_decision_tier_classify two-option-tradeoff)" = "default-veto" ] || fail "two-option-tradeoff must classify default-veto"
[ "$(fm_decision_tier_classify scope-narrowing)" = "default-veto" ] || fail "scope-narrowing must classify default-veto"
[ "$(fm_decision_tier_classify risk-tradeoff-reversible)" = "default-veto" ] || fail "risk-tradeoff-reversible must classify default-veto"
[ "$(fm_decision_tier_classify process-default)" = "default-veto" ] || fail "process-default must classify default-veto"
pass "every documented default-veto category classifies default-veto"

for cat in merge destructive irreversible scope-expansion client-facing credential outward-facing security-sensitive; do
  [ "$(fm_decision_tier_classify "$cat")" = "hard-stop" ] || fail "$cat must classify hard-stop"
done
pass "every documented hard-stop category classifies hard-stop"

# Fail-closed: this is the property that keeps an unrecognized category from
# silently acting or silently proceeding on a stated default. Mutating the
# classify table's default case to anything other than hard-stop must turn
# this assertion red.
[ "$(fm_decision_tier_classify some-category-nobody-registered-yet)" = "hard-stop" ] \
  || fail "an unrecognized category must fail closed to hard-stop"
[ "$(fm_decision_tier_classify "")" = "hard-stop" ] || fail "an empty category must fail closed to hard-stop"
pass "an unrecognized or empty category fails closed to hard-stop"

# categories-for is derived from classify, not a second table: every category
# it returns for a tier must itself classify to that tier, and every known
# category must show up in exactly one tier's list.
TOTAL_KNOWN=$(fm_decision_tier_known_categories | grep -c .)
TOTAL_BY_TIER=0
for tier in $(fm_decision_tier_tiers); do
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$(fm_decision_tier_classify "$c")" = "$tier" ] || fail "categories_for $tier returned $c, which classifies $(fm_decision_tier_classify "$c")"
    TOTAL_BY_TIER=$((TOTAL_BY_TIER + 1))
  done < <(fm_decision_tier_categories_for "$tier")
done
[ "$TOTAL_BY_TIER" -eq "$TOTAL_KNOWN" ] || fail "categories_for across all three tiers ($TOTAL_BY_TIER) must partition the known vocabulary ($TOTAL_KNOWN)"
pass "categories_for partitions the known vocabulary across exactly the three tiers, derived from classify"

# --- 2. the decision record ---------------------------------------------------

REC=$(fm_decision_tier_record 1000 dec-1 merge hard-stop escalated "" "" "" "attempted merge without explicit captain word")
[ "$(fm_decision_tier_epoch "$REC")" = "1000" ] || fail "epoch accessor wrong: $REC"
[ "$(fm_decision_tier_id "$REC")" = "dec-1" ] || fail "id accessor wrong: $REC"
[ "$(fm_decision_tier_category "$REC")" = "merge" ] || fail "category accessor wrong: $REC"
[ "$(fm_decision_tier_tier "$REC")" = "hard-stop" ] || fail "tier accessor wrong: $REC"
[ "$(fm_decision_tier_event "$REC")" = "escalated" ] || fail "event accessor wrong: $REC"
[ "$(fm_decision_tier_note "$REC")" = "attempted merge without explicit captain word" ] || fail "note accessor wrong: $REC"
pass "fm_decision_tier_record builds a 9-field record and every accessor reads its field"

TABS=$(printf '%s' "$REC" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$TABS" = "8" ] || fail "record must have exactly 8 TAB separators (9 fields), got $TABS"
pass "fm_decision_tier_record uses a single TAB between each of the nine fields"

DIRTY=$(fm_decision_tier_record 1000 dec-1 merge hard-stop escalated "" "" "" $'multi\tline\nnote')
DIRTY_TABS=$(printf '%s' "$DIRTY" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$DIRTY_TABS" = "8" ] || fail "a field with a stray TAB/newline must not add columns, got $DIRTY_TABS tabs"
[ "$(fm_decision_tier_event "$DIRTY")" = "escalated" ] || fail "stray-field scrub desynced event: $DIRTY"
pass "fm_decision_tier_record scrubs TAB/newline out of fields so the record stays exactly nine columns"

# --- mutators refuse a category that classifies to a different tier --------

if fm_decision_tier_log_auto "$LOG" 1000 dec-bad merge "should be refused" 2>/dev/null; then
  fail "log_auto must refuse a hard-stop category (merge)"
fi
[ ! -s "$LOG" ] || fail "a refused log_auto must not write anything to the log"
pass "log_auto refuses to log a category that classifies outside auto"

if fm_decision_tier_log_hard_stop "$LOG" 1000 dec-bad precedent-match "should be refused" 2>/dev/null; then
  fail "log_hard_stop must refuse an auto category (precedent-match)"
fi
[ ! -s "$LOG" ] || fail "a refused log_hard_stop must not write anything to the log"
pass "log_hard_stop refuses to log a category that classifies outside hard-stop"

if fm_decision_tier_open_default "$LOG" 1000 dec-bad merge "rec" "default" 300 2>/dev/null; then
  fail "open_default must refuse a hard-stop category (merge)"
fi
[ ! -s "$LOG" ] || fail "a refused open_default must not write anything to the log"
pass "open_default refuses to open a timed default for a category that classifies outside default-veto"

if fm_decision_tier_open_default "$LOG" 1000 dec-bad process-default "rec" "default" 0 2>/dev/null; then
  fail "open_default must refuse a zero window"
fi
[ ! -s "$LOG" ] || fail "a refused zero-window open_default must not write anything to the log"
pass "open_default refuses a zero-second window"

if fm_decision_tier_open_default "$LOG" 1000 dec-bad two-option-tradeoff "" "apply default" 300 2>/dev/null; then
  fail "open_default must refuse an empty recommendation"
fi
[ ! -s "$LOG" ] || fail "a refused empty-recommendation open_default must not write anything to the log"
pass "open_default refuses an empty recommendation"

if fm_decision_tier_open_default "$LOG" 1000 dec-bad two-option-tradeoff "prefer A" "" 300 2>/dev/null; then
  fail "open_default must refuse an empty default action"
fi
[ ! -s "$LOG" ] || fail "a refused empty-default-action open_default must not write anything to the log"
pass "open_default refuses an empty default action"

# A recommendation/default action of pure whitespace is not empty (the
# nonempty check alone would let it through) but carries no content once
# fm_decision_tier_clean_field's TAB/newline scrub runs on it - the exact gap
# fm_decision_tier_require_meaningful closes.
if fm_decision_tier_open_default "$LOG" 1000 dec-bad two-option-tradeoff "   " "apply default" 300 2>/dev/null; then
  fail "open_default must refuse a whitespace-only recommendation"
fi
[ ! -s "$LOG" ] || fail "a refused whitespace-only-recommendation open_default must not write anything to the log"
pass "open_default refuses a recommendation that is whitespace only"

if fm_decision_tier_open_default "$LOG" 1000 dec-bad two-option-tradeoff "prefer A" "$(printf '\t\n')" 300 2>/dev/null; then
  fail "open_default must refuse a default action that is only a TAB/newline"
fi
[ ! -s "$LOG" ] || fail "a refused whitespace-only-default-action open_default must not write anything to the log"
pass "open_default refuses a default action that is whitespace only"

# --- mutators refuse an id that already has any record in the log ----------

REUSE_LOG="$TMP_ROOT/decisions-reuse.log"

fm_decision_tier_log_auto "$REUSE_LOG" 1000 dec-reuse-1 precedent-match "first use of this id" \
  || fail "log_auto should succeed for a fresh id"
if fm_decision_tier_log_auto "$REUSE_LOG" 2000 dec-reuse-1 precedent-match "second use, same id" 2>/dev/null; then
  fail "log_auto must refuse an id that already has a record"
fi
if fm_decision_tier_log_hard_stop "$REUSE_LOG" 2000 dec-reuse-1 merge "reuse via a different mutator" 2>/dev/null; then
  fail "log_hard_stop must refuse an id already used by log_auto"
fi
if fm_decision_tier_open_default "$REUSE_LOG" 2000 dec-reuse-1 two-option-tradeoff "rec" "default" 300 2>/dev/null; then
  fail "open_default must refuse an id already used by log_auto"
fi
REUSE_RECORD_COUNT=$(fm_decision_tier_find_records "$REUSE_LOG" dec-reuse-1 | grep -c .)
[ "$REUSE_RECORD_COUNT" = "1" ] || fail "every refused reuse attempt must leave the id with exactly its original record, got $REUSE_RECORD_COUNT"
pass "log_auto, log_hard_stop, and open_default all refuse an id that already has a record, from any mutator"

# --- concurrent writers must not both pass the uniqueness check ------------
#
# A sequential reuse attempt (above) can't catch a race: without a lock
# around the check-and-append sequence, two processes can both read "no
# record for this id yet" before either has written, and both append -
# fm_decision_tier_require_unused_id alone can't see a write that hasn't
# happened yet. This spawns two real background processes contending for the
# same fresh id and asserts the lock serializes them down to exactly one
# surviving record. Comment out either fm_decision_tier_lock_acquire call in
# open_default/log_auto to see this go red.
CONCURRENT_LOG="$TMP_ROOT/decisions-concurrent.log"
CONCURRENT_ID="dec-concurrent-1"
CONCURRENT_RESULTS="$TMP_ROOT/concurrent-results"
mkdir -p "$CONCURRENT_RESULTS"

fm_decision_tier_concurrent_attempt() {  # <slot>
  if fm_decision_tier_log_auto "$CONCURRENT_LOG" 1000 "$CONCURRENT_ID" precedent-match "concurrent attempt $1" 2>/dev/null; then
    printf 'ok\n' > "$CONCURRENT_RESULTS/$1"
  else
    printf 'refused\n' > "$CONCURRENT_RESULTS/$1"
  fi
}

fm_decision_tier_concurrent_attempt 1 &
CONCURRENT_PID_1=$!
fm_decision_tier_concurrent_attempt 2 &
CONCURRENT_PID_2=$!
wait "$CONCURRENT_PID_1" "$CONCURRENT_PID_2"

CONCURRENT_RECORD_COUNT=$(fm_decision_tier_find_records "$CONCURRENT_LOG" "$CONCURRENT_ID" | grep -c .)
[ "$CONCURRENT_RECORD_COUNT" = "1" ] \
  || fail "two concurrent log_auto calls racing on the same fresh id must leave exactly one record, got $CONCURRENT_RECORD_COUNT"

CONCURRENT_OK_COUNT=$(cat "$CONCURRENT_RESULTS"/1 "$CONCURRENT_RESULTS"/2 | grep -c '^ok$')
[ "$CONCURRENT_OK_COUNT" = "1" ] \
  || fail "exactly one of two concurrent log_auto calls racing on the same fresh id must succeed, got $CONCURRENT_OK_COUNT"
pass "concurrent writers opening the same fresh id are serialized by the log lock, not both accepted"

# --- successful logging for each tier ---------------------------------------

fm_decision_tier_log_auto "$LOG" 1000 dec-auto-1 precedent-match "matched the sibling ruling from dec-0" \
  || fail "log_auto should succeed for an auto category"
STATUS_OUT=$(fm_decision_tier_status "$LOG" dec-auto-1 1000)
[ "$STATUS_OUT" = "unknown" ] || fail "an acted auto decision has no opened record, status must read unknown, got $STATUS_OUT"
pass "log_auto succeeds and writes an acted record for an auto category"

fm_decision_tier_log_hard_stop "$LOG" 1000 dec-hard-1 merge "attempted merge, escalated per hard rule 2" \
  || fail "log_hard_stop should succeed for a hard-stop category"
pass "log_hard_stop succeeds and writes an escalated record for a hard-stop category"

# --- 3. status derivation and the default-with-veto timeout -----------------

fm_decision_tier_open_default "$LOG" 1000 dec-default-1 two-option-tradeoff \
  "prefer option A" "apply option A" 300 \
  || fail "open_default should succeed for a default-veto category"

[ "$(fm_decision_tier_status "$LOG" dec-default-1 1100)" = "pending" ] \
  || fail "inside the window, status must be pending"
[ "$(fm_decision_tier_status "$LOG" dec-default-1 1300)" = "expired" ] \
  || fail "exactly at the window boundary (now - opened == window), status must be expired"
[ "$(fm_decision_tier_status "$LOG" dec-default-1 5000)" = "expired" ] \
  || fail "well past the window, status must be expired"
pass "a default-veto decision transitions pending -> expired purely as a function of time, with no poll or reminder"

[ "$(fm_decision_tier_status "$LOG" dec-never-opened 1000)" = "unknown" ] \
  || fail "an id with no opened record must report unknown"
pass "status on an id that was never opened reports unknown"

fm_decision_tier_open_default "$LOG" 1000 dec-default-2 scope-narrowing \
  "narrow the wording" "apply the narrower wording" 300 \
  || fail "open_default should succeed for the veto scenario"
fm_decision_tier_veto "$LOG" 1100 dec-default-2 "captain wants the broader wording kept" \
  || fail "veto should succeed while the decision is still pending"
[ "$(fm_decision_tier_status "$LOG" dec-default-2 5000)" = "vetoed" ] \
  || fail "a vetoed decision must stay vetoed even long past its window"
pass "vetoing inside the window wins permanently, even checked long after the original window would have elapsed"

if fm_decision_tier_veto "$LOG" 1100 dec-default-2 "second veto attempt" 2>/dev/null; then
  fail "vetoing an already-vetoed decision a second time must be refused"
fi
pass "a second veto on an already-vetoed decision is refused"

fm_decision_tier_open_default "$LOG" 1000 dec-default-3 risk-tradeoff-reversible \
  "take the reversible path" "apply the reversible path" 300 \
  || fail "open_default should succeed for the too-late-veto scenario"
if fm_decision_tier_veto "$LOG" 5000 dec-default-3 "too-late objection" 2>/dev/null; then
  fail "vetoing after the window has expired must be refused - the default already cleared to run"
fi
[ "$(fm_decision_tier_status "$LOG" dec-default-3 5000)" = "expired" ] \
  || fail "a refused too-late veto must leave the decision's status as expired, not silently vetoed"
pass "vetoing after the window has already expired is refused, so a stated default cannot be reopened after it cleared to run"

# --- reporting ----------------------------------------------------------------

REPORT=$(fm_decision_tier_report "$LOG" 5000)
get_counter() {  # <key>
  printf '%s\n' "$REPORT" | grep "^$1=" | cut -d= -f2
}
# Log contents by id at this point:
#   dec-auto-1     -> acted      (auto)
#   dec-hard-1     -> escalated  (hard-stop)
#   dec-default-1  -> opened only, expired by now=5000
#   dec-default-2  -> opened + vetoed
#   dec-default-3  -> opened only, expired by now=5000 (veto attempt was refused, wrote nothing)
[ "$(get_counter total)" = "5" ] || fail "report total should count 5 distinct ids, got $(get_counter total)"
[ "$(get_counter auto)" = "1" ] || fail "report auto should be 1, got $(get_counter auto)"
[ "$(get_counter hard_stop)" = "1" ] || fail "report hard_stop should be 1, got $(get_counter hard_stop)"
[ "$(get_counter default_expired)" = "2" ] || fail "report default_expired should be 2, got $(get_counter default_expired)"
[ "$(get_counter default_vetoed)" = "1" ] || fail "report default_vetoed should be 1, got $(get_counter default_vetoed)"
[ "$(get_counter default_pending)" = "0" ] || fail "report default_pending should be 0, got $(get_counter default_pending)"
[ "$(get_counter escalation_count)" = "1" ] || fail "escalation_count must equal hard_stop (the only tier that unconditionally escalates), got $(get_counter escalation_count)"
pass "fm_decision_tier_report aggregates every id into the right counter and reports a measurable escalation_count"

EMPTY_REPORT=$(fm_decision_tier_report "$TMP_ROOT/no-such-log.log" 1000)
[ "$(printf '%s\n' "$EMPTY_REPORT" | grep '^total=')" = "total=0" ] || fail "a report over a missing log must read as zero decisions, not error"
pass "reporting on a log that does not exist yet reports all-zero counters instead of failing"

echo "# fm-decision-tier-lib.test.sh: all assertions passed"
