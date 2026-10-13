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

AMBIGUOUS=ambiguous-pr
mkdir -p "$HOME_DIR/data/$AMBIGUOUS"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add "$AMBIGUOUS" 'Ambiguous PR receipt' \
  --kind ship --body 'Ambiguous PR receipt fixture.' --start >/dev/null \
  || fail 'ambiguous PR task fixture could not be created'
printf '%s\n' \
  '{"schema":"fm-merge-receipt.v1","task_id":"ambiguous-pr","execution_generation":"generation-pr","url":"https://codebase.example.invalid/merge_requests/3","head":"1111111111111111111111111111111111111111"}' \
  '{"schema":"fm-merge-receipt.v1","task_id":"ambiguous-pr","execution_generation":"generation-pr","url":"https://codebase.example.invalid/merge_requests/3","head":"2222222222222222222222222222222222222222"}' \
  > "$HOME_DIR/state/$AMBIGUOUS.merge-receipts.jsonl"
if FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_current "$2" "$3" >/dev/null' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$AMBIGUOUS" generation-pr 2>/dev/null; then
  fail 'multiple PR heads passed the local-continuation selector'
fi

HISTORICAL_LOCAL=historical-local
HISTORICAL_REPO="$TMP_ROOT/historical-project"
mkdir -p "$HOME_DIR/data/$HISTORICAL_LOCAL"
fm_git_init_commit "$HISTORICAL_REPO"
git -C "$HISTORICAL_REPO" checkout -qb "fm/$HISTORICAL_LOCAL"
printf 'first local landing\n' >> "$HISTORICAL_REPO/README.md"
git -C "$HISTORICAL_REPO" add README.md
git -C "$HISTORICAL_REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm first-local
historical_head=$(git -C "$HISTORICAL_REPO" rev-parse HEAD)
printf 'continued local landing\n' >> "$HISTORICAL_REPO/README.md"
git -C "$HISTORICAL_REPO" add README.md
git -C "$HISTORICAL_REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm continued-local
continued_head=$(git -C "$HISTORICAL_REPO" rev-parse HEAD)
historical_url="local:$HISTORICAL_REPO#main"
jq -cn --arg id "$HISTORICAL_LOCAL" --arg url "$historical_url" --arg head "$historical_head" \
  '{schema:"fm-task-lifecycle.v2",task_id:$id,owner_receipts:{merge:[{
    execution_generation:"generation-local",facts:{url:$url,head:$head}}]}}' \
  > "$HOME_DIR/data/$HISTORICAL_LOCAL/lifecycle.json"
FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_record_local "$2" "$3" "$4" "$5" "$6" "$7"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$HISTORICAL_LOCAL" generation-local \
  "$historical_url" "$HISTORICAL_REPO" "refs/heads/fm/$HISTORICAL_LOCAL" "$continued_head" \
  || fail 'historical first landing blocked a valid local continuation receipt'
jq -e --arg previous "$historical_head" --arg head "$continued_head" \
  '.previous_head==$previous and .head==$head' \
  "$HOME_DIR/state/$HISTORICAL_LOCAL.merge-receipts.jsonl" >/dev/null \
  || fail 'local continuation did not link to the retained historical first landing'
current_local=$(FM_HOME="$HOME_DIR" bash -c \
  '. "$1"; fm_merge_receipt_current "$2" "$3"' \
  _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$HISTORICAL_LOCAL" generation-local) \
  || fail 'historical-first local continuation remained ambiguous'
printf '%s\n' "$current_local" | jq -e --arg head "$continued_head" '.head==$head' >/dev/null \
  || fail 'historical-first local continuation did not select the newest receipt'

pass 'merge receipts: completed evidence leaves active state and remains generation-readable without duplicate recreation'
