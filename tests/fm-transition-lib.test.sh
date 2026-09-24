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

# A field containing a stray TAB/newline is scrubbed to spaces so the record
# never desyncs into more than five fields.
DIRTY=$(fm_transition_record "wG:pQ" "wG" "" "blocked" $'multi\tline\nagent')
DIRTY_TABS=$(printf '%s' "$DIRTY" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$DIRTY_TABS" = "4" ] || fail "a field with a stray TAB must not add columns, got $DIRTY_TABS tabs"
[ "$(fm_transition_to_status "$DIRTY")" = "blocked" ] || fail "stray-field scrub desynced to_status: $DIRTY"
pass "fm_transition_record scrubs TAB/newline out of fields so the record stays exactly five columns"

# --- the single-owner policy table ------------------------------------------

[ "$(fm_transition_policy blocked)" = "actionable" ] || fail "blocked must be actionable"
[ "$(fm_transition_policy working)" = "absorb" ] || fail "working must be absorb"
[ "$(fm_transition_policy idle)" = "defer" ] || fail "idle must be defer"
[ "$(fm_transition_policy "done")" = "defer" ] || fail "done must be defer"
[ "$(fm_transition_policy unknown)" = "fallback" ] || fail "unknown must be fallback"
[ "$(fm_transition_policy "")" = "fallback" ] || fail "empty status must be fallback"
[ "$(fm_transition_policy some-future-status)" = "fallback" ] || fail "an unrecognized status must be fallback"
pass "fm_transition_policy is the single-owner status->action table (blocked=actionable, working=absorb, idle/done=defer, else=fallback)"

echo "# fm-transition-lib.test.sh: all assertions passed"
