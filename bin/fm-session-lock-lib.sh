#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# This file is sourced by scripts and has no side effects on source.

# Historical lock owners still exclude a second writer; recognizing one never
# makes it selectable, dispatchable, or controllable.
# shellcheck source=bin/fm-control-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"

# Primary session locks belong to Pi or Codex; TraeX remains worker-only.
FM_HARNESS_RE='codex|^pi$|^pi-launcher$'
FM_HARNESS_NAMES=(codex pi pi-launcher)

# Exact executable path components supplement kernel process names.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when a process identifies a maintained primary harness.
fm_harness_process_matches() { # <comm> <args>
  local comm=$1 args=$2 base argv0
  base=$(basename -- "$comm")
  printf '%s' "$base" | grep -qE "$FM_HARNESS_RE" && return 0
  argv0=${args%% *}
  fm_harness_path_name "$comm" >/dev/null && return 0
  fm_harness_path_name "$argv0" >/dev/null && return 0
  case "$comm" in
    *node*|*python*)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && return 0 ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# The innermost maintained harness is the session owner.
fm_harness_ancestry_pids() {
  local pid=$$ comm args printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the session pid used when acquiring the home lock.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" && return 0
  local path component
  for path in "$comm" "${args%% *}"; do
    while [ -n "$path" ] && [ "$path" != / ] && [ "$path" != . ]; do
      component=$(basename -- "$path")
      fm_control_harness_removed "$component" && return 0
      case "$path" in */*) path=${path%/*} ;; *) break ;; esac
    done
  done
  return 1
}

# True only when the recorded lock owner is this process's harness ancestor.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
