#!/usr/bin/env bash
# Historical state-only retirement requires exact terminal and completed-cleanup
# proof, refuses pending delivery, and replays receipt archival without metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-retire-historical)
RETIRE="$ROOT/bin/fm-task-retire.sh"
FACTS='{"taskRecordRemoved":true,"endpointConfirmedGone":true,"copyDisposition":"retained-shared","bookkeepingComplete":true}'

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

new_terminal_task() {  # <home> <task>
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" add "$2" 'Historical cleanup fixture' --kind scout --start >/dev/null
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" 'done' "$2" --report "data/$2/report.md" >/dev/null
  printf '# retained report\n' >"$1/data/$2/report.md"
}

record_completion() {  # <home> <task> <generation>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" bash -c '
    . "$1/bin/fm-cleanup-receipt-lib.sh"
    fm_cleanup_receipt create "$2" "$3" >/dev/null
    fm_cleanup_receipt completion-record "$2" "$3" --facts "$4" >/dev/null
  ' _ "$ROOT" "$2" "$3" "$FACTS"
}

bind_historical_terminal() {  # <home> <task> <generation> [disposition]
  local home=$1 task=$2 generation=$3 disposition=${4:-archived}
  jq -n --arg id "$task" --arg generation "$generation" --arg disposition "$disposition" \
    '{schema:"fm-task-lifecycle.v2",task_id:$id,execution_generation:$generation,disposition:$disposition}' \
    >"$home/data/$task/lifecycle.json"
  rm -f -- "$home/data/$task/task.json"
}

mark_presented() {  # <home> <task>
  printf 'done: historical fixture\nnote: terminal status was presented\n' >"$1/state/$2.status"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null
}

test_dry_run_then_apply_retires_only_proved_state() {
  local home id=historical-complete generation=g-historical out
  home=$(new_home dry-run-apply)
  new_terminal_task "$home" "$id"
  record_completion "$home" "$id" "$generation"
  bind_historical_terminal "$home" "$id" "$generation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" bash -c '
    . "$1/bin/fm-merge-receipt-lib.sh"
    fm_merge_receipt_record "$2" "$3" https://code.byted.org/example/firstmate/merge_requests/7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  ' _ "$ROOT" "$id" "$generation" || fail 'could not create merge receipt fixture'
  mark_presented "$home" "$id"
  printf 'runtime\n' >"$home/state/$id.busy-session"
  printf 'runtime\n' >"$home/state/$id.turn-ended"
  mkdir -p "$home/state/$id.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\nhandled\n' >"$home/state/$id.inbox/handled/001.msg"

  out=$(FM_HOME="$home" "$RETIRE" "$id" --historical-state dry-run --generation "$generation") \
    || fail 'eligible historical cleanup dry-run refused'
  assert_contains "$out" "eligible: $id generation=$generation disposition=archived" \
    'dry-run did not report its proof-bound eligibility'
  assert_present "$home/state/$id.status" 'dry-run removed status state'
  assert_present "$home/state/$id.cleanup.json" 'dry-run archived the cleanup receipt'

  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" >/dev/null \
    || fail 'eligible historical cleanup apply refused'
  assert_absent "$home/state/$id.status" 'apply retained status state'
  assert_absent "$home/state/$id.busy-session" 'apply retained runtime projection'
  assert_absent "$home/state/$id.turn-ended" 'apply retained turn-ended projection'
  assert_absent "$home/state/$id.inbox" 'apply retained settled inbox history'
  assert_absent "$home/state/$id.cleanup.json" 'apply retained active cleanup receipt'
  assert_absent "$home/state/$id.merge-receipts.jsonl" 'apply retained active merge receipt'
  assert_absent "$home/data/$id/task.json" 'apply recreated an absent canonical task record'
  assert_present "$home/data/$id/report.md" 'apply removed the report'
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" bash -c '
    . "$1/bin/fm-cleanup-receipt-lib.sh"
    . "$1/bin/fm-merge-receipt-lib.sh"
    fm_cleanup_receipt completion-read "$2" "$3" >/dev/null
    fm_merge_receipt_current "$2" "$3" >/dev/null
  ' _ "$ROOT" "$id" "$generation" || fail 'archived owner evidence was not readable'
  pass 'historical state cleanup dry-runs then applies only after exact terminal completion proof'
}

test_pending_inbox_and_handoff_refuse_without_mutation() {
  local home id=historical-pending generation=g-pending rc=0
  home=$(new_home pending)
  new_terminal_task "$home" "$id"
  record_completion "$home" "$id" "$generation"
  bind_historical_terminal "$home" "$id" "$generation"
  mark_presented "$home" "$id"
  mkdir -p "$home/state/$id.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\nunread\n' >"$home/state/$id.inbox/001.msg"
  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/inbox.out" 2>"$home/inbox.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup accepted an unhandled inbox record'
  assert_grep 'unhandled inbox record' "$home/inbox.err" 'inbox refusal was not explicit'
  assert_present "$home/state/$id.status" 'inbox refusal partially retired status state'

  rm -f "$home/state/$id.inbox/001.msg"
  mkdir -p "$home/state/task-handoffs/records" "$home/state/task-handoffs/status"
  printf 'schema=fm-task-handoff.v1\nfrom=source\ntarget=%s\n--\nmessage\n' "$id" \
    >"$home/state/task-handoffs/records/pending-one.msg"
  rc=0
  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/handoff.out" 2>"$home/handoff.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup accepted a pending handoff'
  assert_grep 'has pending handoff' "$home/handoff.err" 'handoff refusal was not explicit'
  assert_present "$home/state/$id.status" 'handoff refusal partially retired status state'

  rm -f "$home/state/task-handoffs/records/pending-one.msg"
  printf 'schema=fm-task-handoff.v1\nid=delivered-one\nfrom=source\ntarget=%s\ntarget_generation=%s\n--\nmessage\n' \
    "$id" "$generation" >"$home/state/task-handoffs/records/delivered-one.msg"
  printf 'schema=fm-task-handoff.v1\nstate=delivered\ninbox_record=%s\n' \
    "$home/state/$id.inbox/001.msg" >"$home/state/task-handoffs/status/delivered-one.state"
  printf 'schema=fm-task-inbox.v1\nexecution_generation=%s\nhandoff=delivered-one\n--\nmessage\n' \
    "$generation" >"$home/state/$id.inbox/001.msg"
  rc=0
  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/delivered.out" 2>"$home/delivered.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup treated delivered handoff as handled'
  assert_grep 'delivered but not handled' "$home/delivered.err" \
    'delivered-unhandled handoff refusal was not explicit'
  assert_present "$home/state/$id.inbox/001.msg" \
    'historical cleanup removed a delivered-unhandled instruction'
  mv "$home/state/$id.inbox/001.msg" "$home/state/$id.inbox/handled/001.msg"
  FM_HOME="$home" "$ROOT/bin/fm-task-handoff.sh" retirement-check "$id" \
    || fail 'handoff owner did not accept the exact handled delivery evidence'
  rm -f "$home/state/$id.inbox/handled/001.msg" \
    "$home/state/task-handoffs/records/delivered-one.msg" \
    "$home/state/task-handoffs/status/delivered-one.state"

  ln -s "$home/data/$id/report.md" "$home/state/task-handoffs/records/unsafe.msg"
  rc=0
  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/unsafe-handoff.out" 2>"$home/unsafe-handoff.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup ignored an unsafe handoff record'
  assert_grep 'handoff record is unsafe' "$home/unsafe-handoff.err" \
    'unsafe handoff refusal was not explicit'
  assert_present "$home/state/$id.status" 'unsafe handoff refusal partially retired status state'
  pass 'historical state cleanup preserves pending inbox and handoff responsibilities'
}

test_archived_cleanup_receipt_replays_merge_archival_without_metadata() {
  local home id=archive-replay generation=g-replay
  home=$(new_home archive-replay)
  new_terminal_task "$home" "$id"
  record_completion "$home" "$id" "$generation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" bash -c '
    . "$1/bin/fm-cleanup-receipt-lib.sh"
    . "$1/bin/fm-merge-receipt-lib.sh"
    fm_merge_receipt_record "$2" "$3" https://code.byted.org/example/firstmate/merge_requests/8 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fm_cleanup_receipt archive "$2" "$3" >/dev/null
  ' _ "$ROOT" "$id" "$generation" || fail 'could not construct partial archival fixture'
  jq -n --arg id "$id" --arg generation "$generation" \
    '{schema:"fm-task-lifecycle.v2",task_id:$id,execution_generation:$generation,disposition:"archived"}' \
    >"$home/data/$id/lifecycle.json"
  rm -f -- "$home/data/$id/task.json"
  assert_absent "$home/state/$id.cleanup.json" 'partial archival fixture kept active cleanup evidence'
  assert_present "$home/state/$id.merge-receipts.jsonl" 'partial archival fixture lost active merge evidence'

  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" >/dev/null \
    || fail 'no-metadata archival replay refused'
  assert_absent "$home/state/$id.merge-receipts.jsonl" 'archival replay left merge receipt in active state'
  assert_present "$home/data/$id/merge-receipts.jsonl" 'archival replay lost merge evidence'
  pass 'historical state cleanup replays a partial receipt archive after metadata removal'
}

test_orphan_decision_cursor_refuses_through_public_entrypoint() {
  local home id=orphan-cursor generation=g-orphan rc=0
  home=$(new_home orphan-cursor)
  new_terminal_task "$home" "$id"
  record_completion "$home" "$id" "$generation"
  bind_historical_terminal "$home" "$id" "$generation"
  printf 'open\tneeds-decision\treview terminal evidence\n' \
    >"$home/state/.$id.open-decisions-cursor"

  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/orphan.out" 2>"$home/orphan.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup erased a decision cursor whose status log was missing'
  assert_grep 'status is missing while its decision cursor remains' "$home/orphan.err" \
    'public historical cleanup did not report the orphan cursor refusal'
  assert_present "$home/state/.$id.open-decisions-cursor" \
    'public historical cleanup removed the orphan decision cursor'
  assert_present "$home/state/$id.cleanup.json" \
    'orphan decision cursor refusal archived active cleanup evidence'
  pass 'historical cleanup public entrypoint preserves orphan decision evidence'
}

test_missing_or_mismatched_proof_refuses() {
  local home id=historical-unsafe generation=g-safe rc=0
  home=$(new_home refusal)
  new_terminal_task "$home" "$id"
  bind_historical_terminal "$home" "$id" "$generation"
  printf 'done: retained until exact proof exists\n' >"$home/state/$id.status"
  FM_HOME="$home" "$RETIRE" "$id" --historical-state dry-run --generation "$generation" \
    >"$home/missing.out" 2>"$home/missing.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup accepted missing completion evidence'
  assert_present "$home/state/$id.status" 'missing-proof refusal removed status state'

  record_completion "$home" "$id" other-generation
  rc=0
  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/mismatch.out" 2>"$home/mismatch.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'historical cleanup accepted a mismatched active cleanup generation'
  assert_grep 'does not match' "$home/mismatch.err" 'generation mismatch refusal was not explicit'
  assert_present "$home/state/$id.status" 'generation refusal removed status state'
  pass 'historical state cleanup fails closed without exact generation-bound completion proof'
}

test_reopened_completed_task_id_refuses_stale_generation_cleanup() {
  local home id=reused-completed generation=old-generation rc=0 before
  home=$(new_home reused-id)
  record_completion "$home" "$id" "$generation"
  mkdir -p "$home/data/$id"
  jq -n --arg id "$id" --arg generation "$generation" \
    '{schema:"fm-task-lifecycle.v2",task_id:$id,execution_generation:$generation,disposition:"archived"}' \
    >"$home/data/$id/lifecycle.json"
  new_terminal_task "$home" "$id"
  printf 'new execution runtime\n' >"$home/state/$id.busy-session"
  printf 'done: newer completed instance\n' >"$home/state/$id.status"
  before=$(shasum "$home/state/$id.busy-session" "$home/state/$id.status" "$home/state/$id.cleanup.json")

  FM_HOME="$home" "$RETIRE" "$id" --historical-state apply --generation "$generation" \
    >"$home/reuse.out" 2>"$home/reuse.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'stale generation receipt retired a reopened completed task ID'
  assert_grep 'has no execution generation' "$home/reuse.err" \
    'reopened task-ID refusal did not identify the missing current generation proof'
  [ "$(shasum "$home/state/$id.busy-session" "$home/state/$id.status" "$home/state/$id.cleanup.json")" = "$before" ] \
    || fail 'stale generation refusal changed newer runtime or old receipt evidence'
  assert_present "$home/data/$id/task.json" 'stale generation refusal removed the current canonical task'
  pass 'historical cleanup preserves reopened completed task runtime when only stale generation proof exists'
}

test_dry_run_then_apply_retires_only_proved_state
test_pending_inbox_and_handoff_refuse_without_mutation
test_archived_cleanup_receipt_replays_merge_archival_without_metadata
test_orphan_decision_cursor_refuses_through_public_entrypoint
test_missing_or_mismatched_proof_refuses
test_reopened_completed_task_id_refuses_stale_generation_cleanup
