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
mkdir -p "$HOME_DIR/data/ordinary"
printf '%s\n' 'Original authenticated task intent.' > "$HOME_DIR/data/ordinary/brief.md"
printf '%s\n' 'spawn_gen=g1' > "$HOME_DIR/state/ordinary.meta"

initial=$(progress progress ordinary) || fail "initial progress read failed"
printf '%s' "$initial" | jq -e '
  .task_id=="ordinary" and .task_state=="in_flight" and .recorded==false and
  .goal=="Keep the requested outcome moving" and .acceptance=="" and
  .current_state=="" and .remaining_gap=="" and .next_step=="" and
  (.record_token|test("^[a-f0-9]{64}$"))' >/dev/null || fail "initial projection was not compact and empty"

token=$(printf '%s' "$initial" | jq -r .record_token)
task_cmd add twin "Keep the requested outcome moving" --kind ship \
  --body "Original scope and acceptance stay here." --start >/dev/null || fail "twin fixture task add failed"
mkdir -p "$HOME_DIR/data/twin"
printf '%s\n' 'Original authenticated task intent.' > "$HOME_DIR/data/twin/brief.md"
printf '%s\n' 'spawn_gen=g1' > "$HOME_DIR/state/twin.meta"
out=$(progress update-progress twin --expected-token "$token" --progress \
  '{"acceptance":"The requested behavior passes its public fixture","current_state":"Implementation returned an intermediate result","remaining_gap":"Validation has not passed","next_step":"Run the authorized validation and review its result"}' 2>&1)
rc=$?
expect_code 6 "$rc" "cross-task progress token"
assert_contains "$out" "task record changed" "an identical task accepted another task's progress token"
task_cmd 'done' twin >/dev/null || fail "twin fixture completion failed"

task_cmd add dash-body "Preserve a dash body" --kind ship --body "-" --start >/dev/null \
  || fail "dash-body fixture task add failed"
dash_initial=$(progress progress dash-body) || fail "dash-body initial progress read failed"
progress update-progress dash-body --expected-token "$(printf '%s' "$dash_initial" | jq -r .record_token)" \
  --progress '{"acceptance":"The original task body survives","current_state":"Ready","remaining_gap":"Check preservation","next_step":"Read the task body"}' >/dev/null \
  || fail "dash-body progress update failed"
dash_shown=$(task_cmd show dash-body --full) || fail "dash-body task read failed"
dash_body=$(printf '%s\n' "$dash_shown" | sed -n 's/^  body: //p' | head -1 | python3 -c 'import json,sys; print(json.load(sys.stdin), end="")') \
  || fail "dash-body task body decode failed"
case "$dash_body" in
  $'-\n\n<!-- firstmate-progress:v1 context='*) ;;
  *) fail "a literal dash task body was discarded by the progress update" ;;
esac
task_cmd 'done' dash-body >/dev/null || fail "dash-body fixture completion failed"

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
assert_grep '<!-- firstmate-progress:v1 context=' "$HOME_DIR/data/backlog.md" \
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

printf '%s\n' 'Authenticated user correction changes the task intent.' > "$HOME_DIR/data/ordinary/brief.md"
out=$(progress update-progress ordinary --expected-token "$token" --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "stale authenticated-intent basis"
assert_contains "$out" "task record changed" "brief correction did not invalidate compact progress authority"
after_intent=$(progress progress ordinary) || fail "progress read after authenticated intent correction failed"
if [ "$(printf '%s' "$after_intent" | jq -r .record_token)" = "$token" ]; then
  fail "authenticated intent correction retained the old progress token"
fi
printf '%s' "$after_intent" | jq -e '
  .recorded==false and .acceptance=="" and .current_state=="" and
  .remaining_gap=="" and .next_step==""' >/dev/null \
  || fail "authenticated intent correction left stale progress active"
corrected_record='{"acceptance":"The corrected task behavior passes","current_state":"The corrected intent is recorded","remaining_gap":"The corrected validation remains","next_step":"Run the corrected validation"}'
corrected=$(progress update-progress ordinary --expected-token "$(printf '%s' "$after_intent" | jq -r .record_token)" \
  --progress "$corrected_record") || fail "corrected intent progress update failed"
printf '%s' "$corrected" | jq -e '.recorded==true and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "MAIN did not reactivate corrected progress"

sed -i 's/^spawn_gen=g1$/spawn_gen=g2/' "$HOME_DIR/state/ordinary.meta"
after_generation=$(progress progress ordinary) || fail "progress read after executor replacement failed"
printf '%s' "$after_generation" | jq -e '
  .recorded==false and .acceptance=="" and .current_state=="" and
  .remaining_gap=="" and .next_step==""' >/dev/null \
  || fail "executor replacement left stale progress active"
regenerated=$(progress update-progress ordinary --expected-token "$(printf '%s' "$after_generation" | jq -r .record_token)" \
  --progress "$corrected_record") || fail "replacement executor progress update failed"
printf '%s' "$regenerated" | jq -e '.recorded==true and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "MAIN did not reactivate replacement executor progress"
token=$(printf '%s' "$regenerated" | jq -r .record_token)

task_cmd hold ordinary --reason "captain decision pending" --kind captain >/dev/null \
  || fail "compact hold fixture failed"
held=$(progress progress ordinary) || fail "held progress read failed"
printf '%s' "$held" | jq -e '
  .task_state=="in_flight" and .task_held=="yes" and .task_blocked=="no" and
  .recorded==false and .remaining_gap=="" and .next_step==""' >/dev/null \
  || fail "an explicit hold left compact continuation authority active"
[ "$(printf '%s' "$held" | jq -r .record_token)" != "$token" ] \
  || fail "an explicit hold retained the old compact authority token"
task_cmd unhold ordinary >/dev/null || fail "compact hold release failed"
released=$(progress progress ordinary) || fail "released progress read failed"
printf '%s' "$released" | jq -e '.task_held=="no" and .task_blocked=="no" and .recorded==true' >/dev/null \
  || fail "releasing the hold did not restore the current MAIN-authored progress"
token=$(printf '%s' "$released" | jq -r .record_token)

task_cmd add progress-blocker "Block the compact fixture" --kind task >/dev/null \
  || fail "compact dependency fixture failed"
task_cmd block ordinary --by progress-blocker >/dev/null || fail "compact block fixture failed"
blocked=$(progress progress ordinary) || fail "blocked progress read failed"
printf '%s' "$blocked" | jq -e '
  .task_state=="in_flight" and .task_held=="no" and .task_blocked=="yes" and
  .recorded==false and .remaining_gap=="" and .next_step==""' >/dev/null \
  || fail "a dependency block left compact continuation authority active"
[ "$(printf '%s' "$blocked" | jq -r .record_token)" != "$token" ] \
  || fail "a dependency block retained the old compact authority token"
task_cmd unblock ordinary --by progress-blocker >/dev/null || fail "compact dependency release failed"
task_cmd "done" progress-blocker >/dev/null || fail "compact dependency cleanup failed"
token=$(progress progress ordinary | jq -r .record_token)

task_cmd add remote "Finish the remote result" --kind scout --body "Keep remote progress resumable." --start >/dev/null \
  || fail "remote fixture task add failed"
mkdir -p "$HOME_DIR/data/remote" "$HOME_DIR/state/remote-tasks/remote"
printf '%s\n' 'Finish the authenticated remote request.' > "$HOME_DIR/data/remote/brief.md"
printf 'kind=scout\nexecutor=remote-agent\nprovider=ida\ntask_type=research\nremote_state=%s\n' \
  "$HOME_DIR/state/remote-tasks/remote" > "$HOME_DIR/state/remote.meta"
jq -n --arg instruction "$HOME_DIR/data/remote/instructions.txt" '{
  schema:"fm-remote-agent-task-state.v1", task_id:"remote", executor:"remote-agent", provider:"ida",
  task_type:"research", phase:"running", generation:1, revision:1, instruction_file:$instruction,
  instruction_sha256:("a" * 64), outcome:null, error_class:null, waiter:"armed",
  result_availability:null, result_path:null, report_path:null, provider_state:{}
}' > "$HOME_DIR/state/remote-tasks/remote/state.json"
chmod 0600 "$HOME_DIR/state/remote.meta" "$HOME_DIR/state/remote-tasks/remote/state.json"
remote_initial=$(progress progress remote) || fail "remote progress read failed"
remote_updated=$(progress update-progress remote --expected-token "$(printf '%s' "$remote_initial" | jq -r .record_token)" \
  --progress "$record") || fail "remote progress update failed"
jq '.generation=2 | .revision+=1' "$HOME_DIR/state/remote-tasks/remote/state.json" > "$HOME_DIR/state/remote-tasks/remote/next.json"
chmod 0600 "$HOME_DIR/state/remote-tasks/remote/next.json"
mv "$HOME_DIR/state/remote-tasks/remote/next.json" "$HOME_DIR/state/remote-tasks/remote/state.json"
remote_replaced=$(progress progress remote) || fail "remote replacement progress read failed"
if [ "$(printf '%s' "$remote_updated" | jq -r .record_token)" = "$(printf '%s' "$remote_replaced" | jq -r .record_token)" ]; then
  fail "remote execution replacement retained the old compact token"
fi
printf '%s' "$remote_replaced" | jq -e '.recorded==false and .next_step==""' >/dev/null \
  || fail "remote execution replacement left stale progress active"

task_cmd add legacy-cloud "Finish the legacy cloud result" --kind scout --body "Keep legacy progress resumable." --start >/dev/null \
  || fail "legacy cloud fixture task add failed"
mkdir -p "$HOME_DIR/data/legacy-cloud" "$HOME_DIR/state/cloud-tasks/legacy-cloud"
printf '%s\n' 'Finish the authenticated legacy cloud request.' > "$HOME_DIR/data/legacy-cloud/brief.md"
printf 'kind=scout\nexecutor=cloud-worker\nprovider=aime\ntask_type=research\ncloud_state=%s\n' \
  "$HOME_DIR/state/cloud-tasks/legacy-cloud" > "$HOME_DIR/state/legacy-cloud.meta"
jq -n --arg instruction "$HOME_DIR/data/legacy-cloud/instructions.txt" '{
  schema:"fm-aime-task-state.v1", task_id:"legacy-cloud", executor:"cloud-worker", provider:"aime",
  execution_generation:"aime-g1", revision:1, phase:"running", site:"sg", space_id:"fixture-space",
  identity:"user", result_mode:"research", instruction_file:$instruction,
  instruction_sha256:("b" * 64), bytedcli_version:"fixture", session_id:null, message_id:null, event_cursor:0
}' > "$HOME_DIR/state/cloud-tasks/legacy-cloud/state.json"
chmod 0600 "$HOME_DIR/state/legacy-cloud.meta" "$HOME_DIR/state/cloud-tasks/legacy-cloud/state.json"
legacy_initial=$(progress progress legacy-cloud) || fail "legacy cloud progress read failed"
legacy_updated=$(progress update-progress legacy-cloud --expected-token "$(printf '%s' "$legacy_initial" | jq -r .record_token)" \
  --progress "$record") || fail "legacy cloud progress update failed"
jq '.execution_generation="aime-g2" | .revision+=1' "$HOME_DIR/state/cloud-tasks/legacy-cloud/state.json" > "$HOME_DIR/state/cloud-tasks/legacy-cloud/next.json"
chmod 0600 "$HOME_DIR/state/cloud-tasks/legacy-cloud/next.json"
mv "$HOME_DIR/state/cloud-tasks/legacy-cloud/next.json" "$HOME_DIR/state/cloud-tasks/legacy-cloud/state.json"
legacy_replaced=$(progress progress legacy-cloud) || fail "legacy cloud replacement progress read failed"
if [ "$(printf '%s' "$legacy_updated" | jq -r .record_token)" = "$(printf '%s' "$legacy_replaced" | jq -r .record_token)" ]; then
  fail "legacy cloud execution replacement retained the old compact token"
fi
printf '%s' "$legacy_replaced" | jq -e '.recorded==false and .next_step==""' >/dev/null \
  || fail "legacy cloud execution replacement left stale progress active"
jq 'del(.execution_generation) | .revision+=1' "$HOME_DIR/state/cloud-tasks/legacy-cloud/state.json" > "$HOME_DIR/state/cloud-tasks/legacy-cloud/next.json"
chmod 0600 "$HOME_DIR/state/cloud-tasks/legacy-cloud/next.json"
mv "$HOME_DIR/state/cloud-tasks/legacy-cloud/next.json" "$HOME_DIR/state/cloud-tasks/legacy-cloud/state.json"
out=$(progress progress legacy-cloud 2>&1)
rc=$?
expect_code 1 "$rc" "legacy cloud missing generation"
assert_contains "$out" "no current cloud execution generation" \
  "legacy cloud progress did not fail closed without an execution generation"
task_cmd "done" remote >/dev/null || fail "remote fixture completion failed"
task_cmd "done" legacy-cloud >/dev/null || fail "legacy cloud fixture completion failed"

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
