#!/usr/bin/env bash
# Behavior tests for exclusive Linear writer assignments and role briefs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-linear-ticket-writer)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOME_DIR="$TMP_ROOT/home"
OWNER_TASK=han-28-owner
PLANNER_TASK=han-28-plan
URL=https://linear.app/hanzireader/issue/HAN-28/make-m14-the-default-and-first-cameraonboarding-profile
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$OWNER_TASK" "$HOME_DIR/data/$PLANNER_TASK"
printf '# Owner task\n' > "$HOME_DIR/data/$OWNER_TASK/brief.md"
printf '# Planner task\n' > "$HOME_DIR/data/$PLANNER_TASK/brief.md"
trap fm_test_cleanup EXIT

writer() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-ticket-writer.sh" "$@"; }

out=$(writer assign issue-immutable-id HAN-28 "$URL" "$OWNER_TASK" luna-han-28)
assert_contains "$out" "assigned: issue=HAN-28 task=$OWNER_TASK writer=luna-han-28" \
  "assignment records the ticket, task, and sole writer"
lease="$HOME_DIR/state/linear-ticket-writers/HAN-28.lease"
assert_grep 'issue=HAN-28' "$lease" "lease omitted the assigned issue"
assert_grep "task=$OWNER_TASK" "$lease" "lease omitted the Firstmate task"
assert_grep 'writer=luna-han-28' "$lease" "lease omitted the writer"
pass "one durable Linear writer assignment is created"

out=$(writer assign issue-immutable-id HAN-28 "$URL" "$OWNER_TASK" luna-han-28)
assert_contains "$out" "already-assigned" "an exact replay is idempotent"
set +e
out=$(writer assign issue-immutable-id HAN-28 "$URL" duplicate-task luna-duplicate 2>&1)
status=$?
set -e
expect_code 1 "$status" "a duplicate task and writer must be refused"
assert_contains "$out" "already has a different writer or task assignment" \
  "duplicate ownership refusal is explicit"
pass "repeated dispatch cannot create a second local owner"

writer assert-writer HAN-28 "$OWNER_TASK" luna-han-28 >/dev/null \
  || fail "assigned Luna writer was not authorized"
set +e
writer assert-writer HAN-28 "$PLANNER_TASK" sol-han-28 >/dev/null 2>&1
status=$?
set -e
expect_code 1 "$status" "Sol must not acquire Linear write authority"
set +e
out=$(writer assert-target HAN-28 "$OWNER_TASK" luna-han-28 HAN-27 2>&1)
status=$?
set -e
expect_code 1 "$status" "the HAN-28 writer must not target another issue"
assert_contains "$out" "may not update HAN-27" "cross-ticket denial names the forbidden target"
pass "only the assigned writer and assigned ticket pass the writer guard"

writer owner-brief HAN-28 "$OWNER_TASK" luna-han-28 >/dev/null
owner_brief="$HOME_DIR/data/$OWNER_TASK/brief.md"
assert_grep 'You are the sole Linear writer for HAN-28.' "$owner_brief" \
  "owner brief omitted exclusive writer authority"
assert_grep 'You may update only HAN-28.' "$owner_brief" \
  "owner brief omitted ticket scope"
# shellcheck disable=SC2016 # Backticks are literal Markdown in the generated brief.
assert_grep 'Create or update exactly one `## Firstmate Workpad` on HAN-28.' "$owner_brief" \
  "owner brief omitted the single Workpad rule"
assert_grep "Do not modify Firstmate's local backlog directly." "$owner_brief" \
  "owner brief omitted Firstmate backlog ownership"
assert_grep 'Do not mark the ticket Done until its PR is verified merged.' "$owner_brief" \
  "owner brief omitted merge verification"
writer planner-brief HAN-28 "$PLANNER_TASK" >/dev/null
planner_brief="$HOME_DIR/data/$PLANNER_TASK/brief.md"
assert_grep 'You are planning or reviewing HAN-28, but you hold no Linear write authority.' "$planner_brief" \
  "Sol brief omitted the no-write role"
assert_grep 'Do not create comments, edit the Workpad, change status, change assignment, or perform any other Linear mutation.' \
  "$planner_brief" "Sol brief omitted the mutation prohibition"
pass "generated Luna and Sol briefs carry opposite Linear authority contracts"

out=$(writer transfer HAN-28 luna-han-28 luna-han-28-replacement)
assert_contains "$out" "transferred: issue=HAN-28 task=$OWNER_TASK writer=luna-han-28-replacement generation=2" \
  "writer transfer reports the replacement and generation"
assert_grep 'writer=luna-han-28-replacement' "$lease" "current lease did not move to replacement writer"
writer owner-brief HAN-28 "$OWNER_TASK" luna-han-28-replacement >/dev/null
[ "$(grep -c '^# Linear ticket ownership$' "$owner_brief")" -eq 1 ] \
  || fail "writer transfer duplicated the owner brief"
assert_grep "assert-target HAN-28 $OWNER_TASK luna-han-28-replacement <target-identifier>" "$owner_brief" \
  "replacement owner brief retained stale writer authority"
history="$HOME_DIR/state/linear-ticket-writers/HAN-28.history"
[ "$(grep -c $'\tassign\t' "$history")" -eq 1 ] || fail "history did not retain exactly one assignment"
[ "$(grep -c $'\ttransfer\t' "$history")" -eq 1 ] || fail "history did not retain exactly one transfer"
set +e
writer transfer HAN-28 luna-han-28 another-writer >/dev/null 2>&1
status=$?
set -e
expect_code 1 "$status" "a stale writer cannot transfer the lease"
pass "writer replacement is explicit, generation-bound, and durable"

printf 'ok: Linear ticket writer behavior tests passed\n'
