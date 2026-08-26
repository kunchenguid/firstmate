#!/usr/bin/env bash
# Report whether a task's merge went through firstmate's recorded merge path
# (bin/fm-pr-merge.sh for a PR/MR, bin/fm-merge-local.sh for a local-only
# fast-forward), the only places that stamp a durable, firstmate-private
# provenance record at merge time (bin/fm-merge-attribution-lib.sh).
#
# This does NOT identify who merged: firstmate, every crewmate, and the
# captain act through the same forge identity, so a forge's merged-by field
# carries no information about who decided. This answers a narrower, checkable
# question instead - did this exact merge go through the one path firstmate
# uses - and a merge with no matching record reads as unattributed, never as
# firstmate's own, because that is exactly what a merge outside firstmate's
# control (a manual `gh pr merge`, a forge auto-merge, or anything else no
# crewmate is supposed to do) looks like.
#
# Usage: fm-merge-attribution.sh <task-id>
#   attributed: ...    (exit 0)  merged, and a matching recorded-path record exists
#   unattributed: ...  (exit 1)  merged, but no matching recorded-path record exists
#   unmerged: ...       (exit 2)  the task's PR/branch is not merged yet
#   error: ...          (exit 3)  usage, missing metadata, or a lookup failure
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-attribution-lib.sh
. "$SCRIPT_DIR/fm-merge-attribution-lib.sh"

if [ "$#" -ne 1 ]; then
  echo "error: usage: fm-merge-attribution.sh <task-id>" >&2
  exit 3
fi
ID=$1
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 3; }

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: task metadata is unavailable" >&2; exit 3; }

# report_attribution <method> <provider> <url> <live-head>: the one place that
# compares a live merged head against the recorded provenance and prints the
# corresponding verdict line. Returns 0 for attributed, 1 for unattributed.
report_attribution() {
  local method=$1 provider=$2 url=$3 live_head=$4
  if fm_merge_prov_read "$STATE" "$ID" \
    && [ "$FM_MERGE_PROV_METHOD" = "$method" ] \
    && [ "$FM_MERGE_PROV_PROVIDER" = "$provider" ] \
    && [ "$FM_MERGE_PROV_URL" = "$url" ] \
    && [ "$FM_MERGE_PROV_HEAD" = "$live_head" ]; then
    printf 'attributed: merged via the recorded path at %s (%s)\n' "$live_head" "$FM_MERGE_PROV_AT"
    return 0
  fi
  printf 'unattributed: no matching recorded-path provenance for the merge at %s\n' "$live_head"
  return 1
}

PR_LINE=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)

if [ -n "$PR_LINE" ]; then
  fm_pr_url_parse "$PR_LINE" || { echo "error: recorded pr= is not a valid PR URL" >&2; exit 3; }
  URL=$FM_PR_URL
  PROVIDER=$FM_PR_PROVIDER

  case "$PROVIDER" in
    github)
      command -v gh > /dev/null 2>&1 || { echo "error: checking a GitHub PR requires gh on PATH" >&2; exit 3; }
      GH_LINE=$(gh pr view "$URL" --json state,headRefOid -q '[.state, .headRefOid] | @tsv' 2> /dev/null) \
        || { echo "error: could not read the PR state" >&2; exit 3; }
      IFS=$'\t' read -r GH_STATE GH_HEAD <<< "$GH_LINE"
      if [ "$GH_STATE" != MERGED ]; then
        printf 'unmerged: %s is not merged\n' "$URL"
        exit 2
      fi
      fm_pr_head_valid "$GH_HEAD" || { echo "error: the PR reports no valid head commit" >&2; exit 3; }
      report_attribution pr-github github "$URL" "$GH_HEAD"
      ;;
    gitlab)
      command -v glab > /dev/null 2>&1 || { echo "error: checking a GitLab MR requires glab on PATH" >&2; exit 3; }
      command -v jq > /dev/null 2>&1 || { echo "error: checking a GitLab MR requires jq on PATH" >&2; exit 3; }
      PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
      GL_JSON=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "$PROJECT_URL" -F json 2> /dev/null) \
        && [ -n "$GL_JSON" ] || { echo "error: could not read the merge request state" >&2; exit 3; }
      GL_STATE=$(printf '%s' "$GL_JSON" | jq -r '.state // ""' 2> /dev/null) \
        || { echo "error: could not read the merge request state" >&2; exit 3; }
      if [ "$GL_STATE" != merged ]; then
        printf 'unmerged: %s is not merged\n' "$URL"
        exit 2
      fi
      GL_HEAD=$(printf '%s' "$GL_JSON" | jq -r '.sha // ""' 2> /dev/null) \
        || { echo "error: could not read the merged head commit" >&2; exit 3; }
      fm_pr_head_valid "$GL_HEAD" || { echo "error: the merge request reports no valid head commit" >&2; exit 3; }
      report_attribution pr-gitlab gitlab "$URL" "$GL_HEAD"
      ;;
    *)
      echo "error: unrecognized PR provider" >&2
      exit 3
      ;;
  esac
  exit 0
fi

# No pr= recorded. That is expected only for mode=local-only, whose merge is a
# fast-forward of the project's own default branch rather than a forge PR/MR
# (bin/fm-merge-local.sh requires that same mode=local-only before it will
# merge). A PR-based mode (direct-PR, no-mistakes) with no recorded pr= means
# the PR was never bound to this task through bin/fm-pr-check.sh - opened or
# merged by hand, say - and local git state (the fm/<id> branch's ancestry)
# says nothing about that PR, so guessing a verdict from it would be reporting
# on the wrong merge entirely.
MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$MODE" != local-only ]; then
  printf 'error: task mode is "%s" with no pr= recorded; the PR was never bound to this task, so its merge cannot be verified\n' \
    "${MODE:-unset}" >&2
  exit 3
fi

PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
[ -n "$PROJ" ] && [ -d "$PROJ" ] || { echo "error: task project is unavailable" >&2; exit 3; }
BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" > /dev/null \
  || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 3; }
DEFAULT=$(fm_merge_default_branch "$PROJ") \
  || { echo "error: cannot determine default branch for $PROJ" >&2; exit 3; }
if ! git -C "$PROJ" merge-base --is-ancestor "$BRANCH" "$DEFAULT" 2> /dev/null; then
  printf 'unmerged: %s is not merged into %s\n' "$BRANCH" "$DEFAULT"
  exit 2
fi
# The branch's own tip, not the default branch's live tip: a fast-forward
# leaves them equal at merge time, but the default branch keeps moving as
# later work lands while the already-merged branch ref does not, so comparing
# against its live tip would make an old, genuinely recorded-path merge read
# unattributed the moment anything else merges after it.
LOCAL_HEAD=$(git -C "$PROJ" rev-parse "$BRANCH")
report_attribution local-only "" "" "$LOCAL_HEAD"
