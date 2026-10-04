#!/usr/bin/env bash
# Behavioral checks for purpose-specific merge receipt history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-receipt)
HOME_DIR="$TMP_ROOT/home"
TASK=historical-empty
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$TASK"

cat > "$HOME_DIR/data/$TASK/lifecycle.json" <<EOF
{"schema":"fm-task-lifecycle.v2","task_id":"$TASK","owner_receipts":{"merge":[]}}
EOF
historical_hash=$(shasum "$HOME_DIR/data/$TASK/lifecycle.json")

history=$(FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_history "$2"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$TASK") \
  || fail 'valid historical lifecycle with no merge receipt was rejected'
[ -z "$history" ] || fail 'empty historical merge history produced a synthetic receipt'

FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_record "$2" "$3" "$4" "$5"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$TASK" generation-1 \
  'https://codebase.example.invalid/merge_requests/1' \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  || fail 'empty retained historical history blocked a new operation receipt'

jq -e --arg task "$TASK" '
  .schema=="fm-merge-receipt.v1" and .task_id==$task and
  .execution_generation=="generation-1" and
  .url=="https://codebase.example.invalid/merge_requests/1" and
  .head=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$HOME_DIR/state/$TASK.merge-receipts.jsonl" >/dev/null \
  || fail 'new exact merge receipt was not recorded'
[ "$(shasum "$HOME_DIR/data/$TASK/lifecycle.json")" = "$historical_hash" ] \
  || fail 'recording a merge receipt rewrote retained historical lifecycle data'

CURRENT=current-task
mkdir -p "$HOME_DIR/data/$CURRENT"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add "$CURRENT" 'Current task' \
  --kind ship --body 'Current canonical merge receipt fixture.' --start >/dev/null \
  || fail 'current canonical task fixture could not be created'
printf '{malformed retained rich history\n' >"$HOME_DIR/data/$CURRENT/lifecycle.json"
FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_record "$2" "$3" "$4" "$5"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$CURRENT" generation-current \
  'https://codebase.example.invalid/merge_requests/2' \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  || fail 'retained rich history controlled a current task merge receipt'
jq -e '.task_id=="current-task" and .execution_generation=="generation-current"' \
  "$HOME_DIR/state/$CURRENT.merge-receipts.jsonl" >/dev/null \
  || fail 'current task merge receipt was not recorded independently of rich history'

FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_archive "$2"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$CURRENT" \
  || fail 'completed merge receipt history could not leave active state'
assert_absent "$HOME_DIR/state/$CURRENT.merge-receipts.jsonl" \
  'archived merge history remained in active state'
assert_present "$HOME_DIR/data/$CURRENT/merge-receipts.jsonl" \
  'archived merge history was not retained with task evidence'
FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_current "$2" "$3" "$4" "$5" >/dev/null' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$CURRENT" generation-current \
  'https://codebase.example.invalid/merge_requests/2' \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  || fail 'original merge owner could not read archived exact-generation evidence'
FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_record "$2" "$3" "$4" "$5"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$CURRENT" generation-current \
  'https://codebase.example.invalid/merge_requests/2' \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  || fail 'exact archived merge receipt did not replay idempotently'
assert_absent "$HOME_DIR/state/$CURRENT.merge-receipts.jsonl" \
  'idempotent archived receipt replay recreated active state'

pass 'merge receipts: completed evidence leaves active state and remains generation-readable without duplicate recreation'
