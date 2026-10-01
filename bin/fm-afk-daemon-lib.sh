#!/usr/bin/env bash
# fm-afk-daemon-lib.sh - the single owner of finding a home's live away-mode
# supervise daemons (bin/fm-supervise-daemon.sh): its singleton lock and the
# parent link of the watcher a daemon runs. Sourced by the daemon,
# bin/fm-afk-start.sh, bin/fm-afk-launch.sh, bin/fm-watch-arm.sh, and
# bin/fm-watch-checkpoint.sh, each after bin/fm-wake-lib.sh, whose fm_pid_alive,
# fm_pid_identity, and fm_watcher_lock_matches_pid it calls. Only
# fm_afk_daemon_stop signals anything.
#
# The lock alone cannot find every live daemon: a daemon can outlive its lock,
# and the lock's recorded identity is fm_pid_identity, whose ps form renders the
# start time in the local time zone, so a host time-zone change makes a live
# daemon no longer match it. The watcher proof finds such a daemon while it
# still runs this home's watcher; a daemon that runs neither exits on its own
# once state/.afk is gone or its lock is lost.
#
# Proofs that a pid is a live daemon of this home, strongest first:
#   lock     the lock names a live pid whose recorded identity still matches,
#            or that recorded no identity and runs the daemon script.
#   watcher  this home's identity-verified watcher's live parent process runs
#            the daemon script, which also names a daemon without its lock.
#   command  the lock names a live pid that runs the daemon script although its
#            recorded identity no longer matches. That keeps the lock and stops a
#            second daemon from starting; it is never enough to signal the pid.

FM_AFK_DAEMON_SCRIPT=fm-supervise-daemon.sh

fm_afk_daemon_lock_path() {  # <state>
  printf '%s/.supervise-daemon.lock\n' "$1"
}

# Print <pid>'s command line, from a Linux-compatible proc root when present.
fm_afk_daemon_pid_command() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "$proc_root/$pid/cmdline" ]; then
    tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null
    return
  fi
  COLUMNS=10000 LC_ALL=C ps -p "$pid" -o command= 2>/dev/null
}

# Print <pid>'s parent pid.
fm_afk_daemon_pid_parent() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} stat_line parent
  local -a fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, index 1 is proc stat field 4 (ppid).
    read -r -a fields <<< "${stat_line##*)}"
    parent=${fields[1]:-}
  else
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$parent" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$parent"
}

# True when <pid> is alive and its command line runs the daemon script.
fm_afk_daemon_pid_runs_daemon() {  # <pid>
  local command
  fm_pid_alive "$1" || return 1
  command=$(fm_afk_daemon_pid_command "$1") || return 1
  case " $command " in
    *"/$FM_AFK_DAEMON_SCRIPT "*|*" $FM_AFK_DAEMON_SCRIPT "*) return 0 ;;
  esac
  return 1
}

# Print the lock's owner directory: the symlink target, or a legacy plain dir.
fm_afk_daemon_lock_owner() {  # <state>
  local lock owner
  lock=$(fm_afk_daemon_lock_path "$1")
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$lock")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

fm_afk_daemon_lock_pid() {  # <state>
  local owner
  owner=$(fm_afk_daemon_lock_owner "$1") || return 1
  cat "$owner/pid" 2>/dev/null || true
}

# The lock proof (header): strong enough to signal the lock's pid.
fm_afk_daemon_lock_holder_proven() {  # <state>
  local state=$1 owner pid identity current
  owner=$(fm_afk_daemon_lock_owner "$state") || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -z "$identity" ]; then
    fm_afk_daemon_pid_runs_daemon "$pid"
    return
  fi
  current=$(fm_pid_identity "$pid") || return 1
  [ "$current" = "$identity" ]
}

# The lock or command proof (header): a live daemon holds the lock, so it must
# be kept and no second daemon may start.
fm_afk_daemon_lock_holder_live() {  # <state>
  local pid
  fm_afk_daemon_lock_holder_proven "$1" && return 0
  pid=$(fm_afk_daemon_lock_pid "$1") || return 1
  fm_afk_daemon_pid_runs_daemon "$pid"
}

# The watcher proof (header): print the pid of the daemon whose child is this
# home's live watcher.
fm_afk_daemon_watcher_owner() {  # <state> <watch-path> <home>
  local state=$1 watch_path=$2 home=$3 watcher parent
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  fm_pid_alive "$watcher" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$watcher" "$home" || return 1
  parent=$(fm_afk_daemon_pid_parent "$watcher") || return 1
  case "$parent" in 0|1) return 1 ;; esac
  fm_afk_daemon_pid_runs_daemon "$parent" || return 1
  printf '%s\n' "$parent"
}

# Print each live daemon of <state> that a lock or watcher proof names, once.
# The watcher proof needs <watch-path> and <home>.
fm_afk_daemon_live_pids() {  # <state> [<watch-path> <home>]
  local state=$1 watch_path=${2:-} home=${3:-} pid found=' '
  if fm_afk_daemon_lock_holder_proven "$state"; then
    pid=$(fm_afk_daemon_lock_pid "$state")
    found="$found$pid "
  fi
  if [ -n "$watch_path" ] && pid=$(fm_afk_daemon_watcher_owner "$state" "$watch_path" "$home"); then
    case "$found" in *" $pid "*) ;; *) found="$found$pid " ;; esac
  fi
  for pid in $found; do
    printf '%s\n' "$pid"
  done
}

# SIGTERM each <pid> and wait up to ten seconds for all of them to exit. A pid
# that still runs under the identity it had before the signal is printed, and
# then the call fails; a pid that exited or was reused counts as stopped.
fm_afk_daemon_stop() {  # <pid>...
  local pid i alive status=0
  local -a pids=() identities=()
  for pid in "$@"; do
    fm_pid_alive "$pid" || continue
    pids+=("$pid")
    identities+=("$(fm_pid_identity "$pid" 2>/dev/null || true)")
    kill -TERM "$pid" 2>/dev/null || true
  done
  [ "${#pids[@]}" -gt 0 ] || return 0
  for _ in $(seq 1 40); do
    alive=0
    for pid in "${pids[@]}"; do
      fm_pid_alive "$pid" && alive=1
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.25
  done
  for i in "${!pids[@]}"; do
    fm_pid_alive "${pids[$i]}" || continue
    [ "$(fm_pid_identity "${pids[$i]}" 2>/dev/null || true)" = "${identities[$i]}" ] || continue
    printf '%s\n' "${pids[$i]}"
    status=1
  done
  return "$status"
}
