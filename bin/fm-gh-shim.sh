#!/usr/bin/env bash
# A `gh` shim that routes pull-request mutations through fm-gh.sh and gives the
# no-mistakes CI read one exact-head, least-privilege workflow-runs fallback.
#
# Install it as a SYMLINK named `gh` in a directory that precedes the real gh on the
# PATH of the process you need to intercept; bin/fm-gh-shim-install.sh owns
# installation, removal, and the precedence check. The symlink is required: the shim
# locates fm-gh.sh relative to its own real path, so a copy placed outside bin/ cannot
# find the wrapper. Read docs/no-mistakes-pr-credential.md before installing, because
# this shim is scoped to a PATH, not to a repository or a worktree, so every process
# resolving gh through that directory is affected.
#
# Credential-routed invocations, chosen because these are the two calls a
# fine-grained token is forbidden from and the pipeline's PR step makes both:
#   gh pr create ...
#   gh pr edit ...
# When either omits --repo/-R, the shim derives owner/name from the working
# checkout's origin remote and appends --repo; an unresolved origin refuses the
# mutation so gh cannot infer a fork's parent repository.
# The CI monitor's exact `gh pr checks ... --json name,state,bucket,completedAt[,link]`
# vectors first try the real gh with the ambient narrow token. Only the known HTTP
# GraphQL personal-token denial for statusCheckRollup reaches fm-gh-ci-fallback.sh, which uses
# that SAME token to read the PR's exact head and workflow runs filtered by that SHA.
# It never reaches fm-gh.sh or config/gh-credential's broader token. Every other
# invocation execs the real gh unchanged, so the shim's default remains current behavior.
set -eu

# FM_GH_SHIM_ACTIVE is a hard recursion stop: if fm-gh.sh's credential prefix itself
# resolves gh through this shim, the second entry passes straight through rather than
# routing again.
ROUTE=passthrough
if [ "${FM_GH_SHIM_ACTIVE:-}" != "1" ] && [ "${1:-}" = "pr" ]; then
  case "${2:-}" in
    create | edit) ROUTE=credential ;;
    checks) ROUTE=ci-candidate ;;
  esac
fi

SHIM_PATH="${BASH_SOURCE[0]}"
SHIM_DIR="$(cd "$(dirname "$SHIM_PATH")" && pwd)"

# resolve_path <path>: echo an absolute, symlink-resolved path, or the input when it
# cannot be resolved. Used only to compare candidates against this shim.
resolve_path() {
  local target=$1
  if command -v realpath > /dev/null 2>&1; then
    realpath "$target" 2> /dev/null || printf '%s\n' "$target"
  else
    local dir base
    dir=$(cd "$(dirname "$target")" 2> /dev/null && pwd) || {
      printf '%s\n' "$target"
      return 0
    }
    base=$(basename "$target")
    while [ -L "$dir/$base" ]; do
      local link
      link=$(readlink "$dir/$base") || break
      case "$link" in
        /*) dir=$(cd "$(dirname "$link")" && pwd) ;;
        *) dir=$(cd "$dir" && cd "$(dirname "$link")" && pwd) ;;
      esac
      base=$(basename "$link")
    done
    printf '%s\n' "$dir/$base"
  fi
}

SHIM_REAL=$(resolve_path "$SHIM_PATH")
# SHIM_DIR is where the shim was INVOKED from and is what must be skipped when
# searching PATH for the real gh. SHIM_SRC_DIR is where the shim's own file actually
# lives, which is the repo's bin/ when installed as a symlink, and is what locates
# fm-gh.sh. The two differ for every real installation, so neither can serve both roles.
SHIM_SRC_DIR="$(cd "$(dirname "$SHIM_REAL")" && pwd)"

# find_real_gh: echo the first executable named gh on PATH that is not this shim.
# Directory identity alone is not enough, because the shim may be installed under a
# path that resolves to a directory already on PATH, so each candidate is compared
# against the shim's own resolved path as well.
find_real_gh() {
  local entry candidate
  local IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/gh"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    [ "$(cd "$entry" 2> /dev/null && pwd)" = "$SHIM_DIR" ] && continue
    [ "$(resolve_path "$candidate")" = "$SHIM_REAL" ] && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

REAL_GH=$(find_real_gh) || {
  echo "fm-gh-shim: no real gh found on PATH beyond the shim directory ($SHIM_DIR)" >&2
  exit 127
}

has_explicit_repo() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo | -R | --repo=* | -R?*) return 0 ;;
    esac
  done
  return 1
}

# origin_repo_slug: print the GitHub owner/name from the current checkout's origin.
# The credential route must never leave repository selection to gh: in a fork,
# gh otherwise prefers the parent repository and can create an upstream PR.
origin_repo_slug() {
  local origin path
  origin=$(git remote get-url origin 2> /dev/null) || return 1
  [ -n "$origin" ] || return 1

  case "$origin" in
    *://*)
      path=${origin#*://}
      path=${path#*/}
      ;;
    *@*:*) path=${origin#*:} ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [[ "$path" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
  printf '%s\n' "$path"
}

if [ "$ROUTE" = credential ]; then
  if ! has_explicit_repo "$@"; then
    REPO=$(origin_repo_slug) || {
      echo "fm-gh-shim: refusing credential-routed gh pr ${2:-<unknown>} without --repo: cannot resolve owner/name from origin" >&2
      exit 1
    }
    set -- "$@" --repo "$REPO"
  fi
  export FM_GH_SHIM_ACTIVE=1
  exec "${FM_GH_SHIM_WRAPPER:-$SHIM_SRC_DIR/fm-gh.sh}" "$REAL_GH" "$@"
fi

CI_FALLBACK="$SHIM_SRC_DIR/fm-gh-ci-fallback.sh"
if [ "$ROUTE" = ci-candidate ] && [ -x "$CI_FALLBACK" ] && \
  "$CI_FALLBACK" --supports "$@"; then
  exec "${FM_GH_SHIM_CI_FALLBACK:-$CI_FALLBACK}" "$REAL_GH" "$@"
fi

exec "$REAL_GH" "$@"
