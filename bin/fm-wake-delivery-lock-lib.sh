#!/usr/bin/env bash
# Bounded mkdir-lock with stale-holder reaping, shared by every process that
# touches state/.wake-delivery-failures or its cooldown marker:
# bin/fm-wake-delivery-alarm.sh (append+trim, cooldown claim) and
# bin/fm-bootstrap.sh (session-start archive to .surfaced). All three must
# serialize under the SAME lock semantics, or bootstrap's archive can race a
# concurrent append and silently move it into .surfaced before it is ever
# surfaced.
#
# mkdir is atomic on every POSIX filesystem, so whichever caller creates the
# lock directory first holds exclusive access. Bounded (not indefinite) so a
# stuck holder never wedges a caller forever; real critical sections here are
# microseconds of file I/O, so the bound only bites a holder that crashed
# between mkdir and release. Every holder stamps its pid into <lock>/pid; a
# caller that fails to acquire checks that stamp - once the recorded pid is no
# longer alive AND the lock is at least <stale-secs> old, the lock is provably
# abandoned and is reaped so it cannot silence every later caller forever. A
# live or recent lock is never touched.

fm_wake_delivery_lock_age() {  # <lock-dir>
  local dir=$1 m now
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    m=$(stat -f %m "$dir" 2>/dev/null) || return 1
  else
    m=$(stat -c %Y "$dir" 2>/dev/null) || return 1
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - m))"
}

fm_wake_delivery_acquire_lock() {  # <lock-dir> <max-attempts> <sleep-seconds> <stale-secs>
  local dir=$1 attempts=$2 delay=$3 stale=$4 i=0 pid age
  while [ "$i" -lt "$attempts" ]; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
      return 0
    fi
    pid=
    if [ -f "$dir/pid" ]; then
      { IFS= read -r pid < "$dir/pid"; } 2>/dev/null || true
    fi
    case "$pid" in
      ''|*[!0-9]*)
        # No usable pid on disk: either the holder crashed between mkdir and
        # the pid write, or that write is still in flight. Liveness can't be
        # checked without a pid, so age alone decides abandonment - a lock
        # this old with no pid ever recorded did not just start.
        age=$(fm_wake_delivery_lock_age "$dir") || age=
        if [ -n "$age" ] && [ "$age" -ge "$stale" ]; then
          rm -rf "$dir" 2>/dev/null || true
        fi
        ;;
      *)
        if ! kill -0 "$pid" 2>/dev/null; then
          age=$(fm_wake_delivery_lock_age "$dir") || age=
          if [ -n "$age" ] && [ "$age" -ge "$stale" ]; then
            rm -rf "$dir" 2>/dev/null || true
          fi
        fi
        ;;
    esac
    i=$((i + 1))
    sleep "$delay" 2>/dev/null || true
  done
  return 1
}

fm_wake_delivery_release_lock() {  # <lock-dir>
  rm -rf "$1" 2>/dev/null || true
}
