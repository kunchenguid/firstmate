#!/usr/bin/env bash
# Q6: lens degrade chain. With no custom lens, no Fugu key, and codex absent
# from PATH, the lens degrades to none LOUDLY (warning on stderr + 'lens: none'
# in the verdict file) and verification still completes.
# Mutation (LEDGER_MUTATE=1): a fake codex is planted on PATH - a correct chain
# then records 'lens: codex', failing the 'lens: none' assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q6)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q6task
fm_write_meta "$S/q6task.meta" \
  "window=firstmate:fm-q6task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
mkdir -p "$D/q6task"

cat > "$TMP/verify-approve.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: approve - fine"
SH
chmod +x "$TMP/verify-approve.sh"

# a bare PATH that keeps core tools but has no codex (mutation plants one)
FB=$(fm_fakebin "$TMP")
for t in git grep sed head tail cut mktemp cat tr sh dirname basename; do
  p=$(command -v "$t") && ln -sf "$p" "$FB/$t"
done
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  cat > "$FB/codex" <<'SH'
#!/usr/bin/env bash
echo "fake codex lens review"
SH
  chmod +x "$FB/codex"
fi

out=$(env -i HOME="$HOME" PATH="$FB:/usr/bin:/bin" \
      FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D" \
      FM_VERIFY_CMD="$TMP/verify-approve.sh" \
      "$ROOT/bin/fm-verify.sh" q6task 2>&1); code=$?
expect_code 0 "$code" "verify must complete despite lens degrade"
assert_contains "$out" "degraded to none" "degradation is announced, never silent"
V=$(fm_verdict_file "$S" q6task)
assert_grep "lens: none" "$V" "lens: none recorded"
[ "$(fm_verdict_last "$S" q6task)" = approve ] || fail "verifier verdict still recorded"

pass "Q6 lens degrade"
