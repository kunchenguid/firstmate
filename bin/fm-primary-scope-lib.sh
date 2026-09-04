#!/usr/bin/env bash
# Shared marker, plain-checkout, or own-live-lock predicate for tracked hooks
# that must act only in a genuine firstmate primary home.
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

# Return 0 when $2 is $1's own state dir and its session lock names a live pid:
# the signature of a linked worktree acting as its own home with the helm taken.
fm_root_holds_own_live_lock() {
  local root=$1 state=$2 lock pid LC_ALL=C
  [ "$state" -ef "$root/state" ] || return 1
  lock="$state/.lock"
  [ -L "$lock" ] && return 1
  [ -f "$lock" ] || return 1
  IFS= read -r pid < "$lock" 2>/dev/null || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home, and a
# linked worktree holding its own live session lock is a leased primary home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    if [ "$git_dir" != "$git_common_dir" ]; then
      fm_root_holds_own_live_lock "$root" "$state" || return 1
    fi
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
