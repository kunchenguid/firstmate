#!/usr/bin/env bash
# Q1: verdict-file grammar. Only approve/reject/escalate/lens append; last
# decision ignores lens lines; reject count counts only rejects.
# Mutation (LEDGER_MUTATE=1): append with kind "working" (invalid) and expect
# it to SUCCEED — a correct validator refuses, so the assertion fails, proving
# the test is keyed to real validation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q1)
S="$TMP/state"; mkdir -p "$S"

# valid kinds append, in order
fm_verdict_append "$S" t1 lens "none stub" || fail "lens append must succeed"
fm_verdict_append "$S" t1 reject "first miss" || fail "reject append must succeed"
fm_verdict_append "$S" t1 lens "codex stub" || fail "second lens append must succeed"
fm_verdict_append "$S" t1 approve "verified" || fail "approve append must succeed"

f=$(fm_verdict_file "$S" t1)
assert_present "$f" "verdict file exists"
assert_grep "reject: first miss" "$f" "reject line recorded verbatim"

# invalid kind refused. Mutation (LEDGER_MUTATE=1): assert the invalid append
# SUCCEEDS - a correct validator refuses it, so the assertion fails, proving
# the test is keyed to real validation.
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  fm_verdict_append "$S" t1 working nope 2>/dev/null \
    || fail "MUTATION: invalid kind expected to succeed"
else
  if fm_verdict_append "$S" t1 working nope 2>/dev/null; then
    fail "invalid kind 'working' must be refused"
  fi
fi
assert_no_grep "nope" "$f" "invalid kind must not reach the file"

# last decision ignores lens lines
last=$(fm_verdict_last "$S" t1) || fail "last decision must resolve"
[ "$last" = approve ] || fail "last decision must be approve (got: $last)"
fm_verdict_append "$S" t1 lens "trailing lens evidence"
last=$(fm_verdict_last "$S" t1) || fail "last decision must still resolve"
[ "$last" = approve ] || fail "trailing lens line must not change the decision (got: $last)"

# reject count counts only rejects; missing file counts 0
[ "$(fm_verdict_reject_count "$S" t1)" = 1 ] || fail "reject count must be 1"
[ "$(fm_verdict_reject_count "$S" ghost)" = 0 ] || fail "missing file must count 0"
fm_verdict_last "$S" ghost >/dev/null 2>&1 && fail "no file must mean no decision"

# file exists but holds only lens evidence -> still no decision (exit 1, no output)
fm_verdict_append "$S" t3 lens "evidence only"
if out=$(fm_verdict_last "$S" t3 2>/dev/null); then
  fail "lens-only file must mean no decision (got exit 0, output: '$out')"
fi

# require_approve: approve passes, reject-last refuses with banner, override passes
fm_verdict_require_approve "$S" t1 test-label || fail "approve-last must pass require_approve"
fm_verdict_append "$S" t2 reject "not yet"
out=$(fm_verdict_require_approve "$S" t2 test-label 2>&1) && fail "reject-last must refuse"
assert_contains "$out" "QUARTERDECK" "refusal prints the Quarterdeck banner"
FM_VERIFY_OVERRIDE=1 fm_verdict_require_approve "$S" t2 test-label >/dev/null 2>&1 \
  || fail "FM_VERIFY_OVERRIDE=1 must bypass"

pass "Q1 verdict grammar"
