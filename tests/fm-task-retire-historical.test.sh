#!/usr/bin/env bash
# Historical business policy cannot supply execution-generation cleanup authority.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-retire-historical)
RETIRE="$ROOT/bin/fm-task-retire.sh"

test_historical_business_fallback_is_removed() {
  local home="$TMP_ROOT/history" id=old generation=old-generation before rc=0
  mkdir -p "$home/state" "$home/data/$id" "$home/config"
  printf '{"schema":"fm-task-lifecycle.v2","task_id":"old","execution_generation":"old-generation","disposition":"archived"}\n' > "$home/data/$id/lifecycle.json"
  printf 'done: historical source\n' > "$home/state/$id.status"
  before=$(shasum "$home/state/$id.status" "$home/data/$id/lifecycle.json")
  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" > "$home/out" 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'legacy disposition granted business/cleanup authority'
  assert_grep 'code: NOT_FOUND' "$home/err" 'missing record did not return canonical owner error'
  [ "$before" = "$(shasum "$home/state/$id.status" "$home/data/$id/lifecycle.json")" ] || fail 'missing record refusal changed historical material'

  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" backfill-archived --state-dir "$home/state" --preview > "$home/preview.json" || fail 'backfill preview failed'
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" backfill-archived --state-dir "$home/state" --apply-file "$home/preview.json" >/dev/null || fail 'backfill failed'
  before=$(shasum "$home/state/$id.status" "$home/data/$id/task.json")
  rc=0
  FM_HOME="$home" "$RETIRE" "$id" --historical-state dry-run --generation "$generation" > "$home/out" 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'backfill archive fabricated an execution binding'
  assert_grep 'has no execution generation' "$home/err" 'archive did not preserve execution boundary'
  [ "$before" = "$(shasum "$home/state/$id.status" "$home/data/$id/task.json")" ] || fail 'archive refusal changed records'
  pass 'legacy/missing and backfilled archive records cannot authorize unbound runtime cleanup'
}

test_exact_receipt_archive_remains_available() {
  local home="$TMP_ROOT/receipts" id=receipt-task generation=exact-generation before
  mkdir -p "$home/state" "$home/data/$id" "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add "$id" 'Archived task' >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" archive "$id" >/dev/null
  before=$(shasum "$home/data/$id/task.json")
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" bash -c '
    . "$1/bin/fm-cleanup-receipt-lib.sh"
    . "$1/bin/fm-merge-receipt-lib.sh"
    fm_cleanup_receipt create "$2" "$3" >/dev/null || exit 1
    fm_cleanup_receipt completion-record "$2" "$3" --facts \
      "{\"taskRecordRemoved\":true,\"endpointConfirmedGone\":true,\"copyDisposition\":\"retained-unlanded\",\"bookkeepingComplete\":true}" >/dev/null || exit 1
    fm_merge_receipt_record "$2" "$3" https://code.byted.org/example/firstmate/merge_requests/7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || exit 1
    fm_cleanup_receipt archive "$2" "$3" >/dev/null || exit 1
    fm_merge_receipt_archive "$2" "$3" || exit 1
    fm_cleanup_receipt archive "$2" "$3" >/dev/null || exit 1
    fm_cleanup_receipt completion-read "$2" "$3" >/dev/null || exit 1
    fm_merge_receipt_current "$2" "$3" >/dev/null || exit 1
    ! fm_cleanup_receipt read "$2" wrong-generation >/dev/null 2>&1
  ' _ "$ROOT" "$id" "$generation" || fail 'exact-generation archive/read/repeat boundary failed'
  [ "$before" = "$(shasum "$home/data/$id/task.json")" ] || fail 'receipt archival changed archived business record'
  assert_absent "$home/state/$id.cleanup.json" 'active receipt remained after archive'
  assert_present "$home/data/$id/cleanup-receipts" 'cleanup evidence was not preserved'
  pass 'exact receipt archival remains repeatable and independent of business state'
}

test_historical_business_fallback_is_removed
test_exact_receipt_archive_remains_available
