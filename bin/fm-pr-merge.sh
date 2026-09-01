#!/usr/bin/env bash
# Merge a task's GitHub PR after recording pr= and pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh and addressed through
# gh-axi by the derived owner and repository.
# GitLab identities are recognized only to return the inactive migration compatibility refusal.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# The gh-axi merge abstraction always performs the merge; the outcome read that
# follows it never becomes a prerequisite for reaching that abstraction. After
# gh-axi returns success, GitHub's live state is read back and accepted only
# when the pull request is merged or in the merge queue at the recorded exact
# green head. gh's GraphQL API supplies that complete queue-aware exact-head
# read; an unavailable or incomplete read never falls back to state alone.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# states that this strict exact-head path does not retain auto-merge.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# Caller-provided --auto is rejected before any metadata or forge mutation.
# An unmerged and unqueued outcome must also prove auto-merge absent, disabling
# and reading it back when the forge implicitly armed it.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the URL.
# bin/fm-merge-outcome-lib.sh owns a confirmed merge's destination,
# normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
if [ "$PROVIDER" != github ]; then
  echo "error: GitLab PR delivery is inactive migration compatibility; checking, polling, and merging support GitHub only" >&2
  exit 1
fi
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
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --match-head-commit|--match-head-commit=*)
        echo "error: extra merge arguments must not override the verified PR head" >&2
        return 1
        ;;
      --auto|--auto=*)
        echo "error: strict exact-head merge does not permit caller auto-merge" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -d "$STATE" ] || [ -L "$STATE" ] || [ ! -f "$META" ] || [ -L "$META" ] \
  || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

PR_LIFECYCLE_LOCK="$STATE/.pr-check-$ID.lock"
PR_LIFECYCLE_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
pr_merge_cleanup() {
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$PR_LIFECYCLE_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_LIFECYCLE_LOCK" || true
    PR_LIFECYCLE_LOCK_HELD=0
  fi
}
trap pr_merge_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$PR_LIFECYCLE_LOCK"
PR_LIFECYCLE_LOCK_HELD=1
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete exact head and state needed for a refusal.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_AUTO=
FM_PR_GITHUB_HEAD=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base='' auto='' head=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName headRefOid autoMergeRequest{enabledAt}}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // ""), "auto=" + (if .autoMergeRequest == null then "false" else "true" end), "head=" + (.headRefOid // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      auto=*) auto=${line#auto=} ;;
      head=*) head=${line#head=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 6 ] || [ "$total" -ne 6 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || { [ "$auto" != true ] && [ "$auto" != false ]; } \
    || [ -z "$base" ] || ! fm_pr_head_valid "$head"; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_AUTO=$auto
  FM_PR_GITHUB_HEAD=$head
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome() {
  github_read_outcome_with_gh && return 0
  echo "error: could not read the exact-head GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
  return 1
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(fm_pr_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

record_pr_metadata() {
  if ! FM_PR_LIFECYCLE_PARENT_LOCK=1 FM_PR_METADATA_PARENT_LOCK=1 \
    "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  fm_pr_metadata_identity_parse "$META" \
    && [ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] \
    && [ "$FM_PR_META_URL" = "$URL" ] \
    && [ "$FM_PR_META_HOST" = "$PR_HOST" ] \
    && [ "$FM_PR_META_PATH" = "$PR_PATH" ] \
    && [ "$FM_PR_META_NUMBER" = "$PR_NUMBER" ] \
    && fm_pr_head_valid "$FM_PR_META_HEAD" \
    && [ "$FM_PR_META_GREEN_HEAD" = "$FM_PR_META_HEAD" ] || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
  FM_PR_MERGE_HEAD=$FM_PR_META_HEAD
}

FM_PR_MERGE_META_HASH=
FM_PR_MERGE_META_IDENTITY=
fm_pr_merge_task_incarnation_capture() {
  [ -f "$META" ] && [ ! -L "$META" ] \
    && [ "$(fm_pr_file_link_count "$META")" = 1 ] || return 1
  FM_PR_MERGE_META_HASH=$(fm_pr_sha256 "$META") || return 1
  FM_PR_MERGE_META_IDENTITY=$(fm_pr_file_identity "$META") || return 1
  fm_pr_metadata_identity_parse "$META" \
    && [ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] \
    && [ "$FM_PR_META_URL" = "$URL" ] \
    && [ "$FM_PR_META_HOST" = "$PR_HOST" ] \
    && [ "$FM_PR_META_PATH" = "$PR_PATH" ] \
    && [ "$FM_PR_META_NUMBER" = "$PR_NUMBER" ] \
    && [ "$FM_PR_META_HEAD" = "$FM_PR_MERGE_HEAD" ] \
    && [ "$FM_PR_META_GREEN_HEAD" = "$FM_PR_MERGE_HEAD" ]
}

fm_pr_merge_task_incarnation_valid() {
  [ -f "$META" ] && [ ! -L "$META" ] \
    && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
    && [ "$(fm_pr_sha256 "$META")" = "$FM_PR_MERGE_META_HASH" ] \
    && [ "$(fm_pr_file_identity "$META")" = "$FM_PR_MERGE_META_IDENTITY" ] \
    && fm_pr_metadata_identity_parse "$META" \
    && [ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] \
    && [ "$FM_PR_META_URL" = "$URL" ] \
    && [ "$FM_PR_META_HOST" = "$PR_HOST" ] \
    && [ "$FM_PR_META_PATH" = "$PR_PATH" ] \
    && [ "$FM_PR_META_NUMBER" = "$PR_NUMBER" ] \
    && [ "$FM_PR_META_HEAD" = "$FM_PR_MERGE_HEAD" ] \
    && [ "$FM_PR_META_GREEN_HEAD" = "$FM_PR_MERGE_HEAD" ]
}

FM_PR_GITHUB_MERGE_ACCEPTED=false

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

github_outcome_matches_recorded_head() {
  [ "$FM_PR_GITHUB_HEAD" = "$FM_PR_MERGE_HEAD" ]
}

github_outcome_is_accepted() {
  github_outcome_matches_recorded_head \
    && { [ "$FM_PR_GITHUB_MERGED" = true ] || [ "$FM_PR_GITHUB_QUEUED" = true ]; }
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      printf 'error: base branch %s requires the merge queue method %s; this strict exact-head path does not retain auto-merge, and no landed or queued outcome is proven\n' \
        "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); the strict exact-head path cannot select one\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this strict exact-head path recognises\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_disable_auto_merge() {
  local output
  if [ "$FM_PR_GITHUB_AUTO" = false ]; then
    echo "verified: GitHub auto-merge is disabled for $URL" >&2
    return 0
  fi
  if ! output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --disable-auto 2>&1); then
    if github_read_outcome_with_gh && [ "$FM_PR_GITHUB_AUTO" = false ]; then
      echo "verified: GitHub auto-merge is disabled for $URL" >&2
      return 0
    fi
    printf 'error: could not disable GitHub auto-merge after the outcome was not proven landed or queued at the recorded exact head: %s\n' \
      "${output:-no forge detail}" >&2
    return 1
  fi
  if ! github_read_outcome_with_gh; then
    echo "error: GitHub auto-merge disablement could not be verified" >&2
    return 1
  fi
  if [ "$FM_PR_GITHUB_AUTO" != false ]; then
    printf 'error: GitHub auto-merge remains armed after disablement: autoMergeRequest=%s\n' \
      "$FM_PR_GITHUB_AUTO" >&2
    return 1
  fi
  echo "verified: GitHub auto-merge is disabled for $URL" >&2
}

github_clear_auto_merge_after_unproven_outcome() {
  github_disable_auto_merge && return 0
  echo "error: unresolved GitHub auto-merge hazard: the outcome is not proven landed or queued at the recorded exact head, and autoMergeRequest could not be verified clear" >&2
  return 1
}

github_report_refused_outcome() {
  local cleanup_status=0
  printf 'error: GitHub merge outcome was not accepted: state=%s, merged=%s, isInMergeQueue=%s, headRefOid=%s, recordedGreenHead=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" \
    "$FM_PR_GITHUB_HEAD" "$FM_PR_MERGE_HEAD" >&2
  github_clear_auto_merge_after_unproven_outcome || cleanup_status=1
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return "$cleanup_status"
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return "$cleanup_status"
  fi
  github_report_queue_rules
  return "$cleanup_status"
}

# Record before the forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
record_pr_metadata || exit 1
fm_pr_merge_task_incarnation_capture \
  || { echo "error: task incarnation changed after exact-head verification" >&2; exit 1; }
fm_pr_poll_snapshot_capture "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: exact-head merge poll is unavailable after publication" >&2; exit 1; }
[ "$FM_PR_POLL_SNAPSHOT_PROVIDER" = "$PROVIDER" ] \
  && [ "$FM_PR_POLL_SNAPSHOT_URL" = "$URL" ] \
  && [ "$FM_PR_POLL_SNAPSHOT_HOST" = "$PR_HOST" ] \
  && [ "$FM_PR_POLL_SNAPSHOT_PATH" = "$PR_PATH" ] \
  && [ "$FM_PR_POLL_SNAPSHOT_NUMBER" = "$PR_NUMBER" ] \
  && [ "$FM_PR_POLL_SNAPSHOT_HEAD" = "$FM_PR_MERGE_HEAD" ] \
  || { echo "error: exact-head merge poll does not match the verified task incarnation" >&2; exit 1; }
if ! fm_pr_merge_task_incarnation_valid \
  || ! fm_pr_poll_snapshot_matches "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  echo "error: task incarnation or merge poll changed before the forge attempt" >&2
  exit 1
fi

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      --match-head-commit "$FM_PR_MERGE_HEAD" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1); then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
    else
      merge_status=$?
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if ! github_outcome_is_accepted; then
          github_report_refused_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back at recorded head %s as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_HEAD" "$FM_PR_GITHUB_STATE" \
            "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        fi
      else
        github_clear_auto_merge_after_unproven_outcome || true
      fi
      exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      github_clear_auto_merge_after_unproven_outcome || true
      exit 1
    fi
    if github_outcome_is_accepted \
      && { ! fm_pr_merge_task_incarnation_valid \
        || ! fm_pr_poll_snapshot_matches "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh"; }; then
      github_report_forge_output "$merge_output"
      echo "error: task incarnation or merge poll changed during the forge attempt" >&2
      if [ "$FM_PR_GITHUB_MERGED" != true ]; then
        github_clear_auto_merge_after_unproven_outcome || true
      fi
      exit 1
    fi
    if github_outcome_matches_recorded_head && [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged at exact head %s (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_HEAD" "$FM_PR_GITHUB_STATE" \
        "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif github_outcome_matches_recorded_head && [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued at exact head %s (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_HEAD" "$FM_PR_GITHUB_STATE" \
        "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_refused_outcome
      exit 1
    fi
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
