#!/usr/bin/env bash
# Q4: fm-verify core round-trip with stubbed seams. Reject -> verdict line
# "(attempt 1 of 3)" + relay message + exit 2. Approve -> approve line + exit 0.
# Non-ship kinds skip (exit 0, no verdict decision).
# Mutation (LEDGER_MUTATE=1): the "rejecting" stub emits approve - every
# reject-path assertion then fails on a correct implementation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q4)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

# crewmate fixture: repo + worktree on branch fm/q4task with one commit
REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q4task
printf 'change\n' > "$WT/work.txt"
git -C "$WT" add work.txt
git -C "$WT" commit -qm "crewmate change"

fm_write_meta "$S/q4task.meta" \
  "window=firstmate:fm-q4task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
mkdir -p "$D/q4task"
printf '# Task\nDo the thing.\n# Definition of done\nwork.txt exists.\n' > "$D/q4task/brief.md"

# stub seams
REJECT_WORD=reject
[ "${LEDGER_MUTATE:-}" = 1 ] && REJECT_WORD=approve
cat > "$TMP/verify-reject.sh" <<SH
#!/usr/bin/env bash
echo "I checked everything."
echo "VERDICT: $REJECT_WORD - tests do not actually pass"
SH
cat > "$TMP/verify-approve.sh" <<'SH'
#!/usr/bin/env bash
echo "Re-ran gates and DoD myself."
echo "VERDICT: approve - all claims reproduced"
SH
cat > "$TMP/relay.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/relay.log"
SH
chmod +x "$TMP"/verify-reject.sh "$TMP"/verify-approve.sh "$TMP"/relay.sh
export FM_LENS_CMD="echo stub-lens-review"

# 1. reject round-trip
out=$(FM_VERIFY_CMD="$TMP/verify-reject.sh" FM_RELAY_CMD="$TMP/relay.sh" \
      "$ROOT/bin/fm-verify.sh" q4task 2>&1); code=$?
expect_code 2 "$code" "reject must exit 2"
V=$(fm_verdict_file "$S" q4task)
assert_grep "lens: custom" "$V" "custom lens recorded"
assert_grep "reject: (attempt 1 of 3)" "$V" "reject recorded with attempt count"
assert_present "$TMP/relay.log" "relay invoked"
assert_grep "QUARTERDECK REJECTED" "$TMP/relay.log" "relay message names the reject"
assert_grep "fm-q4task" "$TMP/relay.log" "relay targets the crewmate window"
assert_present "$D/q4task/verify-report.md" "verifier report persisted"
assert_present "$D/q4task/lens-review.md" "lens review persisted"

# 2. approve after a fix
out=$(FM_VERIFY_CMD="$TMP/verify-approve.sh" FM_RELAY_CMD="$TMP/relay.sh" \
      "$ROOT/bin/fm-verify.sh" q4task 2>&1); code=$?
expect_code 0 "$code" "approve must exit 0"
last=$(fm_verdict_last "$S" q4task)
[ "$last" = approve ] || fail "last decision must be approve (got: $last)"

# 3. non-ship kinds skip
fm_write_meta "$S/q4scout.meta" \
  "window=firstmate:fm-q4scout" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=scout" "mode=local-only" "yolo=off"
out=$(FM_VERIFY_CMD="$TMP/verify-reject.sh" "$ROOT/bin/fm-verify.sh" q4scout 2>&1); code=$?
expect_code 0 "$code" "scout must skip with exit 0"
assert_contains "$out" "skip" "scout skip is announced"
fm_verdict_last "$S" q4scout >/dev/null 2>&1 && fail "scout must record no decision"

pass "Q4 fm-verify reject round-trip"
