#!/usr/bin/env bash
# tests/fm-nm-findings-lib.test.sh - behavior tests for the no-mistakes
# finding-retention ledger owned by bin/fm-nm-findings-lib.sh.
#
# Reproduces the reported defect through the ledger's own documented event
# shapes (bin/fm-nm-findings-lib.sh's header is the single owner of that
# format): a registered `axi respond --action fix --findings <ids>` round
# that selects only some of a gate's findings leaves the rest unselected, and
# the tool's own registered interface does not re-surface them on a later
# round (real incident: run 01M1TB9ZZQGN0JQ1RYV3WERD4S review round3, evidence
# data/dos-cited-read-sol8w-implementation/deferred-findings-verbatim-ledger-20260906.json
# in the primary FM_HOME, outside this repo). These tests drive the ledger
# with fixtures shaped exactly like that registered interface's finding
# objects (id, severity, file, description) and its respond disposition
# (fixed/skipped-closed/deferred) to prove retention, explicit
# closure/defer, negative controls, and backward compatibility - without
# requiring a live, token-spending pipeline round.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-nm-findings-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-findings-lib)

command -v jq >/dev/null 2>&1 || fail "fm-nm-findings-lib tests require jq"

new_case() {  # <name> -> echoes <data-dir>, with <data-dir>/<name> as the task dir
  local name=$1 dir
  dir=$(mktemp -d "$TMP_ROOT/case-XXXXXX")
  mkdir -p "$dir/data/$name"
  printf '%s' "$dir/data"
}

ledger_path() {  # <data-dir> <task-id>
  printf '%s/%s/nm-findings-ledger.jsonl' "$1" "$2"
}

append_line() {  # <ledger-path> <json-line>
  printf '%s\n' "$2" >> "$1"
}

test_unselected_findings_are_reproduced_then_retained() {
  local data id ledger folded open_ids

  id=unselected-repro
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  # Round 1: a review gate presents three findings; the registered respond
  # call selects only one to fix (finding-A), exactly reproducing the
  # documented bug shape - finding-B and finding-C are unselected.
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-A","severity":"warning","file":"x.py","description":"desc A"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-B","severity":"info","file":"y.py","description":"desc B"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-C","severity":"warning","file":"z.py","description":"desc C"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-A","disposition":"fixed"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 3 "$(printf '%s' "$folded" | jq 'length')" \
    "round1: all three findings must be retained, not just the selected one"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .disposition')" \
    "round1: unselected finding-B must remain open, never dropped"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .disposition')" \
    "round1: unselected finding-C must remain open, never dropped"
  assert_equals "desc B" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .finding.description')" \
    "round1: retained finding must keep its original verbatim text"

  assert_equals fixed "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-A") | .disposition')" \
    "round1: the selected finding-A must fold to its fixed disposition"
  open_ids=$(printf '%s' "$folded" | jq -r '.[] | select(.disposition=="open") | .id' | sort | tr '\n' ' ')
  assert_equals "finding-B finding-C " "$open_ids" \
    "round1: the open findings must be exactly the two unselected ones"
  pass "fm-nm-findings-lib: reproduces and retains unselected findings across a round"
}

test_retention_across_rounds_with_new_and_deferred_findings() {
  local data id ledger folded

  id=multi-round
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-A","severity":"warning","file":"x.py","description":"desc A"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-B","severity":"info","file":"y.py","description":"desc B"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-C","severity":"warning","file":"z.py","description":"desc C"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-A","disposition":"fixed"}'

  # Round 2: the pipeline's own gate no longer re-shows finding-B or
  # finding-C (the documented behavior), but the ledger keeps them from
  # round1 by construction. A new finding-D appears and is fixed, and
  # finding-C is explicitly deferred to an external owner/id.
  append_line "$ledger" '{"round":2,"step":"review","finding":{"id":"finding-D","severity":"info","file":"w.py","description":"desc D"}}'
  append_line "$ledger" '{"round":2,"step":"review","finding_id":"finding-D","disposition":"fixed"}'
  append_line "$ledger" '{"round":2,"step":"review","finding_id":"finding-C","disposition":"deferred","deferred_owner":"decision-os-tracker","deferred_id":"dos-9912"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 4 "$(printf '%s' "$folded" | jq 'length')" \
    "round2: prior findings must survive alongside the new one"
  assert_equals deferred "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .disposition')" \
    "round2: finding-C must show its explicit defer disposition"
  assert_equals "decision-os-tracker" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .deferred_owner')" \
    "round2: deferred finding must retain its external owner"
  assert_equals "dos-9912" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .deferred_id')" \
    "round2: deferred finding must retain its external id"
  assert_equals 2 "$(printf '%s' "$folded" | jq '.[] | select(.id=="finding-D") | .first_seen.round')" \
    "round2: a finding first seen in round2 must record round2 as its first_seen"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .disposition')" \
    "round2: finding-B must still be open (never resurfaced, never lost)"


  # Round 3: the last open finding is explicitly closed as intentionally
  # not-a-fix (skipped-closed), leaving nothing open.
  append_line "$ledger" '{"round":3,"step":"review","finding_id":"finding-B","disposition":"skipped-closed"}'
  folded=$("$LIB" fold "$data" "$id")
  assert_equals skipped-closed "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .disposition')" \
    "round3: finding-B must show its explicit skipped-closed disposition"
  assert_equals 0 "$(printf '%s' "$folded" | jq '[.[] | select(.disposition=="open")] | length')" \
    "round3: no finding may remain open once every one is closed or deferred"
  pass "fm-nm-findings-lib: retains findings across rounds and reflects explicit close/defer"
}

test_deferred_without_owner_and_id_stays_open() {
  local data id ledger disposition

  id=defer-negative-control
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-X","severity":"warning","file":"a.py","description":"desc X"}}'
  # Missing deferred_id: an incomplete defer must never count as a real defer.
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-X","disposition":"deferred","deferred_owner":"someone"}'

  disposition=$("$LIB" fold "$data" "$id" | jq -r '.[] | select(.id=="finding-X") | .disposition')
  assert_equals open "$disposition" \
    "a deferred disposition missing deferred_id must not be trusted; the finding stays open"
  pass "fm-nm-findings-lib: rejects an incomplete defer as a negative control"
}

test_fixed_with_deferred_fields_is_rejected() {
  local data id ledger disposition

  id=fixed-with-defer-fields
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-Y","severity":"info","file":"b.py","description":"desc Y"}}'
  # A non-deferred disposition must not carry deferred_owner/deferred_id.
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-Y","disposition":"fixed","deferred_owner":"someone","deferred_id":"ext-1"}'

  disposition=$("$LIB" fold "$data" "$id" | jq -r '.[] | select(.id=="finding-Y") | .disposition')
  assert_equals open "$disposition" \
    "a fixed disposition carrying stray deferred fields is malformed and must not be trusted"
  pass "fm-nm-findings-lib: rejects a fixed disposition polluted with defer fields"
}

test_disposition_for_unseen_finding_is_not_fabricated() {
  local data id ledger folded

  id=ghost-disposition
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  # No seen event at all for this id: a disposition alone must never
  # fabricate a closure for a finding nobody ever recorded seeing.
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"ghost-finding","disposition":"fixed"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 0 "$(printf '%s' "$folded" | jq 'length')" \
    "a disposition with no matching seen event must not appear in the fold at all"
  pass "fm-nm-findings-lib: never fabricates a closure for an unseen finding id"
}

test_backward_compatible_with_absent_or_empty_ledger() {
  local data id id2

  id=absent-ledger
  data=$(new_case "$id")
  # No ledger file is ever created for this task.

  assert_equals '[]' "$("$LIB" fold "$data" "$id")" \
    "an absent ledger must fold to an empty array, not an error"

  id2=empty-ledger
  mkdir -p "$data/$id2"
  : > "$(ledger_path "$data" "$id2")"
  assert_equals '[]' "$("$LIB" fold "$data" "$id2")" \
    "an empty ledger file must also fold to an empty array"
  pass "fm-nm-findings-lib: backward compatible with a task that has no findings recorded"
}

test_represented_finding_after_disposition_reopens() {
  local data id ledger folded

  id=represented-after-fix
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-R","severity":"warning","file":"r.py","description":"desc R"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-R","disposition":"fixed"}'
  # Round 3: the fix was incomplete, the gate presents finding-R again, and
  # the worker leaves it unselected - the earlier fix must not mask it.
  append_line "$ledger" '{"round":3,"step":"review","finding":{"id":"finding-R","severity":"warning","file":"r.py","description":"desc R again"}}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-R") | .disposition')" \
    "a finding presented again after its fix, left unselected, must reopen"
  assert_equals 3 "$(printf '%s' "$folded" | jq '.[] | select(.id=="finding-R") | .last_seen.round')" \
    "the reopened finding must record the re-presenting round as last_seen"
  assert_equals "desc R" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-R") | .finding.description')" \
    "the reopened finding must keep its first-seen verbatim text"

  append_line "$ledger" '{"round":3,"step":"review","finding_id":"finding-R","disposition":"fixed"}'
  assert_equals fixed "$("$LIB" fold "$data" "$id" | jq -r '.[] | select(.id=="finding-R") | .disposition')" \
    "a newer disposition after the re-presentation must close the finding again"
  pass "fm-nm-findings-lib: reopens a finding presented again after its disposition"
}

test_same_id_in_two_steps_folds_separately() {
  local data id ledger folded

  id=same-id-two-steps
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"unused-helper","severity":"info","file":"a.sh","description":"review text"}}'
  append_line "$ledger" '{"round":1,"step":"document","finding":{"id":"unused-helper","severity":"info","file":"README.md","description":"document text"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"unused-helper","disposition":"fixed"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 2 "$(printf '%s' "$folded" | jq 'length')" \
    "the same id reported by two steps must fold to two separate findings"
  assert_equals fixed "$(printf '%s' "$folded" | jq -r '.[] | select(.step=="review" and .id=="unused-helper") | .disposition')" \
    "the review step's finding must fold to its own fixed disposition"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.step=="document" and .id=="unused-helper") | .disposition')" \
    "closing the review step's finding must leave the document step's same-id finding open"
  assert_equals "document text" "$(printf '%s' "$folded" | jq -r '.[] | select(.step=="document") | .finding.description')" \
    "the document step's finding must keep its own verbatim text"
  pass "fm-nm-findings-lib: keys findings by step and id so one step cannot close another"
}

test_malformed_lines_do_not_crash_the_fold() {
  local data id ledger folded

  id=malformed-lines
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  printf 'not json at all\n' >> "$ledger"
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-Z","severity":"info","file":"c.py","description":"desc Z"}}'
  printf '{"round":1,"unterminated\n' >> "$ledger"

  folded=$("$LIB" fold "$data" "$id") || fail "a malformed line must not abort the whole fold"
  assert_equals 1 "$(printf '%s' "$folded" | jq 'length')" \
    "the one well-formed finding must still be retained despite surrounding malformed lines"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[0].disposition')" \
    "the well-formed finding must still fold to open"
  pass "fm-nm-findings-lib: tolerates malformed ledger lines without losing valid ones"
}

test_unselected_findings_are_reproduced_then_retained
test_retention_across_rounds_with_new_and_deferred_findings
test_deferred_without_owner_and_id_stays_open
test_fixed_with_deferred_fields_is_rejected
test_disposition_for_unseen_finding_is_not_fabricated
test_backward_compatible_with_absent_or_empty_ledger
test_represented_finding_after_disposition_reopens
test_same_id_in_two_steps_folds_separately
test_malformed_lines_do_not_crash_the_fold
