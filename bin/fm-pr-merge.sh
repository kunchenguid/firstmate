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
# including an auto-merge that is only queued or waiting in a merge queue, so a
# caller can never read a queued or rejected merge as landed work.
#
# The pr=/pr_head= recording above exists for one consumer: bin/fm-teardown.sh,
# which must prove a worktree's work landed before discarding it. That consumer
# only exists while the task does, and teardown removes state/<id>.meta itself,
# so requiring the metadata unconditionally made the sanctioned merge path stop
# working at exactly the point the work was finished. This script therefore
# resolves the task against durable evidence instead of assuming meta exists:
#
#   meta present   - live task, unchanged path: record pr=/pr_head= through
#                    bin/fm-pr-check.sh and refuse if that recording fails.
#   meta absent,   - torn-down task: nothing is left to discard unsafely, so
#   brief present    there is no landed-work check to satisfy. The merge is
#                    still confirmed at the forge and is recorded durably (see
#                    below) rather than into state teardown already removed.
#   neither        - unknown task, refused exactly as before.
#
# data/<id>/brief.md is the evidence because bin/fm-spawn.sh refuses to launch
# without it and no teardown path removes it, while state/<id>.meta is written
# by spawn and removed only by teardown. Meta present but not a plain file is
# still refused, so tampering is never read as teardown. A live task whose meta
# was lost some other way also lands here; that task can no longer be torn down
# at all (teardown reads the same file), so no landed-work guard is bypassed.
#
# Every confirmed merge appends one line to data/<id>/merge.md, which survives
# teardown. That record is history, not authority: a merge that is confirmed at
# the forge but cannot be recorded still exits 0 with a warning, because the
# exit code describes the forge's state and nothing else.
#
# The ordinary lifecycle still merges before cleanup; this path exists so an
# out-of-order teardown cannot force a hand merge at the forge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

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
BRIEF="$DATA/$ID/brief.md"

# Resolve the task against durable evidence. Only the absence of the metadata
# file counts as teardown; a present-but-irregular meta stays a refusal so a
# symlink or a directory can never be read as a finished task.
if [ -e "$META" ] || [ -L "$META" ]; then
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi
  TASK_STATE=live
elif [ -f "$BRIEF" ] && [ ! -L "$BRIEF" ]; then
  TASK_STATE=torn-down
else
  echo "error: task metadata is unavailable and no durable record of $ID exists" >&2
  exit 1
fi

# A live task still records the PR before merging, because its worktree has not
# been discarded yet and teardown's landed-work check reads that record. A
# torn-down task has no worktree left to protect and no metadata to record
# into, so it skips this step rather than re-arming state teardown removed.
if [ "$TASK_STATE" = live ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
fi

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
  # PR_STATE, not STATE: the state directory is still needed after this loop.
  PR_STATE=$(gh pr view "$URL" --json state -q .state 2>/dev/null) || PR_STATE=
  if [ "$PR_STATE" = MERGED ]; then
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

# Only now, past the forge confirmation, is there a merge to record. The merge
# commit is read best-effort and is supplementary: it never gates the outcome,
# and an unreadable one is recorded as unavailable rather than retried.
MERGE_COMMIT=$(gh pr view "$URL" --json mergeCommit -q .mergeCommit.oid 2>/dev/null) || MERGE_COMMIT=
fm_pr_head_valid "$MERGE_COMMIT" || MERGE_COMMIT=unavailable

record_merge() {
  local dir="$DATA/$ID" record="$DATA/$ID/merge.md"
  mkdir -p "$dir" || return 1
  [ -s "$record" ] || printf '# Merge record: %s\n\n' "$ID" > "$record" || return 1
  printf -- '- %s %s confirmed merged at the forge; merge commit %s; task %s at merge\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$URL" "$MERGE_COMMIT" "$TASK_STATE" >> "$record"
}

record_merge || echo "warning: $URL merged but the merge record could not be written" >&2
printf 'merged: %s\n' "$URL"
