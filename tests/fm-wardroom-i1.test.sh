#!/usr/bin/env bash
# I1: intake-channel grammar. Only proceed/revise/escalate/panel append; last
# decision ignores panel lines; no-file AND decision-free files mean no decision;
# revise count counts only revises.
# Mutation (LEDGER_MUTATE=1): assert an invalid-kind append SUCCEEDS - a correct
# validator refuses, so the assertion fails.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-i1)
S="$TMP/state"; mkdir -p "$S"

fm_intake_append "$S" t1 panel "lens none stub" || fail "panel append must succeed"
fm_intake_append "$S" t1 revise "needs a provable DoD" || fail "revise append must succeed"
fm_intake_append "$S" t1 panel "second panel line" || fail "second panel append must succeed"
fm_intake_append "$S" t1 proceed "vetted" || fail "proceed append must succeed"

f=$(fm_intake_file "$S" t1)
assert_present "$f" "intake file exists"
assert_grep "revise: needs a provable DoD" "$f" "revise line recorded verbatim"

# invalid kind refused. Mutation: assert the invalid append SUCCEEDS.
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  fm_intake_append "$S" t1 working nope 2>/dev/null \
    || fail "MUTATION: invalid kind expected to succeed"
else
  if fm_intake_append "$S" t1 working nope 2>/dev/null; then
    fail "invalid kind 'working' must be refused"
  fi
fi
assert_no_grep "nope" "$f" "invalid kind must not reach the file"

# last decision ignores panel lines, even trailing ones
last=$(fm_intake_last "$S" t1) || fail "last decision must resolve"
[ "$last" = proceed ] || fail "last decision must be proceed (got: $last)"
fm_intake_append "$S" t1 panel "trailing panel evidence"
last=$(fm_intake_last "$S" t1) || fail "last decision must still resolve"
[ "$last" = proceed ] || fail "trailing panel line must not change the decision (got: $last)"

# revise count; no-file and decision-free contracts
[ "$(fm_intake_revise_count "$S" t1)" = 1 ] || fail "revise count must be 1"
[ "$(fm_intake_revise_count "$S" ghost)" = 0 ] || fail "missing file must count 0"
fm_intake_last "$S" ghost >/dev/null 2>&1 && fail "no file must mean no decision"
fm_intake_append "$S" t3 panel "evidence only"
if out=$(fm_intake_last "$S" t3 2>/dev/null); then
  fail "panel-only file must mean no decision (got exit 0, output: '$out')"
fi

# require_proceed: proceed passes; revise-last refuses with banner; override passes
fm_intake_require_proceed "$S" t1 test-label || fail "proceed-last must pass require_proceed"
fm_intake_append "$S" t2 revise "not yet"
out=$(fm_intake_require_proceed "$S" t2 test-label 2>&1) && fail "revise-last must refuse"
assert_contains "$out" "WARDROOM" "refusal prints the Wardroom banner"
FM_INTAKE_OVERRIDE=1 fm_intake_require_proceed "$S" t2 test-label >/dev/null 2>&1 \
  || fail "FM_INTAKE_OVERRIDE=1 must bypass"

pass "I1 intake grammar"
