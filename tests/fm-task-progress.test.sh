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

# tasks-axi may append structured artifacts in an order different from its
# sorted links field. The stored compact identity must recover the exact
# original title, while a path that was already part of the original title
# must remain ordinary goal text.
task_cmd add artifact-order "Artifact order goal" --kind ship --body "Original body." --start >/dev/null \
  || fail "artifact-order fixture add failed"
mkdir -p "$HOME_DIR/data/artifact-order"
printf '%s\n' 'Artifact-order intent.' >"$HOME_DIR/data/artifact-order/brief.md"
printf '%s\n' 'spawn_gen=artifact-g1' >"$HOME_DIR/state/artifact-order.meta"
artifact_initial=$(progress progress artifact-order) || fail "artifact-order initial read failed"
progress update-progress artifact-order --expected-token "$(printf '%s' "$artifact_initial" | jq -r .record_token)" \
  --progress "$record" >/dev/null || fail "artifact-order progress update failed"
task_cmd update artifact-order --pr https://github.com/example/repo/pull/1 >/dev/null \
  || fail "artifact-order PR link failed"
task_cmd update artifact-order --report data/artifact-order/report.md >/dev/null \
  || fail "artifact-order report link failed"
artifact_read=$(progress progress artifact-order) || fail "artifact-order decorated read failed"
printf '%s' "$artifact_read" | jq -e \
  '.goal=="Artifact order goal" and .recorded==true and .context_relation=="exact"' >/dev/null \
  || fail "artifact order corrupted the original goal identity"

task_cmd add natural-artifact "Natural goal data/natural-artifact/report.md" --kind scout \
  --body "Original body." --start >/dev/null || fail "natural-artifact fixture add failed"
mkdir -p "$HOME_DIR/data/natural-artifact"
printf '%s\n' 'Natural-artifact intent.' >"$HOME_DIR/data/natural-artifact/brief.md"
printf '%s\n' 'spawn_gen=natural-g1' >"$HOME_DIR/state/natural-artifact.meta"
natural_initial=$(progress progress natural-artifact) || fail "natural-artifact initial read failed"
assert_equals "Natural goal data/natural-artifact/report.md" "$(printf '%s' "$natural_initial" | jq -r .goal)" \
  "a genuine artifact-shaped title suffix was removed"
progress update-progress natural-artifact --expected-token "$(printf '%s' "$natural_initial" | jq -r .record_token)" \
  --progress "$record" >/dev/null || fail "natural-artifact progress update failed"
assert_equals "Natural goal data/natural-artifact/report.md" "$(progress progress natural-artifact | jq -r .goal)" \
  "stored identity did not preserve genuine artifact-shaped title text"
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
  .recorded==false and .context_relation=="mismatch" and
  .remaining_gap=="Validation has not passed" and
  .next_step=="Run the authorized validation and review its result"' >/dev/null \
  || fail "authenticated intent correction did not expose stale progress for MAIN-only reconciliation"
corrected_record='{"acceptance":"The corrected task behavior passes","current_state":"The corrected intent is recorded","remaining_gap":"The corrected validation remains","next_step":"Run the corrected validation"}'
corrected=$(progress update-progress ordinary --expected-token "$(printf '%s' "$after_intent" | jq -r .record_token)" \
  --progress "$corrected_record") || fail "corrected intent progress update failed"
printf '%s' "$corrected" | jq -e '.recorded==true and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "MAIN did not reactivate corrected progress"

task_cmd update ordinary --title "Corrected requested outcome" >/dev/null \
  || fail "title-only correction fixture failed"
after_title=$(progress progress ordinary) || fail "progress read after title-only correction failed"
printf '%s' "$after_title" | jq -e '
  .goal=="Corrected requested outcome" and .recorded==false and .context_relation=="mismatch" and
  .remaining_gap=="The corrected validation remains" and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "title-only goal correction did not require MAIN reconciliation"
corrected=$(progress update-progress ordinary --expected-token "$(printf '%s' "$after_title" | jq -r .record_token)" \
  --progress "$corrected_record") || fail "title-corrected progress update failed"

printf '%s\n' 'spawn_gen=g2' >> "$HOME_DIR/state/ordinary.meta"
after_generation=$(progress progress ordinary) || fail "progress read after executor replacement failed"
printf '%s' "$after_generation" | jq -e '
  .recorded==false and .context_relation=="mismatch" and
  .remaining_gap=="The corrected validation remains" and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "executor replacement did not require MAIN reconciliation"
regenerated=$(progress update-progress ordinary --expected-token "$(printf '%s' "$after_generation" | jq -r .record_token)" \
  --progress "$corrected_record") || fail "replacement executor progress update failed"
printf '%s' "$regenerated" | jq -e '.recorded==true and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "MAIN did not reactivate replacement executor progress"
token=$(printf '%s' "$regenerated" | jq -r .record_token)

sed -i '/^spawn_gen=/d' "$HOME_DIR/state/ordinary.meta"
out=$(progress progress ordinary 2>&1)
rc=$?
expect_code 1 "$rc" "missing local execution generation"
assert_contains "$out" "no current local execution generation" \
  "compact progress admitted a local task without exact execution identity"
printf '%s\n' 'spawn_gen=g2' >> "$HOME_DIR/state/ordinary.meta"

task_cmd "done" ordinary >/dev/null || fail "disposition completion fixture failed"
task_cmd reopen ordinary >/dev/null || fail "disposition reopen fixture failed"
queued=$(progress progress ordinary) || fail "queued progress read failed"
printf '%s' "$queued" | jq -e '
  .task_state=="queued" and .recorded==false and .context_relation=="disposition_only" and
  .remaining_gap=="The corrected validation remains" and .next_step=="Run the corrected validation"' >/dev/null \
  || fail "queued task retained in-flight compact progress authority"
[ "$(printf '%s' "$queued" | jq -r .record_token)" != "$token" ] \
  || fail "task disposition change retained the old compact authority token"
out=$(progress update-progress ordinary --expected-token "$token" --progress "$corrected_record" 2>&1)
rc=$?
expect_code 6 "$rc" "stale pre-completion task token"
assert_contains "$out" "task record changed" "queued task accepted stale in-flight progress authority"
task_cmd start ordinary >/dev/null || fail "disposition restart fixture failed"
token=$(progress progress ordinary | jq -r .record_token)

task_cmd hold ordinary --reason "captain decision pending" --kind captain >/dev/null \
  || fail "compact hold fixture failed"
held=$(progress progress ordinary) || fail "held progress read failed"
printf '%s' "$held" | jq -e '
  .task_state=="in_flight" and .task_held=="yes" and .task_blocked=="no" and
  .recorded==false and .context_relation=="disposition_only" and
  .remaining_gap=="The corrected validation remains" and .next_step=="Run the corrected validation"' >/dev/null \
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
  .recorded==false and .context_relation=="disposition_only" and
  .remaining_gap=="The corrected validation remains" and .next_step=="Run the corrected validation"' >/dev/null \
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
printf '%s' "$remote_replaced" | jq -e '.recorded==false and .context_relation=="mismatch" and .next_step!=""' >/dev/null \
  || fail "remote execution replacement did not retain stale progress for MAIN reconciliation"

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
printf '%s' "$legacy_replaced" | jq -e '.recorded==false and .context_relation=="mismatch" and .next_step!=""' >/dev/null \
  || fail "legacy cloud execution replacement did not retain stale progress for MAIN reconciliation"
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

task_cmd update ordinary --body "User corrected the task body while MAIN was working." >/dev/null \
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
assert_equals $'artifact-order\ndash-body\nlegacy-cloud\nnatural-artifact\nordinary\nremote' "$(printf '%s' "$listed" | jq -r '.tasks[]')" \
  "monitoring did not retain Done rows whose compact gaps remain open"

task_cmd add malformed-done "Malformed compact row" --kind ship \
  --body '<!-- firstmate-progress:v1 malformed -->' --start >/dev/null \
  || fail "malformed Done fixture add failed"
task_cmd "done" malformed-done >/dev/null || fail "malformed Done fixture completion failed"
out=$(progress progress-list 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "progress-list silently truncated a malformed Done compact row"
assert_contains "$out" "malformed Firstmate progress block" \
  "progress-list failure did not expose the unreadable Done row"
task_cmd update malformed-done --body "Legacy body without compact progress." >/dev/null \
  || fail "malformed Done fixture repair failed"

mkdir -p "$TMP_ROOT/fakebin"
# shellcheck disable=SC2016 # These variables expand when the generated fixture runs.
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$FM_TIMEOUT_LOG"' \
  'mode=${FM_TIMEOUT_MODE:?}' \
  'shift 3' \
  'case "$mode:${2:-}" in list:list|read:-c|update:update) exit 124 ;; esac' \
  'exec "$@"' > "$TMP_ROOT/fakebin/timeout"
chmod +x "$TMP_ROOT/fakebin/timeout"
export FM_TIMEOUT_LOG="$TMP_ROOT/timeout.log"
: > "$FM_TIMEOUT_LOG"
out=$(FM_TIMEOUT_MODE=list PATH="$TMP_ROOT/fakebin:$PATH" progress progress-list 2>&1)
rc=$?
expect_code 124 "$rc" "bounded progress-list backend read"
assert_grep '-k 10 10 tasks-axi list ' "$FM_TIMEOUT_LOG" \
  "progress-list did not apply its default backend bound"

: > "$FM_TIMEOUT_LOG"
out=$(FM_TIMEOUT_MODE=read PATH="$TMP_ROOT/fakebin:$PATH" progress progress ordinary 2>&1)
rc=$?
expect_code 124 "$rc" "bounded direct progress read"
assert_grep '-k 1 10 bash -c ' "$FM_TIMEOUT_LOG" \
  "progress read did not apply the backlog row backend bound"
assert_grep 'exec tasks-axi show ' "$FM_TIMEOUT_LOG" \
  "progress read did not use the bounded backlog row owner"

: > "$FM_TIMEOUT_LOG"
out=$(FM_TIMEOUT_MODE=update PATH="$TMP_ROOT/fakebin:$PATH" progress update-progress ordinary \
  --expected-token "$(printf '%s' "$complete" | jq -r .record_token)" --progress "$record" 2>&1)
rc=$?
expect_code 1 "$rc" "bounded progress update"
assert_contains "$out" "did not finish within 10s" "progress update did not report its backend bound"
assert_grep '-k 10 10 tasks-axi update ' "$FM_TIMEOUT_LOG" \
  "progress update did not apply its default backend bound"
progress progress ordinary >/dev/null || fail "timed-out progress update retained the metadata lock"

out=$(FM_SUPERVISION_ACTOR=branch progress update-progress ordinary \
  --expected-token "$(printf '%s' "$complete" | jq -r .record_token)" --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "branch progress write"
assert_contains "$out" "task progress belongs to MAIN" "branch update refusal lost ownership reason"

task_cmd "done" ordinary >/dev/null || fail "fixture completion failed"
assert_equals $'artifact-order\ndash-body\nlegacy-cloud\nnatural-artifact\nremote' "$(progress progress-list | jq -r '.tasks[]')" \
  "accepted completion hid or invented open compact gaps"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" bash -c \
  '. "$1"; fm_cleanup_completion_mode ordinary g2' _ "$ROOT/bin/fm-cleanup-receipt-lib.sh" >/dev/null \
  || fail "Done disposition invalidated identity-bound empty compact completion"
printf '%s\n' 'New authenticated intent opens work after the old acceptance.' >"$HOME_DIR/data/ordinary/brief.md"
out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" bash -c \
  '. "$1"; fm_cleanup_completion_mode ordinary g2' _ "$ROOT/bin/fm-cleanup-receipt-lib.sh" 2>&1)
rc=$?
expect_code 6 "$rc" "completion after authenticated intent change"
assert_contains "$out" 'not MAIN-accepted' \
  "raw empty progress bypassed the authenticated intent binding"
mkdir -p "$HOME_DIR/data/historical-terminal"
jq -n '{schema:"fm-task-lifecycle.v2",task_id:"historical-terminal",execution_generation:"legacy-g1",disposition:"archived"}' \
  >"$HOME_DIR/data/historical-terminal/lifecycle.json"
historical_mode=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" bash -c \
  '. "$1"; fm_cleanup_completion_mode historical-terminal legacy-g1' _ "$ROOT/bin/fm-cleanup-receipt-lib.sh") \
  || fail "generation-matched historical terminal fact was not readable"
assert_equals archived "$historical_mode" "historical archived disposition was not selected before field access"
out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" bash -c \
  '. "$1"; fm_task_progress_completion_guard historical-terminal' _ "$ROOT/bin/fm-task-progress-lib.sh" 2>&1)
rc=$?
expect_code 6 "$rc" "missing original row through the ordinary teardown fallback"
assert_contains "$out" 'absent from its configured original-task source' \
  "ordinary teardown treated a missing compact-era row as implicit acceptance"
out=$(progress update-progress ordinary --expected-token "$(printf '%s' "$complete" | jq -r .record_token)" --progress "$record" 2>&1)
rc=$?
expect_code 6 "$rc" "completed task progress update"

pass "task progress: goal/acceptance/state/gap/next step live in the original row with MAIN-only token-checked updates and no unchanged writes"
