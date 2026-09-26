#!/usr/bin/env bash
# fm-machine-inventory.sh - report host-wide resource leaks that need a human
# owner, and remain silent only when every requested measurement is available
# and below its threshold.
#
# Usage:
#   fm-machine-inventory.sh [--help]
#
# The command is strictly observational.
# It never stops, signals, restarts, or changes an inventoried process,
# container, or simulator; the only processes it signals are its own queries
# that outlive their time bound or are still running when the run is
# interrupted.
#
# Every successful scan covers the host rather than a configured port or
# Firstmate-home subset:
#   - TCP LISTEN and bound, unconnected UDP network sockets from lsof
#   - every running container on the current Docker context
#   - every booted simulator in each CoreSimulator device set discovered by its
#     device_set.plist within five levels of the caller's ~/Library/Developer,
#     following symlinks (such as the default, XCTest clone, Playgrounds, and
#     Xcode Previews sets)
#   - every process in the ps process table that fm-agent-process-lib.sh
#     classifies as an agent
#   - the fifteen-minute load average against online CPU cores
#
# Unix-domain sockets are intentionally outside the network-listener category.
# The command's name and output therefore never claim to inventory them.
# CoreSimulator device sets belong to the calling user's home, so other users'
# simulators are outside the scan.
# The ps, lsof, docker, simctl, and device-set discovery queries each run under
# a sixty-second bound from fm-timeout-lib.sh where a killable timeout mechanism
# (timeout, gtimeout, or its bash fallback) exists; under its perl fallback,
# interrupt behavior is not guaranteed.
# A missing command, inaccessible system-wide result, failed or timed-out query,
# lsof warning, unreadable device set, or interrupted scan emits a NOT CHECKED
# finding instead of silently making a broader claim than it proved; records a
# warned lsof query did return are still reported.
# lsof sees only the caller's own sockets unless run as root, so a non-root run
# reports other users' sockets as NOT CHECKED.
#
# Listeners, containers, simulators, and agent processes are reported once
# older than one day; load is reported once it exceeds one per online CPU core.
#
# Exit 0 means every measurement completed and no finding exceeded its rule.
# Exit 1 means at least one leak or unmeasured category was reported.
# Exit 2 means invalid invocation.
# Exit 129, 130, or 143 means HUP, INT, or TERM interrupted the run; findings
# collected so far are still printed, and the interrupted scan and every scan
# after it are reported as NOT CHECKED.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '1,/^set -u$/p' "$0"
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

AGE_SECS=86400
QUERY_SECS=60

# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-machine-inventory.XXXXXX") || {
  printf '%s\n' 'NOT CHECKED: every scan (temporary directory unavailable)'
  exit 1
}
trap 'rm -rf "$TMP_ROOT"' EXIT
exec 9>&1
FINDINGS="$TMP_ROOT/findings"
PROCESSES="$TMP_ROOT/processes"
: > "$FINDINGS"

finding() {
  printf '%s\n' "$*" >> "$FINDINGS"
}

run_query() {  # <what> <stdout file> <command...>; bounded, NOT CHECKED on failure
  local what=$1 output=$2 rc=0
  shift 2
  fm_run_timed "$QUERY_SECS" "$@" > "$output" 2> "$output.err" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124) finding "NOT CHECKED: $what (query timed out)" ;;
    *) finding "NOT CHECKED: $what (query failed)" ;;
  esac
  return "$rc"
}

elapsed_seconds() {  # [[days-]hours:]minutes:seconds -> integer seconds
  local elapsed=$1 days=0 hours=0 minutes=0 seconds=0 rest
  case "$elapsed" in
    *-*) days=${elapsed%%-*}; rest=${elapsed#*-} ;;
    *) rest=$elapsed ;;
  esac
  IFS=: read -r hours minutes seconds <<EOF
$rest
EOF
  if [ -z "${seconds:-}" ]; then
    seconds=$minutes
    minutes=$hours
    hours=0
  fi
  case "$days:$hours:$minutes:$seconds" in *[!0-9:]*|*::*|:*) return 1 ;; esac
  printf '%s\n' $((10#$days * 86400 + 10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
}

scan_process_table() {  # -> $PROCESSES rows of pid<TAB>etime<TAB>comm<TAB>command
  local names="$TMP_ROOT/ps-comm" commands="$TMP_ROOT/ps-command"
  run_query 'process table' "$names" ps -axo pid=,etime=,comm= || return
  run_query 'process table' "$commands" ps -axo pid=,command= || return
  awk '
    NR == FNR { pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); command[pid] = $0; next }
    { pid = $1; etime = $2; sub(/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); printf "%s\t%s\t%s\t%s\n", pid, etime, $0, command[pid] }
  ' "$commands" "$names" > "$PROCESSES"
}

pid_elapsed() {  # <pid> -> etime from the process table, empty when the pid started later
  awk -F '\t' -v pid="$1" '$1 == pid { print $2; exit }' "$PROCESSES"
}

report_listener_records() {  # <protocol> <lsof output>
  local protocol=$1 records=$2 pid='' command='' line age age_seconds
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      p*) pid=${line#p} ;;
      c*) command=${line#c} ;;
      n*'->'*|'n*:*') ;;
      n*)
        age=$(pid_elapsed "$pid")
        [ -n "$age" ] || continue
        age_seconds=$(elapsed_seconds "$age" 2>/dev/null || true)
        if [ -z "$age_seconds" ]; then
          finding "NOT CHECKED: $protocol socket pid=$pid command=${command:-unknown} age unreadable"
        elif [ "$age_seconds" -gt "$AGE_SECS" ]; then
          finding "LISTENER: protocol=$protocol pid=$pid age=$age command=${command:-unknown} endpoint=${line#n}"
        fi
        ;;
    esac
  done < "$records"
}

scan_listeners() {
  local protocol=$1; shift
  local output="$TMP_ROOT/lsof-$protocol" errors="$TMP_ROOT/lsof-$protocol.err" rc=0 warning
  if ! command -v lsof >/dev/null 2>&1; then
    finding "NOT CHECKED: $protocol network sockets (lsof unavailable)"
    return
  fi
  if [ ! -f "$PROCESSES" ]; then
    finding "NOT CHECKED: $protocol network sockets (process table unavailable)"
    return
  fi
  fm_run_timed "$QUERY_SECS" lsof -nP "$@" -Fpcn > "$output" 2> "$errors" || rc=$?
  if [ "$rc" -eq 124 ]; then
    finding "NOT CHECKED: $protocol network sockets (lsof query timed out)"
    return
  fi
  if [ "$rc" -gt 1 ]; then
    finding "NOT CHECKED: $protocol network sockets (lsof query incomplete)"
    return
  fi
  if [ -s "$errors" ]; then
    IFS= read -r warning < "$errors"
    finding "NOT CHECKED: $protocol network sockets possibly omitted by lsof warning ($warning)"
  fi
  if [ "$(id -u)" != 0 ]; then
    finding "NOT CHECKED: $protocol network sockets owned by other users (not run as root)"
  fi
  report_listener_records "$protocol" "$output"
}

scan_network_sockets() {
  scan_listeners TCP -iTCP -sTCP:LISTEN
  scan_listeners UDP -iUDP
}

online_cores() {
  local cores
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  case "$cores" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s\n' "$cores"
}

load15() {
  local load
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ gsub(/[{}]/, ""); print $3 }')
  [ -n "$load" ] || load=$(awk '{ print $3 }' /proc/loadavg 2>/dev/null)
  printf '%s\n' "$load"
}

scan_load() {
  local cores load
  cores=$(online_cores || true)
  load=$(load15 || true)
  case "$cores" in ''|*[!0-9]*) finding 'NOT CHECKED: fifteen-minute load (online CPU core count unavailable)'; return ;; esac
  case "$load" in ''|*[!0-9.]*|*.*.*) finding 'NOT CHECKED: fifteen-minute load average unavailable'; return ;; esac
  if awk -v load="$load" -v cores="$cores" 'BEGIN { exit !(load > cores) }'; then
    finding "LOAD: fifteen-minute=$load cores=$cores"
  fi
}

seconds_since() {  # <RFC3339 timestamp> -> whole seconds elapsed
  local stamp=${1%%.*} started now
  stamp=${stamp%Z}
  case "$stamp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;; *) return 1 ;; esac
  started=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$stamp" +%s 2>/dev/null || date -u -d "${stamp}Z" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  case "$started:$now" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$started" -le "$now" ] || return 1
  printf '%s\n' $((now - started))
}

scan_containers() {
  local ids="$TMP_ROOT/docker-ids" inspected="$TMP_ROOT/docker-started" id name age
  if ! command -v docker >/dev/null 2>&1; then
    finding 'NOT CHECKED: running containers (docker unavailable)'
    return
  fi
  run_query 'running containers' "$ids" docker ps --format '{{.ID}}\t{{.Names}}' || return
  while IFS=$'\t' read -r id name || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    run_query "running container id=$id name=${name:-unknown} uptime" "$inspected" \
      docker inspect --format '{{.State.StartedAt}}' "$id" || continue
    age=$(seconds_since "$(cat "$inspected")" 2>/dev/null || true)
    if [ -z "$age" ]; then
      finding "NOT CHECKED: running container id=$id name=${name:-unknown} uptime unreadable"
    elif [ "$age" -gt "$AGE_SECS" ]; then
      finding "CONTAINER: id=$id name=${name:-unknown} uptime=${age}s"
    fi
  done < "$ids"
}

scan_simulator_set() {  # <device-set path>
  local set=$1 output="$TMP_ROOT/simulators" booted="$TMP_ROOT/simulators.tsv" udid started name age
  if [ ! -r "$set/device_set.plist" ]; then
    finding "NOT CHECKED: booted simulators set=$set (device set unreadable)"
    return
  fi
  run_query "booted simulators set=$set" "$output" xcrun simctl --set "$set" list -j devices || return
  if ! jq -r '.devices[][] | select(.state == "Booted") | [.udid, .lastBootedAt // "unknown", .name] | @tsv' "$output" > "$booted" 2>/dev/null; then
    finding "NOT CHECKED: booted simulators set=$set (simctl output unreadable)"
    return
  fi
  while IFS=$'\t' read -r udid started name || [ -n "$udid" ]; do
    [ -n "$udid" ] || continue
    age=$(seconds_since "$started" 2>/dev/null || true)
    if [ -z "$age" ]; then
      finding "NOT CHECKED: booted simulator set=$set udid=$udid name=${name:-unknown} uptime unreadable"
    elif [ "$age" -gt "$AGE_SECS" ]; then
      finding "SIMULATOR: set=$set udid=$udid name=${name:-unknown} uptime=${age}s"
    fi
  done < "$booted"
}

scan_simulators() {
  local tool plist sets="$TMP_ROOT/simulator-sets"
  for tool in xcrun jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      finding "NOT CHECKED: booted simulators ($tool unavailable)"
      return
    fi
  done
  run_query "booted simulator device set discovery under $HOME/Library/Developer" "$sets" \
    find -L "$HOME/Library/Developer" -maxdepth 5 -name device_set.plist
  while IFS= read -r plist <&3; do
    scan_simulator_set "${plist%/device_set.plist}"
  done 3< "$sets"
}

scan_agent_processes() {
  local pid elapsed comm command argv0 age
  if [ ! -f "$PROCESSES" ]; then
    finding 'NOT CHECKED: agent processes (process table unavailable)'
    return
  fi
  while IFS=$'\t' read -r pid elapsed comm command; do
    [ -n "${pid:-}" ] || continue
    case "$command" in
      "$comm"|"$comm "*) argv0=$comm ;;
      *) argv0=${command%%[[:space:]]*} ;;
    esac
    [ "$(fm_agent_process_classify "$comm" "$argv0" "$command" "$pid")" = agent ] || continue
    age=$(elapsed_seconds "$elapsed" 2>/dev/null || true)
    if [ -z "$age" ]; then
      finding "NOT CHECKED: agent process pid=$pid command=${argv0:-$comm} age unreadable"
    elif [ "$age" -gt "$AGE_SECS" ]; then
      finding "AGENT: pid=$pid age=$elapsed command=${argv0:-$comm}"
    fi
  done < "$PROCESSES"
}

SCANS='scan_process_table scan_network_sockets scan_load scan_containers scan_simulators scan_agent_processes'
PENDING_SCANS=$SCANS

interrupted() {  # <exit status>
  local scan job
  for job in $(jobs -p); do
    kill -TERM -- "-$job" 2>/dev/null
  done
  for scan in $PENDING_SCANS; do
    scan=${scan#scan_}
    finding "NOT CHECKED: ${scan//_/ } scan (interrupted)"
  done
  sort -u "$FINDINGS" >&9
  exit "$1"
}

trap 'interrupted 129' HUP
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

for scan in $SCANS; do
  "$scan"
  PENDING_SCANS=${PENDING_SCANS#"$scan"}
  PENDING_SCANS=${PENDING_SCANS# }
done

if [ -s "$FINDINGS" ]; then
  sort -u "$FINDINGS"
  exit 1
fi
