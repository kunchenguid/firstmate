#!/usr/bin/env bash
# fm-capacity.sh - report open lanes and host headroom for queued-work dispatch.
#
# Read-only, fast, and network-free: it reads this home's state/*.meta and
# optional config/lane-capacity, then probes the host. It never spawns,
# writes, or locks anything.
#
# Output: the first line is machine-readable, one space-separated key=value
# list in this fixed order:
#   capacity: free_lanes=<N|unknown> reason=<reason> lanes=<N> target=<N|none|invalid>
#     secondmates=<N> load1=<X|unknown> cores=<N|unknown>
#     mem_free_pct=<N|unknown> disk_free_mb=<N|unknown>
# (one physical line). A short human summary follows it.
#
# lanes counts task metadata records whose kind is not secondmate (ship and
# scout work, including records not yet reconciled after an endpoint died).
# secondmates counts persistent secondmates separately; they hold no lane.
#
# target comes only from config/lane-capacity: one non-negative integer, the
# number of concurrent lanes this home should run. Absent means no target, so
# free_lanes=unknown reason=no-target and the counts are still printed; the
# script never invents a target. A malformed file reports target=invalid
# reason=invalid-target, names the problem on stderr, and exits 1.
#
# With a target, free_lanes is target minus lanes (never below 0), unless the
# host is constrained, in which case free_lanes=0 and reason names every
# constraint, comma-separated, in the order cpu,memory,disk:
#   cpu     1-minute load average >= logical cores
#   memory  free-memory percentage < 10
#   disk    free space on the filesystem holding FM_HOME < 5120 MB
# Otherwise reason is ok when free_lanes > 0 and full when it is 0.
#
# Probes degrade gracefully: an unavailable probe prints unknown and its
# constraint is not evaluated. Darwin reads sysctl (vm.loadavg,
# kern.memorystatus_level, hw.logicalcpu); other systems read /proc/loadavg
# and /proc/meminfo (MemAvailable/MemTotal); cores come from getconf with a
# sysctl fallback; disk comes from df -Pk.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on a report, 1 on an invalid config/lane-capacity, 2 on a
# usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

MEM_FREE_MIN_PCT=10
DISK_FREE_MIN_MB=5120

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "usage: fm-capacity.sh [--help]" >&2; exit 2 ;;
esac

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# --- lanes ------------------------------------------------------------------
lanes=0
secondmates=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  if grep -qx 'kind=secondmate' "$meta" 2>/dev/null; then
    secondmates=$((secondmates + 1))
  else
    lanes=$((lanes + 1))
  fi
done

target=none
target_error=
if [ -e "$CONFIG/lane-capacity" ]; then
  raw=$(tr -d ' \t\r\n' < "$CONFIG/lane-capacity" 2>/dev/null) || raw=
  if is_uint "$raw"; then
    target=$((10#$raw))
  else
    target=invalid
    target_error="config/lane-capacity must hold one non-negative integer"
  fi
fi

# --- host probes ------------------------------------------------------------
os=$(uname -s 2>/dev/null) || os=unknown

load1=unknown
if [ "$os" = Darwin ]; then
  v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
else
  v=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
fi
case "$v" in [0-9]*) load1=$v ;; esac

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=
is_uint "$cores" || cores=$(sysctl -n hw.logicalcpu 2>/dev/null) || cores=
is_uint "$cores" && [ "$cores" -gt 0 ] || cores=unknown

mem_free_pct=unknown
if [ "$os" = Darwin ]; then
  v=$(sysctl -n kern.memorystatus_level 2>/dev/null)
else
  v=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t > 0 && a != "") printf "%d", a * 100 / t}' /proc/meminfo 2>/dev/null)
fi
is_uint "$v" && mem_free_pct=$v

disk_free_mb=unknown
v=$(df -Pk "$FM_HOME" 2>/dev/null | awk 'NR==2{print int($4 / 1024)}')
is_uint "$v" && disk_free_mb=$v

# --- verdict ----------------------------------------------------------------
constraints=
add_constraint() { constraints=${constraints:+$constraints,}$1; }
if [ "$load1" != unknown ] && [ "$cores" != unknown ] &&
  awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l >= c)}'; then
  add_constraint cpu
fi
[ "$mem_free_pct" != unknown ] && [ "$mem_free_pct" -lt "$MEM_FREE_MIN_PCT" ] && add_constraint memory
[ "$disk_free_mb" != unknown ] && [ "$disk_free_mb" -lt "$DISK_FREE_MIN_MB" ] && add_constraint disk

free_lanes=unknown
case "$target" in
  none) reason=no-target ;;
  invalid) reason=invalid-target ;;
  *)
    free_lanes=$((target - lanes))
    [ "$free_lanes" -ge 0 ] || free_lanes=0
    if [ -n "$constraints" ]; then
      free_lanes=0
      reason=$constraints
    elif [ "$free_lanes" -gt 0 ]; then
      reason=ok
    else
      reason=full
    fi
    ;;
esac

printf 'capacity: free_lanes=%s reason=%s lanes=%s target=%s secondmates=%s load1=%s cores=%s mem_free_pct=%s disk_free_mb=%s\n' \
  "$free_lanes" "$reason" "$lanes" "$target" "$secondmates" "$load1" "$cores" "$mem_free_pct" "$disk_free_mb"

case "$target" in
  none) echo "Lanes: $lanes running, no target set (config/lane-capacity absent)." ;;
  invalid) echo "Lanes: $lanes running, target unreadable ($target_error)." ;;
  *) echo "Lanes: $lanes running of $target target, $free_lanes open." ;;
esac
[ "$secondmates" -eq 0 ] || echo "Secondmates: $secondmates (hold no lane)."
mem_text="${mem_free_pct}%"; [ "$mem_free_pct" != unknown ] || mem_text=unknown
disk_text="$disk_free_mb MB"; [ "$disk_free_mb" != unknown ] || disk_text=unknown
echo "Host: load $load1 on $cores cores, memory free $mem_text, disk free $disk_text."
[ -z "$constraints" ] || echo "Constrained: $constraints - hold new dispatch until it clears."

if [ -n "$target_error" ]; then
  echo "fm-capacity: $target_error" >&2
  exit 1
fi
exit 0
