#!/usr/bin/env bash
# A `gh` shim that routes pull-request mutations through fm-gh.sh and passes every
# other invocation straight to the real gh.
#
# Install it as a SYMLINK named `gh` in a directory that precedes the real gh on the
# PATH of the process you need to intercept; bin/fm-gh-shim-install.sh owns
# installation, removal, and the precedence check. The symlink is required: the shim
# locates fm-gh.sh relative to its own real path, so a copy placed outside bin/ cannot
# find the wrapper. Read docs/no-mistakes-pr-credential.md before installing, because
# this shim is scoped to a PATH, not to a repository or a worktree, so every process
# resolving gh through that directory is affected.
#
# Routed invocations, chosen because these are the two calls a fine-grained token is
# forbidden from and the pipeline's PR step makes both:
#   gh pr create ...
#   gh pr edit ...
# The shape must be exactly `pr` as the first argument and `create` or `edit` as the
# second. Every other invocation, including any other `pr` subcommand, execs the real
# gh unchanged, so the shim's default is current behavior.
set -eu

# FM_GH_SHIM_ACTIVE is a hard recursion stop: if fm-gh.sh's credential prefix itself
# resolves gh through this shim, the second entry passes straight through rather than
# routing again.
ROUTE=no
if [ "${FM_GH_SHIM_ACTIVE:-}" != "1" ] && [ "${1:-}" = "pr" ]; then
  case "${2:-}" in
    create | edit) ROUTE=yes ;;
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

if [ "$ROUTE" = "yes" ]; then
  export FM_GH_SHIM_ACTIVE=1
  exec "${FM_GH_SHIM_WRAPPER:-$SHIM_SRC_DIR/fm-gh.sh}" "$REAL_GH" "$@"
fi

exec "$REAL_GH" "$@"
