#!/usr/bin/env bash
# Public-interface coverage for lightweight MAIN-owned continuation progress.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE_BIN="$ROOT/bin/fm-task-state.sh"
TASKS_BIN="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-progress)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
export FM_HOME="$HOME_DIR"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_ROOT_OVERRIDE="$ROOT"

task_cmd() { "$TASKS_BIN" "$@"; }
progress() { "$STATE_BIN" "$@"; }

task_cmd add ordinary "Keep the requested outcome moving" --kind ship \
  --body "Original scope and acceptance stay here." --start >/dev/null || fail "fixture task add failed"

initial=$(progress progress ordinary) || fail "initial progress read failed"
printf '%s' "$initial" | jq -e '
  .task_id=="ordinary" and .task_state=="in_flight" and .recorded==false and
  .goal=="Keep the requested outcome moving" and .acceptance=="" and
  .current_state=="" and .remaining_gap=="" and .next_step=="" and
  (.record_token|test("^[a-f0-9]{64}$"))' >/dev/null || fail "initial projection was not compact and empty"

token=$(printf '%s' "$initial" | jq -r .record_token)
record='{"acceptance":"The requested behavior passes its public fixture","current_state":"Implementation returned an intermediate result","remaining_gap":"Validation has not passed","next_step":"Run the authorized validation and review its result"}'
updated=$(progress update-progress ordinary --expected-token "$token" --progress "$record") \
  || fail "material progress update failed"
printf '%s' "$updated" | jq -e '
  .recorded==true and .current_state=="Implementation returned an intermediate result" and
  .goal=="Keep the requested outcome moving" and
  .acceptance=="The requested behavior passes its public fixture" and
  .remaining_gap=="Validation has not passed" and
  .next_step=="Run the authorized validation and review its result"' >/dev/null \
  || fail "updated projection lost resumable progress"
assert_grep '<!-- firstmate-progress:v1 -->' "$HOME_DIR/data/backlog.md" \
  "progress did not reuse the original task record"
assert_absent "$HOME_DIR/data/ordinary/lifecycle.json" \
  "ordinary progress created a second lifecycle progress store"

before=$(sha256sum "$HOME_DIR/data/backlog.md" | awk '{print $1}')
token=$(printf '%s' "$updated" | jq -r .record_token)
again=$(progress update-progress ordinary --expected-token "$token" --progress "$record") \
  || fail "identical progress update failed"
assert_equals "$before" "$(sha256sum "$HOME_DIR/data/backlog.md" | awk '{print $1}')" \
  "an unchanged update rewrote the task record"
assert_equals "$token" "$(printf '%s' "$again" | jq -r .record_token)" \
  "an unchanged update changed its read token"

task_cmd update ordinary --title "Corrected requested outcome" \
  --body "User corrected the task body while MAIN was working." >/dev/null \
  || fail "concurrent correction fixture failed"
out=$(progress update-progress ordinary --expected-token "$token" --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "stale task-record basis"
assert_contains "$out" "task record changed" "stale update refusal did not explain the correction"
assert_grep 'User corrected the task body' "$HOME_DIR/data/backlog.md" \
  "stale progress update overwrote a concurrent correction"

fresh=$(progress progress ordinary) || fail "progress read after correction failed"
assert_equals "Corrected requested outcome" "$(printf '%s' "$fresh" | jq -r .goal)" \
  "progress read did not use the corrected canonical task title"
done_record='{"acceptance":"The requested behavior passes its public fixture","current_state":"Requested outcome verified","remaining_gap":"","next_step":""}'
complete=$(progress update-progress ordinary --expected-token "$(printf '%s' "$fresh" | jq -r .record_token)" --progress "$done_record") \
  || fail "satisfied-goal progress update failed"
printf '%s' "$complete" | jq -e '.remaining_gap=="" and .next_step==""' >/dev/null \
  || fail "satisfied goal retained an executable next step"

listed=$(progress progress-list) || fail "active task discovery failed"
assert_equals "ordinary" "$(printf '%s' "$listed" | jq -r '.tasks[]')" \
  "monitoring did not discover the unfinished original task record"

out=$(FM_SUPERVISION_ACTOR=branch progress update-progress ordinary \
  --expected-token "$(printf '%s' "$complete" | jq -r .record_token)" --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "branch progress write"
assert_contains "$out" "task progress belongs to MAIN" "branch update refusal lost ownership reason"

task_cmd "done" ordinary >/dev/null || fail "fixture completion failed"
assert_equals 0 "$(progress progress-list | jq '.tasks | length')" "completed task remained active progress work"
out=$(progress update-progress ordinary --expected-token "$(printf '%s' "$complete" | jq -r .record_token)" --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "completed task progress update"

pass "task progress: goal/acceptance/state/gap/next step live in the original row with MAIN-only CAS updates and no unchanged writes"
