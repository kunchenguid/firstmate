#!/usr/bin/env bash
# Q3: the PR-poll hard gate. fm-pr-check must refuse to arm state/<id>.check.sh
# (the watcher's merge poll) without a trailing approve verdict.
# Mutation (LEDGER_MUTATE=1): with a trailing reject the test asserts arming
# SUCCEEDS - a correct gate refuses, failing the test.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q3)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
URL="https://github.com/example/repo/pull/1"

fm_write_meta "$S/q3task.meta" \
  "window=firstmate:fm-q3task" "worktree=$TMP/wt" "project=$TMP/proj" \
  "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"

# 1. no verdict -> refuse, nothing armed, no pr= recorded
out=$("$ROOT/bin/fm-pr-check.sh" q3task "$URL" 2>&1); code=$?
expect_code 1 "$code" "arming without a verdict must refuse"
assert_contains "$out" "QUARTERDECK" "refusal shows the banner"
assert_absent "$S/q3task.check.sh" "check script must not be armed"
assert_no_grep "pr=$URL" "$S/q3task.meta" "pr url must not be recorded on refusal"

# 2. trailing reject -> refuse (mutation expects success)
fm_verdict_append "$S" q3task reject "not proven"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  "$ROOT/bin/fm-pr-check.sh" q3task "$URL" >/dev/null 2>&1 \
    || fail "MUTATION: arming over reject expected to succeed"
else
  out=$("$ROOT/bin/fm-pr-check.sh" q3task "$URL" 2>&1); code=$?
  expect_code 1 "$code" "arming with trailing reject must refuse"
  assert_absent "$S/q3task.check.sh" "check script still must not exist"
fi

# 3. approve -> arms
fm_verdict_append "$S" q3task approve "verified"
out=$("$ROOT/bin/fm-pr-check.sh" q3task "$URL" 2>&1) || fail "arming with approve must succeed: $out"
assert_present "$S/q3task.check.sh" "check script armed"
assert_grep "pr=$URL" "$S/q3task.meta" "pr url recorded"

pass "Q3 pr-check hard gate"
