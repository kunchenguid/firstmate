#!/usr/bin/env bash
# fm-ground.sh — resolve and print the ground-truth facts for a repo firstmate
# orchestrates, so every crewmate brief (and firstmate itself) starts grounded in
# the target repo's real architecture instead of guessing it.
#
# Ground-truth files live at $FM_HOME/data/repos/<key>.md (firstmate-private,
# gitignored with the rest of data/). <key> is the repo's short name (basename of
# its path, or an explicit registered name). A file may declare `repo-path:` so an
# EXTERNAL repo (one outside firstmate's projects/) is first-class: firstmate
# orchestrates it in place, never cloning it under projects/.
#
# Usage:
#   fm-ground.sh <repo-name-or-path>     print that repo's ground truth (empty if none)
#   fm-ground.sh --path <repo-name>      print the resolved repo-path only
#   fm-ground.sh --list                  list repos that have a ground-truth file
#   fm-ground.sh --check <name-or-path>  exit 0 if ground truth exists, 1 if not
#
# Silent + exit 0 when no ground truth exists: grounding is additive, never a
# blocker. But fm-brief.sh warns when a dispatch targets a repo with none, so the
# gap is visible rather than silently re-improvised.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REPOS="$DATA/repos"

# key = basename with any trailing slash and .git stripped
key_of() {
  local a="${1%/}"; a="${a##*/}"; printf '%s' "${a%.git}"
}

case "${1:-}" in
  --list)
    [ -d "$REPOS" ] || exit 0
    for f in "$REPOS"/*.md; do
      [ -e "$f" ] || continue
      b="${f##*/}"; printf '%s\n' "${b%.md}"
    done
    exit 0 ;;
  --path)
    shift; key="$(key_of "${1:?usage: fm-ground.sh --path <repo>}")"
    f="$REPOS/$key.md"
    [ -e "$f" ] || exit 1
    grep -iE '^repo-path:' "$f" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//'
    exit 0 ;;
  --check)
    shift; key="$(key_of "${1:?usage: fm-ground.sh --check <repo>}")"
    [ -e "$REPOS/$key.md" ] ;;
  "" )
    echo "usage: fm-ground.sh <repo-name-or-path> | --path <repo> | --list | --check <repo>" >&2
    exit 2 ;;
  *)
    key="$(key_of "$1")"
    f="$REPOS/$key.md"
    [ -e "$f" ] || exit 0   # no ground truth: silent, non-fatal
    cat "$f"
    exit 0 ;;
esac
