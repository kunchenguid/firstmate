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
REMOTE_PERSISTED="$TMP_ROOT/remote-persisted"
OBSERVE_COUNT="$TMP_ROOT/observe.count"
START_LOG="$TMP_ROOT/start.log"
TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STALE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ISSUED_AT=2026-07-27T12:00:00Z

mkdir -p "$HOME_DIR/state"
printf '%s\n' '{"alpha":{"vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},"beta":{"vm":"expanly-beta","slot":2,"frontend_port":5175,"branch":""},"gamma":{"vm":"expanly-gamma","slot":3,"frontend_port":5176,"branch":""}}' > "$REGISTRY_FILE"

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
  rm -f "$REMOTE_PERSISTED"
  : > "$START_LOG"
  printf '0\n' > "$OBSERVE_COUNT"
  TEST_REGISTRY='[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]'
  unset FM_TEST_CLAIM_TRANSPORT_FAIL FM_TEST_REMOTE_STALE FM_TEST_STATUS_LEASE_JSON FM_TEST_STATUS_LEASE_MISSING
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

  reset_controller_state
  fm_devenv_enqueue_json "$(task_json z-first 4 2026-07-27T12:00:00Z)" || fail "first tie enqueue failed"
  fm_devenv_enqueue_json "$(task_json a-second 4 2026-07-27T12:00:00Z)" || fail "second tie enqueue failed"
  queue=$(fm_devenv_queue_json) || fail "tied queue could not be read"
  [ "$(printf '%s\n' "$queue" | jq -r '[.[].task_id] | join(",")')" = z-first,a-second ] \
    || fail "identical priority and timestamp reordered insertion FIFO: $queue"
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
TEST_REGISTRY='[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""}]'

fm_devenv_registry_json() {
  printf '%s\n' "$TEST_REGISTRY"
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
  local host=$1 request=$2 operation token request_id status_lease
  operation=$(printf '%s\n' "$request" | jq -r '.operation')
  token=$(printf '%s\n' "$request" | jq -r '.lease.generation_token // ""')
  request_id=$(printf '%s\n' "$request" | jq -r '.request_id')
  printf '%s|%s|%s\n' "$host" "$operation" "$token" >> "$REMOTE_LOG"
  if [ "$operation" = claim ] && [ "${FM_TEST_CLAIM_TRANSPORT_FAIL:-0}" = 1 ]; then
    printf '%s\n' "$token" > "$REMOTE_PERSISTED"
    return 1
  fi
  if [ "$operation" = status ] && [ "${FM_TEST_REMOTE_STALE:-0}" = 1 ]; then
    jq -cn --arg request_id "$request_id" \
      '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:false,result:null,error:{code:"stale_token",message:"generation token does not match current lease"}}'
    return 0
  fi
  status_lease=${FM_TEST_STATUS_LEASE_JSON:-'{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/fm-example","lease_state":"leased","issued_at":"2026-07-27T12:00:00Z"}'}
  if [ "$operation" = status ] && [ "${FM_TEST_STATUS_LEASE_MISSING:-0}" = 1 ]; then
    jq -cn --arg request_id "$request_id" \
      '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:true,result:{git:{branch:"fm/fm-example",clean:true},runtime_version:null,agent_present:false,herdr_session_present:false},error:null}'
    return 0
  fi
  if [ "$operation" != status ]; then
    status_lease=null
  fi
  jq -cn --arg request_id "$request_id" --argjson lease "$status_lease" \
    '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:true,result:{lease:$lease,git:{branch:"fm/fm-example",clean:true},runtime_version:"0123456789012345678901234567890123456789",agent_present:false,herdr_session_present:false},error:null}'
}

fm_devenv_new_token() {
  printf '%s\n' "$TOKEN"
}

make() {
  printf '%s\n' "$*" >> "$START_LOG"
  # Real make narrates on stdout; the claim result must stay machine-readable.
  printf 'make: entering directory and running %s\n' "$*"
  [ "${FM_TEST_START_FAIL:-0}" != 1 ]
}

sleep() {
  :
}

seed_one_task() {
  fm_devenv_enqueue_json "$(task_json fm-example 0 "$ISSUED_AT")"
}

seed_local_lease() {
  mkdir -p "$STATE_ROOT/environments" "$STATE_ROOT/tasks"
  jq -cn --arg token "$TOKEN" --arg issued_at "$ISSUED_AT" \
    '{schema:"firstmate.devenv.controller-lease.v1",generation_token:$token,environment:"alpha",vm:"expanly-alpha",task_id:"fm-example",branch:"fm/fm-example",lease_state:"leased",phase:"control-plane-test",issued_at:$issued_at}' \
    > "$STATE_ROOT/environments/alpha.json"
  jq -cn --arg token "$TOKEN" --arg issued_at "$ISSUED_AT" \
    '{schema:"firstmate.devenv.controller-task.v1",generation_token:$token,environment:"alpha",vm:"expanly-alpha",task_id:"fm-example",branch:"fm/fm-example",claim_state:"claimed",reason:null,issued_at:$issued_at}' \
    > "$STATE_ROOT/tasks/fm-example.json"
}

publication_fixture() {
  case "$1" in
    queue)
      printf '[%s]\n' "$(task_json fm-example 0 "$ISSUED_AT")"
      ;;
    task)
      fm_devenv_task_claim_json "$TOKEN" alpha expanly-alpha fm-example fm/fm-example "$ISSUED_AT" claiming ''
      ;;
    environment|quarantine)
      jq -cn --arg token "$TOKEN" --arg issued_at "$ISSUED_AT" \
        '{schema:"firstmate.devenv.controller-lease.v1",generation_token:$token,environment:"alpha",vm:"expanly-alpha",task_id:"fm-example",branch:"fm/fm-example",lease_state:"leased",phase:"control-plane-test",issued_at:$issued_at}'
      ;;
    *) return 2 ;;
  esac
}

publication_destination() {
  case "$1" in
    queue) printf '%s\n' "$FM_DEVENV_QUEUE" ;;
    task) printf '%s\n' "$FM_DEVENV_TASKS/fm-example.json" ;;
    environment) printf '%s\n' "$FM_DEVENV_ENVIRONMENTS/alpha.json" ;;
    quarantine) printf '%s\n' "$FM_DEVENV_QUARANTINE/alpha.json" ;;
    *) return 2 ;;
  esac
}

publish_fixture() {
  local kind=$1 fixture=$2
  case "$kind" in
    queue) fm_devenv_atomic_write "$FM_DEVENV_QUEUE" "$fixture" ;;
    task) fm_devenv_publish_task_claim fm-example "$fixture" ;;
    environment) fm_devenv_publish_local_lease alpha "$fixture" ;;
    quarantine) fm_devenv_publish_quarantine alpha "$fixture" fixture_quarantine ;;
    *) return 2 ;;
  esac
}

publication_expected() {
  local kind=$1 fixture=$2
  if [ "$kind" = quarantine ]; then
    printf '%s\n' "$fixture" | jq -ce \
      '. + {schema:"firstmate.devenv.controller-quarantine.v1",lease_state:"quarantined",reason:"fixture_quarantine"}'
  else
    printf '%s\n' "$fixture"
  fi
}

test_atomic_state_publication_rejects_directories_and_symlink_directories() {
  local kind shape destination target sentinel fixture expected expected_file rc
  for kind in queue task environment quarantine; do
    fixture=$(publication_fixture "$kind") || fail "$kind publication fixture could not be built"
    for shape in directory symlink-directory; do
      reset_controller_state
      destination=$(publication_destination "$kind") || fail "$kind publication destination is missing"
      target="$TMP_ROOT/publication-$kind-$shape"
      rm -rf "$target"
      mkdir -p "$(dirname "$destination")" "$target"
      if [ "$shape" = directory ]; then
        rmdir "$target"
        mkdir -p "$destination"
        target=$destination
      else
        ln -s "$target" "$destination"
      fi
      sentinel="$target/sentinel"
      printf 'preserve\n' > "$sentinel"
      publish_fixture "$kind" "$fixture" >/dev/null 2>&1
      rc=$?
      [ "$rc" -ne 0 ] || fail "$kind publication reported success for a $shape destination"
      [ "$(cat "$sentinel")" = preserve ] || fail "$kind publication changed the preserved $shape object"
      [ -z "$(find "$target" -name '.*.tmp.*' -print -quit)" ] \
        || fail "$kind publication leaked a temporary file inside the $shape destination"
      if [ "$shape" = directory ]; then
        [ -d "$destination" ] && [ ! -L "$destination" ] \
          || fail "$kind publication replaced its directory destination"
      else
        [ -L "$destination" ] || fail "$kind publication replaced its symlink-directory destination"
      fi
    done

    reset_controller_state
    destination=$(publication_destination "$kind") || fail "$kind success destination is missing"
    publish_fixture "$kind" "$fixture" || fail "$kind canonical publication failed"
    [ -f "$destination" ] && [ ! -L "$destination" ] \
      || fail "$kind canonical publication was not a regular non-symlink file"
    expected=$(publication_expected "$kind" "$fixture") || fail "$kind expected bytes could not be built"
    expected_file="$TMP_ROOT/publication-$kind-expected"
    printf '%s\n' "$expected" > "$expected_file"
    cmp -s "$expected_file" "$destination" || fail "$kind canonical publication did not preserve exact bytes"
  done
  pass "devenv controller: queue, task, environment, and quarantine publication rejects directory aliases and verifies canonical bytes"
}

test_atomic_state_publication_cleans_directory_races() {
  local kind shape destination target sentinel fixture rc
  for kind in queue task environment quarantine; do
    fixture=$(publication_fixture "$kind") || fail "$kind race publication fixture could not be built"
    for shape in directory symlink-directory; do
      reset_controller_state
      destination=$(publication_destination "$kind") || fail "$kind race publication destination is missing"
      target="$TMP_ROOT/publication-$kind-raced-$shape"
      rm -rf "$destination" "$target"
      mkdir -p "$(dirname "$destination")"
      if [ "$shape" = symlink-directory ]; then
        mkdir -p "$target"
      else
        target=$destination
      fi
      sentinel="$target/sentinel"
      (
        # shellcheck disable=SC2329
        mv() {
          if [ "$shape" = directory ]; then
            mkdir -p "$destination"
          else
            ln -s "$target" "$destination"
          fi
          printf 'preserve\n' > "$sentinel"
          /bin/mv "$@"
        }
        publish_fixture "$kind" "$fixture" >/dev/null 2>&1
      )
      rc=$?
      [ "$rc" -ne 0 ] || fail "$kind publication reported success when a $shape appeared during rename"
      [ "$(cat "$sentinel")" = preserve ] || fail "$kind publication changed a raced $shape object"
      [ -z "$(find "$target" -name '.*.tmp.*' -print -quit)" ] \
        || fail "$kind publication leaked its moved temporary file inside a raced $shape"
    done
  done
  pass "devenv controller: publication detects directory races through rename and removes moved temporary files"
}

test_task_fence_publication_failure_prevents_remote_claim() {
  local running rc marker
  reset_controller_state
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$running" "$running")
  seed_one_task || fail "task-fence publication fixture enqueue failed"
  marker="$STATE_ROOT/tasks/fm-example.json"
  mkdir -p "$marker"
  printf 'preserve\n' > "$marker/sentinel"
  fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "task-fence directory publication reported a successful claim"
  [ ! -s "$REMOTE_LOG" ] || fail "task-fence publication failure reached remote mutation"
  [ "$(cat "$marker/sentinel")" = preserve ] || fail "task-fence publication failure changed its destination object"
  [ -z "$(find "$marker" -name '.*.tmp.*' -print -quit)" ] \
    || fail "task-fence publication failure leaked a nested temporary file"
  pass "devenv controller: task-fence publication must succeed before remote claim"
}

test_concurrent_claims_serialize_after_queue_head_validation() {
  local first_ready_fifo first_release_fifo second_blocked_fifo first_pid second_pid signal artifacts
  reset_controller_state
  TEST_REGISTRY='[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":""},{"name":"beta","vm":"expanly-beta","slot":2,"frontend_port":5175,"branch":""}]'
  fm_devenv_enqueue_json "$(task_json fm-first 0 "$ISSUED_AT")" || fail "first concurrent task enqueue failed"
  fm_devenv_enqueue_json "$(task_json fm-second 0 "$ISSUED_AT")" || fail "second concurrent task enqueue failed"
  first_ready_fifo="$TMP_ROOT/first-ready.fifo"
  first_release_fifo="$TMP_ROOT/first-release.fifo"
  second_blocked_fifo="$TMP_ROOT/second-blocked.fifo"
  rm -f "$first_ready_fifo" "$first_release_fifo" "$second_blocked_fifo"
  mkfifo "$first_ready_fifo" "$first_release_fifo" "$second_blocked_fifo"
  exec 7<> "$first_ready_fifo"
  exec 8<> "$first_release_fifo"
  exec 9<> "$second_blocked_fifo"

  (
    # shellcheck disable=SC2329
    fm_devenv_task_has_local_fence() {
      printf 'ready\n' > "$first_ready_fifo"
      IFS= read -r -t 5 signal < "$first_release_fifo" || return 0
      [ "$signal" = release ] || return 0
      return 1
    }
    # shellcheck disable=SC2329
    fm_devenv_observe_environment() {
      local row=$1 name marker observation lease
      name=$(printf '%s\n' "$row" | jq -er '.name') || return 1
      observation=$(inspection_json "$name" running) || return 1
      marker="$STATE_ROOT/environments/$name.json"
      if [ -f "$marker" ]; then
        lease=$(jq -ce . "$marker") || return 1
        observation=$(printf '%s\n' "$observation" | jq -ce --argjson lease "$lease" '.local_lease = $lease') || return 1
      fi
      printf '%s\n' "$observation"
    }
    # shellcheck disable=SC2329
    fm_devenv_new_token() { printf '%s\n' "$TOKEN"; }
    fm_devenv_claim_next fm-first fm/fm-first "$ISSUED_AT" > "$TMP_ROOT/first-result" 2> "$TMP_ROOT/first-error"
    printf '%s\n' "$?" > "$TMP_ROOT/first-rc"
  ) &
  first_pid=$!

  IFS= read -r -t 5 signal <&7 || fail "first concurrent claim did not reach its post-head-validation barrier"
  [ "$signal" = ready ] || fail "first concurrent claim emitted an unexpected barrier signal"
  (
    # shellcheck disable=SC2329
    fm_devenv_observe_environment() {
      local row=$1 name marker observation lease
      name=$(printf '%s\n' "$row" | jq -er '.name') || return 1
      observation=$(inspection_json "$name" running) || return 1
      marker="$STATE_ROOT/environments/$name.json"
      if [ -f "$marker" ]; then
        lease=$(jq -ce . "$marker") || return 1
        observation=$(printf '%s\n' "$observation" | jq -ce --argjson lease "$lease" '.local_lease = $lease') || return 1
      fi
      printf '%s\n' "$observation"
    }
    # shellcheck disable=SC2329
    fm_devenv_new_token() { printf '%s\n' "$STALE_TOKEN"; }
    # shellcheck disable=SC2329
    sleep() {
      if [ ! -e "$TMP_ROOT/second-wait-notified" ]; then
        : > "$TMP_ROOT/second-wait-notified"
        printf 'blocked\n' > "$second_blocked_fifo"
      fi
      /bin/sleep "$1"
    }
    FM_DEVENV_LEASE_LOCK_TIMEOUT=5 fm_devenv_claim_next fm-second fm/fm-second "$ISSUED_AT" > "$TMP_ROOT/second-result" 2> "$TMP_ROOT/second-error"
    printf '%s\n' "$?" > "$TMP_ROOT/second-rc"
  ) &
  second_pid=$!

  IFS= read -r -t 5 signal <&9 || fail "second concurrent claim did not block on the held queue lock"
  [ "$signal" = blocked ] || fail "second concurrent claim emitted an unexpected lock signal"
  [ ! -s "$REMOTE_LOG" ] || fail "a concurrent claim reached remote mutation before the first claim resumed"
  printf 'release\n' >&8
  wait "$first_pid"
  wait "$second_pid"
  exec 7>&-
  exec 8>&-
  exec 9>&-

  [ "$(cat "$TMP_ROOT/first-rc")" = 0 ] || fail "first concurrent claim failed: $(cat "$TMP_ROOT/first-error")"
  [ "$(cat "$TMP_ROOT/second-rc")" = 0 ] || fail "second concurrent claim failed: $(cat "$TMP_ROOT/second-error")"
  jq -e '.claimed == true and .environment == "alpha"' "$TMP_ROOT/first-result" >/dev/null \
    || fail "first queue head did not claim alpha"
  jq -e '.claimed == true and .environment == "beta"' "$TMP_ROOT/second-result" >/dev/null \
    || fail "second queue head did not claim beta after serialization"
  [ "$(awk -F'|' '$2 == "claim" {print $3}' "$REMOTE_LOG" | paste -sd, -)" = "$TOKEN,$STALE_TOKEN" ] \
    || fail "concurrent remote claims did not preserve queue order"
  [ "$(awk -F'|' -v token="$TOKEN" '$2 == "claim" && $3 == token {count++} END {print count + 0}' "$REMOTE_LOG")" = 1 ] \
    || fail "first task produced more than one remote lease"
  [ "$(awk -F'|' -v token="$STALE_TOKEN" '$2 == "claim" && $3 == token {count++} END {print count + 0}' "$REMOTE_LOG")" = 1 ] \
    || fail "second task produced more than one remote lease"
  [ "$(fm_devenv_queue_json | jq 'length')" = 0 ] || fail "serialized concurrent claims left queued tasks"
  artifacts=$(find "$STATE_ROOT" \( -name '*.lock' -o -name '*.lock.*' -o -name '.*.tmp.*' \) -print -quit)
  [ -z "$artifacts" ] || fail "serialized concurrent claims leaked a lock or temporary artifact: $artifacts"
  pass "devenv controller: concurrent queue-head claims serialize before remote mutation and preserve one lease per task"
}

test_enqueue_proceeds_while_a_claim_boots_a_stopped_vm() {
  local stopped running start_ready_fifo start_release_fifo claim_pid signal queue
  reset_controller_state
  stopped=$(inspection_json alpha stopped)
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$stopped" "$stopped" "$running")
  fm_devenv_enqueue_json "$(task_json fm-booting 0 "$ISSUED_AT")" || fail "boot fixture enqueue failed"
  start_ready_fifo="$TMP_ROOT/start-ready.fifo"
  start_release_fifo="$TMP_ROOT/start-release.fifo"
  rm -f "$start_ready_fifo" "$start_release_fifo"
  mkfifo "$start_ready_fifo" "$start_release_fifo"
  exec 4<> "$start_ready_fifo"
  exec 5<> "$start_release_fifo"

  (
    # shellcheck disable=SC2329
    make() {
      local released
      printf '%s\n' "$*" >> "$START_LOG"
      printf 'make: entering directory and running %s\n' "$*"
      printf 'starting\n' > "$start_ready_fifo"
      IFS= read -r -t 10 released < "$start_release_fifo" || return 1
      [ "$released" = release ]
    }
    fm_devenv_claim_next fm-booting fm/fm-booting "$ISSUED_AT" > "$TMP_ROOT/boot-result" 2> "$TMP_ROOT/boot-error"
    printf '%s\n' "$?" > "$TMP_ROOT/boot-rc"
  ) &
  claim_pid=$!

  IFS= read -r -t 10 signal <&4 || fail "the claim never reached its stopped-VM start"
  [ "$signal" = starting ] || fail "the claim emitted an unexpected start signal"
  FM_DEVENV_LEASE_LOCK_TIMEOUT=5 fm_devenv_enqueue_json "$(task_json fm-parallel 9 2026-07-27T12:05:00Z)" \
    || fail "enqueue could not finish within its lock timeout while a claim was booting a VM"
  printf 'release\n' >&5
  wait "$claim_pid"
  exec 4>&-
  exec 5>&-

  [ "$(cat "$TMP_ROOT/boot-rc")" = 0 ] || fail "the booting claim failed: $(cat "$TMP_ROOT/boot-error")"
  jq -e --arg token "$TOKEN" '.claimed == true and .environment == "alpha" and .generation_token == $token' \
    "$TMP_ROOT/boot-result" >/dev/null \
    || fail "VM start output polluted the claim result: $(cat "$TMP_ROOT/boot-result")"
  queue=$(fm_devenv_queue_json) || fail "queue became unreadable after the parallel enqueue"
  [ "$(printf '%s\n' "$queue" | jq -r '[.[].task_id] | join(",")')" = fm-parallel ] \
    || fail "the admitted claim did not dequeue exactly its own task: $queue"
  pass "devenv controller: enqueue completes while a claim boots a VM, and the admitted claim still dequeues its own task"
}

test_claim_enforces_durable_queue_head() {
  local running rc queue
  reset_controller_state
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$running" "$running")
  fm_devenv_enqueue_json "$(task_json fm-low 0 2026-07-27T12:00:00Z)" || fail "low-priority fixture enqueue failed"
  fm_devenv_enqueue_json "$(task_json fm-high 10 2026-07-27T12:01:00Z)" || fail "high-priority fixture enqueue failed"
  fm_devenv_claim_next fm-low fm/fm-low "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "direct low-priority claim bypassed the durable queue head"
  [ ! -s "$REMOTE_LOG" ] || fail "out-of-order claim reached remote mutation"
  [ ! -e "$STATE_ROOT/environments/alpha.json" ] || fail "out-of-order claim published a local lease"
  queue=$(fm_devenv_queue_json) || fail "queue became unreadable after out-of-order claim"
  [ "$(printf '%s\n' "$queue" | jq -r '[.[].task_id] | join(",")')" = fm-high,fm-low ] \
    || fail "out-of-order claim changed the durable queue"
  pass "devenv controller: only the durable priority/FIFO queue head may claim capacity"
}

test_stopped_start_failure_keeps_task_queued() {
  local stopped rc
  reset_controller_state
  stopped=$(inspection_json alpha stopped)
  TEST_OBSERVATIONS=("$stopped")
  seed_one_task || fail "start-failure fixture enqueue failed"
  FM_TEST_START_FAIL=1 fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
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
  result=$(fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" 2>/dev/null) \
    || fail "safe stopped environment could not be claimed"
  marker="$STATE_ROOT/environments/alpha.json"
  printf '%s\n' "$result" | jq -e --arg token "$TOKEN" '.claimed == true and .environment == "alpha" and .generation_token == $token' \
    >/dev/null || fail "claim result was not one machine-readable claim object: $result"
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
  marker="$STATE_ROOT/environments/alpha.json"
  seed_local_lease
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
  [ ! -e "$STATE_ROOT/tasks/fm-example.json" ] || fail "successful release left the task claim fence"
  [ "$(cut -d'|' -f2 "$REMOTE_LOG" | paste -sd, -)" = status,release ] \
    || fail "release did not verify remote token before mutation"
  pass "devenv controller: release requires matching Mac and remote tokens for control-plane leases"
}

test_release_requires_exact_remote_lease_identity() {
  local marker before rc label lease
  while IFS='|' read -r label lease; do
    reset_controller_state
    seed_local_lease
    marker="$STATE_ROOT/environments/alpha.json"
    before=$(cat "$marker")
    if [ "$label" = missing ]; then
      FM_TEST_STATUS_LEASE_MISSING=1 fm_devenv_release_environment alpha "$TOKEN" >/dev/null 2>&1
    else
      FM_TEST_STATUS_LEASE_JSON="$lease" fm_devenv_release_environment alpha "$TOKEN" >/dev/null 2>&1
    fi
    rc=$?
    [ "$rc" -ne 0 ] || fail "$label remote status lease was accepted for release"
    [ "$(cat "$marker")" = "$before" ] || fail "$label remote status changed the local lease"
    [ "$(awk -F'|' '$2 == "release" {count++} END {print count + 0}' "$REMOTE_LOG")" = 0 ] \
      || fail "$label remote status reached release mutation"
  done <<'CASES'
missing|unused
null|null
malformed|{"environment":"alpha"}
environment|{"environment":"beta","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/fm-example","lease_state":"leased","issued_at":"2026-07-27T12:00:00Z"}
vm|{"environment":"alpha","vm":"expanly-beta","task_id":"fm-example","branch":"fm/fm-example","lease_state":"leased","issued_at":"2026-07-27T12:00:00Z"}
task|{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-other","branch":"fm/fm-example","lease_state":"leased","issued_at":"2026-07-27T12:00:00Z"}
branch|{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/other","lease_state":"leased","issued_at":"2026-07-27T12:00:00Z"}
issued-at|{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/fm-example","lease_state":"leased","issued_at":"2026-07-27T12:00:01Z"}
takeover|{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/fm-example","lease_state":"takeover","issued_at":"2026-07-27T12:00:00Z"}
quarantined|{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/fm-example","lease_state":"quarantined","issued_at":"2026-07-27T12:00:00Z"}
cooling|{"environment":"alpha","vm":"expanly-alpha","task_id":"fm-example","branch":"fm/fm-example","lease_state":"cooling","issued_at":"2026-07-27T12:00:00Z"}
CASES
  pass "devenv controller: release refuses null, malformed, mismatched, and non-leased remote status"
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

test_claim_scans_orphaned_local_task_fences() {
  local directory marker alpha_blocked beta_running gamma_blocked rc
  for directory in environments quarantine; do
    reset_controller_state
    TEST_REGISTRY=$(registry_json)
    mkdir -p "$STATE_ROOT/$directory"
    marker="$STATE_ROOT/$directory/alpha.json"
    jq -cn --arg token "$TOKEN" --arg issued_at "$ISSUED_AT" \
      --arg schema "firstmate.devenv.controller-${directory}.v1" \
      '{schema:$schema,generation_token:$token,environment:"alpha",vm:"expanly-alpha",task_id:"fm-example",branch:"fm/fm-example",lease_state:"leased",phase:"control-plane-test",issued_at:$issued_at}' \
      > "$marker"
    alpha_blocked=$(inspection_json alpha running | jq -c '.local_lease = {task_id:"fm-example"}')
    beta_running=$(inspection_json beta running)
    gamma_blocked=$(inspection_json gamma running | jq -c '.pipeline_active = true')
    TEST_OBSERVATIONS=("$alpha_blocked" "$beta_running" "$gamma_blocked" "$beta_running")
    seed_one_task || fail "$directory orphan-fence fixture enqueue failed"
    fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "orphaned $directory task fence allowed another claim"
    [ ! -s "$REMOTE_LOG" ] || fail "orphaned $directory task fence reached remote mutation"
  done
  pass "devenv controller: orphaned local leases and quarantines fence the same task before routing"
}

test_ambiguous_remote_claim_fences_task_and_environment() {
  local running rc task_fence quarantine claims
  reset_controller_state
  TEST_REGISTRY=$(registry_json)
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$running" "$(inspection_json beta running)" "$(inspection_json gamma running)" "$running")
  seed_one_task || fail "ambiguous-claim fixture enqueue failed"
  FM_TEST_CLAIM_TRANSPORT_FAIL=1 fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous remote claim reported success"
  [ "$(cat "$REMOTE_PERSISTED")" = "$TOKEN" ] || fail "remote ambiguity fixture did not persist the issued token"
  task_fence="$STATE_ROOT/tasks/fm-example.json"
  quarantine="$STATE_ROOT/quarantine/alpha.json"
  jq -e --arg token "$TOKEN" '.task_id == "fm-example" and .environment == "alpha" and .generation_token == $token and .claim_state == "recovery_required" and .reason == "remote_claim_outcome_unknown"' \
    "$task_fence" >/dev/null || fail "ambiguous claim did not atomically fence the task with its token"
  jq -e --arg token "$TOKEN" '.task_id == "fm-example" and .environment == "alpha" and .generation_token == $token and .lease_state == "quarantined"' \
    "$quarantine" >/dev/null || fail "ambiguous claim did not quarantine the environment with its token"
  claims=$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")
  TEST_OBSERVATIONS=("$(inspection_json beta running)" "$(inspection_json beta running)")
  fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "fenced ambiguous task claimed another environment"
  [ "$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")" = "$claims" ] \
    || fail "fenced ambiguous task issued a second remote claim"
  [ "$(awk -F'|' '$2 == "release" {count++} END {print count + 0}' "$REMOTE_LOG")" = 0 ] \
    || fail "ambiguous claim attempted tokenless cleanup"
  pass "devenv controller: ambiguous remote outcome fences task and environment with the issued token"
}

test_queue_removal_failure_leaves_claim_fenced() {
  local running rc claims task_fence
  reset_controller_state
  TEST_REGISTRY=$(registry_json)
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$running" "$(inspection_json beta running)" "$(inspection_json gamma running)" "$running")
  seed_one_task || fail "queue-removal fixture enqueue failed"
  (
    # shellcheck disable=SC2329
    fm_devenv_queue_remove_unlocked() { return 1; }
    fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" -ne 0 ] || fail "queue-removal failure reported a safely completed claim"
  task_fence="$STATE_ROOT/tasks/fm-example.json"
  jq -e --arg token "$TOKEN" '.claim_state == "recovery_required" and .generation_token == $token and .reason == "queue_removal_failed_after_claim"' \
    "$task_fence" >/dev/null || fail "queue-removal failure did not fence the claimed task"
  claims=$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")
  fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "queue-removal-fenced task was safely retryable"
  [ "$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")" = "$claims" ] \
    || fail "queue-removal-fenced task issued a second remote claim"
  pass "devenv controller: queue-removal failure leaves the claimed task fenced against retry"
}

test_publication_failure_retains_remote_lease_and_quarantines() {
  local running rc quarantine claims task_fence
  reset_controller_state
  TEST_REGISTRY=$(registry_json)
  running=$(inspection_json alpha running)
  TEST_OBSERVATIONS=("$running" "$(inspection_json beta running)" "$(inspection_json gamma running)" "$running")
  seed_one_task || fail "publication-failure fixture enqueue failed"
  (
    # shellcheck disable=SC2329
    fm_devenv_publish_local_lease() { return 1; }
    fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  )
  rc=$?
  [ "$rc" -ne 0 ] || fail "Mac publication failure reported a successful claim"
  [ "$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")" = 1 ] \
    || fail "publication-failure fixture did not first establish the remote lease"
  [ "$(awk -F'|' '$2 == "release" {count++} END {print count + 0}' "$REMOTE_LOG")" = 0 ] \
    || fail "publication failure issued cleanup after losing local publication"
  quarantine="$STATE_ROOT/quarantine/alpha.json"
  jq -e --arg token "$TOKEN" '.lease_state == "quarantined" and .generation_token == $token and .reason == "mac_publication_failed_after_remote_claim"' \
    "$quarantine" >/dev/null || fail "publication failure did not emit a token-bound quarantine record"
  task_fence="$STATE_ROOT/tasks/fm-example.json"
  jq -e --arg token "$TOKEN" '.claim_state == "recovery_required" and .generation_token == $token and .reason == "mac_publication_failed_after_remote_claim"' \
    "$task_fence" >/dev/null || fail "publication failure did not fence the task with its known token"
  [ "$(fm_devenv_queue_json | jq -r '.[0].task_id')" = fm-example ] || fail "publication failure removed the queued task"
  claims=$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")
  fm_devenv_claim_next fm-example fm/fm-example "$ISSUED_AT" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "publication-fenced task claimed another environment"
  [ "$(awk -F'|' '$2 == "claim" {count++} END {print count + 0}' "$REMOTE_LOG")" = "$claims" ] \
    || fail "publication-fenced task issued a second remote claim"
  pass "devenv controller: Mac publication failure retains remote authority and emits token-bound quarantine"
}

test_controller_contract_exists
test_priority_fifo_and_exact_queue_schema
test_atomic_state_publication_rejects_directories_and_symlink_directories
test_atomic_state_publication_cleans_directory_races
test_task_fence_publication_failure_prevents_remote_claim
test_selection_order_and_no_preemption
test_every_unsafe_or_unreadable_observation_queues
test_unsafe_explicit_preference_does_not_fall_back
test_claim_enforces_durable_queue_head
test_enqueue_proceeds_while_a_claim_boots_a_stopped_vm
test_stopped_start_failure_keeps_task_queued
test_claim_reinspects_under_lock_and_publishes_matching_state
test_release_requires_matching_local_and_remote_tokens
test_release_requires_exact_remote_lease_identity
test_task_phase_is_not_releasable_in_control_plane
test_claim_scans_orphaned_local_task_fences
test_ambiguous_remote_claim_fences_task_and_environment
test_queue_removal_failure_leaves_claim_fenced
test_publication_failure_retains_remote_lease_and_quarantines
test_concurrent_claims_serialize_after_queue_head_validation
