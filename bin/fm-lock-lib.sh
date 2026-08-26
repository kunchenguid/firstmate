#!/usr/bin/env bash
# Shared "is this git lock file provably abandoned?" decision procedure.
#
# ONE owner for the staleness proof that fm-teardown.sh (a worktree index.lock)
# and fm-fleet-sync.sh (a clone's .git/packed-refs.lock) both rely on: a lock is
# provably stale iff ALL of the following hold -
#   1. the lock file still exists;
#   2. no live process holds the lock file open, and none holds a companion
#      directory (the worktree, or the repo's .git dir) open as cwd or an fd -
#      a live git process keeps its own lock open for the whole operation, so an
#      empty holder result means the file was abandoned, not that no one held it;
#   3. its mtime age is at least a caller-supplied threshold - a freshly created
#      lock might belong to a process the holder probe has not yet reflected.
# ANY uncertainty - no usable holder probe, a probe error, an unreadable mtime -
# returns non-zero (NOT stale): fail safe, never remove a lock that cannot be
# proven dead.
# Diagnostics print to stderr prefixed by ${FM_LOCK_LOG_PREFIX:-fm-lock} so each
# caller's output stays recognizable.
#
# The holder probe is `lsof` wherever lsof exists. Windows Git Bash (MSYS) ships
# none, which used to leave every probe permanently at "maybe held" and every
# stale lock unreclaimable there, so that platform - and only that platform, and
# only on the branch where lsof is genuinely absent - answers the same two
# questions from what Windows itself already provides:
#   - a FILE holder: one PowerShell open of the file with FileShare.None, which
#     Windows refuses with ERROR_SHARING_VIOLATION iff some process still has
#     that file open. That is a kernel verdict covering every process on the
#     machine, not only the ones a process lister can enumerate.
#   - a DIRECTORY holder, and fm-teardown.sh's "which pids are rooted under this
#     worktree" scan: cwd read out of the MSYS procfs, which tracks every
#     process the MSYS runtime spawned - so every process firstmate, its crew,
#     and their git invocations descend from. A process started entirely outside
#     MSYS is absent from that table; the file probe above still catches such a
#     process for as long as it holds the lock open, but the cwd scan alone
#     cannot see it. Anything the scan cannot resolve is reported as uncertainty,
#     never as "provably free".

fm_lock_log() {
  echo "${FM_LOCK_LOG_PREFIX:-fm-lock}: $*" >&2
}

# Portable mtime in epoch seconds. Kept self-contained so this leaf lib drags in
# no wake-queue machinery when a caller only needs the staleness proof.
fm_lock_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_lock_lsof_holder <target>: 0 a process holds it, 1 provably none, 2 lsof
# errored (cannot tell). Diagnostics print on the error path only.
fm_lock_lsof_holder() {
  local target=$1 output status
  if output=$(lsof -- "$target" 2>&1); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 1
  fi
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      fm_lock_log "lsof check failed: $line"
    done <<< "$output"
  else
    fm_lock_log "lsof check failed for $target with exit $status"
  fi
  return 2
}

# --- Windows (Git Bash/MSYS) native probes -----------------------------------
# See the header for why these exist and exactly what each one proves.

# True on Windows Git Bash (MSYS/MinGW) or Cygwin. Same cheap uname prefix test
# bin/fm-session-lock-lib.sh's fm_harness_platform_is_windows uses for the same
# question; this leaf lib keeps its own copy rather than sourcing the harness
# lib for four lines. Cached because every MSYS fork costs ~100ms and the cwd
# scan below asks per teardown pass.
FM_LOCK_UNAME_S=''
fm_lock_platform_is_windows() {
  [ -n "$FM_LOCK_UNAME_S" ] || FM_LOCK_UNAME_S=$(uname -s 2>/dev/null || printf 'unknown')
  case "$FM_LOCK_UNAME_S" in
    MSYS*|MINGW*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# True when the native cwd scan below can run at all. ONE predicate so every
# call site - this lib's directory probe and fm-teardown.sh's reaper - takes the
# same branch and can never disagree about which probe answered.
fm_lock_windows_cwd_scan_supported() {
  fm_lock_platform_is_windows && [ -d "${FM_PROC_ROOT_OVERRIDE:-/proc}" ]
}

# fm_lock_windows_file_holder <file>: 0 a process holds the file open, 1
# provably none, 2 the probe could not answer. Windows refuses an open that
# asks for FileShare.None while ANY other handle to the file is open, so a
# successful open is proof that nothing holds it and a sharing violation is
# proof that something does. The probe's own handle lives for microseconds and
# is only ever taken on a lock file already judged abandoned by every earlier
# retry.
fm_lock_windows_file_holder() {  # <file>
  local target=$1 win out status
  [ -n "$target" ] || return 2
  if ! win=$(cygpath -w -- "$target" 2>/dev/null) || [ -z "$win" ]; then
    fm_lock_log "holder check failed for $target: cannot resolve a Windows path"
    return 2
  fi
  # The path is interpolated into a single-quoted PowerShell literal, so double
  # every quote it contains.
  win=${win//\'/\'\'}
  out=$(MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "
    try {
      \$f = [System.IO.File]::Open('$win', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
      \$f.Close()
      'free'
    } catch {
      # PowerShell wraps a .NET method's exception, and rebinds \$_ inside a
      # switch, so unwrap to the real exception and hold it in a named variable
      # before asking for its Win32 code.
      \$e = \$_.Exception
      while (\$e.InnerException) { \$e = \$e.InnerException }
      switch (\$e.HResult) {
        -2147024864 { 'holder' }   # 0x80070020 ERROR_SHARING_VIOLATION
        -2147024863 { 'holder' }   # 0x80070021 ERROR_LOCK_VIOLATION
        -2147024894 { 'free' }     # 0x80070002 ERROR_FILE_NOT_FOUND
        -2147024893 { 'free' }     # 0x80070003 ERROR_PATH_NOT_FOUND
        default { 'error: ' + \$e.Message }
      }
    }" 2>&1) || { status=$?; out="error: powershell.exe exited $status${out:+ ($out)}"; }
  # Matched whole, not line-wise: any extra output at all means something other
  # than this probe spoke, and an unrecognized answer is uncertainty.
  out=${out//$'\r'/}
  case "$out" in
    free) return 1 ;;
    holder) return 0 ;;
  esac
  fm_lock_log "holder check failed for $target: ${out:-no output from powershell.exe}"
  return 2
}

# fm_lock_windows_pid_liveness <pid>: 0 kill -0 reaches a live process, 1 the
# kernel answered ESRCH - the one failure that proves the pid exited, 2 any
# other failure (EPERM, an unrecognized message). A 2 may still be a live
# process the walker cannot signal, so callers must treat it as uncertainty,
# never as death.
fm_lock_windows_pid_liveness() {  # <pid>
  local err
  if err=$(LC_ALL=C kill -0 "$1" 2>&1); then
    return 0
  fi
  case "$err" in
    *'No such process'*) return 1 ;;
  esac
  return 2
}

# fm_lock_windows_pids_with_cwd_under <dir>: print the MSYS pid of every OTHER
# process whose current working directory is <dir> or under it, one per line.
# Returns non-zero when the table itself could not be walked, or when the cwd
# of a still-listed process that kill -0 cannot prove dead would not resolve:
# the answer is incomplete and callers must read that as "cannot tell", never
# as "nothing found". A lingering entry for a provably dead pid is the exit
# race explained inline below and is skipped, not a gap.
#
# `cd -P` is a bash builtin that resolves the procfs symlink with no fork;
# `readlink` over the same table costs one fork per process, measured at ~5s for
# a typical MSYS table against ~0.3s for this walk. The walk therefore runs in
# the CALLER's shell and restores the entry cwd before returning, rather than
# hiding in a subshell of its own: callers read it through a command
# substitution, which already forks, and that fork is what $BASHPID names below
# so the walk cannot report the process doing the walking.
fm_lock_windows_pids_with_cwd_under() {  # <dir>
  local dir=$1 proc_root entry pid origin rc=0 incomplete=0 alive
  local CDPATH=''
  [ -n "$dir" ] || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  origin=$PWD
  cd -P "$proc_root" 2>/dev/null || return 1
  proc_root=$PWD
  if ! cd -P "$dir" 2>/dev/null; then
    cd -P "$origin" 2>/dev/null || :
    return 1
  fi
  dir=$PWD
  for entry in "$proc_root"/[0-9]*; do
    pid=${entry##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$pid" in "$$"|"$BASHPID") continue ;; esac
    if cd -P "$entry/cwd" 2>/dev/null; then
      case "$PWD" in
        "$dir"|"$dir"/*) printf '%s\n' "$pid" ;;
      esac
    elif [ -d "$entry" ]; then
      # Still listed, but its cwd would not resolve. An exiting MSYS process
      # sits in exactly this state for a beat (its cwd stops resolving before
      # its /proc entry disappears), and counting that race as a gap made
      # every busy-host scan randomly incomplete. Only an ESRCH answer from
      # kill -0 proves that exit race and is skipped; a live process gets one
      # short grace and then counts as a real gap, and any other kill -0
      # failure (EPERM, unrecognized) may be a live process the walker cannot
      # signal, so it fails closed exactly like the live case.
      alive=0; fm_lock_windows_pid_liveness "$pid" || alive=$?
      if [ "$alive" -eq 0 ]; then
        sleep 0.2
        if cd -P "$entry/cwd" 2>/dev/null; then
          case "$PWD" in
            "$dir"|"$dir"/*) printf '%s\n' "$pid" ;;
          esac
        elif [ -d "$entry" ]; then
          alive=0; fm_lock_windows_pid_liveness "$pid" || alive=$?
          [ "$alive" -eq 1 ] || incomplete=1
        fi
      elif [ "$alive" -eq 2 ]; then
        incomplete=1
      fi
    fi
  done
  cd -P "$origin" 2>/dev/null || rc=1
  [ "$incomplete" -eq 0 ] || rc=1
  return "$rc"
}

# fm_lock_windows_dir_holder <dir>: 0 a live process is rooted in <dir>, 1
# provably none, 2 the scan could not answer. The Windows stand-in for
# `lsof -- <dir>` in the companion-directory half of the proof below.
fm_lock_windows_dir_holder() {  # <dir>
  local dir=$1 pids
  [ -n "$dir" ] || return 2
  [ -e "$dir" ] || return 1
  if ! pids=$(fm_lock_windows_pids_with_cwd_under "$dir"); then
    fm_lock_log "holder check failed for $dir: the MSYS /proc cwd scan could not complete"
    return 2
  fi
  [ -n "$pids" ] || return 1
  return 0
}

# Windows body of fm_lock_has_live_holder: same order, same fail-safe boundaries
# as the lsof body, with each half answered by the probe that can answer it.
fm_lock_windows_has_live_holder() {  # <lock> <dir>
  local lock=$1 dir=$2 status
  if [ -n "$lock" ]; then
    if fm_lock_windows_file_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if fm_lock_windows_dir_holder "$dir"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}

# fm_lock_has_live_holder <lock> <dir>: 0 if a live process holds $lock or the
# companion $dir open, OR if the answer is uncertain - a probe error, or no
# usable probe at all, is treated as "cannot prove no holder" (fail safe: assume
# live). Returns 1 only when a probe reports provably no holder on both.
fm_lock_has_live_holder() {
  local lock=$1 dir=$2 status
  if ! command -v lsof >/dev/null 2>&1; then
    fm_lock_platform_is_windows || return 0
    fm_lock_windows_has_live_holder "$lock" "$dir"
    return
  fi
  if [ -n "$lock" ]; then
    if fm_lock_lsof_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if fm_lock_lsof_holder "$dir"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}

# fm_lock_age <lock>: prints the lock's mtime age in whole seconds, or fails.
fm_lock_age() {
  local lock=$1 m now
  m=$(fm_lock_path_mtime "$lock") || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# fm_lock_is_provably_stale <lock> <dir> <min_age_secs>: THE proof. Returns 0 iff
# the lock exists, has no live holder, and its mtime age is at least
# <min_age_secs>. Returns non-zero on any uncertainty - never remove a lock this
# returns non-zero for.
fm_lock_is_provably_stale() {
  local lock=$1 dir=$2 min_age=$3 age
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  fm_lock_has_live_holder "$lock" "$dir" && return 1
  if ! age=$(fm_lock_age "$lock"); then
    fm_lock_log "cannot read mtime for git lock $lock; leaving it in place"
    return 1
  fi
  [ "$age" -ge "$min_age" ]
}
