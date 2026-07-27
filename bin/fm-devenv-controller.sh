#!/usr/bin/env bash
# fm-devenv-controller.sh - durable queue and safe control-plane claims for Expanly devenvs.
#
# Commands:
#   enqueue <task-id> <packet-path> [priority] [enqueued-at] [previous-environment|-] [preferred-environment|-]
#   queue
#   inspect
#   claim <task-id> <branch> [issued-at]
#   release <environment> <generation-token>
#   status --json
#
# Claims serialize on claim.lock for their whole dispatch, including a VM start.
# queue.lock only covers one atomic queue read or write, so enqueue never waits
# behind a claim that is booting a stopped VM. Because every queue.lock holder is
# that short, and a dead holder is reclaimed, the post-claim dequeue waits for the
# lock instead of timing out: only a real queue fault may strand a live lease.
#
# The normalized observation object consumed by fm_devenv_select has exactly:
# name, vm, lifecycle, reachable, git.clean, local_lease, remote_lease,
# takeover, quarantined, pipeline_active, interactive_attachment,
# unknown_checkout_process, agent_present, and herdr_session_present.
# A missing, null, contradictory, or unsafe fact makes an environment ineligible.

FM_DEVENV_CONTROLLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-devenv-lib.sh
. "$FM_DEVENV_CONTROLLER_DIR/fm-devenv-lib.sh"
# shellcheck source=bin/fm-devenv-lease-lib.sh
. "$FM_DEVENV_CONTROLLER_DIR/fm-devenv-lease-lib.sh"
# shellcheck source=bin/backends/devenv.sh
. "$FM_DEVENV_CONTROLLER_DIR/backends/devenv.sh"

FM_DEVENV_STATE_ROOT="${FM_DEVENV_STATE_ROOT:-${FM_HOME:-$FM_DEVENV_CONTROLLER_DIR/..}/state/devenv}"
FM_DEVENV_QUEUE="$FM_DEVENV_STATE_ROOT/queue.json"
FM_DEVENV_QUEUE_LOCK="$FM_DEVENV_STATE_ROOT/queue.lock"
FM_DEVENV_CLAIM_LOCK="$FM_DEVENV_STATE_ROOT/claim.lock"
FM_DEVENV_ENVIRONMENTS="$FM_DEVENV_STATE_ROOT/environments"
FM_DEVENV_TASKS="$FM_DEVENV_STATE_ROOT/tasks"
FM_DEVENV_LOCKS="$FM_DEVENV_STATE_ROOT/locks"
FM_DEVENV_QUARANTINE="$FM_DEVENV_STATE_ROOT/quarantine"

fm_devenv_controller_error() {
  printf 'fm-devenv-controller: %s\n' "$1" >&2
  return 1
}

fm_devenv_atomic_write() (
  [ "$#" -eq 2 ] || return 2
  local destination=$1 content=$2 directory base temporary temporary_name
  directory=$(dirname "$destination")
  base=$(basename "$destination")
  mkdir -p "$directory" || return 1
  chmod 0700 "$directory" || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  fi
  temporary=$(mktemp "$directory/.${base}.tmp.XXXXXX") || return 1
  temporary_name=$(basename "$temporary") || return 1
  trap '[ -z "$temporary" ] || { rm -f -- "$temporary"; rm -f -- "$destination/$temporary_name" 2>/dev/null || true; }' EXIT
  chmod 0600 "$temporary" || return 1
  printf '%s\n' "$content" > "$temporary" || return 1
  mv -f -- "$temporary" "$destination" || return 1
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  printf '%s\n' "$content" | cmp -s - "$destination" || return 1
  temporary=
)

fm_devenv_queue_validate() {
  jq -ce '
    if (
      type == "array"
      and all(.[];
        type == "object"
        and keys == ["enqueued_at","packet_path","preferred_environment","previous_environment","priority","task_id"]
        and (.task_id | type == "string" and test("^[A-Za-z0-9_-]+$") and length <= 128)
        and (.priority | type == "number" and floor == .)
        and (.enqueued_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and (.previous_environment == null or (.previous_environment | type == "string" and test("^[A-Za-z0-9_-]+$")))
        and (.preferred_environment == null or (.preferred_environment | type == "string" and test("^[A-Za-z0-9_-]+$")))
        and (.packet_path | type == "string" and length > 0 and length <= 1024)
      )
      and ([.[].task_id] | length == (unique | length))
    ) then
      to_entries
      | sort_by([-.value.priority, .value.enqueued_at, .key])
      | map(.value)
    else error("invalid queue") end
  ' 2>/dev/null
}

fm_devenv_queue_json() {
  local queue
  if [ ! -e "$FM_DEVENV_QUEUE" ] && [ ! -L "$FM_DEVENV_QUEUE" ]; then
    printf '[]\n'
    return 0
  fi
  [ -f "$FM_DEVENV_QUEUE" ] && [ -r "$FM_DEVENV_QUEUE" ] || return 1
  queue=$(jq -ce -s 'if length == 1 then .[0] else error("invalid queue") end' "$FM_DEVENV_QUEUE" 2>/dev/null) \
    || return 1
  printf '%s\n' "$queue" | fm_devenv_queue_validate
}

fm_devenv_queue_lock_acquire() {
  mkdir -p "$FM_DEVENV_STATE_ROOT" || return 1
  fm_devenv_lease_lock_acquire "$FM_DEVENV_QUEUE_LOCK"
}

fm_devenv_claim_lock_acquire() {
  mkdir -p "$FM_DEVENV_STATE_ROOT" || return 1
  fm_devenv_lease_lock_acquire "$FM_DEVENV_CLAIM_LOCK"
}

fm_devenv_enqueue_json() (
  [ "$#" -eq 1 ] || return 2
  local task=$1 queue updated lock_held=
  task=$(printf '%s\n' "$task" | jq -ce '
    if (
      type == "object"
      and keys == ["enqueued_at","packet_path","preferred_environment","previous_environment","priority","task_id"]
    ) then . else error("invalid task") end
  ' 2>/dev/null) || { fm_devenv_controller_error 'enqueue requires the exact task record schema'; return 1; }
  printf '[%s]\n' "$task" | fm_devenv_queue_validate >/dev/null \
    || { fm_devenv_controller_error 'enqueue rejected an invalid task field; do not retry unchanged'; return 1; }
  trap '[ -z "$lock_held" ] || fm_lock_release "$FM_DEVENV_QUEUE_LOCK"' EXIT
  fm_devenv_queue_lock_acquire \
    || { fm_devenv_controller_error 'queue lock is busy; retry the enqueue'; return 1; }
  lock_held=1
  queue=$(fm_devenv_queue_json) \
    || { fm_devenv_controller_error "queue is unreadable or invalid; repair $FM_DEVENV_QUEUE"; return 1; }
  updated=$(printf '%s\n' "$queue" | jq -ce --argjson task "$task" '
    if any(.[]; .task_id == $task.task_id) then error("duplicate task") else . + [$task] end
  ' 2>/dev/null) \
    || { fm_devenv_controller_error "task id is already queued; do not retry: $(printf '%s\n' "$task" | jq -r '.task_id')"; return 1; }
  updated=$(printf '%s\n' "$updated" | fm_devenv_queue_validate) \
    || { fm_devenv_controller_error 'enqueue would produce an invalid queue; repair the queue'; return 1; }
  fm_devenv_atomic_write "$FM_DEVENV_QUEUE" "$updated" \
    || { fm_devenv_controller_error "queue publication failed; repair $FM_DEVENV_QUEUE"; return 1; }
)

fm_devenv_queue_remove() (
  [ "$#" -eq 1 ] || return 2
  local task_id=$1 lock_held=
  mkdir -p "$FM_DEVENV_STATE_ROOT" || return 1
  trap '[ -z "$lock_held" ] || fm_lock_release "$FM_DEVENV_QUEUE_LOCK"' EXIT
  fm_lock_acquire_wait "$FM_DEVENV_QUEUE_LOCK"
  lock_held=1
  fm_devenv_queue_remove_unlocked "$task_id"
)

# Removes the exact claimed task. Queue order is enforced when a claim is
# admitted, so a task that was the head at admission stays removable even when a
# higher-priority task is enqueued while its environment boots.
fm_devenv_queue_remove_unlocked() {
  [ "$#" -eq 1 ] || return 2
  local task_id=$1 queue updated
  queue=$(fm_devenv_queue_json) \
    || { fm_devenv_controller_error "queue is unreadable or invalid; repair $FM_DEVENV_QUEUE"; return 1; }
  updated=$(printf '%s\n' "$queue" | jq -ce --arg task_id "$task_id" '
    if any(.[]; .task_id == $task_id) then map(select(.task_id != $task_id)) else error("task is not queued") end
  ' 2>/dev/null) || { fm_devenv_controller_error "task is not queued: $task_id"; return 1; }
  fm_devenv_atomic_write "$FM_DEVENV_QUEUE" "$updated" \
    || { fm_devenv_controller_error "queue publication failed; repair $FM_DEVENV_QUEUE"; return 1; }
}

fm_devenv_select() {
  [ "$#" -eq 3 ] || return 2
  local registry=$1 inspections=$2 task=$3
  jq -cn \
    --argjson registry "$registry" \
    --argjson inspections "$inspections" \
    --argjson task "$task" '
    def observation_shape:
      type == "object"
      and keys == ["agent_present","git","herdr_session_present","interactive_attachment","lifecycle","local_lease","name","pipeline_active","quarantined","reachable","remote_lease","takeover","unknown_checkout_process","vm"]
      and (.git | type == "object" and keys == ["clean"]);
    def observed($object; $path): try ($object | getpath($path)) catch null;
    def reasons($row; $matches):
      if ($matches | length) != 1 then ["unreadable_inspection"]
      else ($matches[0]) as $o
      | [
          if ($o | observation_shape) then empty else "unreadable_inspection" end,
          if observed($o; ["name"]) == $row.name and observed($o; ["vm"]) == $row.vm then empty else "identity_mismatch" end,
          if (observed($o; ["lifecycle"]) == "running" or observed($o; ["lifecycle"]) == "stopped") then empty else "unreadable_lifecycle" end,
          if observed($o; ["reachable"]) == true then empty else "unreachable" end,
          if observed($o; ["git","clean"]) == true then empty else "dirty_or_unreadable_git" end,
          if observed($o; ["local_lease"]) == null then empty else "local_lease" end,
          if observed($o; ["remote_lease"]) == null then empty else "remote_lease" end,
          if observed($o; ["takeover"]) == false then empty else "takeover_or_unreadable" end,
          if observed($o; ["quarantined"]) == false then empty else "quarantine_or_unreadable" end,
          if observed($o; ["pipeline_active"]) == false then empty else "pipeline_or_unreadable" end,
          if observed($o; ["interactive_attachment"]) == false then empty else "attachment_or_unreadable" end,
          if observed($o; ["unknown_checkout_process"]) == false then empty else "checkout_process_or_unreadable" end,
          if observed($o; ["agent_present"]) == false then empty else "agent_or_unreadable" end,
          if observed($o; ["herdr_session_present"]) == false then empty else "herdr_or_unreadable" end
        ] | unique
      end;
    if (
      ($registry | type) == "array"
      and ($inspections | type) == "array"
      and ($task | type) == "object"
      and ($task.preferred_environment == null or ($task.preferred_environment | type) == "string")
      and ($task.previous_environment == null or ($task.previous_environment | type) == "string")
    ) then
      [
        $registry[] as $row
        | [$inspections[] | select(type == "object" and (.name? == $row.name))] as $matches
        | {
            environment:$row.name,
            vm:$row.vm,
            slot:$row.slot,
            lifecycle:(if ($matches | length) == 1 then $matches[0].lifecycle else null end),
            reasons:reasons($row; $matches)
          }
      ] as $evaluated
      | ($evaluated | map(select(.reasons | length == 0))) as $eligible
      | if $task.preferred_environment != null then
          ($eligible | map(select(.environment == $task.preferred_environment))) as $preferred
          | if ($preferred | length) == 1 then
              {selected:true,environment:$preferred[0].environment,reason:null}
            else
              {selected:false,environment:null,reason:{code:"no_safe_capacity",requested_environment:$task.preferred_environment,environments:$evaluated}}
            end
        elif ($eligible | length) > 0 then
          ($eligible
            | sort_by(
                (if $task.previous_environment != null and .environment == $task.previous_environment then 0 elif .lifecycle == "running" then 1 else 2 end),
                .slot,
                .environment
              )
            | .[0]) as $winner
          | {selected:true,environment:$winner.environment,reason:null}
        else
          {selected:false,environment:null,reason:{code:"no_safe_capacity",requested_environment:null,environments:$evaluated}}
        end
    else
      {selected:false,environment:null,reason:{code:"no_safe_capacity",requested_environment:null,environments:[]}}
    end
  '
}

fm_devenv_vm_lifecycle() {
  [ "$#" -eq 1 ] || return 2
  local vm=$1 inventory status
  command -v orb >/dev/null 2>&1 || { printf 'null\n'; return 0; }
  inventory=$(orb list -f json 2>/dev/null) || { printf 'null\n'; return 0; }
  status=$(printf '%s\n' "$inventory" | jq -er --arg vm "$vm" '
    (if type == "array" then . elif (.machines | type) == "array" then .machines else [] end)
    | map(select((.name // .id // "") == $vm))
    | if length == 1 then (.[0].status // .[0].state // null) else null end
  ' 2>/dev/null) || { printf 'null\n'; return 0; }
  case "$status" in
    running|Running) printf 'running\n' ;;
    stopped|Stopped) printf 'stopped\n' ;;
    *) printf 'null\n' ;;
  esac
}

fm_devenv_request_id() {
  local token
  token=$(fm_devenv_new_token) || return 1
  printf '%s\n' "${token:0:32}"
}

fm_devenv_protocol_request() {
  [ "$#" -eq 4 ] || return 2
  local row=$1 operation=$2 lease=$3 payload=$4 request_id
  request_id=$(fm_devenv_request_id) || return 1
  jq -cn \
    --arg request_id "$request_id" \
    --arg operation "$operation" \
    --arg environment "$(printf '%s\n' "$row" | jq -r '.name')" \
    --arg vm "$(printf '%s\n' "$row" | jq -r '.vm')" \
    --argjson lease "$lease" \
    --argjson payload "$payload" \
    '{schema:"firstmate.devenv.v1",request_id:$request_id,operation:$operation,environment:$environment,vm:$vm,lease:$lease,payload:$payload}'
}

fm_devenv_task_claim_validate() {
  jq -ce '
    if (
      type == "object"
      and keys == ["branch","claim_state","environment","generation_token","issued_at","reason","schema","task_id","vm"]
      and .schema == "firstmate.devenv.controller-task.v1"
      and (.generation_token | type == "string" and test("^[0-9a-f]{64}$"))
      and (.environment | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.vm | type == "string" and test("^expanly-[A-Za-z0-9_-]+$"))
      and (.task_id | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.branch | type == "string" and length > 0 and length <= 256)
      and (.claim_state == "claiming" or .claim_state == "claimed" or .claim_state == "recovery_required")
      and (.reason == null or (.reason | type == "string" and length > 0 and length <= 160))
      and (.issued_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ) then . else error("invalid task claim") end
  ' 2>/dev/null
}

fm_devenv_task_claim_json() {
  [ "$#" -eq 8 ] || return 2
  jq -cn \
    --arg token "$1" \
    --arg environment "$2" \
    --arg vm "$3" \
    --arg task_id "$4" \
    --arg branch "$5" \
    --arg issued_at "$6" \
    --arg claim_state "$7" \
    --arg reason "$8" \
    '{
      schema:"firstmate.devenv.controller-task.v1",
      generation_token:$token,
      environment:$environment,
      vm:$vm,
      task_id:$task_id,
      branch:$branch,
      claim_state:$claim_state,
      reason:(if $reason == "" then null else $reason end),
      issued_at:$issued_at
    }'
}

fm_devenv_publish_task_claim() {
  [ "$#" -eq 2 ] || return 2
  local task_id=$1 record=$2
  printf '%s\n' "$record" | fm_devenv_task_claim_validate >/dev/null || return 1
  fm_devenv_atomic_write "$FM_DEVENV_TASKS/$task_id.json" "$record"
}

fm_devenv_task_fence_read() {
  [ "$#" -eq 1 ] || return 2
  local marker="$FM_DEVENV_TASKS/$1.json"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 3
  fi
  [ -f "$marker" ] && [ -r "$marker" ] || return 4
  fm_devenv_task_claim_validate < "$marker" || return 4
}

fm_devenv_task_has_local_fence() {
  [ "$#" -eq 1 ] || return 2
  local task_id=$1 status=0 directory marker record
  fm_devenv_task_fence_read "$task_id" >/dev/null 2>&1 || status=$?
  case "$status" in
    0|4) return 0 ;;
    3) ;;
    *) return 0 ;;
  esac
  for directory in "$FM_DEVENV_ENVIRONMENTS" "$FM_DEVENV_QUARANTINE"; do
    [ -d "$directory" ] || continue
    for marker in "$directory"/*.json; do
      [ -e "$marker" ] || continue
      record=$(jq -ce '
        if type == "object" and (.task_id | type == "string") then . else error("invalid local fence") end
      ' "$marker" 2>/dev/null) || return 0
      [ "$(printf '%s\n' "$record" | jq -r '.task_id')" = "$task_id" ] && return 0
    done
  done
  return 1
}

fm_devenv_task_recovery() {
  [ "$#" -eq 2 ] || return 2
  local task_id=$1 reason=$2 current updated
  current=$(fm_devenv_task_fence_read "$task_id") || return 1
  updated=$(printf '%s\n' "$current" | jq -ce --arg reason "$reason" \
    '.claim_state = "recovery_required" | .reason = $reason') || return 1
  fm_devenv_publish_task_claim "$task_id" "$updated"
}

fm_devenv_environment_task_fence() {
  [ "$#" -eq 1 ] || return 2
  local environment=$1 marker record
  [ -d "$FM_DEVENV_TASKS" ] || return 3
  for marker in "$FM_DEVENV_TASKS"/*.json; do
    [ -e "$marker" ] || continue
    record=$(fm_devenv_task_claim_validate < "$marker") || {
      printf '{"invalid":true}\n'
      return 0
    }
    if [ "$(printf '%s\n' "$record" | jq -r '.environment')" = "$environment" ]; then
      printf '%s\n' "$record"
      return 0
    fi
  done
  return 3
}

fm_devenv_local_record() {
  [ "$#" -eq 1 ] || return 2
  local environment=$1 marker
  marker="$FM_DEVENV_ENVIRONMENTS/$environment.json"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    if fm_devenv_environment_task_fence "$environment"; then
      return 0
    fi
    printf 'null\n'
    return 0
  fi
  [ -f "$marker" ] && [ -r "$marker" ] || { printf '{"invalid":true}\n'; return 0; }
  jq -ce -s 'if length == 1 and (.[0] | type) == "object" then .[0] else {invalid:true} end' "$marker" 2>/dev/null \
    || printf '{"invalid":true}\n'
}

fm_devenv_observe_environment() {
  [ "$#" -eq 1 ] || return 2
  local row=$1 name vm lifecycle local_record quarantine takeover=false quarantined=false
  local request response reachable=false remote_result=null remote_lease=null clean=null
  local agent_present=null herdr_session_present=null interactive_attachment=null
  name=$(printf '%s\n' "$row" | jq -er '.name') || return 1
  vm=$(printf '%s\n' "$row" | jq -er '.vm') || return 1
  lifecycle=$(fm_devenv_vm_lifecycle "$vm") || lifecycle=null
  local_record=$(fm_devenv_local_record "$name") || local_record='{"invalid":true}'
  quarantine="$FM_DEVENV_QUARANTINE/$name.json"
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    quarantined=true
  elif printf '%s\n' "$local_record" | jq -e '.lease_state == "quarantined"' >/dev/null 2>&1; then
    quarantined=true
  fi
  if printf '%s\n' "$local_record" | jq -e '.lease_state == "takeover"' >/dev/null 2>&1; then
    takeover=true
  fi
  if [ "$lifecycle" = running ]; then
    request=$(fm_devenv_protocol_request "$row" inspect null '{}') || request=
    if [ -n "$request" ]; then
      response=$(fm_backend_devenv_request "$vm" "$request" 2>/dev/null) || response=
      if [ -n "$response" ] && printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        reachable=true
        remote_result=$(printf '%s\n' "$response" | jq -c '.result') || remote_result=null
        remote_lease=$(printf '%s\n' "$remote_result" | jq -c '.lease') || remote_lease=null
        clean=$(printf '%s\n' "$remote_result" | jq -c '.git.clean') || clean=null
        agent_present=$(printf '%s\n' "$remote_result" | jq -c '.agent_present') || agent_present=null
        herdr_session_present=$(printf '%s\n' "$remote_result" | jq -c '.herdr_session_present') || herdr_session_present=null
        if [ "$herdr_session_present" = true ]; then
          interactive_attachment=true
        fi
      fi
    fi
  elif [ "$lifecycle" = stopped ]; then
    reachable=true
  fi
  jq -cn \
    --arg name "$name" \
    --arg vm "$vm" \
    --argjson lifecycle "$(if [ "$lifecycle" = null ]; then printf 'null'; else jq -Rn --arg value "$lifecycle" '$value'; fi)" \
    --argjson reachable "$reachable" \
    --argjson clean "$clean" \
    --argjson local_lease "$local_record" \
    --argjson remote_lease "$remote_lease" \
    --argjson takeover "$takeover" \
    --argjson quarantined "$quarantined" \
    --argjson interactive_attachment "$interactive_attachment" \
    --argjson agent_present "$agent_present" \
    --argjson herdr_session_present "$herdr_session_present" \
    '{
      name:$name,
      vm:$vm,
      lifecycle:$lifecycle,
      reachable:$reachable,
      git:{clean:$clean},
      local_lease:$local_lease,
      remote_lease:$remote_lease,
      takeover:$takeover,
      quarantined:$quarantined,
      pipeline_active:null,
      interactive_attachment:$interactive_attachment,
      unknown_checkout_process:null,
      agent_present:$agent_present,
      herdr_session_present:$herdr_session_present
    }'
}

fm_devenv_inspect_all() {
  [ "$#" -eq 1 ] || return 2
  local registry=$1 inspections='[]' row observation
  while IFS= read -r row; do
    observation=$(fm_devenv_observe_environment "$row") || observation=
    if [ -z "$observation" ]; then
      observation=$(printf '%s\n' "$row" | jq -c '{name:.name,vm:.vm,lifecycle:null,reachable:null,git:{clean:null},local_lease:null,remote_lease:null,takeover:null,quarantined:null,pipeline_active:null,interactive_attachment:null,unknown_checkout_process:null,agent_present:null,herdr_session_present:null}') \
        || return 1
    fi
    inspections=$(printf '%s\n' "$inspections" | jq -c --argjson observation "$observation" '. + [$observation]') \
      || return 1
  done < <(printf '%s\n' "$registry" | jq -c '.[]')
  printf '%s\n' "$inspections"
}

fm_devenv_controller_lease_validate() {
  jq -ce '
    if (
      type == "object"
      and keys == ["branch","environment","generation_token","issued_at","lease_state","phase","schema","task_id","vm"]
      and .schema == "firstmate.devenv.controller-lease.v1"
      and (.generation_token | type == "string" and test("^[0-9a-f]{64}$"))
      and (.environment | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.vm | type == "string" and test("^expanly-[A-Za-z0-9_-]+$"))
      and (.task_id | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.branch | type == "string" and length > 0 and length <= 256)
      and .lease_state == "leased"
      and (.phase == "control-plane-test" or .phase == "task")
      and (.issued_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ) then . else error("invalid controller lease") end
  ' 2>/dev/null
}

fm_devenv_publish_local_lease() {
  [ "$#" -eq 2 ] || return 2
  local environment=$1 lease=$2
  printf '%s\n' "$lease" | fm_devenv_controller_lease_validate >/dev/null || return 1
  fm_devenv_atomic_write "$FM_DEVENV_ENVIRONMENTS/$environment.json" "$lease"
}

fm_devenv_publish_quarantine() {
  [ "$#" -eq 3 ] || return 2
  local environment=$1 lease=$2 reason=$3 record
  record=$(printf '%s\n' "$lease" | jq -ce --arg reason "$reason" '
    . + {schema:"firstmate.devenv.controller-quarantine.v1",lease_state:"quarantined",reason:$reason}
  ') || return 1
  fm_devenv_atomic_write "$FM_DEVENV_QUARANTINE/$environment.json" "$record"
}

fm_devenv_claim_recovery() {
  [ "$#" -eq 4 ] || return 2
  local environment=$1 task_id=$2 lease=$3 reason=$4 status=0
  fm_devenv_task_recovery "$task_id" "$reason" || status=1
  fm_devenv_publish_quarantine "$environment" "$lease" "$reason" || status=1
  [ "$status" -eq 0 ] || printf '%s\n' "$lease" | jq -c \
    --arg reason "$reason" '. + {lease_state:"quarantined",reason:$reason}' >&2
  return "$status"
}

fm_devenv_inspection_selects_environment() {
  [ "$#" -eq 3 ] || return 2
  local row=$1 observation=$2 task=$3 result
  result=$(fm_devenv_select "[$row]" "[$observation]" "$task") || return 1
  printf '%s\n' "$result" | jq -e '.selected == true' >/dev/null 2>&1
}

fm_devenv_claim_environment() (
  [ "$#" -eq 4 ] || return 2
  local row=$1 task=$2 branch=$3 issued_at=$4
  local environment vm lock lock_held='' observation lifecycle attempts checkout token remote_lease
  local request response local_lease task_id task_claim claimed_record
  environment=$(printf '%s\n' "$row" | jq -er '.name') || return 1
  vm=$(printf '%s\n' "$row" | jq -er '.vm') || return 1
  fm_devenv_name_valid "$environment" || { fm_devenv_controller_error "invalid environment name: $environment"; return 1; }
  fm_devenv_vm_valid "$vm" || { fm_devenv_controller_error "invalid VM name: $vm"; return 1; }
  mkdir -p "$FM_DEVENV_LOCKS" || return 1
  lock="$FM_DEVENV_LOCKS/$environment.lock"
  trap '[ -z "$lock_held" ] || fm_lock_release "$lock"' EXIT
  fm_devenv_lease_lock_acquire "$lock" \
    || { fm_devenv_controller_error "environment lock is busy; retry: $environment"; return 1; }
  lock_held=1

  observation=$(fm_devenv_observe_environment "$row") \
    || { fm_devenv_controller_error "could not observe environment: $environment"; return 1; }
  lifecycle=$(printf '%s\n' "$observation" | jq -er '.lifecycle') \
    || { fm_devenv_controller_error "environment lifecycle is unreadable: $environment"; return 1; }
  if [ "$lifecycle" = stopped ]; then
    fm_devenv_inspection_selects_environment "$row" "$observation" "$task" \
      || { fm_devenv_controller_error "environment became ineligible under its lock: $environment"; return 1; }
    checkout=${FM_DEVENV_EXPANLY_CHECKOUT:-}
    [ -n "$checkout" ] && [ "${checkout#/}" != "$checkout" ] \
      || { fm_devenv_controller_error 'FM_DEVENV_EXPANLY_CHECKOUT must be an absolute path to start a stopped VM'; return 1; }
    # Start output is diagnostic, so it must not reach the machine-readable claim result.
    make -C "$checkout" devenv-start "NAME=$environment" >&2 \
      || { fm_devenv_controller_error "devenv-start failed for $environment; see the start output above"; return 1; }
    attempts=${FM_DEVENV_START_ATTEMPTS:-12}
    case "$attempts" in
      ''|*[!0-9]*|0) fm_devenv_controller_error "invalid FM_DEVENV_START_ATTEMPTS: $attempts"; return 1 ;;
    esac
    while [ "$attempts" -gt 0 ]; do
      observation=$(fm_devenv_observe_environment "$row") || observation=
      if [ -n "$observation" ] \
        && [ "$(printf '%s\n' "$observation" | jq -r '.lifecycle // ""')" = running ] \
        && fm_devenv_inspection_selects_environment "$row" "$observation" "$task"; then
        break
      fi
      attempts=$((attempts - 1))
      if [ "$attempts" -le 0 ]; then
        fm_devenv_controller_error "$environment did not become safely running within the start budget"
        return 1
      fi
      sleep "${FM_DEVENV_START_INTERVAL:-5}"
    done
  else
    [ "$lifecycle" = running ] \
      || { fm_devenv_controller_error "environment is neither running nor stopped: $environment"; return 1; }
    fm_devenv_inspection_selects_environment "$row" "$observation" "$task" \
      || { fm_devenv_controller_error "environment became ineligible under its lock: $environment"; return 1; }
  fi

  token=$(fm_devenv_new_token) || return 1
  task_id=$(printf '%s\n' "$task" | jq -r '.task_id') || return 1
  local_lease=$(jq -cn \
    --arg token "$token" \
    --arg environment "$environment" \
    --arg vm "$vm" \
    --arg task_id "$task_id" \
    --arg branch "$branch" \
    --arg issued_at "$issued_at" \
    '{schema:"firstmate.devenv.controller-lease.v1",generation_token:$token,environment:$environment,vm:$vm,task_id:$task_id,branch:$branch,lease_state:"leased",phase:"control-plane-test",issued_at:$issued_at}') \
    || return 1
  printf '%s\n' "$local_lease" | fm_devenv_controller_lease_validate >/dev/null || return 1
  task_claim=$(fm_devenv_task_claim_json \
    "$token" "$environment" "$vm" "$task_id" "$branch" "$issued_at" claiming '') || return 1
  fm_devenv_publish_task_claim "$task_id" "$task_claim" \
    || { fm_devenv_controller_error "could not publish the task claim fence for $task_id; no remote claim was issued"; return 1; }
  remote_lease=$(printf '%s\n' "$local_lease" | jq -c 'del(.phase) | .schema = "firstmate.devenv.lease.v1"') \
    || return 1
  request=$(fm_devenv_protocol_request "$row" claim "$remote_lease" '{}') || {
    fm_devenv_claim_recovery "$environment" "$task_id" "$local_lease" remote_claim_outcome_unknown || true
    fm_devenv_controller_error "could not build the remote claim for $environment; $task_id needs recovery"
    return 1
  }
  response=$(fm_backend_devenv_request "$vm" "$request") || {
    fm_devenv_claim_recovery "$environment" "$task_id" "$local_lease" remote_claim_outcome_unknown || true
    fm_devenv_controller_error "remote claim outcome is unknown for $environment; $task_id needs recovery"
    return 1
  }
  if ! printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    fm_devenv_claim_recovery "$environment" "$task_id" "$local_lease" remote_claim_outcome_unknown || true
    fm_devenv_controller_error "remote refused the claim for $environment; $task_id needs recovery"
    return 1
  fi
  if ! fm_devenv_publish_local_lease "$environment" "$local_lease"; then
    fm_devenv_claim_recovery "$environment" "$task_id" "$local_lease" mac_publication_failed_after_remote_claim || true
    fm_devenv_controller_error "the remote lease for $environment survived a failed Mac publication; $task_id needs recovery"
    return 1
  fi
  claimed_record=$(printf '%s\n' "$task_claim" | jq -ce '.claim_state = "claimed"') || return 1
  fm_devenv_publish_task_claim "$task_id" "$claimed_record" || return 1
  jq -cn --arg environment "$environment" --arg token "$token" \
    '{claimed:true,environment:$environment,generation_token:$token}'
)

fm_devenv_claim_next() (
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || return 2
  local task_id=$1 branch=$2 issued_at=${3:-} registry queue task inspections selection environment row
  local claim_lock_held='' queue_lock_held='' claim_result
  fm_devenv_name_valid "$task_id" || { fm_devenv_controller_error "invalid task id: $task_id"; return 1; }
  [ -n "$branch" ] && [ "${#branch}" -le 256 ] \
    || { fm_devenv_controller_error 'branch must be between 1 and 256 characters'; return 1; }
  if [ -z "$issued_at" ]; then
    issued_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  fi
  trap '[ -z "$queue_lock_held" ] || fm_lock_release "$FM_DEVENV_QUEUE_LOCK"; [ -z "$claim_lock_held" ] || fm_lock_release "$FM_DEVENV_CLAIM_LOCK"' EXIT
  fm_devenv_claim_lock_acquire \
    || { fm_devenv_controller_error 'another claim holds the dispatch lock; retry once it finishes'; return 1; }
  claim_lock_held=1
  fm_devenv_queue_lock_acquire \
    || { fm_devenv_controller_error 'queue lock is busy; retry the claim'; return 1; }
  queue_lock_held=1
  queue=$(fm_devenv_queue_json) \
    || { fm_devenv_controller_error "queue is unreadable or invalid; repair $FM_DEVENV_QUEUE"; return 1; }
  task=$(printf '%s\n' "$queue" | jq -ce --arg task_id "$task_id" '
    if length > 0 and .[0].task_id == $task_id then .[0] else error("task is not queue head") end
  ' 2>/dev/null) || { fm_devenv_controller_error "task is not the durable queue head: $task_id"; return 1; }
  fm_lock_release "$FM_DEVENV_QUEUE_LOCK"
  queue_lock_held=''
  ! fm_devenv_task_has_local_fence "$task_id" \
    || { fm_devenv_controller_error "task already has a local claim fence and needs recovery: $task_id"; return 1; }
  # shellcheck disable=SC2119
  registry=$(fm_devenv_registry_json "$(fm_devenv_registry_path)") \
    || { fm_devenv_controller_error "environment registry is unreadable or invalid: $(fm_devenv_registry_path)"; return 1; }
  inspections=$(fm_devenv_inspect_all "$registry") \
    || { fm_devenv_controller_error 'fleet inspection failed; no environment was claimed'; return 1; }
  selection=$(fm_devenv_select "$registry" "$inspections" "$task") \
    || { fm_devenv_controller_error 'environment selection failed'; return 1; }
  environment=$(printf '%s\n' "$selection" | jq -r '.environment // ""') || return 1
  if [ -z "$environment" ]; then
    printf '%s\n' "$selection"
    return 3
  fi
  row=$(printf '%s\n' "$registry" | jq -ce --arg environment "$environment" '.[] | select(.name == $environment)') \
    || return 1
  claim_result=$(fm_devenv_claim_environment "$row" "$task" "$branch" "$issued_at") || return 1
  if ! fm_devenv_queue_remove "$task_id"; then
    fm_devenv_task_recovery "$task_id" queue_removal_failed_after_claim || true
    fm_devenv_controller_error "$environment is claimed but $task_id could not be dequeued; it needs recovery"
    return 1
  fi
  printf '%s\n' "$claim_result"
)

fm_devenv_release_environment() (
  [ "$#" -eq 2 ] || return 2
  local environment=$1 token=$2 registry row marker task_marker task_record='' lock lock_held='' before current request response
  fm_devenv_name_valid "$environment" || { fm_devenv_controller_error "invalid environment name: $environment"; return 1; }
  printf '%s\n' "$token" | grep -Eq '^[0-9a-f]{64}$' \
    || { fm_devenv_controller_error 'release requires one 64-character hexadecimal generation token'; return 1; }
  # shellcheck disable=SC2119
  registry=$(fm_devenv_registry_json "$(fm_devenv_registry_path)") \
    || { fm_devenv_controller_error "environment registry is unreadable or invalid: $(fm_devenv_registry_path)"; return 1; }
  row=$(printf '%s\n' "$registry" | jq -ce --arg environment "$environment" '.[] | select(.name == $environment)') \
    || { fm_devenv_controller_error "environment is not registered: $environment"; return 1; }
  marker="$FM_DEVENV_ENVIRONMENTS/$environment.json"
  mkdir -p "$FM_DEVENV_LOCKS" || return 1
  lock="$FM_DEVENV_LOCKS/$environment.lock"
  trap '[ -z "$lock_held" ] || fm_lock_release "$lock"' EXIT
  fm_devenv_lease_lock_acquire "$lock" \
    || { fm_devenv_controller_error "environment lock is busy; retry: $environment"; return 1; }
  lock_held=1
  before=$(cat "$marker" 2>/dev/null | fm_devenv_controller_lease_validate) \
    || { fm_devenv_controller_error "no valid Mac lease to release for $environment"; return 1; }
  printf '%s\n' "$before" | jq -e --arg token "$token" --arg environment "$environment" \
    '.generation_token == $token and .phase == "control-plane-test" and .environment == $environment' \
    >/dev/null 2>&1 \
    || { fm_devenv_controller_error "the Mac lease for $environment is not a control-plane-test lease held by this token"; return 1; }
  task_marker="$FM_DEVENV_TASKS/$(printf '%s\n' "$before" | jq -r '.task_id').json"
  if [ -e "$task_marker" ] || [ -L "$task_marker" ]; then
    task_record=$(fm_devenv_task_claim_validate < "$task_marker") \
      || { fm_devenv_controller_error "the task claim fence for $environment is unreadable or invalid"; return 1; }
    printf '%s\n' "$task_record" | jq -e --argjson local "$before" '
      .generation_token == $local.generation_token
      and .environment == $local.environment
      and .vm == $local.vm
      and .task_id == $local.task_id
      and .branch == $local.branch
      and .issued_at == $local.issued_at
      and .claim_state == "claimed"
    ' >/dev/null 2>&1 \
      || { fm_devenv_controller_error "the task claim fence does not match the Mac lease for $environment"; return 1; }
  fi
  request=$(fm_devenv_protocol_request "$row" status "$(jq -cn --arg token "$token" '{generation_token:$token}')" '{}') \
    || return 1
  response=$(fm_backend_devenv_request "$(printf '%s\n' "$row" | jq -r '.vm')" "$request") \
    || { fm_devenv_controller_error "could not read remote lease status for $environment; nothing was released"; return 1; }
  printf '%s\n' "$response" | jq -e --argjson local "$before" '
    .ok == true
    and (.result | type == "object")
    and (.result.lease | type == "object")
    and (.result.lease | keys == ["branch","environment","issued_at","lease_state","task_id","vm"])
    and .result.lease.environment == $local.environment
    and .result.lease.vm == $local.vm
    and .result.lease.task_id == $local.task_id
    and .result.lease.branch == $local.branch
    and .result.lease.issued_at == $local.issued_at
    and .result.lease.lease_state == "leased"
  ' >/dev/null 2>&1 \
    || { fm_devenv_controller_error "the remote lease for $environment does not match this Mac lease; nothing was released"; return 1; }
  current=$(cat "$marker" 2>/dev/null | fm_devenv_controller_lease_validate) || return 1
  [ "$current" = "$before" ] \
    || { fm_devenv_controller_error "the Mac lease for $environment changed during release"; return 1; }
  request=$(fm_devenv_protocol_request "$row" release "$(jq -cn --arg token "$token" '{generation_token:$token}')" '{}') \
    || return 1
  response=$(fm_backend_devenv_request "$(printf '%s\n' "$row" | jq -r '.vm')" "$request") \
    || { fm_devenv_controller_error "remote release outcome is unknown for $environment; re-run release with the same token"; return 1; }
  printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null 2>&1 \
    || { fm_devenv_controller_error "remote refused the release for $environment"; return 1; }
  [ "$(cat "$marker" 2>/dev/null)" = "$before" ] \
    || { fm_devenv_controller_error "the Mac lease for $environment changed after the remote release"; return 1; }
  if [ -n "$task_record" ]; then
    [ "$(cat "$task_marker" 2>/dev/null)" = "$task_record" ] \
      || { fm_devenv_controller_error "the task claim fence for $environment changed after the remote release"; return 1; }
    rm -f -- "$task_marker" || return 1
  fi
  rm -f -- "$marker" || return 1
  [ ! -e "$marker" ] && [ ! -L "$marker" ]
)

fm_devenv_status_json() {
  local registry inspections queue environment_records quarantine_records
  # shellcheck disable=SC2119
  registry=$(fm_devenv_registry_json "$(fm_devenv_registry_path)") \
    || { fm_devenv_controller_error "environment registry is unreadable or invalid: $(fm_devenv_registry_path)"; return 1; }
  inspections=$(fm_devenv_inspect_all "$registry") \
    || { fm_devenv_controller_error 'fleet inspection failed; status is incomplete'; return 1; }
  queue=$(fm_devenv_queue_json) \
    || { fm_devenv_controller_error "queue is unreadable or invalid; repair $FM_DEVENV_QUEUE"; return 1; }
  environment_records=$(find "$FM_DEVENV_ENVIRONMENTS" -maxdepth 1 -type f -name '*.json' -exec jq -c . {} \; 2>/dev/null | jq -sc '.') \
    || environment_records='[]'
  quarantine_records=$(find "$FM_DEVENV_QUARANTINE" -maxdepth 1 -type f -name '*.json' -exec jq -c . {} \; 2>/dev/null | jq -sc '.') \
    || quarantine_records='[]'
  jq -cn \
    --argjson queue "$queue" \
    --argjson inspections "$inspections" \
    --argjson environments "$environment_records" \
    --argjson quarantines "$quarantine_records" \
    '{schema:"firstmate.devenv.controller-status.v1",queue:$queue,inspections:$inspections,environments:$environments,quarantines:$quarantines}'
}

fm_devenv_controller_usage() {
  printf '%s\n' 'usage: fm-devenv-controller.sh enqueue|queue|inspect|claim|release|status ...' >&2
  return 2
}

fm_devenv_controller_main() {
  [ "$#" -ge 1 ] || { fm_devenv_controller_usage; return $?; }
  local command=$1 task_id packet_path priority enqueued_at previous preferred task registry
  shift
  case "$command" in
    enqueue)
      [ "$#" -ge 2 ] && [ "$#" -le 6 ] || { fm_devenv_controller_usage; return $?; }
      task_id=$1
      packet_path=$2
      priority=${3:-0}
      enqueued_at=${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
      previous=${5:--}
      preferred=${6:--}
      case "$priority" in ''|*[!0-9-]*) return 1 ;; esac
      [ "$previous" = - ] && previous=null || previous=$(jq -Rn --arg value "$previous" '$value')
      [ "$preferred" = - ] && preferred=null || preferred=$(jq -Rn --arg value "$preferred" '$value')
      task=$(jq -cn \
        --arg task_id "$task_id" \
        --argjson priority "$priority" \
        --arg enqueued_at "$enqueued_at" \
        --argjson previous_environment "$previous" \
        --argjson preferred_environment "$preferred" \
        --arg packet_path "$packet_path" \
        '{task_id:$task_id,priority:$priority,enqueued_at:$enqueued_at,previous_environment:$previous_environment,preferred_environment:$preferred_environment,packet_path:$packet_path}') \
        || return 1
      fm_devenv_enqueue_json "$task"
      ;;
    queue)
      [ "$#" -eq 0 ] || { fm_devenv_controller_usage; return $?; }
      fm_devenv_queue_json \
        || { fm_devenv_controller_error "queue is unreadable or invalid; repair $FM_DEVENV_QUEUE"; return 1; }
      ;;
    inspect)
      [ "$#" -eq 0 ] || { fm_devenv_controller_usage; return $?; }
      # shellcheck disable=SC2119
      registry=$(fm_devenv_registry_json "$(fm_devenv_registry_path)") \
        || { fm_devenv_controller_error "environment registry is unreadable or invalid: $(fm_devenv_registry_path)"; return 1; }
      fm_devenv_inspect_all "$registry" \
        || { fm_devenv_controller_error 'fleet inspection failed'; return 1; }
      ;;
    claim)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { fm_devenv_controller_usage; return $?; }
      fm_devenv_claim_next "$@"
      ;;
    release)
      [ "$#" -eq 2 ] || { fm_devenv_controller_usage; return $?; }
      fm_devenv_release_environment "$@"
      ;;
    status)
      [ "$#" -eq 1 ] && [ "$1" = --json ] || { fm_devenv_controller_usage; return $?; }
      fm_devenv_status_json
      ;;
    *) fm_devenv_controller_usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_devenv_controller_main "$@"
fi
