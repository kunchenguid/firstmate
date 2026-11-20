#!/usr/bin/env bash
# tests/fm-transition-lib.test.sh - unit tests for the shared, backend-neutral
# normalized-transition shape and the single-owner status->action policy table
# (bin/fm-transition-lib.sh). Pure functions, no backend required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-transition-lib.sh"

# --- record construction + accessors ----------------------------------------

REC=$(fm_transition_record "wG:pQ" "wG" "" "blocked" "claude" "permission: Allow Bash")
[ "$(fm_transition_pane_id "$REC")" = "wG:pQ" ] || fail "pane_id accessor wrong: $REC"
[ "$(fm_transition_workspace_id "$REC")" = "wG" ] || fail "workspace_id accessor wrong: $REC"
[ "$(fm_transition_from_status "$REC")" = "" ] || fail "from_status should be empty: $REC"
[ "$(fm_transition_to_status "$REC")" = "blocked" ] || fail "to_status accessor wrong: $REC"
[ "$(fm_transition_agent "$REC")" = "claude" ] || fail "agent accessor wrong: $REC"
[ "$(fm_transition_detail "$REC")" = "permission: Allow Bash" ] || fail "detail accessor wrong: $REC"
pass "fm_transition_record builds a 6-field record and every accessor reads its field"

# The record is exactly TAB-separated (six fields, five tabs).
TABS=$(printf '%s' "$REC" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$TABS" = "5" ] || fail "record must have exactly 5 TAB separators, got $TABS"
pass "fm_transition_record uses a single TAB between each of the six fields"

# A field containing a stray TAB/newline is scrubbed to spaces so the record
# never desyncs into more than five fields.
DIRTY=$(fm_transition_record "wG:pQ" "wG" "" "blocked" $'multi\tline\nagent' $'a\tmessage\r\nfrom a program')
DIRTY_TABS=$(printf '%s' "$DIRTY" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$DIRTY_TABS" = "5" ] || fail "a field with a stray TAB must not add columns, got $DIRTY_TABS tabs"
[ "$(fm_transition_to_status "$DIRTY")" = "blocked" ] || fail "stray-field scrub desynced to_status: $DIRTY"
[ "$(fm_transition_detail "$DIRTY")" = "a message  from a program" ] || fail "stray-field scrub desynced detail: $DIRTY"
pass "fm_transition_record scrubs TAB/newline out of fields so the record stays exactly six columns"

# Empty optional fields are allowed (herdr leaves workspace/agent empty on the
# reconcile path).
REC2=$(fm_transition_record "w1:p3" "" "" "working" "")
[ "$(fm_transition_pane_id "$REC2")" = "w1:p3" ] || fail "pane_id wrong with empty optionals: $REC2"
[ "$(fm_transition_to_status "$REC2")" = "working" ] || fail "to_status wrong with empty optionals: $REC2"
[ "$(fm_transition_detail "$REC2")" = "" ] || fail "an omitted detail must read empty: $REC2"
pass "fm_transition_record tolerates empty workspace/from/agent/detail fields"

# --- the single-owner policy table ------------------------------------------

[ "$(fm_transition_policy blocked)" = "actionable" ] || fail "blocked must be actionable"
[ "$(fm_transition_policy working)" = "absorb" ] || fail "working must be absorb"
[ "$(fm_transition_policy idle)" = "defer" ] || fail "idle must be defer"
[ "$(fm_transition_policy "done")" = "defer" ] || fail "done must be defer"
[ "$(fm_transition_policy gone)" = "rescan" ] || fail "gone must be rescan"
[ "$(fm_transition_policy unknown)" = "fallback" ] || fail "unknown must be fallback"
[ "$(fm_transition_policy "")" = "fallback" ] || fail "empty status must be fallback"
[ "$(fm_transition_policy some-future-status)" = "fallback" ] || fail "an unrecognized status must be fallback"
pass "fm_transition_policy is the single-owner status->action table (blocked=actionable, working=absorb, idle/done=defer, gone=rescan, else=fallback)"

# --- the shared per-pane dedupe ----------------------------------------------

DEDUPE=$(fm_test_tmproot fm-transition-dedupe)
MARK="$DEDUPE/.x-escalated-s1_p2"
[ "$(fm_transition_marker "$DEDUPE" .x-escalated- s1:p2)" = "$MARK" ] || fail "marker path must key the window like .stale-<key>"
BLOCKED=$(fm_transition_record p2 "" "" blocked agent "question: Continue?")
HIT=$(fm_transition_apply "$DEDUPE" .x-escalated- s1 "$BLOCKED") || fail "a fresh blocked edge must be a hit"
[ "$HIT" = "$BLOCKED" ] || fail "a hit must print the record unchanged: $HIT"
[ ! -e "$MARK" ] || fail "apply must not commit the marker; the caller commits after handling"
fm_transition_commit "$DEDUPE" .x-escalated- s1 "$BLOCKED" || fail "commit failed"
[ -e "$MARK" ] || fail "commit must write the marker"
OUT=$(fm_transition_apply "$DEDUPE" .x-escalated- s1 "$BLOCKED") && fail "an already-escalated blocked edge must not hit again"
[ -z "$OUT" ] || fail "a deduped edge must print nothing"
[ ! -e "$DEDUPE/.y-escalated-s1_p2" ] || fail "another backend's prefix must not share the marker"
fm_transition_apply "$DEDUPE" .x-escalated- s1 "$(fm_transition_record p2 "" "" working agent)" && fail "working is never a hit"
[ ! -e "$MARK" ] || fail "a working edge must clear the marker"
fm_transition_apply "$DEDUPE" .x-escalated- s1 "$BLOCKED" >/dev/null || fail "a blocked edge after working must hit again"
fm_transition_commit "$DEDUPE" .x-escalated- s1 "$BLOCKED"
fm_transition_clear "$DEDUPE" .x-escalated- s1:p2
[ ! -e "$MARK" ] || fail "clear must remove the window's marker"
RC=0; fm_transition_apply "$DEDUPE" .x-escalated- s1 "$(fm_transition_record p2 "" "" gone "" "block closed")" || RC=$?
[ "$RC" = 3 ] || fail "a gone edge must return 3 (rescan), got $RC"
RC=0; fm_transition_apply "$DEDUPE" .x-escalated- s1 "$(fm_transition_record p2 "" "" idle agent)" || RC=$?
[ "$RC" = 1 ] || fail "an idle edge must return 1, got $RC"
pass "fm_transition_apply/_commit/_clear: one hit per blocked edge, cleared by working or cleanup, prefix-scoped, gone rescans"

echo "# fm-transition-lib.test.sh: all assertions passed"
