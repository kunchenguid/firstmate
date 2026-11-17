#!/usr/bin/env bash
# fm-goal-probe-pr-merged.sh - the shared stage probe for a "PR merged" rung
# (see bin/fm-stage-ladder-lib.sh for the probe contract).
#
# Usage: fm-goal-probe-pr-merged.sh [<pr-url>]
#
# Without <pr-url> the pull request is the one recorded for the item's task:
# FM_GOAL_TASK names a task whose <state>/<task>.meta carries pr=<url>. Exit 0
# and the PR URL on stdout when the forge reports the pull request merged; exit
# 1 when it is open or closed unmerged; exit 2 when it cannot tell (no task, no
# recorded PR, an unsupported forge, an unreadable forge answer), so an unknown
# is never read as a merge. GitHub (gh, else gh-axi), GitLab, Forgejo and
# Gerrit are read through bin/fm-pr-lib.sh.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$DIR/fm-pr-lib.sh"

home=${FM_GOAL_HOME:-${FM_HOME:-$(cd "$DIR/.." && pwd)}}
state=${FM_STATE_OVERRIDE:-$home/state}
url=${1-}
if [ -z "$url" ]; then
  task=${FM_GOAL_TASK-}
  [ -n "$task" ] || { echo 'fm-goal-probe-pr-merged: no PR url and no FM_GOAL_TASK' >&2; exit 2; }
  fm_pr_task_id_valid "$task" || { echo "fm-goal-probe-pr-merged: unsafe task id: $task" >&2; exit 2; }
  fm_pr_metadata_identity_parse "$state/$task.meta" \
    || { echo "fm-goal-probe-pr-merged: no recorded PR for task $task" >&2; exit 2; }
  url=$FM_PR_META_URL
fi
fm_pr_url_parse "$url" || { echo "fm-goal-probe-pr-merged: not a pull request url: $url" >&2; exit 2; }
provider=$FM_PR_PROVIDER host=$FM_PR_HOST path=$FM_PR_PATH number=$FM_PR_NUMBER
FM_PR_RECORD_MERGED=
case "$provider" in
  github) fm_pr_github_read_record "$host" "$FM_PR_OWNER" "$FM_PR_REPO" "$number" ;;
  gitlab) fm_pr_gitlab_read_record "$host" "$path" "$number" ;;
  forgejo) fm_pr_forgejo_read_record "$host" "$path" "$number" ;;
  gerrit) fm_pr_gerrit_read_record "$host" "$number" ;;
  *) echo "fm-goal-probe-pr-merged: unsupported forge: $provider" >&2; exit 2 ;;
esac || { echo "fm-goal-probe-pr-merged: could not read $url" >&2; exit 2; }
case "${FM_PR_RECORD_MERGED-}" in
  true) printf '%s\n' "$url"; exit 0 ;;
  false) exit 1 ;;
  *) echo "fm-goal-probe-pr-merged: no merged answer for $url" >&2; exit 2 ;;
esac
