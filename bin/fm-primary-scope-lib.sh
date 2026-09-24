#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
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

# Echo the branch named by $1's genuine linked-primary marker and return 0.
# The captain writes .fm-primary-home by hand in a primary home that is itself a
# linked git worktree (an Orca workspace, for example); its whitespace-stripped
# first line is the branch that home is meant to sit on. Never inferred.
fm_primary_home_branch() {
  local marker="$1/.fm-primary-home" branch LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r branch < "$marker" 2>/dev/null || [ -n "$branch" ] || return 1
  branch=${branch//[[:space:]]/}
  [ -n "$branch" ] || return 1
  case "$branch" in
    *[!A-Za-z0-9._/-]*|-*|/*|*/|*//*|*..*) return 1 ;;
  esac
  printf '%s\n' "$branch"
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate or linked-primary marker force-includes a linked home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root" && ! fm_primary_home_branch "$root" >/dev/null; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
