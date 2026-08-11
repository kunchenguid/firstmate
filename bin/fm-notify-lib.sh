#!/usr/bin/env bash
# Shared best-effort active-notification channels for Firstmate daemons.
#
# Callers set these variables before calling fm_notify:
#   FM_NOTIFY_CONFIG_FILE       channel file; one directive per non-comment line
#   FM_NOTIFY_CHANNEL           optional single-directive override
#   FM_NOTIFY_EXEC              test seam: <cmd> <channel> <summary>; discard = no delivery
#   FM_NOTIFY_TIMEOUT_SECS      per-channel timeout (default 10)
#   FM_NOTIFY_TITLE             notification title
#
# Directives are off, auto/default, osascript, herdr, and command:<cmd>.
# fm_notify returns success only when at least one channel reports successful
# delivery. A disabled, unavailable, unrecognized, or failed set returns 1.

FM_NOTIFY_TIMEOUT_DEFAULT=10
FM_NOTIFY_ACTIVE_PID=

fm_notify_log() {
  local message="${FM_NOTIFY_LOG_PREFIX:-}$*"
  if declare -F log >/dev/null 2>&1; then
    log "$message"
  else
    printf '%s\n' "fm-notify: $message" >&2
  fi
}

fm_notify_configured_channels() {
  local cfg=${FM_NOTIFY_CONFIG_FILE:-} line found=
  if [ -n "${FM_NOTIFY_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_NOTIFY_CHANNEL"
    return 0
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

fm_notify_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript\n' ;;
    *) : ;;
  esac
}

fm_notify_stop_active() {
  local pid=${FM_NOTIFY_ACTIVE_PID:-}
  [ -n "$pid" ] || return 0
  FM_NOTIFY_ACTIVE_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

fm_notify_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_NOTIFY_TIMEOUT_SECS:-$FM_NOTIFY_TIMEOUT_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$FM_NOTIFY_TIMEOUT_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$FM_NOTIFY_TIMEOUT_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) fm_notify_log "$channel notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  FM_NOTIFY_ACTIVE_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      fm_notify_stop_active
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fm_notify_log "$channel notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  FM_NOTIFY_ACTIVE_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

fm_notify_override() {
  local channel=$1 summary=$2 rc override=${FM_NOTIFY_EXEC:-}
  case "$override" in
    '') return 2 ;;
    discard) return 1 ;;
    *)
      fm_notify_run_bounded "$channel" "$override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      fm_notify_log "notifier override exited $rc for channel '$channel'"
      return 1
      ;;
  esac
}

fm_notify_via_osascript() {
  local summary=$1 rc
  fm_notify_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    fm_notify_log "osascript not found; cannot post a macOS notification"
    return 1
  }
  fm_notify_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Basso"' \
    -e 'end run' "$summary" "${FM_NOTIFY_TITLE:-firstmate alert}" >/dev/null 2>&1 && return 0
  fm_notify_log "osascript notification failed"
  return 1
}

fm_notify_via_herdr() {
  local summary=$1 rc
  fm_notify_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    fm_notify_log "herdr not found; cannot post a herdr notification"
    return 1
  }
  fm_notify_run_bounded herdr herdr notification show "${FM_NOTIFY_TITLE:-firstmate alert}" \
    --body "$summary" --sound request >/dev/null 2>&1 && return 0
  fm_notify_log "herdr notification failed"
  return 1
}

fm_notify_via_command() {
  local cmd=$1 summary=$2 rc
  [ -n "$cmd" ] || { fm_notify_log "empty command: channel; nothing to run"; return 1; }
  fm_notify_override command "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  fm_notify_run_bounded command sh -c "$cmd" fm-notify "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  fm_notify_log "command channel exited $rc (command redacted)"
  return 1
}

fm_notify_emit() {
  local channel=$1 summary=$2 cmd=${3:-}
  case "$channel" in
    osascript) fm_notify_via_osascript "$summary" ;;
    herdr) fm_notify_via_herdr "$summary" ;;
    command) fm_notify_via_command "$cmd" "$summary" ;;
    *) return 1 ;;
  esac
}

fm_notify() {
  local summary=$1 marker=${2:-} ch successes=0
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] && channels+=("$ch")
  done < <(fm_notify_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 1
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(fm_notify_platform_default) ;; esac
    case "$ch" in
      '') fm_notify_log "no OS-level alert channel on $(uname); ${marker:-no durable marker}; configure a command: directive" ;;
      osascript|herdr) fm_notify_emit "$ch" "$summary" && successes=$((successes + 1)) ;;
      command:*) fm_notify_emit command "$summary" "${ch#command:}" && successes=$((successes + 1)) ;;
      *) fm_notify_log "unrecognized active-alert channel directive (redacted); ${FM_NOTIFY_UNKNOWN_SUFFIX:-notification skipped}" ;;
    esac
  done
  [ "$successes" -gt 0 ]
}
