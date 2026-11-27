#!/usr/bin/env bash
# Behavior tests for bin/fm-forget.sh (remove, restore, list, feed) and the
# suggestion verbs it drives in bin/fm-suggestions.sh (list --json, drop,
# restore): a removed row comes back identical, a 20-task batch round-trips,
# every guard keeps its task with a reason and moves nothing, links cut at
# removal come back, a crash between cutting and moving repairs itself, and old
# removals are archived, never deleted. Assertions are on task state through
# the backlog wrapper and on command output, never on source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORGET="$ROOT/bin/fm-forget.sh"
SUGG="$ROOT/bin/fm-suggestions.sh"
AXI="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-forget)
HOLDER_PID=

cleanup() {
  [ -z "$HOLDER_PID" ] || kill -KILL "$HOLDER_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}
in_home() {  # <home> <command...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}
axi() { local home=$1; shift; in_home "$home" "$AXI" "$@" >/dev/null || fail "tasks-axi $* failed"; }
full() { in_home "$1" "$AXI" show "$2" --full; }
on_list() { in_home "$1" "$AXI" list | grep -q "^  $2,"; }

test_remove_then_restore_is_identical() {
  local home before after out
  home=$(make_home identical)
  axi "$home" add base "A blocker that stays"
  axi "$home" add one "Write the pilot plan" --repo firstmate --kind docs --priority 1 \
    --body "$(printf 'Captain 2026-11-06: plan the pilot\nsecond line, with "quotes"')" --blocked-by base
  axi "$home" hold one --reason "start after launch" --until 2099-01-01
  before=$(full "$home" one)
  out=$(in_home "$home" "$FORGET" remove --by tester one)
  assert_contains "$out" "removed one" "remove did not report the row"
  on_list "$home" one && fail "a removed row is still on the task list"
  on_list "$home" base || fail "removing a dependent took its blocker too"
  out=$(in_home "$home" "$FORGET" list)
  assert_contains "$out" "one " "the removed list does not show the row"
  out=$(in_home "$home" "$FORGET" restore one)
  assert_contains "$out" "restored one" "restore did not report the row"
  after=$(full "$home" one)
  assert_equals "$after" "$before" "a restored row differs from the removed one"
  jq -s -e 'map(.event) == ["removed","restored"] and .[0].by == "tester" and .[0].unlinked == ["base"]
    and .[1].relinked == ["base"]' "$home/data/forgotten-index.jsonl" >/dev/null \
    || fail "the index does not record the removal and restore: $(cat "$home/data/forgotten-index.jsonl")"
  [ "$(stat -c %a "$home/data/forgotten-index.jsonl" 2>/dev/null || stat -f %Lp "$home/data/forgotten-index.jsonl")" = 600 ] \
    || fail "the index is not private"
  pass "remove then restore returns an identical row, its cut link included"
}

test_twenty_task_batch_round_trip() {
  local home i out snap
  home=$(make_home batch)
  axi "$home" add keeper "Stays on the list"
  for i in $(seq 1 20); do
    case $((i % 4)) in
      0) axi "$home" add "t$i" "Task number $i" --priority $((i % 5)) --body "note $i" ;;
      1) axi "$home" add "t$i" "Task number $i" --blocked-by keeper ;;
      2) axi "$home" add "t$i" "Task number $i" --blocked-by "t$((i - 1))" ;;
      3) axi "$home" add "t$i" "Task number $i" --repo "repo$i"; axi "$home" hold "t$i" --reason "parked for now" --kind parked ;;
    esac
  done
  snap="$TMP_ROOT/batch.snap"
  : > "$snap"
  for i in $(seq 1 20); do full "$home" "t$i" >> "$snap"; done
  out=$(in_home "$home" "$FORGET" remove --batch round-trip $(seq -f 't%g' 1 20))
  assert_contains "$out" "batch round-trip removed=20 kept=0" "the batch did not remove all 20: $out"
  for i in $(seq 1 20); do on_list "$home" "t$i" && fail "t$i is still on the list after the batch"; done
  [ "$(in_home "$home" "$FORGET" list --json | jq '[.[] | select(.batch == "round-trip")] | length')" = 20 ] \
    || fail "the removed list does not hold the batch"
  out=$(in_home "$home" "$FORGET" restore --batch round-trip)
  assert_contains "$out" "restored=20 kept=0" "restoring the batch did not bring back 20: $out"
  : > "$snap.after"
  for i in $(seq 1 20); do full "$home" "t$i" >> "$snap.after"; done
  cmp -s "$snap" "$snap.after" || fail "the restored batch differs: $(diff "$snap" "$snap.after" | head -20)"
  [ "$(in_home "$home" "$FORGET" list --json | jq length)" = 0 ] || fail "restored rows are still listed as removed"
  pass "removing 20 tasks in one batch and restoring the batch returns 20 identical rows"
}

test_guards_keep_with_reasons() {
  local home out before lock_lib
  home=$(make_home guards)
  axi "$home" add needed "Needed by another"
  axi "$home" add needer "Needs the first" --blocked-by needed
  axi "$home" add running "Has a worker"
  fm_write_meta "$home/state/running.meta" 'kind=ship' 'harness=claude' 'window=firstmate:fm-running'
  axi "$home" add started "Already started"
  axi "$home" start started
  axi "$home" add asked "A question for the captain"
  axi "$home" hold asked --reason "captain decision pending" --kind captain
  axi "$home" add shipped "Has a pull request" --pr https://github.com/o/r/pull/7
  axi "$home" add questioned "Has an open crew question"
  printf 'needs-decision [key=pick] [at=%s]: A or B?\n' "$(date +%s)" > "$home/state/questioned.status"
  axi "$home" add sm "A secondmate home" --kind secondmate
  axi "$home" add stale "Changed since the page"
  axi "$home" add busy "Another action runs"
  lock_lib="$ROOT/bin/fm-wake-lib.sh"
  # shellcheck disable=SC2016
  bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; sleep 60' _ "$lock_lib" "$home/state/.control-busy.lock" &
  HOLDER_PID=$!
  local i=0
  while [ ! -f "$home/state/.control-busy.lock/pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  before=$(cat "$home/data/backlog.md")
  out=$(in_home "$home" "$FORGET" remove needed running started asked shipped questioned sm stale@0000000000000000 busy elsewhere)
  kill -KILL "$HOLDER_PID" >/dev/null 2>&1 || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  assert_contains "$out" "kept needed: Another open task still needs it" "a needed task was not kept"
  assert_contains "$out" "needed by: Needs the first" "the keep reason does not name the dependent"
  assert_contains "$out" "kept running: A worker record is still attached" "a task with a worker was not kept"
  assert_contains "$out" "kept started: Work on it has started" "a started task was not kept"
  assert_contains "$out" "kept asked: It is a question for you" "a captain hold was not kept"
  assert_contains "$out" "kept shipped: It has a recorded pull request" "a task with a PR was not kept"
  assert_contains "$out" "kept questioned: A crew question about it is still open" "a task with an open question was not kept"
  assert_contains "$out" "kept sm: It is a secondmate's home" "a secondmate row was not kept"
  assert_contains "$out" "kept stale: It changed after the page was built" "a stale revision was not kept"
  assert_contains "$out" "kept busy: Another action on it is running" "a locked task was not kept"
  assert_contains "$out" "kept elsewhere: It is not on this home's task list" "a foreign id was not kept"
  assert_contains "$out" "removed=0 kept=10" "the summary does not count every refusal"
  assert_equals "$(cat "$home/data/backlog.md")" "$before" "a refused remove changed the task list"
  [ ! -s "$home/data/forgotten-index.jsonl" ] || fail "a refused remove wrote the index"
  pass "remove keeps running, started, finished-but-not-torn-down, held, linked, questioned, needed, stale, busy and foreign tasks, moving nothing"
}

test_together_and_restore_sets() {
  local home out rev
  home=$(make_home together)
  axi "$home" add a "Blocker"
  axi "$home" add b "Dependent" --blocked-by a
  out=$(in_home "$home" "$FORGET" remove --batch pair a b)
  assert_contains "$out" "removed=2 kept=0" "a task removed with its dependent was refused: $out"
  out=$(in_home "$home" "$FORGET" restore a)
  assert_contains "$out" "kept a: It was removed together with a task it is linked to" "a blocker restored without its dependent was not kept"
  on_list "$home" a && fail "a half-restored set moved"
  out=$(in_home "$home" "$FORGET" restore a b)
  assert_contains "$out" "restored=2 kept=0" "restoring the pair together failed: $out"
  in_home "$home" "$AXI" show b | grep -q 'blocked_by: a' || fail "the pair lost its link"
  rev=$(in_home "$home" "$FORGET" feed | jq -r '.rows[] | select(.id == "b") | .rev')
  out=$(in_home "$home" "$FORGET" remove "b@$rev")
  assert_contains "$out" "removed b" "a current revision was refused: $out"
  axi "$home" add b2 "Same id comes back"
  axi "$home" rm b2
  axi "$home" add b "A new task under the old id"
  out=$(in_home "$home" "$FORGET" restore b)
  assert_contains "$out" "kept b: A task with this id is on the list again" "a restore over a live id was not kept"
  pass "a task and its dependent go and come back together, and restore never overwrites a live id"
}

test_crash_between_cut_and_move_repairs() {
  local home
  home=$(make_home crash)
  axi "$home" add a "Blocker"
  axi "$home" add b "Dependent" --blocked-by a
  # The state a crash after cutting the link and before the move leaves.
  axi "$home" unblock b --by a
  printf 'b\ta\n' > "$home/state/.forget-journal"
  in_home "$home" "$FORGET" remove nothing-here >/dev/null
  in_home "$home" "$AXI" show b | grep -q 'blocked_by: a' || fail "the journal did not restore the cut link"
  assert_absent "$home/state/.forget-journal" "the journal survived its repair"
  pass "a crash between cutting a link and moving the row is repaired by the next call"
}

test_old_removals_are_archived_not_deleted() {
  local home out later
  home=$(make_home expiry)
  axi "$home" add old "Removed long ago"
  in_home "$home" "$FORGET" remove --batch long-ago old >/dev/null
  later=$(( $(date +%s) + 91 * 86400 ))
  out=$(FM_FORGET_NOW=$later in_home "$home" "$FORGET" restore --batch long-ago)
  assert_contains "$out" "restored=0" "a row past the keep window was restored"
  [ "$(FM_FORGET_NOW=$later in_home "$home" "$FORGET" list --json | jq length)" = 0 ] || fail "an archived row is still restorable"
  assert_grep "old - Removed long ago" "$home/data/forgotten-archive.md" "the archived row is not in the archive"
  jq -s -e 'any(.[]; .event == "archived" and .id == "old")' "$home/data/forgotten-index.jsonl" >/dev/null \
    || fail "the archive move was not recorded"
  pass "removals older than 90 days move to the archive, never deleted"
}

test_suggestions_drop_and_restore() {
  local home id out
  home=$(make_home sugg)
  id=sg-00000001
  jq -cn --arg id "$id" --argjson now "$(date +%s)" \
    '{id:$id, title:"Tidy the follow-up list", origin:"scout-x", item:1, kind:"hardening",
      file_line:"", size:"", risk:"", repo:"", filed_at:$now, outcome:"suggested"}' \
    > "$home/data/suggestions.jsonl"
  [ "$(in_home "$home" "$SUGG" list --json | jq -r '.[0].id')" = "$id" ] || fail "list --json does not show the waiting suggestion"
  out=$(in_home "$home" "$FORGET" remove --batch sg-batch "$id")
  assert_contains "$out" "removed $id" "a suggestion was not dropped: $out"
  [ "$(in_home "$home" "$SUGG" list --json | jq length)" = 0 ] || fail "a dropped suggestion is still waiting"
  in_home "$home" "$SUGG" archive | grep -q "$id \[dropped\]" || fail "the dropped suggestion is not in the never-deleted archive"
  out=$(in_home "$home" "$SUGG" drop "$id" 2>&1) && fail "dropping a dropped suggestion succeeded"
  out=$(in_home "$home" "$FORGET" restore --batch sg-batch)
  assert_contains "$out" "restored $id" "restoring the batch did not bring the suggestion back: $out"
  [ "$(in_home "$home" "$SUGG" list --json | jq -r '.[0].id')" = "$id" ] || fail "a restored suggestion is not waiting again"
  in_home "$home" "$SUGG" drop "$id" >/dev/null || fail "drop failed"
  out=$(in_home "$home" "$SUGG" pick "$id")
  assert_contains "$out" "picked $id" "a dropped suggestion cannot be picked"
  pass "suggestions drop to the archive, restore to the list, and stay pickable"
}

fm_test_run test_remove_then_restore_is_identical test_twenty_task_batch_round_trip \
  test_guards_keep_with_reasons test_together_and_restore_sets test_crash_between_cut_and_move_repairs \
  test_old_removals_are_archived_not_deleted test_suggestions_drop_and_restore
