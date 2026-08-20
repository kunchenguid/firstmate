#!/usr/bin/env bash
# Characterization tests for the network-free dry-run path of fm-x-dismiss.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-x-dismiss)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
REQ_ID='mention.with-safe-chars-7'

mkdir -p "$STATE_DIR/x-context"

# shellcheck source=bin/fm-x-lib.sh
. "$ROOT/bin/fm-x-lib.sh"
FM_HOME="$HOME_DIR"
export FM_HOME
fmx_context_registry_set "$STATE_DIR" "$REQ_ID" discord 1900 1

test_dry_run_records_dismiss_and_clears_context() {
  local out
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-dismiss.sh" "$REQ_ID" 2>"$TMP_ROOT/stderr") \
    || fail "fm-x-dismiss dry-run should succeed"
  [ "$out" = "$REQ_ID" ] || fail "dry-run should print only the request ID: $out"
  assert_present "$STATE_DIR/x-outbox/$REQ_ID.json" \
    "dry-run should publish a dismiss preview"
  [ "$(jq -r '.endpoint' "$STATE_DIR/x-outbox/$REQ_ID.json")" = dismiss ] \
    || fail "preview should identify the dismiss endpoint"
  [ "$(jq -r '.request_id' "$STATE_DIR/x-outbox/$REQ_ID.json")" = "$REQ_ID" ] \
    || fail "preview should preserve the request ID"
  jq -e '((has("text") | not) and (has("texts") | not))' \
    "$STATE_DIR/x-outbox/$REQ_ID.json" >/dev/null \
    || fail "dismiss preview should contain no reply text"
  assert_absent "$STATE_DIR/x-context/$REQ_ID.json" \
    "dismiss should clear the durable reply context"
  assert_contains "$(cat "$TMP_ROOT/stderr")" 'DRY RUN' \
    "dry-run should explain that no request was posted"
  pass "fm-x-dismiss: dry-run records a dismiss-only preview and clears context"
}

test_unsafe_request_id_is_rejected() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-dismiss.sh" '../unsafe' 2>&1); rc=$?
  expect_code 2 "$rc" "unsafe request IDs must be rejected"
  assert_contains "$out" 'unsafe request_id' \
    "unsafe request ID rejection should explain the validation failure"
  pass "fm-x-dismiss: rejects path traversal request IDs"
}

test_dry_run_records_dismiss_and_clears_context
test_unsafe_request_id_is_rejected
