#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
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

fm_pid_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
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

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

# Claim a freshly-created (or freshly-reclaimed) lock dir: write our pid, then
# read it straight back and confirm it is still ours. The read-back is the race
# arbiter - if a competitor stomped the pid file in between, we lost and must
# not act as the holder. Returns 0 only when the lock provably names us.
#
# mypid is read as ${BASHPID:-$$} directly in this function's (caller's) shell,
# NOT via $(fm_current_pid): a command substitution forks a subshell whose
# BASHPID differs, which would record a dead pid and mismatch fm_lock_release's
# own ${BASHPID:-$$} comparison. This matches the holder pid the caller's shell
# is identified by.
fm_lock_claim() {
  local lockdir=$1 mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$lockdir/pid"; } 2>/dev/null; then
    rmdir "$lockdir" 2>/dev/null || true
    return 1
  fi
  back=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

# Single-winner lock acquire, portable (mkdir/rmdir only; no flock).
#
# Correctness rests on two facts:
#   1. `mkdir "$lockdir"` is atomic: between any two successful mkdirs of the
#      same path the dir must have been removed in between.
#   2. A live holder's lock dir is never removed - reclaim only ever evicts a
#      lock whose recorded pid is dead, and re-verifies that deadness while
#      holding a serialized steal mutex immediately before the rmdir.
# Together these mean: once an acquirer writes its own (live) pid and reads it
# back, no concurrent acquirer can evict it, so under any number of concurrent
# fm_lock_try_acquire calls on one lockdir AT MOST ONE returns 0.
fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_stale mid_acquire_stale
  FM_LOCK_HELD_PID=

  # Fast path: create the lock dir atomically and claim it.
  if mkdir "$lockdir" 2>/dev/null; then
    fm_lock_claim "$lockdir" && return 0
    return 1
  fi

  # Dir exists - someone holds (or held) it.
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  # Empty / non-numeric pid means a holder is mid-acquire (mkdir done, pid not
  # written yet). Respect a grace window before treating that as abandoned.
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      if [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]; then
        FM_LOCK_HELD_PID=$pid
        return 1
      fi
      ;;
  esac

  # Stale lock (dead pid, or empty/non-numeric past the grace). Serialize the
  # destroy-and-recreate through a sibling steal mutex so two stealers can never
  # evict-and-recreate concurrently - that serialization is what guarantees a
  # single winner. The steal critical section is a few syscalls, so a steal
  # mutex older than steal_stale can only belong to a crashed stealer and is
  # safe to clear. Its threshold is INDEPENDENT of FM_LOCK_STALE_AFTER and never
  # below 2s: tying it to that knob (which may be tuned to 0) would let a live
  # stealer's mutex be force-cleared, breaking serialization and re-admitting
  # the double-winner race.
  steal_stale=$FM_LOCK_STALE_AFTER
  [ "$steal_stale" -lt 2 ] && steal_stale=2
  steal="$lockdir.steal"
  if ! mkdir "$steal" 2>/dev/null; then
    if [ "$(fm_path_age "$steal")" -ge "$steal_stale" ]; then
      rmdir "$steal" 2>/dev/null || true
    fi
    if ! mkdir "$steal" 2>/dev/null; then
      FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
      return 1
    fi
  fi

  # Sole stealer now. Re-read the holder pid immediately before evicting: a
  # racer may have refreshed it to a live pid since our first read above.
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    rmdir "$steal" 2>/dev/null || true
    FM_LOCK_HELD_PID=$cur
    return 1
  fi

  # Evict the stale dir and reclaim. The recreate mkdir still competes with any
  # fresh fast-path contender; mkdir is atomic, so only one of us creates it.
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
  rc=1
  if mkdir "$lockdir" 2>/dev/null; then
    fm_lock_claim "$lockdir" && rc=0
  else
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
  fi
  rmdir "$steal" 2>/dev/null || true
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current
  current=${BASHPID:-$$}
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
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
