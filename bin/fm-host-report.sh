#!/usr/bin/env bash
# Host report for Firstmate operational homes.
#
# Usage:
#   fm-host-report.sh [--line]
#
# Runs on a host against the home in FM_HOME and prints a compact, stable,
# sectioned report:
#   - host name
#   - uptime and load averages with CPU count
#   - free disk on the home's filesystem
#   - memory summary (macOS and Linux)
#   - this code root's revision (short sha, branch or detached, ahead/behind
#     origin/main without fetching)
#   - live agent processes (claude, codex, agy, opencode, herdr, fm-watch)
#     with pid, elapsed time and a truncated command
#   - supervision beacon age from state/.last-watcher-beat
#   - the home's work counts and under-way ids from bin/fm-fleet-snapshot.sh --json
#   - the last 5 lines of each state/*.status
#
# Every probe is bounded; a failed probe prints 'unavailable: <reason>' and
# the report continues.
# With --line, prints a compact single-line summary intended for /bearings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

PROBE_TIMEOUT=${FM_HOST_REPORT_TIMEOUT:-5}
SNAPSHOT_TIMEOUT=${FM_HOST_REPORT_SNAPSHOT_TIMEOUT:-10}

LINE_MODE=0
case "${1:-}" in
  -h|--help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --line|--compact)
    LINE_MODE=1
    ;;
  "") ;;
  *)
    echo "error: unknown argument: $1" >&2
    exit 2
    ;;
esac

# --- Probe 1: Host name ----------------------------------------------------
probe_hostname() {
  local h
  if h=$(fm_run_timed "$PROBE_TIMEOUT" hostname 2>/dev/null) && [ -n "$h" ]; then
    printf '%s\n' "$h"
  elif h=$(fm_run_timed "$PROBE_TIMEOUT" uname -n 2>/dev/null) && [ -n "$h" ]; then
    printf '%s\n' "$h"
  else
    printf 'unavailable: hostname failed\n'
  fi
}

# --- Probe 2: CPU count & Uptime / Load averages ---------------------------
probe_cpus() {
  local n
  if n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) && [ -n "$n" ]; then
    printf '%s\n' "$n"
  elif n=$(nproc 2>/dev/null) && [ -n "$n" ]; then
    printf '%s\n' "$n"
  elif n=$(sysctl -n hw.ncpu 2>/dev/null) && [ -n "$n" ]; then
    printf '%s\n' "$n"
  else
    printf 'unknown\n'
  fi
}

probe_uptime() {
  local up cpus
  cpus=$(probe_cpus)
  if up=$(fm_run_timed "$PROBE_TIMEOUT" uptime 2>/dev/null) && [ -n "$up" ]; then
    # Normalize uptime output: extract load averages
    local loads
    loads=$(printf '%s\n' "$up" | sed -E 's/.*load averages?:[[:space:]]*//; s/[[:space:]]+/ /g')
    local up_time
    up_time=$(printf '%s\n' "$up" | sed -E 's/^[[:space:]]*[0-9:]+[[:space:]]+up[[:space:]]+//; s/,[[:space:]]*[0-9]+[[:space:]]+user.*//')
    if [ "$cpus" != unknown ]; then
      printf 'up %s, load averages: %s (%s CPUs)\n' "$up_time" "$loads" "$cpus"
    else
      printf 'up %s, load averages: %s\n' "$up_time" "$loads"
    fi
  else
    printf 'unavailable: uptime failed\n'
  fi
}

probe_load_only() {
  local up cpus
  cpus=$(probe_cpus)
  if up=$(fm_run_timed "$PROBE_TIMEOUT" uptime 2>/dev/null) && [ -n "$up" ]; then
    local loads
    loads=$(printf '%s\n' "$up" | sed -E 's/.*load averages?:[[:space:]]*//; s/[[:space:]]+/ /g')
    if [ "$cpus" != unknown ]; then
      printf '%s (%s CPUs)' "$loads" "$cpus"
    else
      printf '%s' "$loads"
    fi
  else
    printf 'unavailable'
  fi
}

# --- Probe 3: Disk free ----------------------------------------------------
probe_disk() {
  local df_out avail size cap
  if df_out=$(fm_run_timed "$PROBE_TIMEOUT" df -Ph "$FM_HOME" 2>/dev/null) && [ -n "$df_out" ]; then
    avail=$(printf '%s\n' "$df_out" | awk 'NR>1 {print $4}' | tail -1)
    size=$(printf '%s\n' "$df_out" | awk 'NR>1 {print $2}' | tail -1)
    cap=$(printf '%s\n' "$df_out" | awk 'NR>1 {print $5}' | tail -1)
    if [ -n "$avail" ] && [ -n "$size" ]; then
      printf '%s free of %s (%s used)\n' "$avail" "$size" "$cap"
    else
      printf 'unavailable: unparseable df output\n'
    fi
  else
    printf 'unavailable: df failed\n'
  fi
}

probe_disk_avail_only() {
  local df_out avail
  if df_out=$(fm_run_timed "$PROBE_TIMEOUT" df -Ph "$FM_HOME" 2>/dev/null) && [ -n "$df_out" ]; then
    avail=$(printf '%s\n' "$df_out" | awk 'NR>1 {print $4}' | tail -1)
    if [ -n "$avail" ]; then
      printf '%s' "$avail"
      return
    fi
  fi
  printf 'unknown'
}

# --- Probe 4: Memory summary -----------------------------------------------
probe_memory() {
  local out
  # Linux free -h
  if command -v free >/dev/null 2>&1; then
    if out=$(fm_run_timed "$PROBE_TIMEOUT" free -h 2>/dev/null) && [ -n "$out" ]; then
      local mem_line
      mem_line=$(printf '%s\n' "$out" | awk '/^Mem:/ {print $3 " used / " $2 " total (" $7 " available)"}')
      if [ -n "$mem_line" ]; then
        printf '%s\n' "$mem_line"
        return
      fi
    fi
  fi
  # macOS top PhysMem
  if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v top >/dev/null 2>&1; then
    if out=$(fm_run_timed "$PROBE_TIMEOUT" top -l 1 -s 0 -n 0 2>/dev/null) && [ -n "$out" ]; then
      local phys
      phys=$(printf '%s\n' "$out" | awk '/PhysMem:/ {sub(/^[[:space:]]*PhysMem:[[:space:]]*/, ""); print $0}')
      if [ -n "$phys" ]; then
        printf '%s\n' "$phys"
        return
      fi
    fi
  fi
  # macOS vm_stat fallback
  if command -v vm_stat >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
    local memsize
    memsize=$(sysctl -n hw.memsize 2>/dev/null || true)
    if [ -n "$memsize" ] && [ "$memsize" -gt 0 ] 2>/dev/null; then
      local mem_gb=$((memsize / 1073741824))
      printf '%s GB total (vm_stat available)\n' "$mem_gb"
      return
    fi
  fi
  # Linux /proc/meminfo fallback
  if [ -r /proc/meminfo ]; then
    local total_kb avail_kb
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)
    avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
    if [ -n "$total_kb" ] && [ -n "$avail_kb" ]; then
      printf '%s MB total / %s MB available\n' "$((total_kb / 1024))" "$((avail_kb / 1024))"
      return
    fi
  fi
  printf 'unavailable: memory probe unsupported or failed\n'
}

# --- Probe 5: Code root revision -------------------------------------------
probe_revision() {
  if ! git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'unavailable: not a git worktree\n'
    return
  fi
  local sha branch ahead_behind ahead behind diff_desc
  if ! sha=$(git -C "$FM_ROOT" rev-parse --short HEAD 2>/dev/null) || [ -z "$sha" ]; then
    printf 'unavailable: git rev-parse failed\n'
    return
  fi
  branch=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached")
  ahead_behind=$(git -C "$FM_ROOT" rev-list --left-right --count HEAD...origin/main 2>/dev/null || true)
  if [ -n "$ahead_behind" ]; then
    ahead=$(printf '%s\n' "$ahead_behind" | awk '{print $1}')
    behind=$(printf '%s\n' "$ahead_behind" | awk '{print $2}')
    if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
      diff_desc="up to date with origin/main"
    else
      diff_desc="ahead $ahead, behind $behind vs origin/main"
    fi
  else
    diff_desc="origin/main not found"
  fi
  printf '%s (%s, %s)\n' "$sha" "$branch" "$diff_desc"
}

# --- Probe 6: Live agent processes -----------------------------------------
# Matches: claude, codex, agy, opencode, herdr, fm-watch
probe_agents() {
  local ps_out
  if ! ps_out=$(fm_run_timed "$PROBE_TIMEOUT" ps -eo pid,etime,command 2>/dev/null) || [ -z "$ps_out" ]; then
    printf 'unavailable: ps failed\n'
    return
  fi
  printf '%s\n' "$ps_out" | awk '
    NR > 1 {
      pid = $1;
      etime = $2;
      $1 = ""; $2 = "";
      sub(/^[[:space:]]+/, "", $0);
      cmd = $0;
      # Match live agents
      if (cmd ~ /(^|[ \/])(claude|codex|agy|opencode|herdr|fm-watch)(\.sh)?([ \t]|$)/) {
        # Avoid matching this script or grep/awk
        if (cmd !~ /(^|[ \/])(fm-host-report|grep|awk)([ \t]|$)/) {
          short_cmd = substr(cmd, 1, 80);
          gsub(/[[:cntrl:]]/, " ", short_cmd);
          printf "  %s %s %s\n", pid, etime, short_cmd;
          matched++;
        }
      }
    }
    END {
      if (matched == 0) {
        print "  none";
      }
    }
  '
}

count_agents() {
  local ps_out
  if ! ps_out=$(fm_run_timed "$PROBE_TIMEOUT" ps -eo pid,command 2>/dev/null) || [ -z "$ps_out" ]; then
    printf '0'
    return
  fi
  printf '%s\n' "$ps_out" | awk '
    NR > 1 {
      cmd = $0;
      if (cmd ~ /(^|[ \/])(claude|codex|agy|opencode|herdr|fm-watch)(\.sh)?([ \t]|$)/) {
        if (cmd !~ /(^|[ \/])(fm-host-report|grep|awk)([ \t]|$)/) {
          matched++;
        }
      }
    }
    END {
      printf "%d", matched;
    }
  '
}

# --- Probe 7: Supervision beacon age ---------------------------------------
probe_beacon() {
  local beat="$STATE/.last-watcher-beat"
  if [ ! -f "$beat" ]; then
    printf 'absent (state/.last-watcher-beat not found)\n'
    return
  fi
  local mtime now age
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$beat" 2>/dev/null || true)
  else
    mtime=$(stat -c %Y "$beat" 2>/dev/null || true)
  fi
  case "$mtime" in
    ''|*[!0-9]*)
      printf 'unavailable: stat failed\n'
      return
      ;;
  esac
  now=$(date +%s)
  age=$((now - mtime))
  [ "$age" -ge 0 ] || age=0
  printf '%ss ago\n' "$age"
}

probe_beacon_age_only() {
  local beat="$STATE/.last-watcher-beat"
  if [ ! -f "$beat" ]; then
    printf 'absent'
    return
  fi
  local mtime now age
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$beat" 2>/dev/null || true)
  else
    mtime=$(stat -c %Y "$beat" 2>/dev/null || true)
  fi
  case "$mtime" in
    ''|*[!0-9]*)
      printf 'unknown'
      return
      ;;
  esac
  now=$(date +%s)
  age=$((now - mtime))
  [ "$age" -ge 0 ] || age=0
  printf '%ss' "$age"
}

# --- Probe 8: Work counts and under-way ids --------------------------------
probe_work() {
  local snap
  if ! snap=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
        fm_run_timed "$SNAPSHOT_TIMEOUT" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) \
     || [ -z "$snap" ]; then
    printf 'unavailable: fleet snapshot timed out or failed\n'
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'unavailable: jq not found\n'
    return
  fi
  local underway task_count in_flight queued done_count
  underway=$(printf '%s' "$snap" | jq -r '[.tasks[].id] | if length == 0 then "none" else join(", ") end' 2>/dev/null || echo "unknown")
  task_count=$(printf '%s' "$snap" | jq -r '.tasks | length' 2>/dev/null || echo "0")
  in_flight=$(printf '%s' "$snap" | jq -r '([.backlog.records[]? | select(.state == "in_flight")] | length)' 2>/dev/null || echo "0")
  queued=$(printf '%s' "$snap" | jq -r '([.backlog.records[]? | select(.state == "queued")] | length)' 2>/dev/null || echo "0")
  done_count=$(printf '%s' "$snap" | jq -r '([.backlog.records[]? | select(.state == "done")] | length)' 2>/dev/null || echo "0")

  printf 'Under-way IDs: %s\n' "$underway"
  printf 'Counts: live tasks: %s; backlog: %s in-flight, %s queued, %s done\n' \
    "$task_count" "$in_flight" "$queued" "$done_count"
}

# --- Probe 9: Last 5 lines of each state/*.status --------------------------
probe_status_logs() {
  local count=0
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    local id
    id=$(basename "$f" .status)
    printf '  %s.status (last 5 lines):\n' "$id"
    tail -n 5 "$f" 2>/dev/null | sed 's/^/    /' || true
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    printf '  none\n'
  fi
}

# --- Output generation -----------------------------------------------------

if [ "$LINE_MODE" -eq 1 ]; then
  # Compact single-line output:
  # reachable, load: <load>, <disk_free> free, <agents_count> agent(s), <rev>, beacon: <beacon>
  load_str=$(probe_load_only)
  disk_str=$(probe_disk_avail_only)
  agent_count=$(count_agents)
  rev_str=$(probe_revision)
  beacon_str=$(probe_beacon_age_only)
  printf 'reachable, load: %s, %s free, %s agent(s), %s, beacon: %s\n' \
    "$load_str" "$disk_str" "$agent_count" "$rev_str" "$beacon_str"
  exit 0
fi

cat <<EOF
# Host Report: $(probe_hostname)
Home: $FM_HOME
Code root: $FM_ROOT

## System
Uptime: $(probe_uptime)
Disk: $(probe_disk)
Memory: $(probe_memory)

## Revision
Revision: $(probe_revision)

## Supervision
Beacon: $(probe_beacon)

## Live Agents
$(probe_agents)

## Work
$(probe_work)

## Status Logs
$(probe_status_logs)
EOF
exit 0
