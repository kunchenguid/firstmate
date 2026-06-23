#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_ROOT/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
# Grace before an empty-pid lock dir (holder died in the microsecond window
# between mkdir and writing its pid) is treated as stale and reclaimed. A normal
# holder death is reclaimed instantly via pid-liveness (kill -0), so this only
# bounds recovery from that rare window. Kept generous (10s) so that under heavy
# scheduling delay a live holder mid-write is never mistaken for stale and have
# its lock stolen - the double-grant that made the concurrency tests flake.
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-10}"
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# The lock is a single FILE created with O_EXCL (bash `set -C` noclobber). This
# replaced an mkdir-based dir lock: plain mkdir is NOT atomic on every target
# filesystem - on WSL2's filesystem several concurrent mkdir calls were observed
# to all "succeed" on one path (verified: 4 simultaneous successes in a 20-way
# barrier race), which silently double-granted the old lock and made the watcher
# singleton and wake-queue draining race. O_EXCL create IS atomic everywhere we
# run (Linux, WSL2, macOS) and writes the holder pid in the SAME redirection, so
# there is never a window where the lock exists with an unknown owner.
#
# The O_EXCL create is the ONE and ONLY grant. Reclaiming a dead holder's lock
# never grants directly: it only frees the lock and lets the next O_EXCL create
# (one atomic winner) take it. A live holder's lock can never be stolen, because
# reclaim is gated on the holder pid being dead, and the one path that moves the
# file (dead-holder reclaim) re-checks what it actually took and restores it via
# an atomic hardlink if a live holder had reappeared in the gap.

fm_lock_try_acquire() {
  local lockfile=$1 pid me steal spid
  FM_LOCK_HELD_PID=
  # Compute the pid in THIS shell, not inside the O_EXCL subshell below (where
  # BASHPID would be the subshell's). Expanded before the subshell forks, so the
  # holder pid is written - and matches what fm_lock_release compares against.
  me=${BASHPID:-$$}

  # If a reclaimable lock is present (dead holder, long-empty file, or a legacy
  # pre-O_EXCL directory), free it first. A LIVE holder's lock is never freed.
  if [ -d "$lockfile" ]; then
    pid=$(cat "$lockfile/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && fm_pid_alive "$pid"; then
      FM_LOCK_HELD_PID=$pid
      return 1
    fi
    rm -rf "$lockfile" 2>/dev/null || true
  elif [ -e "$lockfile" ]; then
    pid=$(cat "$lockfile" 2>/dev/null || true)
    if fm_pid_alive "$pid"; then
      FM_LOCK_HELD_PID=$pid
      return 1
    fi
    # Empty-but-fresh file: tolerate a brief writer gap rather than reclaim.
    if [ -z "$pid" ] && [ "$(fm_path_age "$lockfile")" -lt "$FM_LOCK_STALE_AFTER" ]; then
      FM_LOCK_HELD_PID=$pid
      return 1
    fi
    # Dead (or long-empty) holder: move the lock aside and re-check the exact
    # bytes we moved. If a live holder had replaced it in the gap, restore it
    # with an atomic hardlink (ln fails if a fresh holder already exists, so we
    # never clobber one) and back off. Otherwise it is freed.
    steal="$lockfile.stale.$me"
    rm -f "$steal" 2>/dev/null || true
    if mv "$lockfile" "$steal" 2>/dev/null; then
      spid=$(cat "$steal" 2>/dev/null || true)
      if [ -n "$spid" ] && fm_pid_alive "$spid"; then
        ln "$steal" "$lockfile" 2>/dev/null || true
        rm -f "$steal" 2>/dev/null || true
        FM_LOCK_HELD_PID=$spid
        return 1
      fi
      rm -f "$steal" 2>/dev/null || true
    fi
  fi

  # The one and only grant: an atomic O_EXCL create. Exactly one racer wins;
  # losers (someone created it first) fall through to report the holder.
  if ( set -C; printf '%s\n' "$me" > "$lockfile" ) 2>/dev/null; then
    return 0
  fi
  pid=$(cat "$lockfile" 2>/dev/null || true)
  # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
  FM_LOCK_HELD_PID=$pid
  return 1
}

fm_lock_acquire_wait() {
  local lockfile=$1
  while ! fm_lock_try_acquire "$lockfile"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockfile=$1 pid current
  current=${BASHPID:-$$}
  # Remove only our own lock. A directory is the legacy format; treat its pid
  # file the same way so an in-flight upgrade releases cleanly.
  if [ -d "$lockfile" ]; then
    pid=$(cat "$lockfile/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    rm -rf "$lockfile" 2>/dev/null || true
    return 0
  fi
  pid=$(cat "$lockfile" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  rm -f "$lockfile" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
