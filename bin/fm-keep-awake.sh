#!/usr/bin/env bash
# fm-keep-awake.sh - manage one macOS idle-system-sleep assertion for a Firstmate home.
#
# Usage:
#   fm-keep-awake.sh start [--until-return]
#       Start one managed `caffeinate -i` process.
#       `--until-return` is private to /afk and binds the assertion to the next
#       genuine captain return handled by bin/fm-afk-return.sh.
#   fm-keep-awake.sh stop
#       Stop only this home's identity-matched managed process.
#   fm-keep-awake.sh status
#       Print active or inactive and safely clear a verified stale record.
#
# The private state/.keep-awake record is a single-link mode-0600 regular file.
# Its exact fields and atomic publication are owned here: schema, pid, process
# identity, executable path, and manual|return lifecycle mode. A stop signals
# only when both the recorded PID identity and its `caffeinate -i` command still
# match. Stale or reused PIDs lose only their record and are never signalled.
#
# This intentionally runs no pmset command and changes no persistent power
# setting. `caffeinate -i` prevents idle system sleep only, so display sleep and
# normal lock-screen behavior remain available. The managed process is detached
# with nohup rather than hosted in a model session or runtime terminal surface.
#
# Test seams: FM_KEEP_AWAKE_PLATFORM and FM_KEEP_AWAKE_CAFFEINATE override the
# platform and tool path for portable fake-process tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.keep-awake"
LOCK="$STATE/.keep-awake.lock"
PLATFORM="${FM_KEEP_AWAKE_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"

# keep_awake_start_new's own polling loop is bounded at 40 * 0.05s plus a 0.2s
# stabilization sleep (~2.2s legitimate worst case), so the lock waiter's budget
# must exceed that with margin rather than time out on a slow-but-legitimate
# start. The mkdir-to-identity-file window it guards is normally instantaneous
# (no sleep between them), so a lock still "incomplete" past this age is a
# SIGKILL-interrupted creation, not a legitimate in-flight acquire. fm_path_age
# truncates to whole seconds (see fm-wake-lib.sh's fm_lock_mid_acquire_is_fresh),
# so this floors at 2 like that primitive does.
KEEP_AWAKE_LOCK_MAX_ATTEMPTS=80
KEEP_AWAKE_LOCK_INCOMPLETE_STALE_AFTER=2

FM_KEEP_AWAKE_PID=
FM_KEEP_AWAKE_IDENTITY=
FM_KEEP_AWAKE_TOOL=
FM_KEEP_AWAKE_MODE=

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

keep_awake_error() {
  printf 'fm-keep-awake: %s\n' "$*" >&2
}

keep_awake_supported() {
  [ "$PLATFORM" = Darwin ]
}

keep_awake_host_is_darwin() {
  [ "$(uname -s 2>/dev/null || printf unknown)" = Darwin ]
}

keep_awake_file_mode() {
  if keep_awake_host_is_darwin; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

keep_awake_file_device() {
  if keep_awake_host_is_darwin; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

keep_awake_file_link_count() {
  if keep_awake_host_is_darwin; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

keep_awake_state_prepare() {
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  else
    (umask 077; mkdir -p -- "$STATE") || return 1
  fi
}

keep_awake_state_device() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  keep_awake_file_device "$STATE"
}

keep_awake_private_file_valid() {  # <path>
  local path=$1 device
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  device=$(keep_awake_state_device) || return 1
  [ "$(keep_awake_file_mode "$path")" = 600 ] \
    && [ "$(keep_awake_file_link_count "$path")" = 1 ] \
    && [ "$(keep_awake_file_device "$path")" = "$device" ]
}

keep_awake_record_load() {
  local line schema_seen=0 pid_seen=0 identity_seen=0 tool_seen=0 mode_seen=0
  FM_KEEP_AWAKE_PID=
  FM_KEEP_AWAKE_IDENTITY=
  FM_KEEP_AWAKE_TOOL=
  FM_KEEP_AWAKE_MODE=
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    return 1
  fi
  keep_awake_private_file_valid "$RECORD" || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        [ "$schema_seen" -eq 0 ] || return 2
        [ "${line#schema=}" = fm-keep-awake.v1 ] || return 2
        schema_seen=1
        ;;
      pid=*)
        [ "$pid_seen" -eq 0 ] || return 2
        FM_KEEP_AWAKE_PID=${line#pid=}
        pid_seen=1
        ;;
      identity=*)
        [ "$identity_seen" -eq 0 ] || return 2
        FM_KEEP_AWAKE_IDENTITY=${line#identity=}
        identity_seen=1
        ;;
      tool=*)
        [ "$tool_seen" -eq 0 ] || return 2
        FM_KEEP_AWAKE_TOOL=${line#tool=}
        tool_seen=1
        ;;
      mode=*)
        [ "$mode_seen" -eq 0 ] || return 2
        FM_KEEP_AWAKE_MODE=${line#mode=}
        mode_seen=1
        ;;
      *) return 2 ;;
    esac
  done < "$RECORD"
  [ "$schema_seen" -eq 1 ] && [ "$pid_seen" -eq 1 ] \
    && [ "$identity_seen" -eq 1 ] && [ "$tool_seen" -eq 1 ] \
    && [ "$mode_seen" -eq 1 ] || return 2
  case "$FM_KEEP_AWAKE_PID" in ''|*[!0-9]*) return 2 ;; esac
  case "$FM_KEEP_AWAKE_IDENTITY" in ''|*$'\t'*|*$'\r'*) return 2 ;; esac
  case "$FM_KEEP_AWAKE_TOOL" in /*) ;; *) return 2 ;; esac
  case "$FM_KEEP_AWAKE_TOOL" in *$'\t'*|*$'\r'*) return 2 ;; esac
  case "$FM_KEEP_AWAKE_MODE" in manual|return) ;; *) return 2 ;; esac
}

keep_awake_record_clear() {
  keep_awake_private_file_valid "$RECORD" || return 1
  rm -f -- "$RECORD" || return 1
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]
}

keep_awake_record_write() {  # <pid> <identity> <tool> <mode>
  local pid=$1 identity=$2 tool=$3 mode=$4 tmp
  tmp=$(umask 077; mktemp "$STATE/.keep-awake.pending.XXXXXX") || return 1
  if ! {
    printf 'schema=fm-keep-awake.v1\n'
    printf 'pid=%s\n' "$pid"
    printf 'identity=%s\n' "$identity"
    printf 'tool=%s\n' "$tool"
    printf 'mode=%s\n' "$mode"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! keep_awake_private_file_valid "$tmp" \
    || ! mv -f -- "$tmp" "$RECORD" || ! keep_awake_private_file_valid "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

keep_awake_command_state() {  # <pid> <tool>: 0 exact process, 1 mismatch, 2 unreadable
  local pid=$1 tool=$2 command
  command=$(ps -p "$pid" -o command= 2>/dev/null) || return 2
  command=$(printf '%s' "$command" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$command" ] || return 2
  case "$command" in
    *"$tool -i") return 0 ;;
    *) return 1 ;;
  esac
}

# With a successfully loaded record, classify its process as active, stale, or
# uncertain. A reused PID is stale only after its identity or fixed command
# mismatches; an unreadable live process remains uncertain and is never killed.
keep_awake_process_state() {  # -> 0 active, 1 stale, 2 uncertain
  local actual command_state
  if ! fm_pid_alive "$FM_KEEP_AWAKE_PID"; then
    return 1
  fi
  actual=$(fm_pid_identity "$FM_KEEP_AWAKE_PID" 2>/dev/null) || return 2
  [ "$actual" = "$FM_KEEP_AWAKE_IDENTITY" ] || return 1
  keep_awake_command_state "$FM_KEEP_AWAKE_PID" "$FM_KEEP_AWAKE_TOOL"
  command_state=$?
  case "$command_state" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

keep_awake_lock_owner_state() {  # -> 0 live identity, 1 stale, 2 incomplete, 3 uncertain
  local pid expected actual
  [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  [ -f "$LOCK/pid" ] && [ ! -L "$LOCK/pid" ] \
    && [ -f "$LOCK/pid-identity" ] && [ ! -L "$LOCK/pid-identity" ] || return 2
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  expected=$(cat "$LOCK/pid-identity" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$expected" ] || return 2
  fm_pid_alive "$pid" || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 3
  [ "$actual" = "$expected" ] && return 0
  return 1
}

keep_awake_lock_discard_stale() {
  [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  for file in "$LOCK/pid" "$LOCK/pid-identity"; do
    if [ -e "$file" ] || [ -L "$file" ]; then
      [ -f "$file" ] && [ ! -L "$file" ] || return 1
      rm -f -- "$file" || return 1
    fi
  done
  rmdir "$LOCK" 2>/dev/null
}

keep_awake_lock_acquire() {
  local attempt=0 state identity
  while [ "$attempt" -lt "$KEEP_AWAKE_LOCK_MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if (umask 077; mkdir "$LOCK") 2>/dev/null; then
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rmdir "$LOCK" 2>/dev/null || true
        return 1
      }
      if printf '%s\n' "$$" > "$LOCK/pid" \
        && printf '%s\n' "$identity" > "$LOCK/pid-identity" \
        && chmod 0600 "$LOCK/pid" "$LOCK/pid-identity"; then
        return 0
      fi
      keep_awake_lock_discard_stale || true
      return 1
    fi
    keep_awake_lock_owner_state
    state=$?
    case "$state" in
      0|3) sleep 0.05 ;;
      1)
        keep_awake_lock_discard_stale || return 1
        ;;
      2)
        if [ "$(fm_path_age "$LOCK")" -ge "$KEEP_AWAKE_LOCK_INCOMPLETE_STALE_AFTER" ]; then
          keep_awake_lock_discard_stale || return 1
        else
          sleep 0.05
        fi
        ;;
      *) return 1 ;;
    esac
  done
  return 3
}

keep_awake_lock_release() {
  local pid identity actual
  [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 0
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$LOCK/pid-identity" 2>/dev/null || true)
  [ "$pid" = "$$" ] && [ -n "$identity" ] || return 0
  actual=$(fm_pid_identity "$$" 2>/dev/null) || return 0
  [ "$actual" = "$identity" ] || return 0
  keep_awake_lock_discard_stale
}

keep_awake_mode_label() {
  case "$1" in
    manual) printf 'manual' ;;
    return) printf 'until return' ;;
  esac
}

keep_awake_stop_recorded() {  # loaded, active record only
  local pid=$FM_KEEP_AWAKE_PID expected=$FM_KEEP_AWAKE_IDENTITY current attempt=0
  if ! kill -TERM "$pid" 2>/dev/null; then
    keep_awake_error "could not signal managed pid $pid; retaining its record"
    return 1
  fi
  while [ "$attempt" -lt 40 ]; do
    attempt=$((attempt + 1))
    if ! fm_pid_alive "$pid"; then
      keep_awake_record_clear || {
        keep_awake_error "managed process stopped but its record could not be removed"
        return 1
      }
      printf 'keep-awake: stopped\n'
      return 0
    fi
    current=$(fm_pid_identity "$pid" 2>/dev/null) || {
      sleep 0.05
      continue
    }
    if [ "$current" != "$expected" ]; then
      keep_awake_record_clear || {
        keep_awake_error "managed process identity changed and its record could not be removed"
        return 1
      }
      printf 'keep-awake: stopped (original process exited)\n'
      return 0
    fi
    sleep 0.05
  done
  keep_awake_error "managed pid $pid did not exit after SIGTERM; retaining its record"
  return 1
}

keep_awake_abort_started_process() {  # <pid> <identity> <tool>
  local pid=$1 identity=$2 tool=$3 actual attempt=0
  fm_pid_alive "$pid" || return 0
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$actual" = "$identity" ] || return 0
  keep_awake_command_state "$pid" "$tool" || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  while [ "$attempt" -lt 40 ]; do
    attempt=$((attempt + 1))
    fm_pid_alive "$pid" || return 0
    actual=$(fm_pid_identity "$pid" 2>/dev/null || true)
    [ "$actual" = "$identity" ] || return 0
    sleep 0.05
  done
  return 1
}

keep_awake_start_new() {  # <manual|return>
  local mode=$1 tool pid='' identity='' current='' attempt=0 command_state
  tool=${FM_KEEP_AWAKE_CAFFEINATE:-/usr/bin/caffeinate}
  case "$tool" in /*) ;; *) keep_awake_error "caffeinate path must be absolute"; return 1 ;; esac
  if [ ! -x "$tool" ]; then
    keep_awake_error "caffeinate is unavailable at $tool"
    return 3
  fi
  nohup "$tool" -i </dev/null >/dev/null 2>&1 &
  pid=$!
  while [ "$attempt" -lt 40 ]; do
    attempt=$((attempt + 1))
    if ! fm_pid_alive "$pid"; then
      keep_awake_error "caffeinate exited before its assertion could be recorded"
      return 1
    fi
    identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ -n "$identity" ]; then
      keep_awake_command_state "$pid" "$tool"
      command_state=$?
      if [ "$command_state" -eq 0 ]; then
        # A script-based test double can pass through an interpreter before it
        # reaches its steady command line. Record only a stable identity, never
        # that transient launcher process.
        sleep 0.2
        current=$(fm_pid_identity "$pid" 2>/dev/null || true)
        if [ "$current" = "$identity" ] \
          && keep_awake_command_state "$pid" "$tool"; then
          if keep_awake_record_write "$pid" "$identity" "$tool" "$mode"; then
            printf 'keep-awake: active (%s)\n' "$(keep_awake_mode_label "$mode")"
            return 0
          fi
          if keep_awake_abort_started_process "$pid" "$identity" "$tool"; then
            keep_awake_error "could not publish the managed-process record; assertion stopped"
          else
            keep_awake_error "could not publish the managed-process record or confirm cleanup"
          fi
          return 1
        fi
      fi
    fi
    sleep 0.05
  done
  if [ -n "$identity" ] && keep_awake_abort_started_process "$pid" "$identity" "$tool"; then
    keep_awake_error "caffeinate process did not reach the expected command shape; assertion stopped"
  else
    keep_awake_error "caffeinate process did not reach the expected command shape; cleanup is unconfirmed"
  fi
  return 1
}

keep_awake_start() {  # <manual|return>
  local mode=$1 loaded process
  keep_awake_record_load
  loaded=$?
  case "$loaded" in
    1) keep_awake_start_new "$mode"; return ;;
    2) keep_awake_error "unsafe managed-process record; refusing to replace it"; return 1 ;;
  esac
  keep_awake_process_state
  process=$?
  case "$process" in
    0) printf 'keep-awake: active (%s)\n' "$(keep_awake_mode_label "$FM_KEEP_AWAKE_MODE")"; return 0 ;;
    1)
      keep_awake_record_clear || { keep_awake_error "stale record could not be removed"; return 1; }
      keep_awake_start_new "$mode"
      ;;
    *) keep_awake_error "managed process is unreadable; retaining its record"; return 1 ;;
  esac
}

keep_awake_status() {
  local loaded process
  keep_awake_record_load
  loaded=$?
  case "$loaded" in
    1) printf 'keep-awake: inactive\n'; return 0 ;;
    2) keep_awake_error "unsafe managed-process record; refusing to inspect it"; return 1 ;;
  esac
  keep_awake_process_state
  process=$?
  case "$process" in
    0) printf 'keep-awake: active (%s)\n' "$(keep_awake_mode_label "$FM_KEEP_AWAKE_MODE")"; return 0 ;;
    1)
      keep_awake_record_clear || { keep_awake_error "stale record could not be removed"; return 1; }
      printf 'keep-awake: inactive (stale record cleared)\n'
      ;;
    *) keep_awake_error "managed process is unreadable; retaining its record"; return 1 ;;
  esac
}

keep_awake_stop() {  # [return-only]
  local return_only=${1:-0} loaded process
  keep_awake_record_load
  loaded=$?
  case "$loaded" in
    1) printf 'keep-awake: inactive\n'; return 0 ;;
    2) keep_awake_error "unsafe managed-process record; refusing to stop it"; return 1 ;;
  esac
  if [ "$return_only" = 1 ] && [ "$FM_KEEP_AWAKE_MODE" = manual ]; then
    printf 'keep-awake: active (manual; return does not stop it)\n'
    return 0
  fi
  keep_awake_process_state
  process=$?
  case "$process" in
    1)
      keep_awake_record_clear || { keep_awake_error "stale record could not be removed"; return 1; }
      printf 'keep-awake: inactive (stale record cleared)\n'
      return 0
      ;;
    2) keep_awake_error "managed process is unreadable; retaining its record"; return 1 ;;
  esac
  keep_awake_stop_recorded
}

main() {
  local command=${1:-status} mode=manual rc
  case "$command" in
    start)
      case "${2:-}" in
        '') ;;
        --until-return) mode='return' ;;
        *) usage >&2; return 2 ;;
      esac
      [ "$#" -le 2 ] || { usage >&2; return 2; }
      ;;
    stop|status|stop-return-bound)
      [ "$#" -eq 1 ] || { usage >&2; return 2; }
      ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac

  if ! keep_awake_supported; then
    keep_awake_error "macOS is required for caffeinate idle-sleep assertions"
    return 3
  fi
  keep_awake_state_prepare || { keep_awake_error "state directory is unsafe or unavailable"; return 1; }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  keep_awake_lock_acquire
  rc=$?
  case "$rc" in
    0) ;;
    3) keep_awake_error "another keep-awake operation still holds its identity-matched lock"; return 1 ;;
    *) keep_awake_error "could not acquire the keep-awake lock safely"; return 1 ;;
  esac
  trap 'keep_awake_lock_release' EXIT
  case "$command" in
    start) keep_awake_start "$mode"; rc=$? ;;
    stop) keep_awake_stop; rc=$? ;;
    status) keep_awake_status; rc=$? ;;
    stop-return-bound) keep_awake_stop 1; rc=$? ;;
  esac
  keep_awake_lock_release
  trap - EXIT
  return "$rc"
}

main "$@"
