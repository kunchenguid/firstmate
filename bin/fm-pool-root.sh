#!/usr/bin/env bash
# Give this operational home its OWN treehouse worktree pool.
#
# Treehouse keys a pool by the repository, not by the checkout: two firstmate
# homes that clone the same project resolve the SAME pool directory and hand
# each other's slots out. Neither home can see the other's state/<id>.meta, so
# the pool re-leases a slot that the other home's task still names, and that
# task's cleanup later hard-resets a copy a live worker is using. Treehouse is a
# pinned third-party binary whose allocation and return-on-exit are not ours to
# change, so the guarantee uses its repo-level `root` setting from a generated
# Git config view inside the canonical operational home.
#
# Usage:
#   fm-pool-root.sh <project-dir>   ensure this home's config, print its root
#   fm-pool-root.sh --print         print this home's pool root, write nothing
#   fm-pool-root.sh --view <project-dir>  ensure and print the config view
#
# The root is <base>/<home-basename>-<hash of the home's real path>, with base
# ${FM_POOL_ROOT_BASE:-$HOME/.treehouse-homes}.
# Treehouse then places the pool itself at <root>/.treehouse/<repo>-<hash>/.
#
# The generated view lives at
# <canonical-FM_HOME>/state/treehouse-config/<project-path-hash>/<project-name>.
# Its .git symlink points at the project's existing Git directory and its
# treehouse.toml contains only the safely encoded home root. Dispatch runs the
# unwrapped `treehouse get` from that view. The project checkout and its
# info/exclude remain byte-for-byte outside this configuration path.
#
# Existing pools are never touched. A worktree already handed out keeps its
# absolute path, `treehouse return` accepts that path whatever the config now
# says, and the separation applies only to slots leased from here on, so live
# work drains out of a shared pool on its own.
#
# The view deliberately wins as Treehouse's repo root for Firstmate dispatches;
# any treehouse.toml in the captain's primary checkout remains untouched and is
# not configuration authority for another operational home's pool.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

die() {
  printf 'fm-pool-root.sh: %s\n' "$*" >&2
  exit 1
}

short_hash() {  # <string>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x", $1}'
  fi
}

# This home's own pool root. Keyed on FM_HOME - the home that owns the
# state/<id>.meta records naming each leased copy - rather than on the code
# root, because two homes sharing one code root would still double-claim.
canonical_home() {
  cd "$FM_HOME" 2>/dev/null && pwd -P
}

pool_root() {
  local home base name
  [ -z "${FM_POOL_ROOT:-}" ] \
    || die "FM_POOL_ROOT cannot preserve per-home isolation; use FM_POOL_ROOT_BASE"
  home=$(canonical_home) \
    || die "cannot resolve FM_HOME '$FM_HOME' for pool isolation"
  base=${FM_POOL_ROOT_BASE:-}
  if [ -z "$base" ]; then
    [ -n "${HOME:-}" ] || die "cannot derive a pool root: neither FM_POOL_ROOT_BASE nor HOME is set"
    base="$HOME/.treehouse-homes"
  fi
  name=$(basename "$home")
  [ -n "$name" ] && [ "$name" != / ] || name=home
  printf '%s/%s-%s' "$base" "$name" "$(short_hash "$home")"
}

project_view() {  # <project>
  local project=$1 home project_real name
  home=$(canonical_home) \
    || die "cannot resolve FM_HOME '$FM_HOME' for pool isolation"
  project_real=$(cd "$project" 2>/dev/null && pwd -P) \
    || die "cannot resolve project '$project' for pool isolation"
  name=$(basename "$project_real")
  printf '%s/state/treehouse-config/%s/%s' \
    "$home" "$(short_hash "$project_real")" "$name"
}

toml_basic_string() {  # <value>
  command -v node >/dev/null 2>&1 || return 1
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

write_config() {  # <view> <project-git-dir> <root>
  local requested_view=$1 project_git_dir=$2 root=$3 home real_view toml tmp literal git_link
  home=$(canonical_home) || return 1
  mkdir -p "$requested_view" || return 1
  real_view=$(cd "$requested_view" 2>/dev/null && pwd -P) || return 1
  case "$real_view" in
    "$home"/*) ;;
    *) return 1 ;;
  esac
  git_link="$real_view/.git"
  if [ -e "$git_link" ] || [ -L "$git_link" ]; then
    [ -L "$git_link" ] || return 1
    [ "$(readlink "$git_link")" = "$project_git_dir" ] || return 1
  else
    ln -s "$project_git_dir" "$git_link" || return 1
  fi
  git -C "$real_view" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  toml="$real_view/treehouse.toml"
  if [ -e "$toml" ] || [ -L "$toml" ]; then
    [ -f "$toml" ] && [ ! -L "$toml" ] || return 1
  fi
  literal=$(toml_basic_string "$root") || return 1
  tmp=$(mktemp "$real_view/.fm-treehouse-config.XXXXXX") || return 1
  printf 'root = %s\n' "$literal" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -f "$toml" ] && cmp -s "$tmp" "$toml"; then
    rm -f -- "$tmp"
  else
    mv -f -- "$tmp" "$toml" || { rm -f -- "$tmp"; return 1; }
  fi
  literal=$(toml_basic_string "$root") || return 1
  [ "$(cat "$toml" 2>/dev/null)" = "root = $literal" ] || return 1
}

case "${1:-}" in
  --print)
    [ "$#" -eq 1 ] || die "usage: fm-pool-root.sh --print"
    pool_root
    printf '\n'
    exit 0
    ;;
  --view)
    [ "$#" -eq 2 ] || die "usage: fm-pool-root.sh --view <project-dir>"
    VIEW_ONLY=1
    shift
    ;;
  ''|-*)
    die "usage: fm-pool-root.sh <project-dir> | fm-pool-root.sh --view <project-dir> | fm-pool-root.sh --print"
    ;;
esac

[ "$#" -eq 1 ] || die "usage: fm-pool-root.sh <project-dir> | fm-pool-root.sh --view <project-dir> | fm-pool-root.sh --print"
PROJECT=$1
[ -d "$PROJECT" ] || die "project directory '$PROJECT' does not exist"
PROJECT=$(cd "$PROJECT" && pwd -P) || die "cannot resolve project directory '$1'"
PROJECT_GIT_DIR=$(git -C "$PROJECT" rev-parse --absolute-git-dir 2>/dev/null) \
  || die "project directory '$PROJECT' is not an available Git repository"
[ -d "$PROJECT_GIT_DIR" ] \
  || die "project directory '$PROJECT' has no available Git directory"

ROOT_VALUE=$(pool_root) || exit 1
CONFIG_VIEW=$(project_view "$PROJECT") || exit 1

# Create and canonicalize before recording it: one home must always resolve the
# same string, or an every-spawn rewrite would churn the file for nothing.
mkdir -p "$ROOT_VALUE" || die "could not create this home's pool root '$ROOT_VALUE'"
ROOT_VALUE=$(cd "$ROOT_VALUE" && pwd -P) || die "could not resolve this home's pool root"
write_config "$CONFIG_VIEW" "$PROJECT_GIT_DIR" "$ROOT_VALUE" \
  || die "could not write and verify this home's isolated Treehouse config view at '$CONFIG_VIEW'"

if [ "${VIEW_ONLY:-0}" = 1 ]; then
  printf '%s\n' "$CONFIG_VIEW"
  exit 0
fi

printf '%s\n' "$ROOT_VALUE"
