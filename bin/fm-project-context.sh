#!/usr/bin/env bash
# Render required project instructions for a worker launch or context recovery.
# Usage: fm-project-context.sh <project-dir> <worktree> <config-dir>
# Opt in with config/project-context/<project-basename>.paths, one required file
# per line. Relative paths resolve in the actual worker worktree; absolute paths
# can name paired repositories. Blank lines and # comments are ignored. No shell
# or Markdown import expansion occurs. CLAUDE.md and AGENTS.md in the worktree are
# required automatically when the manifest exists. Output is buffered so a missing
# source never publishes a partial prompt. Source paths and SHA-256 bind the bytes.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,11p' "$0"
  exit 0
fi
[ "$#" -eq 3 ] || { echo 'usage: fm-project-context.sh <project-dir> <worktree> <config-dir>' >&2; exit 2; }
project=$1
worktree=$(cd "$2" && pwd -P)
config=$3
manifest="$config/project-context/$(basename "$project").paths"
[ -f "$manifest" ] || exit 0
buffer=$(mktemp)
trap 'rm -f -- "$buffer"' EXIT
{
  printf '%s\n' 'CLAUDE.md' 'AGENTS.md'
  cat "$manifest"
} | while IFS= read -r source || [ -n "$source" ]; do
  case "$source" in ''|'#'*) continue ;; /*) ;; *) source="$worktree/$source" ;; esac
  [ -f "$source" ] && [ -r "$source" ] || { printf 'error: required project context is unreadable: %s\n' "$source" >&2; exit 1; }
  digest=$(shasum -a 256 "$source")
  digest=${digest%% *}
  printf '\n## Required instruction source: %s\nSHA-256: %s\n\n' "$source" "$digest"
  cat "$source"
  printf '\n'
done > "$buffer"
printf '\n## Project development context\nPreserve these requirements and source paths in every handoff and compaction summary.\nAfter compaction or changing checkout, reload these sources before dependent work.\n'
cat "$buffer"
