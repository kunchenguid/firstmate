#!/usr/bin/env bash
# fm-proctree-lib.sh - the ONE owner of bounded parent-chain climbing (plan v3
# U1.4: the ppid-walk copies in fm-backend.sh, fm-harness.sh, and
# fm-session-lock-lib.sh consolidate here BEFORE any liveness semantics change,
# so there is exactly one climbing mechanic to change later).
#
# fm_proctree_climb <start-pid> <max-hops> <visitor>
#   Calls `<visitor> <pid>` for the start pid and then each parent in turn.
#   Visitor return codes: 0 = stop, climb succeeds (exit 0);
#                         2 = stop, climb fails (exit 1);
#                         anything else = keep climbing.
#   The climb itself fails at a missing or non-numeric parent, at pid <= 1
#   (init/launchd - a reparented process can never false-positive above it),
#   and at hop exhaustion. Visitors carry richer results through globals of
#   their own; this library keeps none.
#
# Accessors (one place to swap the process-fact source later):
#   fm_proctree_comm <pid>    the kernel command name, or failure
#   fm_proctree_args <pid>    the full argument string, or failure
#   fm_proctree_parent <pid>  the parent pid, whitespace-stripped
#
# Sourced only; no side effects on source.

fm_proctree_comm() { ps -o comm= -p "$1" 2>/dev/null; }
fm_proctree_args() { ps -o args= -p "$1" 2>/dev/null; }
fm_proctree_parent() { ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]'; }

fm_proctree_climb() { # <start-pid> <max-hops> <visitor>
  local pid=$1 max=$2 visitor=$3 hops=0 rc
  while [ "$hops" -lt "$max" ]; do
    "$visitor" "$pid"
    rc=$?
    case "$rc" in
      0) return 0 ;;
      2) return 1 ;;
    esac
    pid=$(fm_proctree_parent "$pid")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    hops=$((hops + 1))
  done
  return 1
}
