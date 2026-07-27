#!/usr/bin/env bash
# fm-devenv-controller.test.sh - durable queue, pure routing, and split-brain-safe claims.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CONTROLLER="$ROOT/bin/fm-devenv-controller.sh"
TMP_ROOT=$(fm_test_tmproot fm-devenv-controller)
HOME_DIR="$TMP_ROOT/home"
STATE_ROOT="$HOME_DIR/state/devenv"
REGISTRY_FILE="$TMP_ROOT/registry.json"
REMOTE_LOG="$TMP_ROOT/remote.log"
OBSERVE_COUNT="$TMP_ROOT/observe.count"
START_LOG="$TMP_ROOT/start.log"
TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STALE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ISSUED_AT=2026-07-27T12:00:00Z

mkdir -p "$HOME_DIR/state"
printf '%s\n' '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},{"name":"beta","vm":"expanly-beta","slot":2,"frontend_port":5175,"branch":""},{"name":"gamma","vm":"expanly-gamma","slot":3,"frontend_port":5176,"branch":""}]' > "$REGISTRY_FILE"

export FM_HOME="$HOME_DIR"
export FM_DEVENV_REGISTRY="$REGISTRY_FILE"
export FM_DEVENV_EXPANLY_CHECKOUT="$TMP_ROOT/expanly"
export FM_DEVENV_START_ATTEMPTS=2
export FM_DEVENV_START_INTERVAL=0

# shellcheck source=/dev/null
[ ! -f "$CONTROLLER" ] || . "$CONTROLLER"

task_json() {
  jq -cn \
    --arg task_id "$1" \
    --argjson priority "$2" \
    --arg enqueued_at "$3" \
    --argjson previous_environment "${4:-null}" \
    --argjson preferred_environment "${5:-null}" \
    --arg packet_path "data/devenv/tasks/$1/task.json" \
    '{task_id:$task_id,priority:$priority,enqueued_at:$enqueued_at,previous_environment:$previous_environment,preferred_environment:$preferred_environment,packet_path:$packet_path}'
}

registry_json() {
  jq -cn '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},{"name":"beta","vm":"expanly-beta","slot":2,"frontend_port":5175,"branch":""},{"name":"gamma","vm":"expanly-gamma","slot":3,"frontend_port":5176,"branch":""}]'
}

inspection_json() {
  jq -cn \
    --arg name "$1" \
    --arg vm "expanly-$1" \
    --arg lifecycle "${2:-running}" \
    '{
      name:$name,
      vm:$vm,
      lifecycle:$lifecycle,
      reachable:true,
      git:{clean:true},
      local_lease:null,
      remote_lease:null,
      takeover:false,
      quarantined:false,
      pipeline_active:false,
      interactive_attachment:false,
      unknown_checkout_process:false,
      agent_present:false,
      herdr_session_present:false
    }'
}

inspection_set() {
  jq -cn --argjson alpha "$(inspection_json alpha "${1:-running}")" \
    --argjson beta "$(inspection_json beta "${2:-running}")" \
    --argjson gamma "$(inspection_json gamma "${3:-running}")" \
    '[$alpha,$beta,$gamma]'
}

selected_name() {
  printf '%s\n' "$1" | jq -r '.environment'
}

assert_no_capacity() {
  printf '%s\n' "$1" | jq -e \
    '.selected == false and .environment == null and .reason.code == "no_safe_capacity" and (.reason.environments | type == "array")' \
    >/dev/null || fail "$2: expected structured no-capacity result, got $1"
}

reset_controller_state() {
  rm -rf "$STATE_ROOT"
  mkdir -p "$HOME_DIR/state"
  : > "$REMOTE_LOG"
  : > "$START_LOG"
  printf '0\n' > "$OBSERVE_COUNT"
}

test_controller_contract_exists() {
  type fm_devenv_select >/dev/null 2>&1 || fail "fm_devenv_select is missing"
  type fm_devenv_enqueue_json >/dev/null 2>&1 || fail "fm_devenv_enqueue_json is missing"
  type fm_devenv_claim_next >/dev/null 2>&1 || fail "fm_devenv_claim_next is missing"
  type fm_devenv_release_environment >/dev/null 2>&1 || fail "fm_devenv_release_environment is missing"
  pass "devenv controller: public queue, selection, claim, and release functions exist"
}

test_priority_fifo_and_exact_queue_schema() {
  local queue first second third
  reset_controller_state
  fm_devenv_enqueue_json "$(task_json fm-late 0 2026-07-27T12:02:00Z)" || fail "late task enqueue failed"
  fm_devenv_enqueue_json "$(task_json fm-priority 9 2026-07-27T12:03:00Z)" || fail "priority task enqueue failed"
  fm_devenv_enqueue_json "$(task_json fm-early 0 2026-07-27T12:01:00Z)" || fail "early task enqueue failed"
  queue=$(fm_devenv_queue_json) || fail "queue could not be read"
  first=$(printf '%s\n' "$queue" | jq -r '.[0].task_id')
  second=$(printf '%s\n' "$queue" | jq -r '.[1].task_id')
  third=$(printf '%s\n' "$queue" | jq -r '.[2].task_id')
  [ "$first,$second,$third" = fm-priority,fm-early,fm-late ] \
    || fail "queue did not use descending priority then FIFO: $first,$second,$third"
  printf '%s\n' "$queue" | jq -e '
    all(.[ ];
      keys == ["enqueued_at","packet_path","preferred_environment","previous_environment","priority","task_id"]
      and (.task_id | type == "string")
      and (.priority | type == "number" and floor == .)
      and (.enqueued_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (.previous_environment == null)
      and (.preferred_environment == null)
    )' >/dev/null || fail "queue did not preserve the exact task schema"
  [ -f "$STATE_ROOT/queue.json" ] || fail "queue was not published durably"
  [ -z "$(find "$STATE_ROOT" -name '.queue.json.tmp.*' -print -quit)" ] \
    || fail "queue publication leaked a temporary file"
  pass "devenv controller: queue is durable and orders explicit priority before FIFO ties"
}

test_selection_order_and_no_preemption() {
  local registry inspections task result leased
  registry=$(registry_json)
  inspections=$(inspection_set stopped running running)

  task=$(task_json fm-affinity 0 2026-07-27T12:00:00Z '"gamma"')
  result=$(fm_devenv_select "$registry" "$inspections" "$task") || fail "affinity selection failed"
  [ "$(selected_name "$result")" = gamma ] || fail "eligible previous environment did not win affinity"

  task=$(task_json fm-running 0 2026-07-27T12:00:00Z)
  result=$(fm_devenv_select "$registry" "$inspections" "$task") || fail "running selection failed"
  [ "$(selected_name "$result")" = beta ] || fail "running environment did not precede stopped capacity"

  task=$(task_json fm-preferred 0 2026-07-27T12:00:00Z null '"alpha"')
  result=$(fm_devenv_select "$registry" "$inspections" "$task") || fail "preferred selection failed"
  [ "$(selected_name "$result")" = alpha ] || fail "explicit eligible environment preference did not override ordering"

  leased=$(printf '%s\n' "$inspections" | jq -c 'map(if .name == "beta" then .remote_lease = {task_id:"active"} else . end)')
  result=$(fm_devenv_select "$registry" "$leased" "$(task_json fm-urgent 999 2026-07-27T12:00:00Z)") \
    || fail "no-preemption selection failed"
  [ "$(selected_name "$result")" = gamma ] || fail "high priority task preempted an active lease"
  pass "devenv controller: affinity, running preference, explicit preference, and no preemption are deterministic"
}

test_every_unsafe_or_unreadable_observation_queues() {
  local registry task base field value inspections result
  registry=$(registry_json)
  task=$(task_json fm-unsafe 0 2026-07-27T12:00:00Z)
  base=$(inspection_json alpha)
  while IFS='|' read -r field value; do
    inspections=$(printf '%s\n' "$base" | jq -c --arg field "$field" --argjson value "$value" \
      '[. | if $field == "git.clean" then .git.clean = $value else .[$field] = $value end]')
    result=$(fm_devenv_select ' [{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]' "$inspections" "$task") \
      || fail "unsafe $field selection did not return structured output"
    assert_no_capacity "$result" "unsafe $field"
  done <<'CASES'
reachable|false
git.clean|false
local_lease|{"task_id":"local"}
remote_lease|{"task_id":"remote"}
takeover|true
quarantined|true
pipeline_active|true
interactive_attachment|true
unknown_checkout_process|true
agent_present|true
herdr_session_present|true
reachable|null
git.clean|null
pipeline_active|null
interactive_attachment|null
unknown_checkout_process|null
CASES

  inspections=$(printf '%s\n' "$base" | jq -c '[del(.pipeline_active)]')
  result=$(fm_devenv_select '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]' "$inspections" "$task") \
    || fail "missing-field selection did not return structured output"
  assert_no_capacity "$result" "missing inspection field"

  inspections='[{"name":"alpha","vm":"expanly-alpha","git":"unreadable"},"malformed"]'
  result=$(fm_devenv_select '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]' "$inspections" "$task") \
    || fail "wrong-type inspection did not return structured output"
  assert_no_capacity "$result" "wrong-type inspection field"
  pass "devenv controller: unsafe and unreadable SSH, Git, lease, takeover, quarantine, pipeline, attachment, and process observations queue"
}

test_unsafe_explicit_preference_does_not_fall_back() {
  local inspections result
  inspections=$(inspection_set running running running)
  inspections=$(printf '%s\n' "$inspections" | jq -c 'map(if .name == "gamma" then .git.clean = false else . end)')
  result=$(fm_devenv_select "$(registry_json)" "$inspections" "$(task_json fm-pinned 0 2026-07-27T12:00:00Z null '"gamma"')") \
    || fail "unsafe explicit preference did not return structured output"
  assert_no_capacity "$result" "unsafe explicit preference"
  printf '%s\n' "$result" | jq -e '.reason.code == "no_safe_capacity" and .reason.requested_environment == "gamma"' \
    >/dev/null || fail "unsafe explicit preference did not preserve requested environment"
  pass "devenv controller: explicit environment preference overrides order but never safety"
}

TEST_OBSERVATIONS=()

fm_devenv_registry_json() {
  jq -cn '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]'
}

fm_devenv_observe_environment() {
  local count index last
  count=$(cat "$OBSERVE_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$OBSERVE_COUNT"
  index=$((count - 1))
  last=$((${#TEST_OBSERVATIONS[@]} - 1))
  [ "$index" -le "$last" ] || index=$last
  printf '%s\n' "${TEST_OBSERVATIONS[$index]}"
}

fm_backend_devenv_request() {
  local host=$1 request=$2 operation token
  operation=$(printf '%s\n' "$request" | jq -r '.operation')
  token=$(printf '%s\n' "$request" | jq -r '.lease.generation_token // ""')
  printf '%s|%s|%s\n' "$host" "$operation" "$token" >> "$REMOTE_LOG"
  if [ "$operation" = status ] && [ "${FM_TEST_REMOTE_STALE:-0}" = 1 ]; then
    jq -cn --arg request_id "$(printf '%s\n' "$request" | jq -r '.request_id')" \
      '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:false,result:null,error:{code:"stale_token",message:"generation token does not match current lease"}}'
    return 0
  fi
  jq -cn --arg request_id "$(printf '%s\n' "$request" | jq -r '.request_id')" \
    '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:true,result:{lease:null,git:{branch:"fm/fm-example",clean:true},runtime_version:"0123456789012345678901234567890123456789",agent_present:false,herdr_session_present:false},error:null}'
}

fm_devenv_new_token() {
  printf '%s\n' "$TOKEN"
}

make() {
  printf '%s\n' "$*" >> "$START_LOG"
  [ "${FM_TEST_START_FAIL:-0}" != 1 ]
}

sleep() {
  :
}

seed_one_task() {
  fm_devenv_enqueue_json "$(task_json fm-example 0 "$ISSUED_AT")"
}

test_stopped_start_failure_keeps_task_queued() {
  local stopped rc
  reset_controller_state
  stopped=$(inspection_json alpha stopped)
  TEST_OBSERVATIONS=("$stopped")
  seed_one_task || fail "start-failure fixture enqueue failed"
  FM_TEST_START_FAIL=1 fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "stopped VM start failure was accepted"
  [ "$(fm_devenv_queue_json | jq -r '.[0].task_id')" = fm-example ] || fail "start failure removed queued task"
  [ ! -s "$REMOTE_LOG" ] || fail "start failure reached remote claim"
  assert_contains "$(cat "$START_LOG")" "-C $FM_DEVENV_EXPANLY_CHECKOUT devenv-start NAME=alpha" \
    "start did not use configured Expanly checkout and validated environment name"
  pass "devenv controller: stopped-VM start failure preserves the queue without remote mutation"
}

test_claim_reinspects_under_lock_and_publishes_matching_state() {
  local stopped running result marker
  reset_controller_state
  stopped=$(inspection_json alpha stopped)
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$stopped" "$stopped" "$running")
  seed_one_task || fail "claim fixture enqueue failed"
  result=$(fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT") || fail "safe stopped environment could not be claimed"
  marker="$STATE_ROOT/environments/alpha.json"
  printf '%s\n' "$result" | jq -e --arg token "$TOKEN" '.claimed == true and .environment == "alpha" and .generation_token == $token' \
    >/dev/null || fail "claim result did not name the token-bound environment"
  jq -e --arg token "$TOKEN" '
    keys == ["branch","environment","generation_token","issued_at","lease_state","phase","schema","task_id","vm"]
    and .schema == "firstmate.devenv.controller-lease.v1"
    and .generation_token == $token
    and .phase == "control-plane-test"
    and .lease_state == "leased"
    and .task_id == "fm-example"
    and .environment == "alpha"
    and .vm == "expanly-alpha"' "$marker" >/dev/null || fail "Mac lease did not match the exact claimed token and identity"
  [ "$(cat "$OBSERVE_COUNT")" -ge 3 ] || fail "claim did not repeat inspection after selection and start"
  [ "$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")" = 1 ] \
    || fail "claim did not publish exactly one remote lease"
  [ "$(fm_devenv_queue_json | jq 'length')" = 0 ] || fail "successful claim left its task queued"
  [ -z "$(find "$STATE_ROOT" -name '.alpha.json.tmp.*' -print -quit)" ] \
    || fail "Mac lease publication leaked a temporary file"
  pass "devenv controller: claim locks, re-inspects, starts boundedly, and publishes one matching token"
}

test_release_requires_matching_local_and_remote_tokens() {
  local marker before rc
  reset_controller_state
  mkdir -p "$STATE_ROOT/environments"
  marker="$STATE_ROOT/environments/alpha.json"
  jq -cn --arg token "$TOKEN" --arg issued_at "$ISSUED_AT" '{schema:"firstmate.devenv.controller-lease.v1",generation_token:$token,environment:"alpha",vm:"expanly-alpha",task_id:"fm-example",branch:"fm/fm-example",lease_state:"leased",phase:"control-plane-test",issued_at:$issued_at}' > "$marker"
  before=$(cat "$marker")

  fm_devenv_release_environment alpha "$STALE_TOKEN" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "stale Mac token released an environment"
  [ "$(cat "$marker")" = "$before" ] || fail "stale Mac token changed local state"
  [ ! -s "$REMOTE_LOG" ] || fail "stale Mac token reached the remote helper"

  FM_TEST_REMOTE_STALE=1 fm_devenv_release_environment alpha "$TOKEN" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "remote stale-token response was accepted"
  [ "$(cat "$marker")" = "$before" ] || fail "remote token mismatch changed local state"
  [ "$(awk -F'|' '$2 == "release" {count++} END {print count + 0}' "$REMOTE_LOG")" = 0 ] \
    || fail "remote mismatch reached release"

  : > "$REMOTE_LOG"
  fm_devenv_release_environment alpha "$TOKEN" || fail "matching local and remote tokens could not release control-plane lease"
  [ ! -e "$marker" ] || fail "successful release left the Mac lease"
  [ "$(cut -d'|' -f2 "$REMOTE_LOG" | paste -sd, -)" = status,release ] \
    || fail "release did not verify remote token before mutation"
  pass "devenv controller: release requires matching Mac and remote tokens for control-plane leases"
}

test_task_phase_is_not_releasable_in_control_plane() {
  local marker rc
  reset_controller_state
  mkdir -p "$STATE_ROOT/environments"
  marker="$STATE_ROOT/environments/alpha.json"
  jq -cn --arg token "$TOKEN" --arg issued_at "$ISSUED_AT" '{schema:"firstmate.devenv.controller-lease.v1",generation_token:$token,environment:"alpha",vm:"expanly-alpha",task_id:"fm-example",branch:"fm/fm-example",lease_state:"leased",phase:"task",issued_at:$issued_at}' > "$marker"
  fm_devenv_release_environment alpha "$TOKEN" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "task lease was releasable before resident execution"
  [ -f "$marker" ] || fail "task-phase refusal removed local state"
  [ ! -s "$REMOTE_LOG" ] || fail "task-phase refusal reached remote mutation"
  pass "devenv controller: only control-plane-test leases are releasable in this plan"
}

test_publication_failure_retains_remote_lease_and_quarantines() {
  local running rc quarantine
  reset_controller_state
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$running" "$running")
  seed_one_task || fail "publication-failure fixture enqueue failed"
  fm_devenv_publish_local_lease() { return 1; }
  fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "Mac publication failure reported a successful claim"
  [ "$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")" = 1 ] \
    || fail "publication-failure fixture did not first establish the remote lease"
  [ "$(awk -F'|' '$2 == "release" {count++} END {print count + 0}' "$REMOTE_LOG")" = 0 ] \
    || fail "publication failure issued cleanup after losing local publication"
  quarantine="$STATE_ROOT/quarantine/alpha.json"
  jq -e --arg token "$TOKEN" '.lease_state == "quarantined" and .generation_token == $token and .reason == "mac_publication_failed_after_remote_claim"' \
    "$quarantine" >/dev/null || fail "publication failure did not emit a token-bound quarantine record"
  [ "$(fm_devenv_queue_json | jq -r '.[0].task_id')" = fm-example ] || fail "publication failure removed the queued task"
  pass "devenv controller: Mac publication failure retains remote authority and emits token-bound quarantine"
}

test_controller_contract_exists
test_priority_fifo_and_exact_queue_schema
test_selection_order_and_no_preemption
test_every_unsafe_or_unreadable_observation_queues
test_unsafe_explicit_preference_does_not_fall_back
test_stopped_start_failure_keeps_task_queued
test_claim_reinspects_under_lock_and_publishes_matching_state
test_release_requires_matching_local_and_remote_tokens
test_task_phase_is_not_releasable_in_control_plane
test_publication_failure_retains_remote_lease_and_quarantines
