#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for entrypoints scoped to a genuine
# firstmate primary home. This file is sourced by hook and supervisor entrypoints
# without side effects.
#
# Threat model: the supervisor guard stops an ordinary crew/scout worker that
# has lost track of its role from running supervisor-only entrypoints out of
# its own worktree. Authority comes only from the checkout containing the
# executing script. Deliberate forgery of checkout records, provisioning files,
# or environment by a process running as the same OS user is out of scope:
# file checks cannot prevent it.

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

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A valid secondmate marker force-includes a linked secondmate
# home. Otherwise only a plain checkout is primary, never a linked task
# worktree.
fm_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
fm_primary_scope_matches() {
  local root=$1 state=$2
  fm_primary_root_matches "$root" && [ -d "$state" ]
}

# Return 0 when $1 is a secondmate home whose provisioning is proven by its own
# durable local parent binding and by the parent's registry entry naming this
# checkout as that mate's home. The identity marker alone proves nothing.
fm_root_is_provisioned_secondmate_home() {
  local root=$1 lib_dir id reg home_key root_key
  fm_root_is_secondmate_home "$root" || return 1
  lib_dir=$(CDPATH='' cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || return 1
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$lib_dir/fm-secondmate-parent-lib.sh" || return 1
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$lib_dir/fm-secondmate-registry-lib.sh" || return 1
  IFS= read -r id < "$root/.fm-secondmate-home" || return 1
  id=${id//[[:space:]]/}
  fm_secondmate_parent_record_parse "$root/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  reg="$FM_SECONDMATE_PARENT_HOME/data/secondmates.md"
  secondmate_registry_line_for_id "$reg" "$id" || return 1
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || return 1
  home_key=$(secondmate_registry_path_key "$SECONDMATE_REGISTRY_HOME") || return 1
  root_key=$(CDPATH='' cd -P "$root" 2>/dev/null && pwd -P) || return 1
  [ "$home_key" = "$root_key" ]
}

# Return 0 when $1 may run supervisor-only entrypoints: a plain primary
# checkout, or a linked checkout that is a provisioned secondmate home.
fm_primary_supervisor_checkout_matches() {
  local root=$1 git_dir git_common_dir
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  fm_root_is_provisioned_secondmate_home "$root" && return 0
  git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common_dir" ]
}

# Refuse supervisor-only entrypoints outside the primary checkout containing
# this sourced library. Caller-supplied root, home, and state overrides and
# FM_TEST_SEAM never establish authority.
fm_primary_supervisor_guard() {  # <entrypoint>
  local entrypoint=${1:-unknown} source_dir root
  source_dir=$(CDPATH='' cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || source_dir=
  root=
  [ -n "$source_dir" ] && root=$(CDPATH='' cd -P "$source_dir/.." 2>/dev/null && pwd -P) || root=
  if [ -n "$root" ]; then
    fm_primary_supervisor_checkout_matches "$root" && return 0
  fi
  printf 'error: refusing supervisor-only %s from a crew/scout worktree or non-primary checkout; return to your own task\n' "$entrypoint" >&2
  return 1
}
