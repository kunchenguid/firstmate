#!/usr/bin/env bash
# docker-sandbox.sh - Docker Sandboxes workspace-placement adapter.
#
# Interface invariants:
# - direct mounts only the selected workspace plus an optional explicit
#   additional workspace; clone creates a private VM clone.
# - A Docker Sandbox always receives one official agent preset.  The adapter
#   accepts the caller-selected preset verbatim after requiring it be nonempty.
# - Sandbox names are deterministic fm-<task-id> values and existing names are
#   refused rather than adopted.
# - Handles bind the task identity to that deterministic name and provider id,
#   so inspect and release refuse mismatched handles.
# - Clone cwd is discovered with sbx exec after creation, never guessed.
#
# Official command assumptions: Docker Sandboxes documents `sbx create --name
# NAME AGENT PATH [PATH...]`, `--clone`, `sbx exec`, `sbx ls --json`, `sbx
# stop`, and `sbx rm`; this adapter uses only those documented sbx automation
# commands.

fm_workspace_placement_docker_sandbox_check() {
  if ! command -v sbx >/dev/null 2>&1; then
    fm_workspace_placement_error 'docker-sandbox placement requires the sbx CLI; install Docker Sandboxes and ensure sbx is on PATH'
    return 127
  fi
  if ! command -v jq >/dev/null 2>&1; then
    fm_workspace_placement_error 'docker-sandbox placement requires jq to verify stable sandbox identities'
    return 127
  fi
}

fm_workspace_placement_docker_sandbox_inventory_array() {
  jq -s -e -c '
    def field($object; $keys):
      reduce $keys[] as $key ({found:false, value:null};
        if .found then .
        elif ($object | has($key)) then {found:true, value:$object[$key]}
        else .
        end);
    def required_field($object; $keys):
      (field($object; $keys)) as $field
      | if $field.found and ($field.value | type) == "string" and ($field.value | length) > 0
        then $field.value
        else error("malformed Docker Sandbox inventory member")
        end;
    def optional_field($object; $keys):
      (field($object; $keys)) as $field
      | if $field.found then
          if ($field.value | type) == "string" and ($field.value | test("^[^\\t\\r\\n]*$"))
          then $field.value
          else error("malformed Docker Sandbox inventory member")
          end
        else ""
        end;
    if length == 1 then .[0]
    else error("unsupported Docker Sandbox inventory shape")
    end
    | if type == "array" then .
    elif type == "object" then
      [
        if has("sandboxes") then .sandboxes else empty end,
        if has("items") then .items else empty end,
        if has("data") then .data else empty end,
        if has("results") then .results else empty end
      ]
      | if length == 1 and (.[0] | type) == "array" then .[0]
        else error("unsupported Docker Sandbox inventory shape")
        end
    else error("unsupported Docker Sandbox inventory shape")
    end
    | map(
        if type != "object" then error("malformed Docker Sandbox inventory member")
        else
          . as $member
          | {
              id: (required_field($member; ["id", "ID", "sandboxId", "sandbox_id"])),
              name: (required_field($member; ["name", "Name", "sandboxName", "sandbox_name"])),
              agent: (optional_field($member; ["agent", "Agent"])),
              workspace: (optional_field($member; ["workspace", "workdir", "workingDir", "working_dir"]))
            }
        end
        | if (.id | test("^[A-Za-z0-9._-]+$")) and (.name | test("^[A-Za-z0-9._-]+$"))
          then .
          else error("malformed Docker Sandbox inventory member")
          end
      )
    | if (map(.id) | length) == (map(.id) | unique | length)
      then .
      else error("duplicate Docker Sandbox provider identity")
      end
  '
}

fm_workspace_placement_docker_sandbox_name() {  # <task-id>
  local task_id=$1
  case "$task_id" in
    ''|*[![:alnum:].-]*)
      fm_workspace_placement_error "docker-sandbox task identity '$task_id' must use only letters, digits, dots, or hyphens"
      return 2
      ;;
  esac
  printf 'fm-%s' "$task_id"
}

fm_workspace_placement_docker_sandbox_handle_parts() {  # <handle>
  local handle=$1 remainder task_id name provider_id expected
  case "$handle" in
    docker-sandbox:*:*:*) remainder=${handle#docker-sandbox:} ;;
    *)
      fm_workspace_placement_error "invalid docker-sandbox placement handle '$handle'"
      return 2
      ;;
  esac
  task_id=${remainder%%:*}
  remainder=${remainder#*:}
  name=${remainder%%:*}
  provider_id=${remainder#*:}
  if [ -z "$task_id" ] || [ -z "$name" ] || [ "$name" = "$task_id" ] || [ -z "$provider_id" ]; then
    fm_workspace_placement_error "invalid docker-sandbox placement handle '$handle'"
    return 2
  fi
  expected=$(fm_workspace_placement_docker_sandbox_name "$task_id") || return 1
  if [ "$name" != "$expected" ]; then
    fm_workspace_placement_error "docker-sandbox handle '$handle' does not match task identity '$task_id'"
    return 2
  fi
  case "$provider_id" in
    *[!A-Za-z0-9._-]*)
      fm_workspace_placement_error "invalid Docker Sandbox provider identity in handle '$handle'"
      return 2
      ;;
  esac
  printf '%s\t%s\t%s' "$task_id" "$name" "$provider_id"
}

fm_workspace_placement_docker_sandbox_handle_name() {  # <handle>
  local parts task_id name provider_id
  parts=$(fm_workspace_placement_docker_sandbox_handle_parts "$1") || return 1
  IFS=$'\t' read -r task_id name provider_id <<EOF
$parts
EOF
  printf '%s' "$name"
}

fm_workspace_placement_docker_sandbox_handle_id() {  # <handle>
  local parts
  parts=$(fm_workspace_placement_docker_sandbox_handle_parts "$1") || return 1
  printf '%s' "${parts##*$'\t'}"
}

fm_workspace_placement_docker_sandbox_resolve_workspace() {  # <workspace>
  local workspace=$1 resolved
  if [ -z "$workspace" ]; then
    fm_workspace_placement_error 'docker-sandbox placement requires a workspace'
    return 2
  fi
  resolved=$(CDPATH='' cd -- "$workspace" 2>/dev/null && pwd -P) || {
    fm_workspace_placement_error "docker-sandbox workspace is not an accessible directory: $workspace"
    return 1
  }
  printf '%s' "$resolved"
}

fm_workspace_placement_docker_sandbox_record() {  # <name-or-id>
  local selector=$1 listing inventory records count id name agent workspace
  listing=$(sbx ls --json) || {
    fm_workspace_placement_error 'could not list Docker Sandboxes with sbx ls --json'
    return 2
  }
  inventory=$(printf '%s' "$listing" | fm_workspace_placement_docker_sandbox_inventory_array) || {
    fm_workspace_placement_error 'Docker Sandbox stable identity output was malformed'
    return 2
  }
  records=$(printf '%s' "$inventory" | jq -r --arg selector "$selector" '
    .[]
    | select(.name == $selector or .id == $selector)
    | [.id, .name, .agent, .workspace]
    | @tsv
  ' 2>/dev/null) || {
    fm_workspace_placement_error 'Docker Sandbox stable identity output was malformed'
    return 2
  }
  count=$(printf '%s\n' "$records" | awk 'NF { n++ } END { print n + 0 }')
  case "$count" in
    0) return 1 ;;
    1) ;;
    *)
      fm_workspace_placement_error "Docker Sandbox selector '$selector' matched multiple provider identities"
      return 2
      ;;
  esac
  IFS=$'\t' read -r id name agent workspace <<EOF
$records
EOF
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  case "$name" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_DOCKER_ID=$id
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_DOCKER_NAME=$name
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_DOCKER_AGENT=$agent
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_DOCKER_WORKSPACE=$workspace
}

fm_workspace_placement_docker_sandbox_snapshot_ids() {
  local inventory rc
  inventory=$(fm_workspace_placement_docker_sandbox_snapshot_inventory) || {
    rc=$?
    return "$rc"
  }
  printf '%s' "$inventory" | jq -r '
    .[].id
  ' 2>/dev/null
}

fm_workspace_placement_docker_sandbox_snapshot_inventory() {
  local listing inventory
  listing=$(sbx ls --json) || return 1
  inventory=$(printf '%s' "$listing" | fm_workspace_placement_docker_sandbox_inventory_array) || return 2
  printf '%s' "$inventory"
}

fm_workspace_placement_docker_sandbox_resolve_acquired() {  # <task-id> <name> <before-ids>
  local task_id=$1 name=$2 before_ids=${3:-} provider_id handle
  fm_workspace_placement_docker_sandbox_record "$name" || return 1
  provider_id=$FM_WORKSPACE_PLACEMENT_DOCKER_ID
  if printf '%s\n' "$before_ids" | grep -Fqx -- "$provider_id"; then
    fm_workspace_placement_error "Docker Sandbox '$name' was not proven to be newly acquired"
    return 1
  fi
  handle="docker-sandbox:$task_id:$name:$provider_id"
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_ACQUIRED_HANDLE=$handle
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_NAME=
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_REASON=
  printf '%s' "$handle"
}

fm_workspace_placement_docker_sandbox_reconcile_failed_create() {  # <task-id> <name> <before-ids>
  local name=$2 before_ids=${3:-} inventory before_json candidates new_count provider_name
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_ACQUIRED_HANDLE=
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_NAME=$name
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_REASON=post-create-inventory-unavailable
  inventory=$(fm_workspace_placement_docker_sandbox_snapshot_inventory) || return 1
  before_json=$(printf '%s\n' "$before_ids" | jq -R -s -c 'split("\n") | map(select(length > 0))') || return 1
  candidates=$(printf '%s' "$inventory" | jq -c --argjson before "$before_json" '
    [ .[]
      | . as $entry
      | ($entry.id) as $entry_id
      | select(($before | index($entry_id)) == null)
    ]
  ') || return 1
  new_count=$(printf '%s' "$candidates" | jq -r 'length') || return 1
  if [ "$new_count" -eq 0 ]; then
    # shellcheck disable=SC2034
    FM_WORKSPACE_PLACEMENT_PENDING_REASON=no-new-provider-identity
    return 1
  fi
  if [ "$new_count" -ne 1 ]; then
    # shellcheck disable=SC2034
    FM_WORKSPACE_PLACEMENT_PENDING_REASON=ambiguous-new-provider-identity
    return 1
  fi
  provider_id=$(printf '%s' "$candidates" | jq -r '.[0].id') || return 1
  provider_name=$(printf '%s' "$candidates" | jq -r '.[0].name') || return 1
  if [ "$provider_name" != "$name" ]; then
    # shellcheck disable=SC2034
    FM_WORKSPACE_PLACEMENT_PENDING_REASON=unattributable-new-provider-identity
    return 1
  fi
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_REASON=provider-ownership-unproven
  return 1
}

fm_workspace_placement_docker_sandbox_prepare() {  # <direct|clone> <task-id> <workspace> <preset> [additional-workspace] [kit-ref...]
  local mode=$1 task_id=$2 workspace=$3 preset=$4 additional_workspace=${5:-}
  local name handle resolved_workspace resolved_additional clone_cwd state kit create_error before_ids
  local -a kits=() create_argv
  if [ "$#" -gt 5 ]; then
    kits=("${@:6}")
  fi
  fm_workspace_placement_docker_sandbox_check || return 1
  case "$mode" in
    direct|clone) ;;
    *)
      fm_workspace_placement_error "docker-sandbox placement does not support mode '$mode' (expected direct or clone)"
      return 2
      ;;
  esac
  [ -n "$preset" ] || {
    fm_workspace_placement_error 'docker-sandbox placement requires an explicit official preset'
    return 2
  }
  name=$(fm_workspace_placement_docker_sandbox_name "$task_id") || return 1
  resolved_workspace=$(fm_workspace_placement_docker_sandbox_resolve_workspace "$workspace") || return 1
  if [ -n "$additional_workspace" ]; then
    resolved_additional=$(fm_workspace_placement_docker_sandbox_resolve_workspace "$additional_workspace") || return 1
    [ "$resolved_additional" != "$resolved_workspace" ] || {
      fm_workspace_placement_error 'docker-sandbox additional workspace must differ from the selected workspace'
      return 2
    }
  fi
  if fm_workspace_placement_docker_sandbox_record "$name"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0)
      fm_workspace_placement_error "docker-sandbox identity collision: sandbox '$name' already exists"
      return 1
      ;;
    1) ;;
    *) return "$state" ;;
  esac
  before_ids=$(fm_workspace_placement_docker_sandbox_snapshot_ids) || {
    fm_workspace_placement_error 'could not capture Docker Sandbox identities before creation'
    return 1
  }
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_NAME=$name
  # shellcheck disable=SC2034
  FM_WORKSPACE_PLACEMENT_PENDING_REASON=creation-in-progress
  create_argv=(sbx create --name "$name")
  if [ "${kits[0]+set}" = set ]; then
    for kit in "${kits[@]}"; do
      create_argv+=(--kit "$kit")
    done
  fi
  case "$mode" in
    direct)
      create_argv+=("$preset" "$resolved_workspace")
      if [ -n "$resolved_additional" ]; then
        create_argv+=("$resolved_additional")
        create_error="could not create Docker Sandbox '$name' for the selected workspaces"
      else
        create_error="could not create Docker Sandbox '$name' for the selected workspace"
      fi
      if ! "${create_argv[@]}" >/dev/null; then
        fm_workspace_placement_error "$create_error"
        if ! fm_workspace_placement_docker_sandbox_reconcile_failed_create "$task_id" "$name" "$before_ids" >/dev/null; then
          fm_workspace_placement_error "could not reconcile Docker Sandbox '$name' ownership after create failure"
        fi
        return 1
      fi
      if ! fm_workspace_placement_docker_sandbox_resolve_acquired "$task_id" "$name" "$before_ids" >/dev/null; then
        fm_workspace_placement_error "could not prove the stable identity of Docker Sandbox '$name'"
        if ! fm_workspace_placement_docker_sandbox_reconcile_failed_create "$task_id" "$name" "$before_ids" >/dev/null; then
          fm_workspace_placement_error "could not reconcile Docker Sandbox '$name' ownership after creation"
        fi
        return 1
      fi
      handle=$FM_WORKSPACE_PLACEMENT_ACQUIRED_HANDLE
      fm_workspace_placement_result_set "$handle" "$resolved_workspace" "$resolved_workspace" 'yes'
      ;;
    clone)
      [ -z "$resolved_additional" ] || {
        fm_workspace_placement_error 'docker-sandbox clone placement does not support an additional workspace'
        return 2
      }
      create_argv+=(--clone "$preset" "$resolved_workspace")
      if ! "${create_argv[@]}" >/dev/null; then
        fm_workspace_placement_error "could not create cloned Docker Sandbox '$name'"
        if ! fm_workspace_placement_docker_sandbox_reconcile_failed_create "$task_id" "$name" "$before_ids" >/dev/null; then
          fm_workspace_placement_error "could not reconcile cloned Docker Sandbox '$name' ownership after create failure"
        fi
        return 1
      fi
      if ! fm_workspace_placement_docker_sandbox_resolve_acquired "$task_id" "$name" "$before_ids" >/dev/null; then
        fm_workspace_placement_error "could not prove the stable identity of cloned Docker Sandbox '$name'"
        if ! fm_workspace_placement_docker_sandbox_reconcile_failed_create "$task_id" "$name" "$before_ids" >/dev/null; then
          fm_workspace_placement_error "could not reconcile cloned Docker Sandbox '$name' ownership after creation"
        fi
        return 1
      fi
      handle=$FM_WORKSPACE_PLACEMENT_ACQUIRED_HANDLE
      clone_cwd=$(sbx exec "$name" pwd) || {
        fm_workspace_placement_docker_sandbox_release "$handle" force || true
        fm_workspace_placement_error "could not determine the working directory inside cloned Docker Sandbox '$name'"
        return 1
      }
      case "$clone_cwd" in
        /*) ;;
        *)
          fm_workspace_placement_docker_sandbox_release "$handle" force || true
          fm_workspace_placement_error "Docker Sandbox '$name' returned a non-absolute clone working directory"
          return 1
          ;;
      esac
      fm_workspace_placement_result_set "$handle" "$resolved_workspace" "$clone_cwd" 'yes'
      ;;
  esac
}

fm_workspace_placement_docker_sandbox_wrap_launch() {  # <handle> <cwd> <command> [arg...]
  local handle=$1 cwd=$2 name
  fm_workspace_placement_docker_sandbox_check || return 1
  name=$(fm_workspace_placement_docker_sandbox_handle_name "$handle") || return 1
  if [ -z "$cwd" ]; then
    fm_workspace_placement_error 'docker-sandbox launch requires an explicit resolved cwd'
    return 2
  fi
  FM_WORKSPACE_PLACEMENT_LAUNCH=(sbx exec -it -w "$cwd" "$name" "${@:3}")
}

fm_workspace_placement_docker_sandbox_inspect() {  # <handle>
  local parts provider_id state
  fm_workspace_placement_docker_sandbox_check || return 1
  parts=$(fm_workspace_placement_docker_sandbox_handle_parts "$1") || return 1
  provider_id=${parts##*$'\t'}
  if fm_workspace_placement_docker_sandbox_record "$provider_id"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0) FM_WORKSPACE_PLACEMENT_PRESENT='1'; return 0 ;;
    1) FM_WORKSPACE_PLACEMENT_PRESENT='0'; return 1 ;;
    *) return "$state" ;;
  esac
}

fm_workspace_placement_docker_sandbox_release() {  # <handle> [force]
  local handle=$1 force=${2:-} parts name provider_id state
  fm_workspace_placement_docker_sandbox_check || return 1
  parts=$(fm_workspace_placement_docker_sandbox_handle_parts "$handle") || return 1
  name=$(printf '%s' "$parts" | cut -f2)
  provider_id=$(printf '%s' "$parts" | cut -f3)
  if fm_workspace_placement_docker_sandbox_record "$provider_id"; then
    [ "$FM_WORKSPACE_PLACEMENT_DOCKER_NAME" = "$name" ] || {
      fm_workspace_placement_error "Docker Sandbox provider identity '$provider_id' no longer names '$name'; refusing release"
      return 1
    }
    state=0
  else
    state=$?
  fi
  case "$state" in
    0) ;;
    1) return 0 ;;
    *) return "$state" ;;
  esac
  sbx stop "$provider_id" >/dev/null || {
    fm_workspace_placement_error "could not stop verified Docker Sandbox '$provider_id'; refusing to remove it"
    return 1
  }
  if fm_workspace_placement_docker_sandbox_record "$provider_id"; then
    state=0
  else
    state=$?
  fi
  case "$state" in
    0) ;;
    1) return 0 ;;
    *) return "$state" ;;
  esac
  if [ "$force" = 'force' ]; then
    sbx rm --force "$provider_id" >/dev/null || {
      fm_workspace_placement_error "could not forcibly remove verified Docker Sandbox '$provider_id'"
      return 1
    }
  else
    sbx rm "$provider_id" >/dev/null || {
      fm_workspace_placement_error "could not remove verified Docker Sandbox '$provider_id'"
      return 1
    }
  fi
}
