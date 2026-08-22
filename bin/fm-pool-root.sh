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
# Its private .git control directory shares the project's common object and ref
# store while keeping a separate empty index, and its treehouse.toml contains
# only the safely encoded home root. Dispatch runs the unwrapped `treehouse get`
# from that view. The project checkout and its info/exclude remain byte-for-byte
# outside this configuration path.
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
TRANSACTION_CREATED_DIRS=()

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

canonical_intended_path() {  # <path>
  local candidate probe suffix='' component anchor
  command -v node >/dev/null 2>&1 || return 1
  candidate=$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$1") || return 1
  probe=$candidate
  while [ ! -d "$probe" ]; do
    if [ -e "$probe" ] || [ -L "$probe" ]; then
      return 1
    fi
    component=$(basename "$probe")
    suffix="/$component$suffix"
    [ "$(dirname "$probe")" != "$probe" ] || return 1
    probe=$(dirname "$probe")
  done
  anchor=$(cd "$probe" 2>/dev/null && pwd -P) || return 1
  printf '%s%s' "$anchor" "$suffix"
}

ensure_transaction_directory() {  # <path>
  local target=$1 probe parent i
  local -a missing=()
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -d "$target" ] || return 1
    return 0
  fi
  probe=$target
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    missing+=("$probe")
    parent=$(dirname "$probe")
    [ "$parent" != "$probe" ] || return 1
    probe=$parent
  done
  [ -d "$probe" ] || return 1
  for ((i=${#missing[@]} - 1; i >= 0; i--)); do
    if mkdir -- "${missing[$i]}"; then
      TRANSACTION_CREATED_DIRS+=("${missing[$i]}")
    elif [ ! -d "${missing[$i]}" ]; then
      return 1
    fi
  done
}

rollback_transaction_directories() {
  local i status=0 path
  for ((i=${#TRANSACTION_CREATED_DIRS[@]} - 1; i >= 0; i--)); do
    path=${TRANSACTION_CREATED_DIRS[$i]}
    if [ -e "$path" ] || [ -L "$path" ]; then
      rmdir -- "$path" 2>/dev/null || status=1
    fi
  done
  TRANSACTION_CREATED_DIRS=()
  return "$status"
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
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]).replace(/\u007f/g, "\\u007F"))' "$1"
}

configured_root() {  # <toml>
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    const fs = require("fs");
    const source = fs.readFileSync(process.argv[1], "utf8");
    const match = source.match(/^root[ \t]*=[ \t]*("(?:[^"\\]|\\.)*")[ \t]*\n?$/);
    if (!match) process.exit(1);
    let root;
    try { root = JSON.parse(match[1]); } catch (_) { process.exit(1); }
    if (typeof root !== "string") process.exit(1);
    process.stdout.write(root);
  ' "$1"
}

remove_private_git_dir() {  # <git-dir>
  local git_dir=$1 status=0
  rm -f -- "$git_dir/HEAD" "$git_dir/commondir" "$git_dir/index" || status=1
  rmdir "$git_dir" 2>/dev/null || status=1
  return "$status"
}

write_config() {  # <view> <project-git-dir> <project-common-dir> <root>
  local requested_view=$1 project_git_dir=$2 project_common_dir=$3 root=$4
  local home real_view toml ignore toml_tmp='' ignore_tmp='' transaction=''
  local configured git_link literal top actual_git actual_common staged_git
  local view_created=0 git_kind=absent new_git_installed=0 toml_had=0 ignore_had=0
  local status=0 rollback_status=0
  home=$(canonical_home) || return 1
  if [ ! -e "$requested_view" ] && [ ! -L "$requested_view" ]; then
    ensure_transaction_directory "$requested_view" || return 1
    view_created=1
  fi
  [ -d "$requested_view" ] && [ ! -L "$requested_view" ] || return 1
  real_view=$(cd "$requested_view" 2>/dev/null && pwd -P) || return 1
  case "$real_view" in
    "$home"/*) ;;
    *) return 1 ;;
  esac
  git_link="$real_view/.git"
  toml="$real_view/treehouse.toml"
  ignore="$real_view/.gitignore"
  if [ -e "$git_link" ] || [ -L "$git_link" ]; then
    if [ -L "$git_link" ]; then
      if [ "$(readlink "$git_link")" != "$project_git_dir" ]; then
        [ "$view_created" -ne 1 ] || rmdir "$real_view" 2>/dev/null || true
        return 1
      fi
      git_kind=symlink
    elif [ -d "$git_link" ]; then
      actual_git=$(git -C "$real_view" rev-parse --absolute-git-dir 2>/dev/null) || return 1
      actual_common=$(git -C "$real_view" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
      if [ "$actual_git" != "$git_link" ] || [ "$actual_common" != "$project_common_dir" ]; then
        return 1
      fi
      git_kind=private
    else
      [ "$view_created" -ne 1 ] || rmdir "$real_view" 2>/dev/null || true
      return 1
    fi
  fi
  if [ -e "$toml" ] || [ -L "$toml" ]; then
    if [ ! -f "$toml" ] || [ -L "$toml" ]; then
      [ "$view_created" -ne 1 ] || rmdir "$real_view" 2>/dev/null || true
      return 1
    fi
    toml_had=1
  fi
  if [ -e "$ignore" ] || [ -L "$ignore" ]; then
    if [ ! -f "$ignore" ] || [ -L "$ignore" ]; then
      [ "$view_created" -ne 1 ] || rmdir "$real_view" 2>/dev/null || true
      return 1
    fi
    ignore_had=1
  fi
  transaction=$(mktemp -d "${real_view%/*}/.fm-treehouse-rollback.XXXXXX") || status=1
  staged_git="$transaction/new.git"
  if [ "$status" -eq 0 ] && [ "$toml_had" -eq 1 ]; then
    cp -p -- "$toml" "$transaction/treehouse.toml" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$ignore_had" -eq 1 ]; then
    cp -p -- "$ignore" "$transaction/.gitignore" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$git_kind" != private ]; then
    mkdir -m 0700 "$staged_git" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$git_kind" != private ]; then
    cp -p -- "$project_git_dir/HEAD" "$staged_git/HEAD" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$git_kind" != private ]; then
    printf '%s\n' "$project_common_dir" > "$staged_git/commondir" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$git_kind" != private ]; then
    GIT_DIR="$staged_git" GIT_WORK_TREE="$real_view" git read-tree --empty >/dev/null 2>&1 || status=1
  fi
  if [ "$status" -ne 0 ]; then
    [ ! -d "$staged_git" ] || remove_private_git_dir "$staged_git" 2>/dev/null || true
    [ -z "$transaction" ] || {
      rm -f -- "$transaction/treehouse.toml" "$transaction/.gitignore" 2>/dev/null || true
      rmdir "$transaction" 2>/dev/null || true
    }
    [ "$view_created" -ne 1 ] || rmdir "$real_view" 2>/dev/null || true
    return 1
  fi
  if [ "$git_kind" = symlink ]; then
    mv -- "$git_link" "$transaction/old.git" || status=1
  fi
  if [ "$status" -eq 0 ] && [ "$git_kind" != private ]; then
    mv -- "$staged_git" "$git_link" || status=1
    if [ "$status" -eq 0 ] && [ -d "$git_link" ] && [ ! -e "$staged_git" ]; then
      new_git_installed=1
    else
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    toml_tmp=$(mktemp "$real_view/.fm-treehouse-config.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    literal=$(toml_basic_string "$root") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf 'root = %s\n' "$literal" > "$toml_tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$toml_tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    mv -f -- "$toml_tmp" "$toml" || status=1
    if [ "$status" -eq 0 ] && [ ! -e "$toml_tmp" ] && [ -f "$toml" ]; then
      toml_tmp=''
    else
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    ignore_tmp=$(mktemp "$real_view/.fm-treehouse-ignore.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '.gitignore\ntreehouse.toml\n' > "$ignore_tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$ignore_tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    mv -f -- "$ignore_tmp" "$ignore" || status=1
    if [ "$status" -eq 0 ] && [ ! -e "$ignore_tmp" ] && [ -f "$ignore" ]; then
      ignore_tmp=''
    else
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    top=$(git -C "$real_view" rev-parse --show-toplevel 2>/dev/null) || status=1
    [ "$status" -ne 0 ] || [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$real_view" ] || status=1
  fi
  if [ "$status" -eq 0 ]; then
    configured=$(configured_root "$toml") || status=1
    [ "$status" -ne 0 ] || [ "$configured" = "$root" ] || status=1
  fi
  if [ "$status" -eq 0 ]; then
    git -C "$real_view" check-ignore -q -- treehouse.toml 2>/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    git -C "$real_view" check-ignore -q -- .gitignore 2>/dev/null || status=1
  fi
  if [ "$status" -eq 0 ]; then
    command -v treehouse >/dev/null 2>&1 || status=1
  fi
  if [ "$status" -eq 0 ]; then
    (cd "$real_view" && treehouse status >/dev/null 2>&1) || status=1
  fi
  if [ "$status" -eq 0 ]; then
    rm -f -- "$transaction/treehouse.toml" "$transaction/.gitignore" 2>/dev/null || true
    rm -f -- "$transaction/old.git" 2>/dev/null || true
    rmdir "$transaction" 2>/dev/null || true
    return 0
  fi

  [ -z "$toml_tmp" ] || rm -f -- "$toml_tmp" || rollback_status=1
  [ -z "$ignore_tmp" ] || rm -f -- "$ignore_tmp" || rollback_status=1
  if [ "$toml_had" -eq 1 ]; then
    mv -f -- "$transaction/treehouse.toml" "$toml" || rollback_status=1
  else
    rm -f -- "$toml" || rollback_status=1
  fi
  if [ "$ignore_had" -eq 1 ]; then
    mv -f -- "$transaction/.gitignore" "$ignore" || rollback_status=1
  else
    rm -f -- "$ignore" || rollback_status=1
  fi
  if [ "$new_git_installed" -eq 1 ]; then
    remove_private_git_dir "$git_link" || rollback_status=1
  elif [ -d "$staged_git" ]; then
    remove_private_git_dir "$staged_git" || rollback_status=1
  fi
  if [ "$git_kind" = symlink ] && [ -L "$transaction/old.git" ]; then
    mv -- "$transaction/old.git" "$git_link" || rollback_status=1
  fi
  rmdir "$transaction" 2>/dev/null || rollback_status=1
  if [ "$view_created" -eq 1 ]; then
    rmdir "$real_view" 2>/dev/null || rollback_status=1
  fi
  [ "$rollback_status" -eq 0 ] || return 1
  return 1
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
PROJECT_GIT_COMMON_DIR=$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "project directory '$PROJECT' has no available common Git directory"
[ -d "$PROJECT_GIT_COMMON_DIR" ] \
  || die "project directory '$PROJECT' has no available common Git directory"

ROOT_VALUE=$(pool_root) || exit 1
CONFIG_VIEW=$(project_view "$PROJECT") || exit 1
ROOT_INTENDED=$(canonical_intended_path "$ROOT_VALUE") \
  || die "cannot safely resolve this home's intended pool root '$ROOT_VALUE'"
case "$ROOT_INTENDED" in
  "$PROJECT"|"$PROJECT"/*)
    die "this home's pool root '$ROOT_INTENDED' would mutate the primary project '$PROJECT'; choose FM_POOL_ROOT_BASE outside the project"
    ;;
esac

# Create and canonicalize before recording it: one home must always resolve the
# same string, or an every-spawn rewrite would churn the file for nothing.
if ! ensure_transaction_directory "$ROOT_VALUE"; then
  rollback_transaction_directories || true
  die "could not create this home's pool root '$ROOT_VALUE'"
fi
if ! ROOT_VALUE=$(cd "$ROOT_VALUE" && pwd -P); then
  rollback_transaction_directories || true
  die "could not resolve this home's pool root"
fi
if ! write_config "$CONFIG_VIEW" "$PROJECT_GIT_DIR" "$PROJECT_GIT_COMMON_DIR" "$ROOT_VALUE"; then
  if ! rollback_transaction_directories; then
    die "could not fully roll back failed Treehouse configuration at '$CONFIG_VIEW'"
  fi
  die "could not write and verify this home's isolated Treehouse config view at '$CONFIG_VIEW'"
fi

if [ "${VIEW_ONLY:-0}" = 1 ]; then
  printf '%s\n' "$CONFIG_VIEW"
  exit 0
fi

printf '%s\n' "$ROOT_VALUE"
