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

# gh accepts its persistent flags between `pr` and the subcommand it runs, so
# the scan skips option words and stops at the first real subcommand instead of
# testing the single word that follows `pr`. The subcommand list below must stay
# identical to PR_SUBCOMMANDS in bin/fm-worker-command-policy.mjs so both layers
# classify the same way; tests/fm-worker-merge-guard.test.sh fails when it drifts.
scan_words() {
  local word scanning=0
  for word in "$@"; do
    if [ "$scanning" -eq 1 ]; then
      case "$word" in
        merge) merge_shaped=1; scanning=0 ;;
        -*) : ;;
        checkout|checks|close|comment|create|diff|edit|list|lock|ready|reopen|revert|review|status|unlock|update-branch|view) scanning=0 ;;
        *) : ;;
      esac
    fi
    [ "$word" != pr ] || scanning=1
    case "$word" in
      *'/pulls/'*'/merge'|*'/pulls/'*'/merge?'*|*mergePullRequest*) merge_shaped=1 ;;
    esac
  done
}

scan_words "$@"

# Prevent creating a gh CLI alias whose literal expansion reaches a merge: the
# alias body arrives as one word, so re-split it and classify it the same way.
if [ "${1:-}" = alias ] && [ "${2:-}" = set ]; then
  set -f
  # shellcheck disable=SC2048,SC2086  # deliberate re-split of the alias body
  scan_words $*
  set +f
fi

if [ "$merge_shaped" -eq 1 ]; then
  echo "[worker-pr-merge] workers never merge PRs; report the full green PR URL and stop for captain approval" >&2
  exit 126
fi

exec "$REAL" "$@"
