#!/usr/bin/env bash
# Shared primary-home predicate for tracked hooks and the OpenCode watch-arm
# plugin, which must act only in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.
# .opencode/plugins/fm-primary-watch-arm.js runs fm_primary_scope_matches
# through bash and reports FM_PRIMARY_SCOPE_REASON, so the plugin and the shell
# hooks share this one rule.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when the pid recorded in $1/.lock is this process or one of its
# ancestors, walking at most sixteen parents. The walk compares raw parent pids
# with no harness-name filter, so it holds for a hook shell under the harness
# and for a bash child of the OpenCode plugin alike. A missing, symlinked,
# malformed, or pid-1 lock never matches.
fm_primary_scope_session_owns_lock() {
  local state=$1 lock_pid pid=$$ _
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  IFS= read -r lock_pid < "$state/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$lock_pid" -gt 1 ] || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# Every root needs AGENTS.md, bin/, and the state dir.
# A valid secondmate marker force-includes a linked secondmate home.
# A plain checkout (git-dir equals git-common-dir) is primary.
# An unmarked linked worktree is primary only on evidence that it is its own
# operational home: the state dir is the root's own state/ and this session
# owns state/.lock. A crewmate or scout task worktree never has that lock, and a
# child worktree whose FM_HOME points at its parent home fails the state-dir
# test, so neither inherits primary scope.
# On failure FM_PRIMARY_SCOPE_REASON names the check that failed.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir own_state resolved_state
  FM_PRIMARY_SCOPE_REASON=""
  if [ ! -f "$root/AGENTS.md" ]; then
    FM_PRIMARY_SCOPE_REASON="$root/AGENTS.md is missing"
    return 1
  fi
  if [ ! -d "$root/bin" ]; then
    FM_PRIMARY_SCOPE_REASON="$root/bin is missing"
    return 1
  fi
  if [ ! -d "$state" ]; then
    FM_PRIMARY_SCOPE_REASON="state dir $state is missing"
    return 1
  fi
  fm_root_is_secondmate_home "$root" && return 0
  if ! git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) \
    || ! git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null); then
    FM_PRIMARY_SCOPE_REASON="git cannot resolve $root"
    return 1
  fi
  [ "$git_dir" = "$git_common_dir" ] && return 0
  own_state=$(cd "$root" 2>/dev/null && pwd -P)/state
  resolved_state=$(cd "$state" 2>/dev/null && pwd -P)
  if [ "$resolved_state" != "$own_state" ]; then
    FM_PRIMARY_SCOPE_REASON="$root is an unmarked linked worktree whose state dir $state is not its own state/"
    return 1
  fi
  if ! fm_primary_scope_session_owns_lock "$state"; then
    FM_PRIMARY_SCOPE_REASON="$root is an unmarked linked worktree and this session does not own $state/.lock"
    return 1
  fi
  return 0
}
