#!/usr/bin/env bash
# fm-telemetry.sh - durable, low-overhead host resource snapshots.
#
# Usage:
#   fm-telemetry.sh arm
#   fm-telemetry.sh disarm
#   fm-telemetry.sh status
#   fm-telemetry.sh fseventsd-check         internal fleet early-warning check
#   fm-telemetry.sh record [owner-token]   internal detached recorder mode
#   fm-telemetry.sh fsync <file>           internal durable-flush helper
#
# The recorder writes append-only daily logs under state/telemetry/.
# Each bounded snapshot contains macOS memory pressure, VM and swap summaries,
# one process-table sample reused for RSS/CPU rankings and parent/PGID counts,
# and root-volume free space.
# After every append the log and its containing directory are flushed with
# fsync(2) plus Darwin's F_FULLFSYNC, so a forced power-cycle loses at most
# the final interval even when that append created the day's log.
# Oldest daily logs are pruned until their total size is no more than
# FM_TELEMETRY_MAX_BYTES (default 209715200, or 200 MiB).
#
# `arm` is idempotent and starts one detached recorder per FM_HOME.
# The lock is one symlink whose target carries the PID, the cadence and a
# unique launch token, so it is published in a single atomic step and is never
# observable half-initialized; stale PID reuse is not trusted by status or
# disarm.
# Every lock reclaim-and-republish sequence is serialized by a guard symlink
# naming its holder, so a stale lock can never be retired on top of a fresh one.
# A guard is only ever reclaimed once its holder is gone from the process table,
# never on a timeout, so a slow holder blocks lock changes instead of losing the
# guard; `arm` and `disarm` then report that they could not reclaim the lock.
# `disarm` sends TERM and waits for the recorder's trap to release that lock.
# `arm` proves the durable-flush helper works before it detaches, and the
# detached recorder's diagnostics are appended to state/telemetry/recorder.err,
# which the loop trims back to its last 32 KiB whenever it exceeds 64 KiB.
# Every diagnostic carries a UTC timestamp and `status` reports the newest one
# with its age; losing the start-up race is reported on stdout instead, so it
# never lands in that stream.
# Nothing auto-arms this tool and it never installs a launch agent.
# The fleet watcher's existing slow-check path calls `fseventsd-check` at most
# once every five minutes. On macOS it samples fseventsd with top, keeps a
# bounded three-hour history under state/telemetry/, and emits only a newly
# reached warning, action, or emergency level. The accepted thresholds are:
# warning above 512 MiB twice or above 256 MiB/hour for two hours; action above
# 2 GiB, a doubling within one hour once already above 512 MiB, or a warning
# combined with warning-or-worse memory pressure or more than 8 GiB swap;
# emergency for sustained growth from the action range toward 4 GiB while memory
# pressure is at warning-or-worse.
# Memory-pressure levels use the kernel's dispatch encoding, where 1 is normal,
# 2 is warning and 4 is critical, so only 2 or above counts as pressure here.
#
# FM_TELEMETRY_INTERVAL controls the cadence in whole seconds from 15 through
# 30 (default 20).
# FM_HOME and FM_STATE_OVERRIDE select the home and state root normally used by
# Firstmate scripts.
# FM_TELEMETRY_PYTHON selects the interpreter used for the durable flush
# (default /usr/bin/python3).
# FM_TELEMETRY_RECORD_ONCE=1 is a test seam that makes internal record mode take
# one snapshot and exit.
# FM_TELEMETRY_NOW is a test seam that overrides the whole-second clock used by
# `fseventsd-check` for its cadence, history and growth windows.
# FM_TELEMETRY_FSEVENTSD_DISABLE=1 makes `fseventsd-check` a no-op before it
# samples anything; the shared test library sets it so watcher tests never read
# the live host, and production never sets it.
# A sample whose history could not be persisted is still alerted on, with the
# persistence failure reported as a diagnostic, so a full disk cannot silence a
# level that was already measured.
# Internal record mode without an owner token re-execs itself with a synthesized
# one, so every recorder carries its token in argv and status and disarm have a
# single liveness rule.
#
# Steady-state overhead is one sleeping Bash process.
# Each tick launches samplers sequentially, never recursively or on overlapping
# schedules, reuses one `ps` result for every process-derived section, and
# adds one short-lived interpreter process for the durable flush.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TELEMETRY_DIR="$STATE/telemetry"
LOCK_LINK="$TELEMETRY_DIR/.record.lock"
GUARD_LINK="$TELEMETRY_DIR/.record.guard"
DIAGNOSTICS_LOG="$TELEMETRY_DIR/recorder.err"
FSEVENTSD_HISTORY="$TELEMETRY_DIR/fseventsd-samples"
FSEVENTSD_ALERT="$TELEMETRY_DIR/fseventsd-alert"
INTERVAL=${FM_TELEMETRY_INTERVAL:-20}
MAX_BYTES=${FM_TELEMETRY_MAX_BYTES:-209715200}
FSYNC_PYTHON="${FM_TELEMETRY_PYTHON:-/usr/bin/python3}"
TOP_COUNT=15
DIAGNOSTICS_MAX_BYTES=65536
SNAPSHOT_SCHEMA=fm-telemetry-v1
SNAPSHOT_TMP=
SAMPLE_TMP=
PROCESS_TMP=
OWNER_TOKEN=
GUARD_TOKEN=

usage() {
  cat <<'EOF'
Usage:
  fm-telemetry.sh arm       start one detached recorder for this FM_HOME
  fm-telemetry.sh disarm    stop this home's recorder cleanly
  fm-telemetry.sh status    report running state and newest snapshot age
  fm-telemetry.sh fseventsd-check
                           run the internal fleet early-warning check

Configuration:
  FM_TELEMETRY_INTERVAL     seconds between snapshots (15..30, default 20)
  FM_TELEMETRY_MAX_BYTES    total daily-log cap (default 209715200)
  FM_HOME                   Firstmate home (defaults to this repository)

This command never auto-arms itself or installs a launch agent.
EOF
}

diagnostic_stamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown'
}

diagnostic() {
  printf 'fm-telemetry: %s %s\n' "$(diagnostic_stamp)" "$1" >&2
}

fail() {
  diagnostic "$1"
  exit 1
}

validate_configuration() {
  case "$INTERVAL" in
    ''|*[!0-9]*) fail "FM_TELEMETRY_INTERVAL must be a whole number from 15 to 30" ;;
  esac
  if [ "$INTERVAL" -lt 15 ] || [ "$INTERVAL" -gt 30 ]; then
    fail "FM_TELEMETRY_INTERVAL must be a whole number from 15 to 30"
  fi
  case "$MAX_BYTES" in
    ''|*[!0-9]*|0) fail "FM_TELEMETRY_MAX_BYTES must be a positive whole number" ;;
  esac
}

lock_exists() {
  [ -L "$LOCK_LINK" ] || [ -e "$LOCK_LINK" ]
}

read_lock_owner() {
  local target rest
  LOCK_PID=
  LOCK_TOKEN=
  LOCK_INTERVAL=unknown
  target=$(readlink "$LOCK_LINK" 2>/dev/null) || return 1
  LOCK_PID=${target%%:*}
  rest=${target#*:}
  LOCK_INTERVAL=${rest%%:*}
  LOCK_TOKEN=${rest#*:}
  [ -n "$LOCK_INTERVAL" ] || LOCK_INTERVAL=unknown
}

lock_owner_is_live() {
  local command_line
  read_lock_owner || return 1
  case "$LOCK_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$LOCK_TOKEN" ] || return 1
  kill -0 "$LOCK_PID" 2>/dev/null || return 1
  command_line=$(ps -p "$LOCK_PID" -o command= 2>/dev/null) || return 1
  case "$command_line" in
    *fm-telemetry.sh*record*"$LOCK_TOKEN"*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_stale_lock() {
  local observed
  lock_exists || return 0
  if ! observed=$(readlink "$LOCK_LINK" 2>/dev/null); then
    rm -rf "$LOCK_LINK" 2>/dev/null || return 1
    return 0
  fi
  [ "$observed" = "$(readlink "$LOCK_LINK" 2>/dev/null)" ] || return 1
  rm -f "$LOCK_LINK" 2>/dev/null || return 1
}

guard_owner_is_live() {
  local target pid command_line
  target=$(readlink "$GUARD_LINK" 2>/dev/null) || return 1
  pid=${target%%:*}
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  command_line=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$command_line" in
    *fm-telemetry.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

guard_acquire() {
  local tries=0 observed
  GUARD_TOKEN="$$:guard-$(date '+%s')-$RANDOM"
  while [ "$tries" -lt 200 ]; do
    tries=$((tries + 1))
    if ln -s "$GUARD_TOKEN" "$GUARD_LINK" 2>/dev/null; then
      return 0
    fi
    if guard_owner_is_live; then
      sleep 0.05
      continue
    fi
    if ! observed=$(readlink "$GUARD_LINK" 2>/dev/null); then
      [ -e "$GUARD_LINK" ] && rm -rf "$GUARD_LINK" 2>/dev/null
      continue
    fi
    [ "$observed" = "$(readlink "$GUARD_LINK" 2>/dev/null)" ] || continue
    rm -f "$GUARD_LINK" 2>/dev/null || true
  done
  GUARD_TOKEN=
  return 1
}

guard_release() {
  local target
  [ -n "$GUARD_TOKEN" ] || return 0
  if target=$(readlink "$GUARD_LINK" 2>/dev/null) && [ "$target" = "$GUARD_TOKEN" ]; then
    rm -f "$GUARD_LINK" 2>/dev/null || true
  fi
  GUARD_TOKEN=
}

acquire_lock() {
  local attempt=0
  while [ "$attempt" -lt 2 ]; do
    if ln -s "$$:$INTERVAL:$OWNER_TOKEN" "$LOCK_LINK" 2>/dev/null; then
      return 0
    fi
    lock_owner_is_live && return 2
    remove_stale_lock || return 1
    attempt=$((attempt + 1))
  done
  return 1
}

guarded_acquire_lock() {
  local rc
  guard_acquire || return 1
  acquire_lock
  rc=$?
  guard_release
  return "$rc"
}

guarded_remove_stale_lock() {
  local rc
  guard_acquire || return 1
  if lock_owner_is_live; then
    guard_release
    return 2
  fi
  remove_stale_lock
  rc=$?
  guard_release
  return "$rc"
}

owns_lock() {
  read_lock_owner || return 1
  [ "$LOCK_PID" = "$$" ] && [ "$LOCK_TOKEN" = "$OWNER_TOKEN" ]
}

release_lock() {
  owns_lock || return 0
  rm -f "$LOCK_LINK" 2>/dev/null || true
}

cleanup_snapshot_temps() {
  [ -n "$SNAPSHOT_TMP" ] && rm -f "$SNAPSHOT_TMP"
  [ -n "$SAMPLE_TMP" ] && rm -f "$SAMPLE_TMP"
  [ -n "$PROCESS_TMP" ] && rm -f "$PROCESS_TMP"
  SNAPSHOT_TMP=
  SAMPLE_TMP=
  PROCESS_TMP=
}

cleanup_record() {
  cleanup_snapshot_temps
  guard_release
  release_lock
}

capture_bounded() {
  local label=$1 lines=$2 command_name=$3
  shift 3
  printf '%s\n' "$label" >> "$SNAPSHOT_TMP"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'unavailable: %s not found\n' "$command_name" >> "$SNAPSHOT_TMP"
    return 0
  fi
  if "$command_name" "$@" > "$SAMPLE_TMP" 2>&1; then
    sed -n "1,${lines}p" "$SAMPLE_TMP" >> "$SNAPSHOT_TMP"
  else
    printf 'sampler_failed: %s\n' "$command_name" >> "$SNAPSHOT_TMP"
    sed -n "1,${lines}p" "$SAMPLE_TMP" >> "$SNAPSHOT_TMP"
  fi
}

# Emit at most TOP_COUNT leading lines while still draining stdin, so the
# upstream `sort` never takes SIGPIPE and never writes a broken-pipe
# diagnostic into the recorder's error stream.
take_top() {
  awk -v limit="$TOP_COUNT" 'NR <= limit { print }'
}

capture_processes() {
  printf 'PROCESS_TABLE\n' >> "$SNAPSHOT_TMP"
  if ! command -v ps >/dev/null 2>&1 ||
    ! ps -axo pid=,ppid=,pgid=,%cpu=,rss=,etime=,comm= > "$PROCESS_TMP" 2> "$SAMPLE_TMP"; then
    printf 'sampler_failed: ps\n' >> "$SNAPSHOT_TMP"
    sed -n '1,5p' "$SAMPLE_TMP" >> "$SNAPSHOT_TMP"
    return 0
  fi

  {
    awk 'NF { count++ } END { print "PROCESS_TOTAL " count + 0 }' "$PROCESS_TMP"
    printf 'TOP_RSS_KIB pid ppid pgid cpu rss_kib etime command\n'
    sort -k5,5nr -k1,1n "$PROCESS_TMP" | take_top
    printf 'TOP_CPU_PERCENT pid ppid pgid cpu rss_kib etime command\n'
    sort -k4,4nr -k1,1n "$PROCESS_TMP" | take_top
    printf 'PROCESS_COUNTS_BY_PARENT count ppid\n'
    awk 'NF { count[$2]++ } END { for (id in count) print count[id], id }' "$PROCESS_TMP" \
      | sort -k1,1nr -k2,2n | take_top
    printf 'PROCESS_COUNTS_BY_PGID_COALITION_APPROX count pgid\n'
    awk 'NF { count[$3]++ } END { for (id in count) print count[id], id }' "$PROCESS_TMP" \
      | sort -k1,1nr -k2,2n | take_top
  } >> "$SNAPSHOT_TMP"
}

size_to_bytes() {
  local raw=${1:-} unit number multiplier
  [ -n "$raw" ] || return 1
  unit=${raw#"${raw%?}"}
  case "$unit" in
    K|k) number=${raw%?}; multiplier=1024 ;;
    M|m) number=${raw%?}; multiplier=1048576 ;;
    G|g) number=${raw%?}; multiplier=1073741824 ;;
    T|t) number=${raw%?}; multiplier=1099511627776 ;;
    [0-9]) number=$raw; multiplier=1 ;;
    *) return 1 ;;
  esac
  awk -v value="$number" -v multiplier="$multiplier" 'BEGIN {
    if (value !~ /^[0-9]+([.][0-9]+)?$/) exit 1
    printf "%.0f\n", value * multiplier
  }'
}

bytes_to_mib() {
  awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1048576 }'
}

bytes_to_gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1073741824 }'
}

fseventsd_sample() {
  local pid top_output mem_raw swap_output swap_raw
  FSEVENTSD_MEM_BYTES=
  FSEVENTSD_PRESSURE_LEVEL=-1
  FSEVENTSD_SWAP_BYTES=0
  command -v pgrep >/dev/null 2>&1 || return 1
  command -v top >/dev/null 2>&1 || return 1
  pid=$(pgrep -x fseventsd 2>/dev/null | head -1)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  top_output=$(top -l 1 -pid "$pid" \
    -stats pid,command,mem,rsize,compressed,cpu,time,threads 2>/dev/null) || return 1
  mem_raw=$(printf '%s\n' "$top_output" |
    awk -v pid="$pid" '$1 == pid && $2 == "fseventsd" { print $3; exit }')
  FSEVENTSD_MEM_BYTES=$(size_to_bytes "$mem_raw") || return 1

  if command -v sysctl >/dev/null 2>&1; then
    FSEVENTSD_PRESSURE_LEVEL=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || printf '%s' -1)
    case "$FSEVENTSD_PRESSURE_LEVEL" in ''|*[!0-9]*) FSEVENTSD_PRESSURE_LEVEL=-1 ;; esac
    swap_output=$(sysctl -n vm.swapusage 2>/dev/null || true)
    swap_raw=$(printf '%s\n' "$swap_output" |
      awk '{ for (i = 1; i <= NF; i++) if ($i == "used" && $(i + 1) == "=") { print $(i + 2); exit } }')
    if [ -n "$swap_raw" ]; then
      FSEVENTSD_SWAP_BYTES=$(size_to_bytes "$swap_raw") || FSEVENTSD_SWAP_BYTES=0
    fi
  fi
}

fseventsd_alert_rank() {
  case "$1" in
    warning) printf '1\n' ;;
    action) printf '2\n' ;;
    emergency) printf '3\n' ;;
    *) printf '0\n' ;;
  esac
}

fseventsd_record_sample() {
  local now=$1 mem=$2 pressure=$3 swap=$4 cutoff tmp
  cutoff=$((now - 10800))
  tmp=$(umask 077; mktemp "$TELEMETRY_DIR/.fseventsd-history.XXXXXX") || return 1
  if [ -f "$FSEVENTSD_HISTORY" ]; then
    awk -v cutoff="$cutoff" '$1 >= cutoff' "$FSEVENTSD_HISTORY" > "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  printf '%s %s %s %s\n' "$now" "$mem" "$pressure" "$swap" >> "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$FSEVENTSD_HISTORY"
}

fseventsd_publish_alert() {
  local severity=$1 message=$2 previous=none previous_rank current_rank tmp
  [ ! -f "$FSEVENTSD_ALERT" ] || previous=$(sed -n '1p' "$FSEVENTSD_ALERT")
  previous_rank=$(fseventsd_alert_rank "$previous")
  current_rank=$(fseventsd_alert_rank "$severity")
  [ "$current_rank" -gt "$previous_rank" ] || return 0
  tmp=$(umask 077; mktemp "$TELEMETRY_DIR/.fseventsd-alert.XXXXXX") || return 1
  printf '%s\n' "$severity" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FSEVENTSD_ALERT" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$message"
}

fseventsd_check() {
  local now last last_epoch previous='' preprevious='' previous_count=0
  local prev_epoch=0 prev_mem=0
  local preprev_epoch=0 preprev_mem=0
  local growth_rate_mib='' doubling=0 warning=0
  local severity=none reasons='' message mem_mib swap_gib pressure_label
  local warning_bytes=536870912 action_bytes=2147483648 swap_action_bytes=8589934592
  local pressure_warn_level=2 pressure_critical_level=4

  case "${FM_TELEMETRY_FSEVENTSD_DISABLE:-0}" in ''|0) ;; *) return 0 ;; esac
  now=${FM_TELEMETRY_NOW:-$(date '+%s' 2>/dev/null || true)}
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  mkdir -p "$TELEMETRY_DIR" || return 0
  if [ -s "$FSEVENTSD_HISTORY" ]; then
    last=$(tail -n 1 "$FSEVENTSD_HISTORY" 2>/dev/null || true)
    last_epoch=${last%% *}
    case "$last_epoch" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$now" -ge "$last_epoch" ] && [ "$((now - last_epoch))" -lt 300 ]; then
          return 0
        fi
        ;;
    esac
    previous=$last
    previous_count=$(wc -l < "$FSEVENTSD_HISTORY" | tr -d '[:space:]')
    if [ "$previous_count" -ge 2 ]; then
      preprevious=$(tail -n 2 "$FSEVENTSD_HISTORY" | sed -n '1p')
    fi
  fi

  fseventsd_sample || return 0
  if [ -n "$previous" ]; then
    read -r prev_epoch prev_mem _ <<EOF
$previous
EOF
  fi
  if [ -n "$preprevious" ]; then
    read -r preprev_epoch preprev_mem _ <<EOF
$preprevious
EOF
  fi

  if [ "$prev_epoch" -le "$now" ] && [ "$((now - prev_epoch))" -le 600 ] \
    && [ "$prev_mem" -gt "$warning_bytes" ] && [ "$FSEVENTSD_MEM_BYTES" -gt "$warning_bytes" ]; then
    warning=1
    reasons='two consecutive samples above 512 MiB'
  fi
  if [ -f "$FSEVENTSD_HISTORY" ]; then
    growth_rate_mib=$(awk -v now="$now" -v mem="$FSEVENTSD_MEM_BYTES" '
      $1 >= now - 10800 && $1 <= now - 7200 { epoch = $1; bytes = $2 }
      END {
        if (epoch > 0 && mem > bytes) {
          rate = (mem - bytes) * 3600 / (now - epoch) / 1048576
          if (rate > 256) printf "%.2f", rate
        }
      }' "$FSEVENTSD_HISTORY")
    if [ -n "$growth_rate_mib" ]; then
      warning=1
      [ -z "$reasons" ] || reasons="$reasons; "
      reasons="${reasons}growth ${growth_rate_mib} MiB/hour for 2h"
    fi
    if [ "$FSEVENTSD_MEM_BYTES" -gt "$warning_bytes" ] && awk -v now="$now" -v mem="$FSEVENTSD_MEM_BYTES" '
      $1 >= now - 3600 && $1 < now && $2 > 0 && mem >= 2 * $2 { found = 1 }
      END { exit(found ? 0 : 1) }' "$FSEVENTSD_HISTORY"; then
      doubling=1
    fi
  fi

  if [ "$FSEVENTSD_MEM_BYTES" -gt "$action_bytes" ]; then
    severity=action
    [ -z "$reasons" ] || reasons="$reasons; "
    reasons="${reasons}MEM above 2 GiB"
  fi
  if [ "$doubling" -eq 1 ]; then
    severity=action
    [ -z "$reasons" ] || reasons="$reasons; "
    reasons="${reasons}doubling within one hour"
  fi
  if [ "$warning" -eq 1 ] && [ "$FSEVENTSD_PRESSURE_LEVEL" -ge "$pressure_warn_level" ]; then
    severity=action
    if [ "$FSEVENTSD_PRESSURE_LEVEL" -ge "$pressure_critical_level" ]; then
      pressure_label='red critical'
    else
      pressure_label=yellow
    fi
    [ -z "$reasons" ] || reasons="$reasons; "
    reasons="${reasons}warning plus ${pressure_label} memory pressure"
  fi
  if [ "$warning" -eq 1 ] && [ "$FSEVENTSD_SWAP_BYTES" -gt "$swap_action_bytes" ]; then
    severity=action
    [ -z "$reasons" ] || reasons="$reasons; "
    reasons="${reasons}warning plus more than 8 GiB swap"
  fi
  if [ "$severity" = none ] && [ "$warning" -eq 1 ]; then
    severity=warning
  fi

  if [ "$preprev_epoch" -gt 0 ] && [ "$prev_epoch" -gt "$preprev_epoch" ] \
    && [ "$now" -gt "$prev_epoch" ] && [ "$((prev_epoch - preprev_epoch))" -le 600 ] \
    && [ "$((now - prev_epoch))" -le 600 ] && [ "$preprev_mem" -lt "$prev_mem" ] \
    && [ "$prev_mem" -lt "$FSEVENTSD_MEM_BYTES" ] \
    && [ "$FSEVENTSD_MEM_BYTES" -gt "$action_bytes" ] \
    && [ "$FSEVENTSD_PRESSURE_LEVEL" -ge "$pressure_warn_level" ]; then
    severity=emergency
    [ -z "$reasons" ] || reasons="$reasons; "
    reasons="${reasons}sustained growth toward 4 GiB plus worsening memory pressure"
  fi

  fseventsd_record_sample "$now" "$FSEVENTSD_MEM_BYTES" \
    "$FSEVENTSD_PRESSURE_LEVEL" "$FSEVENTSD_SWAP_BYTES" \
    || diagnostic "could not persist the fseventsd sample history"
  if [ "$severity" = none ]; then
    rm -f "$FSEVENTSD_ALERT"
    return 0
  fi

  mem_mib=$(bytes_to_mib "$FSEVENTSD_MEM_BYTES")
  swap_gib=$(bytes_to_gib "$FSEVENTSD_SWAP_BYTES")
  case "$severity" in
    warning) message="WARNING: fseventsd MEM=${mem_mib} MiB; $reasons" ;;
    action) message="ACTION: fseventsd MEM=${mem_mib} MiB; $reasons; pressure_level=$FSEVENTSD_PRESSURE_LEVEL swap_used=${swap_gib} GiB" ;;
    emergency)
      message="EMERGENCY: fseventsd MEM=${mem_mib} MiB; $reasons; pressure_level=$FSEVENTSD_PRESSURE_LEVEL swap_used=${swap_gib} GiB; stop launching new work, save state, and reduce workload before the machine wedges"
      ;;
  esac
  fseventsd_publish_alert "$severity" "$message"
}

fsync_file() {
  local target=${1:-}
  if [ -z "$target" ] || [ ! -f "$target" ]; then
    diagnostic "fsync target ${target:-<missing>} is not a file"
    return 1
  fi
  "$FSYNC_PYTHON" - "$target" <<'FSYNC_PY'
import errno
import fcntl
import os
import sys

F_FULLFSYNC = 51

def flush(fd, label):
    os.fsync(fd)
    if sys.platform != "darwin":
        return
    try:
        fcntl.fcntl(fd, F_FULLFSYNC)
    except OSError as exc:
        if exc.errno not in (errno.ENOTSUP, errno.ENOTTY, errno.EINVAL):
            raise
        sys.stderr.write("fm-telemetry: F_FULLFSYNC unsupported for %s\n" % label)


path = sys.argv[1]
parent = os.path.dirname(path) or "."

fd = os.open(path, os.O_WRONLY | os.O_APPEND)
try:
    flush(fd, path)
finally:
    os.close(fd)

dfd = os.open(parent, os.O_RDONLY)
try:
    flush(dfd, parent)
finally:
    os.close(dfd)
FSYNC_PY
}

probe_durability() {
  local probe
  probe=$(mktemp "$TELEMETRY_DIR/.durability.XXXXXX") || return 1
  printf 'durability-probe\n' > "$probe" || {
    rm -f "$probe"
    return 1
  }
  if ! fsync_file "$probe"; then
    rm -f "$probe"
    return 1
  fi
  rm -f "$probe"
}

trim_diagnostics() {
  local bytes tmp
  [ -f "$DIAGNOSTICS_LOG" ] || return 0
  bytes=$(wc -c < "$DIAGNOSTICS_LOG" 2>/dev/null) || return 0
  [ "$bytes" -gt "$DIAGNOSTICS_MAX_BYTES" ] || return 0
  tmp=$(mktemp "$TELEMETRY_DIR/.diagnostics.XXXXXX") || return 1
  if ! tail -c "$((DIAGNOSTICS_MAX_BYTES / 2))" "$DIAGNOSTICS_LOG" > "$tmp" 2>/dev/null ||
    ! cat "$tmp" > "$DIAGNOSTICS_LOG" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

newest_diagnostic() {
  [ -s "$DIAGNOSTICS_LOG" ] || return 1
  tail -n 1 "$DIAGNOSTICS_LOG" 2>/dev/null
}

append_snapshot() {
  local timestamp epoch day utc_offset log_file
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  epoch=$(date '+%s') || return 1
  day=$(date -u '+%Y-%m-%d') || return 1
  utc_offset=$(date '+%z') || return 1
  log_file="$TELEMETRY_DIR/telemetry-$day.log"
  SNAPSHOT_TMP=$(mktemp "$TELEMETRY_DIR/.snapshot.XXXXXX") || {
    cleanup_snapshot_temps
    return 1
  }
  SAMPLE_TMP=$(mktemp "$TELEMETRY_DIR/.sample.XXXXXX") || {
    cleanup_snapshot_temps
    return 1
  }
  PROCESS_TMP=$(mktemp "$TELEMETRY_DIR/.processes.XXXXXX") || {
    cleanup_snapshot_temps
    return 1
  }

  printf 'SNAPSHOT_BEGIN schema=%s timestamp=%s epoch=%s local_utc_offset=%s recorder_pid=%s\n' \
    "$SNAPSHOT_SCHEMA" "$timestamp" "$epoch" "$utc_offset" "$$" > "$SNAPSHOT_TMP"
  capture_bounded MEMORY_PRESSURE 20 memory_pressure -Q
  capture_bounded VM_STAT 80 vm_stat
  capture_bounded SWAP_USAGE 10 sysctl vm.swapusage
  capture_processes
  capture_bounded DISK_FREE_KIB 10 df -k /
  printf 'SNAPSHOT_END timestamp=%s\n\n' "$timestamp" >> "$SNAPSHOT_TMP"

  if ! cat "$SNAPSHOT_TMP" >> "$log_file"; then
    cleanup_snapshot_temps
    return 1
  fi
  if ! fsync_file "$log_file"; then
    diagnostic "durability flush failed for $log_file"
    cleanup_snapshot_temps
    return 1
  fi
  cleanup_snapshot_temps
}

daily_log_bytes() {
  local file total=0 bytes
  for file in "$TELEMETRY_DIR"/telemetry-*.log; do
    [ -f "$file" ] || continue
    bytes=$(wc -c < "$file") || return 1
    total=$((total + bytes))
  done
  printf '%s\n' "$total"
}

prune_daily_logs() {
  local total file removed current_log
  total=$(daily_log_bytes) || return 1
  current_log="telemetry-$(date -u '+%Y-%m-%d').log"
  while [ "$total" -gt "$MAX_BYTES" ]; do
    removed=0
    for file in "$TELEMETRY_DIR"/telemetry-*.log; do
      [ -f "$file" ] || continue
      if [ "${file##*/}" = "$current_log" ]; then
        continue
      fi
      rm -f "$file" || return 1
      removed=1
      break
    done
    [ "$removed" -eq 1 ] || break
    total=$(daily_log_bytes) || return 1
  done
}

record() {
  local tick_rc token
  validate_configuration
  mkdir -p "$TELEMETRY_DIR" || fail "could not create $TELEMETRY_DIR"
  if [ -z "${1:-}" ]; then
    token="manual-$(date '+%s')-$$"
    exec "$SCRIPT_PATH" record "$token"
  fi
  OWNER_TOKEN=$1
  guarded_acquire_lock
  case $? in
    0) ;;
    2)
      printf 'fm-telemetry: recorder already running\n'
      exit 1
      ;;
    *) fail "could not acquire $LOCK_LINK" ;;
  esac
  trap 'cleanup_record; exit 0' TERM INT
  trap cleanup_record EXIT

  while :; do
    if ! owns_lock; then
      diagnostic 'lock owner changed, standing down'
      return 0
    fi
    if ! trim_diagnostics; then
      diagnostic "could not trim $DIAGNOSTICS_LOG"
    fi
    tick_rc=0
    if ! append_snapshot; then
      diagnostic 'snapshot failed'
      tick_rc=1
    fi
    if ! prune_daily_logs; then
      diagnostic 'rotation failed'
      tick_rc=1
    fi
    if [ "${FM_TELEMETRY_RECORD_ONCE:-0}" = 1 ]; then
      return "$tick_rc"
    fi
    sleep "$INTERVAL" &
    wait "$!" || break
  done
}

arm() {
  local token child_pid tries=0 child_alive=1
  validate_configuration
  mkdir -p "$TELEMETRY_DIR" || fail "could not create $TELEMETRY_DIR"
  if lock_owner_is_live; then
    printf 'fm-telemetry: already running pid=%s interval=%ss\n' "$LOCK_PID" "$LOCK_INTERVAL"
    return 0
  fi
  if lock_exists; then
    guarded_remove_stale_lock
    case $? in
      0) ;;
      2)
        printf 'fm-telemetry: already running pid=%s interval=%ss\n' "$LOCK_PID" "$LOCK_INTERVAL"
        return 0
        ;;
      *) fail "could not remove stale lock $LOCK_LINK" ;;
    esac
  fi
  probe_durability ||
    fail "durable-flush helper $FSYNC_PYTHON failed; set FM_TELEMETRY_PYTHON to a working interpreter"
  token="fmtelemetry-$(date '+%s')-$$"
  nohup "$SCRIPT_PATH" record "$token" </dev/null >/dev/null 2>>"$DIAGNOSTICS_LOG" &
  child_pid=$!
  while [ "$tries" -lt 30 ]; do
    if lock_owner_is_live; then
      printf 'fm-telemetry: running pid=%s interval=%ss directory=%s\n' \
        "$LOCK_PID" "$LOCK_INTERVAL" "$TELEMETRY_DIR"
      return 0
    fi
    if ! kill -0 "$child_pid" 2>/dev/null; then
      child_alive=0
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ "$child_alive" -eq 0 ]; then
    wait "$child_pid" 2>/dev/null || true
  else
    read_lock_owner || true
    if [ "$LOCK_PID" = "$child_pid" ]; then
      printf 'fm-telemetry: running pid=%s interval=%ss directory=%s\n' \
        "$LOCK_PID" "$LOCK_INTERVAL" "$TELEMETRY_DIR"
      return 0
    fi
    kill -TERM "$child_pid" 2>/dev/null || true
    tries=0
    while kill -0 "$child_pid" 2>/dev/null && [ "$tries" -lt 30 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
  fi
  if lock_owner_is_live; then
    printf 'fm-telemetry: already running pid=%s interval=%ss\n' "$LOCK_PID" "$LOCK_INTERVAL"
    return 0
  fi
  fail "recorder did not acquire its lock"
}

disarm() {
  local pid tries=0
  mkdir -p "$TELEMETRY_DIR" || fail "could not create $TELEMETRY_DIR"
  if ! lock_owner_is_live; then
    if lock_exists; then
      guarded_remove_stale_lock
      case $? in
        0|2) ;;
        *) fail "could not remove stale lock $LOCK_LINK" ;;
      esac
    fi
    printf 'fm-telemetry: not running\n'
    return 0
  fi
  pid=$LOCK_PID
  kill -TERM "$pid" 2>/dev/null || fail "could not signal recorder pid $pid"
  while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    fail "recorder pid $pid did not stop cleanly"
  fi
  if lock_exists; then
    guarded_remove_stale_lock
    case $? in
      0|2) ;;
      *) fail "could not retire $LOCK_LINK" ;;
    esac
  fi
  printf 'fm-telemetry: stopped pid=%s\n' "$pid"
}

# Portable mtime; Linux stat lacks -f (it means --file-system there), macOS stat lacks -c.
file_mtime() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

newest_snapshot_age() {
  local newest newest_mtime file mtime now
  newest=
  newest_mtime=0
  for file in "$TELEMETRY_DIR"/telemetry-*.log; do
    [ -f "$file" ] || continue
    mtime=$(file_mtime "$file") || continue
    case "$mtime" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$newest_mtime" ]; then
      newest=$file
      newest_mtime=$mtime
    fi
  done
  [ -n "$newest" ] || {
    printf 'none'
    return 0
  }
  now=$(date '+%s') || {
    printf 'unknown'
    return 0
  }
  printf '%ss' "$((now - newest_mtime))"
}

diagnostic_age() {
  local stamp=$1 epoch now
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" '+%s' 2>/dev/null) ||
    epoch=$(date -u -d "$stamp" '+%s' 2>/dev/null) || return 1
  now=$(date '+%s') || return 1
  printf '%ss\n' "$((now - epoch))"
}

report_diagnostics() {
  local newest stamp age
  newest=$(newest_diagnostic) || return 0
  stamp=${newest#fm-telemetry: }
  stamp=${stamp%% *}
  age=$(diagnostic_age "$stamp") || age=unknown
  printf 'fm-telemetry: newest diagnostic (age %s) in %s: %s\n' \
    "$age" "$DIAGNOSTICS_LOG" "$newest"
}

status() {
  local age rc
  age=$(newest_snapshot_age)
  if lock_owner_is_live; then
    printf 'fm-telemetry: running pid=%s interval=%ss newest_snapshot_age=%s directory=%s\n' \
      "$LOCK_PID" "$LOCK_INTERVAL" "$age" "$TELEMETRY_DIR"
    rc=0
  else
    printf 'fm-telemetry: not running newest_snapshot_age=%s directory=%s\n' "$age" "$TELEMETRY_DIR"
    rc=1
  fi
  report_diagnostics
  return "$rc"
}

case "${1:-}" in
  arm) arm ;;
  disarm) disarm ;;
  status) status ;;
  fseventsd-check) fseventsd_check ;;
  record) shift; record "${1:-}" ;;
  fsync) shift; fsync_file "${1:-}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
