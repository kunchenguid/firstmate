#!/usr/bin/env bash
# Where a task worktree is allowed to live, and how firstmate puts it there.
#
# THE INVARIANT: a linked worktree and the object store it points at must sit on
# ONE filesystem. When they are split, git's read_gitfile_gently blocks inside
# open(), and `no-mistakes init` and `no-mistakes axi run` hang forever - so a
# crew in a split worktree can never run the validation pipeline. Ordinary git
# reads inherit the open descriptor and look completely healthy, which is what
# makes this a trap rather than an obvious failure.
#
# HOW TREEHOUSE PICKS THE POOL: a repo's pool lives at {root}/.treehouse/, where
# root comes from a treehouse.toml in the REPO ROOT (no ancestor search) and
# otherwise defaults to $HOME. There is no environment override - TREEHOUSE_DIR
# appears in the binary but does not select the pool; verified inert against the
# v2.0.0 build and the v2.0.1 pin in bin/fm-install-treehouse.sh. Firstmate
# therefore selects the pool by running treehouse under a HOME of its own
# choosing, as a per-command assignment so that nothing else - above all not the
# crew agent's own shell - inherits it.
#
# A repo-root treehouse.toml still outranks that HOME, so this file cannot make
# placement unconditional. fm_treehouse_worktree_colocated is the backstop: it
# checks the invariant on the acquired worktree itself, whoever placed it.

fm_treehouse_device() {  # <path>
  local path=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$path" 2>/dev/null
  else
    stat -c %d "$path" 2>/dev/null
  fi
}

# The object store a working tree actually reads through, canonicalized.
# --path-format=absolute needs git 2.31+; the fallback resolves the relative form
# against the repo so an older git still answers instead of silently returning "".
fm_treehouse_object_store() {  # <repo-or-worktree-dir>
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) \
    || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  [ -d "$common" ] || return 1
  (CDPATH='' cd -- "$common" 2>/dev/null && pwd -P)
}

# The mount point of an existing directory: walk up until the device id changes.
# Deriving it this way avoids parsing `df`, whose filesystem and mount-point
# columns can both contain spaces.
fm_treehouse_mount_point() {  # <existing-dir>
  local path=$1 dev parent parent_dev
  path=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
  dev=$(fm_treehouse_device "$path")
  [ -n "$dev" ] || return 1
  while [ "$path" != / ]; do
    parent=$(dirname "$path")
    parent_dev=$(fm_treehouse_device "$parent")
    [ -n "$parent_dev" ] || return 1
    [ "$parent_dev" = "$dev" ] || break
    path=$parent
  done
  printf '%s\n' "$path"
}

# A stable per-project pool identity: the repo's own directory name plus a
# discriminator derived from the canonical object-store path, so two projects
# that happen to share a name never share a pool.
fm_treehouse_project_slug() {  # <canonical-object-store-path>
  local store=$1 name discriminator
  name=$(basename "$(dirname "$store")")
  case "$name" in
    ''|.|/) name=repo ;;
  esac
  # cksum is POSIX and present on every supported host; the value only has to be
  # stable and collision-resistant enough to separate two same-named projects.
  discriminator=$(printf '%s' "$store" | cksum | awk '{print $1}')
  printf '%s-%s\n' "$name" "$discriminator"
}

# The HOME to run treehouse under, so this repo's pool lands on the repo's own
# filesystem AND in a pool of its own. Derived from the repo, never from a
# hardcoded volume: a fleet can hold repos on several volumes, and the
# requirement is "same filesystem as this repo's object store", not one path.
#
# Each project gets its own pool root under .fm-pools/<slug>/. That segregation
# is a safety property, not tidiness: treehouse's prune and destroy operate on a
# pool, so one shared pool means a cleanup aimed at one project can reach into
# another project's worktrees - including ones holding work that has not been
# pushed anywhere else. Per-project pools bound that blast radius to one project.
#
# Existing pooled worktrees are unaffected: they keep their absolute paths, and
# fm-teardown.sh returns them by absolute path regardless of pool root.
fm_treehouse_pool_home() {  # <repo-dir>
  local repo=$1 store store_dev home_dev base
  store=$(fm_treehouse_object_store "$repo") || {
    echo "error: cannot resolve the git object store for $repo" >&2
    return 1
  }
  store_dev=$(fm_treehouse_device "$store")
  home_dev=$(fm_treehouse_device "${HOME:-/}")
  [ -n "$store_dev" ] || {
    echo "error: cannot read the filesystem of $store" >&2
    return 1
  }
  if [ -n "$home_dev" ] && [ "$store_dev" = "$home_dev" ]; then
    base=$HOME
  else
    base=$(fm_treehouse_mount_point "$store") || {
      echo "error: cannot resolve the filesystem holding $store" >&2
      return 1
    }
  fi
  printf '%s/.fm-pools/%s\n' "$base" "$(fm_treehouse_project_slug "$store")"
}

# Preserve git and gh configuration discovery across the pool HOME substitution.
# `treehouse get` runs `git fetch origin` for the repo, and over HTTPS that fetch
# is authenticated through git's global config (the credential helper) and, when
# that helper is `gh auth git-credential`, through gh's own stored credentials.
# Both are found only through HOME, so running treehouse under the pool HOME
# hides them and the fetch dies with "could not read Username for
# 'https://github.com'" even though the same fetch succeeds in an ordinary shell.
# Pinning the two locations from the REAL HOME restores exactly that discovery
# and nothing else, so the pool HOME still keeps the crew away from ~/.claude.
#
# Call this in the same subshell BEFORE HOME is substituted, so $HOME is still
# the real one. The exports then survive into the treehouse child.
#
# An operator's own values win, and only paths that exist are pinned, so a user
# whose git config lives at the XDG location is never pointed at a missing
# ~/.gitconfig.
fm_treehouse_preserve_user_config() {
  local xdg=${XDG_CONFIG_HOME:-${HOME:-}/.config}
  if [ -z "${GIT_CONFIG_GLOBAL:-}" ]; then
    if [ -f "${HOME:-}/.gitconfig" ]; then
      GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
      export GIT_CONFIG_GLOBAL
    elif [ -f "$xdg/git/config" ]; then
      GIT_CONFIG_GLOBAL="$xdg/git/config"
      export GIT_CONFIG_GLOBAL
    fi
  fi
  if [ -z "${GH_CONFIG_DIR:-}" ] && [ -d "$xdg/gh" ]; then
    GH_CONFIG_DIR="$xdg/gh"
    export GH_CONFIG_DIR
  fi
  # Pinning is best effort, so the function must not report failure when there
  # was nothing to pin. Callers chain it as
  #   cd "$repo" && fm_treehouse_preserve_user_config && HOME=... treehouse get
  # and a bash function returns the status of its last command - so a machine
  # with no $XDG_CONFIG_HOME/gh directory, or one that already exports
  # GH_CONFIG_DIR, left this returning 1 and short-circuited the lease. The
  # spawn then died with "treehouse returned no usable worktree path (got '')",
  # which reads like a treehouse fault and is not one.
  return 0
}

fm_treehouse_with_pool_home() {  # <repo-dir> <command> [arg...]
  local repo=$1 pool_home
  shift
  pool_home=$(fm_treehouse_pool_home "$repo") || return 1
  ( cd "$repo" && fm_treehouse_preserve_user_config && HOME="$pool_home" "$@" )
}

fm_treehouse_return() {  # <repo-dir> <worktree-or-home>
  local repo=$1 target=$2
  fm_treehouse_with_pool_home "$repo" treehouse return --force "$target"
}

# Check the invariant on a worktree that already exists, whoever created it.
# Exit 0 colocated, 1 split, 2 undeterminable (never treat 2 as a violation).
# On 0 or 1 the three FM_TREEHOUSE_* variables carry the evidence for the caller's
# diagnostic, so a refusal can name both devices instead of asserting a verdict.
FM_TREEHOUSE_WT_DEVICE=
FM_TREEHOUSE_STORE=
FM_TREEHOUSE_STORE_DEVICE=
fm_treehouse_worktree_colocated() {  # <worktree>
  local wt=$1 store wt_dev store_dev
  FM_TREEHOUSE_WT_DEVICE=
  FM_TREEHOUSE_STORE=
  FM_TREEHOUSE_STORE_DEVICE=
  store=$(fm_treehouse_object_store "$wt") || return 2
  wt_dev=$(fm_treehouse_device "$wt")
  store_dev=$(fm_treehouse_device "$store")
  [ -n "$wt_dev" ] && [ -n "$store_dev" ] || return 2
  # shellcheck disable=SC2034 # Read by callers after this function returns.
  FM_TREEHOUSE_WT_DEVICE=$wt_dev
  # shellcheck disable=SC2034 # Read by callers after this function returns.
  FM_TREEHOUSE_STORE=$store
  # shellcheck disable=SC2034 # Read by callers after this function returns.
  FM_TREEHOUSE_STORE_DEVICE=$store_dev
  [ "$wt_dev" = "$store_dev" ]
}
