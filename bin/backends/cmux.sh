#!/usr/bin/env bash
# bin/backends/cmux.sh - the cmux session-provider adapter (EXPERIMENTAL).
#
# cmux is a session provider only: treehouse remains the worktree provider for
# ship/scout tasks, exactly like tmux, herdr, and zellij. This adapter creates
# one cmux workspace per task, named fm-<id>, and targets the workspace's first
# terminal surface. Target string shape: "workspace:<n>/surface:<n>".
#
# Empirical baseline: cmux 0.64.17 on macOS. Verified CLI primitives:
#   cmux workspace create --name <label> --cwd <path> --focus false -> OK workspace:<n>
#   cmux tree --all --json -> windows[].workspaces[].panes[].surfaces[]
#   cmux read-screen --workspace <ref> --surface <ref> --scrollback --lines <n>
#   cmux send --workspace <ref> --surface <ref> -- <text>
#   cmux send-key --workspace <ref> --surface <ref> -- enter|escape|ctrl+c
#   cmux workspace close <workspace-ref>
#
# Requires: cmux (CLI) and jq (JSON parsing). Sourced only through
# bin/fm-backend.sh's fm_backend_source in normal operation.

FM_BACKEND_CMUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_CMUX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

fm_backend_cmux_tool_check() {
  command -v cmux >/dev/null 2>&1 || { echo "error: backend=cmux selected but the 'cmux' CLI is not installed (https://cmux.com)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=cmux selected but 'jq' is not installed (required to parse cmux's JSON output)" >&2; return 1; }
  return 0
}

fm_backend_cmux_version_check() {
  fm_backend_cmux_tool_check || return 1
  cmux version >/dev/null 2>&1 || { echo "error: 'cmux version' failed; is cmux installed and reachable?" >&2; return 1; }
}

fm_backend_cmux_container_ensure() {
  fm_backend_cmux_version_check || return 1
  printf 'cmux'
}

fm_backend_cmux_tree_json() {
  cmux tree --all --json 2>/dev/null
}

fm_backend_cmux_workspace_for_label() {  # <label>
  local label=$1
  fm_backend_cmux_tree_json \
    | jq -r --arg want "$label" '.windows[]?.workspaces[]? | select(.title == $want) | .ref' 2>/dev/null | head -1
}

fm_backend_cmux_surface_for_workspace() {  # <workspace-ref>
  local workspace=$1
  fm_backend_cmux_tree_json \
    | jq -r --arg ws "$workspace" '.windows[]?.workspaces[]? | select(.ref == $ws) | .panes[]?.surfaces[]? | select(.type == "terminal") | .ref' 2>/dev/null | head -1
}

fm_backend_cmux_workspace_exists() {  # <workspace-ref>
  local workspace=$1
  fm_backend_cmux_tree_json \
    | jq -e --arg ws "$workspace" '[.windows[]?.workspaces[]? | select(.ref == $ws)] | length > 0' >/dev/null 2>&1
}

fm_backend_cmux_surface_exists() {  # <workspace-ref> <surface-ref>
  local workspace=$1 surface=$2
  fm_backend_cmux_tree_json \
    | jq -e --arg ws "$workspace" --arg surf "$surface" '[.windows[]?.workspaces[]? | select(.ref == $ws) | .panes[]?.surfaces[]? | select(.ref == $surf and .type == "terminal")] | length > 0' >/dev/null 2>&1
}

fm_backend_cmux_parse_target() {  # <workspace-ref>/<surface-ref>
  local target=$1
  FM_BACKEND_CMUX_WORKSPACE=${target%%/*}
  FM_BACKEND_CMUX_SURFACE=${target#*/}
  [ -n "$FM_BACKEND_CMUX_WORKSPACE" ] && [ -n "$FM_BACKEND_CMUX_SURFACE" ] && [ "$FM_BACKEND_CMUX_SURFACE" != "$target" ]
}

fm_backend_cmux_target_ready() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-}
  fm_backend_cmux_parse_target "$target" || return 1
  if [ -n "$expected_label" ]; then
    local actual
    actual=$(fm_backend_cmux_workspace_for_label "$expected_label" 2>/dev/null || true)
    [ "$actual" = "$FM_BACKEND_CMUX_WORKSPACE" ] || return 1
  fi
  fm_backend_cmux_surface_exists "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE"
}

fm_backend_cmux_create_task() {  # <container> <label> <cwd>
  local label=$2 cwd=$3 existing out workspace surface i
  existing=$(fm_backend_cmux_workspace_for_label "$label" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    echo "error: cmux workspace '$label' already exists ($existing)" >&2
    return 1
  fi
  out=$(CMUX_QUIET=1 cmux workspace create --name "$label" --cwd "$cwd" --focus false 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  workspace=$(printf '%s\n' "$out" | sed -nE 's/.*(workspace:[0-9]+).*/\1/p' | tail -1)
  if [ -z "$workspace" ]; then
    echo "error: cmux workspace create did not return a workspace ref (got '$out')" >&2
    return 1
  fi
  for i in $(seq 1 20); do
    surface=$(fm_backend_cmux_surface_for_workspace "$workspace" 2>/dev/null || true)
    [ -n "$surface" ] && { printf '%s %s' "$workspace" "$surface"; return 0; }
    sleep 0.5
  done
  echo "error: could not find a terminal surface for cmux workspace $workspace ($label)" >&2
  return 1
}

fm_backend_cmux_capture() {  # <target> <lines> [expected-label]
  local target=$1 lines=$2 expected_label=${3:-}
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 1
  cmux read-screen --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" --scrollback --lines "$lines"
}

fm_backend_cmux_normalize_key() {  # <key>
  case "$1" in
    Enter|enter|Return|return) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|Ctrl-c|ctrl-c|Ctrl+C|ctrl+c) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_cmux_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2 expected_label=${3:-} normalized
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 1
  normalized=$(fm_backend_cmux_normalize_key "$key")
  cmux send-key --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" -- "$normalized" >/dev/null
}

fm_backend_cmux_send_literal() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected_label=${3:-}
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 1
  cmux send --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" -- "$text" >/dev/null
}

fm_backend_cmux_send_text_line() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected_label=${3:-}
  fm_backend_cmux_send_literal "$target" "$text" "$expected_label" || return 1
  fm_backend_cmux_send_key "$target" Enter "$expected_label"
}

fm_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 _retries=$3 _enter_sleep=$4 settle=$5 expected_label=${6:-}
  if ! fm_backend_cmux_send_literal "$target" "$text" "$expected_label"; then
    printf 'send-failed'
    return 0
  fi
  [ -z "$settle" ] || sleep "$settle"
  if ! fm_backend_cmux_send_key "$target" Enter "$expected_label"; then
    printf 'send-failed'
    return 0
  fi
  # cmux does not currently expose a verified composer-clear primitive through
  # this adapter, so this path is intentionally lenient like an unreadable tmux
  # pane: if the send commands succeeded, treat the submission as landed.
  printf 'unknown'
}

fm_backend_cmux_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} out line marker_begin="__FM_CMUX_CWD_BEGIN__" marker_end="__FM_CMUX_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 0
  fm_backend_cmux_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" "$expected_label" || return 0
  sleep 0.3
  out=$(fm_backend_cmux_capture "$target" 200 "$expected_label") || return 0
  while IFS= read -r line; do
    if [ "$line" = "$marker_begin" ]; then
      in_block=1
      chunk=""
      continue
    fi
    if [ "$line" = "$marker_end" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

fm_backend_cmux_kill() {  # <target>
  local target=$1 workspace
  if fm_backend_cmux_parse_target "$target"; then
    workspace=$FM_BACKEND_CMUX_WORKSPACE
  else
    workspace=$target
  fi
  cmux workspace close "$workspace" >/dev/null 2>&1 || true
}
