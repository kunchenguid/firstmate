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
# --torn-down merges a PR whose task has already been cleaned up, so a late
# merge keeps the guarded path instead of reaching around it to a raw merge
# command. It requires the task metadata to be genuinely absent, refusing when
# the task is still live so it can never be used to skip recording or the merge
# poll for a task that has both. An irregular metadata path is refused by both
# paths as something to inspect rather than merged around. Absent metadata alone
# is not enough, because an invented or mistyped id has none either, so the flag
# also requires positive evidence that the task genuinely existed: either the
# data/<task-id>/brief.md that bin/fm-brief.sh writes at brief time and teardown
# leaves in place, or a completed backlog entry for the id in data/backlog.md or
# data/done-archive.md.
# With no metadata to record into and no live task for a merge poll to wake, the
# merge is recorded in the durable ledger data/merged-prs.log as one
# <utc-timestamp><TAB><task-id><TAB><pr-url> line. The ledger path is validated
# before the merge, but the line is appended only after gh-axi pr merge reports
# success, so the ledger never asserts a merge that did not happen; a failed
# merge writes no line and exits with the merge command's own status. Every
# failure after that successful merge names the merge as done and the recording
# step that failed, so a non-zero exit is never read as an unmerged PR.
# Usage: fm-pr-merge.sh [--torn-down] <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

TORN_DOWN=0
if [ "${1:-}" = "--torn-down" ]; then
  TORN_DOWN=1
  shift
fi

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

# Positive evidence that a torn-down task genuinely existed: bin/fm-brief.sh
# writes data/<id>/brief.md at brief time and teardown leaves it in place, and
# the task's completed backlog row survives in data/backlog.md until retention
# rolls it into the archive. A row counts as completed when it is checked or sits
# under a Done heading. The row shape matches backlog_key_section in
# bin/fm-backlog-handoff.sh - the id is the first whitespace-delimited token
# after the marker, compared whole - so a hand-edited row with no title
# separator still counts and no other id's prefix can match.
torn_down_task_recorded() {  # <task-id>
  local id=$1 file
  [ -f "$DATA/$id/brief.md" ] && return 0
  for file in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    [ -f "$file" ] || continue
    awk -v id="$id" '
      /^##[ \t]+/ {
        heading = $0
        sub(/^##[ \t]+/, "", heading)
        sub(/[ \t]+$/, "", heading)
        in_done = (heading == "Done")
        next
      }
      {
        row = ""
        checked = 0
        if (match($0, /^[-*][ \t]+\[[ xX]\][ \t]+/)) {
          checked = (substr($0, RSTART, RLENGTH) ~ /\[[xX]\]/)
          row = substr($0, RSTART + RLENGTH)
          sub(/[ \t].*$/, "", row)
          sub(/\r$/, "", row)
        } else if (match($0, /^[-*][ \t]+\*\*[^*]+\*\*/)) {
          row = substr($0, RSTART, RLENGTH)
          sub(/^[-*][ \t]+\*\*/, "", row)
          sub(/\*\*$/, "", row)
        }
        if (row == id && (checked || in_done)) {
          hit = 1
          exit
        }
      }
      END { exit(hit ? 0 : 1) }
    ' "$file" && return 0
  done
  return 1
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
LEDGER=
# A symlink, directory, or other irregular metadata path is neither live
# metadata nor a cleaned-up task, so both paths refuse it as something to
# inspect rather than sending the caller to a flag that also refuses.
if [ -L "$META" ] || { [ -e "$META" ] && [ ! -f "$META" ]; }; then
  echo "error: irregular task metadata at $META; inspect it before merging task $ID's PR" >&2
  exit 1
fi
if [ "$TORN_DOWN" = 1 ]; then
  if [ -e "$META" ]; then
    echo "error: task $ID still has metadata; merge it without --torn-down" >&2
    exit 1
  fi
  if ! torn_down_task_recorded "$ID"; then
    echo "error: no record of a cleaned-up task $ID; --torn-down needs $DATA/$ID/brief.md or a completed $ID entry in $DATA/backlog.md or $DATA/done-archive.md" >&2
    exit 1
  fi
  LEDGER="$DATA/merged-prs.log"
  umask 077
  mkdir -p "$DATA" || exit 1
  if [ -L "$LEDGER" ] || { [ -e "$LEDGER" ] && [ ! -f "$LEDGER" ]; }; then
    echo "error: merge ledger is unavailable" >&2
    exit 1
  fi
else
  if [ ! -e "$META" ]; then
    echo "error: task metadata is unavailable; merge a cleaned-up task's PR with --torn-down" >&2
    exit 1
  fi

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

MERGE_RC=0
gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@" \
  || MERGE_RC=$?
[ "$MERGE_RC" -eq 0 ] || exit "$MERGE_RC"

if [ -n "$LEDGER" ]; then
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$URL" >> "$LEDGER" || {
    echo "error: PR $URL merged but merge ledger recording failed" >&2
    exit 1
  }
  chmod 0600 "$LEDGER" || {
    echo "error: PR $URL merged and recorded but tightening merge ledger permissions failed" >&2
    exit 1
  }
fi
