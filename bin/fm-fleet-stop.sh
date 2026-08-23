#!/usr/bin/env bash
# fm-fleet-stop.sh - captain-ordered, machine-readable fleet stop.
#
# Usage:
#   fm-fleet-stop.sh set --wortlaut "<captain's verbatim wording>"
#   fm-fleet-stop.sh status     print flag state; exit 0 active, exit 1 inactive
#   fm-fleet-stop.sh lift       remove the flag
#   fm-fleet-stop.sh --help
#
# File contract (this header is the single owner): $FM_HOME/state/.fleet-stop
#   line 1:          set=<UTC timestamp, date -u +%Y-%m-%dT%H:%M:%SZ>
#   remaining lines: the captain's verbatim wording, exactly as given
#
# WHY. On 23.08.2026 the captain hard-stopped the whole fleet, and session
# start's secondmate liveness sweep relaunched the stopped secondmates twice,
# because the stop existed only as prose no automation reads. While the flag
# file exists, bin/fm-spawn.sh refuses every launch and bin/fm-bootstrap.sh's
# network_sweep_authorized stands down the four mutating network sweeps
# (dead-secondmate relaunch, secondmate convergence, pending handoff delivery,
# project clone refresh), and the bootstrap section of every session start
# prints a self-contained FLEET_STOP banner. A restart or crash can therefore
# no longer resurrect the fleet against the captain's word.
#
# Setting and lifting are captain-word operations by AGENTS.md policy; this
# script enforces only the mechanics: `set` refuses without an explicit
# non-empty wording (no silent stop with an unexplained flag), writes are
# atomic, and `lift` reports what it removed so the action is auditable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FLAG="$STATE/.fleet-stop"

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
case "$cmd" in
  set)
    shift
    wortlaut=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --wortlaut) wortlaut="${2:-}"; shift 2 ;;
        *) echo "error: unknown argument '$1' for set" >&2; exit 2 ;;
      esac
    done
    if [ -z "${wortlaut//[[:space:]]/}" ]; then
      echo "error: set requires --wortlaut with the captain's non-empty verbatim wording" >&2
      exit 2
    fi
    mkdir -p "$STATE"
    tmp="$FLAG.tmp.$$"
    {
      printf 'set=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\n' "$wortlaut"
    } > "$tmp"
    mv -f "$tmp" "$FLAG"
    echo "fleet stop set: $FLAG"
    ;;
  status)
    if [ -f "$FLAG" ]; then
      echo "fleet stop ACTIVE ($FLAG)"
      cat "$FLAG"
      exit 0
    fi
    echo "no fleet stop active"
    exit 1
    ;;
  lift)
    if [ ! -f "$FLAG" ]; then
      echo "no fleet stop active - nothing to lift"
      exit 0
    fi
    echo "lifting fleet stop that was:"
    cat "$FLAG"
    rm -f "$FLAG"
    echo "fleet stop lifted"
    ;;
  --help|-h|help|"")
    usage
    [ "$cmd" = "" ] && exit 2 || exit 0
    ;;
  *)
    echo "error: unknown command '$cmd' (set|status|lift|--help)" >&2
    exit 2
    ;;
esac
