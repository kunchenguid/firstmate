#!/usr/bin/env bash
# Give this operational home its OWN treehouse worktree pool.
#
# Treehouse keys a pool by the repository, not by the checkout: two firstmate
# homes that clone the same project resolve the SAME pool directory and hand
# each other's slots out. Neither home can see the other's state/<id>.meta, so
# the pool re-leases a slot that the other home's task still names, and that
# task's cleanup later hard-resets a copy a live worker is using. Treehouse is a
# pinned third-party binary whose allocation and return-on-exit are not ours to
# change, so the guarantee has to come from the one knob its config exposes:
# `root` in the clone's treehouse.toml, which decides where the pool lives.
#
# Usage:
#   fm-pool-root.sh <project-dir>   ensure that clone's pool root, print it
#   fm-pool-root.sh --print         print this home's pool root, write nothing
#
# The root is <base>/<home-basename>-<hash of the home's real path>, with base
# ${FM_POOL_ROOT_BASE:-$HOME/.treehouse-homes}.
# Treehouse then places the pool itself at <root>/.treehouse/<repo>-<hash>/.
#
# Idempotent by design, so running it before every spawn converges without
# churn: an already-correct treehouse.toml is left byte-identical, other keys in
# that file are preserved, and the file is added to the clone's
# .git/info/exclude so it never dirties the project or reaches a commit.
#
# Existing pools are never touched. A worktree already handed out keeps its
# absolute path, `treehouse return` accepts that path whatever the config now
# says, and the separation applies only to slots leased from here on, so live
# work drains out of a shared pool on its own.
#
# A clone that TRACKS treehouse.toml is refused rather than rewritten: silently
# committing a machine-local path would be worse than stopping, and silently
# sharing a pool is the very thing this exists to prevent.
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
pool_root() {
  local home base name
  [ -z "${FM_POOL_ROOT:-}" ] \
    || die "FM_POOL_ROOT cannot preserve per-home isolation; use FM_POOL_ROOT_BASE"
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) \
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

# The `root` value already configured for this clone, empty when unset. Only
# top-level keys count: treehouse's config is flat, and a `root` under some
# future [section] would be a different key entirely.
configured_root() {  # <toml>
  local toml=$1 line value
  [ -f "$toml" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      \[*) break ;;
      root[[:space:]]*=*|root=*) ;;
      *) continue ;;
    esac
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf '%s' "$value"
    return 0
  done < "$toml"
}

# Rewrite <toml> so its top-level `root` is <root>, preserving every other line.
# A file with no top-level `root` gains one at the top, where TOML requires
# keys that belong to no section to live anyway.
write_root() {  # <toml> <root>
  local toml=$1 root=$2 tmp body seen=0 line in_body=1
  tmp=$(mktemp "${toml%/*}/.fm-treehouse-toml.XXXXXX") || return 1
  body=$(mktemp "${toml%/*}/.fm-treehouse-body.XXXXXX") || { rm -f -- "$tmp"; return 1; }
  if [ -f "$toml" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \[*) in_body=0 ;;
      esac
      if [ "$in_body" = 1 ]; then
        case "$line" in
          root[[:space:]]*=*|root=*)
            [ "$seen" = 1 ] || printf 'root = "%s"\n' "$root" >> "$body"
            seen=1
            continue
            ;;
        esac
      fi
      printf '%s\n' "$line" >> "$body"
    done < "$toml"
  fi
  if [ "$seen" = 0 ]; then
    printf 'root = "%s"\n' "$root" > "$tmp"
  fi
  cat "$body" >> "$tmp" || { rm -f -- "$tmp" "$body"; return 1; }
  rm -f -- "$body"
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$toml"
}

# Keep the clone's own status clean: the file is machine-local configuration,
# never project content.
exclude_from_git() {  # <project> <relative-path>
  local project=$1 rel=$2 excl grep_status
  excl=$(git -C "$project" rev-parse --git-path info/exclude 2>/dev/null) || return 1
  [ -n "$excl" ] || return 1
  case "$excl" in
    /*) ;;
    *) excl="$project/$excl" ;;
  esac
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 1
  if [ -e "$excl" ] || [ -L "$excl" ]; then
    [ -f "$excl" ] && [ ! -L "$excl" ] || return 1
    grep -qxF "$rel" "$excl" 2>/dev/null
    grep_status=$?
    case "$grep_status" in
      0) ;;
      1) printf '%s\n' "$rel" >> "$excl" || return 1 ;;
      *) return 1 ;;
    esac
  else
    printf '%s\n' "$rel" > "$excl" || return 1
  fi
  git -C "$project" check-ignore -q -- "$rel" 2>/dev/null
}

case "${1:-}" in
  --print)
    [ "$#" -eq 1 ] || die "usage: fm-pool-root.sh --print"
    pool_root
    printf '\n'
    exit 0
    ;;
  ''|-*)
    die "usage: fm-pool-root.sh <project-dir> | fm-pool-root.sh --print"
    ;;
esac

[ "$#" -eq 1 ] || die "usage: fm-pool-root.sh <project-dir>"
PROJECT=$1
[ -d "$PROJECT" ] || die "project directory '$PROJECT' does not exist"
PROJECT=$(cd "$PROJECT" && pwd -P) || die "cannot resolve project directory '$1'"

ROOT_VALUE=$(pool_root) || exit 1
TOML="$PROJECT/treehouse.toml"

if git -C "$PROJECT" ls-files --error-unmatch treehouse.toml >/dev/null 2>&1; then
  die "project '$PROJECT' tracks treehouse.toml, so this home cannot claim its own worktree pool without changing project content. Untrack that file, then spawn again"
fi

if [ -e "$TOML" ] || [ -L "$TOML" ]; then
  [ -f "$TOML" ] && [ ! -L "$TOML" ] \
    || die "'$TOML' is not a regular file; refusing to configure this home's pool root"
fi

# Create and canonicalize before recording it: one home must always resolve the
# same string, or an every-spawn rewrite would churn the file for nothing.
mkdir -p "$ROOT_VALUE" || die "could not create this home's pool root '$ROOT_VALUE'"
ROOT_VALUE=$(cd "$ROOT_VALUE" && pwd -P) || die "could not resolve this home's pool root"

if [ "$(configured_root "$TOML")" != "$ROOT_VALUE" ]; then
  write_root "$TOML" "$ROOT_VALUE" || die "could not record this home's pool root in '$TOML'"
fi
[ "$(configured_root "$TOML")" = "$ROOT_VALUE" ] \
  || die "could not verify this home's pool root in '$TOML'"
exclude_from_git "$PROJECT" treehouse.toml \
  || die "could not exclude treehouse.toml from project '$PROJECT' or verify that Git ignores it"

printf '%s\n' "$ROOT_VALUE"
