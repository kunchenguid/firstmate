#!/usr/bin/env bash
# fm-capacity.sh - report open lanes and host headroom for queued-work dispatch,
# and publish this home's lane facts for placement.
#
# Usage:
#   fm-capacity.sh            the report: one key=value line, then a human summary
#   fm-capacity.sh --json     the fm-lane-capacity.v1 document on stdout
#   fm-capacity.sh --publish  write that document to state/lane-capacity.json
#   fm-capacity.sh --admit    this home's own admission verdict as an exit status
#   fm-capacity.sh --spawn-gate  --admit, but only when config/lane-capacity
#                             declares admit-spawns (bin/fm-spawn.sh's check)
#   fm-capacity.sh --spawn-gate-enabled  exit 0 when --spawn-gate would judge
#                             a spawn, 1 when it would admit unconditionally
#
# It reads this home's state/*.meta, the optional config/lane-capacity, the
# pressure files and reserve flags that file names, and the host's own probes.
# It never spawns, locks, or changes anything; --publish writes its files
# (state/lane-capacity.json, and in auto mode state/lane-footprint.json and the
# Windows host cache state/.lane-vitals-host).
# It is network-free unless config/lane-capacity names a quota-provider.
# docs/configuration.md "Lane capacity" owns the config/lane-capacity format
# (the cap on its first line, then optional keyed lines); with the file absent
# nothing changes and no target is ever invented.
#
# Report: the first line is machine-readable, one space-separated key=value
# list in this fixed order:
#   capacity: free_lanes=<N|unknown> reason=<reason> lanes=<N> target=<N|none|invalid>
#     secondmates=<N> load1=<X|unknown> cores=<N|unknown>
#     mem_free_pct=<N|unknown> disk_free_mb=<N|unknown>
# (one physical line). A short human summary follows it. load1, cores,
# mem_free_pct and disk_free_mb are always this host's own probes.
#
# lanes counts task metadata records whose kind is not secondmate (ship and
# scout work, including records not yet reconciled after an endpoint died).
# secondmates counts persistent secondmates separately; they hold no lane.
#
# target is the cap from config/lane-capacity. Absent means no target, so
# free_lanes=unknown reason=no-target and the counts are still printed. A
# malformed file reports target=invalid reason=invalid-target, names the
# problem and its line on stderr, and exits 1.
#
# With a target, free_lanes is target minus lanes (never below 0), unless a
# constraint holds, in which case free_lanes=0 and reason names every
# constraint, comma-separated, in this order:
#   cpu       probe basis: 1-minute load average >= logical cores
#   memory    probe basis: free-memory percentage < 10; or, with min-avail-gb
#             set, available memory minus min-avail-gb is under the 1 GB a
#             default lane needs
#   disk      probe basis: free space on the filesystem holding FM_HOME
#             < 5120 MB; or a disk row under min-disk-gb
#   pressure  beat basis: the pressure level is warn or critical
#   load      load1 is at or over max-load1
#   reserve   a reserve-flag file exists
#   battery   a fresh beat reports the machine on battery
# Otherwise reason is ok when free_lanes > 0 and full when it is 0.
# The human "Constrained" hold line is printed only when config/lane-capacity
# exists; without it the report is counts and host figures only, with no
# dispatch advice.
#
# Pressure basis. Each pressure-file is a lookout.beat 1.x document judged by
# its own file age against its interval_s (default 15): live up to two
# intervals, late (used, with "beat N s old" in why) up to four, stale beyond
# that and skipped. A missing, unreadable, or foreign file is skipped with its
# reason in why. With any fresh file the basis is beat: the worst fresh level
# wins, the first fresh file supplies memory, run queue, load and swap, every
# fresh file's disk rows count, and any fresh on_battery true counts. With no
# fresh file the basis is probe, and the level is warn when a cpu, memory, or
# disk probe constraint holds, else ok; with no probe at all it is none and
# the level unknown. Reading beats needs jq; without jq every beat is skipped.
# A fresh beat missing load, memory, or disk rows leaves max-load1,
# min-avail-gb, and min-disk-gb judged on this host's own probes.
#
# Probes degrade gracefully: an unavailable probe prints unknown and its
# constraint is not evaluated. Darwin reads sysctl (vm.loadavg,
# kern.memorystatus_level, hw.logicalcpu, hw.memsize, kern.boottime); other
# systems read /proc/loadavg, /proc/meminfo (MemAvailable/MemTotal),
# /proc/uptime, /proc/stat btime and /proc/sys/kernel/random/boot_id; cores
# come from getconf with a sysctl fallback; disk comes from df -Pk.
#
# --json prints one fm-lane-capacity.v1 object (needs jq):
#   schema, generated_epoch (this host's clock), home ("main", or the id in
#   .fm-secondmate-home), machine (the first readable beat's host, else the
#   short host name),
#   lanes {count, pr_ready (records with a pr= line), ids},
#   cap {target (number or null), status ok|none|invalid},
#   projects (clone directory names under projects/),
#   pressure {level ok|warn|critical|unknown, why[], basis beat|probe|none,
#     beat_age_s, avail_gb, total_gb, runq_per_core (probe basis: load1 over
#     cores), swap_rate_pps_1m, mem_stall_pct, load1, on_battery,
#     disks[{label, free_gb}]},
#   uptime_s, boot_id, boots[] (boot epochs, last 10: the current boot is
#     appended when boot_id differs from the previously published document's),
#   watcher_beat_age_s (age of state/.last-watcher-beat, null when absent),
#   reserve {flag not-configured|absent|present, label},
#   captain not-configured|present|idle|away|unknown (captain-idle: away while
#     an away record exists, else macOS HID idle time under the threshold is
#     present and at or over it idle; anything unreadable is unknown),
#   quota null | {provider, runway} (the all_models runway status from
#     quota-axi --json --provider <p> --max-age 15m, bounded to 5 s; unknown
#     when it cannot be read),
#   limits {min_avail_gb, min_disk_gb, max_load1} (null when unset),
#   verdict {admit, free_lanes, reasons[]}.
# verdict.admit is true only with a valid cap, lanes under it, and no
# constraint, or in auto mode as below; its reasons are the constraints in words. The document carries
# labels and derived states only, never paths, addresses, commands, or tokens:
# a beat's own why and error text is published as counts (pressure_why=N,
# beat_errors=N), and an invalid config line by its line number and a fixed
# reason. --json and --publish print the full detail on stderr.
#
# --publish writes the document atomically (mode 0600) when config/lane-capacity
# exists, skipping when state/lane-capacity.json is younger than
# FM_LANE_CAPACITY_PUBLISH_INTERVAL seconds (default 30; 0 always publishes).
# A malformed config is still published with cap.status invalid. It is
# best-effort: every failure goes to stderr and it exits 0.
#
# --admit exits 0 when config/lane-capacity is absent or the verdict admits,
# and 75 with one `deferred:` line on stderr when it does not. --spawn-gate
# exits 0 at once unless the file declares admit-spawns (an invalid file exits
# 1 only when one of its lines names admit-spawns), and is otherwise --admit;
# bin/fm-spawn.sh owns where it runs.
#
# Auto mode. A first line of `auto` replaces the fixed cap with a lane budget
# measured on every call; an integer first line keeps everything above exactly.
# Auto-only keys: max-lanes N (an optional ceiling, published as cap.target),
# lane-footprint-gb X and lane-disk-gb X (pin the per-lane costs, at least
# 0.1), host-min-avail-gb X (WSL), min-gpu-free-gb X (count the GPU). Keys for
# both modes: allow-battery (never close for battery) and admit-spawns (the
# spawn gate). Auto mode needs jq; without it nothing is admitted.
#   Lanes: this home's records, plus the records of every other local home on
#   this machine (fm_local_firstmate_state_dirs) for young lanes and the
#   ceiling; an unreadable walk counts this home only and says so in notes.
#   A lane is young for 180 s after its spawn_gen time and reserves one full
#   per-lane cost, because its footprint is not yet visible to the probes.
#   Footprint: --publish samples every lane of this home through
#   bin/fm-lane-vitals-lib.sh (processes attributed by worktree cwd, memory,
#   CPU-time deltas) and one worktree's du per call, into
#   state/lane-footprint.json (fm-lane-footprint.v1: per-lane samples, and the
#   last 30 lanes that left state/). The per-lane cost is the p90 of those 30
#   lanes' peak memory, mean CPU cores, and disk, once 5 are recorded, never
#   under 0.5 GB, 0.25 core, 0.5 GB; before that 2 GB, 1 core, 3 GB.
#   When no process working directory can be read at all (lsof timed out on a
#   loaded host), every lane keeps its last sample and notes say so, so an
#   unreadable table never looks like lanes with no agent.
#   Budget: open = the smallest of
#     memory  floor((available - kept - young x F_mem) / F_mem), where kept is
#             min-avail-gb, else the larger of 10% of RAM and 2 GB
#     cpu     floor((cores x 0.85 - max(load1, load5) - young x F_cpu) / F_cpu);
#             inside WSL the load is at least the Windows host CPU share
#     disk    per filesystem (the home's, then each one holding a worktree),
#             floor((free - kept - young x F_disk) / F_disk), kept min-disk-gb
#             else 10 GB
#     ceiling max-lanes minus this machine's lanes
#   never below 0. With neither a memory nor a cpu probe the budget is the
#   ceiling alone, or 0 without one. Free lanes grow by at most 2 over the
#   previously published verdict.
#   Gates close admission at once and reopen only after their reopen test holds
#   on 3 consecutive publishes; an unmeasurable gate is unknown and not judged:
#     cpu             load1/cores >= 1; reopens < 0.8 with load5/cores < 0.85
#     load            load1 >= max-load1; reopens < 0.9 x max-load1
#     memory-pressure Linux PSI memory some avg10 >= 10 or full avg10 >= 5,
#                     reopens some avg60 < 5 and full avg10 < 1; macOS vm
#                     pressure level >= 2, reopens at 1
#     swap            swap-in >= 100 pages/s since the last publish; reopens < 10
#     io              Linux PSI io full avg10 >= 20; reopens avg60 < 10
#     host-memory     WSL: Windows available < host-min-avail-gb (default the
#                     larger of 10% of host RAM and 2 GB) or commit >= 95%;
#                     reopens 1 GB above it and under 90%
#     thermal         macOS CPU speed limit under 100 or a recorded warning
#     battery         on battery (unless allow-battery)
#     gpu             with min-gpu-free-gb: the least free GPU memory under it
#   In auto mode these gates replace the fixed-mode cpu, load, and battery
#   constraints and the budget replaces the memory and disk constraints, so
#   each signal is judged once; pressure and reserve constraints still apply.
#   Reclaim: a ranked recommendation of this home's idle lanes, never an
#   action: finished (last status done/failed over 10 min ago, idle 10 min),
#   no-agent (under 16 MB attributed for 10 min), handed-off (pr= recorded, CPU
#   under 2% of a core for 30 min), parked (paused with an until over 2 h away,
#   or no until for 2 h, idle 30 min), quiet (no status event for 60 min, idle
#   30 min); ranked in that order, then by memory held, then idle time.
#   The document adds cap.mode "auto", budget {lanes, open, raw,
#   machine_lanes, by {memory, cpu, disk, ceiling}, binding, young, damped,
#   notes[]}, footprint {mem_gb, cpu_cores, disk_gb, source
#   default|learned|pinned, samples}, vitals {load5, psi {cpu_some10,
#   mem_some10, mem_some60, mem_full10, io_full10, io_full60}, swapin_total,
#   swap_in_pps, vm_pressure_level, thermal, battery_pct, on_ac, wsl
#   {avail_gb, total_gb, commit_pct, cpu_pct, age_s} | null, gpu [{name,
#   util_pct, mem_used_gb, mem_total_gb}]}, gates [{name, state
#   open|closed|unknown, since_epoch, clear_count}], and reclaim [{id, class,
#   idle_s, mem_gb, cpu_pct, evidence[], next cleanup|recover|retire-pane|
#   review}]. The report line appends mode=auto budget=<lanes>, and reason
#   names the closed gates, the binding resource when nothing is open, or ok.
#   GPU never counts unless min-gpu-free-gb is set: agent workers do not use it.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_PROJECTS_OVERRIDE resolve the home exactly as the other bin/ scripts do.
# FM_PROC_ROOT_OVERRIDE replaces /proc for every Linux read (tests), and
# FM_LANE_VITALS_HOST_MAX_AGE (default 120 s) bounds the cached Windows host view.
#
# Exit status: 0 on a report, 1 on an invalid config/lane-capacity (report,
# --json, --admit), 2 on a usage error or --json without jq, 75 on an --admit
# deferral.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LANE_CONFIG="$CONFIG/lane-capacity"
PUBLISHED="$STATE/lane-capacity.json"
PROC_ROOT=${FM_PROC_ROOT_OVERRIDE:-/proc}

MEM_FREE_MIN_PCT=10
DISK_FREE_MIN_MB=5120
LANE_FOOTPRINT_GB=1
QUOTA_TIMEOUT=5
BOOTS_KEPT=10
GATE_REOPEN_SAMPLES=3

mode=report
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  --json) mode=json ;;
  --publish) mode=publish ;;
  --admit) mode=admit ;;
  --spawn-gate) mode=spawn_gate ;;
  --spawn-gate-enabled) mode=spawn_gate_enabled ;;
  *) echo "usage: fm-capacity.sh [--json|--publish|--admit|--spawn-gate|--spawn-gate-enabled|--help]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: fm-capacity.sh [--json|--publish|--admit|--spawn-gate|--spawn-gate-enabled|--help]" >&2; exit 2; }

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

is_num() {  # non-negative decimal
  case "$1" in ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;; esac
}

num_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a < b)}'; }

file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=
  is_uint "$m" || m=$(/usr/bin/stat -f %m "$1" 2>/dev/null) || m=
  is_uint "$m" && printf '%s\n' "$m"
}

now=$(date +%s)

case "$mode" in
  admit|publish|spawn_gate) [ -e "$LANE_CONFIG" ] || exit 0 ;;
  spawn_gate_enabled) [ -e "$LANE_CONFIG" ] || exit 1 ;;
esac
if [ "$mode" = publish ]; then
  interval=${FM_LANE_CAPACITY_PUBLISH_INTERVAL:-30}
  is_uint "$interval" || interval=30
  if [ "$interval" -gt 0 ] && m=$(file_mtime "$PUBLISHED") && [ $((now - m)) -lt "$interval" ] && [ "$m" -le "$now" ]; then
    exit 0
  fi
fi
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1
if [ "$have_jq" -eq 0 ]; then
  case "$mode" in
    json) echo "fm-capacity: --json needs jq" >&2; exit 2 ;;
    publish) echo "fm-capacity: --publish needs jq; nothing published" >&2; exit 0 ;;
  esac
fi

# --- lanes ------------------------------------------------------------------
lanes=0
secondmates=0
pr_ready=0
lane_ids=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  if grep -qx 'kind=secondmate' "$meta" 2>/dev/null; then
    secondmates=$((secondmates + 1))
  else
    lanes=$((lanes + 1))
    lane_ids="$lane_ids$(basename "$meta" .meta)
"
    grep -q '^pr=..*' "$meta" 2>/dev/null && pr_ready=$((pr_ready + 1))
  fi
done

# --- config/lane-capacity ---------------------------------------------------
target=none
target_error=
cap_mode=fixed
min_avail_gb=
min_disk_gb=
max_load1=
max_lanes=
lane_footprint_gb=
lane_disk_gb=
host_min_avail_gb=
min_gpu_free_gb=
allow_battery=0
admit_spawns=0
captain_idle=
quota_provider=
pressure_files=
reserve_flags=
expand_path() {
  case "$1" in
    \~/*) printf '%s\n' "${HOME:-}/${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}
target_reason=
config_error() {  # <lineno|-> <published reason> [stderr-only detail]
  if [ "$1" = - ]; then target_reason=$2; else target_reason="line $1: $2"; fi
  target_error="$target_reason${3:+ $3}"
}
parse_lane_config() {
  local line lineno=0 key value rest path seen=
  target=
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//')
    [ -n "$line" ] || continue
    if [ -z "$target" ]; then
      if [ "$line" = auto ]; then
        cap_mode=auto target=none
        continue
      fi
      is_uint "$line" && [ "${#line}" -le 9 ] || { config_error "$lineno" "the first line must be the lane cap, one non-negative integer, or auto"; return 1; }
      target=$((10#$line))
      continue
    fi
    key=${line%% *}
    rest=
    [ "$key" = "$line" ] || rest=$(printf '%s' "${line#* }" | sed 's/^ *//')
    value=${rest%% *}
    case "$key" in
      min-avail-gb|min-disk-gb|max-load1|captain-idle|quota-provider|pressure-file|reserve-flag) ;;
      allow-battery|admit-spawns) ;;
      max-lanes|lane-footprint-gb|lane-disk-gb|host-min-avail-gb|min-gpu-free-gb)
        [ "$cap_mode" = auto ] || { config_error "$lineno" "$key needs auto on the first line"; return 1; }
        ;;
      *) config_error "$lineno" "unknown key" "'$key'"; return 1 ;;
    esac
    case "$key" in
      pressure-file|reserve-flag) ;;
      *)
        case " $seen " in *" $key "*) config_error "$lineno" "$key appears more than once"; return 1 ;; esac
        seen="$seen $key"
        case "$key" in
          allow-battery|admit-spawns) [ -z "$rest" ] || { config_error "$lineno" "$key takes no value"; return 1; } ;;
          *) [ "$value" = "$rest" ] || { config_error "$lineno" "$key takes one value"; return 1 ;} ;;
        esac
        ;;
    esac
    case "$key" in
      min-avail-gb|min-disk-gb|max-load1|host-min-avail-gb|min-gpu-free-gb)
        is_num "$value" || { config_error "$lineno" "$key needs a non-negative number"; return 1; }
        case "$key" in
          min-avail-gb) min_avail_gb=$value ;;
          min-disk-gb) min_disk_gb=$value ;;
          max-load1) max_load1=$value ;;
          host-min-avail-gb) host_min_avail_gb=$value ;;
          min-gpu-free-gb) min_gpu_free_gb=$value ;;
        esac
        ;;
      lane-footprint-gb|lane-disk-gb)
        if ! is_num "$value" || num_lt "$value" 0.1; then
          config_error "$lineno" "$key needs a number of at least 0.1"
          return 1
        fi
        case "$key" in
          lane-footprint-gb) lane_footprint_gb=$value ;;
          lane-disk-gb) lane_disk_gb=$value ;;
        esac
        ;;
      max-lanes)
        is_uint "$value" && [ "${#value}" -le 9 ] || { config_error "$lineno" "max-lanes needs one non-negative integer"; return 1; }
        max_lanes=$((10#$value))
        target=$max_lanes
        ;;
      allow-battery) allow_battery=1 ;;
      admit-spawns) admit_spawns=1 ;;
      captain-idle)
        is_uint "$value" && [ "${#value}" -le 9 ] && [ "$((10#$value))" -gt 0 ] || { config_error "$lineno" "captain-idle needs a positive number of seconds"; return 1; }
        captain_idle=$((10#$value))
        ;;
      quota-provider)
        case "$value" in ''|*[!a-z0-9-]*) config_error "$lineno" "quota-provider needs one provider name"; return 1 ;; esac
        quota_provider=$value
        ;;
      pressure-file)
        [ -n "$value" ] && [ "$value" = "$rest" ] || { config_error "$lineno" "pressure-file takes one absolute path"; return 1; }
        path=$(expand_path "$value") || { config_error "$lineno" "pressure-file takes one absolute path"; return 1; }
        pressure_files="$pressure_files$path
"
        ;;
      reserve-flag)
        path=$(expand_path "$value") || { config_error "$lineno" "reserve-flag needs an absolute path"; return 1; }
        rest=$(printf '%s' "${rest#"$value"}" | sed 's/^ *//')
        reserve_flags="$reserve_flags$path	${rest:-reserved}
"
        ;;
    esac
  done < "$LANE_CONFIG"
  [ -n "$target" ] || { config_error - "no lane cap: the first line must be one non-negative integer"; return 1; }
}
if [ -e "$LANE_CONFIG" ]; then
  if [ ! -r "$LANE_CONFIG" ] || ! parse_lane_config; then
    [ -n "$target_error" ] || config_error - "unreadable"
    target_error="config/lane-capacity: $target_error"
    target_reason="config/lane-capacity: $target_reason"
    target=invalid
    min_avail_gb='' min_disk_gb='' max_load1='' captain_idle='' quota_provider='' pressure_files='' reserve_flags=''
    cap_mode=fixed max_lanes='' lane_footprint_gb='' lane_disk_gb='' host_min_avail_gb='' min_gpu_free_gb='' allow_battery=0
  fi
fi
# --spawn-gate is --admit for bin/fm-spawn.sh, and only when the file opts in;
# an invalid file refuses only when one of its lines asks for the gate.
if [ "$mode" = spawn_gate ] || [ "$mode" = spawn_gate_enabled ]; then
  gate_enabled=0
  if [ "$target" = invalid ]; then
    grep -Eq '^[[:space:]]*admit-spawns([[:space:]#]|$)' "$LANE_CONFIG" 2>/dev/null && gate_enabled=1
  else
    [ "$admit_spawns" -eq 0 ] || gate_enabled=1
  fi
  if [ "$mode" = spawn_gate_enabled ]; then
    [ "$gate_enabled" -eq 1 ] && exit 0
    exit 1
  fi
  [ "$gate_enabled" -eq 1 ] || exit 0
  mode=admit
fi

# --- host probes ------------------------------------------------------------
os=$(uname -s 2>/dev/null) || os=unknown

load1=unknown
if [ "$os" = Darwin ]; then
  v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
else
  v=$(awk '{print $1}' "$PROC_ROOT/loadavg" 2>/dev/null)
fi
case "$v" in [0-9]*) load1=$v ;; esac

cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=
is_uint "$cores" || cores=$(sysctl -n hw.logicalcpu 2>/dev/null) || cores=
is_uint "$cores" && [ "$cores" -gt 0 ] || cores=unknown

mem_free_pct=unknown
probe_avail_gb=
probe_total_gb=
if [ "$os" = Darwin ]; then
  v=$(sysctl -n kern.memorystatus_level 2>/dev/null)
  is_uint "$v" && mem_free_pct=$v
  v=$(sysctl -n hw.memsize 2>/dev/null)
  if is_uint "$v" && [ "$mem_free_pct" != unknown ]; then
    probe_total_gb=$(awk -v b="$v" 'BEGIN{printf "%.2f", b / 1073741824}')
    probe_avail_gb=$(awk -v b="$v" -v p="$mem_free_pct" 'BEGIN{printf "%.2f", b * p / 100 / 1073741824}')
  fi
else
  v=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t > 0 && a != "") printf "%d %.2f %.2f", a * 100 / t, a / 1048576, t / 1048576}' "$PROC_ROOT/meminfo" 2>/dev/null)
  if [ -n "$v" ]; then
    # shellcheck disable=SC2086
    set -- $v
    mem_free_pct=$1 probe_avail_gb=$2 probe_total_gb=$3
  fi
fi

disk_free_mb=unknown
v=$(df -Pk "$FM_HOME" 2>/dev/null | awk 'NR==2{print int($4 / 1024)}')
is_uint "$v" && disk_free_mb=$v
probe_disks=
[ "$disk_free_mb" = unknown ] || probe_disks="home	$(awk -v m="$disk_free_mb" 'BEGIN{printf "%.1f", m / 1024}')
"

# --- pressure ---------------------------------------------------------------
level_rank() {
  case "$1" in ok) echo 0 ;; warn) echo 1 ;; critical) echo 2 ;; *) echo -1 ;; esac
}
why=
pub_why=
pressure_why=
add_why() {  # <detail> [published text, default the detail; empty publishes nothing]
  why="$why$1
"
  pub_why="$pub_why${2-$1}
"
}
basis=none
level=unknown
beat_age_s=
avail_gb='' total_gb='' runq_per_core='' swap_rate='' mem_stall='' p_load1='' on_battery=''
disks=
first_host=
nfiles=$(printf '%s' "$pressure_files" | grep -c . 2>/dev/null) || nfiles=0
idx=0
worst=-1
while IFS= read -r pfile; do
  [ -n "$pfile" ] || continue
  idx=$((idx + 1))
  label="pressure-file $idx"
  if [ ! -e "$pfile" ]; then
    add_why "$label: beat absent"; continue
  fi
  if [ "$have_jq" -eq 0 ]; then
    add_why "$label: beat unreadable (jq missing)"; continue
  fi
  parsed=$(jq -r '
    def s: tostring | gsub("[\t\n\r\u001f]"; " ");
    def n: if type == "number" then tostring else "" end;
    if type == "object" and .schema == "lookout.beat"
       and ((.schema_version // "") | tostring | startswith("1."))
       and (.machine | type) == "object" then
      ([ "beat",
         ((.host // .machine.id // "") | s),
         (.interval_s | n),
         ((.machine.pressure.level // "") | s),
         (.machine.mem.avail_gb | n), (.machine.mem.total_gb | n),
         (.machine.load.runq_per_core | n), (.machine.mem.swap_rate_pps_1m | n),
         (.machine.mem.psi_some10 | n), (.machine.load.l1 | n),
         (if .machine.on_battery == true then "true" elif .machine.on_battery == false then "false" else "" end)
       ] | join("\u001f")),
      ((.machine.pressure.why // [])[] | "why\u001f" + s),
      ((.machine.beat.errors // [])[] | "error\u001f" + s),
      ((.machine.disks // [])[] | select(type == "object") | "disk\u001f" + ((.label // "disk") | s) + "\u001f" + (.free_gb | n))
    else "foreign" end' "$pfile" 2>/dev/null) || parsed=
  case "$parsed" in
    beat*) ;;
    foreign*) add_why "$label: not a lookout.beat 1.x document"; continue ;;
    *) add_why "$label: beat unreadable"; continue ;;
  esac
  IFS=$'\x1f' read -r _ host interval blevel b_avail b_total b_runq b_swap b_stall b_l1 b_batt <<EOF
$(printf '%s\n' "$parsed" | head -1)
EOF
  case "$host" in *[!A-Za-z0-9._-]*) host= ;; esac
  [ -z "$host" ] || label=$host
  [ -n "$first_host" ] || first_host=$host
  is_num "$interval" && ! num_lt "$interval" 1 || interval=15
  m=$(file_mtime "$pfile") || m=$now
  age=$((now - m)); [ "$age" -ge 0 ] || age=0
  if ! num_lt "$((age))" "$(awk -v i="$interval" 'BEGIN{print 4 * i + 0.001}')"; then
    add_why "$label: beat $age s old"; continue
  fi
  rank=$(level_rank "$blevel")
  if [ "$rank" -lt 0 ]; then
    add_why "$label: beat has no pressure level"; continue
  fi
  num_lt "$age" "$(awk -v i="$interval" 'BEGIN{print 2 * i + 0.001}')" || add_why "$label: beat $age s old"
  prefix=
  [ "$nfiles" -le 1 ] || prefix="$label: "
  errs=
  nerrs=0
  nwhy=0
  while IFS=$'\x1f' read -r kind a b; do
    case "$kind" in
      why)
        add_why "$prefix$a" ""
        pressure_why="${pressure_why:+$pressure_why; }$prefix$a"
        nwhy=$((nwhy + 1))
        ;;
      error) errs="${errs:+$errs; }$a"; nerrs=$((nerrs + 1)) ;;
      disk) disks="$disks${prefix:+$label }$a	$b
" ;;
    esac
  done <<EOF
$(printf '%s\n' "$parsed" | sed 1d)
EOF
  [ "$nwhy" -eq 0 ] || pub_why="$pub_why${prefix}pressure_why=$nwhy
"
  [ -z "$errs" ] || add_why "${prefix}beat errors: $errs" "${prefix}beat_errors=$nerrs"
  [ "$b_batt" != true ] || on_battery=true
  [ "$rank" -le "$worst" ] || worst=$rank
  if [ "$basis" != beat ]; then
    basis=beat beat_age_s=$age
    avail_gb=$b_avail total_gb=$b_total runq_per_core=$b_runq swap_rate=$b_swap
    mem_stall=$b_stall p_load1=$b_l1
    [ "$b_batt" != false ] || [ -n "$on_battery" ] || on_battery=false
  fi
done <<EOF
$pressure_files
EOF

probe_cpu=0 probe_mem=0 probe_disk=0
if [ "$load1" != unknown ] && [ "$cores" != unknown ] &&
  awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l >= c)}'; then
  probe_cpu=1
fi
[ "$mem_free_pct" != unknown ] && [ "$mem_free_pct" -lt "$MEM_FREE_MIN_PCT" ] && probe_mem=1
[ "$disk_free_mb" != unknown ] && [ "$disk_free_mb" -lt "$DISK_FREE_MIN_MB" ] && probe_disk=1

if [ "$basis" = beat ]; then
  case "$worst" in 0) level=ok ;; 1) level=warn ;; 2) level=critical ;; esac
elif [ "$load1" != unknown ] || [ "$mem_free_pct" != unknown ] || [ "$disk_free_mb" != unknown ]; then
  basis=probe level=ok
  [ "$load1" = unknown ] || p_load1=$load1
  avail_gb=$probe_avail_gb total_gb=$probe_total_gb
  if [ "$load1" != unknown ] && [ "$cores" != unknown ]; then
    runq_per_core=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.2f", l / c}')
  fi
  disks=$probe_disks
  [ "$probe_cpu" -eq 0 ] || { level=warn; add_why "load $load1 on $cores cores"; }
  [ "$probe_mem" -eq 0 ] || { level=warn; add_why "memory $mem_free_pct% free"; }
  [ "$probe_disk" -eq 0 ] || { level=warn; add_why "disk $disk_free_mb MB free"; }
fi

# --- reserve ----------------------------------------------------------------
reserve_flag=not-configured
reserve_label=
while IFS='	' read -r rpath rlabel; do
  [ -n "$rpath" ] || continue
  [ "$reserve_flag" = present ] && continue
  reserve_flag=absent
  if [ -e "$rpath" ]; then
    reserve_flag=present reserve_label=$rlabel
  fi
done <<EOF
$reserve_flags
EOF

# --- auto budget --------------------------------------------------------------
# Auto mode (first line `auto`): the lane budget is computed from measured
# headroom and a learned per-lane footprint instead of a fixed cap. The header
# owns every rule; AUTO_JQ below is the one place they are computed.
LANE_LEDGER="$STATE/lane-footprint.json"
HOST_CACHE="$STATE/.lane-vitals-host"
HOST_CACHE_MAX_AGE=${FM_LANE_VITALS_HOST_MAX_AGE:-120}
is_uint "$HOST_CACHE_MAX_AGE" || HOST_CACHE_MAX_AGE=120
DU_TIMEOUT=3
YOUNG_S=180

# Strip the characters the lane table uses as separators.
tsv_field() { printf '%s' "$1" | tr '\t\n\r' '   '; }

# auto_lane_rows <home-index> <state-dir>: one lane-table row per task record.
auto_lane_rows() {
  local idx=$1 dir=$2 meta id wt harness kind pr spawn line verb at until sf
  for meta in "$dir"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null && continue
    id=$(basename "$meta" .meta)
    wt=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -1)
    harness=$(sed -n 's/^harness=//p' "$meta" 2>/dev/null | head -1)
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -1)
    pr=0
    grep -q '^pr=..*' "$meta" 2>/dev/null && pr=1
    spawn=$(sed -n 's/^spawn_gen=s\([0-9][0-9]*\)\..*/\1/p' "$meta" 2>/dev/null | head -1)
    is_uint "$spawn" || spawn=$(file_mtime "$meta") || spawn=
    verb='' at='' until=''
    sf="$dir/$id.status"
    if [ "$idx" -eq 0 ] && [ -f "$sf" ]; then
      line=$(last_status_line "$sf" 2>/dev/null) || line=
      if [ -n "$line" ]; then
        verb=$(status_line_verb "$line" 2>/dev/null) || verb=
        case "$verb" in *[!a-z-]*) verb= ;; esac
        at=$(status_line_at_epoch "$line" 2>/dev/null) || at=$(file_mtime "$sf") || at=
        until=$(status_paused_until "$line" 2>/dev/null) || until=
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$(tsv_field "$id")" "$(tsv_field "$wt")" \
      "$(tsv_field "$harness")" "$(tsv_field "$kind")" "$pr" "$spawn" "$verb" "$at" "$until"
  done
}

# auto_host_view: print "avail total commit cpu age" for the Windows host, from
# the cache when fresh, else one live query (cached only by --publish).
auto_host_view() {
  local line epoch rest age
  if [ -f "$HOST_CACHE" ] && IFS= read -r line < "$HOST_CACHE" 2>/dev/null; then
    epoch=${line%% *} rest=${line#* }
    if is_uint "$epoch" && [ "$epoch" -le "$now" ] && [ $((now - epoch)) -le "$HOST_CACHE_MAX_AGE" ]; then
      printf '%s %s\n' "$rest" $((now - epoch))
      return 0
    fi
  fi
  line=$(fm_lane_vitals_wsl_host) || return 1
  if [ "$mode" = publish ] && [ -d "$STATE" ]; then
    if ! { printf '%s %s\n' "$now" "$line" > "$HOST_CACHE.$$" && mv -f "$HOST_CACHE.$$" "$HOST_CACHE"; } 2>/dev/null; then
      rm -f "$HOST_CACHE.$$"
    fi
  fi
  printf '%s 0\n' "$line"
}

# shellcheck disable=SC2016 # a jq program: its $names are jq variables.
AUTO_JQ='
def num: if . == null or . == "" then null else (tonumber? // null) end;
def rows: split("\n") | map(select(. != "") | split("\t"));
def r2: (. * 100 + 0.5 | floor) / 100;
def n2: if . == null then null else r2 end;
def p90: sort | .[((length * 9 + 9) / 10 | floor) - 1];
def nn: map(select(. != null));
def dur: if . == null then "?" elif . >= 86400 then "\(. / 86400 | floor)d" elif . >= 3600 then "\(. / 3600 | floor)h"
  elif . >= 60 then "\(. / 60 | floor)m" else "\(. | floor)s" end;
($lanes_tsv | rows | map({home: (.[0] | tonumber), id: .[1], key: "\(.[0]):\(.[1])", harness: (.[3] // ""),
  kind: (.[4] // ""), pr: (.[5] == "1"), spawn: (.[6] | num), verb: (.[7] // ""), at: (.[8] | num), until: (.[9] | num)})) as $lanes
| ($attr_tsv | rows | map({key: .[0], pid: .[1], mem_kb: ((.[2] | num) // 0), cpu_s: ((.[3] | num) // 0)})) as $attr
| ($disks_tsv | rows | map({label: .[0], free_gb: (.[1] | num)}) | map(select(.free_gb != null))) as $disks
| ($gpu_tsv | rows | map({name: .[0], util_pct: (.[1] | num), mem_used_gb: (.[2] | num), mem_total_gb: (.[3] | num)})) as $gpu
| ($host_tsv | split(" ") | map(select(. != ""))) as $hv
| (if ($hv | length) == 5 then {avail_gb: ($hv[0] | num | n2), total_gb: ($hv[1] | num | n2), commit_pct: ($hv[2] | num | n2),
    cpu_pct: ($hv[3] | num | n2), age_s: ($hv[4] | num | n2)} else null end) as $h
| (if ($prev_ledger | type) == "object" and $prev_ledger.schema == "fm-lane-footprint.v1" then $prev_ledger
   else {lanes: {}, history: []} end) as $pl
| (if ($prev_doc | type) == "object" and (($prev_doc.cap.mode // "") == "auto")
     and (($now - ($prev_doc.generated_epoch // 0)) | . >= 0 and . <= 300) then $prev_doc else null end) as $pd
| [ $lanes[] | select(.home == 0) ] as $own
| ($own | map(. as $l
    | [ $attr[] | select(.key == $l.key) ] as $procs
    | (($pl.lanes // {})[$l.id] // null) as $p
    | (($procs | map(.mem_kb) | add // 0) / 1048576) as $mem
    | (if $p != null then $now - ($p.last_seen // $now) else null end) as $dt
    | (if $p != null and $dt > 0 and $dt <= 600 then
         ([ $procs[] | ((($p.pids // {})[.pid]) // null) as $was
            | if $was != null and .cpu_s >= $was then .cpu_s - $was else ([.cpu_s, $dt] | min) end ] | add // 0) / $dt
       else null end) as $cpu
    | if ($attr_ok | not) then {key: $l.id, value: (($p // {first_seen: $now, last_seen: null, samples: 0, procs: null,
        mem_gb: null, peak_mem_gb: 0, mem_sum_gb: 0, cpu_cores: null, peak_cpu_cores: 0, cpu_sum: 0, cpu_n: 0,
        quiet_since: null, noagent_since: null, disk_gb: null, disk_epoch: null, pids: {}})
        + {harness: $l.harness, kind: $l.kind}
        + (if $disk_sample.id == $l.id then {disk_gb: $disk_sample.gb, disk_epoch: $now} else {} end))}
      else {key: $l.id, value: {harness: $l.harness, kind: $l.kind,
        first_seen: ($p.first_seen // $now), last_seen: $now, samples: (($p.samples // 0) + 1),
        procs: ($procs | length), mem_gb: ($mem | r2), peak_mem_gb: ([$mem, ($p.peak_mem_gb // 0)] | max | r2),
        mem_sum_gb: ((($p.mem_sum_gb // 0) + $mem) | r2),
        cpu_cores: (if $cpu == null then null else ($cpu | r2) end),
        peak_cpu_cores: ([($cpu // 0), ($p.peak_cpu_cores // 0)] | max | r2),
        cpu_sum: ((($p.cpu_sum // 0) + ($cpu // 0)) | r2), cpu_n: (($p.cpu_n // 0) + (if $cpu == null then 0 else 1 end)),
        quiet_since: (if $cpu == null then ($p.quiet_since // null)
          elif $cpu < 0.02 then ($p.quiet_since // ($p.last_seen // $now)) else null end),
        noagent_since: (if $mem < 0.016 then ($p.noagent_since // $now) else null end),
        disk_gb: (if $disk_sample.id == $l.id then $disk_sample.gb else ($p.disk_gb // null) end),
        disk_epoch: (if $disk_sample.id == $l.id then $now else ($p.disk_epoch // null) end),
        pids: ($procs | map({key: .pid, value: .cpu_s}) | from_entries)}} end) | from_entries) as $ll
| [ ($pl.lanes // {}) | to_entries[] | select(.key as $k | $ll | has($k) | not) | .value | select((.samples // 0) >= 2)
    | {harness, kind, peak_mem_gb, mean_mem_gb: ((.mem_sum_gb // 0) / .samples | r2),
       mean_cpu_cores: (if (.cpu_n // 0) > 0 then (.cpu_sum / .cpu_n | r2) else null end), disk_gb,
       lifetime_s: ((.last_seen // $now) - (.first_seen // $now)), ended_epoch: $now} ] as $ended
| ((($pl.history // []) + $ended) | .[-30:]) as $history
| ($history | map(.peak_mem_gb) | nn) as $hm
| ($history | map(.mean_cpu_cores) | nn) as $hc
| ($history | map(.disk_gb) | nn) as $hd
| {mem_gb: (if $cfg.lane_fp != null then $cfg.lane_fp elif ($hm | length) >= 5 then ([($hm | p90), 0.5] | max) else 2 end),
   cpu_cores: (if ($hc | length) >= 5 then ([($hc | p90), 0.25] | max) else 1 end),
   disk_gb: (if $cfg.lane_disk != null then $cfg.lane_disk elif ($hd | length) >= 5 then ([($hd | p90), 0.5] | max) else 3 end),
   source: (if $cfg.lane_fp != null then "pinned" elif ($hm | length) >= 5 then "learned" else "default" end),
   samples: ($hm | length)} as $fp
| ($lanes | length) as $mlanes
| ([ $lanes[] | select(.spawn != null and ($now - .spawn) >= 0 and ($now - .spawn) < $young_s) ] | length) as $young
| ($avail != null or ($load1 != null and $cores != null)) as $measurable
| (if $cfg.min_avail != null then $cfg.min_avail elif $total != null then ([$total * 0.10, 2] | max) else 2 end) as $min_avail
| (if $avail == null then null else (($avail - $min_avail - $young * $fp.mem_gb) / $fp.mem_gb | floor) end) as $mem_open
| ([$load1, $vit.load5] | nn | max) as $loadavg
| (if $vit.wsl and $h != null and $h.cpu_pct != null and $cores != null
   then ([$loadavg, ($h.cpu_pct / 100 * $cores)] | nn | max) else $loadavg end) as $cpu_load
| (if $cores == null or $cpu_load == null then null
   else (($cores * 0.85 - $cpu_load - $young * $fp.cpu_cores) / $fp.cpu_cores | floor) end) as $cpu_open
| ($cfg.min_disk // 10) as $min_disk
| ($disks | map(. + {open: ((.free_gb - $min_disk - $young * $fp.disk_gb) / $fp.disk_gb | floor)})) as $dopen
| (if ($dopen | length) == 0 then null else ($dopen | min_by(.open)) end) as $dbind
| (if $cfg.max_lanes != null then $cfg.max_lanes - $mlanes else null end) as $ceil_open
| {memory: $mem_open, cpu: $cpu_open, disk: $dbind.open, ceiling: $ceil_open} as $by
| (if $measurable then ($by | to_entries | map(select(.value != null)) | if length == 0 then null else min_by(.value) end)
   elif $ceil_open != null then {key: "ceiling", value: $ceil_open} else null end) as $bind
| (if $bind == null then 0 else ([$bind.value, 0] | max) end) as $raw
| ($pd.verdict.free_lanes // null) as $prev_free
| (if $prev_free != null and $raw > ($prev_free + 2) then $prev_free + 2 else $raw end) as $open
| (if $pd != null and $vit.swapin != null and $pd.vitals.swapin_total != null and $vit.swapin >= $pd.vitals.swapin_total
     and ($now - $pd.generated_epoch) > 0
   then (($vit.swapin - $pd.vitals.swapin_total) / ($now - $pd.generated_epoch) | r2) else null end) as $swap_rate
| (if $vit.on_ac != null then $vit.on_ac elif $beat_battery == true then false elif $beat_battery == false then true else null end) as $on_ac
| def gate($name; $close; $clear; $what):
    ((($pd.gates // []) | map(select(.name == $name)) | .[0]) // {}) as $g
    | if $close == null then {name: $name, state: "unknown", since_epoch: null, clear_count: 0, what: $what}
      elif $close then {name: $name, state: "closed", since_epoch: (if $g.state == "closed" then $g.since_epoch else $now end),
        clear_count: 0, what: $what}
      elif $g.state == "closed" then
        (if $clear then ($g.clear_count // 0) + 1 else 0 end) as $n
        | if $n >= $reopen then {name: $name, state: "open", since_epoch: $now, clear_count: 0, what: $what}
          else {name: $name, state: "closed", since_epoch: $g.since_epoch, clear_count: $n, what: $what} end
      else {name: $name, state: "open", since_epoch: ($g.since_epoch // null), clear_count: 0, what: $what} end;
  [ gate("cpu"; (if $load1 == null or $cores == null then null else ($load1 / $cores >= 1) end);
      ($load1 != null and $cores != null and ($load1 / $cores) < 0.8 and ($vit.load5 == null or ($vit.load5 / $cores) < 0.85));
      "load \($load1 | n2) on \($cores) cores"),
    (if $cfg.max_load1 == null then empty else
      gate("load"; (if $load1 == null then null else $load1 >= $cfg.max_load1 end);
        ($load1 != null and $load1 < 0.9 * $cfg.max_load1); "load \($load1 | n2), max-load1 \($cfg.max_load1)") end),
    (if $vit.psi_mem10 != null then
      gate("memory-pressure"; ($vit.psi_mem10 >= 10 or ($vit.psi_memfull10 // 0) >= 5);
        ((($vit.psi_mem60 // $vit.psi_mem10) < 5) and (($vit.psi_memfull10 // 0) < 1)); "memory stall \($vit.psi_mem10)%")
     elif $vit.vmpress != null then
      gate("memory-pressure"; ($vit.vmpress >= 2); ($vit.vmpress == 1); "vm pressure level \($vit.vmpress)")
     else empty end),
    (if $swap_rate == null then empty else gate("swap"; $swap_rate >= 100; $swap_rate < 10; "swap-in \($swap_rate) pages/s") end),
    (if $vit.psi_io10 == null then empty else
      gate("io"; $vit.psi_io10 >= 20; (($vit.psi_io60 // $vit.psi_io10) < 10); "io stall \($vit.psi_io10)%") end),
    (if $vit.wsl | not then empty elif $h == null or $h.avail_gb == null then gate("host-memory"; null; false; "Windows host unreadable")
     else (if $cfg.host_min != null then $cfg.host_min else ([(($h.total_gb // 0) * 0.10), 2] | max | r2) end) as $hmin
      | gate("host-memory"; ($h.avail_gb < $hmin or ($h.commit_pct // 0) >= 95);
          ($h.avail_gb >= $hmin + 1 and ($h.commit_pct // 0) < 90);
          "Windows host \($h.avail_gb | n2) GB available of \($h.total_gb | n2), \($h.commit_pct)% committed, \($hmin) GB kept") end),
    (if $vit.thermal == null then empty else gate("thermal"; $vit.thermal == "limited"; $vit.thermal == "ok"; "thermal \($vit.thermal)") end),
    (if $cfg.allow_battery or $on_ac == null then empty else
      gate("battery"; $on_ac == false; $on_ac == true;
        (if $on_ac then "on AC" else "on battery" + (if $vit.battery_pct != null then " at \($vit.battery_pct)%" else "" end) end)) end),
    (if $cfg.gpu_min == null then empty else
      ($gpu | map(select(.mem_total_gb != null and .mem_used_gb != null) | (.mem_total_gb - .mem_used_gb | r2)) | if length == 0 then null else min end) as $gf
      | gate("gpu"; (if $gf == null then null else $gf < $cfg.gpu_min end); ($gf != null and $gf >= $cfg.gpu_min + 1);
          "GPU \($gf // "unknown") GB free, \($cfg.gpu_min) GB kept") end)
  ] as $gates
| [ $gates[] | select(.state == "closed") ] as $closed
| ($closed | map("\(.name): \(.what)" + (if .clear_count > 0 then " (clearing \(.clear_count) of \($reopen))" else "" end))) as $gate_reasons
| (if ($closed | length) > 0 or $open > 0 then []
   elif $bind == null then ["vitals unmeasurable: no memory or cpu probe and no max-lanes ceiling"]
   else [ (if $measurable then "" else "vitals unmeasurable, ceiling only: " end) +
     (if $bind.key == "memory" then "memory: \($avail | n2) GB available, \($min_avail | r2) GB kept, \($young) starting, a lane needs \($fp.mem_gb) GB"
      elif $bind.key == "cpu" then "cpu: load \($cpu_load | n2) of \($cores * 0.85 | r2) usable on \($cores) cores, \($young) starting, a lane needs \($fp.cpu_cores) core"
      elif $bind.key == "disk" then "disk: \($dbind.label) \($dbind.free_gb | n2) GB free, \($min_disk) GB kept, \($young) starting, a lane needs \($fp.disk_gb) GB"
      else "ceiling: \($mlanes) of \($cfg.max_lanes) lanes on this machine (max-lanes)" end) ] end) as $budget_reasons
| (if ($closed | length) > 0 then ($closed | map(.name)) elif $open > 0 then ["ok"]
   elif $bind == null then ["unmeasurable"] else [$bind.key] end) as $names
| ($own | map(. as $l | $ll[$l.id] as $e
    | (if $e.quiet_since == null then 0 else $now - $e.quiet_since end) as $q
    | (if $e.noagent_since == null then 0 else $now - $e.noagent_since end) as $na
    | (if $l.at == null then null else $now - $l.at end) as $ev
    | (if ($l.verb == "done" or $l.verb == "failed") and ($ev // 0) >= 600 and ([$q, $na] | max) >= 600 then "finished"
       elif $na >= 600 then "no-agent"
       elif $l.pr and $q >= 1800 then "handed-off"
       elif $l.verb == "paused" and $q >= 1800 and (($l.until != null and ($l.until - $now) > 7200)
         or ($l.until == null and ($ev // 0) >= 7200)) then "parked"
       elif (($ev // (if $l.spawn != null then $now - $l.spawn else 0 end)) >= 3600) and $q >= 1800 then "quiet"
       else null end) as $cls
    | select($cls != null)
    | {id: $l.id, class: $cls, idle_s: ([$q, $na] | max), mem_gb: $e.mem_gb,
       cpu_pct: (if $e.cpu_cores == null then null else ($e.cpu_cores * 100 | r2) end),
       evidence: [ (if $l.verb != "" then "status:\($l.verb) \($ev | dur)" else empty end), "procs:\($e.procs // "?")",
         (if $l.pr then "pr:recorded" else empty end),
         (if $na > 0 then "no agent for \($na | dur)" elif $q > 0 then "cpu<2% for \($q | dur)" else empty end),
         (if $l.until != null then "until:" + (($l.until - $now) | if . < 0 then "passed" else "+" + (. | dur) end) else empty end) ],
       next: ({finished: "cleanup", "no-agent": "recover", "handed-off": "retire-pane", parked: "review", quiet: "review"}[$cls])})
  | sort_by(({finished: 0, "no-agent": 1, "handed-off": 2, parked: 3, quiet: 4}[.class]), -(.mem_gb // 0), -.idle_s)) as $reclaim
| {ledger: {schema: "fm-lane-footprint.v1", generated_epoch: $now, lanes: $ll, history: $history},
   admit: (($closed | length) == 0 and $open > 0),
   free_lanes: (if ($closed | length) == 0 then $open else 0 end),
   names: $names, reasons: ($gate_reasons + $budget_reasons),
   doc: {budget: {lanes: ($mlanes + $open), open: $open, raw: $raw, machine_lanes: $mlanes, by: $by,
           binding: (if ($closed | length) > 0 then "gate" elif $bind == null then "unmeasurable" else $bind.key end),
           young: $young, damped: ($open < $raw), notes: ($notes | split("\n") | map(select(. != "")))},
         footprint: $fp,
         vitals: {load5: $vit.load5, psi: {cpu_some10: $vit.psi_cpu10, mem_some10: $vit.psi_mem10, mem_some60: $vit.psi_mem60,
             mem_full10: $vit.psi_memfull10, io_full10: $vit.psi_io10, io_full60: $vit.psi_io60},
           swapin_total: $vit.swapin, swap_in_pps: $swap_rate, vm_pressure_level: $vit.vmpress, thermal: $vit.thermal,
           battery_pct: $vit.battery_pct, on_ac: $on_ac,
           wsl: (if $vit.wsl then ($h // {avail_gb: null, total_gb: null, commit_pct: null, cpu_pct: null, age_s: null}) else null end),
           gpu: $gpu},
         gates: ($gates | map(del(.what))),
         reclaim: $reclaim}}'

auto_notes=
auto_ledger=
auto_budget() {
  local attr_ok tmp lstate i n_states have_states=0 v cfg vit prev_ledger prev_doc out disk_sample host lab mount free seen_mounts
  if [ "$have_jq" -eq 0 ]; then
    free_lanes=0 reason=auto-needs-jq
    reasons="${reasons}auto: needs jq to read the lane footprint ledger
"
    pub_reasons="${pub_reasons}auto: needs jq to read the lane footprint ledger
"
    return 0
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-lane-vitals-lib.sh
  . "$SCRIPT_DIR/fm-lane-vitals-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  fm_lane_vitals_probe "$os"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-capacity.XXXXXX") || tmp=
  if [ -z "$tmp" ]; then
    free_lanes=0 reason=auto-unavailable
    reasons="${reasons}auto: cannot create a temporary directory
"
    pub_reasons="${pub_reasons}auto: cannot create a temporary directory
"
    return 0
  fi

  # Lanes: this home first, then every other local home on this machine.
  auto_lane_rows 0 "$STATE" > "$tmp/lanes"
  if [ -d "$STATE" ]; then
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    if fm_local_firstmate_state_dirs "$STATE" 2>/dev/null; then
      have_states=1
    else
      auto_notes="${auto_notes}other local homes not counted
"
      printf 'fm-capacity: auto: other local homes not counted: %s\n' "${FM_LOCAL_FIRSTMATE_ERROR:-unreadable}" >&2
    fi
  fi
  if [ "$have_states" -eq 1 ]; then
    n_states=${#FM_LOCAL_FIRSTMATE_STATES[@]}
    i=1
    while [ "$i" -lt "$n_states" ]; do
      lstate=${FM_LOCAL_FIRSTMATE_STATES[$i]}
      auto_lane_rows "$i" "$lstate" >> "$tmp/lanes"
      i=$((i + 1))
    done
  fi
  awk -F'\t' -v OFS='\t' '{print $1 ":" $2, $3}' "$tmp/lanes" > "$tmp/worktrees"

  # Processes attributed to each lane's worktree.
  attr_ok=true
  : > "$tmp/ps"
  if ! awk -F'\t' '$2 != "" { found = 1; exit } END { exit !found }' "$tmp/worktrees"; then
    :  # no lane has a worktree, so there is nothing to attribute
  elif ! fm_lane_vitals_processes "$os" "$tmp/ps" 2>/dev/null; then
    attr_ok=false
    auto_notes="${auto_notes}process attribution unavailable; lane samples kept from the last reading
"
  fi
  fm_lane_vitals_attribute "$tmp/worktrees" "$tmp/ps" > "$tmp/attr" 2>/dev/null || : > "$tmp/attr"
  fm_lane_vitals_pss "$os" "$tmp/attr" 2>/dev/null || true

  # Disks: the home's filesystem, then each other filesystem holding a worktree.
  : > "$tmp/disks"
  seen_mounts=
  if v=$(fm_lane_vitals_disk_mount "$FM_HOME") && [ -n "$v" ]; then
    printf 'home\t%s\n' "${v#*	}" >> "$tmp/disks"
    seen_mounts="|${v%%	*}|"
  fi
  i=1
  while IFS='	' read -r _ _ v _; do
    [ -n "$v" ] && [ -d "$v" ] || continue
    v=$(fm_lane_vitals_disk_mount "$v") && [ -n "$v" ] || continue
    mount=${v%%	*} free=${v#*	}
    case "$seen_mounts" in *"|$mount|"*) continue ;; esac
    seen_mounts="$seen_mounts|$mount|"
    lab=worktrees
    [ "$i" -eq 1 ] || lab="worktrees-$i"
    i=$((i + 1))
    printf '%s\t%s\n' "$lab" "$free" >> "$tmp/disks"
  done < "$tmp/lanes"

  host=
  if [ "$LV_WSL" = 1 ]; then
    host=$(auto_host_view) || { host=; auto_notes="${auto_notes}Windows host view unavailable
"; }
  fi

  prev_ledger=null
  [ -f "$LANE_LEDGER" ] && prev_ledger=$(jq -c . "$LANE_LEDGER" 2>/dev/null) && [ -n "$prev_ledger" ] || prev_ledger=null
  prev_doc=null
  [ -f "$PUBLISHED" ] && prev_doc=$(jq -c . "$PUBLISHED" 2>/dev/null) && [ -n "$prev_doc" ] || prev_doc=null

  # One lane's worktree size per publish, the least recently measured first.
  disk_sample=null
  if [ "$mode" = publish ]; then
    v=$(awk -F'\t' '$1 == 0 && $3 != "" {print $2}' "$tmp/lanes" | jq -R . | jq -rs --argjson pl "$prev_ledger" '
      map({id: ., at: (($pl.lanes // {})[.].disk_epoch // 0)}) | sort_by(.at) | .[0].id // empty' 2>/dev/null) || v=
    if [ -n "$v" ]; then
      lstate=$(awk -F'\t' -v id="$v" '$1 == 0 && $2 == id {print $3; exit}' "$tmp/lanes")
      if [ -d "$lstate" ] && free=$(fm_lane_vitals_du_gb "$lstate" "$DU_TIMEOUT"); then
        disk_sample=$(jq -cn --arg id "$v" --argjson gb "$free" '{id: $id, gb: (($gb * 100 + 0.5 | floor) / 100)}')
      fi
    fi
  fi

  cfg=$(jq -cn --arg max_lanes "$max_lanes" --arg min_avail "$min_avail_gb" --arg min_disk "$min_disk_gb" \
    --arg max_load1 "$max_load1" --arg lane_fp "$lane_footprint_gb" --arg lane_disk "$lane_disk_gb" \
    --arg host_min "$host_min_avail_gb" --arg gpu_min "$min_gpu_free_gb" --arg allow_battery "$allow_battery" '
    def num: if . == "" then null else tonumber end;
    {max_lanes: ($max_lanes | num), min_avail: ($min_avail | num), min_disk: ($min_disk | num), max_load1: ($max_load1 | num),
     lane_fp: ($lane_fp | num), lane_disk: ($lane_disk | num), host_min: ($host_min | num), gpu_min: ($gpu_min | num),
     allow_battery: ($allow_battery == "1")}')
  vit=$(jq -cn --arg load5 "$LV_LOAD5" --arg c10 "$LV_PSI_CPU10" --arg m10 "$LV_PSI_MEM10" --arg m60 "$LV_PSI_MEM60" \
    --arg mf10 "$LV_PSI_MEMFULL10" --arg io10 "$LV_PSI_IO10" --arg io60 "$LV_PSI_IO60" --arg swapin "$LV_SWAPIN" \
    --arg vmpress "$LV_VMPRESS" --arg ac "$LV_ON_AC" --arg batt "$LV_BATT_PCT" --arg thermal "$LV_THERMAL" --arg wsl "$LV_WSL" '
    def num: if . == "" then null else (tonumber * 100 + 0.5 | floor) / 100 end;
    {load5: ($load5 | num), psi_cpu10: ($c10 | num), psi_mem10: ($m10 | num), psi_mem60: ($m60 | num),
     psi_memfull10: ($mf10 | num), psi_io10: ($io10 | num), psi_io60: ($io60 | num), swapin: ($swapin | num),
     vmpress: ($vmpress | num), on_ac: (if $ac == "" then null else $ac == "true" end), battery_pct: ($batt | num),
     thermal: (if $thermal == "" then null else $thermal end), wsl: ($wsl == "1")}')

  out=$(jq -cn --argjson now "$now" --rawfile lanes_tsv "$tmp/lanes" --rawfile attr_tsv "$tmp/attr" \
    --rawfile disks_tsv "$tmp/disks" --arg gpu_tsv "$LV_GPU" --arg host_tsv "$host" \
    --argjson prev_ledger "$prev_ledger" --argjson prev_doc "$prev_doc" --argjson disk_sample "$disk_sample" \
    --argjson cfg "$cfg" --argjson vit "$vit" --argjson young_s "$YOUNG_S" --argjson reopen "$GATE_REOPEN_SAMPLES" \
    --argjson cores "$( [ "$cores" = unknown ] && echo null || echo "$cores")" \
    --argjson load1 "$( [ "$load1" = unknown ] && echo null || echo "$load1")" \
    --argjson avail "${lim_avail:-null}" --argjson total "${total_gb:-${probe_total_gb:-null}}" \
    --argjson beat_battery "${on_battery:-null}" --arg notes "$auto_notes" --argjson attr_ok "$attr_ok" "$AUTO_JQ" 2>"$tmp/jq.err") || out=
  if [ -z "$out" ]; then
    free_lanes=0 reason=auto-unavailable
    reasons="${reasons}auto: the budget could not be computed ($(head -1 "$tmp/jq.err" 2>/dev/null))
"
    pub_reasons="${pub_reasons}auto: the budget could not be computed
"
    rm -rf "$tmp"
    return 0
  fi
  auto_doc=$(printf '%s' "$out" | jq -c '.doc')
  auto_ledger=$(printf '%s' "$out" | jq -c '.ledger')
  v=$(printf '%s' "$out" | jq -r '.reasons[]')
  if [ -n "$v" ]; then
    reasons="$reasons$v
"
    pub_reasons="$pub_reasons$v
"
  fi
  if [ -n "$constraints" ]; then
    free_lanes=0
    reason=$constraints
    v=$(printf '%s' "$out" | jq -r '.names | map(select(. != "ok")) | join(",")')
    [ -z "$v" ] || reason="$reason,$v"
  else
    free_lanes=$(printf '%s' "$out" | jq -r '.free_lanes')
    reason=$(printf '%s' "$out" | jq -r '.names | join(",")')
    [ "$(printf '%s' "$out" | jq -r '.admit')" != true ] || admit=true
  fi
  rm -rf "$tmp"
}

# --- verdict ----------------------------------------------------------------
constraints=
reasons=
pub_reasons=
add_constraint() {  # <name> <reason> [published reason, default the reason]
  case ",$constraints," in *",$1,"*) ;; *) constraints=${constraints:+$constraints,}$1 ;; esac
  reasons="$reasons$2
"
  pub_reasons="$pub_reasons${3-$2}
"
}
if [ "$basis" = probe ]; then
  # In auto mode the gates own cpu, with hysteresis, and the budget owns memory and disk.
  [ "$probe_cpu" -eq 0 ] || [ "$cap_mode" = auto ] || add_constraint cpu "cpu: load $load1 on $cores cores"
  [ "$probe_mem" -eq 0 ] || [ "$cap_mode" = auto ] || add_constraint memory "memory: $mem_free_pct% free"
  [ "$probe_disk" -eq 0 ] || [ "$cap_mode" = auto ] || add_constraint disk "disk: $disk_free_mb MB free"
fi
lim_avail=${avail_gb:-$probe_avail_gb}
lim_load1=$p_load1
[ -n "$lim_load1" ] || [ "$load1" = unknown ] || lim_load1=$load1
lim_disks=${disks:-$probe_disks}
if [ "$cap_mode" != auto ] && [ -n "$min_avail_gb" ] && [ -n "$lim_avail" ]; then
  if num_lt "$(awk -v a="$lim_avail" -v k="$min_avail_gb" 'BEGIN{print a - k}')" "$LANE_FOOTPRINT_GB"; then
    add_constraint memory "memory: no room for a $LANE_FOOTPRINT_GB GB lane: $lim_avail GB available, $min_avail_gb GB kept"
  fi
fi
if [ "$cap_mode" != auto ] && [ -n "$min_disk_gb" ]; then
  while IFS='	' read -r dlabel dfree; do
    [ -n "$dfree" ] || continue
    num_lt "$dfree" "$min_disk_gb" && add_constraint disk "disk: $dlabel $dfree GB free, under $min_disk_gb GB"
  done <<EOF
$lim_disks
EOF
fi
case "$level" in
  warn|critical)
    [ "$basis" != beat ] || add_constraint pressure "pressure $level${pressure_why:+: $pressure_why}" "pressure $level"
    ;;
esac
if [ "$cap_mode" != auto ] && [ -n "$max_load1" ] && [ -n "$lim_load1" ] && ! num_lt "$lim_load1" "$max_load1"; then
  add_constraint load "load: $lim_load1 over its max-load1 $max_load1"
fi
[ "$reserve_flag" != present ] || add_constraint reserve "captain reserve: $reserve_label"
[ "$on_battery" != true ] || [ "$allow_battery" -eq 1 ] || [ "$cap_mode" = auto ] || add_constraint battery "on battery"

free_lanes=unknown
admit=false
auto_doc=
if [ "$cap_mode" = auto ]; then
  auto_budget
else
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
      admit=true
    else
      reason=full
      reasons="full: $lanes of $target lanes
"
      pub_reasons=$reasons
    fi
    ;;
esac
fi

# --- admit ------------------------------------------------------------------
if [ "$mode" = admit ]; then
  if [ "$target" = invalid ]; then
    echo "fm-capacity: $target_error" >&2
    exit 1
  fi
  [ "$admit" = true ] && exit 0
  echo "deferred: lane capacity of this home ($LANE_CONFIG) does not admit another lane: $(printf '%s' "$reasons" | paste -sd ';' - | sed 's/;/; /g')" >&2
  exit 75
fi

# --- report -----------------------------------------------------------------
if [ "$mode" = report ]; then
  auto_tail=
  if [ -n "$auto_doc" ]; then
    auto_tail=" mode=auto budget=$(printf '%s' "$auto_doc" | jq -r '.budget.lanes')"
  elif [ "$cap_mode" = auto ]; then
    auto_tail=" mode=auto budget=unknown"
  fi
  printf 'capacity: free_lanes=%s reason=%s lanes=%s target=%s secondmates=%s load1=%s cores=%s mem_free_pct=%s disk_free_mb=%s%s\n' \
    "$free_lanes" "$reason" "$lanes" "$target" "$secondmates" "$load1" "$cores" "$mem_free_pct" "$disk_free_mb" "$auto_tail"

  if [ -n "$auto_doc" ]; then
    printf '%s' "$auto_doc" | jq -r --arg lanes "$lanes" '
      def gb: tostring + " GB";
      "Lanes: \($lanes) running here, \(.budget.machine_lanes) on this machine; auto budget \(.budget.lanes) (\(.budget.open) open, bound by \(.budget.binding)\(if .budget.damped then ", growth damped" else "" end)).",
      "Per lane: \(.footprint.mem_gb | gb), \(.footprint.cpu_cores) core, \(.footprint.disk_gb | gb) disk (\(if .footprint.source == "learned" then "learned from \(.footprint.samples) lanes" elif .footprint.source == "pinned" then "pinned" else "default until 5 lanes are measured" end)).",
      (.gates | map(select(.state == "closed") | .name) | if length > 0 then "Gates closed: \(join(", "))." else empty end),
      (.reclaim | if length > 0 then
        "Reclaim: \(length) (\(group_by(.class) | map("\(.[0].class) \(length)") | join(", "))), \(map(.mem_gb // 0) | add * 100 | floor / 100) GB held." else empty end)'
  elif [ "$cap_mode" = auto ]; then
    echo "Lanes: $lanes running, auto budget unavailable."
  fi
  case "$target" in
    none) [ "$cap_mode" = auto ] || echo "Lanes: $lanes running, no target set (config/lane-capacity absent)." ;;
    invalid) echo "Lanes: $lanes running, target unreadable ($target_error)." ;;
    *) [ "$cap_mode" = auto ] || echo "Lanes: $lanes running of $target target, $free_lanes open." ;;
  esac
  [ "$secondmates" -eq 0 ] || echo "Secondmates: $secondmates (hold no lane)."
  mem_text="${mem_free_pct}%"; [ "$mem_free_pct" != unknown ] || mem_text=unknown
  disk_text="$disk_free_mb MB"; [ "$disk_free_mb" != unknown ] || disk_text=unknown
  echo "Host: load $load1 on $cores cores, memory free $mem_text, disk free $disk_text."
  if [ -n "$pressure_files" ]; then
    why_text=$(printf '%s' "$why" | paste -sd ';' - | sed 's/;/; /g')
    echo "Pressure: $level from $basis${why_text:+ ($why_text)}."
  fi
  if [ "$cap_mode" = auto ]; then
    [ "$admit" = true ] || echo "Constrained: $reason - hold new dispatch until it clears."
  else
    [ "$target" = none ] || [ -z "$constraints" ] || echo "Constrained: $constraints - hold new dispatch until it clears."
  fi

  if [ -n "$target_error" ]; then
    echo "fm-capacity: $target_error" >&2
    exit 1
  fi
  exit 0
fi

# --- document (--json, --publish) -------------------------------------------
home=main
if [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ]; then
  IFS= read -r v < "$FM_HOME/.fm-secondmate-home" 2>/dev/null || v=
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!A-Za-z0-9._-]*) ;; *) home=$v ;; esac
fi
machine=$first_host
if [ -z "$machine" ]; then
  machine=$(hostname 2>/dev/null) || machine=
  machine=${machine%%.*}
fi

project_names=
for p in "$PROJECTS"/*/; do
  [ -d "$p" ] || continue
  project_names="$project_names$(basename "$p")
"
done

boot_id='' boot_epoch='' uptime_s=''
if [ "$os" = Darwin ]; then
  v=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^[^0-9]*sec = \([0-9][0-9]*\).*/\1/p')
  if is_uint "$v"; then
    boot_id=$v boot_epoch=$v uptime_s=$((now - v))
  fi
else
  IFS= read -r boot_id < "$PROC_ROOT/sys/kernel/random/boot_id" 2>/dev/null || boot_id=
  boot_epoch=$(awk '/^btime /{print $2}' "$PROC_ROOT/stat" 2>/dev/null)
  uptime_s=$(awk '{print int($1)}' "$PROC_ROOT/uptime" 2>/dev/null)
  is_uint "$boot_epoch" || boot_epoch=
  is_uint "$uptime_s" || uptime_s=
fi
prev_boot_id='' prev_boots='[]'
if [ -f "$PUBLISHED" ]; then
  prev_boot_id=$(jq -r 'if (.boot_id | type) == "string" then .boot_id else "" end' "$PUBLISHED" 2>/dev/null) || prev_boot_id=
  prev_boots=$(jq -c 'if (.boots | type) == "array" then [.boots[] | select(type == "number")] else [] end' "$PUBLISHED" 2>/dev/null) || prev_boots='[]'
  [ -n "$prev_boots" ] || prev_boots='[]'
fi
new_boot=
if [ -n "$boot_id" ] && [ -n "$boot_epoch" ] && [ "$boot_id" != "$prev_boot_id" ]; then
  new_boot=$boot_epoch
fi

watcher_age=
if m=$(file_mtime "$STATE/.last-watcher-beat"); then
  watcher_age=$((now - m)); [ "$watcher_age" -ge 0 ] || watcher_age=0
fi

captain=not-configured
if [ -n "$captain_idle" ]; then
  captain=unknown
  if [ -f "$STATE/.afk-contract" ] &&
    [ "$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = away ]; then
    captain=away
  elif [ "$os" = Darwin ]; then
    v=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/{print int($NF / 1000000000); exit}')
    if is_uint "$v"; then
      if [ "$v" -lt "$captain_idle" ]; then captain=present; else captain=idle; fi
    fi
  fi
fi

quota_json=null
if [ -n "$quota_provider" ]; then
  runway=unknown
  if command -v quota-axi >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    qout=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi --json --provider "$quota_provider" --max-age 15m 2>/dev/null) || qout=
    v=$(printf '%s' "$qout" | jq -r --arg p "$quota_provider" '
      [.providers[]? | select(.provider == $p) | .quotaSemantics.effectiveAvailability[]?
       | select(.scope == "all_models") | .runway.status | strings] | first // empty' 2>/dev/null) || v=
    case "$v" in ''|*[!a-z_]*) ;; *) runway=$v ;; esac
  fi
  quota_json=$(jq -cn --arg p "$quota_provider" --arg r "$runway" '{provider: $p, runway: $r}')
fi

cap_status=ok
case "$target" in none) cap_status=none ;; invalid) cap_status=invalid ;; esac
verdict_reasons=$pub_reasons
[ "$target" != none ] || [ "$cap_mode" = auto ] || verdict_reasons="no lane cap declared (config/lane-capacity absent)
"
[ "$target" != invalid ] || verdict_reasons="$target_reason
"

doc=$(jq -n \
  --argjson now "$now" --arg home "$home" --arg machine "$machine" \
  --arg lanes "$lanes" --arg pr_ready "$pr_ready" --arg lane_ids "$lane_ids" \
  --arg target "$target" --arg cap_status "$cap_status" --arg projects "$project_names" \
  --arg level "$level" --arg why "$pub_why" --arg basis "$basis" --arg beat_age "$beat_age_s" \
  --arg avail "$avail_gb" --arg total "$total_gb" --arg runq "$runq_per_core" \
  --arg swap "$swap_rate" --arg stall "$mem_stall" --arg load1 "$p_load1" \
  --arg battery "$on_battery" --arg disks "$disks" \
  --arg uptime "$uptime_s" --arg boot_id "$boot_id" --argjson prev_boots "$prev_boots" \
  --arg new_boot "$new_boot" --argjson kept "$BOOTS_KEPT" --arg watcher_age "$watcher_age" \
  --arg reserve_flag "$reserve_flag" --arg reserve_label "$reserve_label" \
  --arg captain "$captain" --argjson quota "$quota_json" \
  --arg min_avail "$min_avail_gb" --arg min_disk "$min_disk_gb" --arg max_load1 "$max_load1" \
  --arg admit "$admit" --arg free_lanes "$free_lanes" --arg reasons "$verdict_reasons" \
  --argjson auto "${auto_doc:-null}" --arg cap_mode "$cap_mode" '
  def num: if . == "" then null else tonumber + 0 end;
  def lines: split("\n") | map(select(. != ""));
  {schema: "fm-lane-capacity.v1", generated_epoch: $now, home: $home, machine: $machine,
   lanes: {count: ($lanes | tonumber), pr_ready: ($pr_ready | tonumber), ids: ($lane_ids | lines)},
   cap: {target: (if $cap_status == "ok" then ($target | tonumber) else null end), status: $cap_status},
   projects: ($projects | lines),
   pressure: {level: $level, why: ($why | lines), basis: $basis, beat_age_s: ($beat_age | num),
     avail_gb: ($avail | num), total_gb: ($total | num), runq_per_core: ($runq | num),
     swap_rate_pps_1m: ($swap | num), mem_stall_pct: ($stall | num), load1: ($load1 | num),
     on_battery: (if $battery == "" then null else $battery == "true" end),
     disks: [$disks | lines[] | split("\t") | {label: .[0], free_gb: (.[1] // "" | num)}]},
   uptime_s: ($uptime | num), boot_id: (if $boot_id == "" then null else $boot_id end),
   boots: (($prev_boots + (if $new_boot == "" then [] else [$new_boot | tonumber] end)) | .[-$kept:]),
   watcher_beat_age_s: ($watcher_age | num),
   reserve: {flag: $reserve_flag, label: (if $reserve_label == "" then null else $reserve_label end)},
   captain: $captain, quota: $quota,
   limits: {min_avail_gb: ($min_avail | num), min_disk_gb: ($min_disk | num), max_load1: ($max_load1 | num)},
   verdict: {admit: ($admit == "true"), free_lanes: ($free_lanes | if . == "unknown" then null else tonumber end),
     reasons: ($reasons | lines)}}
  | if $cap_mode != "auto" then . else (.cap.mode = "auto") + ($auto // {budget: null}) end') || {
  echo "fm-capacity: could not assemble the lane capacity document" >&2
  [ "$mode" = publish ] && exit 0
  exit 1
}

if [ "$why" != "$pub_why" ] || [ "$reasons" != "$pub_reasons" ]; then
  printf '%s' "$why" | sed 's/^/fm-capacity: pressure: /' >&2
  printf '%s' "$reasons" | sed 's/^/fm-capacity: reason: /' >&2
fi
if [ "$mode" = json ]; then
  printf '%s\n' "$doc"
  if [ -n "$target_error" ]; then
    echo "fm-capacity: $target_error" >&2
    exit 1
  fi
  exit 0
fi

# --publish
[ -z "$target_error" ] || echo "fm-capacity: $target_error (published as invalid)" >&2
if [ ! -d "$STATE" ]; then
  echo "fm-capacity: no state directory at $STATE; nothing published" >&2
  exit 0
fi
tmp=$(mktemp "$STATE/.lane-capacity.json.XXXXXX" 2>/dev/null) || {
  echo "fm-capacity: cannot create a temporary file in $STATE; nothing published" >&2
  exit 0
}
if chmod 600 "$tmp" && printf '%s\n' "$doc" > "$tmp" && mv -f "$tmp" "$PUBLISHED"; then
  if [ -n "$auto_ledger" ]; then
    tmp=$(mktemp "$STATE/.lane-footprint.json.XXXXXX" 2>/dev/null) || {
      echo "fm-capacity: cannot create a temporary file in $STATE; footprint ledger not written" >&2
      exit 0
    }
    if ! { chmod 600 "$tmp" && printf '%s\n' "$auto_ledger" > "$tmp" && mv -f "$tmp" "$LANE_LEDGER"; }; then
      rm -f "$tmp"
      echo "fm-capacity: could not write $LANE_LEDGER" >&2
    fi
  fi
  exit 0
fi
rm -f "$tmp"
echo "fm-capacity: could not write $PUBLISHED" >&2
exit 0
