#!/usr/bin/env bash
# Public-interface coverage for canonical per-task business/progress records.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-progress)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT"
TASKS="$ROOT/bin/fm-tasks-axi.sh"
STATE="$ROOT/bin/fm-task-state.sh"

"$TASKS" add first "Keep the first outcome moving" --kind ship --body "First body" --start >/dev/null \
  || fail "first task create failed"
"$TASKS" add second "Keep the second outcome moving" --kind scout --body "Second body" >/dev/null \
  || fail "second task create failed"
first="$HOME_DIR/data/first/task.json"
second="$HOME_DIR/data/second/task.json"
[ -f "$first" ] && [ -f "$second" ] || fail "task create did not use task directories"
[ "$(stat -c %a "$first")" = 600 ] || fail "task record is not private"
assert_absent "$HOME_DIR/data/backlog.md" "task CRUD created a shared backlog"

shown=$("$TASKS" show first --full) || fail "single-task read failed"
assert_contains "$shown" "title: Keep the first outcome moving" "single-task read lost the goal"
listed=$("$TASKS" list --state in_flight --limit 10) || fail "filtered task list failed"
assert_contains "$listed" "first,in_flight,ship" "filtered list lost the in-flight task"
assert_not_contains "$listed" "second," "filtered list included a queued task"
inventory=$(python3 "$ROOT/bin/fm-task-record.py" --data "$HOME_DIR/data" inventory) || fail "unified inventory read failed"
assert_equals $'first\nsecond' "$(printf '%s' "$inventory" | jq -r '.tasks[].id')" "inventory did not aggregate both task records"

LEGACY_HOME="$TMP_ROOT/legacy-only"
mkdir -p "$LEGACY_HOME/data" "$LEGACY_HOME/state"
printf '## In flight\n\n- [ ] legacy-only - Legacy goal\n\n## Queued\n\n## Done\n' > "$LEGACY_HOME/data/backlog.md"
printf '## Archived 2026-10\n\n- [x] archived-only - Archived goal\n' > "$LEGACY_HOME/data/done-archive.md"
rc=0
out=$(FM_HOME="$LEGACY_HOME" FM_DATA_OVERRIDE="$LEGACY_HOME/data" "$STATE" progress legacy-only 2>&1) || rc=$?
expect_code 1 "$rc" "legacy-only progress read"
assert_contains "$out" 'code: NOT_FOUND' "legacy backlog supplied progress without a canonical record"
assert_equals 0 "$(FM_HOME="$LEGACY_HOME" FM_DATA_OVERRIDE="$LEGACY_HOME/data" "$STATE" progress-list | jq '.tasks|length')" \
  "legacy backlog supplied unfinished task discovery"
assert_equals 0 "$(FM_HOME="$LEGACY_HOME" FM_DATA_OVERRIDE="$LEGACY_HOME/data" "$ROOT/bin/fm-fleet-snapshot.sh" --json | jq '.backlog.records|length')" \
  "legacy backlog or archive supplied fleet task data"
rc=0
FM_HOME="$LEGACY_HOME" FM_DATA_OVERRIDE="$LEGACY_HOME/data" bash -c \
  '. "$1"; fm_task_progress_completion_guard legacy-only' _ "$ROOT/bin/fm-task-progress-lib.sh" \
  >/dev/null 2>"$TMP_ROOT/missing-canonical.err" || rc=$?
expect_code 6 "$rc" "missing canonical completion guard"
assert_grep 'no canonical task record' "$TMP_ROOT/missing-canonical.err" \
  "missing canonical record was silently reconstructed"
assert_absent "$ROOT/bin/fm-task-import.sh" "legacy import command remains advertised as executable"
rc=0
python3 "$ROOT/bin/fm-task-record.py" --data "$LEGACY_HOME/data" import-snapshot \
  --snapshot "$LEGACY_HOME/data/backlog.md" >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "removed import-snapshot command"

# Empty progress is absence of semantic acceptance, never permission to clean up.
# shellcheck source=bin/fm-task-progress-lib.sh
. "$ROOT/bin/fm-task-progress-lib.sh"
rc=0
fm_task_progress_completion_guard first >/dev/null 2>"$TMP_ROOT/blank-acceptance.err" || rc=$?
expect_code 6 "$rc" "blank progress completion guard"
assert_grep 'not MAIN-accepted' "$TMP_ROOT/blank-acceptance.err" \
  "blank progress authorized cleanup without semantic acceptance"

record='{"acceptance":"The requested behavior passes","current_state":"Implementation exists","remaining_gap":"Review remains","next_step":"Run review"}'
second_before=$(sha256sum "$second" | awk '{print $1}')
updated=$("$STATE" update-progress first --progress "$record") || fail "progress update failed"
printf '%s' "$updated" | jq -e '.goal=="Keep the first outcome moving" and .next_step=="Run review"' >/dev/null \
  || fail "progress response lost goal-directed fields"
assert_equals "$second_before" "$(sha256sum "$second" | awk '{print $1}')" \
  "one task progress update changed another task"
assert_absent "$HOME_DIR/data/backlog.md" "progress update created a shared backlog"

mtime=$(stat -c %Y "$first")
sleep 1
rc=0
out=$("$STATE" update-progress first --expected-token obsolete --progress "$record" 2>&1) || rc=$?
expect_code 2 "$rc" "obsolete expected-token argument"
"$STATE" update-progress first --progress "$record" >/dev/null || fail "identical progress update failed"
assert_equals "$mtime" "$(stat -c %Y "$first")" "identical progress update rewrote the task record"

out=$(FM_SUPERVISION_ACTOR=branch "$STATE" update-progress first --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "branch progress update"
assert_contains "$out" "task progress belongs to MAIN" "MAIN-only refusal was lost"

rc=0
out=$("$STATE" update-progress first --progress \
  '{"acceptance":"line one\nline two","current_state":"state","remaining_gap":"gap","next_step":"step"}' 2>&1) || rc=$?
expect_code 6 "$rc" "multiline progress update"
assert_contains "$out" 'must be one line' 'multiline progress was not bounded'
oversized=$(printf 'x%.0s' $(seq 1 1201))
oversized_json=$(jq -cn --arg value "$oversized" \
  '{acceptance:$value,current_state:"state",remaining_gap:"gap",next_step:"step"}')
rc=0
out=$("$STATE" update-progress first --progress "$oversized_json" 2>&1) || rc=$?
expect_code 6 "$rc" "oversized progress update"
assert_contains "$out" 'exceeds 1200 UTF-8 bytes' 'oversized progress was not bounded'

changed='{"acceptance":"The requested behavior passes","current_state":"A later result exists","remaining_gap":"Final review remains","next_step":"Run final review"}'
before=$(sha256sum "$first" | awk '{print $1}')
out=$(FM_TASK_RECORD_TEST_FAIL_BEFORE_REPLACE=1 "$STATE" update-progress first --progress "$changed" 2>&1)
rc=$?
expect_code 6 "$rc" "injected interrupted write"
assert_equals "$before" "$(sha256sum "$first" | awk '{print $1}')" \
  "interrupted replacement published partial JSON"
[ -z "$(find "$HOME_DIR/data/first" -maxdepth 1 -name '.first.task.*' -print)" ] \
  || fail "interrupted replacement left a temporary record"

mkdir -p "$HOME_DIR/state/first.meta.lock" "$HOME_DIR/state/.lease-command.lock"
timeout 3 "$STATE" update-progress first --progress "$changed" >/dev/null \
  || fail "unrelated lease or metadata lock serialized descriptive progress"
rmdir "$HOME_DIR/state/first.meta.lock" "$HOME_DIR/state/.lease-command.lock"

restarted=$("$STATE" progress first) || fail "restart progress read failed"
assert_equals "Run final review" "$(printf '%s' "$restarted" | jq -r .next_step)" \
  "restart lost the authorized next step"
assert_equals first "$("$STATE" progress-list | jq -r '.tasks[]')" \
  "progress discovery did not use the per-task inventory"

"$TASKS" hold first --reason "captain decision" --kind captain >/dev/null || fail "hold failed"
held=$("$STATE" progress first) || fail "held progress read failed"
printf '%s' "$held" | jq -e '.task_held=="yes" and .recorded==true and .context_relation=="disposition_only" and .next_step=="Run final review"' >/dev/null \
  || fail "held task lost progress or remained routeable"
aged_snapshot=$(FM_SNAPSHOT_NOW=2026-11-30T00:00:00Z "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
  || fail "aged canonical hold snapshot failed"
printf '%s' "$aged_snapshot" | jq -e '
  any(.backlog.records[];.id=="first" and .hold_set!=null and .hold_bucket=="aged" and .captain_actionable==false)' \
  >/dev/null || fail "canonical captain hold lost its age classification"
"$TASKS" unhold first >/dev/null || fail "unhold failed"
"$TASKS" block first --by second >/dev/null || fail "dependency block failed"
blocked=$("$STATE" progress first) || fail "blocked progress read failed"
printf '%s' "$blocked" | jq -e '.task_blocked=="yes" and .recorded==true and .context_relation=="disposition_only"' >/dev/null \
  || fail "dependency block did not disable continuation routing"
"$TASKS" unblock first --by second >/dev/null || fail "dependency unblock failed"

snapshot=$("$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
printf '%s' "$snapshot" | jq -e '.backlog.records|length==2 and any(.[];.id=="first" and .compact_progress.next_step=="Run final review")' >/dev/null \
  || fail "fleet snapshot did not derive its view from task records"

DEP_DATA="$TMP_ROOT/dependencies/data"
mkdir -p "$DEP_DATA"
FM_DATA_OVERRIDE="$DEP_DATA" "$TASKS" add blocker "Dependency blocker" --kind ship >/dev/null
FM_DATA_OVERRIDE="$DEP_DATA" "$TASKS" add dependent "Dependent work" --kind ship >/dev/null
FM_DATA_OVERRIDE="$DEP_DATA" "$TASKS" block dependent --by blocker >/dev/null
assert_not_contains "$(FM_DATA_OVERRIDE="$DEP_DATA" "$TASKS" ready)" "dependent," \
  "unresolved dependency was dispatchable"
FM_DATA_OVERRIDE="$DEP_DATA" "$TASKS" "done" blocker >/dev/null
assert_contains "$(FM_DATA_OVERRIDE="$DEP_DATA" "$TASKS" ready)" "dependent,queued,ship" \
  "completed dependency did not release queued work"
rc=0
FM_HOME="$TMP_ROOT/dependencies" FM_DATA_OVERRIDE="$DEP_DATA" bash -c \
  '. "$1"; fm_cleanup_completion_mode blocker g1' _ "$ROOT/bin/fm-cleanup-receipt-lib.sh" \
  >/dev/null 2>"$TMP_ROOT/done-without-acceptance.err" || rc=$?
expect_code 6 "$rc" "Done task without MAIN acceptance"
assert_grep 'not MAIN-accepted' "$TMP_ROOT/done-without-acceptance.err" \
  "Done disposition bypassed MAIN semantic acceptance"

done_record='{"acceptance":"The requested behavior passes","current_state":"The outcome is accepted","remaining_gap":"","next_step":""}'
"$STATE" update-progress first --progress "$done_record" >/dev/null || fail "acceptance update failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" bash -c \
  '. "$1"; fm_cleanup_completion_mode first g1' _ "$ROOT/bin/fm-cleanup-receipt-lib.sh" >/dev/null \
  || fail "cleanup consumer rejected semantic acceptance"
"$TASKS" 'done' first >/dev/null || fail "completion failed"
done_date=$(jq -r '.closed' "$first")
done_mtime=$(stat -c %Y "$first")
sleep 1
"$TASKS" 'done' first >/dev/null || fail "idempotent completion replay failed"
assert_equals "$done_date" "$(jq -r '.closed' "$first")" "done replay moved the close date"
assert_equals "$done_mtime" "$(stat -c %Y "$first")" "done replay rewrote an unchanged record"
"$TASKS" archive second >/dev/null || fail "archive failed"
assert_equals 0 "$("$STATE" progress-list | jq '.tasks | length')" \
  "terminal task records remained eligible for continuation"
assert_equals $'first\nsecond' "$(python3 "$ROOT/bin/fm-task-record.py" --data "$HOME_DIR/data" inventory | jq -r '.tasks[].id')" \
  "terminal records disappeared from inventory"

pass "task records: local atomic CRUD, progress, filtered inventory, continuation, holds, dependencies, completion and snapshot derivation"
