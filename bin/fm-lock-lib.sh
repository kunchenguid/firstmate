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
#      empty lsof result means the file was abandoned, not that no one held it;
#   3. its mtime age is at least a caller-supplied threshold - a freshly created
#      lock might belong to a process lsof has not yet reflected.
# ANY uncertainty - lsof missing, an lsof error, an unreadable mtime - returns
# non-zero (NOT stale): fail safe, never remove a lock that cannot be proven dead.
# Diagnostics print to stderr prefixed by ${FM_LOCK_LOG_PREFIX:-fm-lock} so each
# caller's output stays recognizable.
#
# This leaf also owns HOW `lsof` itself is located (fm_lsof_bin), because it is
# the shared lsof consumer: fm-teardown.sh's leaked-process reaper resolves the
# binary through the same function so one host can never answer "is lsof here?"
# two different ways.

fm_lock_log() {
  echo "${FM_LOCK_LOG_PREFIX:-fm-lock}: $*" >&2
}

# fm_lsof_bin: prints a usable lsof to stdout, non-zero when the host has none.
#
# Resolution is deliberately NOT PATH-only. On macOS lsof ships solely as
# /usr/sbin/lsof - there is no /usr/bin/lsof and Homebrew installs none - so any
# session whose PATH omits /usr/sbin (agent shells routinely have exactly
# ~/.local/bin:~/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin) read as
# "this host has no lsof" and silently took the degraded path: teardown stopped
# reaping processes leaked under the task worktree - the exact incident the
# reaper exists for - and every git lock read as live.
#
# PATH still wins when it has one, so a package-manager lsof or a test stub is
# unaffected; the standard system locations are only a fallback.
# FM_LSOF_FALLBACK_DIRS (space-separated; set it empty to disable the fallback)
# overrides those locations so tests can model a host with no lsof anywhere.
fm_lsof_bin() {
  local dir resolved
  if resolved=$(command -v lsof 2>/dev/null) && [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  # shellcheck disable=SC2086 # deliberate split: the override is a directory list
  for dir in ${FM_LSOF_FALLBACK_DIRS-/usr/sbin /sbin}; do
    [ -x "$dir/lsof" ] || continue
    printf '%s\n' "$dir/lsof"
    return 0
  done
  return 1
}

# Portable mtime in epoch seconds. Kept self-contained so this leaf lib drags in
# no wake-queue machinery when a caller only needs the staleness proof.
fm_lock_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_lock_lsof_holder <target>: 0 a process holds it, 1 provably none, 2 lsof
# errored (cannot tell). Diagnostics print on the error path only.
fm_lock_lsof_holder() {
  local target=$1 output status lsof_bin
  if ! lsof_bin=$(fm_lsof_bin); then
    fm_lock_log "lsof check failed for $target: no lsof on PATH or in the standard system locations"
    return 2
  fi
  if output=$("$lsof_bin" -- "$target" 2>&1); then
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

# fm_lock_has_live_holder <lock> <dir>: 0 if a live process holds $lock or the
# companion $dir open, OR if the answer is uncertain - a missing lsof or an lsof
# error is treated as "cannot prove no holder" (fail safe: assume live). Returns
# 1 only when lsof reports provably no holder on both.
fm_lock_has_live_holder() {
  local lock=$1 dir=$2 status
  fm_lsof_bin >/dev/null 2>&1 || return 0
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
