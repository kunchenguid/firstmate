#!/usr/bin/env bash
# fm-host-headroom.sh - measure this machine's memory and CPU headroom, decide
# whether one more worker fits, and keep the footprint record that shows what a
# healthy worker load is.
#
# Every Firstmate home and worker on a machine shares its memory, so a fan-out
# that exhausts it takes all of them down at once. bin/fm-spawn.sh runs `check`
# before a fresh ship or scout launch and defers the launch when the machine is
# already below its headroom thresholds. A relaunch of existing work and a
# --secondmate spawn are not gated. This file is the single owner of what is
# measured, the threshold file format, the verdict, and the footprint log;
# docs/configuration.md "Host headroom" is the operator reference.
#
# Usage:
#   fm-host-headroom.sh check
#   fm-host-headroom.sh record <event> [<task-id> [<worktree>]]
#   fm-host-headroom.sh sample
#   fm-host-headroom.sh report
#
# check prints one line, `ok: ...` or `defer: ...`, naming every measured value
# and every threshold it breached. Exit 0 when the machine has headroom, 75
# (the sysexits temporary-failure code bin/fm-project-capacity-lib.sh also uses
# for a deferral) when it does not, 1 when the threshold file is unreadable, and
# 2 for bad usage.
#
# Measurements. A value that cannot be measured is printed as `?` and judged by
# no threshold, so a missing tool or an unfamiliar platform never blocks a spawn;
# the line then says which values were unmeasured.
#   macOS: total memory from `sysctl hw.memsize`; available percent from
#   `sysctl kern.memorystatus_level`, the system-wide free percentage
#   `memory_pressure` reports, falling back to free plus inactive plus
#   speculative pages from `vm_stat`; swap used from `sysctl vm.swapusage`;
#   the kernel pressure level (normal, warn, critical) from
#   `sysctl kern.memorystatus_vm_pressure_level`; the 1-minute load average
#   from `sysctl vm.loadavg` and the core count from `sysctl hw.ncpu`.
#   Linux: MemTotal, MemAvailable, SwapTotal, and SwapFree from /proc/meminfo,
#   the 1-minute load average from /proc/loadavg, and the core count from
#   `getconf _NPROCESSORS_ONLN`; Linux reports no pressure level.
#
# Thresholds: config/host-headroom in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine judges the same machine by the same numbers. Absent, the defaults
# below apply. One `key=value` per line; blank lines and lines starting with `#`
# are ignored; any value may be `off` to disable that threshold.
#   min_avail_pct=20        defer when available memory is below this percent
#   max_swap_used_mb=16384  defer when swap in use exceeds this many MB
#   max_load_per_core=1.5   defer when the 1-minute load per core exceeds this
#   defer_pressure=critical defer at this kernel pressure level or worse
#                           (warn or critical)
# The defaults suit a 48 GB Mac running a large fleet: macOS sits at the warn
# pressure level and keeps several GB of swap in use during ordinary heavy
# work, so only the critical level and a swap total well past that defer. An
# unknown key, a malformed value, a duplicate key, or an unreadable file makes
# check exit 1, and bin/fm-spawn.sh then refuses rather than guessing the
# intended limits.
# FM_SPAWN_IGNORE_HEADROOM=1 in bin/fm-spawn.sh's environment skips check for
# that one spawn; it is never read here.
#
# Test seam: only while FM_TEST_SEAM=1, FM_HOST_HEADROOM_SAMPLE replaces every
# measurement with its space-separated total_mb, avail_mb, avail_pct,
# swap_used_mb, load1, cores, and pressure values; FM_HOST_HEADROOM_PLATFORM
# forces the darwin or linux reader; and FM_HOST_HEADROOM_PROC names the /proc
# root the linux reader uses.
#
# Footprint log: state/host-footprint.log in the home running the command, one
# line per event, appended and never rewritten:
#   <epoch> event=<event> task=<id|-> worker_rss_mb=<n|-> avail_pct=<n|?>
#     avail_mb=<n|?> total_mb=<n|?> swap_used_mb=<n|?> load1=<n|?> cores=<n|?>
#     pressure=<level|?>
# (one physical line). bin/fm-spawn.sh records event=spawn after a fresh launch,
# with no worker memory yet, and bin/fm-teardown.sh records event=teardown with
# the worker's resident memory before it stops the worker's processes. A
# worker's resident memory is the summed RSS of every process whose current
# directory is inside its task worktree, which covers the agent and the tools
# and tests it runs there on every runtime backend. record never fails its
# caller's work: a measurement it cannot take is written as `?` or `-`.
# sample records event=sample for every ship or scout task record in this home
# whose worktree still exists, so a long-running worker's footprint is seen
# while it works rather than only at cleanup.
# report runs sample, then summarizes the log: the largest resident memory seen
# for each task, the median and largest of those across tasks, this machine's
# current headroom, and how many more workers of the largest observed size fit
# before available memory reaches min_avail_pct - which, added to the workers
# running now, is the largest concurrent load the thresholds imply.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_HOST_HEADROOM_DEFER_EXIT=75
FOOTPRINT_LOG="$STATE/host-footprint.log"

usage() {
  sed -n '/^# Usage:/,/^# check prints/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

# The config directory holding this machine's thresholds: this home's own
# config dir when it is the local root (so an override of it applies),
# otherwise the root home's config/.
config_dir() {
  local root home_real
  root=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || { printf '%s\n' "$CONFIG"; return 0; }
  home_real=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { printf '%s\n' "$CONFIG"; return 0; }
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$CONFIG"
  else
    printf '%s/config\n' "$root"
  fi
}

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
is_num() {
  case "$1" in '' | . | *.*.* | *[!0-9.]*) return 1 ;; esac
}

# --- measurement --------------------------------------------------------------

# Sets H_TOTAL_MB, H_AVAIL_MB, H_AVAIL_PCT, H_SWAP_USED_MB, H_LOAD1, H_CORES, and
# H_PRESSURE; a value that cannot be measured is left empty.
measure() {
  H_TOTAL_MB='' H_AVAIL_MB='' H_AVAIL_PCT='' H_SWAP_USED_MB='' H_LOAD1='' H_CORES='' H_PRESSURE=''
  local platform=${_FM_UNAME:-unknown}
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HOST_HEADROOM_PLATFORM:-}" ]; then
    platform=$FM_HOST_HEADROOM_PLATFORM
  fi
  case "$platform" in
    Darwin | darwin) measure_darwin ;;
    Linux | linux) measure_linux ;;
  esac
  derive_avail
}

# Fill whichever of available MB and available percent is missing from the other.
derive_avail() {
  if [ -z "$H_AVAIL_MB" ] && is_uint "$H_AVAIL_PCT" && is_uint "$H_TOTAL_MB"; then
    H_AVAIL_MB=$((H_TOTAL_MB * H_AVAIL_PCT / 100))
  fi
  if [ -z "$H_AVAIL_PCT" ] && is_uint "$H_AVAIL_MB" && is_uint "$H_TOTAL_MB" && [ "$H_TOTAL_MB" -gt 0 ]; then
    H_AVAIL_PCT=$((H_AVAIL_MB * 100 / H_TOTAL_MB))
  fi
  return 0
}

measure_darwin() {
  local v page free inactive spec
  v=$(sysctl -n hw.memsize 2>/dev/null) && is_uint "$v" && H_TOTAL_MB=$((v / 1048576))
  v=$(sysctl -n kern.memorystatus_level 2>/dev/null) && is_uint "$v" && [ "$v" -le 100 ] && H_AVAIL_PCT=$v
  if [ -z "$H_AVAIL_PCT" ] && v=$(vm_stat 2>/dev/null); then
    page=$(printf '%s\n' "$v" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -1)
    free=$(printf '%s\n' "$v" | sed -n 's/^Pages free: *\([0-9][0-9]*\)\.*$/\1/p' | head -1)
    inactive=$(printf '%s\n' "$v" | sed -n 's/^Pages inactive: *\([0-9][0-9]*\)\.*$/\1/p' | head -1)
    spec=$(printf '%s\n' "$v" | sed -n 's/^Pages speculative: *\([0-9][0-9]*\)\.*$/\1/p' | head -1)
    is_uint "$spec" || spec=0
    if is_uint "$page" && is_uint "$free" && is_uint "$inactive"; then
      H_AVAIL_MB=$(((free + inactive + spec) * page / 1048576))
    fi
  fi
  if v=$(sysctl -n vm.swapusage 2>/dev/null); then
    v=$(printf '%s\n' "$v" | sed -n 's/.*used = \([0-9][0-9.]*\)\([KMG]\).*/\1 \2/p' | head -1)
    [ -z "$v" ] || H_SWAP_USED_MB=$(printf '%s\n' "$v" | awk '{ m = $1; if ($2 == "K") m /= 1024; if ($2 == "G") m *= 1024; printf "%d", m + 0.5 }')
  fi
  v=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) && case "$v" in
    1) H_PRESSURE=normal ;;
    2) H_PRESSURE=warn ;;
    4) H_PRESSURE=critical ;;
  esac
  if v=$(sysctl -n vm.loadavg 2>/dev/null); then
    v=$(printf '%s\n' "$v" | tr -d '{}' | awk '{ print $1 }')
    ! is_num "$v" || H_LOAD1=$v
  fi
  v=$(sysctl -n hw.ncpu 2>/dev/null) && is_uint "$v" && [ "$v" -gt 0 ] && H_CORES=$v
  return 0
}

measure_linux() {
  local proc=/proc v total avail stotal sfree
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HOST_HEADROOM_PROC:-}" ]; then
    proc=$FM_HOST_HEADROOM_PROC
  fi
  if [ -r "$proc/meminfo" ]; then
    total=$(awk '$1 == "MemTotal:" { print $2 }' "$proc/meminfo")
    avail=$(awk '$1 == "MemAvailable:" { print $2 }' "$proc/meminfo")
    stotal=$(awk '$1 == "SwapTotal:" { print $2 }' "$proc/meminfo")
    sfree=$(awk '$1 == "SwapFree:" { print $2 }' "$proc/meminfo")
    ! is_uint "$total" || H_TOTAL_MB=$((total / 1024))
    ! is_uint "$avail" || H_AVAIL_MB=$((avail / 1024))
    if is_uint "$stotal" && is_uint "$sfree"; then
      H_SWAP_USED_MB=$(((stotal - sfree) / 1024))
    fi
  fi
  if [ -r "$proc/loadavg" ]; then
    v=$(awk '{ print $1 }' "$proc/loadavg")
    ! is_num "$v" || H_LOAD1=$v
  fi
  v=$(getconf _NPROCESSORS_ONLN 2>/dev/null) && is_uint "$v" && [ "$v" -gt 0 ] && H_CORES=$v
  return 0
}

# The test seam replaces measurement with fixed values, so the verdict can be
# exercised at exact threshold edges on any machine.
measure_or_seam() {
  local kv
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HOST_HEADROOM_SAMPLE+x}" ]; then
    H_TOTAL_MB='' H_AVAIL_MB='' H_AVAIL_PCT='' H_SWAP_USED_MB='' H_LOAD1='' H_CORES='' H_PRESSURE=''
    for kv in $FM_HOST_HEADROOM_SAMPLE; do
      case "$kv" in
        total_mb=*) H_TOTAL_MB=${kv#*=} ;;
        avail_mb=*) H_AVAIL_MB=${kv#*=} ;;
        avail_pct=*) H_AVAIL_PCT=${kv#*=} ;;
        swap_used_mb=*) H_SWAP_USED_MB=${kv#*=} ;;
        load1=*) H_LOAD1=${kv#*=} ;;
        cores=*) H_CORES=${kv#*=} ;;
        pressure=*) H_PRESSURE=${kv#*=} ;;
      esac
    done
    derive_avail
    return 0
  fi
  measure
}

load_per_core() {
  [ -n "$H_LOAD1" ] && [ -n "$H_CORES" ] || return 1
  awk -v l="$H_LOAD1" -v c="$H_CORES" 'BEGIN { printf "%.2f", l / c }'
}

pressure_rank() {
  case "$1" in normal) echo 1 ;; warn) echo 2 ;; critical) echo 3 ;; *) echo 0 ;; esac
}

# --- thresholds ---------------------------------------------------------------

# Sets T_MIN_AVAIL_PCT, T_MAX_SWAP_USED_MB, T_MAX_LOAD_PER_CORE, T_DEFER_PRESSURE
# (empty means off) and T_FILE. Returns 1 with T_ERROR when the file is unreadable.
load_thresholds() {
  local line lineno=0 key value seen='|'
  T_MIN_AVAIL_PCT=20 T_MAX_SWAP_USED_MB=16384 T_MAX_LOAD_PER_CORE=1.5 T_DEFER_PRESSURE=critical
  T_FILE="$(config_dir)/host-headroom"
  T_ERROR=
  [ -e "$T_FILE" ] || [ -L "$T_FILE" ] || return 0
  if [ ! -f "$T_FILE" ] || [ ! -r "$T_FILE" ]; then
    T_ERROR="$T_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) T_ERROR="$T_FILE line $lineno is not key=value"; return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$seen" in *"|$key|"*) T_ERROR="$T_FILE line $lineno sets $key twice"; return 1 ;; esac
    seen="$seen$key|"
    if [ "$value" = off ]; then
      case "$key" in
        min_avail_pct) T_MIN_AVAIL_PCT= ;;
        max_swap_used_mb) T_MAX_SWAP_USED_MB= ;;
        max_load_per_core) T_MAX_LOAD_PER_CORE= ;;
        defer_pressure) T_DEFER_PRESSURE= ;;
        *) T_ERROR="$T_FILE line $lineno has unknown key $key"; return 1 ;;
      esac
      continue
    fi
    case "$key" in
      min_avail_pct)
        { is_uint "$value" && [ "$value" -le 100 ]; } || { T_ERROR="$T_FILE line $lineno: min_avail_pct must be a whole percent from 0 to 100 or off"; return 1; }
        T_MIN_AVAIL_PCT=$value ;;
      max_swap_used_mb)
        is_uint "$value" || { T_ERROR="$T_FILE line $lineno: max_swap_used_mb must be a whole number of MB or off"; return 1; }
        T_MAX_SWAP_USED_MB=$value ;;
      max_load_per_core)
        is_num "$value" || { T_ERROR="$T_FILE line $lineno: max_load_per_core must be a number or off"; return 1; }
        T_MAX_LOAD_PER_CORE=$value ;;
      defer_pressure)
        case "$value" in warn | critical) ;; *) T_ERROR="$T_FILE line $lineno: defer_pressure must be warn, critical, or off"; return 1 ;; esac
        T_DEFER_PRESSURE=$value ;;
      *) T_ERROR="$T_FILE line $lineno has unknown key $key"; return 1 ;;
    esac
  done < "$T_FILE"
  return 0
}

# --- verdict ------------------------------------------------------------------

show() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '?'; fi; }

numbers_text() {
  local lpc
  lpc=$(load_per_core) || lpc='?'
  printf 'available %s%% (%s of %s MB), swap used %s MB, load %s on %s cores (%s per core), pressure %s' \
    "$(show "$H_AVAIL_PCT")" "$(show "$H_AVAIL_MB")" "$(show "$H_TOTAL_MB")" "$(show "$H_SWAP_USED_MB")" \
    "$(show "$H_LOAD1")" "$(show "$H_CORES")" "$lpc" "$(show "$H_PRESSURE")"
}

# Sets V_REASONS (breached thresholds, '; '-joined) and V_UNMEASURED.
judge() {
  local lpc
  V_REASONS='' V_UNMEASURED=''
  add_reason() { V_REASONS="${V_REASONS:+$V_REASONS; }$1"; }
  add_unmeasured() { V_UNMEASURED="${V_UNMEASURED:+$V_UNMEASURED, }$1"; }
  if [ -n "$T_MIN_AVAIL_PCT" ]; then
    if ! is_uint "$H_AVAIL_PCT"; then add_unmeasured "available memory"
    elif [ "$H_AVAIL_PCT" -lt "$T_MIN_AVAIL_PCT" ]; then
      add_reason "available memory ${H_AVAIL_PCT}% is below min_avail_pct=$T_MIN_AVAIL_PCT"
    fi
  fi
  if [ -n "$T_MAX_SWAP_USED_MB" ]; then
    if ! is_uint "$H_SWAP_USED_MB"; then add_unmeasured "swap"
    elif [ "$H_SWAP_USED_MB" -gt "$T_MAX_SWAP_USED_MB" ]; then
      add_reason "swap used ${H_SWAP_USED_MB} MB exceeds max_swap_used_mb=$T_MAX_SWAP_USED_MB"
    fi
  fi
  if [ -n "$T_MAX_LOAD_PER_CORE" ]; then
    if ! lpc=$(load_per_core) || ! is_num "$H_LOAD1" || ! is_uint "$H_CORES"; then add_unmeasured "load"
    elif awk -v a="$lpc" -v b="$T_MAX_LOAD_PER_CORE" 'BEGIN { exit !(a > b) }'; then
      add_reason "load ${lpc} per core exceeds max_load_per_core=$T_MAX_LOAD_PER_CORE"
    fi
  fi
  if [ -n "$T_DEFER_PRESSURE" ]; then
    if [ "$(pressure_rank "$H_PRESSURE")" -eq 0 ]; then add_unmeasured "pressure level"
    elif [ "$(pressure_rank "$H_PRESSURE")" -ge "$(pressure_rank "$T_DEFER_PRESSURE")" ]; then
      add_reason "memory pressure is $H_PRESSURE (defer_pressure=$T_DEFER_PRESSURE)"
    fi
  fi
}

cmd_check() {
  [ "$#" -eq 0 ] || usage
  if ! load_thresholds; then
    echo "error: host headroom thresholds are unreadable: $T_ERROR" >&2
    return 1
  fi
  measure_or_seam
  judge
  local tail=''
  [ -z "$V_UNMEASURED" ] || tail=" (unmeasured, not judged: $V_UNMEASURED)"
  if [ -n "$V_REASONS" ]; then
    printf 'defer: %s - %s%s\n' "$V_REASONS" "$(numbers_text)" "$tail"
    return "$FM_HOST_HEADROOM_DEFER_EXIT"
  fi
  printf 'ok: %s%s\n' "$(numbers_text)" "$tail"
}

# --- footprint ----------------------------------------------------------------

canon_dir() { (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P); }

# Print "pid cwd" for every process whose current directory is readable.
process_cwds() {
  local d pid cwd
  if [ -d /proc/self ] && [ -L /proc/self/cwd ]; then
    for d in /proc/[0-9]*; do
      pid=${d#/proc/}
      cwd=$(readlink "$d/cwd" 2>/dev/null) || continue
      printf '%s %s\n' "$pid" "$cwd"
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -w -a -d cwd -Fpn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^n/ { print pid, substr($0, 2) }'
}

# Summed RSS in MB of every process whose cwd is inside <dir>, given the
# process_cwds listing (read once per command); fails when it is unavailable.
worktree_rss_mb() {  # <dir> <process-cwds>
  local dir cwds=$2 pids
  dir=$(canon_dir "$1") || return 1
  [ -n "$cwds" ] || return 1
  pids=$(printf '%s\n' "$cwds" | awk -v d="$dir" '{
      pid = $1; sub(/^[^ ]+ /, "")
      if ($0 == d || index($0, d "/") == 1) print pid
    }')
  { printf '%s\n' "$pids" | sed -n 's/^\([0-9][0-9]*\)$/want \1/p'; ps -A -o pid=,rss= 2>/dev/null; } | awk '
    $1 == "want" { want[$2] = 1; next }
    ($1 in want) { kb += $2 }
    END { printf "%d\n", (kb + 512) / 1024 }'
}

footprint_line() {  # <event> <task> <worker-rss-mb>
  printf '%s event=%s task=%s worker_rss_mb=%s avail_pct=%s avail_mb=%s total_mb=%s swap_used_mb=%s load1=%s cores=%s pressure=%s\n' \
    "$(date +%s)" "$1" "${2:--}" "${3:--}" "$(show "$H_AVAIL_PCT")" "$(show "$H_AVAIL_MB")" \
    "$(show "$H_TOTAL_MB")" "$(show "$H_SWAP_USED_MB")" "$(show "$H_LOAD1")" "$(show "$H_CORES")" \
    "$(show "$H_PRESSURE")"
}

append_footprint() {  # <line>
  mkdir -p "$STATE" 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$FOOTPRINT_LOG" 2>/dev/null
}

cmd_record() {
  local event=${1:-} task=${2:-} wt=${3:-} rss=''
  [ -n "$event" ] && [ "$#" -le 3 ] || usage
  case "$event" in *[!a-z-]*) usage ;; esac
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    rss=$(worktree_rss_mb "$wt" "$(process_cwds)") || rss=''
  fi
  measure_or_seam
  append_footprint "$(footprint_line "$event" "$task" "$rss")" ||
    echo "warning: could not append to $FOOTPRINT_LOG" >&2
  return 0
}

# Ship and scout records in this home whose worktree still exists, as
# "id worktree" lines.
live_workers() {
  local meta id kind wt
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -1)
    [ "$kind" != secondmate ] || continue
    wt=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | tail -1)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    printf '%s %s\n' "$id" "$wt"
  done
}

# Sets S_LIVE to the number of workers sampled with resident memory.
cmd_sample() {
  local id wt rss cwds
  S_LIVE=0
  measure_or_seam
  cwds=$(process_cwds) || cwds=''
  while read -r id wt; do
    [ -n "$id" ] || continue
    rss=$(worktree_rss_mb "$wt" "$cwds") || rss=''
    if is_uint "$rss" && [ "$rss" -gt 0 ]; then S_LIVE=$((S_LIVE + 1)); fi
    append_footprint "$(footprint_line sample "$id" "$rss")" ||
      echo "warning: could not append to $FOOTPRINT_LOG" >&2
  done <<EOF
$(live_workers)
EOF
  return 0
}

cmd_report() {
  [ "$#" -eq 0 ] || usage
  if ! load_thresholds; then
    echo "error: host headroom thresholds are unreadable: $T_ERROR" >&2
    return 1
  fi
  cmd_sample
  measure_or_seam
  judge
  local stats tasks median largest floor_mb fit
  stats=$(awk '
      { task = ""; rss = "" }
      { for (i = 2; i <= NF; i++) {
          split($i, kv, "=")
          if (kv[1] == "task") task = kv[2]
          if (kv[1] == "worker_rss_mb") rss = kv[2]
        } }
      task != "-" && task != "" && rss ~ /^[0-9]+$/ && rss > 0 { if (rss > peak[task]) peak[task] = rss }
      END { for (t in peak) print peak[t] }' "$FOOTPRINT_LOG" 2>/dev/null | sort -n)
  tasks=$(printf '%s\n' "$stats" | awk 'NF { n++ } END { print n + 0 }')
  echo "Host headroom now: $(numbers_text)"
  if [ -n "$V_REASONS" ]; then
    echo "Verdict now: defer - $V_REASONS"
  else
    echo "Verdict now: ok"
  fi
  echo "Thresholds ($T_FILE): min_avail_pct=$(show "$T_MIN_AVAIL_PCT") max_swap_used_mb=$(show "$T_MAX_SWAP_USED_MB") max_load_per_core=$(show "$T_MAX_LOAD_PER_CORE") defer_pressure=$(show "$T_DEFER_PRESSURE")"
  echo "Workers running now with measured memory: $S_LIVE"
  if [ "$tasks" -eq 0 ]; then
    echo "Per-worker memory: no worker samples yet in $FOOTPRINT_LOG"
    return 0
  fi
  median=$(printf '%s\n' "$stats" | awk 'NF { v[++n] = $1 } END { print v[int((n + 1) / 2)] }')
  largest=$(printf '%s\n' "$stats" | awk 'NF { v = $1 } END { print v }')
  echo "Per-worker memory: largest seen per task across $tasks task(s) - median $median MB, largest $largest MB"
  if is_uint "$H_AVAIL_MB" && is_uint "$H_TOTAL_MB" && [ -n "$T_MIN_AVAIL_PCT" ] && [ "$largest" -gt 0 ]; then
    floor_mb=$((H_TOTAL_MB * T_MIN_AVAIL_PCT / 100))
    fit=0
    [ "$H_AVAIL_MB" -le "$floor_mb" ] || fit=$(((H_AVAIL_MB - floor_mb) / largest))
    echo "More workers that fit before available memory reaches $T_MIN_AVAIL_PCT% ($floor_mb MB): $fit at $largest MB each"
    echo "Largest safe concurrent worker count implied: $((S_LIVE + fit)) ($S_LIVE running + $fit more)"
  else
    echo "Largest safe concurrent worker count implied: unknown (available memory or min_avail_pct is not available)"
  fi
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  record) shift; cmd_record "$@" ;;
  sample) shift; [ "$#" -eq 0 ] || usage; cmd_sample ;;
  report) shift; cmd_report "$@" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
