#!/usr/bin/env bash
# tests/fm-open-decisions-resolved-fold.test.sh - regression test for the
# reserved-key resolution bug: a resolved line whose note does not start with
# the reserved namespace prefix (e.g. "answered:" instead of
# "pending-reply-...:" ) must still close the decision.  Before the fix,
# _fm_decision_key_transition_allowed only recognized the namespace's own
# vocabulary and rejected "answered:" (fm-send.sh --resolve-key) and
# "tracked by" (fm-decision-hold.sh captain-held) - leaving a decision
# nothing could ever resolve through those trusted system paths.
#
# Shapes tested:
#   1. open then resolved on adjacent lines with "answered:" note (the live reproduction)
#   2. open then resolved separated by an intervening cursor checkpoint
#   3. an unrelated writer cannot OPEN a reserved key with a non-vocabulary note
#   4. a foreign resolution cannot CLOSE a reserved key (the safety property)
#   5. captain-held with "tracked by" note closes the decision
#   6. full and incremental folds agree on all of the above
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-open-decisions-resolved-fold-tests)

case_dir() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

# --- Case 1: adjacent open+resolved with "answered:" note (the live reproduction) ---
test_reserved_key_resolved_adjacent() {
  local dir f
  dir=$(case_dir adjacent)
  f="$dir/t.status"

  # The blocked line uses vocabulary ("pending-reply-missed:") - opens.
  # The resolved line uses "answered:" (fm-send.sh --resolve-key) - must close.
  printf 'blocked [key=pending-reply-23332bee7274560a]: pending-reply-missed: task=lucie pending-reply-id=23332bee7274560a request=CONFIG_REREAD: ...\n' > "$f"
  printf 'resolved [key=pending-reply-23332bee7274560a]: answered: Config-reread delivery confirmed\n' >> "$f"

  assert_fold "$f" "" "adjacent reserved-key open+resolved"
  pass "a reserved-key decision resolved on the next line with 'answered:' note is closed"
}

# --- Case 2: open then resolved separated by a cursor checkpoint ------------
test_reserved_key_resolved_across_cursor_checkpoint() {
  local dir f
  dir=$(case_dir cursor-split)
  f="$dir/t.status"

  # Phase 1: only the blocked line exists, fold it so the cursor advances.
  printf 'blocked [key=pending-reply-aabbccdd]: pending-reply-missed: task=x pending-reply-id=aabbccdd request=FOO: ...\n' > "$f"
  local first
  first=$(status_open_decisions_incremental "$f")
  local expected
  expected=$(printf 'pending-reply-aabbccdd\tblocked\tpending-reply-missed: task=x pending-reply-id=aabbccdd request=FOO: ...\n')
  [ "$first" = "$expected" ] \
    || fail "cursor-split phase 1: got '$first' want '$expected'"

  # Phase 2: append the resolution after the cursor checkpoint, then refold.
  printf 'resolved [key=pending-reply-aabbccdd]: answered: confirmed\n' >> "$f"
  assert_fold "$f" "" "cursor-split reserved-key open+resolved across checkpoint"
  pass "a reserved-key resolution arriving after a cursor checkpoint still closes the decision"
}

# --- Case 3: open guard still works - unrelated writer cannot hijack ---------
test_reserved_key_open_guard_still_rejects_non_vocabulary() {
  local dir f
  dir=$(case_dir open-guard)
  f="$dir/t.status"

  # A blocked line with a reserved key but a note that does NOT start with
  # the namespace vocabulary must NOT open a decision.
  printf 'blocked [key=pending-reply-deadbeef]: some unrelated blocker\n' > "$f"
  assert_fold "$f" "" "non-vocabulary open on reserved key"

  # But the same key with the right vocabulary opens normally.
  printf 'blocked [key=pending-reply-deadbeef]: pending-reply-missed: task=y pending-reply-id=deadbeef request=BAR: ...\n' >> "$f"
  local expected
  expected=$(printf 'pending-reply-deadbeef\tblocked\tpending-reply-missed: task=y pending-reply-id=deadbeef request=BAR: ...\n')
  assert_fold "$f" "$expected" "vocabulary open on reserved key"
  pass "the open guard still rejects non-vocabulary opens on reserved keys"
}

# --- Case 4: foreign resolution cannot close a reserved key (safety) ---------
test_foreign_resolution_cannot_close_reserved_key() {
  local dir f expected
  dir=$(case_dir foreign-resolve)
  f="$dir/t.status"

  # Open with vocabulary.
  printf 'blocked [key=pending-reply-abcdef01]: pending-reply-missed: task=ios pending-reply-id=abcdef01 request=ship: ...\n' > "$f"
  # A foreign resolve with a non-vocabulary, non-trusted note must NOT close it.
  printf 'resolved [key=pending-reply-abcdef01]: all good now\n' >> "$f"

  expected=$(printf 'pending-reply-abcdef01\tblocked\tpending-reply-missed: task=ios pending-reply-id=abcdef01 request=ship: ...\n')
  assert_fold "$f" "$expected" "foreign resolution on reserved key"
  pass "a foreign resolution with non-vocabulary note cannot close a reserved-key decision"
}

# --- Case 5: captain-held with "tracked by" closes reserved keys ------------
test_reserved_key_captain_held_closes() {
  local dir f
  dir=$(case_dir captain-held)
  f="$dir/t.status"

  printf 'blocked [key=pending-reply-cafe0001]: pending-reply-missed: task=z pending-reply-id=cafe0001 request=THING: ...\n' > "$f"
  # fm-decision-hold.sh writes "tracked by <hold-id>" as its captain-held note.
  printf 'captain-held [key=pending-reply-cafe0001]: tracked by hold-pending-reply-cafe0001\n' >> "$f"

  assert_fold "$f" "" "captain-held closes reserved key"
  pass "captain-held with 'tracked by' note closes a reserved-key decision"
}

# --- Case 6: non-reserved key behavior unchanged ----------------------------
test_non_reserved_key_still_works() {
  local dir f expected
  dir=$(case_dir non-reserved)
  f="$dir/t.status"

  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$f"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')
  assert_fold "$f" "$expected" "non-reserved open"

  printf 'resolved [key=api-shape]: answered: use REST\n' >> "$f"
  assert_fold "$f" "" "non-reserved resolved"
  pass "non-reserved keys open and close as before"
}

# --- Case 7: pending-reply-resolved vocabulary note also works ---------------
test_reserved_key_vocabulary_resolve_also_works() {
  local dir f
  dir=$(case_dir vocab-resolve)
  f="$dir/t.status"

  # fm-pending-reply-lib.sh writes "pending-reply-resolved:" as its note.
  # This always worked, but verify it still does.
  printf 'blocked [key=pending-reply-11223344]: pending-reply-missed: task=a pending-reply-id=11223344 request=X: ...\n' > "$f"
  printf 'resolved [key=pending-reply-11223344]: pending-reply-resolved: task=a pending-reply-id=11223344 via=direct\n' >> "$f"

  assert_fold "$f" "" "vocabulary-note resolution"
  pass "a reserved-key resolution with vocabulary note still closes (no regression)"
}

test_reserved_key_resolved_adjacent
test_reserved_key_resolved_across_cursor_checkpoint
test_reserved_key_open_guard_still_rejects_non_vocabulary
test_foreign_resolution_cannot_close_reserved_key
test_reserved_key_captain_held_closes
test_non_reserved_key_still_works
test_reserved_key_vocabulary_resolve_also_works
