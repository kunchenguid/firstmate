#!/usr/bin/env bash
# Re-queue a GitHub pull request that the merge-queue poll reported as ejected.
# Usage: fm-pr-enqueue.sh <task-id> <reason>
#
# The watcher wakes firstmate with dequeued:<reason>:<timestamp>. This script is
# the response: it calls enqueuePullRequest when the live pull request is still
# open, not a draft, not already in the queue, mergeable, with green checks and
# resolved review threads that fit one read page, and the ejection reason is a
# transient check failure in either the forge's or firstmate's spelling. Any
# other reason, including merge_conflict, an ejection the forge left unlabelled,
# a reason no known vocabulary covers, red checks, unresolved threads, more
# review threads than one page holds, an unreadable forge read, a second
# automatic attempt for the same ejection, or a delivery that has already spent
# its automatic attempts, prints escalate: and does not enqueue.
# Re-queue is not a merge. The bound is one automatic enqueuePullRequest per
# ejection, under a ceiling of FM_PR_ENQUEUE_ATTEMPT_CEILING attempts for the
# armed PR identity as a whole, both recorded in state/<id>.pr-poll-enqueued.
#
# Eligibility is decided on the reason the ejection marker recorded from the
# forge. The <reason> argument is only a cross-check that the caller answered
# this ejection: a reason that disagrees with the recorded one is refused with
# both values rather than either being preferred in silence.
#
# The target identity is the pull request recorded in the ejection marker, not
# the pull request currently named in task metadata. If those two disagree, this
# script refuses rather than choosing.
#
# GitHub's merge-queue mutation is GraphQL-only. gh-axi has no enqueue verb, and
# gh-axi pr merge --auto can land a merge when no queue is required, so this
# script uses gh api graphql for the authorized enqueuePullRequest mutation
# only. GitLab merge trains are out of scope.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

escalate() {
  printf 'escalate: %s\n' "$1"
  exit 2
}

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR enqueue request" >&2
  exit 2
fi
ID=$1
REASON=$2
if ! fm_pr_task_id_valid "$ID" || ! [[ "$REASON" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "error: invalid PR enqueue request" >&2
  exit 2
fi

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
fm_pr_metadata_identity_parse "$META" || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}

MARKER="$STATE/$ID.pr-poll-dequeued"
if [ ! -f "$MARKER" ] || [ -L "$MARKER" ] || [ "$(fm_pr_file_link_count "$MARKER")" != 1 ]; then
  echo "error: ejection identity is unavailable" >&2
  exit 1
fi
STATE_DEVICE=$(fm_pr_file_device "$STATE") || {
  echo "error: ejection identity is unavailable" >&2
  exit 1
}
fm_pr_poll_dequeued_identity_parse "$MARKER" "$STATE_DEVICE" || {
  echo "error: ejection identity is unavailable" >&2
  exit 1
}

if [ "$FM_PR_DEQUEUED_PROVIDER" != "$FM_PR_META_PROVIDER" ] \
  || [ "$FM_PR_DEQUEUED_HOST" != "$FM_PR_META_HOST" ] \
  || [ "$FM_PR_DEQUEUED_PATH" != "$FM_PR_META_PATH" ] \
  || [ "$FM_PR_DEQUEUED_NUMBER" != "$FM_PR_META_NUMBER" ]; then
  escalate "$REASON ejection identity does not match task metadata"
fi

URL=$FM_PR_META_URL
PROVIDER=$FM_PR_DEQUEUED_PROVIDER
HOST=$FM_PR_DEQUEUED_HOST
PROJECT_PATH=$FM_PR_DEQUEUED_PATH
NUMBER=$FM_PR_DEQUEUED_NUMBER
[ "$PROVIDER" = github ] || escalate "$REASON gitlab merge queue is not supported"
[ "$HOST" = github.com ] || escalate "$REASON host is not github.com"

OWNER=${PROJECT_PATH%%/*}
REPO=${PROJECT_PATH#*/}

# The forge spells its removal reasons in upper snake case, and firstmate's own
# vocabulary is lower snake case, so both tokens are folded before they are
# compared or matched, and a reason outside every known spelling is refused by
# name rather than silently treated as ineligible.
REASON_TOKEN=$(printf '%s\n' "$REASON" | tr '[:lower:]' '[:upper:]')
MARKER_TOKEN=$(printf '%s\n' "$FM_PR_DEQUEUED_REASON" | tr '[:lower:]' '[:upper:]')
[ "$REASON_TOKEN" = "$MARKER_TOKEN" ] \
  || escalate "$REASON does not match the recorded ejection reason $FM_PR_DEQUEUED_REASON"
case "$MARKER_TOKEN" in
  CI_FAILURE|CI_TIMEOUT|FAILED_CHECKS|CHECKS_TIMED_OUT) ;;
  UNREPORTED|UNREADABLE)
    escalate "$REASON the forge reported no usable ejection reason" ;;
  MANUAL|MERGE_CONFLICT|QUEUE_CLEARED|ROLL_BACK|BRANCH_PROTECTIONS|ALREADY_MERGED|\
  GIT_TREE_INVALID|INVALID_MERGE_COMMIT|UNKNOWN_REMOVAL_REASON)
    escalate "$REASON is not an automatic re-queue reason" ;;
  *)
    escalate "$REASON is not a known merge-queue ejection reason" ;;
esac

# What the forge ejected this delivery for is the more specific fact, so it is
# established before either bound is consulted: a reason no automatic re-queue
# covers is reported as itself rather than as a spent budget.
if fm_pr_poll_enqueued_already "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" \
  "$FM_PR_DEQUEUED_AT"; then
  escalate "$REASON already requeued once"
fi

# A delivery that fails deterministically inside the merge group is ejected
# again on every attempt, and each attempt reads the pull request head rather
# than the merge group, so the per-ejection bound alone would keep re-queueing
# it. Past this ceiling the delivery stops being automated and goes to the
# captain. A marker that cannot be read records no attempts, and the write at
# the end of a successful re-queue replaces it.
ATTEMPT_CEILING=${FM_PR_ENQUEUE_ATTEMPT_CEILING:-3}
case "$ATTEMPT_CEILING" in ''|*[!0-9]*|0) ATTEMPT_CEILING=3 ;; esac
fm_pr_poll_enqueued_attempts "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" \
  || FM_PR_ENQUEUED_ATTEMPTS=0
[ "$FM_PR_ENQUEUED_ATTEMPTS" -lt "$ATTEMPT_CEILING" ] \
  || escalate "$REASON reached the automatic re-queue ceiling of $ATTEMPT_CEILING after $FM_PR_ENQUEUED_ATTEMPTS attempts on this pull request"

# shellcheck disable=SC2016 # GraphQL variables are for gh, not the shell.
gql_read='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id state isDraft isInMergeQueue mergeable reviewDecision commits(last:1){nodes{commit{statusCheckRollup{state}}}} reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved isOutdated}}}}}'
# shellcheck disable=SC2016 # jq owns every $ expression in this filter.
gql_read_filter='.data.repository.pullRequest as $pr | if $pr == null then empty else [($pr.id // ""), ($pr.state // ""), (if $pr.isDraft == true then "true" else "false" end), (if $pr.isInMergeQueue == true then "true" else "false" end), ($pr.mergeable // ""), ($pr.reviewDecision // ""), ((($pr.commits.nodes // []) | last | .commit.statusCheckRollup.state) // ""), ([($pr.reviewThreads.nodes // [])[] | select(.isResolved == false and .isOutdated != true)] | length | tostring), (if $pr.reviewThreads.pageInfo.hasNextPage == true then "true" else "false" end)] | @tsv end'

read_pr_state() {
  gh api graphql -f query="$gql_read" -f owner="$OWNER" -f name="$REPO" -F number="$NUMBER" \
    -q "$gql_read_filter" 2>/dev/null
}

parse_pr_state() {
  local raw=$1
  [ -n "$raw" ] || return 1
  case "$raw" in
    *$'\n'*) return 1 ;;
  esac
  [ "$(printf '%s\n' "$raw" | awk -F '\t' '{print NF}')" = 9 ] || return 1
  pr_id=$(printf '%s\n' "$raw" | awk -F '\t' '{print $1}')
  pr_state=$(printf '%s\n' "$raw" | awk -F '\t' '{print $2}')
  is_draft=$(printf '%s\n' "$raw" | awk -F '\t' '{print $3}')
  in_queue=$(printf '%s\n' "$raw" | awk -F '\t' '{print $4}')
  mergeable=$(printf '%s\n' "$raw" | awk -F '\t' '{print $5}')
  review_decision=$(printf '%s\n' "$raw" | awk -F '\t' '{print $6}')
  check_state=$(printf '%s\n' "$raw" | awk -F '\t' '{print $7}')
  unresolved=$(printf '%s\n' "$raw" | awk -F '\t' '{print $8}')
  threads_beyond_page=$(printf '%s\n' "$raw" | awk -F '\t' '{print $9}')
  [ -n "$pr_id" ] || return 1
  [[ "$pr_id" =~ ^[A-Za-z0-9_=-]+$ ]] || return 1
}

# The forge answers these three whatever mergeability says, and it never
# recomputes mergeability for a pull request it has already settled, so they are
# read on every read and answered before any wait on UNKNOWN.
settled_state() {
  if [ "$in_queue" = true ]; then
    printf 'queued: %s\n' "$URL"
    exit 0
  fi
  [ "$pr_state" = OPEN ] || escalate "$REASON pull request is not open"
  [ "$is_draft" = false ] || escalate "$REASON pull request is a draft"
}

raw=$(read_pr_state) || escalate "$REASON forge state could not be read"
parse_pr_state "$raw" || escalate "$REASON forge state could not be read"
settled_state

# GitHub's mergeability recompute after a merge-queue ejection routinely takes
# longer than six seconds on a busy repository, so the default budget is sixty
# seconds with backoff rather than six. The budget is the authority on how long
# to wait; the read ceiling only stops a loop whose delay never grows, and when
# it is what ends the wait it says so instead of claiming the budget elapsed.
unknown_budget=${FM_PR_ENQUEUE_UNKNOWN_BUDGET_SECS:-60}
unknown_sleep=${FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS:-1}
unknown_reads=8
case "$unknown_budget" in ''|*[!0-9]*) unknown_budget=60 ;; esac
case "$unknown_sleep" in ''|*[!0-9]*) unknown_sleep=1 ;; esac
if [ "$mergeable" = UNKNOWN ]; then
  unknown_started=$SECONDS
  unknown_extra=0
  unknown_delay=$unknown_sleep
  while [ "$mergeable" = UNKNOWN ]; do
    unknown_extra=$((unknown_extra + 1))
    [ "$unknown_extra" -le "$unknown_reads" ] \
      || escalate "$REASON mergeable is UNKNOWN after $unknown_reads reads, short of the ${unknown_budget}s budget"
    [ $((SECONDS - unknown_started)) -lt "$unknown_budget" ] \
      || escalate "$REASON mergeable is UNKNOWN"
    sleep "$unknown_delay"
    raw=$(read_pr_state) || escalate "$REASON forge state could not be read"
    parse_pr_state "$raw" || escalate "$REASON forge state could not be read"
    settled_state
    if [ "$unknown_delay" -gt 0 ]; then
      unknown_delay=$((unknown_delay * 2))
      [ "$unknown_delay" -gt 30 ] && unknown_delay=30
    fi
  done
fi

[ "$mergeable" = MERGEABLE ] || escalate "$REASON mergeable is $mergeable"
[ "$review_decision" != CHANGES_REQUESTED ] || escalate "$REASON changes requested"
if [ -z "$check_state" ]; then
  escalate "$REASON no checks on the head commit"
fi
[ "$check_state" = SUCCESS ] || escalate "$REASON checks are not green"
[ "$unresolved" = 0 ] || escalate "$REASON unresolved review threads"
# The read asks for one page of review threads, so a pull request with more
# threads than that page holds has an uncounted remainder: zero unresolved on
# the page is not zero unresolved on the pull request, and guessing it is would
# re-queue a delivery that is still waiting on a review.
[ "$threads_beyond_page" = false ] \
  || escalate "$REASON review threads do not fit one page and could not be counted"

# shellcheck disable=SC2016 # GraphQL variables are for gh, not the shell.
gql_mut='mutation($id:ID!){enqueuePullRequest(input:{pullRequestId:$id}){mergeQueueEntry{id}}}'
gql_mut_filter='.data.enqueuePullRequest.mergeQueueEntry.id // empty'
queued_id=$(gh api graphql -f query="$gql_mut" -F id="$pr_id" -q "$gql_mut_filter" 2>/dev/null) || escalate "$REASON enqueuePullRequest failed"
[ -n "$queued_id" ] || escalate "$REASON enqueuePullRequest failed"
case "$queued_id" in
  *$'\n'*) escalate "$REASON enqueuePullRequest failed" ;;
esac

# The mutation already landed, so the outcome reported is a re-queue either way.
# A marker that could not be written only loses the one-attempt bound, and
# saying the re-queue failed would send the captain after a pull request that is
# in fact back in the queue.
if ! fm_pr_poll_enqueued_mark "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" \
  "$FM_PR_DEQUEUED_AT" "$FM_PR_DEQUEUED_REASON"; then
  printf 'queued: %s\n' "$URL"
  escalate "$REASON pull request was requeued but the attempt could not be recorded"
fi
printf 'queued: %s\n' "$URL"
exit 0
