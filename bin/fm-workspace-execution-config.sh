# shellcheck shell=bash
# Workspace placement and command-execution configuration.
# Usage: . bin/fm-workspace-execution-config.sh
#
# The optional, gitignored config/workspace-execution.json is the sole owner of
# placement and command-execution defaults.  Its complete schema is:
# {
#   "workerPlacement": {"adapter": "host|docker-sandbox", "workspaceMode": "direct", "kits": []},
#   "secondmatePlacement": {"adapter": "host|docker-sandbox", "workspaceMode": "direct", "kits": []},
#   "commandExecution": {"adapter": "local|crabbox", "profile": null|string}
# }
#
# Placement is currently direct-only because worker briefs, state hooks, and
# no-mistakes execute in the host worktree.  An absent file resolves to the
# established host/direct, host/direct, local/null behavior.  Source this file
# safely: it only defines functions.  Call fm_workspace_execution_config_load
# with an explicit config directory before consuming the resolved globals:
#   FM_WORKER_PLACEMENT_ADAPTER
#   FM_WORKER_PLACEMENT_WORKSPACE_MODE
#   FM_WORKER_PLACEMENT_KITS
#   FM_SECONDMATE_PLACEMENT_ADAPTER
#   FM_SECONDMATE_PLACEMENT_WORKSPACE_MODE
#   FM_SECONDMATE_PLACEMENT_KITS
#   FM_COMMAND_EXECUTION_ADAPTER
#   FM_COMMAND_EXECUTION_PROFILE
# The local adapter is always paired with an empty profile global, representing
# the JSON null value.  Crabbox always has a nonempty profile string.

fm_workspace_execution_config_fail() {
  printf 'workspace-execution config: %s\n' "$1" >&2
  return 1
}

# fm_workspace_execution_config_validate <config-dir>
# Validates the optional config file without changing the caller's globals.
fm_workspace_execution_config_validate() {
  local config_dir=${1-} path error

  [ "$#" -eq 1 ] && [ -n "$config_dir" ] \
    || { fm_workspace_execution_config_fail "expected one config directory"; return 1; }

  if [ -L "$config_dir" ]; then
    fm_workspace_execution_config_fail "config directory is symlinked"
    return 1
  fi
  if [ -e "$config_dir" ] && [ ! -d "$config_dir" ]; then
    fm_workspace_execution_config_fail "config directory is not a directory"
    return 1
  fi

  path="$config_dir/workspace-execution.json"
  if [ -L "$path" ]; then
    fm_workspace_execution_config_fail "config/workspace-execution.json is symlinked"
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    fm_workspace_execution_config_fail "config/workspace-execution.json is not a regular file"
    return 1
  fi
  [ -e "$path" ] || return 0

  command -v jq >/dev/null 2>&1 \
    || { fm_workspace_execution_config_fail "jq is required to parse config/workspace-execution.json"; return 1; }
  if ! jq -e . "$path" >/dev/null 2>&1; then
    fm_workspace_execution_config_fail "config/workspace-execution.json contains malformed JSON"
    return 1
  fi

  error=$(jq -r '
    def unknown($allowed): (keys - $allowed | sort);
    def missing($allowed): ($allowed - keys | sort);
    def invalid_kit:
      if type == "string" then length == 0 or test("[\r\n\t]") else true end;
    if type != "object" then
      "top level must be an object"
    elif unknown(["workerPlacement", "secondmatePlacement", "commandExecution"]) | length > 0 then
      "unknown top-level key: " + (unknown(["workerPlacement", "secondmatePlacement", "commandExecution"]) | join(", "))
    elif missing(["workerPlacement", "secondmatePlacement", "commandExecution"]) | length > 0 then
      "missing top-level key: " + (missing(["workerPlacement", "secondmatePlacement", "commandExecution"]) | join(", "))
    elif (.workerPlacement | type) != "object" then
      "workerPlacement must be an object"
    elif (.workerPlacement | unknown(["adapter", "workspaceMode", "kits"]) | length) > 0 then
      "unknown workerPlacement key: " + (.workerPlacement | unknown(["adapter", "workspaceMode", "kits"]) | join(", "))
    elif (.workerPlacement | missing(["adapter", "workspaceMode"]) | length) > 0 then
      "missing workerPlacement key: " + (.workerPlacement | missing(["adapter", "workspaceMode"]) | join(", "))
    elif (.workerPlacement.adapter | type) != "string" then
      "workerPlacement.adapter must be a string"
    elif (.workerPlacement.workspaceMode | type) != "string" then
      "workerPlacement.workspaceMode must be a string"
    elif (.workerPlacement.adapter != "host" and .workerPlacement.adapter != "docker-sandbox") then
      "workerPlacement.adapter must be host or docker-sandbox"
    elif .workerPlacement.workspaceMode != "direct" then
      "workerPlacement.workspaceMode must be direct"
    elif (.workerPlacement.kits? != null and (.workerPlacement.kits | type) != "array") then
      "workerPlacement.kits must be an array"
    elif (.workerPlacement.kits? != null and any(.workerPlacement.kits[]?; invalid_kit)) then
      "workerPlacement.kits must contain only nonempty strings without CR, LF, or TAB"
    elif (.workerPlacement.adapter == "host" and (.workerPlacement.kits? // [] | length) > 0) then
      "workerPlacement.kits must be empty when workerPlacement.adapter is host"
    elif (.secondmatePlacement | type) != "object" then
      "secondmatePlacement must be an object"
    elif (.secondmatePlacement | unknown(["adapter", "workspaceMode", "kits"]) | length) > 0 then
      "unknown secondmatePlacement key: " + (.secondmatePlacement | unknown(["adapter", "workspaceMode", "kits"]) | join(", "))
    elif (.secondmatePlacement | missing(["adapter", "workspaceMode"]) | length) > 0 then
      "missing secondmatePlacement key: " + (.secondmatePlacement | missing(["adapter", "workspaceMode"]) | join(", "))
    elif (.secondmatePlacement.adapter | type) != "string" then
      "secondmatePlacement.adapter must be a string"
    elif (.secondmatePlacement.workspaceMode | type) != "string" then
      "secondmatePlacement.workspaceMode must be a string"
    elif (.secondmatePlacement.adapter != "host" and .secondmatePlacement.adapter != "docker-sandbox") then
      "secondmatePlacement.adapter must be host or docker-sandbox"
    elif .secondmatePlacement.workspaceMode != "direct" then
      "secondmatePlacement.workspaceMode must be direct"
    elif (.secondmatePlacement.kits? != null and (.secondmatePlacement.kits | type) != "array") then
      "secondmatePlacement.kits must be an array"
    elif (.secondmatePlacement.kits? != null and any(.secondmatePlacement.kits[]?; invalid_kit)) then
      "secondmatePlacement.kits must contain only nonempty strings without CR, LF, or TAB"
    elif (.secondmatePlacement.adapter == "host" and (.secondmatePlacement.kits? // [] | length) > 0) then
      "secondmatePlacement.kits must be empty when secondmatePlacement.adapter is host"
    elif (.commandExecution | type) != "object" then
      "commandExecution must be an object"
    elif (.commandExecution | unknown(["adapter", "profile"]) | length) > 0 then
      "unknown commandExecution key: " + (.commandExecution | unknown(["adapter", "profile"]) | join(", "))
    elif (.commandExecution | missing(["adapter", "profile"]) | length) > 0 then
      "missing commandExecution key: " + (.commandExecution | missing(["adapter", "profile"]) | join(", "))
    elif (.commandExecution.adapter | type) != "string" then
      "commandExecution.adapter must be a string"
    elif (.commandExecution.profile != null and (.commandExecution.profile | type) != "string") then
      "commandExecution.profile must be null or a string"
    elif (.commandExecution.adapter != "local" and .commandExecution.adapter != "crabbox") then
      "commandExecution.adapter must be local or crabbox"
    elif .commandExecution.adapter == "local" and .commandExecution.profile != null then
      "commandExecution.profile must be null when commandExecution.adapter is local"
    elif .commandExecution.adapter == "crabbox" and (.commandExecution.profile | type) != "string" then
      "commandExecution.profile must be a nonempty string when commandExecution.adapter is crabbox"
    elif .commandExecution.adapter == "crabbox" and (.commandExecution.profile | length) == 0 then
      "commandExecution.profile must be a nonempty string when commandExecution.adapter is crabbox"
    else
      empty
    end
  ' "$path") || {
    fm_workspace_execution_config_fail "could not validate config/workspace-execution.json"
    return 1
  }
  if [ -n "$error" ]; then
    fm_workspace_execution_config_fail "$error"
    return 1
  fi
  return 0
}

# fm_workspace_execution_config_load <config-dir>
# Resolves all axes and updates the eight documented globals only after successful
# validation and parsing.  The absent-file result retains host/local defaults.
fm_workspace_execution_config_load() {
  local config_dir=${1-} path worker_adapter worker_mode secondmate_adapter secondmate_mode command_adapter command_profile
  local -a worker_kits=() secondmate_kits=()

  fm_workspace_execution_config_validate "$config_dir" || return 1
  path="$config_dir/workspace-execution.json"
  if [ ! -e "$path" ]; then
    worker_adapter=host
    worker_mode=direct
    secondmate_adapter=host
    secondmate_mode=direct
    command_adapter=local
    command_profile=""
  else
    if ! worker_adapter=$(jq -r '.workerPlacement.adapter' "$path"); then
      fm_workspace_execution_config_fail "could not read config/workspace-execution.json"
      return 1
    elif ! worker_mode=$(jq -r '.workerPlacement.workspaceMode' "$path"); then
      fm_workspace_execution_config_fail "could not read config/workspace-execution.json"
      return 1
    elif ! secondmate_adapter=$(jq -r '.secondmatePlacement.adapter' "$path"); then
      fm_workspace_execution_config_fail "could not read config/workspace-execution.json"
      return 1
    elif ! secondmate_mode=$(jq -r '.secondmatePlacement.workspaceMode' "$path"); then
      fm_workspace_execution_config_fail "could not read config/workspace-execution.json"
      return 1
    elif ! command_adapter=$(jq -r '.commandExecution.adapter' "$path"); then
      fm_workspace_execution_config_fail "could not read config/workspace-execution.json"
      return 1
    elif ! command_profile=$(jq -r '.commandExecution.profile // ""' "$path"); then
      fm_workspace_execution_config_fail "could not read config/workspace-execution.json"
      return 1
    fi
    while IFS= read -r kit; do
      worker_kits+=("$kit")
    done < <(jq -r '.workerPlacement.kits // [] | .[]' "$path")
    while IFS= read -r kit; do
      secondmate_kits+=("$kit")
    done < <(jq -r '.secondmatePlacement.kits // [] | .[]' "$path")
  fi

  FM_WORKER_PLACEMENT_ADAPTER=$worker_adapter
  FM_WORKER_PLACEMENT_WORKSPACE_MODE=$worker_mode
  FM_SECONDMATE_PLACEMENT_ADAPTER=$secondmate_adapter
  FM_SECONDMATE_PLACEMENT_WORKSPACE_MODE=$secondmate_mode
  # shellcheck disable=SC2034 # documented cross-file output global
  FM_WORKER_PLACEMENT_KITS=()
  if [ "${worker_kits[0]+set}" = set ]; then
    # shellcheck disable=SC2034 # documented cross-file output global
    FM_WORKER_PLACEMENT_KITS=("${worker_kits[@]}")
  fi
  # shellcheck disable=SC2034 # documented cross-file output global
  FM_SECONDMATE_PLACEMENT_KITS=()
  if [ "${secondmate_kits[0]+set}" = set ]; then
    # shellcheck disable=SC2034 # documented cross-file output global
    FM_SECONDMATE_PLACEMENT_KITS=("${secondmate_kits[@]}")
  fi
  FM_COMMAND_EXECUTION_ADAPTER=$command_adapter
  # shellcheck disable=SC2034 # documented cross-file output global
  FM_COMMAND_EXECUTION_PROFILE=$command_profile
}

# The following accessors emit stable, newline-delimited enum fields after a
# caller has loaded an explicit config directory.  Command profile remains a
# global because it may contain arbitrary JSON string content.
fm_workspace_execution_config_worker_placement() {
  printf '%s\n%s\n' "$FM_WORKER_PLACEMENT_ADAPTER" "$FM_WORKER_PLACEMENT_WORKSPACE_MODE"
}

fm_workspace_execution_config_secondmate_placement() {
  printf '%s\n%s\n' "$FM_SECONDMATE_PLACEMENT_ADAPTER" "$FM_SECONDMATE_PLACEMENT_WORKSPACE_MODE"
}

fm_workspace_execution_config_command_adapter() {
  printf '%s\n' "$FM_COMMAND_EXECUTION_ADAPTER"
}
