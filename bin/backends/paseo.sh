#!/usr/bin/env bash
# bin/backends/paseo.sh - the Paseo runtime backend (EXPERIMENTAL).
#
# Paseo owns both the agent endpoint and the task worktree. This adapter uses
# only the CLI's public JSON/status surfaces: logs are timeline output, not a
# verified viewport, and agent liveness remains unverified because Paseo does
# not expose a worker pid through its CLI. Paseo never starts, stops, or
# restarts its daemon here; the daemon must already be reachable.

FM_BACKEND_PASEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_PASEO_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

fm_backend_paseo_tool_check() {
  command -v paseo >/dev/null 2>&1 || { echo "error: backend=paseo selected but the 'paseo' CLI is not installed" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=paseo selected but 'jq' is not installed" >&2; return 1; }
}

fm_backend_paseo_runtime_check() {
  fm_backend_paseo_tool_check || return 1
  paseo daemon status >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'paseo daemon status' failed; start the Paseo daemon outside firstmate" >&2
    return 1
  }
}

fm_backend_paseo_provider() { # <firstmate-harness>
  case "$1" in
    codex|opencode) printf '%s' "$1" ;;
    claude)
      local diagnostic providers
      diagnostic=$(paseo provider diagnostic claude --json 2>&1) || {
        echo "error: Paseo provider claude is not explicitly enabled by the host diagnostic" >&2
        return 1
      }
      if ! printf '%s\n' "$diagnostic" | jq -e '
        type == "object" and .provider == "claude" and
        ((has("enabled") | not) or .enabled == true or
          ((.enabled | type) == "string" and (.enabled | ascii_downcase) == "enabled")) and
        ((has("status") | not) or
          ((.status | type) == "string" and ((.status | ascii_downcase) | IN("ready", "available", "enabled")))) and
        (.diagnostic | type == "string" and
          (split("\n") | any(test("^[[:space:]]*Status:[[:space:]]*(Ready|Available|Enabled)[[:space:]]*$"; "i"))))
      ' >/dev/null 2>&1; then
        echo "error: Paseo provider claude is not explicitly enabled by the host diagnostic" >&2
        return 1
      fi
      providers=$(paseo provider ls --json 2>&1) || {
        echo "error: Paseo provider claude availability could not be verified" >&2
        return 1
      }
      if ! printf '%s\n' "$providers" | jq -e '
        type == "array" and
        ([.[] | select(.provider == "claude" and
          ((.status | type) == "string") and (.status | ascii_downcase) == "available" and
          ((.enabled | type) == "string") and (.enabled | ascii_downcase) == "enabled")] | length) == 1
      ' >/dev/null 2>&1; then
        echo "error: Paseo provider claude is not enabled and available on this host" >&2
        return 1
      fi
      printf claude
      ;;
    *) echo "error: Paseo cannot map unknown firstmate harness '$1' to a provider" >&2; return 1 ;;
  esac
}

fm_backend_paseo_create_task() { # <id> <source-clone> <brief> <harness> <model> <effort> <home-tag> <workspace-id> [env key=value...]
  local id=$1 source=$2 brief=$3 harness=$4 model=${5:-} effort=${6:-} home_tag=${7:-} workspace_id=${8:-}
  shift 8
  local provider base_ref candidate raw json agent workspace worktree run_status reported_workspace
  local -a args
  fm_backend_paseo_runtime_check || return 1
  provider=$(fm_backend_paseo_provider "$harness") || return 1
  if [ -n "$workspace_id" ]; then
    args=(run --background --workspace "$workspace_id" --provider "$provider"
      --label "fm-task=$id" --label "fm-home=$home_tag" --title "fm-$id" --json)
  else
    base_ref=$(git -C "$source" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$base_ref" ] && ! git -C "$source" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
      base_ref=
    fi
    if [ -z "$base_ref" ]; then
      for candidate in main master; do
        if git -C "$source" rev-parse --verify --quiet "refs/heads/$candidate^{commit}" >/dev/null; then
          base_ref=$candidate
          break
        fi
      done
    fi
    [ -n "$base_ref" ] || base_ref=$(git -C "$source" rev-parse --verify --quiet 'HEAD^{commit}') || {
      echo "error: could not resolve a valid source base for Paseo task $id" >&2
      return 1
    }
    args=(run --background --new-workspace worktree --base "$base_ref"
      --worktree-slug "fm-$id" --cwd "$source" --provider "$provider"
      --label "fm-task=$id" --label "fm-home=$home_tag" --title "fm-$id" --json)
  fi
  [ -n "$model" ] && [ "$model" != default ] && args+=(--model "$model")
  [ -n "$effort" ] && [ "$effort" != default ] && args+=(--thinking "$effort")
  case "$provider" in
    opencode) args+=(--mode build) ;;
  esac
  for env_value in "$@"; do args+=(--env "$env_value"); done
  args+=("$brief")
  if raw=$(env -u PASEO_AGENT_ID -u PASEO_WORKSPACE_ID paseo "${args[@]}" 2>&1); then
    run_status=0
  else
    run_status=$?
  fi
  reported_workspace=$(printf '%s\n' "$raw" | sed -n 's/.*Created workspace \([^[:space:]]*\).*/\1/p' | tail -n 1)
  if [ "$run_status" -ne 0 ]; then
    if [ -n "$reported_workspace" ]; then
      printf 'error: Paseo run failed for task %s after creating workspace %s; workspace retained for manual reconciliation\n' \
        "$id" "$reported_workspace" >&2
    else
      printf 'error: Paseo run failed for task %s\n' "$id" >&2
    fi
    printf '%s\n' "$raw" >&2
    return 1
  fi
  json=$(printf '%s\n' "$raw" | awk 'found || /^\{/{found=1; print}')
  agent=$(printf '%s\n' "$json" | jq -r '.agentId // .id // empty' 2>/dev/null)
  workspace=$(printf '%s\n' "$json" | jq -r '.workspaceId // .workspace.id // .workspace // empty' 2>/dev/null)
  [ -n "$workspace" ] || workspace=$reported_workspace
  worktree=$(printf '%s\n' "$json" | jq -r '.worktreePath // .worktree // .cwd // empty' 2>/dev/null)
  [ -n "$agent" ] && [ -n "$workspace" ] && [ -n "$worktree" ] || {
    echo "error: Paseo did not return agent id, workspace id, and worktree path for task $id" >&2
    printf '%s\n' "$raw" >&2
    return 1
  }
  printf '%s\t%s\t%s' "$agent" "$workspace" "$worktree"
}

fm_backend_paseo_capture() { # <agent-id> <lines>
  local id=$1 lines=${2:-40}
  fm_backend_paseo_tool_check || return 1
  paseo logs "$id" --tail "$lines"
}

fm_backend_paseo_status() {
  fm_backend_paseo_tool_check || return 1
  paseo inspect "$1" --json | jq -r '(.lastStatus // .LastStatus // .status // .Status // .agent.lastStatus // .agent.status // empty) | ascii_downcase' 2>/dev/null
}

fm_backend_paseo_busy_state() {
  case "$(fm_backend_paseo_status "$1" 2>/dev/null || true)" in
    initializing|running|working|busy) printf busy ;;
    idle|closed|completed|failed|canceled|cancelled|stopped|archived) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_paseo_terminal_proof() { # <agent-id>
  case "$(fm_backend_paseo_status "$1" 2>/dev/null || true)" in
    closed|archived) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_paseo_stop_status_proof() { # <agent-id> <timeout> <poll>
  local id=$1 timeout=${2:-30} poll=${3:-0.5} elapsed=0 status
  fm_backend_paseo_tool_check || return 1
  fm_backend_paseo_terminal_proof "$id" && return 0
  paseo stop "$id" >/dev/null 2>&1 || return 1
  while :; do
    status=$(fm_backend_paseo_status "$id" 2>/dev/null || true)
    case "$status" in
      closed|archived) return 0 ;;
      idle) return 1 ;;
    esac
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
  return 1
}

fm_backend_paseo_archive_agent() {
  fm_backend_paseo_tool_check || return 1
  paseo archive "$1" >/dev/null || return 1
  local timeout=30 poll=0.5 elapsed=0 status
  while :; do
    status=$(fm_backend_paseo_status "$1" 2>/dev/null || true)
    case "$status" in
      closed|archived) return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
  echo "error: Paseo archive of agent $1 was not confirmed by native terminal status" >&2
  return 1
}

fm_backend_paseo_send_text_submit() { # <agent-id> <text> ...
  local id=$1 text=$2
  fm_backend_paseo_tool_check || return 1
  paseo send "$id" --no-wait "$text" >/dev/null
}

fm_backend_paseo_send_key() { # <agent-id> <key>
  case "$2" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C) fm_backend_paseo_tool_check && paseo stop "$1" ;;
    *) echo "error: Paseo cannot express key '$2'; only interrupt maps to paseo stop" >&2; return 1 ;;
  esac
}

fm_backend_paseo_kill() { # <agent-id> <workspace-id>
  local agent=$1 workspace=${2:-}
  fm_backend_paseo_archive_agent "$agent" || return 1
  [ -n "$workspace" ] || return 0
  paseo workspace archive "$workspace" >/dev/null
}

fm_backend_paseo_agent_state() { printf unverified; }

fm_backend_paseo_target_exists() {
  fm_backend_paseo_tool_check || return 1
  paseo inspect "$1" --json >/dev/null 2>&1
}
