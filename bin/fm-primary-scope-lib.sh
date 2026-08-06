#!/usr/bin/env bash
# Shared positive-evidence predicate for tracked hooks that must act only in a
# genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

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

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# Runtime callers require a session lock, tracked hook surface, and active
# state evidence from task metadata, X-mode polling, or a process-event source.
# A valid secondmate marker is an explicit primary-home signal.
# --prelock is only for startup wrappers that run before the session lock and
# active state evidence exist.
fm_primary_scope_matches() {
  local root=$1 state=$2 home meta lock_pid git_dir git_common_dir prelock=0
  [ "${3:-}" = --prelock ] && prelock=1
  home=${state%/state}
  if [ -e "$root/.fm-secondmate-home" ] && ! fm_root_is_secondmate_home "$root"; then
    return 1
  fi
  if [ -e "$home/.fm-secondmate-home" ] && [ "$home" != "$root" ]; then
    return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
  if [ "$prelock" -eq 1 ]; then
    if ! fm_root_is_secondmate_home "$root" && ! fm_root_is_secondmate_home "$home"; then
      git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
      git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
      [ "$git_dir" = "$git_common_dir" ] || return 1
    fi
    return 0
  fi
  [ -f "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && return 0
  done
  [ -f "$state/x-watch.check.sh" ] && return 0
  for meta in "$state"/procevent/*.source; do
    [ -f "$meta" ] && return 0
  done
  return 1
}
