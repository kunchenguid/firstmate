#!/usr/bin/env bash
# Attended merge for a pull request whose task record is already gone
# (post-teardown), with the guards a raw `gh pr merge` path loses.
#
# Usage: fm-pr-merge-detached.sh <pr-url> [--method merge|squash|rebase]
#
# The normal path for a task merge is bin/fm-pr-merge.sh, which refuses once
# the task record is torn down because its recording surfaces are gone. Until
# this script existed that refusal pushed every post-teardown merge onto raw
# forge commands with no green gate, no head binding, and no record (observed
# live: four merges in one programme shipped that way). This script is the
# recorded replacement, and ONLY that: a task that still has its record goes
# through bin/fm-pr-merge.sh, and this script refuses when any task metadata in
# this home already binds the same pull request.
#
# Guards, all read live at merge time:
#   - Attended only: refuses while an away-posture record exists, because a
#     detached pull request has no task record to resolve merge authority from.
#     The operator's decision to run this is the captain's relayed word for
#     THIS merge, exactly as it is on the attended yolo-off path.
#   - Green gate: open, non-draft, MERGEABLE, not DIRTY, and every reported
#     check green (SUCCESS / NEUTRAL / SKIPPED check runs, SUCCESS status
#     contexts). A pending, failed, or unreadable rollup refuses.
#   - Head binding: the merge carries --match-head-commit for the exact head
#     this run verified, so a push that lands in between is refused by GitHub.
#   - Proved outcome: the merge counts only when the pull request reads back
#     state=MERGED, merged=true; anything else is reported as unproved and the
#     script exits nonzero.
#   - Recorded: an append-only line lands in state/pr-merge-ledger.log with the
#     URL, verified head, and method. This log is the durable merge metadata
#     the task-recorded path keeps in task metadata.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

URL=
METHOD=merge
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method)
      [ "$#" -ge 2 ] || { echo "error: --method requires a value" >&2; exit 2; }
      METHOD=$2
      shift 2
      ;;
    --method=*)
      METHOD=${1#*=}
      shift
      ;;
    --merge|--squash|--rebase)
      METHOD=${1#--}
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      usage 2 >&2
      ;;
    *)
      [ -z "$URL" ] || { echo "error: exactly one pull request URL is required" >&2; exit 2; }
      URL=$1
      shift
      ;;
  esac
done
[ -n "$URL" ] || { usage 2 >&2; }

case "$METHOD" in
  merge|squash|rebase) ;;
  *) echo "error: --method must be merge, squash, or rebase" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "error: gh is required on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required on PATH" >&2; exit 1; }

# Parse owner/repo/number from the URL.
case "$URL" in
  https://github.com/*/*)
    path=${URL#https://github.com/}
    owner=${path%%/*}
    rest=${path#*/}
    repo=${rest%%/*}
    tail=${rest#*/}
    number=${tail%%/*}
    case "$number" in
      pull) number=${tail#*/}; number=${number%%[!0-9]*} ;;
    esac
    case "$number" in
      ''|*[!0-9]*) echo "error: could not read a pull request number from $URL" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "error: only https://github.com/ pull request URLs are supported" >&2
    exit 2
    ;;
esac

# A task record that already binds this pull request goes back to the wrapper.
bound_task=$(grep -lxF "pr=$URL" "$STATE"/*.meta 2>/dev/null | head -1 || true)
if [ -n "$bound_task" ]; then
  echo "error: $(basename "$bound_task" .meta) still records $URL - merge it through bin/fm-pr-merge.sh, not this script" >&2
  exit 1
fi

# Attended only: no away record, because no task record exists to resolve
# merge authority from.
if [ -e "$STATE/.afk-contract" ] || [ -e "$STATE/.afk-contract-lock" ]; then
  echo "error: an away-posture record exists; a detached merge has no task record to resolve authority from and refuses rather than merge unattended" >&2
  exit 1
fi

# Live green gate, one read.
json=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup 2>/dev/null) \
  || { echo "error: could not read the pull request state before merging" >&2; exit 1; }

readout=$(printf '%s' "$json" | jq -r '
  if type == "object" then
    "state=" + ((.state // "") | tostring),
    "draft=" + (if .isDraft == null then "" else (.isDraft | tostring) end),
    "mergeable=" + ((.mergeable // "") | tostring),
    "merge_state=" + ((.mergeStateStatus // "") | tostring),
    "head=" + ((.headRefOid // "") | tostring)
  else
    error("pull request payload is not an object")
  end' 2>/dev/null) || { echo "error: could not read the pull request state before merging" >&2; exit 1; }

state=$(printf '%s\n' "$readout" | sed -n 's/^state=//p')
draft=$(printf '%s\n' "$readout" | sed -n 's/^draft=//p')
mergeable=$(printf '%s\n' "$readout" | sed -n 's/^mergeable=//p')
merge_state=$(printf '%s\n' "$readout" | sed -n 's/^merge_state=//p')
head=$(printf '%s\n' "$readout" | sed -n 's/^head=//p')

refusals=''
[ "$state" = OPEN ] || refusals="$refusals  - state is \"${state:-unreadable}\", not OPEN
"
[ "$draft" = false ] || refusals="$refusals  - the pull request is a draft
"
[ "$mergeable" = MERGEABLE ] || refusals="$refusals  - mergeable is \"${mergeable:-unreadable}\", not MERGEABLE
"
[ "$merge_state" != DIRTY ] || refusals="$refusals  - mergeStateStatus is DIRTY (conflicts)
"
case "$head" in
  ''|*[!0-9a-f]*) refusals="$refusals  - the head commit could not be read
" ;;
esac

reds=$(printf '%s' "$json" | jq -r '
  [ .statusCheckRollup // [] | .[]
    | if .__typename == "CheckRun" then
        {name: (.name // "(unnamed check)"),
         ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED"))}
      else
        {name: (.context // "(unnamed check)"), ok: (.state == "SUCCESS")}
      end
    | select(.ok | not) | .name ]
  | unique | .[]' 2>/dev/null) || reds="(rollup unreadable)"
[ -z "$reds" ] || refusals="$refusals$(printf '%s\n' "$reds" | sed 's/^/  - check '\''/; s/$/'\'' is not green/')"$'\n'

if [ -n "$refusals" ]; then
  printf 'error: refusing to merge %s\n%s' "$URL" "$refusals" >&2
  exit 1
fi

printf 'verified: %s is open, non-draft, MERGEABLE, every reported check green, at head %s\n' "$URL" "$head" >&2

# Head-bound merge.
if ! gh pr merge "$number" --repo "$owner/$repo" --method "$METHOD" --match-head-commit "$head" >/dev/null 2>&1; then
  echo "error: the merge command failed; nothing is recorded as landed" >&2
  exit 1
fi

# Proved outcome only.
# shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
out=$(gh api graphql \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged}}}' \
  -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
  --jq '"state=" + (.data.repository.pullRequest.state // ""), "merged=" + (.data.repository.pullRequest.merged | tostring)' 2>/dev/null) \
  || { echo "error: could not read the pull request outcome after the merge attempt; nothing is recorded as landed" >&2; exit 1; }
out_state=$(printf '%s\n' "$out" | sed -n 's/^state=//p')
out_merged=$(printf '%s\n' "$out" | sed -n 's/^merged=//p')
if [ "$out_merged" != true ] || [ "$out_state" != MERGED ]; then
  printf 'error: the merge did not land: state=%s, merged=%s; nothing is recorded as landed\n' "${out_state:-unreadable}" "${out_merged:-unreadable}" >&2
  exit 1
fi

printf '%s\tmerged\t%s\thead=%s\tmethod=%s\tdetached=1\n' \
  "$(date +%s)" "$URL" "$head" "$METHOD" >> "$STATE/pr-merge-ledger.log"
printf 'verified: %s is MERGED; recorded detached in state/pr-merge-ledger.log\n' "$URL"
