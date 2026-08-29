#!/usr/bin/env bash
# Q2: the merge hard gate. fm-merge-local must refuse a task whose verdict file
# is missing or whose last decision is not approve, must merge on approve, and
# must honor the loud FM_VERIFY_OVERRIDE=1 captain bypass.
# Mutation (LEDGER_MUTATE=1): with the last verdict a reject, the test asserts
# the merge SUCCEEDS - a correct gate refuses, failing the test.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q2)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
fm_git_identity

REPO="$TMP/proj"
fm_git_init_commit "$REPO"
DEF=$(git -C "$REPO" symbolic-ref --short HEAD)
git -C "$REPO" checkout -q -b fm/q2task
printf 'x\n' > "$REPO/x.txt"
git -C "$REPO" add x.txt
git -C "$REPO" commit -qm change
git -C "$REPO" checkout -q "$DEF"

fm_write_meta "$S/q2task.meta" \
  "window=firstmate:fm-q2task" "worktree=$TMP/wt" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"

# 1. no verdict file -> refuse with banner
out=$("$ROOT/bin/fm-merge-local.sh" q2task 2>&1); code=$?
expect_code 1 "$code" "merge without any verdict must refuse"
assert_contains "$out" "QUARTERDECK" "refusal shows the Quarterdeck banner"

# 2. trailing reject -> refuse (mutation expects success here)
fm_verdict_append "$S" q2task lens "none stub"
fm_verdict_append "$S" q2task reject "not proven"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  "$ROOT/bin/fm-merge-local.sh" q2task >/dev/null 2>&1 \
    || fail "MUTATION: merge over trailing reject expected to succeed"
else
  out=$("$ROOT/bin/fm-merge-local.sh" q2task 2>&1); code=$?
  expect_code 1 "$code" "merge with trailing reject must refuse"
fi

# 3. override bypasses loudly even over a reject
out=$(FM_VERIFY_OVERRIDE=1 "$ROOT/bin/fm-merge-local.sh" q2task 2>&1) \
  || fail "override merge must succeed: $out"
assert_contains "$out" "OVERRIDE" "override prints the warning banner"
assert_contains "$out" "merged fm/q2task" "override actually merged"

# 4. approve merges cleanly (fresh branch so there is something to merge)
git -C "$REPO" checkout -q -b fm/q2b
printf 'y\n' > "$REPO/y.txt"
git -C "$REPO" add y.txt
git -C "$REPO" commit -qm change2
git -C "$REPO" checkout -q "$DEF"
fm_write_meta "$S/q2b.meta" \
  "window=firstmate:fm-q2b" "worktree=$TMP/wt" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
fm_verdict_append "$S" q2b approve "verified"
out=$("$ROOT/bin/fm-merge-local.sh" q2b 2>&1) || fail "merge with approve must succeed: $out"
assert_contains "$out" "merged fm/q2b" "approve merge output"

pass "Q2 merge hard gate"
