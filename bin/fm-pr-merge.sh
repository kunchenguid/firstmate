#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# A PR whose task has no runtime record at all - state/<id>.meta absent, as
# happens when a real PR outlives the session that raised it - is still merged,
# because refusing it only pushes the caller to call gh-axi directly and step
# around this path. Nothing is recorded for such a PR and no merge poll is
# armed, so the reduced guarantee is printed in full on stderr rather than left
# silent. Anything else occupying the metadata path - a symlink, a directory -
# is a tampering signal, not an absent record, and keeps the original refusal.
# bin/fm-pr-check.sh deliberately does NOT get the same treatment: its product
# is a durable merge poll whose validation is bound to the task's recorded
# metadata identity (fm_pr_poll_artifacts_valid in bin/fm-pr-lib.sh, re-checked
# by the watcher and by bin/fm-pr-check-migrate.sh), and there is no task to
# wake for anyway. This path therefore skips it instead of relaxing it.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
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

# Name every guarantee this merge does not carry, so an unrecorded PR is an
# informed choice rather than a silent downgrade.
report_unrecorded_pr() {
  echo "notice: no runtime record at state/$ID.meta, merging $URL as an unrecorded PR" >&2
  echo "notice: not recorded: pr=$URL, so bin/fm-teardown.sh has no PR reference to verify landed work for $ID after a squash merge" >&2
  echo "notice: not recorded: pr_head=, so bin/fm-review-diff.sh cannot pin the reviewed head for $ID" >&2
  echo "notice: not armed: the merge poll, so no wake follows this merge" >&2
  echo "notice: unchanged: the merge itself, including the checks bar, which gh-axi pr merge and the forge still decide for $PR_OWNER/$PR_REPO#$PR_NUMBER" >&2
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ -f "$META" ] && [ ! -L "$META" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
elif [ -e "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
else
  report_unrecorded_pr
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
