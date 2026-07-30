#!/usr/bin/env bash
# Delete remote branches on origin except the PropPlane keeper set.
# Standing captain order (2026-07-28): agents never leave feature branches on GitHub.
# Run after an agent branch lands on prakrit, not on every prakrit sync.
#
# Usage:
#   fm-proplane-prune-stray-branches.sh [--dry-run]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      echo "usage: fm-proplane-prune-stray-branches.sh [--dry-run]"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

GIT_ROOT=$(fm_proplane_agent_git_root) || {
  echo "proplane-prune: missing GIT_ROOT in $FM_PROPLANE_AGENT_CONFIG" >&2
  exit 1
}

# The keeper list always ends with the hardcoded prakrit/main/production, so an
# "is it empty?" check could never fire. When the config was missing or unreadable
# the sandbox keepers silently dropped out and this script deleted every agent
# branch on origin — including branches holding the only copy of unlanded work.
# Require the sandbox rows to actually be present before deleting anything.
if [ -z "$(fm_proplane_agent_sandbox_rows)" ]; then
  echo "proplane-prune: no sandbox keeper rows in $FM_PROPLANE_AGENT_CONFIG — refusing to" >&2
  echo "  prune, because every agent branch would look strays-able and be deleted." >&2
  exit 1
fi

keepers=$(fm_proplane_agent_keeper_branches | tr '\n' ' ')

is_keeper() {
  local b=$1
  for k in $keepers; do
    [ "$k" = "$b" ] && return 0
  done
  return 1
}

git -C "$GIT_ROOT" fetch origin --prune || exit 1

deleted=0
skipped=0
while read -r _ ref; do
  [ -n "$ref" ] || continue
  case "$ref" in refs/heads/*) ;; *) continue ;; esac
  branch=${ref#refs/heads/}
  if is_keeper "$branch"; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY delete origin/$branch"
  else
    echo "proplane-prune: deleting origin/$branch"
    git -C "$GIT_ROOT" push origin --delete "$branch" || {
      echo "proplane-prune: failed to delete origin/$branch" >&2
      exit 1
    }
  fi
  deleted=$((deleted + 1))
done < <(git -C "$GIT_ROOT" ls-remote --refs origin 'refs/heads/*')

echo "proplane-prune: deleted=$deleted kept=$skipped (keepers: $keepers)"
