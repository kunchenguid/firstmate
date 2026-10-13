#!/usr/bin/env bash
# fm-host-headroom.sh - treat this machine's memory as one budget shared by every
# Firstmate home, project, and worker on it: measure the headroom left, decide
# whether one more worker of a given kind fits, and keep the footprint record
# that shows what each kind of worker really uses.
#
# Every home and worker on a machine shares its memory, so a fan-out that
# exhausts it takes all of them down at once, whichever projects the workers
# belong to. bin/fm-spawn.sh runs `check` before a fresh ship or scout launch
# with the new worker's kind, harness, model, and project, and defers the launch
# when the machine's headroom, less the memory every running worker still needs
# to reach its expected footprint and less the memory the new worker is
# expected to use, would fall below the thresholds. A worker launched seconds
# ago has barely grown, so without that reservation a rapid fan-out would pass
# every check and exhaust memory once its workers grow. bin/fm-spawn.sh holds
# the machine-wide lock .host-headroom.lock in the root home's state directory
# from check until the new task record is published, so concurrent spawns from
# any home are judged one at a time, each seeing the workers admitted before
# it. A mix of workers from different projects is therefore admitted together
# until the machine budget is spent. A relaunch of existing work and a
# --secondmate spawn are not gated. This file is the single
# owner of what is measured, the threshold file format, the expected-footprint
# rule, the verdict, and the footprint log; docs/configuration.md
# "Host headroom" is the operator reference.
#
# Usage:
#   fm-host-headroom.sh check [--kind <kind>] [--harness <name>] [--model <name>] [--project <name>]
#   fm-host-headroom.sh record <event> <task-id> [<worktree>]
#   fm-host-headroom.sh sample
#   fm-host-headroom.sh report
#
# check prints one line, `ok: ...` or `defer: ...`, naming every measured value,
# the expected footprint and where it came from, and every threshold breached.
# --model and --project are accepted for the caller's symmetry and do not
# change the verdict. Exit 0 when the worker fits, 75 (the sysexits
# temporary-failure code bin/fm-project-capacity-lib.sh also uses for a
# deferral) when it does not, 1 when the threshold file is unreadable, and 2 for
# bad usage.
#
# Measurements. A value that cannot be measured is printed as `?` and judged by
# no threshold, so a missing tool or an unfamiliar platform never blocks a spawn;
# the line then says which values were unmeasured. check first samples every
# running worker (see sample below), so the footprint log learns from workers
# while they work at every spawn.
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
# Machine-wide files. The thresholds and the footprint log live in the local
# root Firstmate home (the home bin/fm-wake-lib.sh's fm_firstmate_root_home
# resolves): config/host-headroom and state/host-footprint.log. Every home on
# this machine therefore judges the same machine by the same numbers and learns
# from every worker the machine has run. When this home is the root, or the
# root cannot be resolved, its own config and state directories (and their
# overrides) are used.
#
# Thresholds: config/host-headroom; absent, the defaults below apply. One
# `key=value` per line; blank lines and lines starting with `#` are ignored; any
# value except default_worker_mb may be `off` to disable that threshold.
#   min_avail_pct=20         defer when available memory, less the new
#                            worker's expected footprint, would fall below this
#                            percent of total memory
#   max_swap_used_mb=16384   defer when swap in use exceeds this many MB
#   max_load_per_core=1.5    defer when the 1-minute load per core exceeds this
#   defer_pressure=critical  defer at this kernel pressure level or worse
#                            (warn or critical)
#   default_worker_mb=1536   expected footprint of a worker before the log has
#                            enough observations of its kind
# The defaults suit a 48 GB Mac running a large fleet: macOS sits at the warn
# pressure level and keeps several GB of swap in use during ordinary heavy
# work, so only the critical level and a swap total well past that defer. An
# unknown key, a malformed value, a duplicate key, or an unreadable file makes
# check and report exit 1, and bin/fm-spawn.sh then refuses rather than
# guessing the intended limits.
# FM_SPAWN_IGNORE_HEADROOM=1 in bin/fm-spawn.sh's environment skips check for
# that one spawn; it is never read here.
#
# Expected footprint. A task's footprint is the largest worker resident memory
# the log holds for it, and a task counts only once the log holds a mid-work
# reading of it: an event=sample reading taken at least 600 seconds after the
# task's event=spawn. A reading taken while the worker is still starting up, or
# for a task the log holds no spawn of, is not mid-work, and a teardown reading
# is taken after the worker handed off and its builds and tests exited, so
# either can raise a task's footprint but never makes a task count on its own.
# Readings under 32 MB are
# only a shell left in a worktree whose agent has exited, so they count neither
# as a footprint nor as a running worker. The expected footprint of a new
# worker is the 90th percentile (nearest rank) of the footprints of the first
# of these groups that holds at least 3 such tasks: the same kind and harness,
# the same kind, every task. With fewer observations it is default_worker_mb.
#
# Reservation. Every ship or scout record whose worktree still exists (the
# workers sample sees) reserves its own expected footprint less its resident
# memory now, or nothing when it already uses more; check and report subtract
# that total from available memory before they judge or budget.
#
# Test seam: only while FM_TEST_SEAM=1, FM_HOST_HEADROOM_SAMPLE replaces every
# measurement with its space-separated total_mb, avail_mb, avail_pct,
# swap_used_mb, load1, cores, and pressure values; FM_HOST_HEADROOM_PLATFORM
# forces the darwin or linux reader; and FM_HOST_HEADROOM_PROC names the /proc
# root the linux reader uses.
#
# Footprint log: one line per event, appended and never rewritten:
#   <epoch> event=<event> task=<id> project=<name|-> kind=<kind|->
#     harness=<name|-> model=<name|-> worker_rss_mb=<n|-> avail_pct=<n|?>
#     avail_mb=<n|?> total_mb=<n|?> swap_used_mb=<n|?> load1=<n|?> cores=<n|?>
#     pressure=<level|?>
# (one physical line; whitespace and `=` inside a value become `_`). record
# reads the task's project (its clone directory name), kind, harness, and model
# from this home's state/<id>.meta. bin/fm-spawn.sh records event=spawn after a
# fresh launch, with no worker memory yet, and bin/fm-teardown.sh records
# event=teardown with the worker's resident memory before it stops the worker's
# processes. A worker's resident memory is the summed RSS of every process
# whose current directory is inside its task worktree, which covers the agent
# and the tools and tests it runs there on every runtime backend. record never
# fails its caller's work: a measurement it cannot take is written as `?` or
# `-`.
# sample records event=sample for every ship or scout task record, in this
# machine's root home and every local secondmate home under it, whose worktree
# still exists, so a long-running worker's footprint is seen while it works
# rather than only at cleanup.
#
# report runs sample, then summarizes: this machine's headroom and the budget
# above the min_avail_pct floor after the running workers' reservation; the workers running now; footprint median,
# 90th percentile, and largest by kind and harness and by project; how many
# more workers of each kind and harness fit in the budget; the largest
# concurrent worker count the thresholds imply; and, for every project cloned
# in the root home, whether its worktree pool cap (max_trees in the clone's
# treehouse.toml, else treehouse's default of 16) binds before that machine
# budget does.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

FM_HOST_HEADROOM_DEFER_EXIT=75
FM_HOST_HEADROOM_MIN_GROUP=3
FM_HOST_HEADROOM_MIDWORK_SECS=600
FM_HOST_HEADROOM_MIN_WORKER_MB=32
FM_HOST_HEADROOM_TREEHOUSE_DEFAULT_TREES=16

usage() {
  sed -n '/^# Usage:/,/^# check prints/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

# The root home's <sub> directory, or <own> when this home is the root (so an
# override of it applies). Falls back to <own> when the root cannot be resolved.
root_dir() {  # <sub> <own>
  local root home_real
  root=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || { printf '%s\n' "$2"; return 0; }
  home_real=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { printf '%s\n' "$2"; return 0; }
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$2"
  else
    printf '%s/%s\n' "$root" "$1"
  fi
}

FOOTPRINT_LOG="$(root_dir state "$STATE")/host-footprint.log"

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
is_num() {
  case "$1" in '' | . | *.*.* | *[!0-9.]*) return 1 ;; esac
}
# A log field value: never empty, no whitespace or '='.
field() { if [ -n "$1" ]; then printf '%s' "$1" | tr ' \t=' '___'; else printf -- '-'; fi; }

# --- measurement --------------------------------------------------------------

# Sets H_TOTAL_MB, H_AVAIL_MB, H_AVAIL_PCT, H_SWAP_USED_MB, H_LOAD1, H_CORES, and
# H_PRESSURE; a value that cannot be measured is left empty.
measure() {
  local kv platform=${_FM_UNAME:-unknown}
  H_TOTAL_MB='' H_AVAIL_MB='' H_AVAIL_PCT='' H_SWAP_USED_MB='' H_LOAD1='' H_CORES='' H_PRESSURE=''
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HOST_HEADROOM_SAMPLE+x}" ]; then
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
  else
    if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HOST_HEADROOM_PLATFORM:-}" ]; then
      platform=$FM_HOST_HEADROOM_PLATFORM
    fi
    case "$platform" in
      Darwin | darwin) measure_darwin ;;
      Linux | linux) measure_linux ;;
    esac
  fi
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

load_per_core() {
  is_num "$H_LOAD1" && is_uint "$H_CORES" || return 1
  awk -v l="$H_LOAD1" -v c="$H_CORES" 'BEGIN { printf "%.2f", l / c }'
}

pressure_rank() {
  case "$1" in normal) echo 1 ;; warn) echo 2 ;; critical) echo 3 ;; *) echo 0 ;; esac
}

# --- thresholds ---------------------------------------------------------------

# Sets T_MIN_AVAIL_PCT, T_MAX_SWAP_USED_MB, T_MAX_LOAD_PER_CORE, T_DEFER_PRESSURE
# (empty means off), T_DEFAULT_WORKER_MB, and T_FILE. Returns 1 with T_ERROR
# when the file is unreadable.
load_thresholds() {
  local line lineno=0 key value seen='|'
  T_MIN_AVAIL_PCT=20 T_MAX_SWAP_USED_MB=16384 T_MAX_LOAD_PER_CORE=1.5 T_DEFER_PRESSURE=critical
  T_DEFAULT_WORKER_MB=1536
  T_FILE="$(root_dir config "$CONFIG")/host-headroom"
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
        default_worker_mb) T_ERROR="$T_FILE line $lineno: default_worker_mb cannot be off"; return 1 ;;
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
      default_worker_mb)
        { is_uint "$value" && [ "$value" -gt 0 ]; } || { T_ERROR="$T_FILE line $lineno: default_worker_mb must be a positive whole number of MB"; return 1; }
        T_DEFAULT_WORKER_MB=$value ;;
      *) T_ERROR="$T_FILE line $lineno has unknown key $key"; return 1 ;;
    esac
  done < "$T_FILE"
  return 0
}

# --- footprint statistics -------------------------------------------------------

# One line per task with a measured footprint: "<peak-mb> <kind> <harness> <project>".
task_footprints() {
  [ -f "$FOOTPRINT_LOG" ] || return 0
  awk -v min="$FM_HOST_HEADROOM_MIN_WORKER_MB" -v midwork="$FM_HOST_HEADROOM_MIDWORK_SECS" '
    { split("", f); for (i = 2; i <= NF; i++) { p = index($i, "="); if (p) f[substr($i, 1, p - 1)] = substr($i, p + 1) } }
    !("task" in f) || f["task"] == "-" { next }
    { t = f["task"]
      if (("kind" in f) && f["kind"] != "-") kind[t] = f["kind"]
      if (("harness" in f) && f["harness"] != "-") harness[t] = f["harness"]
      if (("project" in f) && f["project"] != "-") project[t] = f["project"]
      if (f["event"] == "spawn") spawned[t] = $1 + 0
      if (f["worker_rss_mb"] !~ /^[0-9]+$/) next
      if (f["worker_rss_mb"] + 0 > peak[t] + 0) peak[t] = f["worker_rss_mb"] + 0
      if (f["event"] == "sample" && f["worker_rss_mb"] + 0 >= min && (t in spawned) && $1 - spawned[t] >= midwork) sampled[t] = 1 }
    END { for (t in sampled)
      print peak[t], (t in kind ? kind[t] : "-"), (t in harness ? harness[t] : "-"), (t in project ? project[t] : "-") }
  ' "$FOOTPRINT_LOG" 2>/dev/null
}

# "<count> <median> <p90> <largest>" over the footprint values on stdin.
stats() {
  sort -n | awk 'NF { v[++n] = $1 }
    END { if (!n) { print 0, 0, 0, 0; exit }
      r = int(n * 0.9); if (r < n * 0.9) r++
      print n, v[int((n + 1) / 2)], v[r], v[n] }'
}

# Sets E_MB and E_BASIS: the expected footprint of a new worker, from the
# task_footprints rows in FP_ROWS.
expected_footprint() {  # <kind> <harness>
  local kind=$1 harness=$2 scope s
  for scope in kind-harness kind all; do
    case "$scope" in
      kind-harness)
        [ -n "$kind" ] && [ -n "$harness" ] || continue
        s=$(printf '%s\n' "$FP_ROWS" | awk -v k="$kind" -v h="$harness" 'NF && $2 == k && $3 == h { print $1 }' | stats) ;;
      kind)
        [ -n "$kind" ] || continue
        s=$(printf '%s\n' "$FP_ROWS" | awk -v k="$kind" 'NF && $2 == k { print $1 }' | stats) ;;
      all) s=$(printf '%s\n' "$FP_ROWS" | awk 'NF { print $1 }' | stats) ;;
    esac
    # shellcheck disable=SC2086 # word-split the four stats fields.
    set -- $s
    [ "$1" -ge "$FM_HOST_HEADROOM_MIN_GROUP" ] || continue
    E_MB=$3
    case "$scope" in
      kind-harness) E_BASIS="90th percentile of $1 $kind $harness workers" ;;
      kind) E_BASIS="90th percentile of $1 $kind workers" ;;
      all) E_BASIS="90th percentile of $1 workers" ;;
    esac
    return 0
  done
  E_MB=$T_DEFAULT_WORKER_MB
  E_BASIS="default_worker_mb, fewer than $FM_HOST_HEADROOM_MIN_GROUP measured workers${kind:+ of kind $kind}"
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

# The available-memory floor in MB; fails when it cannot be computed.
floor_mb() {
  [ -n "$T_MIN_AVAIL_PCT" ] && is_uint "$H_TOTAL_MB" || return 1
  printf '%s\n' $((H_TOTAL_MB * T_MIN_AVAIL_PCT / 100))
}

add_reason() { V_REASONS="${V_REASONS:+$V_REASONS; }$1"; }
add_unmeasured() { V_UNMEASURED="${V_UNMEASURED:+$V_UNMEASURED, }$1"; }

# Sets V_REASONS (breached thresholds, '; '-joined) and V_UNMEASURED for a new
# worker expected to use <expected-mb> while running workers reserve
# <reserved-mb>.
judge() {  # <expected-mb> <reserved-mb>
  local expected=$1 reserved=$2 lpc floor left
  V_REASONS='' V_UNMEASURED=''
  if [ -n "$T_MIN_AVAIL_PCT" ]; then
    if ! is_uint "$H_AVAIL_MB" || ! floor=$(floor_mb); then
      add_unmeasured "available memory"
    else
      left=$((H_AVAIL_MB - reserved - expected))
      if [ "$left" -lt "$floor" ]; then
        add_reason "available memory $H_AVAIL_MB MB less $reserved MB reserved for running workers and this worker's expected $expected MB leaves $left MB, below min_avail_pct=$T_MIN_AVAIL_PCT ($floor MB)"
      fi
    fi
  fi
  if [ -n "$T_MAX_SWAP_USED_MB" ]; then
    if ! is_uint "$H_SWAP_USED_MB"; then
      add_unmeasured "swap"
    elif [ "$H_SWAP_USED_MB" -gt "$T_MAX_SWAP_USED_MB" ]; then
      add_reason "swap used $H_SWAP_USED_MB MB exceeds max_swap_used_mb=$T_MAX_SWAP_USED_MB"
    fi
  fi
  if [ -n "$T_MAX_LOAD_PER_CORE" ]; then
    if ! lpc=$(load_per_core); then
      add_unmeasured "load"
    elif awk -v a="$lpc" -v b="$T_MAX_LOAD_PER_CORE" 'BEGIN { exit !(a > b) }'; then
      add_reason "load $lpc per core exceeds max_load_per_core=$T_MAX_LOAD_PER_CORE"
    fi
  fi
  if [ -n "$T_DEFER_PRESSURE" ]; then
    if [ "$(pressure_rank "$H_PRESSURE")" -eq 0 ]; then
      add_unmeasured "pressure level"
    elif [ "$(pressure_rank "$H_PRESSURE")" -ge "$(pressure_rank "$T_DEFER_PRESSURE")" ]; then
      add_reason "memory pressure is $H_PRESSURE (defer_pressure=$T_DEFER_PRESSURE)"
    fi
  fi
}

cmd_check() {
  local kind='' harness='' tail=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || usage; kind=$2; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || usage; harness=$2; shift 2 ;;
      --model | --project) [ "$#" -ge 2 ] || usage; shift 2 ;;
      *) usage ;;
    esac
  done
  if ! load_thresholds; then
    echo "error: host headroom thresholds are unreadable: $T_ERROR" >&2
    return 1
  fi
  cmd_sample
  reserve_live
  [ -z "$kind" ] || kind=$(field "$kind")
  [ -z "$harness" ] || harness=$(field "$harness")
  expected_footprint "$kind" "$harness"
  judge "$E_MB" "$S_RESERVED_MB"
  [ -z "$V_UNMEASURED" ] || tail=" (unmeasured, not judged: $V_UNMEASURED)"
  if [ -n "$V_REASONS" ]; then
    printf 'defer: %s - %s; expected worker %s MB (%s); %s running worker(s) reserve %s MB%s\n' "$V_REASONS" "$(numbers_text)" "$E_MB" "$E_BASIS" "$S_TRACKED" "$S_RESERVED_MB" "$tail"
    return "$FM_HOST_HEADROOM_DEFER_EXIT"
  fi
  printf 'ok: %s; expected worker %s MB (%s); %s running worker(s) reserve %s MB%s\n' "$(numbers_text)" "$E_MB" "$E_BASIS" "$S_TRACKED" "$S_RESERVED_MB" "$tail"
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

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

footprint_line() {  # <event> <task> <meta> <worker-rss-mb>
  local meta=$3 project
  project=$(meta_value "$meta" project)
  printf '%s event=%s task=%s project=%s kind=%s harness=%s model=%s worker_rss_mb=%s avail_pct=%s avail_mb=%s total_mb=%s swap_used_mb=%s load1=%s cores=%s pressure=%s\n' \
    "$(date +%s)" "$1" "$(field "$2")" "$(field "${project##*/}")" "$(field "$(meta_value "$meta" kind)")" \
    "$(field "$(meta_value "$meta" harness)")" "$(field "$(meta_value "$meta" model)")" "${4:--}" \
    "$(show "$H_AVAIL_PCT")" "$(show "$H_AVAIL_MB")" "$(show "$H_TOTAL_MB")" "$(show "$H_SWAP_USED_MB")" \
    "$(show "$H_LOAD1")" "$(show "$H_CORES")" "$(show "$H_PRESSURE")"
}

append_footprint() {  # <line>
  mkdir -p "${FOOTPRINT_LOG%/*}" 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$FOOTPRINT_LOG" 2>/dev/null
}

cmd_record() {
  local event=${1:-} task=${2:-} wt=${3:-} rss=''
  [ -n "$event" ] && [ -n "$task" ] && [ "$#" -le 3 ] || usage
  case "$event" in *[!a-z-]*) usage ;; esac
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    rss=$(worktree_rss_mb "$wt" "$(process_cwds)") || rss=''
  fi
  measure
  append_footprint "$(footprint_line "$event" "$task" "$STATE/$task.meta" "$rss")" ||
    echo "warning: could not append to $FOOTPRINT_LOG" >&2
  return 0
}

# Ship and scout records whose worktree still exists, in this machine's root
# home and every local secondmate home under it, as "<meta-path><TAB><worktree>".
live_workers() {
  local dir meta kind wt
  fm_local_firstmate_state_dirs "$STATE" ||
    echo "warning: not every local Firstmate home could be read, so only the workers of ${FM_LOCAL_FIRSTMATE_STATES[*]} are counted: $FM_LOCAL_FIRSTMATE_ERROR" >&2
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] || continue
      kind=$(meta_value "$meta" kind)
      [ "$kind" != secondmate ] || continue
      wt=$(meta_value "$meta" worktree)
      [ -n "$wt" ] && [ -d "$wt" ] || continue
      printf '%s\t%s\n' "$meta" "$wt"
    done
  done
}

# Sets S_LIVE and S_LIVE_MB to the number of workers sampled with resident
# memory and their total, S_TRACKED to the number of worker records sampled,
# and S_WORKERS to one "<kind> <harness> <rss-mb>" line per record.
cmd_sample() {
  local meta wt rss cwds='' id live
  S_LIVE=0 S_LIVE_MB=0 S_TRACKED=0 S_WORKERS=''
  measure
  live=$(live_workers)
  [ -z "$live" ] || cwds=$(process_cwds) || cwds=''
  while IFS=$'\t' read -r meta wt; do
    [ -n "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    rss=$(worktree_rss_mb "$wt" "$cwds") || rss=''
    S_TRACKED=$((S_TRACKED + 1))
    S_WORKERS="$S_WORKERS$(field "$(meta_value "$meta" kind)") $(field "$(meta_value "$meta" harness)") ${rss:-0}
"
    if is_uint "$rss" && [ "$rss" -ge "$FM_HOST_HEADROOM_MIN_WORKER_MB" ]; then
      S_LIVE=$((S_LIVE + 1))
      S_LIVE_MB=$((S_LIVE_MB + rss))
    fi
    append_footprint "$(footprint_line sample "$id" "$meta" "$rss")" ||
      echo "warning: could not append to $FOOTPRINT_LOG" >&2
  done <<EOF
$live
EOF
  return 0
}

# Sets FP_ROWS to task_footprints and S_RESERVED_MB to what the workers
# cmd_sample saw still need to reach their expected footprints. Requires
# load_thresholds and cmd_sample.
reserve_live() {
  local kind harness rss
  FP_ROWS=$(task_footprints)
  S_RESERVED_MB=0
  while read -r kind harness rss; do
    [ -n "$kind" ] || continue
    [ "$kind" != - ] || kind=''
    [ "$harness" != - ] || harness=''
    expected_footprint "$kind" "$harness"
    [ "$rss" -ge "$E_MB" ] || S_RESERVED_MB=$((S_RESERVED_MB + E_MB - rss))
  done <<EOF
$S_WORKERS
EOF
}

# --- report -------------------------------------------------------------------

# max_trees from a clone's treehouse.toml, else treehouse's default.
pool_cap() {  # <clone>
  local v=''
  [ ! -f "$1/treehouse.toml" ] ||
    v=$(sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/treehouse.toml" | head -1)
  if is_uint "$v"; then printf '%s\n' "$v"; else printf '%s\n' "$FM_HOST_HEADROOM_TREEHOUSE_DEFAULT_TREES"; fi
}

# Print "  <label>: <n> task(s), median ..., p90 ..., largest ...[; <k> more fit
# in the budget]" for the footprints on stdin.
group_line() {  # <label> <budget-mb|empty>
  local s fit=''
  s=$(stats)
  # shellcheck disable=SC2086 # word-split the four stats fields.
  set -- "$1" "$2" $s
  [ -z "$2" ] || fit="; $(($2 / $5)) more fit in the budget"
  echo "  $1: $3 task(s), median $4 MB, p90 $5 MB, largest $6 MB$fit"
}

cmd_report() {
  [ "$#" -eq 0 ] || usage
  if ! load_thresholds; then
    echo "error: host headroom thresholds are unreadable: $T_ERROR" >&2
    return 1
  fi
  cmd_sample
  reserve_live
  local budget='' floor total='' more key clone cap pools
  expected_footprint '' ''
  judge "$E_MB" "$S_RESERVED_MB"
  echo "Host headroom now: $(numbers_text)"
  if [ -n "$V_REASONS" ]; then
    echo "Verdict for one more worker: defer - $V_REASONS"
  else
    echo "Verdict for one more worker: ok"
  fi
  echo "Thresholds ($T_FILE): min_avail_pct=$(show "$T_MIN_AVAIL_PCT") max_swap_used_mb=$(show "$T_MAX_SWAP_USED_MB") max_load_per_core=$(show "$T_MAX_LOAD_PER_CORE") defer_pressure=$(show "$T_DEFER_PRESSURE") default_worker_mb=$T_DEFAULT_WORKER_MB"
  if is_uint "$H_AVAIL_MB" && floor=$(floor_mb); then
    budget=$((H_AVAIL_MB - floor - S_RESERVED_MB))
    [ "$budget" -ge 0 ] || budget=0
    echo "Machine budget: $budget MB available above the $T_MIN_AVAIL_PCT% floor ($floor MB) after $S_RESERVED_MB MB reserved for $S_TRACKED running worker(s) to reach their expected footprint, shared by every project"
  else
    echo "Machine budget: unknown (available memory or min_avail_pct is not available)"
  fi
  echo "Workers running now with measured memory: $S_LIVE using $S_LIVE_MB MB"
  if [ -z "$FP_ROWS" ]; then
    echo "Per-worker memory: no worker samples yet in $FOOTPRINT_LOG; new workers are expected at default_worker_mb=$T_DEFAULT_WORKER_MB MB"
  else
    echo "Per-worker memory (largest seen per task) by kind and harness:"
    for key in $(printf '%s\n' "$FP_ROWS" | awk 'NF { print $2 "/" $3 }' | sort -u); do
      printf '%s\n' "$FP_ROWS" | awk -v k="${key%%/*}" -v h="${key#*/}" 'NF && $2 == k && $3 == h { print $1 }' |
        group_line "$key" "$budget"
    done
    echo "Per-worker memory by project:"
    for key in $(printf '%s\n' "$FP_ROWS" | awk 'NF { print $4 }' | sort -u); do
      printf '%s\n' "$FP_ROWS" | awk -v p="$key" 'NF && $4 == p { print $1 }' | group_line "$key" ''
    done
  fi
  if [ -n "$budget" ]; then
    more=$((budget / E_MB))
    total=$((S_TRACKED + more))
    echo "Largest safe concurrent worker count implied: $total ($S_TRACKED running + $more more at $E_MB MB each, $E_BASIS)"
  else
    echo "Largest safe concurrent worker count implied: unknown"
  fi
  pools=$(root_dir projects "$PROJECTS")
  [ -d "$pools" ] || return 0
  echo "Project worktree pools ($pools):"
  for clone in "$pools"/*/; do
    [ -d "$clone" ] || continue
    clone=${clone%/}
    cap=$(pool_cap "$clone")
    if [ -z "$total" ]; then
      echo "  ${clone##*/}: pool cap $cap"
    elif [ "$cap" -lt "$total" ]; then
      echo "  ${clone##*/}: pool cap $cap binds before the machine budget ($total workers)"
    else
      echo "  ${clone##*/}: pool cap $cap; the machine budget ($total workers) binds first"
    fi
  done
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  record) shift; cmd_record "$@" ;;
  sample) shift; [ "$#" -eq 0 ] || usage; cmd_sample ;;
  report) shift; cmd_report "$@" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
