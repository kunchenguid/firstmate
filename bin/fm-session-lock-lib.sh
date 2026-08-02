#!/usr/bin/env bash
# Shared readers and liveness checks for state/.lock.
#
# The lock format is:
#   line 1: harness PID
#   line 2: harness process start time
#   home=<canonical FM_HOME>
#   backend=<terminal backend>, when the holder identity owns a proven endpoint
#   target=<backend target>, when the holder identity owns a proven endpoint
#
# Legacy one-line locks remain valid session locks while their harness PID is
# live, but they do not carry enough evidence for home-bound visible delivery.

FM_SESSION_LOCK_HARNESS_RE='claude|codex|opencode|grok|^pi$'

fm_session_lock_process_start_time() {  # <pid>
  local pid=$1 out
  out=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_session_lock_process_command_text() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null || true)
  printf '%s %s\n' "$(basename "$comm")" "$args"
}

fm_session_lock_command_is_app_server() {  # <command-text>
  printf '%s' "$1" | grep -qE '(^|[[:space:]/])app-server([[:space:]]|$)'
}

fm_session_lock_pid() {  # <lock-file>
  sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$1" 2>/dev/null
}

fm_session_lock_start_time() {  # <lock-file>
  sed -n '2{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$1" 2>/dev/null
}

fm_session_lock_field() {  # <lock-file> <key>
  local lock=$1 key=$2 count
  count=$(grep -c "^${key}=" "$lock" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^${key}=//p" "$lock"
}

fm_session_lock_holder_alive() {  # <lock-file>
  local lock=$1 pid recorded_start current_start command
  pid=$(fm_session_lock_pid "$lock")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  recorded_start=$(fm_session_lock_start_time "$lock")
  if [ -n "$recorded_start" ]; then
    current_start=$(fm_session_lock_process_start_time "$pid") || return 1
    [ "$current_start" = "$recorded_start" ] || return 1
  fi
  command=$(fm_session_lock_process_command_text "$pid") || return 1
  fm_session_lock_command_is_app_server "$command" && return 1
  printf '%s' "$command" | grep -qE "$FM_SESSION_LOCK_HARNESS_RE"
}

fm_session_lock_pid_descends_from() {  # <pid> <ancestor-pid>
  local pid=$1 ancestor=$2 hops=0
  case "$pid:$ancestor" in *[!0-9:]*) return 1 ;; esac
  while [ "$hops" -lt 64 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    hops=$((hops + 1))
  done
  return 1
}

fm_session_lock_supervisor_target_owns_pid() {  # <backend> <target> <holder-pid>
  local backend=$1 target=$2 holder_pid=$3 pane_pid
  case "$backend" in
    tmux)
      pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      pane_pid=$(printf '%s' "$pane_pid" | tr -d '[:space:]')
      case "$pane_pid" in ''|*[!0-9]*) return 1 ;; esac
      fm_session_lock_pid_descends_from "$holder_pid" "$pane_pid"
      ;;
    *) return 1 ;;
  esac
}

fm_session_lock_supervisor_route() {  # <lock-file> <canonical-home>
  local lock=$1 expected_home=$2 recorded_home backend target holder_pid
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  fm_session_lock_holder_alive "$lock" || return 1
  holder_pid=$(fm_session_lock_pid "$lock") || return 1
  recorded_home=$(fm_session_lock_field "$lock" home) || return 1
  [ "$recorded_home" = "$expected_home" ] || return 1
  backend=$(fm_session_lock_field "$lock" backend) || return 1
  target=$(fm_session_lock_field "$lock" target) || return 1
  [ -n "$target" ] || return 1
  fm_session_lock_supervisor_target_owns_pid "$backend" "$target" "$holder_pid" || return 1
  printf '%s\t%s\n' "$backend" "$target"
}
