#!/usr/bin/env bash
# fm-fleet-wait.sh — the token-economy core of federated mode.
#
# Blocks (BASH ONLY — zero LLM tokens) until THIS operator has a FRESH claim
# (an item stamped `claimed-by:<op>@<ts> status:claimed`, i.e. assigned but not yet
# started), then prints the claimed id(s) and exits 0. A firstmate primary (or its
# supervision daemon) runs this and stays idle until it returns, so an operator's
# LLM is invoked ONLY when there is real work — not on a polling loop of its own.
# While waiting it also heartbeats (cheap file write, no git), so "being online"
# costs nothing.
#
# Usage:
#   fm-fleet-wait.sh <operator> [--interval N] [--timeout S] [--once] [--no-heartbeat]
#     --interval N     poll seconds (default FM_FLEET_WAIT_INTERVAL or 15)
#     --timeout S      give up after S seconds and exit 2 (default 0 = wait forever)
#     --once           check exactly once: exit 0 if a fresh claim exists, else 1
#     --no-heartbeat   do not refresh liveness while waiting
#   Exits 3 on a usage error or when the resolved fleet dir is not an
#   initialized, chosen fleet (fm_fleet_assert_usable).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-fleet-lib.sh"
DIR=$(fm_fleet_dir)

op=${1:-}; [ -n "$op" ] || { echo "usage: fm-fleet-wait.sh <operator> [--interval N] [--timeout S] [--once] [--no-heartbeat]" >&2; exit 3; }
shift
interval=${FM_FLEET_WAIT_INTERVAL:-15}; timeout=0; once=0; heartbeat=1
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval=$2; shift 2 ;;
    --timeout)  timeout=$2; shift 2 ;;
    --once)     once=1; shift ;;
    --no-heartbeat) heartbeat=0; shift ;;
    *) echo "fm-fleet-wait.sh: unknown arg '$1'" >&2; exit 3 ;;
  esac
done

fm_fleet_assert_usable "$DIR" || exit 3

# A fresh claim for this operator: claimed-by:<op>@<ts> with status:claimed
# (NOT status:in-flight — once the firstmate starts an item it is no longer a wake).
fresh_claims() {
  awk -v op="$op" '
    function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
    function claimed_by(line){ if (match(line, /claimed-by:[^ @]+@/)) return substr(line, RSTART+11, RLENGTH-12); return "" }
    claimed_by($0)==op && index($0, "status:claimed") {
      id=item_id($0)
      if (id != "") print "[id:" id "]"
    }
  ' "$DIR/backlog.md" 2>/dev/null
}

start=$(date -u +%s)
while :; do
  ids=$(fresh_claims)
  if [ -n "$ids" ]; then
    printf '%s\n' "$ids"
    exit 0
  fi
  [ "$once" = 1 ] && exit 1
  [ "$heartbeat" = 1 ] && fm_fleet_heartbeat "$DIR" "$op" >/dev/null 2>&1 || true
  if [ "$timeout" -gt 0 ] 2>/dev/null; then
    now=$(date -u +%s)
    [ $((now - start)) -ge "$timeout" ] && { echo "fm-fleet-wait: timed out after ${timeout}s with no claim for $op" >&2; exit 2; }
  fi
  sleep "$interval"
done
