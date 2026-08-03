#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# A zero exit means the PR was confirmed merged at the forge, never merely that
# the merge command was accepted. Exit 3 is the distinct "not merged" outcome,
# including an auto-merge that is only queued, so a caller can never read a
# queued or rejected merge as landed work.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_requested_auto() {
  local arg
  for arg in "$@"; do
    [ "$arg" = --auto ] && return 0
  done
  return 1
}

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# The merge command exiting 0 is not proof the PR merged. gh-axi reports
# "status: ok" as soon as gh accepts the request, and `gh pr merge --auto`
# exits 0 after merely queueing an auto-merge that may never land. Firstmate's
# lifecycle treats a completed merge here as ground truth that the work is live
# and lets teardown discard the task's branch, so the merged state is confirmed
# from the forge before this script reports success. The state read is the same
# one bin/fm-pr-poll.sh uses as the watcher's merge authority, so both paths
# agree on what merged means; gh is necessarily present because gh-axi shells
# out to it, and an unreadable state is treated as not merged rather than
# assumed landed.
VERIFY_TIMEOUT=${FM_PR_MERGE_VERIFY_TIMEOUT:-30}
VERIFY_INTERVAL=${FM_PR_MERGE_VERIFY_INTERVAL:-2}
case "$VERIFY_TIMEOUT" in ''|*[!0-9]*) VERIFY_TIMEOUT=30 ;; esac
case "$VERIFY_INTERVAL" in ''|*[!0-9]*|0) VERIFY_INTERVAL=2 ;; esac

MERGED=
ELAPSED=0
while :; do
  STATE=$(gh pr view "$URL" --json state -q .state 2>/dev/null) || STATE=
  if [ "$STATE" = MERGED ]; then
    MERGED=yes
    break
  fi
  [ "$ELAPSED" -lt "$VERIFY_TIMEOUT" ] || break
  sleep "$VERIFY_INTERVAL"
  ELAPSED=$((ELAPSED + VERIFY_INTERVAL))
done

if [ -z "$MERGED" ]; then
  if caller_requested_auto "$@"; then
    echo "error: auto-merge was queued but $URL is not merged" >&2
  else
    echo "error: the merge was accepted but $URL is not merged" >&2
  fi
  echo "error: the task's work has not landed; do not tear it down" >&2
  exit 3
fi
printf 'merged: %s\n' "$URL"
