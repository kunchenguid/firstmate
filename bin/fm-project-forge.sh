#!/usr/bin/env bash
# Resolve the forge route for a project from its origin and print worker-ready
# instructions. A GitHub origin uses gh-axi, an authenticated GitLab origin
# uses glab plus ordinary git push, and an unknown or conflicting origin stops
# with a concrete ambiguity instead of guessing.
# Usage: fm-project-forge.sh <project-dir>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

REPO=${1:-}
[ "$#" -eq 1 ] && [ -n "$REPO" ] || {
  echo "usage: fm-project-forge.sh <project-dir>" >&2
  exit 2
}

if ! fm_project_forge_from_repo "$REPO"; then
  fm_project_forge_instructions ambiguous
  echo "error: $FM_PROJECT_FORGE_ERROR" >&2
  exit 1
fi
fm_project_forge_instructions resolved
