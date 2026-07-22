#!/usr/bin/env bash
# fm-lane-governor.sh - fail-closed pre-spawn capacity and memory guard.
#
# Usage:
#   fm-lane-governor.sh acquire <lease-id> [--kind <ship|scout|secondmate>] [--count <n>] [--holder-pid <pid>]
#   fm-lane-governor.sh release <lease-id> [--holder-pid <pid>]
#   fm-lane-governor.sh check [--kind <ship|scout|secondmate>] [--count <n>]
#   fm-lane-governor.sh memwatch
#
# The governor is a spawn-time guard, not a supervisor.
# It refuses new spawns when the current home is at its lane capacity, when swap
# or available RAM crosses the configured lines, or when a likely orphaned
# harness process belonging to this home is still alive under a launchd-reparented zsh.
# Available RAM means reclaimable memory, not just the free list: on Linux it is
# MemAvailable, and on macOS it is free + speculative + inactive + purgeable pages,
# so the same threshold means the same thing on both platforms.
# A harness process is never called an orphan when it is an ancestor of this
# governor run or when it sits in a worktree or home recorded for a live task.
# Lane capacity governs transient ship/scout workers only: persistent secondmates
# keep a kind=secondmate meta in the main home permanently and are excluded from
# the active count, and a --kind secondmate acquire/check bypasses the capacity gate
# and lease entirely (only the memory and orphan checks apply to its provisioning).
# Completed workers are reported for cleanup but do not consume lane capacity,
# because PR-ready and report-ready work may legitimately wait on approval.
# Leases held past FM_LANE_LEASE_TTL_SECONDS, or whose holder pid is dead, are reaped.
# Orphaned harnesses under another home are reported but never block this home's spawns.
#
# Runtime state lives under state/.lane-governor/ and is volatile.
# The defaults live here so no local config file is required:
#   FM_LANE_MAX_CONCURRENT=4
#   FM_LANE_MAX_SWAP_GB=24
#   FM_LANE_MIN_AVAILABLE_RAM_GB=1
#   FM_LANE_LEASE_TTL_SECONDS=600
#   FM_LANE_ORPHAN_CHECK=1
# Set FM_LANE_GOVERNOR=0 to bypass the guard deliberately.
# Set either memory threshold to 0 to disable that threshold.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LEASE_ROOT="$STATE/.lane-governor"
LEASE_DIR="$LEASE_ROOT/leases"
LOCK="$LEASE_ROOT.lock"

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

LANE_LOCK_HELD=0
lane_governor_cleanup() {
  [ "$LANE_LOCK_HELD" -eq 0 ] || fm_lock_release "$LOCK" 2>/dev/null || true
}
trap lane_governor_cleanup EXIT

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

err() {
  printf 'LANE_GOVERNOR: %s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

disabled() {
  case "${FM_LANE_GOVERNOR:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {  # <value>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

validate_nonnegative_int() {  # <label> <value>
  case "$2" in
    ''|*[!0-9]*)
      err "$1 must be a non-negative integer"
      exit 2
      ;;
  esac
}

validate_positive_int() {  # <label> <value>
  validate_nonnegative_int "$1" "$2"
  [ "$2" -gt 0 ] || { err "$1 must be greater than zero"; exit 2; }
}

validate_decimal() {  # <label> <value>
  case "$2" in
    ''|*[!0-9.]*|*.*.*)
      err "$1 must be a non-negative number"
      exit 2
      ;;
  esac
}

gb_to_mb() {  # <gb>
  awk -v gb="$1" 'BEGIN { printf "%.0f\n", gb * 1024 }'
}

mb_to_gb() {  # <mb>
  awk -v mb="$1" 'BEGIN { printf "%.1fGB\n", mb / 1024 }'
}

now_epoch() {
  date +%s
}

path_mtime_epoch() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

safe_lease_id() {
  case "$1" in
    ''|*/*|*[!A-Za-z0-9._=-]*) return 1 ;;
    *) return 0 ;;
  esac
}

lease_path() {  # <lease-id>
  safe_lease_id "$1" || return 1
  printf '%s/%s.lease\n' "$LEASE_DIR" "$1"
}

meta_value() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

crew_state_for_id() {  # <id>
  local id=$1 out line state
  if [ -n "${FM_LANE_CREW_STATE_FILE:-}" ] && [ -f "$FM_LANE_CREW_STATE_FILE" ]; then
    state=$(grep "^$id=" "$FM_LANE_CREW_STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$state" ] && { printf '%s\n' "$state"; return 0; }
  fi
  out=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  line=$(printf '%s\n' "$out" | head -1)
  case "$line" in
    state:\ *)
      state=${line#state: }
      state=${state%% *}
      [ -n "$state" ] && { printf '%s\n' "$state"; return 0; }
      ;;
  esac
  printf 'unknown\n'
}

ACTIVE_WORKERS=0
COMPLETED_WORKERS=
worker_inventory() {  # [<exclude-id>]
  local exclude=${1:-} meta id kind state
  ACTIVE_WORKERS=0
  COMPLETED_WORKERS=
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" = "$exclude" ] && continue
    kind=$(meta_value "$meta" kind)
    [ "$kind" = secondmate ] && continue
    state=$(crew_state_for_id "$id")
    case "$state" in
      done|failed)
        if [ -n "$COMPLETED_WORKERS" ]; then
          COMPLETED_WORKERS="$COMPLETED_WORKERS, $id=$state"
        else
          COMPLETED_WORKERS="$id=$state"
        fi
        ;;
      *)
        ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
        ;;
    esac
  done
}

lease_field() {  # <file> <key>
  meta_value "$1" "$2"
}

LEASE_COUNT=0
reap_and_count_leases() {
  local file pid count created age ttl now
  LEASE_COUNT=0
  ttl=${FM_LANE_LEASE_TTL_SECONDS:-600}
  case "$ttl" in ''|*[!0-9]*) ttl=600 ;; esac
  mkdir -p "$LEASE_DIR" || return 1
  for file in "$LEASE_DIR"/*.lease; do
    [ -f "$file" ] || continue
    pid=$(lease_field "$file" holder_pid)
    count=$(lease_field "$file" count)
    created=$(lease_field "$file" created)
    case "$count" in ''|*[!0-9]*|0) count=1 ;; esac
    case "$created" in ''|*[!0-9]*) created=$(path_mtime_epoch "$file" || printf '0') ;; esac
    now=$(now_epoch)
    age=$(( now - created ))
    [ "$age" -lt 0 ] && age=0
    if ! fm_pid_alive "$pid"; then
      rm -f "$file" 2>/dev/null || true
      continue
    fi
    if [ "$ttl" -gt 0 ] && [ "$age" -ge "$ttl" ]; then
      rm -f "$file" 2>/dev/null || true
      continue
    fi
    LEASE_COUNT=$((LEASE_COUNT + count))
  done
}

parse_unit_mb() {  # <value-with-unit>
  local raw=$1
  awk -v raw="$raw" '
    BEGIN {
      value = raw
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      unit = value
      gsub(/^[0-9.]+[[:space:]]*/, "", unit)
      gsub(/[[:space:]]+$/, "", unit)
      gsub(/[^0-9.].*$/, "", value)
      if (value == "") exit 1
      unit = toupper(unit)
      if (unit ~ /^G/) mult = 1024
      else if (unit ~ /^M/ || unit == "") mult = 1
      else if (unit ~ /^K/) mult = 1 / 1024
      else if (unit ~ /^B/) mult = 1 / 1024 / 1024
      else mult = 1
      printf "%.0f\n", value * mult
    }'
}

platform_name() {
  printf '%s\n' "${FM_LANE_PLATFORM:-$(uname)}"
}

vm_stat_text() {
  if [ -n "${FM_LANE_VM_STAT_FILE:-}" ]; then
    cat "$FM_LANE_VM_STAT_FILE" 2>/dev/null || true
    return 0
  fi
  command -v vm_stat >/dev/null 2>&1 || return 0
  vm_stat 2>/dev/null || true
}

swapusage_text() {
  if [ -n "${FM_LANE_SWAPUSAGE_FILE:-}" ]; then
    cat "$FM_LANE_SWAPUSAGE_FILE" 2>/dev/null || true
    return 0
  fi
  sysctl -n vm.swapusage 2>/dev/null || true
}

meminfo_path() {
  printf '%s\n' "${FM_LANE_MEMINFO_FILE:-/proc/meminfo}"
}

# Reclaimable memory on macOS, in MB, comparable in intent to Linux MemAvailable:
# the free list alone is routinely a few hundred MB on a healthy Mac because the
# kernel parks reclaimable memory on the inactive, speculative, and purgeable lists.
darwin_available_mb() {  # reads vm_stat output on stdin
  awk '
    function pages(v) { gsub(/[^0-9]/, "", v); return v + 0 }
    /page size of/ {
      line = $0
      sub(/.*page size of[[:space:]]*/, "", line)
      sub(/[^0-9].*$/, "", line)
      if (line != "") page_size = line + 0
    }
    /^Pages free:/ { free = pages($NF) }
    /^Pages speculative:/ { speculative = pages($NF) }
    /^Pages inactive:/ { inactive = pages($NF) }
    /^Pages purgeable:/ { purgeable = pages($NF) }
    END {
      if (page_size <= 0) exit 1
      printf "%.0f\n", (free + speculative + inactive + purgeable) * page_size / 1048576
    }'
}

MEMORY_AVAILABLE_MB=
SWAP_USED_MB=
memory_snapshot() {
  local vm_text swap_line meminfo mem_avail swap_total swap_free available used
  MEMORY_AVAILABLE_MB=
  SWAP_USED_MB=

  if [ -n "${FM_LANE_MEMORY_AVAILABLE_MB:-}" ] || [ -n "${FM_LANE_SWAP_USED_MB:-}" ]; then
    MEMORY_AVAILABLE_MB=${FM_LANE_MEMORY_AVAILABLE_MB:-}
    SWAP_USED_MB=${FM_LANE_SWAP_USED_MB:-}
    is_uint "$MEMORY_AVAILABLE_MB" || MEMORY_AVAILABLE_MB=
    is_uint "$SWAP_USED_MB" || SWAP_USED_MB=
    return 0
  fi

  if [ "$(platform_name)" = Darwin ]; then
    vm_text=$(vm_stat_text)
    if [ -n "$vm_text" ]; then
      available=$(printf '%s\n' "$vm_text" | darwin_available_mb || true)
      is_uint "$available" && MEMORY_AVAILABLE_MB=$available
    fi
    swap_line=$(swapusage_text)
    if [ -n "$swap_line" ]; then
      used=$(printf '%s\n' "$swap_line" \
        | sed -nE 's/.*used = ([0-9.]+[[:space:]]*[KMG]?)[[:space:]]*.*/\1/p' \
        | head -1 \
        | while IFS= read -r v; do parse_unit_mb "$v"; done)
      is_uint "$used" && SWAP_USED_MB=$used
    fi
    return 0
  fi

  meminfo=$(meminfo_path)
  if [ -r "$meminfo" ]; then
    mem_avail=$(awk '/^MemAvailable:/ { print $2; exit }' "$meminfo")
    swap_total=$(awk '/^SwapTotal:/ { print $2; exit }' "$meminfo")
    swap_free=$(awk '/^SwapFree:/ { print $2; exit }' "$meminfo")
    is_uint "$mem_avail" && MEMORY_AVAILABLE_MB=$((mem_avail / 1024))
    if is_uint "$swap_total" && is_uint "$swap_free"; then
      SWAP_USED_MB=$(((swap_total - swap_free) / 1024))
      [ "$SWAP_USED_MB" -lt 0 ] && SWAP_USED_MB=0
    fi
  fi
}

harness_from_process() {  # <comm> <args>
  local comm_base args=$2
  comm_base=$(basename -- "$1")
  comm_base=${comm_base#-}
  case "$comm_base" in
    *claude*) printf 'claude\n'; return 0 ;;
    *codex*) printf 'codex\n'; return 0 ;;
    *opencode*) printf 'opencode\n'; return 0 ;;
    *grok*) printf 'grok\n'; return 0 ;;
    pi) printf 'pi\n'; return 0 ;;
    node*|python*)
      case "$args" in
        *claude*) printf 'claude\n'; return 0 ;;
        *codex*) printf 'codex\n'; return 0 ;;
        *opencode*) printf 'opencode\n'; return 0 ;;
        *grok*) printf 'grok\n'; return 0 ;;
        *" pi "*|*/pi) printf 'pi\n'; return 0 ;;
      esac
      ;;
  esac
  return 1
}

process_cwd() {  # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  if [ -n "${FM_LANE_PROCESS_CWD_FILE:-}" ] && [ -f "$FM_LANE_PROCESS_CWD_FILE" ]; then
    grep "^$pid=" "$FM_LANE_PROCESS_CWD_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
    return 0
  fi
  if [ -r "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true
  fi
}

home_worktree_paths() {
  local clone
  if [ -n "${FM_LANE_HOME_WORKTREES_FILE:-}" ] && [ -f "$FM_LANE_HOME_WORKTREES_FILE" ]; then
    cat "$FM_LANE_HOME_WORKTREES_FILE" 2>/dev/null || true
    return 0
  fi
  command -v git >/dev/null 2>&1 || return 0
  [ -d "$PROJECTS" ] || return 0
  for clone in "$PROJECTS"/*; do
    [ -e "$clone/.git" ] || continue
    git -C "$clone" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{ $1=""; sub(/^ /,""); print }'
  done
}

orphan_belongs_to_home() {  # <cwd>
  local cwd=$1 wt
  [ -n "$cwd" ] || return 1
  case "$cwd/" in
    "$FM_HOME"/*) return 0 ;;
  esac
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    case "$cwd/" in
      "$wt"/*) return 0 ;;
    esac
  done <<EOF
$(home_worktree_paths)
EOF
  return 1
}

# The governor runs under the very agent it is guarding: a firstmate launched
# through nohup/setsid, or from a terminal whose session leader has exited, is
# itself a harness below a reparented zsh. Its own ancestry is never an orphan.
governor_ancestor_pids() {
  local pid=$$ next depth=0
  while [ "$depth" -lt 64 ]; do
    is_uint "$pid" || break
    [ "$pid" -gt 1 ] || break
    printf '%s\n' "$pid"
    next=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
    is_uint "$next" || break
    pid=$next
    depth=$((depth + 1))
  done
}

# Worktrees and homes recorded for a task that is not done or failed: a harness
# sitting in one of those is that task's live worker, not a leaked process.
live_task_paths() {
  local meta id state path
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    state=$(crew_state_for_id "$id")
    case "$state" in done|failed) continue ;; esac
    for path in "$(meta_value "$meta" worktree)" "$(meta_value "$meta" home)"; do
      [ -n "$path" ] && printf '%s\n' "$path"
    done
  done
}

path_under_any() {  # <path> <newline-separated-roots>
  local path=$1 roots=$2 root
  [ -n "$path" ] || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$path/" in
      "$root"/*) return 0 ;;
    esac
  done <<EOF
$roots
EOF
  return 1
}

detect_orphaned_harnesses() {
  local pid ppid comm args harness parent_ppid parent_comm parent_base row cwd ancestors
  case "${FM_LANE_ORPHAN_CHECK:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 0 ;;
  esac
  ancestors=" $(governor_ancestor_pids | tr '\n' ' ')"
  LC_ALL=C ps -axo pid=,ppid=,comm=,args= 2>/dev/null | while IFS= read -r row; do
    [ -n "$row" ] || continue
    # shellcheck disable=SC2086 # ps fields are intentionally tokenized into pid, ppid, comm, and rest.
    set -- $row
    pid=${1:-}
    ppid=${2:-}
    comm=${3:-}
    args=${row#"$pid"}
    args=${args#*"${ppid}"}
    args=${args#*"${comm}"}
    is_uint "$pid" || continue
    is_uint "$ppid" || continue
    case "$ancestors" in
      *" $pid "*) continue ;;
    esac
    harness=$(harness_from_process "$comm" "$args" || true)
    [ -n "$harness" ] || continue
    parent_ppid=$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d '[:space:]' || true)
    parent_comm=$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d '\n' || true)
    parent_base=$(basename -- "$parent_comm")
    parent_base=${parent_base#-}
    [ "$parent_ppid" = 1 ] || continue
    [ "$parent_base" = zsh ] || continue
    cwd=$(process_cwd "$pid")
    printf '%s\tpid=%s harness=%s parent_zsh=%s\n' "$cwd" "$pid" "$harness" "$ppid"
  done
}

memory_and_orphan_check() {
  local swap_limit_gb avail_min_gb swap_limit_mb avail_min_mb orphans
  local cwd desc line home_orphans foreign_orphans unresolved_orphans live_paths
  swap_limit_gb=${FM_LANE_MAX_SWAP_GB:-24}
  avail_min_gb=${FM_LANE_MIN_AVAILABLE_RAM_GB:-1}
  validate_decimal FM_LANE_MAX_SWAP_GB "$swap_limit_gb"
  validate_decimal FM_LANE_MIN_AVAILABLE_RAM_GB "$avail_min_gb"
  swap_limit_mb=$(gb_to_mb "$swap_limit_gb")
  avail_min_mb=$(gb_to_mb "$avail_min_gb")

  memory_snapshot
  if [ -n "$SWAP_USED_MB" ] && [ "$swap_limit_mb" -gt 0 ] && [ "$SWAP_USED_MB" -gt "$swap_limit_mb" ]; then
    die "refusing spawn: swap used $(mb_to_gb "$SWAP_USED_MB") exceeds limit $(mb_to_gb "$swap_limit_mb")"
  fi
  if [ -n "$MEMORY_AVAILABLE_MB" ] && [ "$avail_min_mb" -gt 0 ] && [ "$MEMORY_AVAILABLE_MB" -lt "$avail_min_mb" ]; then
    die "refusing spawn: available RAM $(mb_to_gb "$MEMORY_AVAILABLE_MB") is below minimum $(mb_to_gb "$avail_min_mb")"
  fi

  orphans=$(detect_orphaned_harnesses)
  if [ -n "$orphans" ]; then
    home_orphans=
    foreign_orphans=
    unresolved_orphans=
    live_paths=$(live_task_paths)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      cwd=${line%%$'\t'*}
      desc=${line#*$'\t'}
      [ -n "$desc" ] || continue
      if path_under_any "$cwd" "$live_paths"; then
        continue
      elif orphan_belongs_to_home "$cwd"; then
        home_orphans=${home_orphans:+$home_orphans;}$desc
      elif [ -z "$cwd" ]; then
        unresolved_orphans=${unresolved_orphans:+$unresolved_orphans;}$desc
      else
        foreign_orphans=${foreign_orphans:+$foreign_orphans;}$desc
      fi
    done <<EOF
$orphans
EOF
    if [ -n "$foreign_orphans" ]; then
      err "ignoring orphaned harness in another home (does not block this home): $foreign_orphans"
    fi
    if [ -n "$unresolved_orphans" ]; then
      err "orphaned harness with unresolvable cwd - not blocking, cannot attribute home: $unresolved_orphans"
    fi
    if [ -n "$home_orphans" ]; then
      die "refusing spawn: orphaned harness process detected: $home_orphans"
    fi
  fi
}

# The exclude id is the task this spawn is for: a recovery relaunch keeps the same
# task identity, so its own still-recorded meta must not count against its lane.
capacity_check() {  # <requested-count> [<exclude-id>]
  local requested=$1 exclude=${2:-} max total
  max=${FM_LANE_MAX_CONCURRENT:-4}
  validate_positive_int FM_LANE_MAX_CONCURRENT "$max"
  validate_positive_int requested_count "$requested"
  worker_inventory "$exclude"
  if [ -n "$COMPLETED_WORKERS" ]; then
    err "completed worker cleanup recommended before more spawns: $COMPLETED_WORKERS"
  fi
  reap_and_count_leases || die "cannot inspect spawn leases"
  total=$((ACTIVE_WORKERS + LEASE_COUNT + requested))
  if [ "$total" -gt "$max" ]; then
    die "refusing spawn: active=$ACTIVE_WORKERS leases=$LEASE_COUNT requested=$requested max=$max for home $FM_HOME"
  fi
}

write_lease() {  # <lease-id> <kind> <count> <holder-pid>
  local id=$1 kind=$2 count=$3 holder_pid=$4 path tmp
  path=$(lease_path "$id") || { err "unsafe lease id: $id"; exit 2; }
  mkdir -p "$LEASE_DIR" || die "cannot create $LEASE_DIR"
  tmp=$(mktemp "$LEASE_DIR/.lease.XXXXXX") || die "cannot create lease temp file"
  {
    printf 'id=%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'count=%s\n' "$count"
    printf 'holder_pid=%s\n' "$holder_pid"
    printf 'home=%s\n' "$FM_HOME"
    printf 'created=%s\n' "$(now_epoch)"
  } > "$tmp" || { rm -f "$tmp"; die "cannot write lease"; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; die "cannot publish lease"; }
}

release_lease() {  # <lease-id> [<holder-pid>]
  local id=$1 holder_pid=${2:-} path recorded
  path=$(lease_path "$id") || return 0
  [ -f "$path" ] || return 0
  recorded=$(lease_field "$path" holder_pid)
  if [ -n "$holder_pid" ] && [ -n "$recorded" ] && [ "$holder_pid" != "$recorded" ]; then
    return 0
  fi
  rm -f "$path" 2>/dev/null || true
}

MODE=${1:-}
shift || true
KIND=ship
COUNT=1
HOLDER_PID=$$
LEASE_ID=

case "$MODE" in
  acquire)
    LEASE_ID=${1:-}
    [ -n "$LEASE_ID" ] || { err "acquire requires a lease id"; exit 2; }
    shift || true
    ;;
  release)
    LEASE_ID=${1:-}
    [ -n "$LEASE_ID" ] || { err "release requires a lease id"; exit 2; }
    shift || true
    ;;
  check|memwatch)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      [ "$#" -ge 2 ] || { err "--kind requires a value"; exit 2; }
      KIND=$2
      shift 2
      ;;
    --count)
      [ "$#" -ge 2 ] || { err "--count requires a value"; exit 2; }
      COUNT=$2
      shift 2
      ;;
    --holder-pid)
      [ "$#" -ge 2 ] || { err "--holder-pid requires a value"; exit 2; }
      HOLDER_PID=$2
      shift 2
      ;;
    *)
      err "unknown argument: $1"
      exit 2
      ;;
  esac
done

case "$KIND" in
  ship|scout|secondmate) ;;
  *) err "--kind must be ship, scout, or secondmate"; exit 2 ;;
esac
validate_positive_int requested_count "$COUNT"
validate_positive_int holder_pid "$HOLDER_PID"

if disabled; then
  exit 0
fi

case "$MODE" in
  release)
    release_lease "$LEASE_ID" "$HOLDER_PID"
    exit 0
    ;;
  memwatch)
    memory_and_orphan_check
    printf 'LANE_GOVERNOR: memwatch ok'
    [ -n "$MEMORY_AVAILABLE_MB" ] && printf ' available_ram=%s' "$(mb_to_gb "$MEMORY_AVAILABLE_MB")"
    [ -n "$SWAP_USED_MB" ] && printf ' swap_used=%s' "$(mb_to_gb "$SWAP_USED_MB")"
    printf '\n'
    exit 0
    ;;
  check)
    memory_and_orphan_check
    [ "$KIND" = secondmate ] || capacity_check "$COUNT"
    exit 0
    ;;
  acquire)
    # Every check below refuses by exiting, so this is a straight-line sequence:
    # reaching the end means the lease is published. The EXIT trap releases the
    # lock on any refusal.
    if [ "$KIND" = secondmate ]; then
      memory_and_orphan_check
      exit 0
    fi
    safe_lease_id "$LEASE_ID" || { err "unsafe lease id: $LEASE_ID"; exit 2; }
    mkdir -p "$LEASE_ROOT" "$LEASE_DIR" || die "cannot create lane governor state"
    fm_lock_acquire_wait "$LOCK"
    LANE_LOCK_HELD=1
    memory_and_orphan_check
    capacity_check "$COUNT" "$LEASE_ID"
    write_lease "$LEASE_ID" "$KIND" "$COUNT" "$HOLDER_PID"
    fm_lock_release "$LOCK"
    LANE_LOCK_HELD=0
    exit 0
    ;;
esac
