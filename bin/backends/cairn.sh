#!/usr/bin/env bash
# Local Cairn session provider. A target carries every identity needed to call
# the exact app and pane after the launching shell has exited.

FM_BACKEND_CAIRN_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_CAIRN_ROOT="$(cd "$(dirname "$FM_BACKEND_CAIRN_SCRIPT")/../.." && pwd)"
unset FM_BACKEND_CAIRN_SCRIPT
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_CAIRN_ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_CAIRN_ROOT/bin/fm-agent-process-lib.sh"

fm_backend_cairn_state_dir() {
  local path=${FM_CAIRN_STATE_DIR:-${CAIRN_INSTANCE_STATE_DIR:-}}
  if [ -z "$path" ] && [ -n "${CAIRN_HOME:-}" ]; then
    path="$CAIRN_HOME/state"
  fi
  if [ -z "$path" ]; then
    path="$HOME/.cairn/state"
  fi
  [ -d "$path" ] && (cd "$path" && pwd -P)
}

fm_backend_cairn_client() { # <state-dir>
  local state=$1 pid executable
  if [ -n "${CAIRNCTL:-}" ]; then
    [ -x "$CAIRNCTL" ] || return 1
    printf '%s' "$CAIRNCTL"
    return 0
  fi
  if command -v cairnctl >/dev/null 2>&1; then
    command -v cairnctl
    return 0
  fi
  pid=$(jq -er '.pid | select(type == "number" and . > 1) | floor' \
    "$state/control.json" 2>/dev/null) || return 1
  executable=$(ps -p "$pid" -o comm= 2>/dev/null) || return 1
  case "$executable" in
    */Contents/MacOS/*)
      executable=${executable%/Contents/MacOS/*}/Contents/Resources/cairnctl
      [ -x "$executable" ] || return 1
      printf '%s' "$executable"
      ;;
    *) return 1 ;;
  esac
}

fm_backend_cairn_call() { # <state-dir> <method> <params-json> <capability>
  local client
  client=$(fm_backend_cairn_client "$1") || {
    echo "error: no cairnctl for the recorded Cairn instance" >&2
    return 1
  }
  "$client" --state-dir "$1" call "$2" "$3" --capability "$4"
}

fm_backend_cairn_identity() { # <state-dir>
  local state=$1 out
  [ -f "$state/control.json" ] || return 1
  out=$(fm_backend_cairn_call "$state" api/ping '{"nonce":"firstmate"}' api.read) \
    || return 1
  printf '%s' "$out" | jq -e '.result.nonce == "firstmate"' >/dev/null
}

fm_backend_cairn_detect() {
  local state=${CAIRN_INSTANCE_STATE_DIR:-} workspace=${CAIRN_WORKSPACE_ID:-} out
  [ -n "$state" ] && [ -n "$workspace" ] || return 1
  state=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  fm_backend_cairn_identity "$state" || return 1
  out=$(fm_backend_cairn_call "$state" workspaces/list '{}' workspaces.read) \
    || return 1
  printf '%s' "$out" | jq -e --arg id "$workspace" \
    '.result.workspaces | any(.id == $id and .target == "local" and .running == true)' \
    >/dev/null
}

fm_backend_cairn_target() { # <state> <home> <task> <workspace> <pane>
  case "$1$2$3$4$5" in *'|'*|*$'\n'*) return 1 ;; esac
  printf '%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5"
}

fm_backend_cairn_parse_target() {
  local target=$1 rest
  CAIRN_TARGET_STATE=${target%%|*}
  rest=${target#*|}
  [ "$rest" != "$target" ] || return 1
  CAIRN_TARGET_HOME=${rest%%|*}
  rest=${rest#*|}
  CAIRN_TARGET_TASK=${rest%%|*}
  rest=${rest#*|}
  CAIRN_TARGET_WORKSPACE=${rest%%|*}
  CAIRN_TARGET_PANE=${rest#*|}
  [ -n "$CAIRN_TARGET_STATE" ] && [ -n "$CAIRN_TARGET_HOME" ] \
    && [ -n "$CAIRN_TARGET_TASK" ] && [ -n "$CAIRN_TARGET_WORKSPACE" ] \
    && [ -n "$CAIRN_TARGET_PANE" ] \
    && [ "$CAIRN_TARGET_PANE" != "$rest" ] \
    && [ "${CAIRN_TARGET_PANE#*|}" = "$CAIRN_TARGET_PANE" ]
}

fm_backend_cairn_params() { # <target> [extra jq args]
  fm_backend_cairn_parse_target "$1" || return 1
  jq -nc --arg workspaceId "$CAIRN_TARGET_WORKSPACE" \
    --arg paneId "$CAIRN_TARGET_PANE" \
    --arg firstMateHome "$CAIRN_TARGET_HOME" \
    --arg firstMateTaskId "$CAIRN_TARGET_TASK" \
    '{workspaceId:$workspaceId,paneId:$paneId,firstMateHome:$firstMateHome,firstMateTaskId:$firstMateTaskId}'
}

fm_backend_cairn_create_task() { # <label> <cwd> [home]
  local label=$1 cwd=$2 home=${3:-$FM_HOME} task state params out workspace pane
  task=${label#fm-}
  state=$(fm_backend_cairn_state_dir) || return 1
  home=$(cd "$home" && pwd -P) || return 1
  fm_backend_cairn_identity "$state" || {
    echo "error: Cairn instance is unavailable; refusing task launch" >&2
    return 1
  }
  out=$(fm_backend_cairn_call "$state" workspaces/list '{}' workspaces.read) \
    || return 1
  local existing
  existing=$(printf '%s' "$out" | jq -r --arg home "$home" --arg task "$task" \
    '.result.workspaces | if type == "array" then
      any(.firstMateHome == $home and .firstMateTaskId == $task)
    else error("missing workspace inventory") end') || return 1
  if [ "$existing" = true ]; then
    echo "error: Cairn already has a bound endpoint for task $task; refusing a second launch without its First Mate record" >&2
    return 1
  fi
  params=$(jq -nc --arg directory "$cwd" --arg name "$label" \
    --arg firstMateHome "$home" --arg firstMateTaskId "$task" \
    --arg launchingWorkspaceId "${CAIRN_WORKSPACE_ID:-}" \
    '{directory:$directory,name:$name,background:true,firstMateHome:$firstMateHome,firstMateTaskId:$firstMateTaskId}
      + (if $launchingWorkspaceId == "" then {} else {launchingWorkspaceId:$launchingWorkspaceId} end)') \
    || return 1
  out=$(fm_backend_cairn_call "$state" workspaces/spawn "$params" workspaces.manage) \
    || return 1
  workspace=$(printf '%s' "$out" | jq -er '.result.workspaceId') || return 1
  pane=$(printf '%s' "$out" | jq -er '.result.paneId') || return 1
  fm_backend_cairn_target "$state" "$home" "$task" "$workspace" "$pane"
}

fm_backend_cairn_inspect() { # <target>
  local params
  params=$(fm_backend_cairn_params "$1") || return 1
  fm_backend_cairn_call "${1%%|*}" firstmate/endpoint/inspect \
    "$params" firstmate.endpoint.read | jq -e '.result'
}

fm_backend_cairn_capture() { # <target> <lines>
  local params
  params=$(fm_backend_cairn_params "$1") || return 1
  params=$(jq -nc --argjson base "$params" --argjson lines "${2:-80}" \
    '$base + {lines:$lines}') || return 1
  fm_backend_cairn_call "${1%%|*}" firstmate/endpoint/capture \
    "$params" firstmate.endpoint.read | jq -er '.result.text'
}

fm_backend_cairn_visible_capture() { # <target>
  local params
  params=$(fm_backend_cairn_params "$1") || return 1
  fm_backend_cairn_call "${1%%|*}" firstmate/endpoint/visible \
    "$params" firstmate.endpoint.read | jq -er '.result.text'
}

fm_backend_cairn_send_literal() { # <target> <text>
  local params
  params=$(fm_backend_cairn_params "$1") || return 1
  params=$(jq -nc --argjson base "$params" --arg text "$2" \
    '$base + {text:$text}') || return 1
  fm_backend_cairn_call "${1%%|*}" firstmate/endpoint/text \
    "$params" firstmate.endpoint.manage | jq -e '.result.sent == true' >/dev/null
}

fm_backend_cairn_send_key() { # <target> <key>
  local params
  params=$(fm_backend_cairn_params "$1") || return 1
  params=$(jq -nc --argjson base "$params" --arg key "$2" \
    '$base + {key:$key}') || return 1
  fm_backend_cairn_call "${1%%|*}" firstmate/endpoint/key \
    "$params" firstmate.endpoint.manage | jq -e '.result.sent == true' >/dev/null
}

fm_backend_cairn_send_text_line() {
  fm_backend_cairn_send_literal "$1" "$2" \
    && fm_backend_cairn_send_key "$1" Enter
}

fm_backend_cairn_current_path() {
  fm_backend_cairn_inspect "$1" | jq -er '.directory | select(length > 0)'
}

fm_backend_cairn_target_exists() {
  fm_backend_cairn_inspect "$1" 2>/dev/null \
    | jq -e '.endpointState == "present"' >/dev/null
}

fm_backend_cairn_agent_state() {
  local result status shell_pid rows pid name verdict found=0 other=0 root_seen=0
  result=$(fm_backend_cairn_inspect "$1" 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  status=$(printf '%s' "$result" | jq -r '.endpointState')
  case "$status" in
    missing) printf 'missing'; return 0 ;;
    present) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  shell_pid=$(printf '%s' "$result" | jq -er '.shellPid | select(. > 1)') || {
    printf 'unreadable'
    return 0
  }
  rows=$(ps -axo pid=,ppid=,comm= 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  if ! printf '%s\n' "$rows" | awk -v root="$shell_pid" \
    '$1 == root { seen=1 } END { exit(!seen) }'; then
    printf 'unreadable'
    return 0
  fi
  while read -r pid _ name; do
    [ -n "$pid" ] || continue
    [ "$pid" != "$shell_pid" ] || root_seen=1
    verdict=$(fm_agent_process_classify_name "$name")
    case "$verdict" in
      agent) found=1 ;;
      shell) ;;
      *) other=1 ;;
    esac
  done < <(printf '%s\n' "$rows" | awk -v root="$shell_pid" '
    { pid=$1; parent=$2; name=$3; parents[pid]=parent; names[pid]=name }
    END {
      if (!(root in parents)) exit 1
      for (pid in parents) {
        cur=pid
        for (i=0; i<64 && cur in parents; i++) {
          if (cur == root) { print pid, parents[pid], names[pid]; break }
          cur=parents[cur]
        }
      }
    }')
  if [ "$root_seen" -ne 1 ]; then
    printf 'unreadable'
  elif [ "$found" -eq 1 ]; then
    printf 'alive'
  elif [ "$other" -eq 1 ]; then
    printf 'ambiguous'
  else
    printf 'dead'
  fi
}

fm_backend_cairn_composer_state() {
  local cap verdict
  cap=$(fm_backend_cairn_visible_capture "$1") || {
    printf 'unknown'
    return 0
  }
  verdict=$(fm_composer_classify_screen \
    "styled=0
cursor=0
identity=0
rows=80" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_cairn_send_text_submit() { # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=${3:-2} enter_sleep=${4:-0.4} settle=${5:-0.5} state
  state=$(fm_backend_cairn_composer_state "$target")
  [ "$state" = empty ] || {
    printf '%s' "$state"
    return 0
  }
  fm_backend_cairn_send_literal "$target" "$text" || {
    printf 'send-failed'
    return 0
  }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_cairn_send_key \
    fm_backend_cairn_composer_state "$target" "$retries" "$enter_sleep"
}

fm_backend_cairn_kill() {
  local params state
  params=$(fm_backend_cairn_params "$1") || return 1
  state=$(fm_backend_cairn_inspect "$1") || return 1
  [ "$(printf '%s' "$state" | jq -r '.endpointState')" = present ] || return 1
  fm_backend_cairn_call "${1%%|*}" firstmate/endpoint/stop \
    "$params" firstmate.endpoint.manage | jq -e '.result.stopped == true' >/dev/null
}

fm_backend_cairn_stop_preflight() {
  local state
  state=$(fm_backend_cairn_inspect "$1") || return 1
  printf '%s' "$state" | jq -e \
    '.endpointState == "present" and .paneCount == 1' >/dev/null
}
