#!/usr/bin/env bash
# Q7: fail closed. A verifier that crashes (non-zero exit) or produces no
# VERDICT line must yield escalate + exit 3 - never an approve.
# Mutation (LEDGER_MUTATE=1): the "crashing" stub instead prints a valid
# approve and exits 0 - a correct implementation then approves, failing the
# escalate assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q7)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q7task
mkdir -p "$D/q7task"
export FM_LENS_CMD="echo stub-lens"

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  cat > "$TMP/verify-crash.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: approve - mutation"
SH
else
  cat > "$TMP/verify-crash.sh" <<'SH'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
SH
fi
cat > "$TMP/verify-mute.sh" <<'SH'
#!/usr/bin/env bash
echo "I have thoughts but no verdict."
SH
chmod +x "$TMP/verify-crash.sh" "$TMP/verify-mute.sh"

# 1. crashing verifier -> escalate
fm_write_meta "$S/q7task.meta" \
  "window=firstmate:fm-q7task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
FM_VERIFY_CMD="$TMP/verify-crash.sh" "$ROOT/bin/fm-verify.sh" q7task >/dev/null 2>&1; code=$?
expect_code 3 "$code" "crashing verifier must exit 3"
V=$(fm_verdict_file "$S" q7task)
assert_grep "escalate: verifier infrastructure failure" "$V" "infra failure recorded as escalate"
assert_no_grep "approve:" "$V" "no approve may appear on infra failure"

# 2. verdict-less verifier -> escalate
fm_write_meta "$S/q7b.meta" \
  "window=firstmate:fm-q7b" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
FM_VERIFY_CMD="$TMP/verify-mute.sh" "$ROOT/bin/fm-verify.sh" q7b >/dev/null 2>&1; code=$?
expect_code 3 "$code" "verdict-less verifier must exit 3"
assert_grep "escalate: verifier infrastructure failure" "$(fm_verdict_file "$S" q7b)" "mute verifier escalates"

pass "Q7 fail closed"
