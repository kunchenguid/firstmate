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

# Return 0 only when the ambient FM_ROOT_OVERRIDE provably names a checkout
# other than $1.
#
# FM_ROOT_OVERRIDE is an operator-directed pointer at the checkout a process is
# meant to run out of. Every producer in this repo sets it to the checkout whose
# bin/ holds the command being invoked, so a credible override always resolves
# to the running script's own checkout. A crew, scout, or secondmate session
# that merely INHERITED the parent primary's environment carries an override
# naming a foreign checkout instead. FM_HOME and the FM_*_OVERRIDE paths travel
# with it and describe the parent's home too, so once the override is proven
# foreign none of them may scope this session.
#
# Both paths must resolve before that proof exists. An override that cannot be
# resolved - a stale mount, a moved home - is evidence of nothing, so it is NOT
# foreign: purging the environment on it would move the hook onto its own
# checkout's state while bin/fm-watch.sh and bin/fm-spawn.sh keep using the
# still-valid FM_HOME. Such an environment stays intact and reaches
# fm_primary_scope_matches, which is the check that already refuses what it
# cannot confirm.
fm_primary_scope_env_is_foreign() {
  local session_root=$1 override=${FM_ROOT_OVERRIDE:-} session_phys override_phys
  [ -n "$override" ] || return 1
  session_phys=$(CDPATH='' cd -- "$session_root" 2>/dev/null && pwd -P) || return 1
  override_phys=$(CDPATH='' cd -- "$override" 2>/dev/null && pwd -P) || return 1
  [ "$override_phys" != "$session_phys" ]
}

# Set FM_ROOT, FM_HOME, STATE and CONFIG for a primary-scoped hook whose own
# checkout is $1. A proven-foreign inherited environment is discarded wholesale,
# so root and effective home cannot come from different sessions. FM_ROOT is
# always the running checkout afterwards, which is what fm_primary_scope_matches
# needs.
#
# That guarantee reaches exactly as far as FM_ROOT_OVERRIDE can prove. A leak
# carrying FM_HOME ALONE is indistinguishable from the legitimate split
# root/home model (docs/remote-secondmates.md), where FM_HOME names a data home
# outside the checkout on purpose, so this cannot reject it - and every launch
# path that hands a child an FM_HOME hands it FM_ROOT_OVERRIDE with it.
#
# A foreign environment is purged from the process environment too, not just
# from these variables: hooks foreground helpers such as bin/fm-watch-arm.sh,
# and those re-derive the same paths from the same names, so leaving the parent
# primary's values in place would only move the cross-home action one process
# down. This mirrors the reset bin/fm-spawn.sh already applies to a secondmate
# launch.
# shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
fm_primary_scope_resolve_env() {
  local session_root=$1
  if fm_primary_scope_env_is_foreign "$session_root"; then
    unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
      FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE
    FM_ROOT=$session_root
    FM_HOME=$session_root
    export FM_HOME
    STATE="$session_root/state"
    CONFIG="$session_root/config"
    return 0
  fi
  FM_ROOT=${FM_ROOT_OVERRIDE:-$session_root}
  FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
  STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# Callers must pass the running script's checkout (fm_primary_scope_resolve_env
# resolves exactly that into FM_ROOT), never a raw inherited FM_ROOT_OVERRIDE.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
