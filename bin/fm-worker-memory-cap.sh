#!/usr/bin/env bash
# fm-worker-memory-cap.sh - per-lane memory cap for ship and scout workers.
#
# Opt-in through config/worker-memory-max (docs/configuration.md "Worker memory
# cap"). With no file, nothing here runs and every launch is unchanged. With a
# file, bin/fm-spawn.sh resolves one cap for the task's harness and project and
# launches the worker inside a transient systemd user scope carrying
# MemoryMax=<cap> and MemorySwapMax=<cap>, so the kernel's cgroup OOM killer
# stops a runaway tool inside that lane instead of letting it exhaust the host.
# The scope holds the agent and every process it starts; systemd's default
# OOMPolicy=stop ends the whole scope, so the lane dies as one unit and
# this script records that as the lane's failure.
#
# Config format: one rule per line, `#` comments and blank lines ignored:
#   <harness|*> <project> <MiB>
# <harness> is the resolved worker harness name, <project> is the basename of
# the project clone (not `*`), and <MiB> is a positive whole number of mebibytes.
# The FIRST matching line wins, so write specific rules above general ones. A task
# no rule matches runs uncapped. Any malformed line refuses every spawn and
# relaunch from the home, before any endpoint, worktree, or record exists.
#
# Usage:
#   fm-worker-memory-cap.sh resolve <config-file> <harness> <project>
#     Print the matching cap in MiB, or nothing when no rule matches. Exit 1 with
#     an error naming the line when the file is unreadable or malformed.
#   fm-worker-memory-cap.sh probe
#     Exit 0 when this host can start a memory-capped systemd user scope, else
#     exit 1 naming what is missing. bin/fm-spawn.sh refuses a capped launch on
#     a failed probe rather than launching the worker without its cap.
#   fm-worker-memory-cap.sh outcome <unit> <cap-mib> <state>/<task>.status <config-dir>
#     Run in the worker's pane shell after the scoped launch returns. When the
#     scope ended with Result=oom-kill, append one
#     `failed [at=<epoch>]: ...` line to the task's status log (plus the opt-in
#     fleet-ledger record, as a worker's own append does) and clear the failed
#     unit. Any other ending writes nothing. Always exits 0, so the pane shell
#     is never disturbed.
#
# The probe and the launch talk to the user's systemd manager, so they need the
# session's user bus (XDG_RUNTIME_DIR). A host without systemd-run, or one
# whose user manager cannot be reached, fails the probe.
set -u

usage() {
  sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "$0" >&2
  exit 2
}

resolve() {  # <config-file> <harness> <project>
  local file=$1 harness=$2 project=$3 line n=0 h p mib extra found=
  set -f
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/worker-memory-max must be a readable regular file of '<harness|*> <project> <MiB>' lines" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    # shellcheck disable=SC2086
    set -- $line
    [ "$#" -gt 0 ] || continue
    h=${1-} p=${2-} mib=${3-} extra=${4-}
    if [ "$#" -ne 3 ] || [ -n "$extra" ]; then
      echo "error: config/worker-memory-max line $n must be '<harness|*> <project> <MiB>'" >&2
      return 1
    fi
    if [ "$p" = '*' ]; then
      echo "error: config/worker-memory-max line $n: project must name a concrete project" >&2
      return 1
    fi
    case "$mib" in
    '' | *[!0-9]* | 0*)
      echo "error: config/worker-memory-max line $n: '$mib' is not a positive whole number of MiB" >&2
      return 1
      ;;
    esac
    if [ -z "$found" ] && { [ "$h" = '*' ] || [ "$h" = "$harness" ]; } &&
      [ "$p" = "$project" ]; then
      found=$mib
    fi
  done <"$file"
  [ -z "$found" ] || printf '%s\n' "$found"
}

probe() {
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "error: config/worker-memory-max caps worker memory, but systemd-run is not installed on this host" >&2
    return 1
  fi
  if ! systemd-run --user --scope --quiet -p MemoryMax=64M -p MemorySwapMax=64M true >/dev/null 2>&1; then
    echo "error: config/worker-memory-max caps worker memory, but 'systemd-run --user --scope' could not start a memory-capped scope (is the user systemd manager reachable from this session?)" >&2
    return 1
  fi
}

outcome() {  # <unit> <cap-mib> <status-file> <config-dir>
  local unit=$1 cap=$2 status=$3 config=$4 props state result tries=0
  command -v systemctl >/dev/null 2>&1 || return 0
  # The scope can still be deactivating when the launch returns: systemd sets
  # Result as soon as the OOM kill lands, but the failed state only after the
  # remaining processes are gone, and reset-failed needs that state.
  while :; do
    props=$(systemctl --user show -p ActiveState -p Result "$unit" 2>/dev/null) || props=
    state=$(printf '%s\n' "$props" | sed -n 's/^ActiveState=//p')
    result=$(printf '%s\n' "$props" | sed -n 's/^Result=//p')
    case "$state" in
    deactivating | activating | reloading) ;;
    *) break ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || break
    sleep 0.1
  done
  if [ "$result" = oom-kill ]; then
    printf 'failed [at=%s]: worker memory cap of %s MiB exceeded; the kernel OOM killer stopped this lane (config/worker-memory-max)\n' \
      "$(date +%s)" "$cap" >>"$status"
    if [ -e "$config/fleet-ledger" ]; then
      "$(dirname -- "$0")/fm-fleet-ledger.sh" appended "$config" "$status" >/dev/null 2>&1 || true
    fi
  fi
  [ "$state" != failed ] || systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  return 0
}

case "${1:-}" in
resolve)
  [ "$#" -eq 4 ] || usage
  resolve "$2" "$3" "$4"
  ;;
probe)
  [ "$#" -eq 1 ] || usage
  probe
  ;;
outcome)
  [ "$#" -eq 5 ] || usage
  outcome "$2" "$3" "$4" "$5"
  ;;
*) usage ;;
esac
