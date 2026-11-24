#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-api)
HOME_DIR="$TMP_ROOT/home"
BIN="$TMP_ROOT/bin"
API="$BIN/fm-api.sh"
SNAPSHOT="$TMP_ROOT/snapshot.json"
mkdir -p "$HOME_DIR/projects/demo" "$HOME_DIR/data" "$BIN"
cp "$ROOT/bin/fm-api.sh" "$API"
printf '%s\n' '- demo [local-only] - disposable fixture' > "$HOME_DIR/data/projects.md"

cat > "$BIN/fm-fleet-snapshot.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${FM_API_TEST_SNAPSHOT_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'partial snapshot'
  exit 1
fi
cat "$FM_API_TEST_SNAPSHOT"
STUB
cat > "$BIN/fm-project-mode.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --raw) printf '%s\n' "${FM_API_TEST_POSTURE:-local-only} off" ;;
  --branch-prefix) printf '%s\n' "fm/" ;;
  --forge) printf '%s\n' none ;;
esac
STUB
cat > "$BIN/fm-tasks-axi.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = add ]
id=${FM_API_TEST_TASK_ID:-created001}
title=${2:-}
repo=
body=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --body) body=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$id" >> "$FM_API_TEST_ADD_CALLS"
printf '%s' "$body" > "$FM_API_TEST_LAST_BODY"
jq --arg id "$id" --arg repo "$repo" --arg title "$title" --arg body "$body" \
  '.backlog.records += [{id:$id,structured:true,state:"queued",repo:$repo,title:$title,body_lines:($body|split("\n"))}]' \
  "$FM_API_TEST_SNAPSHOT" > "$FM_API_TEST_SNAPSHOT.tmp"
mv "$FM_API_TEST_SNAPSHOT.tmp" "$FM_API_TEST_SNAPSHOT"
jq -cn --arg id "$id" '{ok:true,task:{id:$id}}'
STUB
cat > "$BIN/fm-brief.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" > "$FM_API_TEST_BRIEF_ARGS"
mkdir -p "$FM_HOME/data/$1"
printf '%s\n' '{TASK}' '{FIRSTMATE_SPEC}' > "$FM_HOME/data/$1/brief.md"
[ "${FM_API_TEST_BRIEF_FAIL:-0}" != 1 ]
STUB
cat > "$BIN/fm-spawn.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_API_TEST_SPAWN_ARGS"
if [ "${FM_API_TEST_HOLD_LOCK_CHILD:-0}" = 1 ]; then
  sleep 30 &
  printf '%s\n' "$!" > "$FM_API_TEST_LOCK_CHILD_PID"
fi
[ "${FM_API_TEST_SPAWN_FAIL:-0}" != 1 ]
STUB
cat > "$BIN/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
[ "${FM_HOME:-}" = "$FM_API_TEST_EXPECT_HOME" ] || exit 1
printf '%s\n' "$*" >> "$FM_API_TEST_SEND_ARGS"
[ "${FM_API_TEST_SEND_FAIL:-0}" != 1 ]
STUB
cat > "$BIN/fm-control.sh" <<'STUB'
#!/usr/bin/env bash
[ "${FM_HOME:-}" = "$FM_API_TEST_EXPECT_HOME" ] || exit 1
printf '%s\n' "$*" >> "$FM_API_TEST_CONTROL_ARGS"
[ "${FM_API_TEST_CONTROL_FAIL:-0}" != 1 ]
STUB
for helper in "$BIN"/*.sh; do
  [ "$helper" = "$API" ] || chmod +x "$helper"
done

export FM_HOME="$HOME_DIR"
export FM_API_OWNER_ID=owner_a
export FM_API_PROJECT_ALLOWLIST=demo
export FM_API_TEST_EXPECT_HOME="$HOME_DIR"
export FM_API_TEST_ADD_CALLS="$TMP_ROOT/tasks.add"
export FM_API_TEST_LAST_BODY="$TMP_ROOT/task.body"
export FM_API_TEST_SNAPSHOT="$SNAPSHOT"
export FM_API_TEST_BRIEF_ARGS="$TMP_ROOT/brief.args"
export FM_API_TEST_SPAWN_ARGS="$TMP_ROOT/spawn.args"
export FM_API_TEST_SEND_ARGS="$TMP_ROOT/send.args"
export FM_API_TEST_CONTROL_ARGS="$TMP_ROOT/control.args"
: > "$FM_API_TEST_ADD_CALLS"
: > "$FM_API_TEST_SPAWN_ARGS"
: > "$FM_API_TEST_SEND_ARGS"
: > "$FM_API_TEST_CONTROL_ARGS"

cat > "$SNAPSHOT" <<'DATA'
{"backlog":{"records":[
  {"id":"owned001","structured":true,"state":"in_flight","repo":"demo","title":"owned task","body_lines":["<!-- fm-api:v1 owner=owner_a request=seed00001 digest=seed -->"]},
  {"id":"foreign001","structured":true,"state":"in_flight","repo":"demo","title":"other session","body_lines":["<!-- fm-api:v1 owner=owner_b request=seed00002 digest=seed -->"]},
  {"id":"working01","structured":true,"state":"in_flight","repo":"demo","title":"working task","body_lines":["<!-- fm-api:v1 owner=owner_a request=seed00005 digest=seed -->"]},
  {"id":"mismatch01","structured":true,"state":"in_flight","repo":"demo","title":"mismatched project","body_lines":["<!-- fm-api:v1 owner=owner_a request=seed00004 digest=seed -->"]},
  {"id":"doneowned","structured":true,"state":"done","repo":"demo","title":"completed","body_lines":["<!-- fm-api:v1 owner=owner_a request=seed00003 digest=seed -->"]}
]},"tasks":[
  {"id":"owned001","project":"demo","kind":"ship","current_state":{"state":"parked","detail":"choose A or B"},"hints":{"pending_decision":true,"open_decisions":[{"key":"choice","verb":"needs-decision","summary":"Choose A or B"}]},"endpoint":{"status":"alive"}},
  {"id":"foreign001","project":"demo","kind":"ship","current_state":{"state":"working","detail":"private work"},"hints":{"pending_decision":false,"open_decisions":[]},"endpoint":{"status":"alive"}},
  {"id":"working01","project":"demo","kind":"ship","current_state":{"state":"working","detail":"continue safe work"},"hints":{"pending_decision":false,"open_decisions":[]},"endpoint":{"status":"alive"}},
  {"id":"mismatch01","project":"unregistered","kind":"ship","current_state":{"state":"working","detail":"wrong project"},"hints":{"pending_decision":false,"open_decisions":[]},"endpoint":{"status":"alive"}},
  {"id":"doneowned","project":"demo","kind":"ship","current_state":{"state":"done","detail":"finished"},"hints":{"pending_decision":false,"open_decisions":[]},"endpoint":{"status":"absent"}}
]}
DATA
jq --arg path "$(cd "$HOME_DIR/projects/demo" && pwd -P)" '(.tasks[] | select(.id == "owned001")).project = $path' \
  "$SNAPSHOT" > "$SNAPSHOT.tmp"
mv "$SNAPSHOT.tmp" "$SNAPSHOT"
mkdir -p "$HOME_DIR/data/owned001"
printf '%s\n' 'canary result' > "$HOME_DIR/data/owned001/report.md"

CREATE=$(jq -cn '{request_id:"create-0001",project:"demo",title:"safe canary",instruction:"Inspect only; preserve quotes and {FIRSTMATE_SPEC}."}')
created=$(printf '%s' "$CREATE" | FM_API_TEST_TASK_ID=created001 "$API" create)
task_id=$(printf '%s\n' "$created" | jq -r .task_id)
[ "$task_id" = created001 ] || fail 'create returns the Firstmate task id'
printf '%s\n' "$created" | jq -e '.created and .state == "working"' >/dev/null \
  || fail 'create reports a new local-only task'
grep -F -- '--mode local-only --yolo off' "$FM_API_TEST_SPAWN_ARGS" >/dev/null \
  || fail 'create fixes execution to local-only with yolo off'
grep -F 'push=false, deploy=false' "$HOME_DIR/data/created001/brief.md" >/dev/null \
  || fail 'the generated brief fixes push and deployment off'
grep -F 'fm-api:v1 owner=owner_a request=create-0001 digest=' "$FM_API_TEST_LAST_BODY" >/dev/null \
  || fail 'ownership and idempotency are recorded in the canonical task body'
pass 'create fixes authority and records owner/request metadata in Firstmate backlog'

add_count=$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')
spawn_count=$(wc -l < "$FM_API_TEST_SPAWN_ARGS" | tr -d '[:space:]')
duplicate=$(printf '%s' "$CREATE" | FM_API_TEST_TASK_ID=other001 "$API" create)
[ "$(printf '%s\n' "$duplicate" | jq -r .task_id)" = "$task_id" ] \
  || fail 'duplicate create returns the original task id'
printf '%s\n' "$duplicate" | jq -e '.reused and (.created == false) and .outcome == "not_retried"' >/dev/null \
  || fail 'duplicate create is observable and does not claim a retry'
[ "$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')" = "$add_count" ] \
  || fail 'duplicate create does not add a second Firstmate task'
[ "$(wc -l < "$FM_API_TEST_SPAWN_ARGS" | tr -d '[:space:]')" = "$spawn_count" ] \
  || fail 'duplicate create does not spawn a second worker'
pass 'same request id is idempotent and never launches twice'

LOCK_CREATE=$(jq -cn '{request_id:"lock-create-0001",project:"demo",title:"lock canary",instruction:"Check create lock lifetime."}')
printf '%s' "$LOCK_CREATE" | env FM_API_TEST_TASK_ID=locktask001 FM_API_TEST_HOLD_LOCK_CHILD=1 \
    FM_API_TEST_LOCK_CHILD_PID="$TMP_ROOT/create-lock-child.pid" "$API" create >/dev/null
lock_child=$(cat "$TMP_ROOT/create-lock-child.pid")
LOCK_CREATE_SECOND=$(jq -cn '{request_id:"lock-create-0002",project:"demo",title:"second lock canary",instruction:"Check lock release."}')
if lock_second=$(printf '%s' "$LOCK_CREATE_SECOND" | env FM_API_TEST_TASK_ID=locktask002 "$API" create 2>/dev/null); then
  kill "$lock_child" 2>/dev/null || true
else
  kill "$lock_child" 2>/dev/null || true
  fail 'detached backend inherited and held the API create lock'
fi
printf '%s\n' "$lock_second" | jq -e '.created and .task_id == "locktask002"' >/dev/null \
  || fail 'a completed create leaves the lock available for another request'
pass 'detached backend cannot retain the serialized create lock'

DUPLICATE_SNAPSHOT=$(jq -c --arg duplicate_id dupe0001 '
  .backlog.records += [
    (.backlog.records[] | select(.id == "created001") | . + {id:$duplicate_id})
  ]' "$SNAPSHOT")
printf '%s\n' "$DUPLICATE_SNAPSHOT" > "$SNAPSHOT"
add_count=$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')
spawn_count=$(wc -l < "$FM_API_TEST_SPAWN_ARGS" | tr -d '[:space:]')
if rejected=$(printf '%s' "$CREATE" | "$API" create 2>/dev/null); then fail 'ambiguous request markers must not select one task'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "create_uncertain" and .task_id == null' >/dev/null \
  || fail 'duplicate request markers are an explicit uncertain result'
[ "$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')" = "$add_count" ] \
  || fail 'ambiguous request markers do not add another task'
[ "$(wc -l < "$FM_API_TEST_SPAWN_ARGS" | tr -d '[:space:]')" = "$spawn_count" ] \
  || fail 'ambiguous request markers do not spawn another worker'
jq ' .backlog.records |= map(select(.id != "dupe0001"))' "$SNAPSHOT" > "$SNAPSHOT.tmp"
mv "$SNAPSHOT.tmp" "$SNAPSHOT"
pass 'duplicate matching markers fail closed without creating or spawning'

SNAPSHOT_VALID="$TMP_ROOT/snapshot.valid"
cp "$SNAPSHOT" "$SNAPSHOT_VALID"
printf '{' > "$SNAPSHOT"
add_count=$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')
if rejected=$(printf '%s' "$CREATE" | "$API" create 2>/dev/null); then fail 'malformed create snapshots must fail closed'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "snapshot_invalid"' >/dev/null \
  || fail 'malformed create snapshots return a structured error'
[ "$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')" = "$add_count" ] \
  || fail 'malformed create snapshots do not create a task'
mv "$SNAPSHOT_VALID" "$SNAPSHOT"
pass 'malformed create snapshots cannot masquerade as an unseen request'

changed=$(printf '%s' "$CREATE" | jq -c '.title = "different payload"')
if rejected=$(printf '%s' "$changed" | "$API" create 2>/dev/null); then fail 'changed payload must conflict with an existing request id'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "idempotency_conflict" and .task_id == "created001"' >/dev/null \
  || fail 'idempotency conflict identifies the same owner task'
pass 'request id cannot be reused with a different payload'

status=$("$API" status owned001)
printf '%s\n' "$status" | jq -e '.task_id == "owned001" and .state == "needs-user" and .needs_user and .open_decisions[0].key == "choice" and .result == "canary result\n"' >/dev/null \
  || fail 'status exposes only the owned task decision and bounded result'
listed=$("$API" list)
printf '%s\n' "$listed" | jq -e '[.tasks[].task_id] | sort == ["owned001","working01"]' >/dev/null \
  || fail 'list filters foreign and terminal tasks'
pass 'status and list are scoped to the configured caller owner'

if rejected=$("$API" status foreign001 2>/dev/null); then fail 'status must hide a task owned by another session'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "not_found" and .task_id == null' >/dev/null \
  || fail 'foreign task status is an opaque not-found result'
if rejected=$("$API" status mismatch01 2>/dev/null); then fail 'status must refuse a task whose snapshot project disagrees with its owned backlog record'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "not_found"' >/dev/null \
  || fail 'project mismatch fails closed'
if rejected=$("$API" steer foreign001 <<'DATA' 2>/dev/null
{"message":"do not deliver"}
DATA
); then fail 'steer must refuse a foreign task'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "not_found"' >/dev/null \
  || fail 'foreign task steer fails before side effects'
if rejected=$("$API" cancel foreign001 2>/dev/null); then fail 'cancel must refuse a foreign task'; fi
[ ! -s "$FM_API_TEST_CONTROL_ARGS" ] || fail 'foreign task cancel did not reach fm-control'
pass 'wrong task ids cannot be read, steered, or cancelled'

decision=$(jq -cn '{message:"Use option B.",resolve_keys:["choice"]}')
steered=$(printf '%s' "$decision" | "$API" steer owned001)
printf '%s\n' "$steered" | jq -e '.accepted and .task_id == "owned001"' >/dev/null \
  || fail 'valid decision steer is accepted for the original id'
grep -F -- 'owned001 --resolve-key choice' "$FM_API_TEST_SEND_ARGS" >/dev/null \
  || fail 'valid key is passed to Firstmate on the same task'
send_count=$(wc -l < "$FM_API_TEST_SEND_ARGS" | tr -d '[:space:]')
stale=$(jq -cn '{message:"answer stale question",resolve_keys:["stale-key"]}')
if rejected=$(printf '%s' "$stale" | "$API" steer owned001 2>/dev/null); then fail 'stale decision key must be refused'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "decision_not_open"' >/dev/null \
  || fail 'stale decision key is a structured refusal'
[ "$(wc -l < "$FM_API_TEST_SEND_ARGS" | tr -d '[:space:]')" = "$send_count" ] \
  || fail 'stale decision key is rejected before sending'
if rejected=$(printf '%s' '{"message":"Use option B."}' | "$API" steer owned001 2>/dev/null); then
  fail 'unkeyed steering must not answer a task with an open decision'
fi
printf '%s\n' "$rejected" | jq -e '.error.code == "decision_key_required"' >/dev/null \
  || fail 'open decision requires its key'
[ "$(wc -l < "$FM_API_TEST_SEND_ARGS" | tr -d '[:space:]')" = "$send_count" ] \
  || fail 'unkeyed decision answer is rejected before sending'
ordinary=$(printf '%s' '{"message":"Continue with the next safe step."}' | "$API" steer working01)
printf '%s\n' "$ordinary" | jq -e '.accepted and .task_id == "working01"' >/dev/null \
  || fail 'ordinary steering remains supported when no decision is open'
pass 'decision answers require a current key while ordinary steering remains available'

cancelled=$("$API" cancel owned001)
printf '%s\n' "$cancelled" | jq -e '.agent_stopped and .task_state_retained and (.semantics | contains("query status"))' >/dev/null \
  || fail 'cancel preserves its verified-exit-only semantics'
pass 'owned cancellation delegates without inventing terminal task state'

for bad in \
  '{"request_id":"authority1","project":"demo","title":"unsafe","instruction":"x","push":true}' \
  '{"request_id":"authority2","project":"demo","title":"unsafe","instruction":"x","authority":{"push":true,"deploy":true}}' \
  '{"request_id":"authority3","project":"demo","title":"unsafe","instruction":"x","mode":"no-mistakes"}'; do
  if rejected=$(printf '%s' "$bad" | "$API" create 2>/dev/null); then fail 'remote authority expansion must be refused'; fi
  printf '%s\n' "$rejected" | jq -e '.error.code == "unsupported_authority"' >/dev/null \
    || fail 'authority refusal is structured'
done
outside=$(printf '%s' "$CREATE" | jq -c '.project="unlisted"')
if rejected=$(printf '%s' "$outside" | "$API" create 2>/dev/null); then fail 'unlisted project must be refused'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "project_not_allowlisted"' >/dev/null \
  || fail 'project allowlist refusal is structured'
if rejected=$(printf '%s' "$CREATE"'{"extra":true}' | "$API" create 2>/dev/null); then fail 'multiple JSON values must be refused'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "invalid_input"' >/dev/null \
  || fail 'multi-value JSON is refused'
if rejected=$(printf '%s' '{' | "$API" create 2>/dev/null); then fail 'malformed JSON must be refused'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "invalid_input"' >/dev/null \
  || fail 'malformed JSON is refused'
pass 'malformed requests, caller authority fields, and unlisted projects fail closed'

PARTIAL=$(jq -cn '{request_id:"partial-0001",project:"demo",title:"partial canary",instruction:"No worker will launch."}')
if partial=$(printf '%s' "$PARTIAL" | FM_API_TEST_TASK_ID=partial001 FM_API_TEST_SPAWN_FAIL=1 "$API" create 2>/dev/null); then fail 'spawn failure must be reported as uncertain'; fi
printf '%s\n' "$partial" | jq -e '.error.code == "create_uncertain" and .task_id == "partial001"' >/dev/null \
  || fail 'partial create returns its task id and uncertainty'
add_count=$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')
spawn_count=$(wc -l < "$FM_API_TEST_SPAWN_ARGS" | tr -d '[:space:]')
reconciled=$(printf '%s' "$PARTIAL" | "$API" create)
printf '%s\n' "$reconciled" | jq -e '.task_id == "partial001" and .reused and .outcome == "not_retried"' >/dev/null \
  || fail 'retry after uncertainty reconciles the same task without respawn'
[ "$(wc -l < "$FM_API_TEST_ADD_CALLS" | tr -d '[:space:]')" = "$add_count" ] \
  || fail 'uncertain retry cannot create a duplicate task'
[ "$(wc -l < "$FM_API_TEST_SPAWN_ARGS" | tr -d '[:space:]')" = "$spawn_count" ] \
  || fail 'uncertain retry cannot relaunch a worker'
partial_status=$("$API" status partial001)
printf '%s\n' "$partial_status" | jq -e '.task_id == "partial001" and .state == "queued" and .endpoint_status == "unknown"' >/dev/null \
  || fail 'status exposes a task when intake succeeded but worker launch was uncertain'
pass 'partial creation is observable and same-key retries do not duplicate work'

if rejected=$(FM_API_TEST_SNAPSHOT_FAIL=1 "$API" list 2>/dev/null); then fail 'snapshot transport failure must fail'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "snapshot_failed"' >/dev/null \
  || fail 'snapshot transport failure is structured'
if rejected=$(FM_API_TEST_CONTROL_FAIL=1 "$API" cancel owned001 2>/dev/null); then fail 'unconfirmed cancellation must fail'; fi
printf '%s\n' "$rejected" | jq -e '.error.code == "cancel_unconfirmed" and .task_id == "owned001"' >/dev/null \
  || fail 'cancel failure identifies the owned task without discarding it'
pass 'snapshot and lifecycle transport failures remain explicit'
