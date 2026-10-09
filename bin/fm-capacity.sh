#!/usr/bin/env bash
# fm-capacity.sh - report open lanes and host headroom for queued-work dispatch,
# and publish this home's lane facts for placement.
#
# Usage:
#   fm-capacity.sh            the report: one key=value line, then a human summary
#   fm-capacity.sh --json     the fm-lane-capacity.v1 document on stdout
#   fm-capacity.sh --publish  write that document to state/lane-capacity.json
#   fm-capacity.sh --admit    this home's own admission verdict as an exit status
#
# It reads this home's state/*.meta, the optional config/lane-capacity, the
# pressure files and reserve flags that file names, and the host's own probes.
# It never spawns, locks, or changes anything; --publish writes its one file.
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
#   memory    probe basis: free-memory percentage < 10; or, on any basis,
#             available memory minus min-avail-gb (0 when unset) is under the
#             1 GB a default lane needs
#   disk      probe basis: free space on the filesystem holding FM_HOME
#             < 5120 MB; or a disk row under min-disk-gb
#   pressure  beat basis: the pressure level is warn or critical
#   load      load1 is at or over max-load1
#   reserve   a reserve-flag file exists
#   battery   a fresh beat reports the machine on battery
# Otherwise reason is ok when free_lanes > 0 and full when it is 0.
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
# constraint; its reasons are the constraints in words. The document carries
# labels and derived states only, never paths, addresses, commands, or tokens.
#
# --publish writes the document atomically (mode 0600) when config/lane-capacity
# exists, skipping when state/lane-capacity.json is younger than
# FM_LANE_CAPACITY_PUBLISH_INTERVAL seconds (default 30; 0 always publishes).
# A malformed config is still published with cap.status invalid. It is
# best-effort: every failure goes to stderr and it exits 0.
#
# --admit exits 0 when config/lane-capacity is absent or the verdict admits,
# and 75 with one `deferred:` line on stderr when it does not.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_PROJECTS_OVERRIDE resolve the home exactly as the other bin/ scripts do.
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

MEM_FREE_MIN_PCT=10
DISK_FREE_MIN_MB=5120
LANE_FOOTPRINT_GB=1
QUOTA_TIMEOUT=5
BOOTS_KEPT=10

mode=report
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  --json) mode=json ;;
  --publish) mode=publish ;;
  --admit) mode=admit ;;
  *) echo "usage: fm-capacity.sh [--json|--publish|--admit|--help]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: fm-capacity.sh [--json|--publish|--admit|--help]" >&2; exit 2; }

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
  admit|publish) [ -e "$LANE_CONFIG" ] || exit 0 ;;
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
min_avail_gb=
min_disk_gb=
max_load1=
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
parse_lane_config() {
  local line lineno=0 key value rest path seen=
  target=
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//')
    [ -n "$line" ] || continue
    if [ -z "$target" ]; then
      is_uint "$line" && [ "${#line}" -le 9 ] || { target_error="line $lineno: the first line must be the lane cap, one non-negative integer"; return 1; }
      target=$((10#$line))
      continue
    fi
    key=${line%% *}
    rest=
    [ "$key" = "$line" ] || rest=$(printf '%s' "${line#* }" | sed 's/^ *//')
    value=${rest%% *}
    case "$key" in
      pressure-file|reserve-flag) ;;
      *)
        case " $seen " in *" $key "*) target_error="line $lineno: $key appears more than once"; return 1 ;; esac
        seen="$seen $key"
        [ "$value" = "$rest" ] || { target_error="line $lineno: $key takes one value"; return 1 ;}
        ;;
    esac
    case "$key" in
      min-avail-gb|min-disk-gb|max-load1)
        is_num "$value" || { target_error="line $lineno: $key needs a non-negative number"; return 1; }
        case "$key" in
          min-avail-gb) min_avail_gb=$value ;;
          min-disk-gb) min_disk_gb=$value ;;
          max-load1) max_load1=$value ;;
        esac
        ;;
      captain-idle)
        is_uint "$value" && [ "${#value}" -le 9 ] && [ "$((10#$value))" -gt 0 ] || { target_error="line $lineno: captain-idle needs a positive number of seconds"; return 1; }
        captain_idle=$((10#$value))
        ;;
      quota-provider)
        case "$value" in ''|*[!a-z0-9-]*) target_error="line $lineno: quota-provider needs one provider name"; return 1 ;; esac
        quota_provider=$value
        ;;
      pressure-file)
        [ -n "$value" ] && [ "$value" = "$rest" ] || { target_error="line $lineno: pressure-file takes one absolute path"; return 1; }
        path=$(expand_path "$value") || { target_error="line $lineno: pressure-file takes one absolute path"; return 1; }
        pressure_files="$pressure_files$path
"
        ;;
      reserve-flag)
        path=$(expand_path "$value") || { target_error="line $lineno: reserve-flag needs an absolute path"; return 1; }
        rest=$(printf '%s' "${rest#"$value"}" | sed 's/^ *//')
        reserve_flags="$reserve_flags$path	${rest:-reserved}
"
        ;;
      *) target_error="line $lineno: unknown key '$key'"; return 1 ;;
    esac
  done < "$LANE_CONFIG"
  [ -n "$target" ] || { target_error="no lane cap: the first line must be one non-negative integer"; return 1; }
}
if [ -e "$LANE_CONFIG" ]; then
  if [ ! -r "$LANE_CONFIG" ] || ! parse_lane_config; then
    [ -n "$target_error" ] || target_error="unreadable"
    target_error="config/lane-capacity: $target_error"
    target=invalid
    min_avail_gb='' min_disk_gb='' max_load1='' captain_idle='' quota_provider='' pressure_files='' reserve_flags=''
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
  v=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t > 0 && a != "") printf "%d %.2f %.2f", a * 100 / t, a / 1048576, t / 1048576}' /proc/meminfo 2>/dev/null)
  if [ -n "$v" ]; then
    # shellcheck disable=SC2086
    set -- $v
    mem_free_pct=$1 probe_avail_gb=$2 probe_total_gb=$3
  fi
fi

disk_free_mb=unknown
v=$(df -Pk "$FM_HOME" 2>/dev/null | awk 'NR==2{print int($4 / 1024)}')
is_uint "$v" && disk_free_mb=$v

# --- pressure ---------------------------------------------------------------
level_rank() {
  case "$1" in ok) echo 0 ;; warn) echo 1 ;; critical) echo 2 ;; *) echo -1 ;; esac
}
why=
pressure_why=
add_why() { why="$why$1
"; }
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
    def s: tostring | gsub("[\t\n\r]"; " ");
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
       ] | join("\t")),
      ((.machine.pressure.why // [])[] | "why\t" + s),
      ((.machine.beat.errors // [])[] | "error\t" + s),
      ((.machine.disks // [])[] | select(type == "object") | "disk\t" + ((.label // "disk") | s) + "\t" + (.free_gb | n))
    else "foreign" end' "$pfile" 2>/dev/null) || parsed=
  case "$parsed" in
    beat*) ;;
    foreign*) add_why "$label: not a lookout.beat 1.x document"; continue ;;
    *) add_why "$label: beat unreadable"; continue ;;
  esac
  IFS='	' read -r _ host interval blevel b_avail b_total b_runq b_swap b_stall b_l1 b_batt <<EOF
$(printf '%s\n' "$parsed" | head -1)
EOF
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
  while IFS='	' read -r kind a b; do
    case "$kind" in
      why) add_why "$prefix$a"; pressure_why="${pressure_why:+$pressure_why; }$prefix$a" ;;
      error) errs="${errs:+$errs; }$a" ;;
      disk) disks="$disks${prefix:+$label }$a	$b
" ;;
    esac
  done <<EOF
$(printf '%s\n' "$parsed" | sed 1d)
EOF
  [ -z "$errs" ] || add_why "${prefix}beat errors: $errs"
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
  [ "$disk_free_mb" = unknown ] || disks="home	$(awk -v m="$disk_free_mb" 'BEGIN{printf "%.1f", m / 1024}')
"
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

# --- verdict ----------------------------------------------------------------
constraints=
reasons=
add_constraint() {
  case ",$constraints," in *",$1,"*) ;; *) constraints=${constraints:+$constraints,}$1 ;; esac
  reasons="$reasons$2
"
}
if [ "$basis" = probe ]; then
  [ "$probe_cpu" -eq 0 ] || add_constraint cpu "cpu: load $load1 on $cores cores"
  [ "$probe_mem" -eq 0 ] || add_constraint memory "memory: $mem_free_pct% free"
  [ "$probe_disk" -eq 0 ] || add_constraint disk "disk: $disk_free_mb MB free"
fi
if [ -n "$avail_gb" ]; then
  keep=${min_avail_gb:-0}
  if num_lt "$(awk -v a="$avail_gb" -v k="$keep" 'BEGIN{print a - k}')" "$LANE_FOOTPRINT_GB"; then
    add_constraint memory "memory: no room for a $LANE_FOOTPRINT_GB GB lane: $avail_gb GB available, $keep GB kept"
  fi
fi
if [ -n "$min_disk_gb" ]; then
  while IFS='	' read -r dlabel dfree; do
    [ -n "$dfree" ] || continue
    num_lt "$dfree" "$min_disk_gb" && add_constraint disk "disk: $dlabel $dfree GB free, under $min_disk_gb GB"
  done <<EOF
$disks
EOF
fi
case "$level" in
  warn|critical)
    [ "$basis" != beat ] || add_constraint pressure "pressure $level${pressure_why:+: $pressure_why}"
    ;;
esac
if [ -n "$max_load1" ] && [ -n "$p_load1" ] && ! num_lt "$p_load1" "$max_load1"; then
  add_constraint load "load: $p_load1 over its max-load1 $max_load1"
fi
[ "$reserve_flag" != present ] || add_constraint reserve "captain reserve: $reserve_label"
[ "$on_battery" != true ] || add_constraint battery "on battery"

free_lanes=unknown
admit=false
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
    fi
    ;;
esac

# --- admit ------------------------------------------------------------------
if [ "$mode" = admit ]; then
  if [ "$target" = invalid ]; then
    echo "fm-capacity: $target_error" >&2
    exit 1
  fi
  [ "$admit" = true ] && exit 0
  echo "deferred: lane capacity of this home ($LANE_CONFIG) does not admit another lane: $(printf '%s' "$reasons" | paste -sd ';' - | sed 's/;/; /g'); the lane was not launched and its backlog item stays queued" >&2
  exit 75
fi

# --- report -----------------------------------------------------------------
if [ "$mode" = report ]; then
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
  if [ -n "$pressure_files" ]; then
    why_text=$(printf '%s' "$why" | paste -sd ';' - | sed 's/;/; /g')
    echo "Pressure: $level from $basis${why_text:+ ($why_text)}."
  fi
  [ -z "$constraints" ] || echo "Constrained: $constraints - hold new dispatch until it clears."

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
  IFS= read -r boot_id < /proc/sys/kernel/random/boot_id 2>/dev/null || boot_id=
  boot_epoch=$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)
  uptime_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
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
verdict_reasons=$reasons
[ "$target" != none ] || verdict_reasons="no lane cap declared (config/lane-capacity absent)
"
[ "$target" != invalid ] || verdict_reasons="$target_error
"

doc=$(jq -n \
  --argjson now "$now" --arg home "$home" --arg machine "$machine" \
  --arg lanes "$lanes" --arg pr_ready "$pr_ready" --arg lane_ids "$lane_ids" \
  --arg target "$target" --arg cap_status "$cap_status" --arg projects "$project_names" \
  --arg level "$level" --arg why "$why" --arg basis "$basis" --arg beat_age "$beat_age_s" \
  --arg avail "$avail_gb" --arg total "$total_gb" --arg runq "$runq_per_core" \
  --arg swap "$swap_rate" --arg stall "$mem_stall" --arg load1 "$p_load1" \
  --arg battery "$on_battery" --arg disks "$disks" \
  --arg uptime "$uptime_s" --arg boot_id "$boot_id" --argjson prev_boots "$prev_boots" \
  --arg new_boot "$new_boot" --argjson kept "$BOOTS_KEPT" --arg watcher_age "$watcher_age" \
  --arg reserve_flag "$reserve_flag" --arg reserve_label "$reserve_label" \
  --arg captain "$captain" --argjson quota "$quota_json" \
  --arg min_avail "$min_avail_gb" --arg min_disk "$min_disk_gb" --arg max_load1 "$max_load1" \
  --arg admit "$admit" --arg free_lanes "$free_lanes" --arg reasons "$verdict_reasons" '
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
     reasons: ($reasons | lines)}}') || {
  echo "fm-capacity: could not assemble the lane capacity document" >&2
  [ "$mode" = publish ] && exit 0
  exit 1
}

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
  exit 0
fi
rm -f "$tmp"
echo "fm-capacity: could not write $PUBLISHED" >&2
exit 0
