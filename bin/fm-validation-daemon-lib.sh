# shellcheck shell=bash
# Liveness read for the shared no-mistakes validation daemon.
# Usage: . bin/fm-validation-daemon-lib.sh
#
# Every shipping task in the fleet depends on one shared validation daemon, and
# nothing ever asked whether it was running. It died silently three times and
# stayed down 2.5 days, 2.9 days and 8 hours before anything restarted it; a
# silent outage is indistinguishable from a quiet fleet, which is what made the
# other daemon failures expensive. This library exists so session start can say
# so, and it OBSERVES ONLY: it never starts, stops, restarts, or reconfigures the
# daemon, and it never invokes the no-mistakes CLI, whose ordinary commands
# auto-start a daemon as a side effect. It reads two files and sends signal 0.
#
# The daemon root is the daemon's own selector, NM_HOME, defaulting to
# ~/.no-mistakes; daemon.pid and logs/daemon.log hang off it.
#
# THE PID FILE IS JSON, NOT A BARE INTEGER:
#   {"pid":929670,"started_at":"2026-08-03T03:25:46Z"}
# Piping it into a signal check reports a LIVE daemon as DOWN, which is how a
# by-hand reading of it got retracted a moment after it was made.
#
# Three outcomes, deliberately never collapsed into two:
#   alive   - a pid was parsed and that process answers signal 0
#   down    - a pid was parsed and nothing answers, or the root has no pid file
#   unknown - a pid file is there but no pid can be read out of it
# Reporting unknown as down manufactures false alarms; reporting it as alive
# recreates the exact silence this check exists to end.
#
# Outage length comes from the mtime of logs/daemon.log, the last moment the
# daemon demonstrably did anything - the same evidence the diagnosis used to
# recover the real death times. started_at only records when the recorded daemon
# started, so it is reported as its own fact and never as a death instant. Both
# clauses are omitted rather than guessed when their source is absent.

FM_VALIDATION_DAEMON_PID_FILE="daemon.pid"
FM_VALIDATION_DAEMON_LOG_FILE="logs/daemon.log"

# fm_validation_daemon_root: the daemon root this home would use.
fm_validation_daemon_root() {
  printf '%s\n' "${NM_HOME:-${HOME:-}/.no-mistakes}"
}

# fm_validation_daemon_mtime <file>: mtime in epoch seconds, or nothing.
fm_validation_daemon_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_validation_daemon_epoch <ISO-8601 UTC>: epoch seconds, or return 1.
fm_validation_daemon_epoch() {
  local ts=$1 out
  out=$(date -u -d "$ts" +%s 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) || out=""
  fi
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# fm_validation_daemon_duration <seconds>: a coarse human span. A multi-day
# outage must read as a multi-day outage rather than merely as "down", so days
# and hours keep one decimal.
fm_validation_daemon_duration() {
  awk -v s="$1" 'BEGIN {
    if (s < 0) s = 0
    if (s < 60) printf "%ds\n", s
    else if (s < 3600) printf "%dm\n", s / 60
    else if (s < 86400) printf "%.1fh\n", s / 3600
    else printf "%.1fd\n", s / 86400
  }'
}

# fm_validation_daemon_age <epoch seconds>: how long ago that was, or nothing.
fm_validation_daemon_age() {
  local then=$1 now
  case "$then" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  fm_validation_daemon_duration "$((now - then))"
}

# fm_validation_daemon_pid <pid file>: the recorded pid, or return 1. Only the
# JSON shape the daemon actually writes is accepted; anything else is unknown
# rather than a guess. Zero is rejected with it, because `kill -0 0` signals the
# CALLER's own process group and would answer for a daemon that is not there.
fm_validation_daemon_pid() {
  local pid
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1)
  [ -n "$pid" ] || return 1
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

# fm_validation_daemon_started_at <pid file>: the recorded start stamp, or empty.
fm_validation_daemon_started_at() {
  sed -n 's/.*"started_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# fm_validation_daemon_report [root]
# Prints one actionable "VALIDATION_DAEMON: <state> - <evidence>" line when the
# daemon is not healthy, and nothing when it is - except under
# FM_BOOTSTRAP_VERBOSE_FACTS=1, where a healthy daemon prints one BOOTSTRAP_INFO
# fact carrying its uptime. A root that does not exist is silent: that home has
# never run the daemon, so there is no outage to report.
fm_validation_daemon_report() {
  local root pid_file log_file pid started_at started_epoch last_active clauses state

  root=${1:-$(fm_validation_daemon_root)}
  [ -d "$root" ] || return 0
  pid_file="$root/$FM_VALIDATION_DAEMON_PID_FILE"
  log_file="$root/$FM_VALIDATION_DAEMON_LOG_FILE"

  last_active=""
  if [ -f "$log_file" ]; then
    last_active=$(fm_validation_daemon_age "$(fm_validation_daemon_mtime "$log_file")" 2>/dev/null || true)
  fi

  if [ ! -f "$pid_file" ]; then
    clauses=""
    [ -z "$last_active" ] || clauses="; last active $last_active ago"
    echo "VALIDATION_DAEMON: down - no pid file at $pid_file$clauses"
    return 0
  fi

  if ! pid=$(fm_validation_daemon_pid "$pid_file"); then
    clauses=""
    [ -z "$last_active" ] || clauses="; last active $last_active ago"
    echo "VALIDATION_DAEMON: unknown - cannot read a pid from $pid_file$clauses"
    return 0
  fi

  started_at=$(fm_validation_daemon_started_at "$pid_file")
  started_epoch=""
  [ -z "$started_at" ] || started_epoch=$(fm_validation_daemon_epoch "$started_at" 2>/dev/null || true)

  state=down
  kill -0 "$pid" 2>/dev/null && state=alive

  if [ "$state" = alive ]; then
    [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] || return 0
    clauses=""
    [ -z "$started_epoch" ] || clauses=", up $(fm_validation_daemon_age "$started_epoch")"
    echo "BOOTSTRAP_INFO: validation daemon alive (pid $pid$clauses)"
    return 0
  fi

  clauses=""
  [ -z "$started_epoch" ] || clauses="started $(fm_validation_daemon_age "$started_epoch") ago"
  if [ -n "$last_active" ]; then
    [ -z "$clauses" ] || clauses="$clauses, "
    clauses="${clauses}last active $last_active ago"
  fi
  [ -z "$clauses" ] || clauses="; $clauses"
  echo "VALIDATION_DAEMON: down - recorded pid $pid is not running$clauses"
}
