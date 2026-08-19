#!/usr/bin/env bash
# Record the exact commit a task's reported verification evidence was measured
# on, into that task's durable metadata as evidence_head=<sha> plus an optional
# one-line evidence_note=<what was measured>. Re-running replaces the previous
# record, so a re-measurement is recorded the same way as the first one.
#
# bin/fm-pr-merge.sh refuses to merge unless evidence_head equals the pull
# request's live head. A validation pipeline can commit after the worker's last
# measurement - a fix round, a documentation step, a rebase onto a newer base -
# which silently turns a reported suite figure or exploit result into a
# description of an earlier commit. Recording the measured commit is what makes
# that staleness detectable instead of a manual comparison someone has to
# remember to perform.
#
# Run it from the task worktree immediately after the verification run it
# describes, and run it again after every re-measurement:
#   bin/fm-evidence-record.sh <task-id> "$(git rev-parse HEAD)" 'full suite 4208 pass; injection exploit blocked'
#
# The note is one printable line of at most 200 characters and is quoted into
# the refusal message so a stale merge says what has to be re-measured. A note
# carrying a newline or control character is refused rather than trimmed,
# because a silently trimmed note is a silently wrong instruction.
# Usage: fm-evidence-record.sh <task-id> <commit-sha> [one-line note]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# An interrupted write must leave the state directory exactly as it found it:
# no half-written temp beside the metadata, and no per-task lock another
# process would have to reclaim through stale-owner recovery. This mirrors
# bin/fm-pr-check.sh, the other writer of this same record.
trap fm_pr_evidence_cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "error: invalid evidence record request" >&2
  echo "usage: fm-evidence-record.sh <task-id> <commit-sha> [one-line note]" >&2
  exit 2
fi
ID=$1
RAW_HEAD=$2
NOTE=${3-}

if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid evidence record request" >&2
  exit 2
fi
HEAD_SHA=$(printf '%s' "$RAW_HEAD" | tr '[:upper:]' '[:lower:]')
if ! fm_pr_head_valid "$HEAD_SHA"; then
  echo "error: '$RAW_HEAD' is not a full commit SHA; pass \"\$(git rev-parse HEAD)\"" >&2
  exit 2
fi
if ! fm_pr_evidence_note_valid "$NOTE"; then
  echo "error: the note must be one printable line of at most 200 characters" >&2
  exit 2
fi

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

if ! fm_pr_evidence_write "$META" "$HEAD_SHA" "$NOTE"; then
  echo "error: could not record the evidence commit for task $ID" >&2
  exit 1
fi

if [ -n "$NOTE" ]; then
  printf 'recorded: %s evidence measured on %s (%s)\n' "$ID" "$HEAD_SHA" "$NOTE"
else
  printf 'recorded: %s evidence measured on %s\n' "$ID" "$HEAD_SHA"
fi
