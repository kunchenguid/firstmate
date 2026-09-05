#!/usr/bin/env bash
# Refresh the GitNexus knowledge-graph index for a project's default branch, so
# workers query one evolving main-index instead of re-analyzing the repo on
# every task. Called after a clean project-clone refresh: bin/fm-fleet-sync.sh's
# per-project fast-forward (both the bootstrap sweep and a post-PR-merge
# refresh) and bin/fm-merge-local.sh's guarded local-only landing are the two
# scripts that actually move a project clone's default branch, so they are this
# step's only two callers (one owner per refresh path; bin/fm-pr-merge.sh lands
# the remote PR but never touches the local clone itself, so it needs no hook).
#
# NEVER mutates the project clone. `gitnexus analyze` was once run directly
# against a worker's project copy and wrote GitNexus boilerplate into that
# copy's AGENTS.md; firstmate never writes to a project (AGENTS.md hard rule
# #1). `--index-only` suppresses that AGENTS.md/CLAUDE.md/skills injection, but
# verified empirically (see tests/fm-gitnexus-reindex.test.sh) it still creates
# a `.gitnexus/` directory and appends a `.gitnexus/` line to `.git/info/exclude`
# inside whatever tree it indexes - so even with that flag, indexing the project
# clone directly would still write into it. Instead, this script indexes a
# dedicated local mirror clone it owns exclusively, under
# $FM_HOME/state/gitnexus-mirrors/<label>, fetched and fast-forwarded from the
# project clone (a local, read-only `git fetch`/`git clone` of that path) but
# never written back to it. `gitnexus analyze --index-only --name fm-<label>`
# then runs against that mirror only, and registers the mirror under a stable
# `fm-<label>` alias so a worker's query targets that alias regardless of the
# mirror's path.
#
# Fail-soft: gitnexus missing, an unreadable project, or any mirror/analyze
# failure prints one "WARN:" line to stderr and this script still exits 0, so a
# fleet sync or a merge never fails because the index step failed.
# Usage: fm-gitnexus-reindex.sh <project-path>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
MIRRORS_DIR="${FM_GITNEXUS_MIRRORS_OVERRIDE:-$FM_HOME/state/gitnexus-mirrors}"

warn() {
  echo "gitnexus-reindex: WARN: $*" >&2
}

PROJ=${1:?usage: fm-gitnexus-reindex.sh <project-path>}

command -v gitnexus >/dev/null 2>&1 || { warn "gitnexus not installed, skipping"; exit 0; }
[ -d "$PROJ" ] || { warn "project path not found: $PROJ, skipping"; exit 0; }

proj_abs=$(cd "$PROJ" 2>/dev/null && pwd -P) || { warn "cannot resolve $PROJ, skipping"; exit 0; }
label=$(basename "$proj_abs")
mirror="$MIRRORS_DIR/$label"

head_sha=$(git -C "$proj_abs" rev-parse HEAD 2>/dev/null) || { warn "cannot read HEAD of $proj_abs, skipping"; exit 0; }

mkdir -p "$MIRRORS_DIR" 2>/dev/null || { warn "cannot create $MIRRORS_DIR, skipping"; exit 0; }

if [ -d "$mirror/.git" ]; then
  if ! git -C "$mirror" fetch --quiet origin >/dev/null 2>&1 \
      || ! git -C "$mirror" checkout --quiet --detach "$head_sha" >/dev/null 2>&1; then
    warn "cannot refresh mirror for $label, skipping"
    exit 0
  fi
else
  rm -rf "$mirror" 2>/dev/null
  if ! git clone --quiet "$proj_abs" "$mirror" >/dev/null 2>&1; then
    warn "cannot create mirror for $label, skipping"
    exit 0
  fi
  git -C "$mirror" checkout --quiet --detach "$head_sha" >/dev/null 2>&1 || true
fi

if ! gitnexus analyze --index-only --name "fm-$label" "$mirror" >/dev/null 2>&1; then
  warn "gitnexus analyze failed for $label, skipping"
  exit 0
fi

echo "$label: gitnexus index refreshed at $head_sha"
