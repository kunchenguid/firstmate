# shellcheck shell=bash
# Machine-capacity primitives: read REAL machine state and decide whether the
# machine has headroom for one more agent.
# Usage: . bin/fm-capacity-lib.sh   (no FM_* setup required)
#
# WHY THIS EXISTS
# A saturated machine is not a throughput problem, it is a "the operator cannot
# use his own computer" problem. Firstmate has driven a 24 GB, 10-core machine
# to a standstill with dozens of agents alive.
#
# THE ENTIRE REMIT IS DECLINING NEW WORK.
# This library never kills, signals, stops, reaps, or deprioritizes anything.
# It reads, it decides, it prints. Restoring headroom by stopping live agents
# would destroy unlanded work, so it is not an option this code may take.
#
# WHAT THE BINDING RESOURCE ACTUALLY IS (measured, not assumed)
# During the incident the machine was measured directly and the obvious reading
# was wrong. MEMORY was exhausted, not CPU:
#   - 24 GB installed, 155 MB unused, 9.6 GB held by the compressor
#   - 21.5 GB of swap, 20.0 GB of it consumed, 25.7 million swapouts
#   - CPU usage about 4.6 of 10 cores, with no fleet agent among the top
#     consumers at all
#   - 1m load average 299
# That load average of 299 was not work queued for CPU. It was processes FROZEN
# ON PAGING. So both of the instruments an engineer reaches for first are wrong
# here, in opposite directions: a guard reading LOAD sees catastrophe while the
# cores sit half idle, and a guard reading CPU UTILISATION sees plenty of room
# while the machine drowns. Neither is the instrument.
#
# So the primary signals are memory and swap, and they bind:
#   1. free memory     what a new agent runtime can actually claim right now.
#   2. swap in use     the machine's own record that it ran out and started
#                      paging. Instantaneous and unambiguous, unlike the
#                      cumulative swapout counter, which is reported as context
#                      because one read cannot tell "swapping now" from
#                      "swapped a week ago" and sampling twice would be a monitor.
#   3. memory pressure the kernel's own instantaneous verdict, where the platform
#                      publishes one. This catches a machine that still reports
#                      comfortable-looking free memory while reclaim is already
#                      costing wall-clock.
#   4. fleet memory    how much memory firstmate's OWN agents hold, measured over
#                      whole process TREES rather than agent process count. This
#                      is the immediate, attributable signal: it moves the instant
#                      a spawn lands, roughly a minute before anything else does.
#                      It is weighed by footprint, not by count, because PAUSING
#                      AN AGENT DOES NOT RELEASE ITS MEMORY - which is exactly why
#                      pausing three whole domains during the incident did not
#                      drain the machine. Trees, not bare agent processes, because
#                      an agent's language runtimes and tool servers are memory
#                      the fleet caused and the fleet holds.
#
# And load average is CORROBORATING ONLY. It is measured and always printed,
# because it is real evidence and it is what a human notices first, but it does
# not refuse by default: on this machine it read 299 while the cores were idle.
# An operator who wants a CPU-side ceiling sets load_per_core_max explicitly.
#
# There is deliberately NO composite score. Each signal is compared against its
# own limit and reported with its own measured and wanted values, so every
# refusal states exactly which resource ran out and by how much. A blended
# number could not be explained in a refusal message, and a refusal nobody can
# read is a refusal nobody can act on.
#
# ANY ONE binding signal over its limit refuses. They are limits on separate
# resources, not votes.
#
# UNREADABLE SIGNALS ARE NEVER A SILENT PASS.
# A probe that cannot read its signal yields the explicit value "unknown", never
# a made-up zero and never a quiet success. An unknown binding signal means the
# guard could not prove there is headroom, and by default that REFUSES, because
# the operator keeping his machine outranks fleet throughput. Operators on a
# platform this cannot measure set on_unknown=allow to opt into the other
# behavior; either way the unknown is printed, never hidden.
#
# CONFIGURATION
# docs/configuration.md "Machine capacity (config/spawn-capacity)" owns the
# operator-facing contract. This header owns the parsing and probe mechanics.
# Keys, one per line, "key = value", "#" comments and blank lines allowed:
#   mode                  enforce (default) | off
#   min_free_memory_mb    integer MB a new agent must be able to claim,
#                         default 1024
#   max_swap_used_pct     integer 0-100, or off, default 50
#   max_memory_pressure   normal (default) | warn | ignore
#   max_fleet_memory_pct  integer 0-100 of installed RAM the fleet's own process
#                         trees may hold, or off, default 40 - the operator keeps
#                         the majority of his own machine
#   load_per_core_max     positive decimal, or off (default) - off because load
#                         rises on paging stalls, not only on CPU demand
#   on_unknown            refuse (default) | allow
# A malformed file REFUSES with the parse error rather than silently reverting
# to defaults, because a typo'd limit that reads as the default is the same class
# of bug as no guard at all. An ABSENT file is not malformed: it means defaults,
# which is the ordinary case.
#
# TEST AND DIAGNOSTIC MEASUREMENT INJECTION
# Each probe honours an environment override so tests and diagnosis can drive the
# decision from fixed numbers instead of the live machine. These substitute a
# MEASUREMENT; they never disable the guard, which still evaluates every rule
# against whatever it is given. The literal string "unknown" is accepted to
# exercise the unreadable path:
#   FM_CAPACITY_MEM_TOTAL_MB FM_CAPACITY_MEM_FREE_MB FM_CAPACITY_SWAP_TOTAL_MB
#   FM_CAPACITY_SWAP_USED_MB FM_CAPACITY_MEM_PRESSURE FM_CAPACITY_SWAPOUTS
#   FM_CAPACITY_FLEET_RSS_MB FM_CAPACITY_FLEET_AGENTS FM_CAPACITY_FLEET_PROCS
#   FM_CAPACITY_CORES FM_CAPACITY_LOAD1
# The operator's real control is the config file above, not these.

# The verified harness adapters firstmate launches (AGENTS.md section 4). A
# fleet root is one of these CLIs running anywhere on the machine, not just in
# this home: every home, pool, and the operator's own interactive agent sessions
# share the same physical RAM. fm_capacity_fleet_totals owns how a process is
# matched against this list.
FM_CAPACITY_WORKER_NAMES="claude codex opencode pi pi-signed grok kimi cline cursor-agent copilot muse agy"

FM_CAPACITY_CONFIG_FILE="spawn-capacity"

FM_CAPACITY_MODE=""
FM_CAPACITY_MIN_FREE_MEMORY_MB=""
FM_CAPACITY_MAX_SWAP_USED_PCT=""
FM_CAPACITY_MAX_MEMORY_PRESSURE=""
FM_CAPACITY_MAX_FLEET_MEMORY_PCT=""
FM_CAPACITY_LOAD_PER_CORE_MAX=""
FM_CAPACITY_ON_UNKNOWN=""
FM_CAPACITY_CONFIG_ERROR=""
FM_CAPACITY_CONFIG_PATH=""

FM_CAPACITY_M_MEM_TOTAL_MB=""
FM_CAPACITY_M_MEM_FREE_MB=""
FM_CAPACITY_M_SWAP_TOTAL_MB=""
FM_CAPACITY_M_SWAP_USED_MB=""
FM_CAPACITY_M_MEM_PRESSURE=""
FM_CAPACITY_M_SWAPOUTS=""
FM_CAPACITY_M_FLEET_RSS_MB=""
FM_CAPACITY_M_FLEET_AGENTS=""
FM_CAPACITY_M_FLEET_PROCS=""
FM_CAPACITY_M_CORES=""
FM_CAPACITY_M_LOAD1=""

FM_CAPACITY_ROWS=""
FM_CAPACITY_SUMMARY=""

# --- small predicates -------------------------------------------------------

fm_capacity_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# One non-negative decimal: digits, optionally one dot and more digits.
fm_capacity_is_decimal() {
  local v=${1:-}
  case "$v" in
    ''|.|*[!0-9.]*) return 1 ;;
  esac
  case "$v" in
    *.*.*) return 1 ;;
  esac
  return 0
}

# fm_capacity_gt <a> <b>  true when decimal a > decimal b.
fm_capacity_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'
}

# fm_capacity_lt <a> <b>  true when decimal a < decimal b.
fm_capacity_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# fm_capacity_pct <part> <whole> as an integer percent; empty when whole is 0.
fm_capacity_pct() {
  awk -v p="$1" -v w="$2" 'BEGIN { if (w + 0 <= 0) exit 1; printf "%d\n", (p * 100) / w }'
}

# fm_capacity_gb <mb> as "N.N GB".
fm_capacity_gb() {
  awk -v m="$1" 'BEGIN { printf "%.1f GB\n", m / 1024 }'
}

# Render a space-separated accumulator as "a, b and c" for the summary line.
fm_capacity_join() {
  printf '%s' "$1" | awk '
    { for (i = 1; i <= NF; i++) w[++n] = $i }
    END {
      for (i = 1; i <= n; i++) {
        if (i > 1) printf "%s", (i == n ? " and " : ", ")
        printf "%s", w[i]
      }
      printf "\n"
    }'
}

# --- probes -----------------------------------------------------------------
#
# Every probe prints one value or the literal "unknown". No probe invents a
# neutral value, because a fabricated healthy reading is exactly how an
# unreadable signal turns into a silent pass.

fm_capacity_probe_mem_total_mb() {
  local v
  if [ -n "${FM_CAPACITY_MEM_TOTAL_MB:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_MEM_TOTAL_MB"
    return 0
  fi
  v=$(sysctl -n hw.memsize 2>/dev/null) || v=
  if fm_capacity_is_uint "$v" && [ "$v" -gt 0 ]; then
    printf '%s\n' "$((v / 1024 / 1024))"
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    v=$(awk '/^MemTotal:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo 2>/dev/null) || v=
    fm_capacity_is_uint "$v" && [ "$v" -gt 0 ] && { printf '%s\n' "$v"; return 0; }
  fi
  printf '%s\n' unknown
}

# Memory a new agent runtime can claim without forcing the machine to reclaim or
# page. On Darwin that is the genuinely unused pages (free plus speculative,
# which is what `top` reports as "unused"); macOS deliberately keeps this low,
# so the default floor below is calibrated for that, not for a Linux-style
# free-memory reading. On Linux it is MemAvailable, the kernel's own estimate of
# the same quantity - deliberately NOT MemFree, which ignores reclaimable cache.
fm_capacity_probe_mem_free_mb() {
  local v
  if [ -n "${FM_CAPACITY_MEM_FREE_MB:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_MEM_FREE_MB"
    return 0
  fi
  if command -v vm_stat >/dev/null 2>&1; then
    v=$(vm_stat 2>/dev/null | awk '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") { ps = $(i + 1) + 0; break } }
      /^Pages free:/ { gsub(/\./, "", $3); free = $3 + 0 }
      /^Pages speculative:/ { gsub(/\./, "", $3); spec = $3 + 0 }
      END { if (ps > 0) printf "%d\n", ((free + spec) * ps) / 1048576 }') || v=
    fm_capacity_is_uint "$v" && { printf '%s\n' "$v"; return 0; }
  fi
  if [ -r /proc/meminfo ]; then
    v=$(awk '/^MemAvailable:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo 2>/dev/null) || v=
    fm_capacity_is_uint "$v" && { printf '%s\n' "$v"; return 0; }
  fi
  printf '%s\n' unknown
}

# Prints "<total_mb> <used_mb>", or "unknown unknown". A machine with no swap
# configured reports "0 0", which is a real answer, not a failed read.
fm_capacity_probe_swap_mb() {
  local line total used
  if [ -n "${FM_CAPACITY_SWAP_TOTAL_MB:-}" ] || [ -n "${FM_CAPACITY_SWAP_USED_MB:-}" ]; then
    printf '%s %s\n' "${FM_CAPACITY_SWAP_TOTAL_MB:-unknown}" "${FM_CAPACITY_SWAP_USED_MB:-unknown}"
    return 0
  fi
  # Darwin: "total = 21504.00M  used = 20022.88M  free = 1481.12M  (encrypted)".
  line=$(sysctl -n vm.swapusage 2>/dev/null) || line=
  if [ -n "$line" ]; then
    total=$(printf '%s\n' "$line" | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p')
    used=$(printf '%s\n' "$line" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
    if fm_capacity_is_decimal "$total" && fm_capacity_is_decimal "$used"; then
      printf '%s %s\n' "$(awk -v v="$total" 'BEGIN { printf "%d\n", v }')" \
        "$(awk -v v="$used" 'BEGIN { printf "%d\n", v }')"
      return 0
    fi
  fi
  if [ -r /proc/meminfo ]; then
    line=$(awk '
      /^SwapTotal:/ { t = $2 }
      /^SwapFree:/ { f = $2; seen = 1 }
      END { if (seen) printf "%d %d\n", t / 1024, (t - f) / 1024 }' /proc/meminfo 2>/dev/null) || line=
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi
  printf '%s %s\n' unknown unknown
}

# Cumulative swapouts since boot. Context only: one read cannot distinguish
# "paging right now" from "paged a week ago", and sampling twice would make this
# a monitor rather than a spawn-time check.
fm_capacity_probe_swapouts() {
  local v
  if [ -n "${FM_CAPACITY_SWAPOUTS:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_SWAPOUTS"
    return 0
  fi
  if command -v vm_stat >/dev/null 2>&1; then
    v=$(vm_stat 2>/dev/null | awk '/^Swapouts:/ { gsub(/\./, "", $2); print $2 + 0; exit }') || v=
    fm_capacity_is_uint "$v" && { printf '%s\n' "$v"; return 0; }
  fi
  if [ -r /proc/vmstat ]; then
    v=$(awk '/^pswpout / { print $2; exit }' /proc/vmstat 2>/dev/null) || v=
    fm_capacity_is_uint "$v" && { printf '%s\n' "$v"; return 0; }
  fi
  printf '%s\n' unknown
}

# The OS's own instantaneous memory-pressure verdict: normal | warn | critical,
# or unknown where the platform publishes none.
fm_capacity_probe_mem_pressure() {
  local v
  if [ -n "${FM_CAPACITY_MEM_PRESSURE:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_MEM_PRESSURE"
    return 0
  fi
  # Darwin: kern.memorystatus_vm_pressure_level is 1 normal, 2 warn, 4 critical.
  v=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) || v=
  case "$v" in
    1) printf '%s\n' normal; return 0 ;;
    2) printf '%s\n' warn; return 0 ;;
    4) printf '%s\n' critical; return 0 ;;
  esac
  # Linux PSI: "some avg10=N" is the percentage of the last 10 seconds in which
  # at least one task stalled waiting on memory. Sustained nonzero stalling
  # means reclaim is already costing wall-clock, so the marks below are
  # deliberately conservative rather than tuned.
  if [ -r /proc/pressure/memory ]; then
    v=$(awk '/^some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit } }' \
      /proc/pressure/memory 2>/dev/null) || v=
    if fm_capacity_is_decimal "$v"; then
      fm_capacity_lt "$v" 5 && { printf '%s\n' normal; return 0; }
      fm_capacity_lt "$v" 20 && { printf '%s\n' warn; return 0; }
      printf '%s\n' critical
      return 0
    fi
  fi
  printf '%s\n' unknown
}

# Separates the two ps snapshots handed to fm_capacity_fleet_totals on one
# stream. Every ps line begins with a pid, so this can never collide with real
# output.
FM_CAPACITY_SNAPSHOT_SEP="--- fm-capacity argv ---"

# fm_capacity_fleet_totals <comm-snapshot> <argv-snapshot>
# Pure matcher over two ps snapshots: "<pid> <ppid> <rss> <comm>" lines and
# "<pid> <full argv>" lines. Prints "<resident_mb> <agent_roots> <procs>".
# Kept separate from the probe below so the matching rules can be exercised
# against fixed snapshots; the probe owns reading the live machine.
#
# WHICH PROCESSES ARE FLEET ROOTS
# FM_CAPACITY_WORKER_NAMES is the source of truth, and it is matched the way the
# harness detectors this repo already depends on match it (bin/fm-harness.sh
# detect_own, bin/fm-session-lock-lib.sh): the command basename usually names
# the adapter, but when that basename is a bare interpreter the adapter is named
# in the script path it was handed instead. Several verified adapters are
# npm-installed and run exactly that way, so basename equality alone would find
# no fleet at all on a machine full of them - and reporting a confident zero for
# a read that actually failed is the one thing this file may never do.
fm_capacity_fleet_totals() {
  printf '%s\n%s\n%s\n' "${2:-}" "$FM_CAPACITY_SNAPSHOT_SEP" "${1:-}" \
    | awk -v names="$FM_CAPACITY_WORKER_NAMES" -v sep="$FM_CAPACITY_SNAPSHOT_SEP" '
    BEGIN { nw = split(names, list, " "); for (i = 1; i <= nw; i++) want[list[i]] = 1 }
    # An adapter basename, or a packaged one that keeps the adapter as its
    # leading name component ("claude-code", "codex.js"). Deliberately not a
    # bare substring test: "pip" must never read as "pi".
    function names_worker(s,   i) {
      if (s in want) return 1
      for (i = 1; i <= nw; i++)
        if (index(s, list[i] "-") == 1 || index(s, list[i] "_") == 1 \
            || index(s, list[i] ".") == 1) return 1
      return 0
    }
    # The adapter as a whole path or word component of an interpreter argv,
    # anchored on both sides for the same reason.
    function argv_names_worker(s,   i) {
      for (i = 1; i <= nw; i++)
        if (s ~ ("(^|/|[[:space:]])" list[i] "([-_./]|[[:space:]]|$)")) return 1
      return 0
    }
    $0 == sep { commphase = 1; next }
    !commphase {
      if (NF < 2) next
      line = $0
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
      argv[$1] = line
      next
    }
    {
      if (NF < 4) next
      pid = $1; ppid = $2; rss = $3
      # comm is the whole remainder of the line, not one field: macOS ps prints
      # an absolute executable path, which may itself contain spaces, while
      # Linux prints a bare name. Reduce both to the command basename.
      cmd = $0
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", cmd)
      base = cmd
      sub(/.*\//, "", base)
      parent[pid] = ppid
      size[pid] = rss
      known[pid] = 1
      hit = names_worker(base)
      if (!hit && (base ~ /^node/ || base ~ /^python/)) hit = argv_names_worker(argv[pid])
      if (hit) { root[pid] = 1; agents++ }
    }
    END {
      for (p in known) {
        q = p; depth = 0
        # Walk to a fleet root. The depth cap keeps a corrupt or cyclic
        # snapshot from spinning rather than trusting the table blindly.
        while (depth < 64) {
          if (q in root) { total += size[p]; procs++; break }
          if (!(q in parent)) break
          q = parent[q]
          depth++
        }
      }
      printf "%d %d %d\n", total / 1024, agents + 0, procs + 0
    }'
}

# Prints "<resident_mb> <agent_roots> <processes_in_those_trees>", or three
# unknowns. Whole process trees, because an agent's language runtimes and tool
# servers are memory the fleet caused and keeps. Resident sizes are summed per
# process, so pages shared between processes are counted more than once; the
# reported figure is therefore an upper bound on the fleet's true footprint and
# is labelled as resident in the report rather than presented as exact.
fm_capacity_probe_fleet() {
  local snapshot argv_snapshot out
  if [ -n "${FM_CAPACITY_FLEET_RSS_MB:-}" ] || [ -n "${FM_CAPACITY_FLEET_AGENTS:-}" ] \
     || [ -n "${FM_CAPACITY_FLEET_PROCS:-}" ]; then
    printf '%s %s %s\n' "${FM_CAPACITY_FLEET_RSS_MB:-unknown}" \
      "${FM_CAPACITY_FLEET_AGENTS:-unknown}" "${FM_CAPACITY_FLEET_PROCS:-unknown}"
    return 0
  fi
  snapshot=$(ps -A -o pid=,ppid=,rss=,comm= 2>/dev/null) || snapshot=
  # A ps that returns nothing did not observe an empty machine: this shell is
  # itself a process, so no output means the read failed.
  [ -n "$snapshot" ] || { printf '%s %s %s\n' unknown unknown unknown; return 0; }
  # The argv read is what makes an interpreter-launched adapter visible, so a ps
  # that cannot produce it leaves the fleet unmeasured rather than undercounted.
  argv_snapshot=$(ps -A -o pid=,args= 2>/dev/null) || argv_snapshot=
  [ -n "$argv_snapshot" ] || { printf '%s %s %s\n' unknown unknown unknown; return 0; }
  out=$(fm_capacity_fleet_totals "$snapshot" "$argv_snapshot") || out=
  [ -n "$out" ] || { printf '%s %s %s\n' unknown unknown unknown; return 0; }
  printf '%s\n' "$out"
}

fm_capacity_probe_cores() {
  local v
  if [ -n "${FM_CAPACITY_CORES:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_CORES"
    return 0
  fi
  v=$(sysctl -n hw.logicalcpu 2>/dev/null) || v=
  fm_capacity_is_uint "$v" && [ "$v" -gt 0 ] && { printf '%s\n' "$v"; return 0; }
  v=$(nproc 2>/dev/null) || v=
  fm_capacity_is_uint "$v" && [ "$v" -gt 0 ] && { printf '%s\n' "$v"; return 0; }
  v=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || v=
  fm_capacity_is_uint "$v" && [ "$v" -gt 0 ] && { printf '%s\n' "$v"; return 0; }
  printf '%s\n' unknown
}

fm_capacity_probe_load1() {
  local v
  if [ -n "${FM_CAPACITY_LOAD1:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_LOAD1"
    return 0
  fi
  # Darwin: "{ 273.79 241.60 202.13 }".
  v=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}') || v=
  fm_capacity_is_decimal "$v" && { printf '%s\n' "$v"; return 0; }
  # Linux: "0.52 0.58 0.59 1/1234 5678".
  if [ -r /proc/loadavg ]; then
    v=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || v=
    fm_capacity_is_decimal "$v" && { printf '%s\n' "$v"; return 0; }
  fi
  # Last resort. Rejected unless it parses as a plain decimal, so a locale that
  # prints "1,23" or a differently worded uptime yields unknown, not 1.
  v=$(uptime 2>/dev/null | sed -n 's/.*[Ll]oad average[s]*: *//p' | tr ',' ' ' | awk '{print $1}') || v=
  fm_capacity_is_decimal "$v" && { printf '%s\n' "$v"; return 0; }
  printf '%s\n' unknown
}

# Reduce anything that is not a usable reading to the explicit "unknown", so a
# nonsense value can never reach a numeric comparison. Real probes already
# validate their own output; this covers the environment overrides, which are
# supplied by hand. Failing to "unknown" is the safe direction: by default an
# unknown signal refuses, so a typo cannot buy a spawn it should not have.
fm_capacity_normalize() {
  local name=$1 kind=$2 value
  eval "value=\${$name}"
  case "$kind" in
    uint)
      fm_capacity_is_uint "$value" || value=unknown
      ;;
    positive-uint)
      { fm_capacity_is_uint "$value" && [ "$value" -gt 0 ]; } || value=unknown
      ;;
    decimal)
      fm_capacity_is_decimal "$value" || value=unknown
      ;;
    pressure)
      case "$value" in
        normal|warn|critical) : ;;
        *) value=unknown ;;
      esac
      ;;
  esac
  eval "$name=\$value"
}

fm_capacity_measure() {
  local swap fleet
  FM_CAPACITY_M_MEM_TOTAL_MB=$(fm_capacity_probe_mem_total_mb)
  FM_CAPACITY_M_MEM_FREE_MB=$(fm_capacity_probe_mem_free_mb)
  swap=$(fm_capacity_probe_swap_mb)
  read -r FM_CAPACITY_M_SWAP_TOTAL_MB FM_CAPACITY_M_SWAP_USED_MB <<EOF
$swap
EOF
  FM_CAPACITY_M_MEM_PRESSURE=$(fm_capacity_probe_mem_pressure)
  FM_CAPACITY_M_SWAPOUTS=$(fm_capacity_probe_swapouts)
  fleet=$(fm_capacity_probe_fleet)
  read -r FM_CAPACITY_M_FLEET_RSS_MB FM_CAPACITY_M_FLEET_AGENTS FM_CAPACITY_M_FLEET_PROCS <<EOF
$fleet
EOF
  FM_CAPACITY_M_CORES=$(fm_capacity_probe_cores)
  FM_CAPACITY_M_LOAD1=$(fm_capacity_probe_load1)

  # A machine reporting zero installed memory is not a reading, so total memory
  # and core count must be positive to count as measured at all.
  fm_capacity_normalize FM_CAPACITY_M_MEM_TOTAL_MB positive-uint
  fm_capacity_normalize FM_CAPACITY_M_MEM_FREE_MB uint
  fm_capacity_normalize FM_CAPACITY_M_SWAP_TOTAL_MB uint
  fm_capacity_normalize FM_CAPACITY_M_SWAP_USED_MB uint
  fm_capacity_normalize FM_CAPACITY_M_SWAPOUTS uint
  fm_capacity_normalize FM_CAPACITY_M_FLEET_RSS_MB uint
  fm_capacity_normalize FM_CAPACITY_M_FLEET_AGENTS uint
  fm_capacity_normalize FM_CAPACITY_M_FLEET_PROCS uint
  fm_capacity_normalize FM_CAPACITY_M_CORES positive-uint
  fm_capacity_normalize FM_CAPACITY_M_LOAD1 decimal
  fm_capacity_normalize FM_CAPACITY_M_MEM_PRESSURE pressure
}

# --- configuration ----------------------------------------------------------

fm_capacity_config_fail() {
  FM_CAPACITY_CONFIG_ERROR=$1
  return 1
}

# fm_capacity_load_config <config-dir>
# Applies defaults, then overlays config/spawn-capacity when present. Returns
# non-zero and sets FM_CAPACITY_CONFIG_ERROR for a malformed file.
fm_capacity_load_config() {
  local dir=${1:-} path line key value
  FM_CAPACITY_CONFIG_ERROR=""
  FM_CAPACITY_MODE=enforce
  FM_CAPACITY_MIN_FREE_MEMORY_MB=1024
  FM_CAPACITY_MAX_SWAP_USED_PCT=50
  FM_CAPACITY_MAX_MEMORY_PRESSURE=normal
  FM_CAPACITY_MAX_FLEET_MEMORY_PCT=40
  # Off by default: on the measured incident machine the 1m load average read
  # 299 while CPU usage was about 4.6 of 10 cores, because the load was
  # processes frozen on paging. Load is reported as corroborating evidence and
  # becomes a limit only when the operator sets a number here.
  FM_CAPACITY_LOAD_PER_CORE_MAX=off
  FM_CAPACITY_ON_UNKNOWN=refuse

  [ -n "$dir" ] || return 0
  path="$dir/$FM_CAPACITY_CONFIG_FILE"
  FM_CAPACITY_CONFIG_PATH=$path
  [ -e "$path" ] || return 0
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fm_capacity_config_fail "$path is not a regular file"
    return 1
  fi
  if [ ! -r "$path" ]; then
    fm_capacity_config_fail "$path is not readable"
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      *=*) : ;;
      *) fm_capacity_config_fail "$path: not a key = value line: $line"; return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$key" in
      mode)
        case "$value" in
          enforce|off) FM_CAPACITY_MODE=$value ;;
          *) fm_capacity_config_fail "$path: mode must be enforce or off, got '$value'"; return 1 ;;
        esac
        ;;
      min_free_memory_mb)
        if ! fm_capacity_is_uint "$value"; then
          fm_capacity_config_fail "$path: min_free_memory_mb must be an integer number of MB, got '$value'"
          return 1
        fi
        FM_CAPACITY_MIN_FREE_MEMORY_MB=$value
        ;;
      max_swap_used_pct)
        if [ "$value" != off ] && { ! fm_capacity_is_uint "$value" || [ "$value" -gt 100 ]; }; then
          fm_capacity_config_fail "$path: max_swap_used_pct must be an integer 0-100 or off, got '$value'"
          return 1
        fi
        FM_CAPACITY_MAX_SWAP_USED_PCT=$value
        ;;
      max_memory_pressure)
        case "$value" in
          normal|warn|ignore) FM_CAPACITY_MAX_MEMORY_PRESSURE=$value ;;
          *) fm_capacity_config_fail "$path: max_memory_pressure must be normal, warn, or ignore, got '$value'"; return 1 ;;
        esac
        ;;
      max_fleet_memory_pct)
        if [ "$value" != off ] && { ! fm_capacity_is_uint "$value" || [ "$value" -gt 100 ]; }; then
          fm_capacity_config_fail "$path: max_fleet_memory_pct must be an integer 0-100 or off, got '$value'"
          return 1
        fi
        FM_CAPACITY_MAX_FLEET_MEMORY_PCT=$value
        ;;
      load_per_core_max)
        if [ "$value" != off ] && { ! fm_capacity_is_decimal "$value" || ! fm_capacity_gt "$value" 0; }; then
          fm_capacity_config_fail "$path: load_per_core_max must be a positive decimal or off, got '$value'"
          return 1
        fi
        FM_CAPACITY_LOAD_PER_CORE_MAX=$value
        ;;
      on_unknown)
        case "$value" in
          refuse|allow) FM_CAPACITY_ON_UNKNOWN=$value ;;
          *) fm_capacity_config_fail "$path: on_unknown must be refuse or allow, got '$value'"; return 1 ;;
        esac
        ;;
      *)
        fm_capacity_config_fail "$path: unknown key '$key'"
        return 1
        ;;
    esac
  done < "$path"
  return 0
}

# --- evaluation -------------------------------------------------------------

fm_capacity_row() {
  FM_CAPACITY_ROWS="${FM_CAPACITY_ROWS}${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4}"$'\n'
}

# fm_capacity_evaluate <config-dir>
# Measures, applies the configured limits, and sets FM_CAPACITY_ROWS (signal,
# measured, wanted, verdict) plus FM_CAPACITY_SUMMARY. The decision itself is
# the return status: 0 when there is headroom, 1 when there is not.
# Rows are emitted binding-signals-first, memory before CPU, because that is the
# order in which this machine actually runs out.
fm_capacity_evaluate() {
  local dir=${1:-} over="" unknown="" pct measured wanted per_core
  FM_CAPACITY_ROWS=""
  FM_CAPACITY_SUMMARY=""
  fm_capacity_measure
  if ! fm_capacity_load_config "$dir"; then
    FM_CAPACITY_SUMMARY="capacity settings are malformed: $FM_CAPACITY_CONFIG_ERROR"
    return 1
  fi

  if [ "$FM_CAPACITY_MODE" = off ]; then
    FM_CAPACITY_SUMMARY="capacity checking is switched off in ${FM_CAPACITY_CONFIG_PATH:-config/$FM_CAPACITY_CONFIG_FILE}"
    return 0
  fi

  # 1. Free memory: what a new agent runtime can actually claim.
  wanted="at least $(fm_capacity_gb "$FM_CAPACITY_MIN_FREE_MEMORY_MB") free"
  if [ "$FM_CAPACITY_M_MEM_FREE_MB" = unknown ]; then
    fm_capacity_row "free memory" "unknown (could not read memory)" "$wanted" unknown
    unknown="$unknown memory"
  else
    measured=$(fm_capacity_gb "$FM_CAPACITY_M_MEM_FREE_MB")
    if [ "$FM_CAPACITY_M_MEM_TOTAL_MB" != unknown ]; then
      pct=$(fm_capacity_pct "$FM_CAPACITY_M_MEM_FREE_MB" "$FM_CAPACITY_M_MEM_TOTAL_MB") || pct=
      [ -z "$pct" ] || measured="$measured of $(fm_capacity_gb "$FM_CAPACITY_M_MEM_TOTAL_MB") installed (${pct}%)"
    fi
    if [ "$FM_CAPACITY_M_MEM_FREE_MB" -lt "$FM_CAPACITY_MIN_FREE_MEMORY_MB" ]; then
      fm_capacity_row "free memory" "$measured" "$wanted" OVER
      over="$over memory"
    else
      fm_capacity_row "free memory" "$measured" "$wanted" ok
    fi
  fi

  # 2. Swap in use: the machine's own record that it already ran out of memory.
  if [ "$FM_CAPACITY_MAX_SWAP_USED_PCT" = off ]; then
    fm_capacity_row "swap in use" "not checked" "not checked" skipped
  elif [ "$FM_CAPACITY_M_SWAP_USED_MB" = unknown ] || [ "$FM_CAPACITY_M_SWAP_TOTAL_MB" = unknown ]; then
    fm_capacity_row "swap in use" "unknown (could not read swap)" \
      "at most ${FM_CAPACITY_MAX_SWAP_USED_PCT}% of swap used" unknown
    unknown="$unknown swap"
  elif [ "$FM_CAPACITY_M_SWAP_TOTAL_MB" -eq 0 ]; then
    # A real answer, not a failed read: with no swap configured, running out of
    # memory surfaces as an out-of-memory kill instead, which the free-memory
    # and pressure signals above and below already cover.
    fm_capacity_row "swap in use" "no swap configured on this machine" \
      "at most ${FM_CAPACITY_MAX_SWAP_USED_PCT}% of swap used" ok
  else
    pct=$(fm_capacity_pct "$FM_CAPACITY_M_SWAP_USED_MB" "$FM_CAPACITY_M_SWAP_TOTAL_MB")
    measured="$(fm_capacity_gb "$FM_CAPACITY_M_SWAP_USED_MB") of $(fm_capacity_gb "$FM_CAPACITY_M_SWAP_TOTAL_MB") swap (${pct}%)"
    [ "$FM_CAPACITY_M_SWAPOUTS" = unknown ] \
      || measured="$measured, $FM_CAPACITY_M_SWAPOUTS swapouts since boot"
    if [ "$pct" -gt "$FM_CAPACITY_MAX_SWAP_USED_PCT" ]; then
      fm_capacity_row "swap in use" "$measured" \
        "at most ${FM_CAPACITY_MAX_SWAP_USED_PCT}% of swap used" OVER
      over="$over swap"
    else
      fm_capacity_row "swap in use" "$measured" \
        "at most ${FM_CAPACITY_MAX_SWAP_USED_PCT}% of swap used" ok
    fi
  fi

  # 3. The kernel's own instantaneous memory verdict.
  if [ "$FM_CAPACITY_MAX_MEMORY_PRESSURE" = ignore ]; then
    fm_capacity_row "memory pressure" "$FM_CAPACITY_M_MEM_PRESSURE" "not checked" skipped
  else
    wanted="$FM_CAPACITY_MAX_MEMORY_PRESSURE or better"
    case "$FM_CAPACITY_M_MEM_PRESSURE" in
      unknown)
        fm_capacity_row "memory pressure" "unknown (not published by this platform)" \
          "$wanted" unknown
        unknown="$unknown pressure"
        ;;
      normal)
        fm_capacity_row "memory pressure" normal "$wanted" ok
        ;;
      warn)
        if [ "$FM_CAPACITY_MAX_MEMORY_PRESSURE" = normal ]; then
          fm_capacity_row "memory pressure" "warn (the kernel is reclaiming memory)" "$wanted" OVER
          over="$over pressure"
        else
          fm_capacity_row "memory pressure" warn "$wanted" ok
        fi
        ;;
      *)
        fm_capacity_row "memory pressure" \
          "$FM_CAPACITY_M_MEM_PRESSURE (the kernel is reclaiming memory)" "$wanted" OVER
        over="$over pressure"
        ;;
    esac
  fi

  # 4. What firstmate's own agents hold. Weighed by memory, not by headcount,
  #    because a paused agent still holds every page it allocated.
  if [ "$FM_CAPACITY_MAX_FLEET_MEMORY_PCT" = off ]; then
    fm_capacity_row "fleet memory" "not checked" "not checked" skipped
  elif [ "$FM_CAPACITY_M_FLEET_RSS_MB" = unknown ] || [ "$FM_CAPACITY_M_MEM_TOTAL_MB" = unknown ]; then
    fm_capacity_row "fleet memory" "unknown (could not read process memory)" \
      "at most ${FM_CAPACITY_MAX_FLEET_MEMORY_PCT}% of installed memory" unknown
    unknown="$unknown fleet"
  else
    pct=$(fm_capacity_pct "$FM_CAPACITY_M_FLEET_RSS_MB" "$FM_CAPACITY_M_MEM_TOTAL_MB") || pct=0
    measured="$(fm_capacity_gb "$FM_CAPACITY_M_FLEET_RSS_MB") resident across $FM_CAPACITY_M_FLEET_AGENTS agents"
    measured="$measured and their $FM_CAPACITY_M_FLEET_PROCS processes (${pct}% of installed memory)"
    if [ "$pct" -gt "$FM_CAPACITY_MAX_FLEET_MEMORY_PCT" ]; then
      fm_capacity_row "fleet memory" "$measured" \
        "at most ${FM_CAPACITY_MAX_FLEET_MEMORY_PCT}% of installed memory" OVER
      over="$over fleet"
    else
      fm_capacity_row "fleet memory" "$measured" \
        "at most ${FM_CAPACITY_MAX_FLEET_MEMORY_PCT}% of installed memory" ok
    fi
  fi

  # 5. Load average. Corroborating evidence, printed always. It is a limit only
  #    when the operator set one, because a high load average does not
  #    distinguish CPU demand from processes frozen on paging.
  if [ "$FM_CAPACITY_M_LOAD1" = unknown ] || [ "$FM_CAPACITY_M_CORES" = unknown ]; then
    measured="unknown (load $FM_CAPACITY_M_LOAD1 over $FM_CAPACITY_M_CORES cores)"
    per_core=
  else
    per_core=$(awk -v a="$FM_CAPACITY_M_LOAD1" -v b="$FM_CAPACITY_M_CORES" \
      'BEGIN { if (b + 0 == 0) exit 1; printf "%.2f\n", (a + 0) / (b + 0) }') || per_core=
    measured="${per_core:-unknown} per core (1m load $FM_CAPACITY_M_LOAD1 over $FM_CAPACITY_M_CORES cores)"
  fi
  if [ "$FM_CAPACITY_LOAD_PER_CORE_MAX" = off ]; then
    fm_capacity_row "load per core" "$measured" \
      "context only - load also rises when memory is paging" context
  elif [ -z "$per_core" ]; then
    fm_capacity_row "load per core" "$measured" \
      "at most $FM_CAPACITY_LOAD_PER_CORE_MAX" unknown
    unknown="$unknown load"
  elif fm_capacity_gt "$per_core" "$FM_CAPACITY_LOAD_PER_CORE_MAX"; then
    fm_capacity_row "load per core" "$measured" "at most $FM_CAPACITY_LOAD_PER_CORE_MAX" OVER
    over="$over load"
  else
    fm_capacity_row "load per core" "$measured" "at most $FM_CAPACITY_LOAD_PER_CORE_MAX" ok
  fi

  if [ -n "$over" ]; then
    FM_CAPACITY_SUMMARY="the machine has no headroom left on $(fm_capacity_join "$over")"
    return 1
  fi
  if [ -n "$unknown" ] && [ "$FM_CAPACITY_ON_UNKNOWN" = refuse ]; then
    FM_CAPACITY_SUMMARY="$(fm_capacity_join "$unknown") could not be measured, so headroom is unproven"
    return 1
  fi
  if [ -n "$unknown" ]; then
    FM_CAPACITY_SUMMARY="headroom available, though $(fm_capacity_join "$unknown") could not be measured and on_unknown is allow"
  else
    FM_CAPACITY_SUMMARY="headroom available"
  fi
  return 0
}

# --- rendering --------------------------------------------------------------

# fm_capacity_render_rows [indent]
# One aligned line per signal: what was measured and what was wanted.
fm_capacity_render_rows() {
  local indent=${1:-  }
  [ -n "$FM_CAPACITY_ROWS" ] || return 0
  printf '%s' "$FM_CAPACITY_ROWS" | awk -F '\t' -v indent="$indent" '
    { if (length($1) > w) w = length($1) }
    { l[NR] = $1; m[NR] = $2; g[NR] = $3; v[NR] = $4 }
    END {
      for (i = 1; i <= NR; i++)
        printf "%s%-*s  measured %s | wanted %s  [%s]\n", indent, w, l[i], m[i], g[i], v[i]
    }'
}

# fm_capacity_refusal_text <what-was-declined>
# The complete operator-facing refusal: the numbers, the limits, the fact that
# nothing running was touched, and the two ways to proceed anyway.
fm_capacity_refusal_text() {
  local what=${1:-this work} path
  path=${FM_CAPACITY_CONFIG_PATH:-config/$FM_CAPACITY_CONFIG_FILE}
  printf 'error: refusing to start %s - %s.\n' "$what" "$FM_CAPACITY_SUMMARY"
  fm_capacity_render_rows '  '
  printf '%s\n' '  Nothing already running was touched: this only declines new work.'
  printf '  To proceed anyway, raise the limits or set mode = off in %s.\n' "$path"
}

# fm_capacity_guard <config-dir> <what-was-declined>
# The single call a spawn path makes. Prints the full refusal to stderr and
# returns 1 when there is no headroom; silent and 0 when there is.
fm_capacity_guard() {
  local dir=${1:-} what=${2:-this work}
  if fm_capacity_evaluate "$dir"; then
    return 0
  fi
  fm_capacity_refusal_text "$what" >&2
  return 1
}
