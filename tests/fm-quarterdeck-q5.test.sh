#!/usr/bin/env bash
# Q5: the attempt cap. Reject #3 escalates (no infinite fix loop); a task
# already at the cap escalates without even invoking the verifier.
# Mutation (LEDGER_MUTATE=1): seed only ONE prior reject - a correct cap then
# does NOT escalate on the next reject, failing the escalate assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q5)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q5task
fm_write_meta "$S/q5task.meta" \
  "window=firstmate:fm-q5task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
mkdir -p "$D/q5task"

cat > "$TMP/verify-reject.sh" <<SH
#!/usr/bin/env bash
touch "$TMP/verifier-ran"
echo "VERDICT: reject - still broken"
SH
cat > "$TMP/relay.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/relay.log"
SH
chmod +x "$TMP/verify-reject.sh" "$TMP/relay.sh"
export FM_LENS_CMD="echo stub-lens" FM_VERIFY_CMD="$TMP/verify-reject.sh" FM_RELAY_CMD="$TMP/relay.sh"

# seed prior rejects (mutation seeds fewer so the cap correctly does not fire)
fm_verdict_append "$S" q5task reject "(attempt 1 of 3) seeded"
[ "${LEDGER_MUTATE:-}" = 1 ] || fm_verdict_append "$S" q5task reject "(attempt 2 of 3) seeded"

# next reject is the third -> reject AND escalate, exit 3
"$ROOT/bin/fm-verify.sh" q5task >/dev/null 2>&1; code=$?
V=$(fm_verdict_file "$S" q5task)
expect_code 3 "$code" "third reject must exit 3 (escalate)"
assert_grep "reject: (attempt 3 of 3)" "$V" "third reject line recorded before the escalate"
assert_grep "escalate: attempt cap reached" "$V" "escalate line recorded at the cap"
[ "$(fm_verdict_last "$S" q5task)" = escalate ] || fail "last decision must be escalate"

# already at the cap -> immediate escalate, verifier never invoked
rm -f "$TMP/verifier-ran"
fm_write_meta "$S/q5b.meta" \
  "window=firstmate:fm-q5b" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
fm_verdict_append "$S" q5b reject "1"; fm_verdict_append "$S" q5b reject "2"; fm_verdict_append "$S" q5b reject "3"
"$ROOT/bin/fm-verify.sh" q5b >/dev/null 2>&1; code=$?
expect_code 3 "$code" "at-cap task must escalate immediately"
assert_absent "$TMP/verifier-ran" "verifier must not run for an at-cap task"
assert_grep "escalate: attempt cap reached" "$(fm_verdict_file "$S" q5b)" "at-cap escalate recorded"

pass "Q5 attempt cap"
