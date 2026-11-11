#!/usr/bin/env bash
# tests/fm-branch-dispatch-signal-paths.test.sh - how the supervision branch
# dispatcher resolves the tasks in a coalesced signal batch row now that the
# queued payload is a compact summary: from the private batch-path record
# bin/fm-watch.sh writes beside the queue, and a scan veto for a row whose record
# is missing so it surfaces rather than being classified from the summary alone.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-dispatch-signal-paths)

run_scope() {  # <case-dir> <label>
  local dir=$1 label=$2 out
  out=$(LIB="$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" STATE="${dir}/state" \
    node --input-type=module --no-warnings -e '
import { pathToFileURL } from "node:url";
const lib = await import(pathToFileURL(process.env.LIB).href);
const scope = lib.scopeForUnreadWake(process.env.STATE, false);
process.stdout.write(JSON.stringify({
  eligible: scope.eligible,
  corrupted: scope.corrupted,
  tasks: [...scope.eligibleTasks].sort(),
  projects: scope.projects,
}));
' 2>&1) || fail "[$label] the dispatcher scope probe failed: $out"
  printf '%s' "$out"
}

expect_scope() {  # <label> <scope-json> <expected-substring...>
  local label=$1 json=$2 want
  shift 2
  for want in "$@"; do
    case "$json" in
      *"$want"*) ;;
      *) fail "[$label] scope $json does not contain $want" ;;
    esac
  done
}

new_case() {  # <name>
  local dir=$1
  mkdir -p "$dir/state"
  printf 'project=%s/projects/approved\nwindow=fm-task-a\n' "$dir" > "$dir/state/task-a.meta"
  printf 'project=%s/projects/approved\nwindow=fm-task-b\n' "$dir" > "$dir/state/task-b.meta"
}

queue_row() {  # <dir> <seq> <key> <payload>
  printf '%s\t1\tsignal\t%s\t%s\n' "$2" "$3" "$4" >> "$1/state/.wake-queue"
}

test_a_compact_payload_resolves_the_batch_from_the_private_record() {
  local dir
  dir="$TMP_ROOT/dispatcher-record"
  rm -rf "$dir"
  mkdir -p "$dir"
  new_case "$dir"
  # The summary names only task-a; the record carries the whole batch, including
  # the turn-ended marker the summary is not allowed to print.
  printf 'signal-batch-ccc\t%s/task-a.status %s/task-b.turn-ended\n' "$dir/state" "$dir/state" \
    > "$dir/state/.signal-batch-paths"
  queue_row "$dir" 1 signal-batch-ccc \
    "signal: 2 files (1 status, 1 turn-end): ${dir}/state/task-a.status +1 more"
  expect_scope "batch record" "$(run_scope "$dir" "batch record")" \
    '"eligible":true' '"corrupted":false' '"task-a"' '"task-b"'
  pass "the dispatcher resolves a compact batch from the private batch-path record"
}

test_b_a_recordless_compact_payload_surfaces_instead_of_trusting_the_summary() {
  local dir
  dir="$TMP_ROOT/dispatcher-missing-record"
  rm -rf "$dir"
  mkdir -p "$dir"
  new_case "$dir"
  queue_row "$dir" 1 signal-batch-ddd \
    "signal: 2 files (1 status, 1 turn-end): ${dir}/state/task-a.status +1 more"
  expect_scope "missing record" "$(run_scope "$dir" "missing record")" \
    '"eligible":false' '"corrupted":true'
  pass "a queued batch without its record surfaces instead of using the compact summary"
}

test_c_a_summary_token_is_never_read_as_a_path() {
  local dir
  dir="$TMP_ROOT/dispatcher-junk"
  rm -rf "$dir"
  mkdir -p "$dir"
  new_case "$dir"
  queue_row "$dir" 1 signal-batch-eee "signal: 3 files (0 status, 3 turn-end)"
  expect_scope "junk" "$(run_scope "$dir" "junk")" '"eligible":false' '"corrupted":true'
  pass "a summary with no resolvable status path stays a scan veto instead of a junk-token task"
}

test_d_a_needs_decision_row_is_main_owned_through_its_status_key() {
  local dir
  dir="$TMP_ROOT/dispatcher-decision"
  rm -rf "$dir"
  mkdir -p "$dir"
  new_case "$dir"
  queue_row "$dir" 1 "task-b.status" \
    "needs-decision: ${dir}/state/task-a.status ${dir}/state/task-b.status"
  expect_scope "decision" "$(run_scope "$dir" "decision")" '"eligible":false' '"corrupted":false'
  pass "a needs-decision row is main-owned through its status-shaped key"
}

test_a_compact_payload_resolves_the_batch_from_the_private_record
test_b_a_recordless_compact_payload_surfaces_instead_of_trusting_the_summary
test_c_a_summary_token_is_never_read_as_a_path
test_d_a_needs_decision_row_is_main_owned_through_its_status_key
