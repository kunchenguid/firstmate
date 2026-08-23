#!/usr/bin/env bash
# tests/fm-decision-tier.test.sh - behavior tests for bin/fm-decision-tier.sh,
# the CLI over bin/fm-decision-tier-lib.sh. Runs the real executable as a
# subprocess against a private temp log; --now pins the clock so every
# assertion is deterministic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-decision-tier.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-tier-cli)
LOG="$TMP_ROOT/decisions.log"

# --- classify / categories ---------------------------------------------------

OUT=$("$CLI" classify merge) || fail "classify merge should exit 0"
[ "$OUT" = "hard-stop" ] || fail "classify merge should print hard-stop, got $OUT"
pass "CLI classify prints the tier for a known category"

OUT=$("$CLI" classify some-brand-new-category-nobody-registered) || fail "classify on an unknown category should still exit 0"
[ "$OUT" = "hard-stop" ] || fail "classify on an unknown category should fail closed to hard-stop, got $OUT"
pass "CLI classify fails closed to hard-stop for an unrecognized category"

OUT=$("$CLI" categories auto) || fail "categories auto should exit 0"
echo "$OUT" | grep -qx "precedent-match" || fail "categories auto should list precedent-match, got: $OUT"
echo "$OUT" | grep -qx "merge" && fail "categories auto must not list a hard-stop category"
pass "CLI categories filters to one tier's vocabulary"

OUT=$("$CLI" categories) || fail "categories with no tier should exit 0"
echo "$OUT" | grep -qx "$(printf 'merge\thard-stop')" || fail "categories with no arg should print <category>\\t<tier> pairs, got: $OUT"
pass "CLI categories with no tier prints every category paired with its tier"

if "$CLI" categories not-a-real-tier >/dev/null 2>&1; then
  fail "categories with an unknown tier name must be refused"
fi
pass "CLI categories refuses an unrecognized tier name"

# --- auto / hard-stop refuse a mis-tiered category --------------------------

if "$CLI" auto --now 1000 "$LOG" dec-1 merge "note" 2>/dev/null; then
  fail "CLI auto must refuse a hard-stop category"
fi
[ ! -s "$LOG" ] || fail "a refused CLI auto call must not write to the log"
pass "CLI auto refuses to log a hard-stop category as auto"

if "$CLI" hard-stop --now 1000 "$LOG" dec-1 precedent-match "note" 2>/dev/null; then
  fail "CLI hard-stop must refuse an auto category"
fi
[ ! -s "$LOG" ] || fail "a refused CLI hard-stop call must not write to the log"
pass "CLI hard-stop refuses to log an auto category as hard-stop"

# --- the default-with-veto lifecycle, end to end through the CLI ------------

"$CLI" auto --now 1000 "$LOG" dec-auto-1 precedent-match "matched an existing ruling" \
  || fail "CLI auto should succeed for an auto category"

"$CLI" hard-stop --now 1000 "$LOG" dec-hard-1 merge "attempted merge, escalated" \
  || fail "CLI hard-stop should succeed for a hard-stop category"

"$CLI" open --now 1000 "$LOG" dec-veto-1 two-option-tradeoff 300 "prefer option A" "apply option A" \
  || fail "CLI open should succeed for a default-veto category"

STATUS=$("$CLI" status --now 1100 "$LOG" dec-veto-1) || fail "CLI status should exit 0 while pending"
[ "$STATUS" = "pending" ] || fail "CLI status should read pending inside the window, got $STATUS"
pass "CLI open followed by status inside the window reads pending"

STATUS=$("$CLI" status --now 5000 "$LOG" dec-veto-1) || fail "CLI status should exit 0 once expired"
[ "$STATUS" = "expired" ] || fail "CLI status should read expired once the window elapses, got $STATUS"
pass "CLI status transitions to expired once the stated window elapses with no veto - it expires into action"

if "$CLI" veto --now 5000 "$LOG" dec-veto-1 "too late" 2>/dev/null; then
  fail "CLI veto must refuse once the decision has already expired"
fi
pass "CLI veto refuses once the window has already expired"

"$CLI" open --now 1000 "$LOG" dec-veto-2 process-default 300 "prefer the routine default" "apply the routine default" \
  || fail "CLI open should succeed for the veto-in-time scenario"
"$CLI" veto --now 1100 "$LOG" dec-veto-2 "captain overrides the default" \
  || fail "CLI veto should succeed while still pending"
STATUS=$("$CLI" status --now 5000 "$LOG" dec-veto-2) || fail "CLI status should exit 0 after a veto"
[ "$STATUS" = "vetoed" ] || fail "CLI status should read vetoed and stay vetoed, got $STATUS"
pass "CLI veto inside the window sticks even when checked long after the original window would have elapsed"

# --- report --------------------------------------------------------------

REPORT=$("$CLI" report --now 5000 "$LOG") || fail "CLI report should exit 0"
echo "$REPORT" | grep -qx "escalation_count=1" || fail "CLI report should show escalation_count=1 (only dec-hard-1 escalated), got: $REPORT"
echo "$REPORT" | grep -qx "auto=1" || fail "CLI report should show auto=1, got: $REPORT"
echo "$REPORT" | grep -qx "default_expired=1" || fail "CLI report should show default_expired=1 (dec-veto-1), got: $REPORT"
echo "$REPORT" | grep -qx "default_vetoed=1" || fail "CLI report should show default_vetoed=1 (dec-veto-2), got: $REPORT"
echo "$REPORT" | grep -qx "total=4" || fail "CLI report should show total=4, got: $REPORT"
pass "CLI report renders a measurable escalation_count and per-tier breakdown over the whole log"

# --- usage / malformed input --------------------------------------------------

if "$CLI" >/dev/null 2>&1; then
  fail "invoking the CLI with no subcommand must not exit 0"
fi
pass "CLI with no subcommand exits nonzero and prints usage"

if "$CLI" open --now not-a-number "$LOG" dec-x process-default 300 "r" "d" 2>/dev/null; then
  fail "CLI must refuse a non-numeric --now"
fi
pass "CLI refuses a non-numeric --now epoch"

echo "# fm-decision-tier.test.sh: all assertions passed"
