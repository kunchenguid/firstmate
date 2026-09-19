#!/usr/bin/env bash
# fm-afk-daemon-run.sh - the away/quiet daemon's restart supervisor, and the
# command bin/fm-afk-launch.sh runs inside the non-visible tracked terminal it
# creates. It is never started by hand and never runs under shell `&`.
#
# WHY IT EXISTS. The daemon is a single long-lived process and its watcher is
# its own child, so one signal takes out the whole supervision chain, and
# state/.afk outlives it under every signal. Recovering from that through a
# model turn is circular: in away mode turns exist only because the daemon
# injects them, so a dead daemon produces no turn to notice itself with, and a
# home out of quota cannot complete a turn at all. This loop needs no turn and
# no quota, which is what makes it the recovery path rather than a convenience.
#
# WHAT IT DOES. It runs bin/fm-afk-start.sh in the foreground, one generation at
# a time. When that generation exits while the away posture still stands and no
# deliberate shutdown is under way, it records the death in the restart journal
# and the daemon log, raises the configured wedge alarm so the captain learns
# the outage happened, and starts the next generation. Repeated immediate deaths
# back off exactly as the daemon's own watcher crash guard does, so a daemon
# that cannot start never becomes a spin.
#
# STANDING DOWN. The loop must never fight a deliberate shutdown, so it stops
# for any of three independent reasons, each checked before a restart:
#   - state/.afk-daemon-stopping names THIS loop's pid (bin/fm-afk-launch.sh
#     stop writes it before it signals the daemon). The pid binding is what
#     keeps a record leaked by an interrupted stop from silencing a later loop.
#   - state/.afk is gone, so the posture itself has ended.
#   - this process was signalled: TERM and INT are forwarded to the current
#     generation and end the loop.
# It publishes its own pid and process identity in state/.afk-daemon-run so
# `stop` can signal it by exact identity, and removes that record on the way out.
#
# Usage: fm-afk-daemon-run.sh
#   FM_HOME, FM_STATE_OVERRIDE  resolve the home and its state dir, as elsewhere.
#   FM_AFK_STATE_PREPARED=1     set by the launcher: the away flag and the
#                               stale-artifact clear already happened
#                               transactionally at entry, so a restart must not
#                               repeat the clear and discard the escalations the
#                               dead generation had buffered.
#   FM_AFK_DAEMON_ENTRY         test seam: the command each generation runs
#                               (default bin/fm-afk-start.sh).
#   FM_AFK_RESTART_MIN_ALIVE_SECS   a generation shorter than this counts toward
#                               the crash-loop guard (default 30).
#   FM_AFK_RESTART_DELAY_SECS   pause before an ordinary restart (default 2).
#   FM_AFK_RESTART_CRASH_THRESHOLD / _CRASH_WINDOW_SECS / _CRASH_BACKOFF_SECS
#                               crash-loop guard (defaults 5, 300, 300).
#   FM_AFK_RESTART_ALARM_SECS   minimum seconds between active alerts, so a
#                               crash loop cannot spam the captain (default 300).
set -u

FM_AFK_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_RUN_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_RUN_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_RUN_RECORD="$FM_AFK_RUN_STATE/.afk-daemon-run"
FM_AFK_RUN_STOPPING="$FM_AFK_RUN_STATE/.afk-daemon-stopping"
FM_AFK_RUN_JOURNAL="$FM_AFK_RUN_STATE/.afk-daemon-restarts"
FM_AFK_RUN_LOG="$FM_AFK_RUN_STATE/.supervise-daemon.log"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_RUN_DIR/fm-wake-lib.sh"
# The single owner of the backend-independent active alert. Sourced rather than
# reimplemented so a restart reaches the captain through exactly the channels
# config/wedge-alarm already configures for the escalation wedge.
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$FM_AFK_RUN_DIR/fm-wedge-alarm-lib.sh"

# The alarm library logs through the embedder's log() when one exists; the
# daemon's own log file is the right destination, so restarts and the daemon's
# own start/stop lines read as one chronology.
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$FM_AFK_RUN_LOG" 2>/dev/null || true
}

FM_AFK_RUN_ENTRY="${FM_AFK_DAEMON_ENTRY:-$FM_AFK_RUN_DIR/fm-afk-start.sh}"
FM_AFK_RUN_MIN_ALIVE=${FM_AFK_RESTART_MIN_ALIVE_SECS:-30}
FM_AFK_RUN_DELAY=${FM_AFK_RESTART_DELAY_SECS:-2}
FM_AFK_RUN_CRASH_THRESHOLD=${FM_AFK_RESTART_CRASH_THRESHOLD:-5}
FM_AFK_RUN_CRASH_WINDOW=${FM_AFK_RESTART_CRASH_WINDOW_SECS:-300}
FM_AFK_RUN_CRASH_BACKOFF=${FM_AFK_RESTART_CRASH_BACKOFF_SECS:-300}
FM_AFK_RUN_ALARM_INTERVAL=${FM_AFK_RESTART_ALARM_SECS:-300}

FM_AFK_RUN_CHILD=""
FM_AFK_RUN_ALARM_LAST=0

fm_afk_run_record_write() {
  local identity
  mkdir -p "$FM_AFK_RUN_STATE" || return 1
  identity=$(fm_pid_identity "$$" 2>/dev/null) || identity=""
  printf '%s\n%s\n' "$$" "$identity" > "$FM_AFK_RUN_RECORD" 2>/dev/null || return 1
}

fm_afk_run_record_remove() {
  local pid
  pid=$(sed -n '1p' "$FM_AFK_RUN_RECORD" 2>/dev/null) || return 0
  [ "$pid" = "$$" ] || return 0
  rm -f "$FM_AFK_RUN_RECORD" 2>/dev/null || true
}

# A deliberate shutdown is one whose marker names THIS loop. An interrupted stop
# that left a marker behind therefore cannot silence a later loop, and a fresh
# entry clears the marker before it creates the terminal in any case.
fm_afk_run_stopping() {
  local pid
  pid=$(sed -n '1p' "$FM_AFK_RUN_STOPPING" 2>/dev/null) || return 1
  [ "$pid" = "$$" ]
}

fm_afk_run_posture_ended() {
  [ ! -e "$FM_AFK_RUN_STATE/.afk" ]
}

fm_afk_run_exit() {  # <reason>
  log "daemon restart supervisor standing down: $1"
  fm_afk_run_record_remove
  exit 0
}

# Forward the signal to the generation in flight so its own cleanup trap flushes
# buffered escalations while state/.afk is still present, then stand down. This
# is the second, independent guarantee that the loop cannot outlive `stop`: it
# holds even when the recorded terminal cannot be closed by id.
fm_afk_run_signalled() {  # <name>
  FM_AFK_RUN_SIGNALLED=$1
  if [ -n "$FM_AFK_RUN_CHILD" ]; then
    kill -TERM "$FM_AFK_RUN_CHILD" 2>/dev/null || true
  fi
}
FM_AFK_RUN_SIGNALLED=""

# Append the death to the durable journal the return brief reads, so an outage
# that happened while nobody was watching is still reported at return rather
# than inferred from a gap in the log.
fm_afk_run_journal_append() {  # <generation> <rc> <uptime-seconds>
  printf '%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" "$3" \
    >> "$FM_AFK_RUN_JOURNAL" 2>/dev/null || true
}

fm_afk_run_alarm() {  # <generation> <rc> <uptime-seconds>
  local now summary
  now=$(date '+%s')
  if [ "$FM_AFK_RUN_ALARM_LAST" -gt 0 ] \
    && [ $((now - FM_AFK_RUN_ALARM_LAST)) -lt "$FM_AFK_RUN_ALARM_INTERVAL" ]; then
    return 0
  fi
  FM_AFK_RUN_ALARM_LAST=$now
  summary="the away-mode supervisor daemon died after ${3}s (generation $1, exit $2) and was restarted - see $FM_AFK_RUN_JOURNAL"
  wedge_alarm_notify "$summary" "$FM_AFK_RUN_JOURNAL" \
    "firstmate: away-mode supervisor daemon RESTARTED" || true
}

# Deaths inside the crash window, trimmed to that window on every append. The
# result is a global rather than stdout because a command substitution would
# evaluate this in a subshell and throw the window away with it.
FM_AFK_RUN_CRASH_TIMES=()
FM_AFK_RUN_BACKOFF=0
fm_afk_run_crash_backoff() {  # sets FM_AFK_RUN_BACKOFF
  local now t
  local -a keep=()
  now=$(date '+%s')
  for t in ${FM_AFK_RUN_CRASH_TIMES[@]+"${FM_AFK_RUN_CRASH_TIMES[@]}"}; do
    [ $((now - t)) -lt "$FM_AFK_RUN_CRASH_WINDOW" ] && keep+=("$t")
  done
  keep+=("$now")
  FM_AFK_RUN_CRASH_TIMES=("${keep[@]}")
  if [ "${#FM_AFK_RUN_CRASH_TIMES[@]}" -ge "$FM_AFK_RUN_CRASH_THRESHOLD" ]; then
    FM_AFK_RUN_CRASH_TIMES=()
    FM_AFK_RUN_BACKOFF=$FM_AFK_RUN_CRASH_BACKOFF
    return 0
  fi
  FM_AFK_RUN_BACKOFF=$FM_AFK_RUN_DELAY
}

# Sleep in one-second steps so a signal or a `stop` marker ends a long crash
# backoff promptly instead of leaving the home unsupervised for its full length.
fm_afk_run_sleep() {  # <seconds>
  local remaining=$1
  while [ "$remaining" -gt 0 ]; do
    [ -z "$FM_AFK_RUN_SIGNALLED" ] || return 0
    fm_afk_run_stopping && return 0
    fm_afk_run_posture_ended && return 0
    sleep 1
    remaining=$((remaining - 1))
  done
}

fm_afk_run_main() {
  local generation=0 started rc uptime

  case "${1:-}" in
    '') ;;
    -h|--help) sed -n '/^# Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; return 0 ;;
    *) echo "usage: fm-afk-daemon-run.sh" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_RUN_STATE" || return 1
  [ -x "$FM_AFK_RUN_ENTRY" ] || { echo "fm-afk-daemon-run: entry not executable: $FM_AFK_RUN_ENTRY" >&2; return 1; }

  trap 'fm_afk_run_signalled TERM' TERM
  trap 'fm_afk_run_signalled INT' INT

  fm_afk_run_record_write || {
    echo "fm-afk-daemon-run: could not publish the restart supervisor record" >&2
    return 1
  }
  log "daemon restart supervisor starting (pid $$); entry=$FM_AFK_RUN_ENTRY"

  while true; do
    fm_afk_run_stopping && fm_afk_run_exit "a deliberate shutdown is under way"
    fm_afk_run_posture_ended && fm_afk_run_exit "the away posture has ended"
    [ -z "$FM_AFK_RUN_SIGNALLED" ] || fm_afk_run_exit "signalled ($FM_AFK_RUN_SIGNALLED)"

    generation=$((generation + 1))
    started=$(date '+%s')
    "$FM_AFK_RUN_ENTRY" &
    FM_AFK_RUN_CHILD=$!
    # A trapped signal interrupts `wait` while the child is still running, so
    # only a genuinely reaped child ends this wait; re-waiting a reaped pid
    # would report "not a child" and lose its real exit status.
    rc=0
    while :; do
      if wait "$FM_AFK_RUN_CHILD" 2>/dev/null; then rc=0; else rc=$?; fi
      kill -0 "$FM_AFK_RUN_CHILD" 2>/dev/null || break
    done
    FM_AFK_RUN_CHILD=""
    uptime=$(( $(date '+%s') - started ))

    fm_afk_run_stopping && fm_afk_run_exit "a deliberate shutdown is under way"
    fm_afk_run_posture_ended && fm_afk_run_exit "the away posture has ended"
    [ -z "$FM_AFK_RUN_SIGNALLED" ] || fm_afk_run_exit "signalled ($FM_AFK_RUN_SIGNALLED)"

    log "ERROR: the away-mode daemon exited rc=$rc after ${uptime}s with the away posture still standing; restarting (generation $generation)"
    fm_afk_run_journal_append "$generation" "$rc" "$uptime"
    fm_afk_run_alarm "$generation" "$rc" "$uptime"

    if [ "$uptime" -lt "$FM_AFK_RUN_MIN_ALIVE" ]; then
      fm_afk_run_crash_backoff
    else
      FM_AFK_RUN_CRASH_TIMES=()
      FM_AFK_RUN_BACKOFF=$FM_AFK_RUN_DELAY
    fi
    [ "$FM_AFK_RUN_BACKOFF" -gt 0 ] && fm_afk_run_sleep "$FM_AFK_RUN_BACKOFF"
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_run_main "$@"
else
  # Library mode: only a test reaches these functions by sourcing. Default the
  # notifier seam to "discard" exactly as bin/fm-supervise-daemon.sh does, so no
  # sourced context can post a real desktop notification.
  : "${FM_WEDGE_ALARM_EXEC:=discard}"
  export FM_WEDGE_ALARM_EXEC
fi
