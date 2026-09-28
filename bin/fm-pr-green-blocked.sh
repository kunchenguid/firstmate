#!/usr/bin/env bash
# Read-only probe: is one open GitHub pull request green but unable to merge?
# bin/fm-watch.sh runs it beside an armed merge poll and owns the 30-minute
# episode timer and the single wake per episode; this script only reads the
# forge once and classifies what it saw.
#
# Prints exactly one line:
#   blocked <head-sha> <reason>
#                     every check is green (bin/fm-pr-lib.sh's
#                     fm_pr_github_checks_not_green owns what green means, the
#                     same rule bin/fm-pr-merge.sh gates on) and the pull
#                     request still cannot merge: a draft, conflicts with its
#                     base, a branch behind its base, or base-branch protection
#                     such as a missing review or required check; <head-sha> is
#                     the head commit the reading describes, so the caller can
#                     tell a re-pushed head that is blocked again from the same
#                     stuck head
#   clear             the stuck condition does not hold: the pull request is
#                     merged or closed, a check is red or pending, or GitHub
#                     reports it mergeable
# and nothing when the answer is unknown: a failed read, an unreadable payload,
# a missing head commit, a missing jq, or mergeability GitHub has not computed
# yet. The caller keeps its episode unchanged on silence, so a flaky read
# neither opens nor ends one.
# It never merges, updates a branch, or writes anything. GitLab and Gerrit are
# not probed: this is GitHub-only.
#
# Usage: fm-pr-green-blocked.sh <github-pull-request-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
[ "$#" -eq 1 ] || exit 0
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 0
command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0

json=$(gh pr view "$FM_PR_URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup 2>/dev/null) || exit 0
[ -n "$json" ] || exit 0
fields=$(printf '%s' "$json" | jq -r '
  if type == "object" then
    (.state // "" | tostring) + " " + (.mergeable // "" | tostring) + " " + (.mergeStateStatus // "" | tostring) + " " + (.headRefOid // "" | tostring)
  else error("not an object") end' 2>/dev/null) || exit 0
read -r state mergeable merge_state head <<EOF
$fields
EOF
draft=$(fm_pr_json_draft_state "$json")

case "$state" in
  OPEN) ;;
  MERGED|CLOSED) echo clear; exit 0 ;;
  *) exit 0 ;;
esac
red=$(fm_pr_github_checks_not_green "$json") || exit 0
if [ -n "$red" ]; then
  echo clear
  exit 0
fi
case "$head" in
  ''|*[!0-9a-fA-F]*) exit 0 ;;
esac

if [ "$draft" = true ]; then
  echo "blocked $head pull request is a draft"
elif [ "$mergeable" = CONFLICTING ] || [ "$merge_state" = DIRTY ]; then
  echo "blocked $head merge conflicts with the base branch"
elif [ "$merge_state" = BEHIND ]; then
  echo "blocked $head branch is behind the base branch"
elif [ "$merge_state" = BLOCKED ]; then
  echo "blocked $head base-branch protection refuses the merge (a required review or required check)"
else
  case "$merge_state" in
    CLEAN|HAS_HOOKS|UNSTABLE) echo clear ;;
  esac
fi
exit 0
