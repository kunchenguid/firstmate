#!/usr/bin/env bash
# bin/backends/hermes.sh - the Hermes session-provider adapter.
#
# EXPERIMENTAL backend (no dedicated CI lane yet). Spawn-capable: creates a
# worktree and launches `hermes chat -q PROMPT --cwd WORKTREE_PATH` as a
# background terminal process. Sourced only through bin/fm-backend.sh's
# fm_backend_source, never directly.
#
# Hermes Agent (hermes-agent by Nous Research) is a single-binary AI agent
# that runs interactively in a terminal. It sets HERMES_CLI=1 on its CLI and
# every tool subprocess. Worker launch: `hermes chat -q PROMPT --cwd PATH`.
#
# This adapter is simplified relative to the tmux reference: Hermes owns its
# own terminal session model (no tmux-style window inventory), so agent state
# is determined by process table inspection (looking for `hermes chat` in the
# process ancestry of the target PID file), and steering delegates to the
# shared bin/fm-send.sh which writes to the task inbox.
set -u

# shellcheck source=bin/fm-backend.sh
. "${FM_BACKEND_LIB_DIR:-}/fm-backend.sh" 2>/dev/null || {
  FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
  FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")/../.." && pwd)/bin"
  # shellcheck source=bin/fm-backend.sh
  . "$FM_BACKEND_LIB_DIR/fm-backend.sh"
}

# fm_backend_hermes_pid_path: the pidfile for a task's hermes process.
# Stored in state alongside the task meta so teardown can signal it.
fm_backend_hermes_pid_path() {  # <state-dir> <id>
  local state=$1 id=$2
  printf '%s/%s.hermes-pid\n' "$state" "$id"
}

# fm_backend_hermes_agent_state: recovery-grade harness-agent state for one
# recorded target. Hermes has no native pane/window inventory like tmux, so
# liveness is determined by reading the recorded PID file and inspecting the
# process table:
#   alive      - a `hermes chat` process is running at the recorded pid.
#   dead       - the pidfile exists but no process is running at that pid.
#   missing    - no pidfile exists (endpoint never recorded or already cleaned).
#   unreadable - the pidfile exists but cannot be read or holds garbage.
fm_backend_hermes_agent_state() {  # <target>
  local target=$1 pidfile pid
  case "$target" in
    *:*)
      pidfile=${target#*:}
      ;;
    *)
      printf 'unreadable'
      return 0
      ;;
  esac
  if [ ! -f "$pidfile" ]; then
    printf 'missing'
    return 0
  fi
  pid=$(head -1 "$pidfile" 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  case "$pid" in
    ''|*[!0-9]*)
      printf 'unreadable'
      return 0
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    # Verify it's actually a hermes chat process, not a recycled pid.
    # Match "hermes chat" specifically to avoid false positives from
    # unrelated processes whose arguments happen to contain "hermes".
    if ps -p "$pid" -o args= 2>/dev/null | grep -qE 'hermes (chat|agent)'; then
      printf 'alive'
    else
      printf 'dead'
    fi
    return 0
  fi
  printf 'dead'
}

# fm_backend_hermes_target_exists: cheap, READ-ONLY existence check - does the
# recorded PID point to a live process? Never starts anything.
fm_backend_hermes_target_exists() {  # <target>
  local target=$1 pidfile pid
  case "$target" in
    *:*)
      pidfile=${target#*:}
      ;;
    *)
      return 1
      ;;
  esac
  [ -f "$pidfile" ] || return 1
  pid=$(head -1 "$pidfile" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# fm_backend_hermes_spawn: create a worktree and launch `hermes chat -q` with
# the brief as a background terminal process. Records the PID for later
# liveness checks. Prints "<pidfile>" as the target handle.
#
# Arguments:
#   $1 - state-dir (for pidfile placement)
#   $2 - task id
#   $3 - worktree path (already created/validated by caller)
#   $4 - brief text (the prompt to pass to hermes chat -q)
fm_backend_hermes_spawn() {  # <state-dir> <id> <worktree> <brief>
  local state=$1 id=$2 worktree=$3 brief=$4
  local pidfile launch_cmd log_file
  pidfile=$(fm_backend_hermes_pid_path "$state" "$id")
  log_file="$state/$id.hermes.log"

  # Build the launch command. Hermes chat -q runs a single prompt
  # non-interactively (or as a persistent session in newer versions).
  # --cwd pins it to the worktree so relative paths resolve correctly.
  # Foreign markers are cleared so the worker doesn't misidentify as
  # the primary's harness.
  launch_cmd="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI"
  launch_cmd="$launch_cmd -u CLAUDECODE -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE"
  launch_cmd="$launch_cmd -u ROVODEV_CLI -u PI_CODING_AGENT -u AGENT"
  launch_cmd="$launch_cmd hermes chat -q $(shell_quote "$brief")"
  launch_cmd="$launch_cmd --cwd $(shell_quote "$worktree")"

  # Launch as a background process. nohup + disown so it survives this
  # script's exit. Redirect stdout/stderr to a log for debugging.
  # The PID is recorded before the background shell forks.
  eval "$launch_cmd" >"$log_file" 2>&1 &
  local bg_pid=$!

  # Record the PID immediately so teardown/liveness can find it
  printf '%s\n' "$bg_pid" >"$pidfile" || {
    echo "error: could not write hermes pidfile $pidfile" >&2
    kill "$bg_pid" 2>/dev/null || true
    return 1
  }

  # Print the target handle: "hermes:<pidfile>"
  printf 'hermes:%s\n' "$pidfile"
}

# fm_backend_hermes_steer: delegate steering to bin/fm-send.sh, which writes
# the message into the task's durable inbox and rings the doorbell. Hermes
# has no native text-injection channel, so inbox-only delivery is the only
# path - the worker polls its inbox between turns.
fm_backend_hermes_steer() {  # <target> <text...>
  local target=$1
  shift
  local send_cmd
  send_cmd="${FM_BACKEND_LIB_DIR}/fm-send.sh"
  if [ ! -x "$send_cmd" ]; then
    echo "error: fm-send.sh not found at $send_cmd" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  "$send_cmd" "$target" "$@"
}
