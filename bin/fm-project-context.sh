#!/usr/bin/env bash
# Render required project instructions for a worker launch or context recovery.
# Usage: fm-project-context.sh <project-dir> <worktree> <config-dir>
# UseRialto/rialto-backend and UseRialto/rialto-frontend always require
# config/rialto-project-context.paths: exactly five absolute paths, ordered as
# backend CLAUDE.md, backend AGENTS.md, frontend CLAUDE.md, frontend AGENTS.md,
# product AGENTS.md. Repository identities are checked through Git remotes.
# Prepare without changing a home:
# fm-project-context.sh --prepare-rialto <backend-dir> <frontend-dir> <product-AGENTS>
# Redirect stdout to a staging file, then review before installing configuration.
# Rendering also requires current-worktree CLAUDE.md and AGENTS.md.
# Output includes full bytes and SHA-256.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,12p' "$0"
  exit 0
fi
repo_identity() {
  local remote url
  while IFS= read -r remote; do
    url=$(git -C "$1" remote get-url "$remote") || return 1
    url=${url%.git}
    case "$url" in
      https://github.com/UseRialto/rialto-backend|git@github.com:UseRialto/rialto-backend|ssh://git@github.com/UseRialto/rialto-backend)
        printf '%s\n' backend; return 0 ;;
      https://github.com/UseRialto/rialto-frontend|git@github.com:UseRialto/rialto-frontend|ssh://git@github.com/UseRialto/rialto-frontend)
        printf '%s\n' frontend; return 0 ;;
    esac
  done < <(git -C "$1" remote 2>/dev/null)
}
validate_rialto() {
  [ "$#" -eq 5 ] || { echo 'error: Rialto configuration requires exactly five source paths; use --prepare-rialto' >&2; return 1; }
  local source
  for source in "$@"; do
    case "$source" in /*) ;; *) echo 'error: Rialto source paths must be absolute' >&2; return 1 ;; esac
    [ -r "$source" ] && [ -f "$source" ] || { printf 'error: required Rialto source is unreadable: %s; prepare accessible paired sources with --prepare-rialto\n' "$source" >&2; return 1; }
  done
  [ "${1##*/}" = CLAUDE.md ] && [ "$2" = "${1%/*}/AGENTS.md" ] &&
    [ "${3##*/}" = CLAUDE.md ] && [ "$4" = "${3%/*}/AGENTS.md" ] &&
    [ "${5##*/}" = AGENTS.md ] &&
    [ "$(repo_identity "${1%/*}")" = backend ] &&
    [ "$(repo_identity "${3%/*}")" = frontend ] || {
      echo 'error: Rialto sources must name verified UseRialto backend/frontend instruction pairs and product AGENTS.md; use --prepare-rialto' >&2
      return 1
    }
}
if [ "${1:-}" = --prepare-rialto ]; then
  [ "$#" -eq 4 ] || { echo 'usage: --prepare-rialto <backend-dir> <frontend-dir> <product-AGENTS>' >&2; exit 2; }
  backend=$(cd "$2" && pwd -P)
  frontend=$(cd "$3" && pwd -P)
  product_parent=$(cd "$(dirname "$4")" && pwd -P)
  sources=("$backend/CLAUDE.md" "$backend/AGENTS.md" "$frontend/CLAUDE.md" "$frontend/AGENTS.md" "$product_parent/$(basename "$4")")
  validate_rialto "${sources[@]}"
  printf '%s\n' "${sources[@]}"
  exit 0
fi
[ "$#" -eq 3 ] || { echo 'usage: fm-project-context.sh <project-dir> <worktree> <config-dir>' >&2; exit 2; }
project=$1
worktree=$(cd "$2" && pwd -P)
config=$3
identity=$(repo_identity "$worktree")
project_identity=$(repo_identity "$project")
[ -n "$identity" ] || [ -n "$project_identity" ] || exit 0
manifest="$config/rialto-project-context.paths"
[ -f "$manifest" ] || { printf 'error: required Rialto configuration missing: %s; use fm-project-context.sh --prepare-rialto with verified backend, frontend and product AGENTS.md sources\n' "$manifest" >&2; exit 1; }
sources=()
while IFS= read -r source || [ -n "$source" ]; do sources+=("$source"); done < "$manifest"
validate_rialto "${sources[@]}"
buffer=$(mktemp)
trap 'rm -f -- "$buffer"' EXIT
for source in "$worktree/CLAUDE.md" "$worktree/AGENTS.md" "${sources[@]}"; do
  [ -f "$source" ] && [ -r "$source" ] || { printf 'error: required project context is unreadable: %s\n' "$source" >&2; exit 1; }
  digest=$(shasum -a 256 "$source")
  digest=${digest%% *}
  printf '\n## Required instruction source: %s\nSHA-256: %s\n\n' "$source" "$digest"
  cat "$source"
  printf '\n'
done > "$buffer"
printf '\n## Project development context\nPreserve these requirements and source paths in every handoff and compaction summary.\nAfter compaction or changing checkout, reload these sources before dependent work.\n'
cat "$buffer"
