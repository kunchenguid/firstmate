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
# The merge is refused unless the task's recorded evidence commit
# (evidence_head=, written by bin/fm-evidence-record.sh) equals the pull
# request's live head. A validation pipeline can commit after the worker's last
# measurement, which silently turns a reported suite figure or exploit result
# into a description of an earlier commit; this guard is what makes that
# staleness stop a merge instead of depending on a manual comparison.
#
# An absent record refuses too, rather than warning and merging. A guard that
# passes when nothing was recorded is defeatable by simply never recording, and
# nothing distinguishes "no claim was made" from "the claim was lost". The
# remedy is one command that records the commit the evidence was measured on,
# not a bypass flag, so a task that predates this record is never stranded and
# the guarantee is never traded away to unblock one merge.
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

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Evidence guard, before any state is recorded or any poll is armed: a refused
# merge must leave the task exactly as it found it.
if ! fm_pr_evidence_read "$META"; then
  echo "error: refusing to merge $URL: the evidence record for task $ID is unreadable or malformed" >&2
  echo "  fix: re-record the commit the reported verification was measured on:" >&2
  echo "    $SCRIPT_DIR/fm-evidence-record.sh $ID <commit it was measured on> '<what was measured>'" >&2
  exit 1
fi
EVIDENCE_HEAD=$FM_PR_EVIDENCE_HEAD
EVIDENCE_NOTE=$FM_PR_EVIDENCE_NOTE

if [ -z "$EVIDENCE_HEAD" ]; then
  echo "error: refusing to merge $URL: no verification evidence commit is recorded for task $ID" >&2
  echo "  expected: the commit the reported verification was measured on" >&2
  echo "  found:    no evidence record" >&2
  echo "  fix: re-run the verification you intend to merge on, then record it:" >&2
  echo "    $SCRIPT_DIR/fm-evidence-record.sh $ID <commit it was measured on> '<what was measured>'" >&2
  exit 1
fi

# The live head is read here rather than taken from a recorded pr_head=, so the
# comparison is always against what would actually merge.
LIVE_HEAD=
if command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json headRefOid -q .headRefOid 2>/dev/null); then
    LIVE_HEAD=$(printf '%s' "$REMOTE_HEAD" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  fi
fi
if ! fm_pr_head_valid "$LIVE_HEAD"; then
  echo "error: refusing to merge $URL: the pull request head could not be confirmed" >&2
  echo "  the recorded evidence commit for task $ID is $EVIDENCE_HEAD" >&2
  echo "  without the live head there is nothing to compare it against, so the merge stops here" >&2
  echo "  fix: restore GitHub access (gh auth status), then merge again" >&2
  exit 1
fi

if [ "$LIVE_HEAD" != "$EVIDENCE_HEAD" ]; then
  echo "error: refusing to merge $URL: the reported evidence was measured on a commit that is no longer this pull request's head" >&2
  if [ -n "$EVIDENCE_NOTE" ]; then
    echo "  evidence measured on: $EVIDENCE_HEAD ($EVIDENCE_NOTE)" >&2
  else
    echo "  evidence measured on: $EVIDENCE_HEAD" >&2
  fi
  echo "  pull request head:    $LIVE_HEAD" >&2
  echo "  fix: re-run that verification on $LIVE_HEAD, then record the result:" >&2
  echo "    $SCRIPT_DIR/fm-evidence-record.sh $ID $LIVE_HEAD '<what was measured>'" >&2
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
