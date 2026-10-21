#!/usr/bin/env bash
# Shared "which home does this session actually operate on?" correction.
#
# A checkout carrying the .fm-secondmate-home identity marker bin/fm-home-seed.sh
# writes at seed time is a persistent second mate's OWN home, and its own session
# must always operate on that root. An inherited FM_HOME or FM_ROOT_OVERRIDE that
# disagrees with it is a launcher/environment leak - a restored pane, a reboot, or
# a backend server passing its own startup environment to a relaunched harness -
# not an intentional divergence, so it must not be trusted.
#
# A crewmate task worktree carries no marker, so its legitimate FM_HOME divergence
# toward its parent home is untouched, and a main home never carries one either.
# The marker is the same regular-file identity bin/fm-primary-scope-lib.sh owns;
# this check only needs to know the home IS a seeded secondmate root.
#
# This is the shell-layer owner of that correction, matching the extension-layer
# resolver in .pi/extensions/lib/fm-home-resolve.ts.
#
# Sourcing this file corrects the inherited environment for the checkout it
# lives in: when that checkout is a seeded secondmate root, any set FM_HOME,
# FM_ROOT_OVERRIDE, or FM_ROOT is replaced with that root (keeping its export
# state), so every path a caller derives afterwards - STATE, DATA, CONFIG,
# PROJECTS - lands on the same home. Every entry point that derives those paths
# from the inherited environment - hooks, wake-lib callers, and the scripts the
# agent runs directly from its own tool shell - therefore sources this file
# BEFORE deriving any of them; correcting only inside wake-lib would split a
# caller across two homes.

fm_home_is_secondmate_root() {  # <root>
  local root=$1 marker
  [ -n "$root" ] || return 1
  marker="$root/.fm-secondmate-home"
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  return 0
}

fm_home_correct_env() {  # <own-root>
  local own=$1
  fm_home_is_secondmate_root "$own" || return 0
  [ -z "${FM_HOME:-}" ] || FM_HOME=$own
  [ -z "${FM_ROOT_OVERRIDE:-}" ] || FM_ROOT_OVERRIDE=$own
  [ -z "${FM_ROOT:-}" ] || FM_ROOT=$own
  return 0
}

fm_home_correct_env "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}/.." && pwd)"
