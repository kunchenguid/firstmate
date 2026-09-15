#!/usr/bin/env bash
# tests/fm-decision-replacement.test.sh - announcement for silenced open-decision
# replacements (bin/fm-classify-lib.sh's status_decision_replacements fold,
# surfaced by bin/fm-wake-drain.sh's DECISION REPLACEMENTS section). The fold
# itself collapses same-key opens on purpose - including two genuinely unkeyed
# decisions sharing "default" - and this suite pins that the fix is the
# announcement, never a change to the fold. Three-way proof: the check FIRES on
# a genuine differing replacement, stays silent on a verbatim re-append (the
# livability case), and stays silent on a prose mention of a key (the rejected
# misplaced-token detector shape must never land here). These tests drive the
# REAL fold and the REAL drain over crafted status logs and assert on their
# printed output, never on either script's source text. Drain wiring lives in
# the second half; the fold contract lives in the first.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-replacement-tests)

# Fresh per-case dir so no cursor or span sidecar leaks between cases.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

test_fires_on_keyed_differing_replacement() {
  local dir
  dir=$(case_dir keyed-fires)
  printf 'needs-decision [key=api-shape]: pick REST\n' > "$dir/t.status"
  printf 'needs-decision [key=api-shape]: pick RPC\n' >> "$dir/t.status"
  [ "$(status_decision_replacements "$dir/t.status")" = "$(printf 'api-shape\tneeds-decision\tpick REST\tpick RPC')" ] \
    || fail "a keyed differing replacement did not announce: '$(status_decision_replacements "$dir/t.status")'"
  [ "$(status_open_decisions "$dir/t.status")" = "$(printf 'api-shape\tneeds-decision\tpick RPC\n')" ] \
    || fail "the fold changed: the survivor is no longer the second note"
  pass "a genuine keyed replacement announces the discarded note while the fold keeps the survivor"
}

test_fires_on_mid_note_default_replacement() {
  local dir
  dir=$(case_dir mid-note-fires)
  printf 'needs-decision: pick [key=api-shape] now please\n' > "$dir/t.status"
  printf 'needs-decision: pick [key=other-shape] now please\n' >> "$dir/t.status"
  [ "$(status_decision_replacements "$dir/t.status")" = "$(printf 'default\tneeds-decision\tpick [key=api-shape] now please\tpick [key=other-shape] now please')" ] \
    || fail "the incident shape stayed silent: '$(status_decision_replacements "$dir/t.status")'"
  pass "two mid-note mentions collapsing in default announce the discarded note"
}

test_fires_on_two_genuinely_unkeyed_decisions() {
  local dir
  dir=$(case_dir unkeyed-fires)
  printf 'needs-decision: first unkeyed question\n' > "$dir/t.status"
  printf 'needs-decision: second unkeyed question\n' >> "$dir/t.status"
  [ -n "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "two genuinely unkeyed decisions overwrote in silence"
  [ "$(status_open_decisions "$dir/t.status")" = "$(printf 'default\tneeds-decision\tsecond unkeyed question\n')" ] \
    || fail "the fold changed: two unkeyed decisions no longer collapse by design"
  pass "two genuinely unkeyed decisions announce their overwrite while still collapsing by design"
}

test_silent_on_verbatim_reappend() {
  local dir
  dir=$(case_dir verbatim-silent)
  printf 'needs-decision: pick [key=api-shape] now please\n' > "$dir/t.status"
  printf 'needs-decision: pick [key=api-shape] now please\n' >> "$dir/t.status"
  [ -z "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "a verbatim re-append announced: '$(status_decision_replacements "$dir/t.status")'"
  printf 'needs-decision [key=route]: north or south\n' > "$dir/k.status"
  printf 'needs-decision [key=route]: north or south\n' >> "$dir/k.status"
  [ -z "$(status_decision_replacements "$dir/k.status")" ] \
    || fail "a keyed verbatim re-append announced: '$(status_decision_replacements "$dir/k.status")'"
  pass "a verbatim re-append stays silent in both default and keyed buckets"
}

test_silent_on_prose_mention_of_key() {
  local dir
  dir=$(case_dir prose-silent)
  printf 'needs-decision [key=red]: which shade\n' > "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  [ -z "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "a working line mentioning a key announced: '$(status_decision_replacements "$dir/t.status")'"
  printf 'needs-decision [key=q1]: real choice\n' > "$dir/c.status"
  printf 'resolved: docs still mention [key=q1]\n' >> "$dir/c.status"
  [ -z "$(status_decision_replacements "$dir/c.status")" ] \
    || fail "a resolved line quoting a key announced: '$(status_decision_replacements "$dir/c.status")'"
  pass "a prose mention of a key never announces"
}

test_marker_clears_when_survivor_closes() {
  local dir
  dir=$(case_dir close-clears)
  printf 'needs-decision: first\n' > "$dir/t.status"
  printf 'needs-decision: second\n' >> "$dir/t.status"
  [ -n "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "setup: the replacement did not announce before the close"
  printf 'resolved: went with second\n' >> "$dir/t.status"
  [ -z "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "a closed survivor still announces: '$(status_decision_replacements "$dir/t.status")'"
  [ -z "$(status_open_decisions "$dir/t.status")" ] \
    || fail "the close did not clear the open decision"
  pass "closing the survivor clears its replacement marker"
}

test_reopen_after_close_is_not_a_replacement() {
  local dir
  dir=$(case_dir reopen-clean)
  printf 'needs-decision [key=route]: north or south\n' > "$dir/t.status"
  printf 'resolved [key=route]: answered: north\n' >> "$dir/t.status"
  printf 'needs-decision [key=route]: south after all\n' >> "$dir/t.status"
  [ -z "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "a legitimate re-open after a close announced: '$(status_decision_replacements "$dir/t.status")'"
  pass "re-opening a key after its close is a new decision, not a replacement"
}

test_reserved_foreign_transition_announces_nothing() {
  local dir
  dir=$(case_dir reserved-silent)
  printf 'blocked [key=pending-reply-abcdef01]: pending-reply-missed: task=ios pending-reply-id=abcdef01 request=ship: go\n' > "$dir/t.status"
  printf 'blocked [key=pending-reply-abcdef01]: shipping is blocked on infra\n' >> "$dir/t.status"
  [ -z "$(status_decision_replacements "$dir/t.status")" ] \
    || fail "a foreign transition the fold ignores announced: '$(status_decision_replacements "$dir/t.status")'"
  pass "a foreign reserved-key transition the fold ignores announces nothing"
}

test_snapshot_scan_agrees_with_whole_file_scan() {
  local dir snapshot whole snap
  dir=$(case_dir snapshot-agrees)
  printf 'needs-decision: pick [key=api-shape] now please\n' > "$dir/state-a.status"
  printf 'needs-decision: pick [key=other-shape] now please\n' >> "$dir/state-a.status"
  whole=$(scan_decision_replacements "$dir")
  snapshot=$(status_presentation_snapshot "$dir")
  snap=$(scan_decision_replacements_snapshot "$dir" "$snapshot")
  [ "$snap" = "$whole" ] \
    || fail "the snapshot scan diverged from the whole-file scan: '$snap' vs '$whole'"
  pass "the snapshot-bounded scan agrees with the whole-file scan"
}

test_drain_announces_replacement_on_empty_queue_path() {
  local dir state out
  dir=$(make_case drain-announces)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: pick [key=api-shape] now please\n' > "$state/task1.status"
  printf 'needs-decision: pick [key=other-shape] now please\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a replaced decision"

  grep -F 'DECISION REPLACEMENTS' "$out" >/dev/null \
    || fail "a genuine replacement produced no DECISION REPLACEMENTS section"
  grep -F 'task1' "$out" | grep -F '[key=default]' | grep -F 'replaced unread: pick [key=api-shape] now please' >/dev/null \
    || fail "the announcement hid the task, key, or discarded note: $(cat "$out")"
  grep -F 'task1 [key=default] needs-decision: pick [key=other-shape] now please' "$out" >/dev/null \
    || fail "OPEN DECISIONS no longer shows the survivor: $(cat "$out")"
  pass "the drain announces the discarded note beside the surviving open decision"
}

test_drain_stays_silent_without_replacement() {
  local dir state out
  dir=$(make_case drain-silent)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a verbatim re-append"

  if grep -F 'DECISION REPLACEMENTS' "$out" >/dev/null; then
    fail "a verbatim re-append printed a DECISION REPLACEMENTS section: $(cat "$out")"
  fi
  grep -F 'task2 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "the open decision itself went missing: $(cat "$out")"
  pass "a verbatim re-append keeps the drain silent while the decision still surfaces"
}

test_fires_on_keyed_differing_replacement
test_fires_on_mid_note_default_replacement
test_fires_on_two_genuinely_unkeyed_decisions
test_silent_on_verbatim_reappend
test_silent_on_prose_mention_of_key
test_marker_clears_when_survivor_closes
test_reopen_after_close_is_not_a_replacement
test_reserved_foreign_transition_announces_nothing
test_snapshot_scan_agrees_with_whole_file_scan
test_drain_announces_replacement_on_empty_queue_path
test_drain_stays_silent_without_replacement
