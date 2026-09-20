#!/usr/bin/env bash
# Read a Firstmate code root this host's agent account does not own.
#
# A remote host commonly keeps its Firstmate code root under a different
# account than the agent user (a shared /opt checkout, a deploy user, root).
# Git refuses such a repository outright - "detected dubious ownership" - and
# the only setting that lifts the refusal is safe.directory. Git reads that one
# through its VERY EARLY config, which ignores the command scope, so neither
# `git -c safe.directory=...` nor the GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n
# environment form reaches the check: both are silently discarded and the
# command still fails. The exception is honored only from a protected scope, so
# this library stages a throwaway global config carrying it and runs the one
# command that has to read the code root against that config.
#
# ONE OWNER of that exception for every remote leg that reads the code root:
# the provisioning clone (bin/fm-remote-home-provision.sh) and the host-local
# sync/update reads, fetches, and code-root update (bin/fm-remote-secondmate-
# control.sh). A caller that reaches the code root without this helper is the
# bug, because a home provisioned from an unowned root could then never follow
# its parent again.
#
# The exception is deliberately minimal:
#   - it names ONLY the code root handed in, never a wildcard and never another
#     path, so nothing else on the host becomes acceptable to git;
#   - it lives in a temporary file for the duration of ONE command, so no
#     persistent configuration of this host or account is changed;
#   - every global config file the account really has is included first, in
#     git's own order, so proxy, transport, identity, and any other ambient
#     settings git would have read still apply, and still resolve to the same
#     value they would have without the guard.
# Ownership remains git's decision everywhere else, including inside the home
# itself: nothing here marks the home, its origin, or a project clone safe.

# fm_git_code_root_config_value <path>: git-config-quoted form of <path>.
fm_git_code_root_config_value() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

# fm_git_code_root_inherited_config: every global config file git would have
# read on its own, one per line and in git's own order, or nothing when the
# account has none. GIT_CONFIG_GLOBAL replaces the whole layer when set
# (including /dev/null, git's own way of saying "no global config"); otherwise
# git reads BOTH the XDG file and ~/.gitconfig, in that order, so a later value
# in ~/.gitconfig keeps overriding the XDG one exactly as it would unguarded.
fm_git_code_root_inherited_config() {
  local xdg
  if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
    [ "$GIT_CONFIG_GLOBAL" = /dev/null ] || printf '%s\n' "$GIT_CONFIG_GLOBAL"
    return 0
  fi
  xdg="${XDG_CONFIG_HOME:-${HOME:-}/.config}/git/config"
  [ ! -f "$xdg" ] || printf '%s\n' "$xdg"
  [ ! -f "${HOME:-}/.gitconfig" ] || printf '%s\n' "$HOME/.gitconfig"
}

# fm_git_code_root_stage_config <code-root> <dest>: write the throwaway global
# config that accepts <code-root>. Both the work tree and its .git directory
# are named because git reports the refusal against whichever one the command
# opens (a clone source resolves to the .git directory, an in-tree read to the
# work tree).
fm_git_code_root_stage_config() {
  local root=$1 dest=$2 inherited
  case $root in /*) ;; *) return 1 ;; esac
  {
    while IFS= read -r inherited; do
      [ -n "$inherited" ] || continue
      printf '[include]\n\tpath = %s\n' "$(fm_git_code_root_config_value "$inherited")"
    done < <(fm_git_code_root_inherited_config)
    printf '[safe]\n\tdirectory = %s\n\tdirectory = %s\n' \
      "$(fm_git_code_root_config_value "$root")" \
      "$(fm_git_code_root_config_value "$root/.git")"
  } > "$dest"
}

# fm_git_code_root_run <code-root> <command> [arg...]: run one command allowed
# to read <code-root>, and return its status. The command is usually git itself;
# a helper script that runs several git commands against the root is passed
# whole so its children inherit the same single exception.
fm_git_code_root_run() {
  local root=$1 config rc=0
  shift
  [ "$#" -gt 0 ] || return 2
  config=$(mktemp "${TMPDIR:-/tmp}/fm-git-code-root.XXXXXX") || return 1
  if ! fm_git_code_root_stage_config "$root" "$config"; then
    rm -f -- "$config"
    return 1
  fi
  GIT_CONFIG_GLOBAL="$config" "$@" || rc=$?
  rm -f -- "$config"
  return "$rc"
}
