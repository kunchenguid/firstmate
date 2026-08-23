#!/usr/bin/env bash
# Report whether a project's default branch is currently red, derived live from
# GitHub rather than rediscovered by each worker reproducing on the baseline by
# hand. A red default branch poisons every branch built on top of it, so this
# is one fast API read a worker (or firstmate) can run BEFORE blaming its own
# branch for a failing check.
# Usage: fm-main-health.sh [<project-dir>]
# <project-dir> defaults to the current directory and must have a GitHub
# origin remote. Prints exactly one of:
#   GREEN: <owner>/<repo>@<default> is healthy at <sha>
#   PENDING: <owner>/<repo>@<default>'s latest CI run has not finished (<sha>): <url>
#   RED: <owner>/<repo>@<default> is currently failing at <sha>: <url>
# and exits 0 for GREEN/PENDING (nothing to blame on the baseline), 1 for RED
# (the baseline itself is broken), or 2 when health cannot be determined at all
# (missing gh/jq, no GitHub remote, no workflow runs, or the API call failed or
# timed out) - a caller must not treat exit 2 as either a clean or a red verdict.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "error: main-health check requires gh on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: main-health check requires jq on PATH" >&2; exit 2; }

REMOTE=$(git -C "$DIR" remote get-url origin 2>/dev/null) || {
  echo "error: $DIR has no origin remote" >&2
  exit 2
}
REPO=$(printf '%s' "$REMOTE" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##')
[ -n "$REPO" ] || { echo "error: origin remote is not a GitHub repository: $REMOTE" >&2; exit 2; }

DEFAULT=$(fm_default_branch "$DIR") || { echo "error: cannot determine default branch for $DIR" >&2; exit 2; }

FM_MAIN_HEALTH_TIMEOUT=${FM_MAIN_HEALTH_TIMEOUT:-20}
case "$FM_MAIN_HEALTH_TIMEOUT" in ''|*[!0-9]*|0) FM_MAIN_HEALTH_TIMEOUT=20 ;; esac

OUT=$(fm_run_timed "$FM_MAIN_HEALTH_TIMEOUT" \
  env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
  gh run list --repo "$REPO" --branch "$DEFAULT" --limit 1 \
    --json conclusion,status,headSha,url 2>/dev/null) || {
  echo "error: could not read CI status for $REPO@$DEFAULT" >&2
  exit 2
}

COUNT=$(printf '%s' "$OUT" | jq 'length' 2>/dev/null || echo 0)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac
[ "$COUNT" -ge 1 ] || { echo "error: no CI runs found for $REPO@$DEFAULT" >&2; exit 2; }

STATUS=$(printf '%s' "$OUT" | jq -r '.[0].status')
CONCLUSION=$(printf '%s' "$OUT" | jq -r '.[0].conclusion')
SHA=$(printf '%s' "$OUT" | jq -r '.[0].headSha')
URL=$(printf '%s' "$OUT" | jq -r '.[0].url')

if [ "$STATUS" != completed ]; then
  echo "PENDING: $REPO@$DEFAULT's latest CI run has not finished ($SHA): $URL"
  exit 0
fi

case "$CONCLUSION" in
  success)
    echo "GREEN: $REPO@$DEFAULT is healthy at $SHA"
    exit 0
    ;;
  failure|timed_out|cancelled|action_required)
    echo "RED: $REPO@$DEFAULT is currently failing at $SHA: $URL"
    exit 1
    ;;
  *)
    echo "error: unrecognized CI conclusion '$CONCLUSION' for $REPO@$DEFAULT" >&2
    exit 2
    ;;
esac
