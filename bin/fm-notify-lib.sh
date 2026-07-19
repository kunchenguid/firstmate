#!/usr/bin/env bash
# Shared bounded notification execution seam.
#
# This library owns the safety-sensitive process execution used by active
# Firstmate notifications.
# Callers own channel selection, titles, bodies, logging, and durable records.
# Notification text is always passed as argv and stdin data, never interpolated
# into AppleScript or a configured command string.
#
# fm_notify_run_bounded <timeout-seconds> <channel> <command> [args...]
# fm_notify_stop_active
# fm_notify_emit <runner-function> <override> <timeout-seconds> <channel> \
#   <title> <body> <sound> [command-channel-body]
#
# The runner function must accept the same arguments as fm_notify_run_bounded.
# An override replaces every real channel and is invoked as:
#   <override> <resolved-channel> <notification-body>
# The special override value "discard" performs no execution.
# A command channel runs through `sh -c` with the notification body in `$1` and
# on stdin.

FM_NOTIFY_ACTIVE_PID=${FM_NOTIFY_ACTIVE_PID:-}
FM_NOTIFY_LAST_ELAPSED=${FM_NOTIFY_LAST_ELAPSED:-0}
FM_NOTIFY_LAST_TIMEOUT=${FM_NOTIFY_LAST_TIMEOUT:-0}

fm_notify_stop_active() {
  local pid=${FM_NOTIFY_ACTIVE_PID:-}
  [ -n "$pid" ] || return 0
  FM_NOTIFY_ACTIVE_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

fm_notify_run_bounded() {  # <timeout-seconds> <channel> <command> [args...]
  local timeout=$1 _channel=$2 monitor_was_on=0 pid start elapsed rc
  shift 2
  case "$timeout" in
    ''|*[!0-9]*|0) return 125 ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) return 125 ;;
  esac
  "$@" &
  pid=$!
  FM_NOTIFY_ACTIVE_PID=$pid
  FM_NOTIFY_LAST_TIMEOUT=$timeout
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      FM_NOTIFY_LAST_ELAPSED=$elapsed
      fm_notify_stop_active
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  FM_NOTIFY_ACTIVE_PID=
  FM_NOTIFY_LAST_ELAPSED=$((SECONDS - start))
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

fm_notify_emit() {  # <runner> <override> <timeout> <channel> <title> <body> <sound> [command]
  local runner=$1 override=$2 timeout=$3 channel=$4 title=$5 body=$6 sound=$7 command_body=${8:-}
  case "$override" in
    discard) return 0 ;;
    '') ;;
    *) "$runner" "$timeout" "$channel" "$override" "$channel" "$body" >/dev/null 2>&1; return $? ;;
  esac
  case "$channel" in
    osascript)
      command -v osascript >/dev/null 2>&1 || return 127
      "$runner" "$timeout" osascript osascript \
        -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)' \
        -e 'end run' "$title" "$body" "$sound" >/dev/null 2>&1
      ;;
    herdr)
      command -v herdr >/dev/null 2>&1 || return 127
      "$runner" "$timeout" herdr herdr notification show "$title" \
        --body "$body" --sound request >/dev/null 2>&1
      ;;
    command)
      [ -n "$command_body" ] || return 64
      "$runner" "$timeout" command sh -c "$command_body" fm-notify "$body" \
        <<< "$body" >/dev/null 2>&1
      ;;
    *) return 64 ;;
  esac
}
