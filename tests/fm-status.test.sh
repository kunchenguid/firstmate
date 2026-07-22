#!/usr/bin/env bash
# Behavior tests for the timestamped Firstmate status-event writer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status)
HOME_DIR="$TMP_ROOT/home with space"
mkdir -p "$HOME_DIR/state"
STATUS="$ROOT/bin/fm-status.sh"

FM_HOME="$HOME_DIR" FM_STATUS_NOW=2026-01-02T03:04:05Z \
  FM_RUN_ID=task-a-20260102T030000Z-42 FM_SESSION_ID=task-a-20260102T030000Z-42-s1 \
  "$STATUS" task-a needs-decision --key api-shape -- "choose the API shape" \
  || fail "status writer rejected a valid keyed event"
expected='needs-decision [key=api-shape]: choose the API shape [at=2026-01-02T03:04:05Z] [run=task-a-20260102T030000Z-42] [session=task-a-20260102T030000Z-42-s1]'
actual=$(cat "$HOME_DIR/state/task-a.status")
[ "$actual" = "$expected" ] || fail "status writer output mismatch: $actual"
pass "fm-status: appends UTC task/run/session correlation without changing the status verb"

PARENT_STATUS="$TMP_ROOT/parent state/domain.status"
FM_STATUS_NOW=2026-01-02T03:05:05Z FM_RUN_ID=domain-run FM_SESSION_ID=domain-session \
  "$STATUS" --file "$PARENT_STATUS" "done" --corr abcdef0123456789 -- "report ready" \
  || fail "status writer rejected an explicit parent route"
assert_grep 'done [corr=abcdef0123456789]: report ready [at=2026-01-02T03:05:05Z] [run=domain-run] [session=domain-session]' "$PARENT_STATUS" \
  "explicit parent status route lost correlation"
pass "fm-status: explicit secondmate parent routes retain corr and run correlation"

set +e
FM_HOME="$HOME_DIR" "$STATUS" task-a "done" $'two\nlines' >/dev/null 2>&1
rc=$?
set -e
expect_code 2 "$rc" "multiline status notes must be rejected"
lines=$(wc -l < "$HOME_DIR/state/task-a.status" | tr -d '[:space:]')
[ "$lines" = 1 ] || fail "rejected multiline note changed the status stream"
pass "fm-status: rejects multiline content before writing"

set +e
"$STATUS" --file relative.status "done" note >/dev/null 2>&1
rc=$?
set -e
expect_code 2 "$rc" "relative --file status path must be rejected"
pass "fm-status: parent route must be an absolute status path"

echo "# all fm-status tests passed"
