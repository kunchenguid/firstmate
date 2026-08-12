#!/usr/bin/env bash
# bin/backends/paseo.sh - the Paseo session-provider adapter.
#
# Design: Paseo companion presentation, interaction, and sub-agent surface.
# Firstmate remains the orchestrator, authority, and supervisor.
# Sourced through bin/fm-backend.sh's fm_backend_source.
#
# Target string shape: "<paseo_agent_id>" - bare UUID or identifier string.

FM_BACKEND_PASEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_PASEO_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared composer-content classifier.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_PASEO_ROOT/bin/fm-composer-lib.sh"

fm_backend_paseo_bin() {
  if command -v paseo >/dev/null 2>&1; then
    printf 'paseo'
    return 0
  fi
  return 1
}

fm_backend_paseo_tool_check() {
  fm_backend_paseo_bin >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'paseo' CLI was not found on PATH" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'jq' is not installed" >&2
    return 1
  }
  command -v treehouse >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'treehouse' is not installed" >&2
    return 1
  }
  return 0
}

fm_backend_paseo_daemon_reachable() {
  local status_out daemon_state
  status_out=$(paseo status --json 2>/dev/null) || return 1
  daemon_state=$(printf '%s' "$status_out" | jq -r '.localDaemon // .connectedDaemon // empty' 2>/dev/null)
  case "$daemon_state" in
    running|reachable|ok) return 0 ;;
  esac
  return 1
}

fm_backend_paseo_readiness_check() {
  fm_backend_paseo_tool_check || return 1
  if fm_backend_paseo_daemon_reachable; then
    return 0
  fi
  local status_out
  status_out=$(paseo status --json 2>/dev/null || true)
  echo "error: Paseo daemon is not running or reachable (${status_out:-failed})" >&2
  return 1
}

fm_backend_paseo_container_ensure() {
  fm_backend_paseo_readiness_check || return 1
  return 0
}

# 1. fm_backend_paseo_parent_id: Resolves current primary PASEO_AGENT_ID
# (or fallback to running primary agent session).
fm_backend_paseo_parent_id() {
  if [ -n "${PASEO_AGENT_ID:-}" ]; then
    printf '%s' "$PASEO_AGENT_ID"
    return 0
  fi
  local parent_id
  parent_id=$(paseo ls --json 2>/dev/null | jq -r '.[]? | select(.status == "running" or .status == "idle") | .id' 2>/dev/null | head -1)
  if [ -n "$parent_id" ] && [ "$parent_id" != "null" ]; then
    printf '%s' "$parent_id"
    return 0
  fi
  return 1
}

# Resolve the model from Paseo's authoritative parent identity. The explicit
# fallback is intentionally opt-in: an unavailable identity must never turn
# into an accidental Paseo default model.
fm_backend_paseo_parent_model() {
  local parent info model
  parent=$(fm_backend_paseo_parent_id) || return 1
  info=$(paseo inspect "$parent" --json 2>/dev/null) || return 1
  model=$(printf '%s' "$info" | jq -r '
    if (.model | type) == "string" then
      if (.model | contains("/")) then
        .model
      else
        ((.provider // .modelProvider // .model.provider // "") + "/" + .model)
      end
    elif (.model | type) == "object" then
      ((.model.provider // .provider // .modelProvider // "") + "/" + (.model.name // .model.id // .modelName // ""))
    else
      ((.provider // .modelProvider // "") + "/" + (.modelName // .name // ""))
    end
  ' 2>/dev/null)
  case "$model" in
    ?*/?*)
      printf '%s' "$model"
      return 0
      ;;
  esac
  return 1
}

fm_backend_paseo_resolve_model() {
  local model
  model=$(fm_backend_paseo_parent_model 2>/dev/null || true)
  if [ -z "$model" ]; then
    model=${PASEO_MODEL_FALLBACK:-}
  fi
  [ -n "$model" ] || {
    echo "error: could not resolve the Paseo parent model; inspect the parent or set documented PASEO_MODEL_FALLBACK" >&2
    return 1
  }
  case "$model" in
    ?*/?*) ;;
    *)
      echo "error: resolved Paseo model '$model' is not provider-qualified (expected 'provider/model')" >&2
      return 1
      ;;
  esac
  printf '%s' "$model"
}

# 2. fm_backend_paseo_create_task: Allocates treehouse worktree, spawns Paseo subagent
# (paseo run --background --cwd <wt> ...), passes brief, GOTMPDIR, trace context, and
# operational instructions.
fm_backend_paseo_create_task() {  # <label> <proj_dir> [brief_path] [task_tmp] [traceparent] [kind] [model] [effort] [launch_contract]
  local label=$1 target_dir=$2 brief_path=${3:-} task_tmp=${4:-} traceparent=${5:-} kind=${6:-}
  local requested_model=${7:-} effort=${8:-} launch_contract=${9:-}
  local wt prompt out agent_id model

  if [ "$kind" = "secondmate" ] || [ -f "$target_dir/.fm-secondmate-home" ] || [ -f "$target_dir/.git" ]; then
    wt="$target_dir"
  else
    wt=$(cd "$target_dir" && treehouse get --lease 2>/dev/null) || {
      echo "error: treehouse get --lease failed for $target_dir" >&2
      return 1
    }
    # Strip banners and trim trailing whitespace to ensure clean path
    wt=$(printf '%s\n' "$wt" | tail -1 | tr -d '\r\n')
  fi
  [ -d "$wt" ] || {
    echo "error: allocated worktree path '$wt' does not exist" >&2
    return 1
  }

  if [ -n "$task_tmp" ]; then
    mkdir -p "$task_tmp/gotmp"
  fi

  model=$(fm_backend_paseo_resolve_model) || return 1
  if [ -n "$requested_model" ] && [ "$requested_model" != default ] && [ "$requested_model" != "$model" ]; then
    echo "error: requested Paseo model '$requested_model' does not match parent model '$model'" >&2
    return 1
  fi
  case "${effort:-}" in
    ''|default) effort= ;;
    low|medium|high|xhigh|max) ;;
    *) echo "error: invalid Paseo thinking level '$effort'" >&2; return 1 ;;
  esac
  if [ -n "$brief_path" ] && [ -f "$brief_path" ]; then
    prompt="Read the brief at $brief_path and follow it exactly."
  else
    prompt="Follow instructions for task $label in working directory $wt."
  fi
  prompt="$prompt Firstmate launch contract: ${launch_contract:-harness=paseo} model=$model effort=${effort:-default}. Do not substitute another model."

  local -a args
  args=(run --background --cwd "$wt" --title "$label" --label "firstmate_task=$label" --model "$model")
  [ -z "$effort" ] || args+=(--thinking "$effort")
  if [ -n "$task_tmp" ]; then
    args+=(--env "GOTMPDIR=$task_tmp/gotmp")
  fi
  if [ -n "$traceparent" ]; then
    args+=(--env "TRACEPARENT=$traceparent")
  fi
  args+=(--json -- "$prompt")

  out=$(paseo "${args[@]}" 2>/dev/null) || {
    echo "error: paseo run failed for $label" >&2
    return 1
  }

  agent_id=$(printf '%s' "$out" | jq -r '.id // .agentId // .agent.id // empty' 2>/dev/null)
  if [ -z "$agent_id" ] || [ "$agent_id" = "null" ]; then
    echo "error: paseo run did not return a valid agent ID" >&2
    return 1
  fi

  printf '%s\t%s\n' "$agent_id" "$wt"
  return 0
}

# 3. fm_backend_paseo_capture: Bounded plain-text log capture.
fm_backend_paseo_capture() {  # <target> <lines> [expected-label]
  local target=$1 lines=${2:-200}
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  paseo logs "$target" --tail "$lines" 2>/dev/null | tail -n "$lines"
}

# 4. fm_backend_paseo_send_text_submit: Submits prompt to Paseo agent.
fm_backend_paseo_send_text_submit() {  # <target> <text> [retries] [enter-sleep] [settle] [expected-label]
  local target=$1 text=$2
  if paseo send "$target" --no-wait -- "$text" >/dev/null 2>&1; then
    printf ''
    return 0
  else
    printf 'send-failed'
    return 1
  fi
}

fm_backend_paseo_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_paseo_send_text_submit "$1" "$2"
}

fm_backend_paseo_send_literal() {  # <target> <text> [expected-label]
  fm_backend_paseo_send_text_submit "$1" "$2"
}

# 5. fm_backend_paseo_send_key: Maps special keys (Escape, C-c -> paseo stop, others -> send).
fm_backend_paseo_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2
  case "$key" in
    Escape|escape|Esc|esc|C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c)
      paseo stop "$target" >/dev/null 2>&1
      ;;
    Enter|enter|C-m|c-m|return|Return|C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u)
      paseo send "$target" --no-wait --key "$key" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# 6. fm_backend_paseo_kill: Archives task (paseo stop then paseo archive).
fm_backend_paseo_kill() {  # <target>
  local target=$1
  [ -n "$target" ] || return 0
  paseo stop "$target" >/dev/null 2>&1 || true
  paseo archive --force "$target" >/dev/null 2>&1 || true
}

# 7. fm_backend_paseo_busy_state: Reads status (running/initializing -> busy, idle -> idle, closed/error/failed -> dead).
fm_backend_paseo_busy_state() {  # <target>
  local target=$1 info status
  info=$(paseo inspect "$target" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$info" | jq -r '.status // .agent.status // empty' 2>/dev/null)
  case "$status" in
    running|initializing) printf 'busy' ;;
    idle) printf 'idle' ;;
    closed|error|failed|archived|stopped) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# 8. fm_backend_paseo_composer_state: Returns empty when idle, pending when busy.
fm_backend_paseo_composer_state() {  # <target> [expected-label]
  local target=$1 st
  st=$(fm_backend_paseo_busy_state "$target")
  case "$st" in
    busy) printf 'pending' ;;
    idle) printf 'empty' ;;
    *) printf 'unknown' ;;
  esac
}

# 9. fm_backend_paseo_target_exists: Validates target existence via paseo inspect.
fm_backend_paseo_target_exists() {  # <target> [expected-label]
  local target=$1
  [ -n "$target" ] || return 1
  paseo inspect "$target" >/dev/null 2>&1
}

# 10. fm_backend_paseo_agent_state: Returns recovery-grade status (alive, dead, missing, unreadable).
fm_backend_paseo_agent_state() {  # <target>
  local target=$1 info status
  [ -n "$target" ] || { printf 'missing'; return 0; }
  info=$(paseo inspect "$target" --json 2>/dev/null) || {
    if fm_backend_paseo_daemon_reachable; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  }
  status=$(printf '%s' "$info" | jq -r '.status // .agent.status // empty' 2>/dev/null)
  case "$status" in
    running|initializing|idle) printf 'alive' ;;
    closed|error|failed|archived|stopped) printf 'dead' ;;
    '') printf 'unreadable' ;;
    *) printf 'unreadable' ;;
  esac
}

# 11. fm_backend_paseo_current_path: Returns current working directory from paseo inspect.
fm_backend_paseo_current_path() {  # <target> [expected-label]
  local target=$1 info cwd
  info=$(paseo inspect "$target" --json 2>/dev/null) || return 0
  cwd=$(printf '%s' "$info" | jq -r '.cwd // .workspace.cwd // .workingDirectory // .agent.cwd // empty' 2>/dev/null)
  printf '%s' "$cwd"
}

# 12. fm_backend_paseo_list_live: Lists live task agents for this home.
fm_backend_paseo_list_live() {
  local list
  list=$(paseo ls --json 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r '.[]? | select(.status == "running" or .status == "initializing" or .status == "idle") | "\(.id)\t\(.name // .title // ("fm-" + .id))"' 2>/dev/null
}
