#!/usr/bin/env bash
# fm-watchdog.sh - cron-level liveness watchdog OUTSIDE the agent stack.
#
# The watcher chain, the away-mode daemon, and every turn-end guard live inside
# the agent stack: when the harness, multiplexer, or daemon itself dies, none of
# them can report that death (observed 2026-08-02: the away daemon died with
# state/.afk still present and nothing alarmed; a home's watcher was dead 15.1h
# with 26 task metas recorded). This script is the independent outer net: run it
# from cron (or any external scheduler) and it checks two facts read-only:
#
#   watcher-stale - work is recorded (any state/<id>.meta) or away mode is on
#                   (state/.afk), but state/.last-watcher-beat is missing or
#                   older than FM_WATCHDOG_GRACE (default 900s; the watcher's
#                   own guard grace is 300s, this net is deliberately coarser).
#   daemon-dead   - state/.afk exists but the away-mode daemon is not running
#                   (state/.supervise-daemon.pid missing or its pid dead; the
#                   daemon removes that pidfile on clean shutdown, so absence
#                   means not-running, matching bin/fm-supervise-daemon.sh).
#
# An idle home (no task metas, no .afk) is healthy regardless of the beacon: a
# watcher is only required while work is recorded or away mode is on.
#
# ALARM = one dated line appended to state/.watchdog-alarm (the authoritative
# record) plus a best-effort visible alert, tried in order:
#   1. powershell.exe on PATH (WSL): a dependency-free WScript.Shell COM popup
#      with a 10s self-timeout - no BurntToast, no module install.
#   2. notify-send, if present.
#   3. stderr echo (always emitted on a firing alarm; doubles as the cron-log
#      record when stdout/stderr are redirected by the cron entry).
# FM_WATCHDOG_ALERT_EXEC, when set, REPLACES the real channels: it is invoked as
# `<exec> <condition> <summary>` (the same seam contract as the daemon's
# FM_WEDGE_ALARM_EXEC; the special value "discard" fires nothing). Tests force
# this seam so they can never raise a real popup.
#
# Dedupe: each condition re-alerts at most once per FM_WATCHDOG_REALERT
# (default 3600s), tracked by the mtime of state/.watchdog-alerted-<condition>.
# The alarm-file append and the visible alert fire only when an alert actually
# fires (first failure, or the re-alert window elapsed); a still-failing but
# deduped condition stays silent yet the exit code remains non-zero. A healthy
# condition removes its marker so the next failure alerts immediately.
#
# Exit codes: 0 healthy (silent), 1 alarm condition present, 2 usage error.
#
# Usage:
#   FM_HOME=/path/to/home bin/fm-watchdog.sh            one check pass
#   FM_HOME=/path/to/home bin/fm-watchdog.sh --install-cron
#     Installs (idempotently, replacing any prior entry for the same home) a
#     crontab entry running this script every 10 minutes with the current
#     FM_HOME, logging to state/.watchdog-cron.log. When crontab is missing,
#     prints manual instructions (including a Windows Task Scheduler
#     schtasks.exe alternative for WSL) and exits 1. When crontab exists but no
#     cron daemon process is detected (common on WSL), the entry is still
#     installed and a start-the-service warning is printed.
#
# Env knobs: FM_WATCHDOG_GRACE (900), FM_WATCHDOG_REALERT (3600),
#            FM_WATCHDOG_ALERT_EXEC (unset = real channels; "discard" = none).
set -eu

usage() {
  sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-watchdog refuses to guess which firstmate home to check" >&2
  exit 2
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_WATCHDOG_GRACE:-900}
REALERT=${FM_WATCHDOG_REALERT:-3600}
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- portable stat (same trap as fm-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# Deliberate copies of fm_path_mtime/fm_path_age (bin/fm-wake-lib.sh): this
# monitor must stay standalone and never source the stack it watches, so the
# stat-portability rule is restated here on purpose. Keep the three copies
# (this, fm-wake-lib.sh, fm-watch.sh age_of) behaviorally identical.
_file_age() {  # seconds since mtime; very large if missing
  local f=$1 m
  m=$(_stat_file_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# --- cron install ------------------------------------------------------------
install_cron() {
  local entry marker tmp log
  log="$STATE/.watchdog-cron.log"
  marker="# fm-watchdog:$FM_HOME"
  entry="*/10 * * * * FM_HOME=$FM_HOME $SELF >> $log 2>&1 $marker"
  if ! command -v crontab >/dev/null 2>&1; then
    cat >&2 <<EOF
error: crontab not found; install cron or schedule this manually:
  every 10 min: FM_HOME=$FM_HOME $SELF
Windows Task Scheduler alternative (from Windows, for WSL):
  schtasks.exe /Create /SC MINUTE /MO 10 /TN firstmate-watchdog \\
    /TR "wsl.exe -- sh -c 'FM_HOME=$FM_HOME $SELF'"
EOF
    return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-watchdog-cron.XXXXXX")
  crontab -l 2>/dev/null | grep -Fv "$marker" > "$tmp" || true
  printf '%s\n' "$entry" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo "installed crontab entry: $entry"
  if ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
    echo "warning: no cron daemon process detected; on WSL start it with: sudo service cron start" >&2
  fi
  return 0
}

if [ "${1:-}" = --install-cron ]; then
  install_cron
  exit $?
fi
if [ "$#" -gt 0 ]; then
  echo "error: unknown argument '$1' (see --help)" >&2
  exit 2
fi

[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 2; }

# --- visible alert channels ---------------------------------------------------
# Summary text is sanitized to a conservative character set before reaching
# powershell so no quoting context can ever be escaped.
_alert_visible() {  # <condition> <summary>
  local condition=$1 summary=$2 safe
  case "${FM_WATCHDOG_ALERT_EXEC:-}" in
    discard) return 0 ;;
    '') : ;;
    *) "${FM_WATCHDOG_ALERT_EXEC}" "$condition" "$summary" >/dev/null 2>&1 || true; return 0 ;;
  esac
  if command -v powershell.exe >/dev/null 2>&1; then
    safe=$(printf '%s' "$summary" | tr -cd 'A-Za-z0-9 ._:()/-')
    set -- powershell.exe -NoProfile -NonInteractive -Command \
      "(New-Object -ComObject WScript.Shell).Popup('$safe',10,'firstmate watchdog',48) | Out-Null"
    command -v timeout >/dev/null 2>&1 && set -- timeout 12 "$@"
    "$@" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "firstmate watchdog" "$summary" >/dev/null 2>&1 || true
    return 0
  fi
  return 0
}

RC=0

# _check <condition> <failing:0|1> <summary>: dedupe bookkeeping + alert firing.
_check() {
  local condition=$1 failing=$2 summary=$3 marker
  marker="$STATE/.watchdog-alerted-$condition"
  if [ "$failing" -eq 0 ]; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  RC=1
  if [ -e "$marker" ] && [ "$(_file_age "$marker")" -lt "$REALERT" ]; then
    return 0  # still failing, but inside the dedupe window: stay quiet
  fi
  touch "$marker"
  printf '[%s] %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$condition" "$summary" >> "$STATE/.watchdog-alarm"
  echo "fm-watchdog ALARM ($condition): $summary" >&2
  _alert_visible "$condition" "$summary"
}

# --- condition a: watcher beacon stale/missing while work is recorded --------
work_recorded=0
if [ -e "$STATE/.afk" ]; then
  work_recorded=1
else
  for _m in "$STATE"/*.meta; do
    [ -e "$_m" ] && { work_recorded=1; break; }
  done
fi
beacon_failing=0
beacon_age=$(_file_age "$STATE/.last-watcher-beat")
if [ "$work_recorded" -eq 1 ] && [ "$beacon_age" -ge "$GRACE" ]; then
  beacon_failing=1
fi
_check watcher-stale "$beacon_failing" \
  "watcher beacon stale/missing (age ${beacon_age}s, grace ${GRACE}s) with work recorded in $FM_HOME"

# --- condition b: away daemon dead while afk is on ----------------------------
daemon_failing=0
if [ -e "$STATE/.afk" ]; then
  daemon_pid=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null || true)
  case "$daemon_pid" in
    ''|*[!0-9]*) daemon_failing=1 ;;
    *) kill -0 "$daemon_pid" 2>/dev/null || daemon_failing=1 ;;
  esac
fi
_check daemon-dead "$daemon_failing" \
  "away-mode daemon not running while state/.afk is present in $FM_HOME"

exit "$RC"
