#!/usr/bin/env bash
# Shared marker, plain-checkout, or own-session-lock predicate for tracked hooks
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

# Return 0 when linked worktree $1 is a leased primary home: $2 is its own state/,
# no parent home records $1 as a task worktree in state/<id>.meta, and the session
# lock there is held by this process's own harness ancestry (docs/turnend-guard.md).
fm_linked_root_is_own_home() {
  local root=$1 state=$2 common parent meta value lib
  [ "$state" -ef "$root/state" ] || return 1
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  parent=$(dirname -- "$common")
  for meta in "$parent"/state/*.meta; do
    [ -f "$meta" ] || continue
    value=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -n 1)
    [ -n "$value" ] && [ "$value" -ef "$root" ] && return 1
  done
  [ -L "$state/.lock" ] && return 1
  [ -f "$state/.lock" ] || return 1
  if ! declare -F fm_session_lock_owned_by_self >/dev/null; then
    lib="$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"
    [ -f "$lib" ] || return 1
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$lib"
  fi
  fm_session_lock_owned_by_self "$state"
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home, and a
# linked worktree that is its own home (fm_linked_root_is_own_home) is a leased
# primary; otherwise only a plain checkout is primary, never a task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    if [ "$git_dir" != "$git_common_dir" ]; then
      fm_linked_root_is_own_home "$root" "$state" || return 1
    fi
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
