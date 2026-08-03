#!/usr/bin/env bash
# Firstmate away-mode health check.
#
# Answers one question the fleet cannot afford to get wrong: is away-mode
# supervision REAL right now?
#
# While state/.afk exists, bin/fm-watch.sh deliberately drops to one-shot and
# hands triage to bin/fm-supervise-daemon.sh. So an .afk flag with no live
# daemon is the single worst combination available - nothing triages, and away
# mode still reports itself active. This script makes that state loud instead of
# silent, and is the reason the daemon writes its readiness beacon and its
# durable exit record.
#
# Verdicts (first token of the single status line, also the exit code):
#   AFK_OFF        0  no away-mode flag; nothing to supervise
#   AFK_HEALTHY    0  flag present, daemon live, past its first housekeeping tick
#   AFK_STARTING   0  flag present, daemon live, not yet ready (still arming)
#   AFK_DEGRADED   1  flag present, NO live daemon - away mode is a lie, repair now
#
# Usage: fm-afk-health.sh [--quiet]
#   --quiet  print nothing; use the exit code only
set -eu

FM_AFK_HEALTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_HEALTH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_HEALTH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Reuse the arming path's own liveness predicate rather than restating it: that
# script's source guard means sourcing it defines the helpers without arming.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_HEALTH_DIR/fm-afk-start.sh"

fm_afk_health_main() {
  local quiet=0
  case "${1:-}" in
    '') ;;
    --quiet) quiet=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) echo "usage: fm-afk-health.sh [--quiet]" >&2; return 2 ;;
  esac

  local state=$FM_AFK_HEALTH_STATE
  local ready="$state/.subsuper-daemon-ready"
  local exited="$state/.subsuper-daemon-exit"
  local log="$state/.supervise-daemon.log"
  local verdict rc detail=""

  if [ ! -f "$state/.afk" ]; then
    verdict=AFK_OFF; rc=0; detail="no away-mode flag"
  elif daemon_lock_held_by_live_daemon; then
    local pid; pid=$(daemon_lock_pid 2>/dev/null || true)
    if [ -f "$ready" ]; then
      verdict=AFK_HEALTHY; rc=0; detail="daemon pid=${pid:-?} ready"
    else
      verdict=AFK_STARTING; rc=0; detail="daemon pid=${pid:-?} not yet past its first housekeeping tick"
    fi
  else
    verdict=AFK_DEGRADED; rc=1
    # The whole point of the durable exit record: say WHY, not just "gone".
    if [ -f "$exited" ]; then
      detail="away-mode flag present but NO live daemon; last exit: $(tr '\t' ' ' < "$exited" | head -1)"
    else
      detail="away-mode flag present but NO live daemon; no exit record (killed, or never started)"
    fi
  fi

  if [ "$quiet" -eq 0 ]; then
    echo "$verdict: $detail"
    if [ "$verdict" = AFK_DEGRADED ]; then
      echo "AFK_DEGRADED: nothing is triaging this fleet while state/.afk exists - re-arm away mode or clear the flag"
      if [ -f "$log" ]; then
        echo "AFK_DEGRADED: last daemon log lines:"
        tail -5 "$log" 2>/dev/null | sed 's/^/  /'
      fi
    fi
  fi
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_health_main "$@"
fi
