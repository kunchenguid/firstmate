#!/usr/bin/env bash
# Report whether a project's default branch is currently red, derived live from
# its forge rather than rediscovered by each worker reproducing on the baseline
# by hand. A red default branch poisons every branch built on top of it, so this
# is one fast API read a worker (or firstmate) can run BEFORE blaming its own
# branch for a failing check.
# Usage: fm-main-health.sh [<project-dir>]
# <project-dir> defaults to the current directory and must have an origin
# remote on GitHub or GitLab, hosted or self-hosted - the same two forges
# bin/fm-pr-lib.sh already addresses for PR/MR polling, so this command is not
# coupled to one vendor. Any other origin is undetermined (exit 2), never a
# guessed GREEN or RED.
# On GitHub, health is the aggregate of every check run reported against the
# default branch's HEAD commit (all workflows, all apps), not just the single
# most-recently-started run - a repo can run several workflows on the same push
# and the latest-started one need not be the project's actual gate. On GitLab,
# every job already aggregates into one pipeline per commit, so health is that
# pipeline's own status.
# Prints exactly one of:
#   GREEN: <repo>@<default> is healthy at <sha>
#   PENDING: <repo>@<default>'s latest CI run has not finished (<sha>): <url>
#   RED: <repo>@<default> is currently failing at <sha>: <url>
# and exits 0 for GREEN/PENDING (nothing to blame on the baseline), 1 for RED
# (the baseline itself is broken), or 2 when health cannot be determined at all
# (missing gh/glab/jq, no recognized GitHub or GitLab remote, no CI run
# recorded, or the API call failed or timed out) - a caller must not treat exit
# 2 as either a clean or a red verdict.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "error: main-health check requires jq on PATH" >&2; exit 2; }

REMOTE=$(git -C "$DIR" remote get-url origin 2>/dev/null) || {
  echo "error: $DIR has no origin remote" >&2
  exit 2
}

# Split the origin remote into HOST and REPO_PATH, covering the URL forms and
# the scp-like [user@]host:path form bin/fm-pr-lib.sh already parses for PR/MR
# URLs. github.com is the one forge addressed by owner/repository; every other
# host is addressed as GitLab, hosted or self-hosted - the same two-forge split
# bin/fm-pr-merge.sh already applies to a recorded PR/MR, so this check is not
# coupled to one vendor.
HOST=
REPO_PATH=
case "$REMOTE" in
  https://*|http://*|ssh://*|git://*)
    _rest=${REMOTE#*://}
    case "$_rest" in *@*) _rest=${_rest#*@} ;; esac
    HOST=${_rest%%/*}
    HOST=${HOST%%:*}
    REPO_PATH=${_rest#*/}
    ;;
  *@*:*)
    _rest=${REMOTE#*@}
    HOST=${_rest%%:*}
    REPO_PATH=${_rest#*:}
    ;;
  *)
    echo "error: origin remote is not a recognized GitHub or GitLab URL: $REMOTE" >&2
    exit 2
    ;;
esac
REPO_PATH=${REPO_PATH%.git}
REPO_PATH=${REPO_PATH#/}
[ -n "$HOST" ] && [ -n "$REPO_PATH" ] || {
  echo "error: origin remote is not a recognized GitHub or GitLab URL: $REMOTE" >&2
  exit 2
}

DEFAULT=$(fm_default_branch "$DIR") || { echo "error: cannot determine default branch for $DIR" >&2; exit 2; }

FM_MAIN_HEALTH_TIMEOUT=${FM_MAIN_HEALTH_TIMEOUT:-20}
case "$FM_MAIN_HEALTH_TIMEOUT" in ''|*[!0-9]*|0) FM_MAIN_HEALTH_TIMEOUT=20 ;; esac

if [ "$HOST" = github.com ]; then
  command -v gh >/dev/null 2>&1 || { echo "error: main-health check requires gh on PATH" >&2; exit 2; }

  REPO=$REPO_PATH

  SHA=$(fm_run_timed "$FM_MAIN_HEALTH_TIMEOUT" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh api "repos/$REPO/commits/$DEFAULT" --jq '.sha' 2>/dev/null) || {
    echo "error: could not resolve HEAD commit for $REPO@$DEFAULT" >&2
    exit 2
  }
  SHA=$(printf '%s' "$SHA" | tr -d '[:space:]')
  [ -n "$SHA" ] || { echo "error: could not resolve HEAD commit for $REPO@$DEFAULT" >&2; exit 2; }

  # Every check run reported against the commit, from every workflow and app -
  # the same aggregate-check shape bin/fm-bearings-snapshot.sh already applies
  # to a PR's statusCheckRollup, applied here to the default branch's HEAD.
  OUT=$(fm_run_timed "$FM_MAIN_HEALTH_TIMEOUT" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh api "repos/$REPO/commits/$SHA/check-runs" -f per_page=100 \
      --jq '.check_runs' 2>/dev/null) || {
    echo "error: could not read CI status for $REPO@$DEFAULT" >&2
    exit 2
  }

  URL="https://github.com/$REPO/commit/$SHA/checks"
  VERDICT=$(printf '%s' "$OUT" | jq -r '
    if (length) == 0 then "none"
    elif any(.[]; (.conclusion // "") as $c
        | ($c=="failure" or $c=="timed_out" or $c=="cancelled" or $c=="action_required" or $c=="startup_failure"))
      then "failing"
    elif any(.[]; (.status // "") != "completed") then "pending"
    else "passing" end
  ' 2>/dev/null) || VERDICT=none
else
  command -v glab >/dev/null 2>&1 || {
    echo "error: main-health check requires glab on PATH for a non-GitHub origin" >&2
    exit 2
  }

  REPO="$HOST/$REPO_PATH"
  # glab resolves the instance from the project URL passed to -R, so the host
  # is rebuilt from the parsed remote rather than read from any ambient
  # default, and GITLAB_HOST is set to the same host for the same reason (see
  # bin/fm-pr-merge.sh, which applies this pairing to a recorded MR).
  PROJECT_URL="https://$HOST/$REPO_PATH"
  # The project path is percent-encoded into the endpoint itself, the same way
  # bin/fm-main-health.sh addresses GitHub by literal owner/repo above, rather
  # than relying on glab's own repo-context substitution.
  ENCODED_PATH=${REPO_PATH//\//%2F}

  # GitLab already aggregates every job under one pipeline per commit, so one
  # call for the branch's HEAD commit carries both the sha and that pipeline's
  # status - no separate check-runs read is needed the way GitHub requires.
  OUT=$(fm_run_timed "$FM_MAIN_HEALTH_TIMEOUT" \
    env GITLAB_HOST="$HOST" \
    glab api "projects/$ENCODED_PATH/repository/commits/$DEFAULT" -R "$PROJECT_URL" 2>/dev/null) || {
    echo "error: could not read CI status for $REPO@$DEFAULT" >&2
    exit 2
  }

  SHA=$(printf '%s' "$OUT" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$SHA" ] || { echo "error: could not resolve HEAD commit for $REPO@$DEFAULT" >&2; exit 2; }

  URL=$(printf '%s' "$OUT" | jq -r '.last_pipeline.web_url // empty' 2>/dev/null)
  [ -n "$URL" ] || URL="https://$HOST/$REPO_PATH/-/commits/$SHA"

  VERDICT=$(printf '%s' "$OUT" | jq -r '
    (.last_pipeline.status // "none") as $s
    | if $s == "none" then "none"
      elif ($s == "failed" or $s == "canceled") then "failing"
      elif $s == "success" then "passing"
      else "pending" end
  ' 2>/dev/null) || VERDICT=none
fi

case "$VERDICT" in
  none)
    echo "error: no CI checks found for $REPO@$DEFAULT" >&2
    exit 2
    ;;
  pending)
    echo "PENDING: $REPO@$DEFAULT's latest CI run has not finished ($SHA): $URL"
    exit 0
    ;;
  failing)
    echo "RED: $REPO@$DEFAULT is currently failing at $SHA: $URL"
    exit 1
    ;;
  passing)
    echo "GREEN: $REPO@$DEFAULT is healthy at $SHA"
    exit 0
    ;;
esac
