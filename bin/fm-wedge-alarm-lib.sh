#!/usr/bin/env bash
# fm-wedge-alarm-lib.sh - the shared backend-independent active wedge alert.
#
# docs/wedge-alarm.md owns the channel contract (directives, precedence,
# platform defaults, best-effort semantics, and the test seam); this file is its
# only implementation. It was extracted from bin/fm-supervise-daemon.sh so a
# second caller could reuse it instead of growing a second notification path:
# bin/fm-secondmate-liveness-lib.sh raises it when a wedged secondmate is
# auto-recovered, so an automatic SIGKILL and relaunch is never silent.
#
# The alert exists because a pane-local signal cannot reach an unattended
# captain. The tmux status-line flash the daemon still does itself is a
# cosmetic, client-side OSD with no cross-backend equivalent, so a wedged
# non-tmux primary (the 2026-07-10 overnight incident: a claude-on-herdr
# primary) got NO active signal - only a passive durable marker, which nothing
# surfaces until the next fleet action (that night, 20 escalations sat buffered
# for 8.5h). These helpers add an alert that does not depend on any pane or its
# backend status-line: an OS-level macOS notification, a herdr notification, or
# a captain-supplied command (push to a phone, etc.).
#
# Every channel is best-effort - a missing or failing channel logs and is
# skipped, never crashing the caller's loop - and a caller's own durable marker
# stays the record whether or not any channel fires.
#
# Callers:
#   - the banner title comes from FM_WEDGE_ALARM_TITLE, so each caller names its
#     own wedge rather than inheriting the away-mode wording;
#   - log lines route through wedge_alarm_log, which delegates to an embedder's
#     own `log` when it defines one and otherwise writes to stderr;
#   - FM_WEDGE_ALARM_EXEC is the single notifier execution seam (see
#     wedge_alarm_os_notifier_override), which the test harness forces to a
#     recorder so no test can post a real notification.

WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10
# The caller's own rate-limit cursor: a sourcing caller reads and updates it so
# a long wedge raises at most one alert per window.
# shellcheck disable=SC2034 # read and written by sourcing callers.
WEDGE_ALARM_LAST_EPOCH=0
WEDGE_ALARM_NOTIFIER_PID=
# The notification title every OS channel posts under. A caller sets this to
# name its own wedge; the default preserves the away-mode wording this library
# was extracted from.
FM_WEDGE_ALARM_TITLE=${FM_WEDGE_ALARM_TITLE:-"firstmate: away-mode escalations WEDGED"}

# Route a diagnostic through the embedder's own logger when there is one (the
# daemon's `log` appends to its run log, which its tests assert on), and
# otherwise to stderr so a library-only caller still reports the failure.
wedge_alarm_log() {  # <message...>
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
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

# Resolve the platform's default OS-level channel for `auto`. macOS reaches the
# captain via an osascript Notification Center banner; other platforms have no
# built-in OS channel (the captain wires a command: directive), so this prints
# nothing and wedge_alarm_notify logs that the marker is the only signal.
wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) wedge_alarm_log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      wedge_alarm_log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The single execution seam for every configured notifier channel.
# FM_WEDGE_ALARM_EXEC, when set, REPLACES the real notifier: the resolved channel
# name and summary are handed to that command instead of ever invoking osascript
# or herdr or a captain-supplied command. This is the one injection point the
# test harness forces to a recorder so no test can post a real desktop
# notification - tests/lib.sh defaults it to "discard" for every suite, and
# bin/fm-supervise-daemon.sh's library-mode guard does the same whenever the
# daemon itself is SOURCED. The special value "discard" fires nothing; unset
# means production (an executed daemon or watcher), so the real channels fire.
wedge_alarm_os_notifier_override() {  # <channel> <summary>
  local channel=$1 summary=$2 rc exec_override=${FM_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      wedge_alarm_log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane or multiplexer status-line. The summary and
# the title are passed as argv items (never interpolated into the AppleScript
# source) so their text can never break the script. Best-effort: logs and
# returns 1 on failure.
wedge_alarm_via_osascript() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    wedge_alarm_log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Basso"' \
    -e 'end run' "$summary" "$FM_WEDGE_ALARM_TITLE" >/dev/null 2>&1 && return 0
  wedge_alarm_log "wedge alarm: osascript notification failed"
  return 1
}

# Post a herdr UI notification - herdr's own surface, separate from the pane and
# its status-line. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_herdr() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    wedge_alarm_log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show "$FM_WEDGE_ALARM_TITLE" \
    --body "$summary" --sound request >/dev/null 2>&1 && return 0
  wedge_alarm_log "wedge alarm: herdr notification failed"
  return 1
}

# Run a captain-supplied command with the summary on $1 and on stdin, so an
# alert can reach a phone/pager (ntfy, Slack, SMS) even when the captain is away
# from the machine entirely. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  if [ "${WEDGE_ALARM_EMIT_ACTIVE:-}" != 1 ]; then
    wedge_alarm_emit command "$summary" "$cmd"
    return $?
  fi
  [ -n "$cmd" ] || { wedge_alarm_log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  wedge_alarm_log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

wedge_alarm_emit() {  # <channel> <summary> [<command>]
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${FM_WEDGE_ALARM_EXEC:-} WEDGE_ALARM_EMIT_ACTIVE=1
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      wedge_alarm_log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire every configured active-alert channel, best-effort. Always returns 0: a
# channel failure can never abort a caller's recovery or the daemon loop. Any
# `off` directive disables the alert, regardless of position; an unresolvable
# `auto` (no OS channel on this platform) logs that the caller's durable marker
# is the only signal. Every notifier routes through the test-forced recorder
# seam.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') wedge_alarm_log "wedge alarm: no OS-level alert channel on $(uname); durable marker $marker is the only signal - set config/wedge-alarm (e.g. a command: directive)" ;;
      osascript|herdr) wedge_alarm_emit "$ch" "$summary" || true ;;
      command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true ;;
      *) wedge_alarm_log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}
