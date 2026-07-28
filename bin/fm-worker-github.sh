#!/usr/bin/env bash
# PATH-level worker wrapper for gh and gh-axi.
#
# fm-worker-guard-install.sh places generated gh/gh-axi launchers ahead of the
# worker PATH and routes them here with the pre-guard real executable path.
# Read, push, PR-create, review, comment, and CI operations exec unchanged.
# PR merge commands, merge API endpoints, mergePullRequest GraphQL mutations,
# and aliases created to reach those operations are refused without executing
# the real CLI. Firstmate's own environment never receives this PATH prefix, so
# an approved bin/fm-pr-merge.sh call remains functional.
#
# Usage: fm-worker-github.sh --tool <gh|gh-axi> --real <absolute-path> -- <args...>
set -eu

TOOL=
REAL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool) TOOL=${2:-}; shift 2 ;;
    --real) REAL=${2:-}; shift 2 ;;
    --) shift; break ;;
    *) echo "fm-worker-github: invalid wrapper invocation" >&2; exit 126 ;;
  esac
done
case "$TOOL" in gh|gh-axi) : ;; *) echo "fm-worker-github: invalid tool identity" >&2; exit 126 ;; esac
case "$REAL" in /*) [ -x "$REAL" ] || { echo "fm-worker-github: real $TOOL executable is unavailable" >&2; exit 126; } ;; *) echo "fm-worker-github: real executable must be absolute" >&2; exit 126 ;; esac

merge_shaped=0
previous=
for argument in "$@"; do
  if [ "$previous" = pr ] && [ "$argument" = merge ]; then
    merge_shaped=1
  fi
  case "$argument" in
    *'/pulls/'*'/merge'|*'/pulls/'*'/merge?'*|*mergePullRequest*) merge_shaped=1 ;;
  esac
  previous=$argument
done

# Prevent creating a gh CLI alias whose literal expansion reaches a merge.
if [ "${1:-}" = alias ] && [ "${2:-}" = set ]; then
  case "$*" in
    *'pr merge'*|*'/pulls/'*'/merge'*|*mergePullRequest*) merge_shaped=1 ;;
  esac
fi

if [ "$merge_shaped" -eq 1 ]; then
  echo "[worker-pr-merge] workers never merge PRs; report the full green PR URL and stop for captain approval" >&2
  exit 126
fi

exec "$REAL" "$@"
