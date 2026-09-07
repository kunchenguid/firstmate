#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# Every GitHub merge is bound to the head this run verified. The merge goes
# through gh-axi's merge API seam, which sends that head as sha=, so a push
# landing between the verdict and the merge makes GitHub refuse the merge
# instead of landing commits nothing reviewed. Caller merge flags are resolved
# onto that one path before anything is recorded: one merge method and commit
# text become merge fields, --delete-branch becomes a deletion performed only
# after the merge is proved landed and only for a head branch in this
# repository, and every other argument is refused. Two different merge methods
# are an ambiguous request and refuse rather than letting the last one win.
# Deferred merging is refused in every spelling - --auto, --auto=<value> and
# --disable-auto - because a queued or auto merge lands whatever the head is
# when the forge reaches it, which no binding available here can pin to the
# reviewed commit; the gh-axi CLI merge is refused for the same reason, since
# it silently drops flags it does not implement and so can carry no binding.
# The merge abstraction always performs the merge; the outcome read that
# follows it never becomes a prerequisite for reaching that abstraction. After
# the merge returns success, GitHub's live state is read back and accepted only
# when the pull request is proved merged; a pull request that entered the merge
# queue instead is refused, because the queue lands whatever the head is when
# it reaches that pull request. gh's GraphQL API
# supplies that queue-aware read when gh is on PATH; when gh is absent or its
# read fails, gh-axi's own view still proves a landed merge, and every outcome
# it cannot prove refuses, reporting the single failed read when gh is absent
# and naming both failed reads when gh is present and its own read failed.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# says the merge has to be arranged outside this script, because a queued merge
# lands whatever the head is when the queue reaches it. A rules response that
# names no queue rule, one that could not be read, rules that disagree, and a
# method this script does not recognise are four distinct outcomes and are
# reported apart, because each one leaves the operator somewhere different.
# The observed state is judged the same way whichever read produced it, and a
# refusal built on the gh-axi view says the merge queue could not be observed
# at all rather than implying an unqueued pull request.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on either forge because the head comes only from the live read.
# Beyond that, each forge accepts only the immediate flags its head-bound path
# can express and refuses the rest, rather than forwarding an argument whose
# effect on the merge this script cannot reason about. A rebase and a repeated
# option are both refused: one replaces the verified head, the other leaves the
# effective request to the CLI rather than to this script's own reading. On
# GitLab the merge command states --auto-merge=false, because glab defaults
# that field to true whenever the merge request has a pipeline, and a wrapper
# flag GitLab has no meaning for refuses before anything is recorded.
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
#
# When the task project is this Firstmate repository, or cannot be resolved to
# any repository, the merge requires an independent review the forge itself
# recorded. The whole reviews response is validated before anything is
# adjudicated: every entry must be a well-formed review of this exact pull
# request, matched by canonical API URL rather than by a suffix another origin
# could share, and one malformed entry refuses the merge instead of being
# dropped, which would let a later negative verdict vanish and leave an older
# approval standing. Among the validated entries, only those by an account that
# is not the pull request's author, on the exact commit the merge will carry,
# count, and each reviewer's effective verdict is their latest APPROVED,
# CHANGES_REQUESTED or DISMISSED record. The merge qualifies only when some
# reviewer's effective verdict is APPROVED and that record carries the
# repository's zero-findings verdict on a line of its own, never while any
# reviewer's effective verdict at this head requests changes - which refuses
# outright rather than becoming a missing receipt an override could excuse -
# and never when two state-bearing records for one reviewer share an ordering
# position. Pull request prose is written by the author and is never read as
# review evidence. Absent, malformed, ambiguous, stale, author-authored,
# wrong-pull-request, wrong-repository, wrong-origin and unreadable evidence
# all refuse.
# A missing review requires --allow-missing-review under explicit captain
# authorization; before the merge attempt, the override is recorded in the
# task metadata and disclosed on stderr. An ordinary merge that needs no
# override instead clears a stale receipt before merging, and either write
# failing refuses the merge rather than landing an untrue audit record. On
# both forges the task identity check, everything each one verifies, the forge
# mutation and the outcome adjudication that follows it are one transaction on
# the per-task metadata lock - on GitHub the review-exemption decision and both
# receipt writes as well - so a concurrent re-pointing of the task can land
# neither between what authorizes a merge and that merge nor between that merge
# and the record its outcome is reported against. Every such write, and bin/fm-pr-check.sh's read
# of the fields it re-emits, runs inside a transaction on that same lock, so a concurrent
# metadata writer can neither stage from a superseded file nor publish over a
# receipt this run just recorded. The
# override is the missing_review_override_ts= line in state/<id>.meta, recorded
# before a missing-review merge attempt and cleared by an ordinary merge.
#
# A non-green GitHub PR requires --allow-red before the optional -- separator.
# That flag records external authority rather than creating it: before the merge
# attempt the override is written to state/<id>.meta as red_override_ts=,
# red_override_pr=, red_override_head= and red_override_condition=, bound to the
# canonical pull request URL and the exact live head and naming what was
# observed to be non-green. A receipt that cannot be written refuses the merge
# before the forge command runs, and an ordinary green merge clears a stale one.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red] [--allow-missing-review] [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Metadata writes here serialize on the per-task lock every other metadata
# writer uses, so this script declares that dependency rather than relying on
# fm-pr-lib.sh's lazy fallback.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# The single owner of what a clone URL means, used to decide whether a task's
# project actually owns the pull request being merged.
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

trap fm_pr_meta_cleanup EXIT
trap 'exit 1' HUP INT TERM

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
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
shift 2
ALLOW_RED=0
ALLOW_MISSING_REVIEW=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-red) ALLOW_RED=1; shift ;;
    --allow-missing-review) ALLOW_MISSING_REVIEW=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

# Caller merge flags, resolved onto the head-bound merge seam before anything
# is recorded or merged. Every flag understood here maps onto GitHub's merge
# API or onto a step this script performs only after a proved merge. Anything
# else refuses: the CLI merge is the one GitHub path that cannot carry a head
# binding, so keeping it as a fallback would let a caller flag merge a commit
# nothing reviewed.
FM_MERGE_METHOD=squash
FM_MERGE_METHOD_NAMED=0
FM_MERGE_COMMIT_TITLE=
FM_MERGE_COMMIT_TITLE_SET=0
FM_MERGE_COMMIT_MESSAGE=
FM_MERGE_COMMIT_MESSAGE_SET=0
FM_MERGE_DELETE_BRANCH=0
_fm_github_seen=''

github_merge_arg_once() {  # <canonical-key>
  case " $_fm_github_seen " in
    *" $1 "*)
      printf 'error: extra merge arguments name %s more than once, so the commit text they ask for is ambiguous\n' \
        "$1" >&2
      return 1
      ;;
  esac
  _fm_github_seen="$_fm_github_seen $1"
}

# A merge method the caller named. Naming two different ones is an ambiguous
# request, not a last-one-wins preference, so it refuses rather than silently
# discarding the method the caller wrote first.
name_merge_method() {  # <method>
  if [ "$FM_MERGE_METHOD_NAMED" -eq 1 ] && [ "$FM_MERGE_METHOD" != "$1" ]; then
    printf 'error: extra merge arguments name two different merge methods (%s and %s)\n' \
      "$FM_MERGE_METHOD" "$1" >&2
    return 1
  fi
  FM_MERGE_METHOD=$1
  FM_MERGE_METHOD_NAMED=1
}

refuse_unbindable_merge_arg() {  # <arg>
  printf 'error: extra merge argument %s cannot be bound to the reviewed head, so it is refused rather than merged through an unfenced path\n' \
    "$1" >&2
  return 1
}

parse_caller_merge_args() {
  local arg value
  _fm_github_seen=''
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --squash|--merge|--rebase)
        name_merge_method "${arg#--}" || return 1
        ;;
      --method)
        [ "$#" -gt 0 ] || { refuse_unbindable_merge_arg "$arg"; return 1; }
        name_merge_method "$1" || return 1
        shift
        ;;
      --method=*)
        name_merge_method "${arg#--method=}" || return 1
        ;;
      --auto|--auto=*|--disable-auto)
        printf 'error: %s is refused: this script merges only what it can bind to the reviewed head, and a deferred merge lands whatever the head is at that later time\n' \
          "${arg%%=*}" >&2
        return 1
        ;;
      --delete-branch|-d) FM_MERGE_DELETE_BRANCH=1 ;;
      --subject)
        github_merge_arg_once commit_title || return 1
        [ "$#" -gt 0 ] || { refuse_unbindable_merge_arg "$arg"; return 1; }
        FM_MERGE_COMMIT_TITLE=$1
        shift
        FM_MERGE_COMMIT_TITLE_SET=1
        ;;
      --subject=*)
        github_merge_arg_once commit_title || return 1
        FM_MERGE_COMMIT_TITLE=${arg#--subject=}
        FM_MERGE_COMMIT_TITLE_SET=1
        ;;
      --body)
        github_merge_arg_once commit_message || return 1
        [ "$#" -gt 0 ] || { refuse_unbindable_merge_arg "$arg"; return 1; }
        FM_MERGE_COMMIT_MESSAGE=$1
        shift
        FM_MERGE_COMMIT_MESSAGE_SET=1
        ;;
      --body=*)
        github_merge_arg_once commit_message || return 1
        FM_MERGE_COMMIT_MESSAGE=${arg#--body=}
        FM_MERGE_COMMIT_MESSAGE_SET=1
        ;;
      --body-file|--body-file=*)
        # The file-backed form fills the same field, so it is the same option.
        github_merge_arg_once commit_message || return 1
        case "$arg" in
          --body-file)
            [ "$#" -gt 0 ] || { refuse_unbindable_merge_arg "$arg"; return 1; }
            value=$1
            shift
            ;;
          *) value=${arg#--body-file=} ;;
        esac
        if [ ! -f "$value" ] || [ -L "$value" ] \
          || ! FM_MERGE_COMMIT_MESSAGE=$(cat -- "$value"); then
          printf 'error: could not read the merge commit body file %s\n' "$value" >&2
          return 1
        fi
        FM_MERGE_COMMIT_MESSAGE_SET=1
        ;;
      *)
        refuse_unbindable_merge_arg "$arg"
        return 1
        ;;
    esac
  done
  case "$FM_MERGE_METHOD" in
    merge|squash|rebase) ;;
    *)
      printf 'error: merge method "%s" is not one of merge, squash or rebase\n' \
        "$FM_MERGE_METHOD" >&2
      return 1
      ;;
  esac
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
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

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

# GitLab caller flags, resolved before anything is recorded. Only immediate
# operations compatible with the --sha this run verifies are forwarded, and the
# list is an allowlist rather than a set of exclusions: a flag this script
# cannot reason about is refused instead of being handed to glab, because the
# merge and a change to scheduled merge authority are both irreversible once
# the forge has them.
#
# Rebasing is refused outright. The --sha this run passes names the head whose
# pipeline and discussions were verified, and a rebase replaces that head, so a
# rebase request is not an immediate operation on the commit that was checked.
#
# Every automatic-merge state operation is refused, including cancelling one:
# scheduling and unscheduling a deferred merge are both authority this run
# cannot bind to the head it verified. A repeated option is refused rather than
# forwarded, so the effective request is this script's reading of the caller's
# words and never the CLI's own conflict resolution. The caller's own
# confirmation flag is consumed rather than forwarded, because this script
# already passes one.
FM_GITLAB_MERGE_ARGS=()
_fm_gitlab_seen=''

# The canonical key for an option however the caller spelled it, so an alias
# and its long form are one operation for duplicate detection rather than two.
gitlab_merge_option_key() {  # <token>
  case "${1%%=*}" in
    -d) printf -- '--remove-source-branch' ;;
    -y) printf -- '--yes' ;;
    -m) printf -- '--message' ;;
    *) printf '%s' "${1%%=*}" ;;
  esac
}

gitlab_merge_arg_once() {  # <canonical-key>
  case " $_fm_gitlab_seen " in
    *" $1 "*)
      printf 'error: extra merge argument %s is given more than once, so the request it names is ambiguous\n' \
        "$1" >&2
      return 1
      ;;
  esac
  _fm_gitlab_seen="$_fm_gitlab_seen $1"
}

# A value that is itself option-shaped is refused rather than consumed: a
# rebase, deferral or cancellation token hidden in a value position would
# otherwise slip past its own refusal branch and reach the forge.
gitlab_merge_value_ok() {  # <flag> <value>
  case "$2" in
    '')
      printf 'error: extra merge argument %s names an empty value\n' "$1" >&2
      return 1
      ;;
    -*)
      printf 'error: extra merge argument %s is followed by %s, which is another option rather than its value\n' \
        "$1" "$2" >&2
      return 1
      ;;
  esac
}

parse_gitlab_merge_args() {
  local arg key value
  FM_GITLAB_MERGE_ARGS=()
  _fm_gitlab_seen=''
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    key=$(gitlab_merge_option_key "$arg")
    case "$key" in
      --auto-merge|--when-pipeline-succeeds|--cancel-auto-merge|--cancel-automatic-merge)
        printf 'error: %s is refused: this script merges only what it can bind to the head it verified, and scheduled merge authority lands whatever the head is at that later time\n' \
          "$key" >&2
        return 1
        ;;
      --rebase|-r)
        printf 'error: %s is refused: the head this run verified is the one it merges, and a rebase replaces that head after its pipeline and discussions were checked\n' \
          "$key" >&2
        return 1
        ;;
      --squash|--remove-source-branch)
        # A boolean option carries no value here: this script forwards the
        # caller's request as a flag, and cannot judge a spelling glab might
        # read as false.
        case "$arg" in
          *=*)
            printf 'error: extra merge argument %s takes no value\n' "$key" >&2
            return 1
            ;;
        esac
        gitlab_merge_arg_once "$key" || return 1
        FM_GITLAB_MERGE_ARGS+=("$key")
        ;;
      --yes)
        # This script passes its own confirmation flag; a second one would be a
        # repeat at the forge seam even though the caller wrote it once.
        case "$arg" in
          *=*)
            printf 'error: extra merge argument %s takes no value\n' "$key" >&2
            return 1
            ;;
        esac
        gitlab_merge_arg_once "$key" || return 1
        ;;
      --message|--squash-message)
        gitlab_merge_arg_once "$key" || return 1
        case "$arg" in
          *=*) value=${arg#*=} ;;
          *)
            [ "$#" -gt 0 ] || {
              printf 'error: extra merge argument %s names no value\n' "$key" >&2
              return 1
            }
            value=$1
            shift
            ;;
        esac
        gitlab_merge_value_ok "$key" "$value" || return 1
        FM_GITLAB_MERGE_ARGS+=("$key" "$value")
        ;;
      *)
        printf 'error: extra merge argument %s is not one this script can bind to the head it verified, so it is refused rather than forwarded\n' \
          "$key" >&2
        return 1
        ;;
    esac
  done
  case " $_fm_gitlab_seen " in
    *" --squash-message "*)
      case " $_fm_gitlab_seen " in
        *" --squash "*) ;;
        *)
          echo "error: extra merge arguments name a squash message without a squash" >&2
          return 1
          ;;
      esac
      ;;
  esac
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1
# Both forges resolve their caller flags before anything is recorded, so a flag
# no head-bound path can express refuses without leaving state behind.
# A wrapper flag this provider has no meaning for is a request this script
# cannot honour, so it refuses here rather than after arming a poll or, worse,
# by quietly proceeding as though it had been asked for nothing.
reject_inapplicable_gitlab_flags() {
  [ "$ALLOW_RED" -eq 0 ] || {
    echo "error: --allow-red is not supported for GitLab merge requests" >&2
    return 1
  }
  [ "$ALLOW_MISSING_REVIEW" -eq 0 ] || {
    echo "error: --allow-missing-review is not supported for GitLab merge requests" >&2
    return 1
  }
}

[ "$PROVIDER" != gitlab ] || reject_inapplicable_gitlab_flags || exit 1
[ "$PROVIDER" != gitlab ] || parse_gitlab_merge_args "$@" || exit 1
[ "$PROVIDER" != github ] || parse_caller_merge_args "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The three GitHub reads every gate binds to - the pull request identity, the
# review evidence and the mergeability verdict - are parsed field by field, and
# only gh prints the selected payload raw. gh-axi wraps the same selection
# differently depending on the value's type and size, so a merge that cannot
# use gh refuses here, before anything is recorded and before the forge is
# asked to mutate anything, rather than reading a shape it would have to guess
# at. An irreversible merge binds to raw data or it does not run.
if [ "$PROVIDER" = github ] && ! command -v gh >/dev/null 2>&1; then
  echo "error: merging a GitHub pull request requires gh on PATH" >&2
  exit 1
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type != "object" then
        error("merge request payload is not an object")
      elif (.has_conflicts | type) != "boolean"
        or (.blocking_discussions_resolved | type) != "boolean" then
        error("merge request payload has non-boolean mergeability fields")
      else
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view when available; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for the merge abstraction.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
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
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
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
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
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

# One live read of the pull request every GitHub gate binds to: the head a
# qualifying review has to name and the merge has to carry, the author whose
# own words can never be that review, and whether the merge already landed.
# Unreadable or malformed, it refuses before anything is recorded or merged.
# A branch name this script is willing to place in a ref path: no whitespace,
# no relative components, and no empty segment, so a deletion cannot address
# anything but the head branch the pull request named.
github_branch_ref_valid() {
  local ref=$1
  case "$ref" in
    ''|/*|*/|*//*|*..*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
}

GH_LIVE_HEAD=
GH_PR_AUTHOR=
GH_PR_MERGED=false
GH_HEAD_REF=
GH_HEAD_REPO=
GH_BASE_REPO=
github_read_pr_identity() {
  local fields line
  local total=0 named=0
  local head='' author='' merged='' ref='' head_repo='' base_repo=''

  # shellcheck disable=SC2016  # The jq program is literal, not a shell string.
  if ! fields=$(gh api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" --jq \
    '"head=" + ((.head.sha // "") | tostring), "author=" + ((.user.login // "") | tostring), "merged=" + (.merged | tostring), "ref=" + ((.head.ref // "") | tostring), "headrepo=" + ((.head.repo.full_name // "") | tostring), "baserepo=" + ((.base.repo.full_name // "") | tostring)' \
    2>/dev/null) || [ -z "$fields" ]; then
    echo "error: could not read the GitHub pull request head commit and author before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      head=*) head=${line#head=} ;;
      author=*) author=${line#author=} ;;
      merged=*) merged=${line#merged=} ;;
      ref=*) ref=${line#ref=} ;;
      headrepo=*) head_repo=${line#headrepo=} ;;
      baserepo=*) base_repo=${line#baserepo=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 6 ] || [ "$total" -ne 6 ] \
    || ! fm_pr_head_valid "$head" || ! fm_pr_github_login_valid "$author" \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || ! github_branch_ref_valid "$ref" || [ -z "$base_repo" ]; then
    echo "error: could not read the GitHub pull request head commit and author before merging" >&2
    return 1
  fi
  # GitHub repository names are case-insensitive, so the URL a caller supplied
  # is not evidence of how the repository is actually named. Every decision
  # below binds to the name the forge returned, and a URL that spells it
  # differently is refused rather than quietly re-spelled.
  if [ "$base_repo" != "$FM_PR_PATH" ]; then
    printf 'error: %s addresses repository %s, which GitHub reports as %s; the exact name decides this merge\n' \
      "$URL" "$FM_PR_PATH" "$base_repo" >&2
    return 1
  fi
  GH_LIVE_HEAD=$head
  GH_PR_AUTHOR=$author
  GH_PR_MERGED=$merged
  GH_HEAD_REF=$ref
  GH_HEAD_REPO=$head_repo
  GH_BASE_REPO=$base_repo
}

git_common_dir_abs() {  # <working-tree>
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) (cd "$common" 2>/dev/null && pwd -P) ;;
    *) (cd "$repo/$common" 2>/dev/null && pwd -P) ;;
  esac
}

# "Cannot tell" is not "another project": an absent or unresolvable project=
# must take the Review guard, or a broken meta would silently disarm it.
# Whether a repository IS the pull request's own repository, decided from its
# one origin. Only remote.origin.url counts: an auxiliary remote is ordinary
# mutable configuration anyone can add, so letting any matching remote answer
# would make the review exemption depend on it. An origin carrying more than
# one URL is two answers to one question and decides nothing; git config --get
# would silently return the last of them, so every value is read and counted.
#
# The comparison itself belongs to bin/fm-project-origin-lib.sh, the single
# owner of what a clone URL means, and is byte exact: this decides whether to
# skip a mandatory review, so a URL that merely normalizes to the right
# repository is not the right repository.
project_owns_pr_repository() {  # <working-tree>
  local record url='' count=0
  # NUL-terminated, because command substitution strips trailing newlines: a
  # second empty origin value and a value with a trailing newline both collapse
  # into one clean-looking string otherwise, which is exactly the malformed
  # configuration this decision has to refuse.
  while IFS= read -r -d '' record; do
    count=$((count + 1))
    url=$record
  done < <(git -C "$1" config --get-all --null remote.origin.url 2>/dev/null)
  [ "$count" -eq 1 ] || return 1
  fm_project_origin_is_canonical_github "$url" "$GH_BASE_REPO"
}

# "Cannot tell" is not "another project". The gate is skipped only for a task
# whose own project is a different repository AND provably owns the pull
# request being merged: without that binding, any task id from another
# repository could be paired with a Firstmate pull request to remove the gate.
#
# The whole decision is one snapshot inside the caller's held per-task metadata
# transaction, so a concurrent transition of project= cannot land between
# reading the task's project and resolving its remotes, nor between this
# decision and the merge it authorizes. A task record naming more than one
# project, or none this run can resolve, decides nothing and keeps the gate.
FM_REVIEW_GATE_REQUIRED=1
resolve_review_gate_requirement() {
  local project projects root_common project_common
  FM_REVIEW_GATE_REQUIRED=1
  projects=$(grep -c '^project=' "$META" || true)
  project=$(sed -n 's/^project=//p' "$META" | tail -n 1)
  root_common=$(git_common_dir_abs "$FM_ROOT") || root_common=
  project_common=
  if [ "$projects" = 1 ] && [ -n "$project" ]; then
    project_common=$(git_common_dir_abs "$project") || project_common=
  fi
  if [ "$projects" != 1 ]; then
    echo "warning: this task's record does not name exactly one project; requiring an independent review" >&2
  elif [ -z "$root_common" ] || [ -z "$project_common" ]; then
    echo "warning: could not resolve this task's project as a repository; requiring an independent review" >&2
  elif [ "$project_common" = "$root_common" ]; then
    : # This repository's own pull request always takes the gate.
  elif ! project_owns_pr_repository "$project"; then
    printf 'warning: this task'"'"'s project origin is not %s, so the pull request is not proved to belong to it; requiring an independent review\n' \
      "$FM_PR_PATH" >&2
  else
    FM_REVIEW_GATE_REQUIRED=0
  fi
}

FM_REVIEW_VERDICT='LGTM ready for merge'

# The verdict every qualifying review has to carry, as its own line rather than
# as a substring: quoting it, negating it, or discussing it in a sentence then
# no longer authorizes a merge.
#
# The whole response is validated before any record is adjudicated. Every entry
# must be a review of this exact pull request, matched by the canonical API URL
# rather than by a suffix another origin could end with, with a login in
# GitHub's own grammar, a canonical submission timestamp, a positive integer
# id, and a state this script knows. Any entry that is not makes the evidence
# invalid, and invalid evidence is never an absence: dropping an entry would
# let a later negative verdict vanish and leave an older approval standing,
# and calling it missing would let the captain's absence escape excuse it.
#
# Among the validated entries, only those by an account that is not the pull
# request's author, on the exact commit the merge will carry, are considered.
# GitHub account names are case-insensitive, so identity is compared and keyed
# in one lowercased form and a case variant of the author is still the author.
# Each reviewer's effective verdict is their latest state-bearing record -
# APPROVED, CHANGES_REQUESTED or DISMISSED - because a COMMENTED or PENDING
# record does not change a reviewer's standing. A merge qualifies only when
# some reviewer's effective verdict is APPROVED and that record carries the
# verdict line, never while any reviewer's effective verdict at this head
# requests changes, and never when two state-bearing records for one reviewer
# share an ordering position, because then there is no latest verdict to read.
#
# FM_REVIEW_ADJUDICATION reports which of those outcomes was reached:
# approved, none, blocked, ambiguous, or invalid for evidence that could not be
# read or validated. Only a successfully read and fully validated none is an
# absence the captain's override may act on.
FM_REVIEW_ADJUDICATION=
firstmate_review_verdict_recorded() {
  local records canonical_url
  local _fm_login _fm_state _fm_at _fm_id _fm_verdict _fm_scope _fm_commit
  FM_REVIEW_ADJUDICATION=invalid
  canonical_url="https://api.github.com/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER"
  records=$(gh api --paginate "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/reviews" --jq "
    if type != \"array\" then
      error(\"reviews payload is not an array\")
    else
      .[]
      | if type != \"object\" then error(\"review record is not an object\")
        elif (.pull_request_url | type) != \"string\" then error(\"review record has no readable pull request URL\")
        elif .pull_request_url != \"$canonical_url\" then error(\"review record names another pull request\")
        elif (.user | type) != \"object\" or (.user.login | type) != \"string\" then error(\"review record has no readable reviewer\")
        elif .user.login == \"\" then error(\"review record has no readable reviewer\")
        elif (.state | type) != \"string\" then error(\"review record has no readable state\")
        elif (.state as \$st | [\"APPROVED\", \"CHANGES_REQUESTED\", \"DISMISSED\", \"COMMENTED\", \"PENDING\"] | index(\$st) | not) then error(\"review record has a state this script does not know\")
        elif (.commit_id | type) != \"string\" then error(\"review record has no readable commit\")
        elif (.id | type) != \"number\" or (.id | floor) != .id or .id <= 0 then error(\"review record has no readable id\")
        elif (.body | type) != \"string\" then error(\"review record has no readable body\")
        elif .state != \"PENDING\"
          and ((.submitted_at | type) != \"string\"
            or (.submitted_at
                | . as \$raw
                | try (strptime(\"%Y-%m-%dT%H:%M:%SZ\") | mktime | strftime(\"%Y-%m-%dT%H:%M:%SZ\")) catch \"\"
                | . != \$raw))
          then error(\"review record has no canonical submission time\")
        else . end
      | [ .user.login,
          .state,
          (.submitted_at // \"\"),
          (.id | tostring),
          (if (.body | test(\"(^|\\\\n)[ \\\\t\\\\r]*${FM_REVIEW_VERDICT}[ \\\\t\\\\r]*(\$|\\\\n)\")) then \"verdict\" else \"none\" end),
          (if ((.user.login | ascii_downcase) != (\"$GH_PR_AUTHOR\" | ascii_downcase))
              and .commit_id == \"$GH_LIVE_HEAD\" then \"scope\" else \"out\" end),
          .commit_id
        ]
      | @tsv
    end" 2>&1) || {
    printf '%s\n' "$records" >&2
    return 1
  }
  # Every account and commit the response named is judged as the forge spelled
  # it, by bin/fm-pr-lib.sh's own owners, and before any normalization: a login
  # ending in an uppercase app suffix is not a login GitHub issued just because
  # lowercasing it would produce one. This covers records this head does not
  # adjudicate too, because one impossible value makes the whole response
  # unreadable rather than partly trusted.
  while IFS='	' read -r _fm_login _fm_state _fm_at _fm_id _fm_verdict _fm_scope _fm_commit; do
    [ -n "$_fm_login" ] || continue
    if ! fm_pr_github_login_valid "$_fm_login"; then
      printf 'error: a review record names an account GitHub could not have issued: %s\n' \
        "$_fm_login" >&2
      return 1
    fi
    if ! fm_pr_head_valid "$_fm_commit"; then
      printf 'error: a review record names a commit GitHub could not have issued: %s\n' \
        "$_fm_commit" >&2
      return 1
    fi
  done <<RECORDS
$records
RECORDS
  # Per reviewer, keep the latest state-bearing record, ordered by submission
  # time with the record id as the tiebreak. A blocking effective verdict wins
  # over an approving one whatever order the reviewers are visited in, and two
  # records sharing one ordering position leave no latest verdict to read.
  FM_REVIEW_ADJUDICATION=$(printf '%s\n' "$records" | awk -F'\t' '
    $6 == "scope" && $1 != "" && ($2 == "APPROVED" || $2 == "CHANGES_REQUESTED" || $2 == "DISMISSED") {
      reviewer = tolower($1)
      order = $3 "\t" sprintf("%020d", $4)
      if ((reviewer SUBSEP order) in seen) { ambiguous = 1 }
      seen[reviewer SUBSEP order] = 1
      if (!(reviewer in latest) || order > latest[reviewer]) {
        latest[reviewer] = order
        verdict_state[reviewer] = $2
        verdict_line[reviewer] = $5
      }
    }
    END {
      if (ambiguous) { print "ambiguous"; exit 0 }
      approved = 0
      for (reviewer in verdict_state) {
        if (verdict_state[reviewer] == "CHANGES_REQUESTED") { print "blocked"; exit 0 }
        if (verdict_state[reviewer] == "APPROVED" && verdict_line[reviewer] == "verdict") approved = 1
      }
      print (approved ? "approved" : "none")
    }') || { FM_REVIEW_ADJUDICATION=invalid; return 1; }
  case "$FM_REVIEW_ADJUDICATION" in
    approved|none|blocked|ambiguous) ;;
    *) FM_REVIEW_ADJUDICATION=invalid ;;
  esac
  [ "$FM_REVIEW_ADJUDICATION" = approved ]
}

merge_meta_identity_matches() {
  [ "$FM_PR_META_URL" = "$URL" ]
}

record_missing_review_override() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-merge-meta \
    missing_review_override_ts \
    merge_meta_identity_matches "missing_review_override_ts=$timestamp"
}

clear_missing_review_override() {
  fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-merge-meta \
    missing_review_override_ts \
    merge_meta_identity_matches
}

# The captain-authorized non-green merge receipt: what was overridden, for
# which pull request and head, when, and what was observed to be non-green.
# Every key is dropped and rewritten together, so a receipt can never keep a
# field from an earlier override.
FM_RED_OVERRIDE_KEYS=red_override_ts:red_override_pr:red_override_head:red_override_condition

record_red_override() {  # <observed non-green condition>
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-merge-meta \
    "$FM_RED_OVERRIDE_KEYS" \
    merge_meta_identity_matches \
    "red_override_ts=$timestamp" \
    "red_override_pr=$URL" \
    "red_override_head=$GH_LIVE_HEAD" \
    "red_override_condition=$1"
}

clear_red_override() {
  fm_pr_meta_rewrite "$META" "$STATE" .fm-pr-merge-meta \
    "$FM_RED_OVERRIDE_KEYS" \
    merge_meta_identity_matches
}

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

FM_PR_GITHUB_MERGE_ACCEPTED=false

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

# The merge this run performs, always bound to the head every gate above
# verified. It goes through GitHub's merge API, where sha= makes GitHub refuse
# a head that moved instead of landing commits nothing reviewed. There is no
# other path: the CLI merge cannot carry that binding, so it is not used for
# GitHub, and a merge this request defers to the forge is refused earlier.
github_run_merge() {
  # The merge API refuses an already-merged pull request, so a repeat run skips
  # a merge that already landed instead of turning at-least-once outcome
  # recovery into a failure.
  [ "$GH_PR_MERGED" != true ] || return 0
  set -- --field "sha=$GH_LIVE_HEAD" --field "merge_method=$FM_MERGE_METHOD"
  [ "$FM_MERGE_COMMIT_TITLE_SET" -eq 0 ] \
    || set -- "$@" --field "commit_title=$FM_MERGE_COMMIT_TITLE"
  [ "$FM_MERGE_COMMIT_MESSAGE_SET" -eq 0 ] \
    || set -- "$@" --field "commit_message=$FM_MERGE_COMMIT_MESSAGE"
  gh-axi api PUT "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" "$@"
}

# A caller-requested branch deletion, performed only after the merge is proved
# landed, and only for a head branch in this same repository: a fork's head ref
# is not this repository's to delete. A failed deletion is reported and never
# turns a landed merge into a failed one.
github_delete_head_branch() {
  [ "$FM_MERGE_DELETE_BRANCH" -eq 1 ] || return 0
  if [ "$GH_HEAD_REPO" != "$PR_OWNER/$PR_REPO" ]; then
    printf 'actionable: merged %s but left head branch %s in place: it belongs to %s, not this repository\n' \
      "$URL" "$GH_HEAD_REF" "${GH_HEAD_REPO:-an unreadable repository}" >&2
    return 0
  fi
  gh-axi api DELETE "/repos/$PR_OWNER/$PR_REPO/git/refs/heads/$GH_HEAD_REF" >/dev/null 2>&1 \
    || printf 'actionable: merged %s but could not delete head branch %s\n' "$URL" "$GH_HEAD_REF" >&2
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
      printf 'error: base branch %s requires the merge queue, configured for %s; a queued merge lands whatever the head is when the queue reaches it, which this script cannot bind to the reviewed head, so the merge has to be arranged outside it\n' \
        "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      ;;
    conflicting)
      printf 'error: base branch %s requires the merge queue and has conflicting configured merge methods (%s)\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if [ "$state" != merged ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state is %s; the merge poll remains armed\n' \
      "$URL" "$state" >&2
    return 1
  fi
}

# GitHub's live identity is read before anything is recorded, so a request
# naming a repository the forge spells differently refuses without re-pointing
# the task or arming a poll for an identity this run rejected.
[ "$PROVIDER" != github ] || github_read_pr_identity || exit 1

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
record_pr_metadata || exit 1

case "$PROVIDER" in
  github)
    # From here until this pull request's outcome is durable is one transaction
    # on the per-task metadata lock. Registration above releases its own lock,
    # and a concurrent fm-pr-check.sh may legitimately re-point the task and
    # replace the previous PR's receipts and poll. Holding this keeps that from
    # landing between the receipt and the merge it authorizes, and equally from
    # landing between the merge and the outcome read: a refusal that promises
    # the pull request's metadata and poll remain recorded has to be telling
    # the truth about this pull request, not whichever one replaced it. The
    # exit trap releases it on every refusing path.
    fm_pr_meta_lock "$META" || {
      echo "error: task metadata is unavailable" >&2
      exit 1
    }
    if ! grep -qxF "pr=$URL" "$META"; then
      echo "error: this task no longer names $URL; refusing to merge a pull request it is not bound to" >&2
      exit 1
    fi
    resolve_review_gate_requirement || exit 1

    MISSING_REVIEW_OVERRIDE=0
    if [ "$FM_REVIEW_GATE_REQUIRED" -eq 1 ]; then
      if ! firstmate_review_verdict_recorded; then
        # Only an absence the forge actually reported is an absence. A reviewer
        # asking for changes, an unreadable order, and evidence that could not
        # be read or validated are each refusals in their own right, so the
        # captain's absence escape cannot stand in for any of them.
        if [ "$FM_REVIEW_ADJUDICATION" = blocked ]; then
          echo "error: refusing Firstmate merge: an independent reviewer's latest verdict at head $GH_LIVE_HEAD requests changes" >&2
          exit 1
        fi
        if [ "$FM_REVIEW_ADJUDICATION" = ambiguous ]; then
          echo "error: refusing Firstmate merge: two review records at head $GH_LIVE_HEAD share one ordering position, so no latest verdict can be read" >&2
          exit 1
        fi
        if [ "$FM_REVIEW_ADJUDICATION" = invalid ]; then
          echo "error: refusing Firstmate merge: the review evidence for head $GH_LIVE_HEAD could not be read or validated, which is not the same as a pull request no one has reviewed" >&2
          exit 1
        fi
        if [ "$ALLOW_MISSING_REVIEW" -ne 1 ]; then
          echo "error: refusing Firstmate merge without an independent review stating \"$FM_REVIEW_VERDICT\" on its own line at head $GH_LIVE_HEAD; pass --allow-missing-review only with explicit captain authorization" >&2
          exit 1
        fi
        MISSING_REVIEW_OVERRIDE=1
      fi
    fi

    # Keep the all-project red-merge guard independent of the Firstmate-only
    # Review receipt. Queue-aware outcome verification below is
    # post-call evidence; it must not let a non-green PR reach the forge call.
    CHECKS_OUTPUT=
    MERGEABLE_OUTPUT=
    CHECKS_GREEN=0
    MERGEABLE_GREEN=0
    if CHECKS_OUTPUT=$(gh-axi pr checks "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>&1); then
      if printf '%s\n' "$CHECKS_OUTPUT" \
        | grep -Eq '^summary: "[0-9]+ passed, 0 failed(, [0-9]+ skipped)?, [1-9][0-9]* total"$'; then
        CHECKS_GREEN=1
      fi
    fi
    if MERGEABLE_OUTPUT=$(gh api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
      --jq '.mergeable == true and .mergeable_state == "clean"' 2>&1); then
      if printf '%s\n' "$MERGEABLE_OUTPUT" | grep -qx true; then
        MERGEABLE_GREEN=1
      fi
    fi
    RED_CONDITION=
    [ "$CHECKS_GREEN" -eq 1 ] || RED_CONDITION="checks not green"
    [ "$MERGEABLE_GREEN" -eq 1 ] \
      || RED_CONDITION="${RED_CONDITION:+$RED_CONDITION; }mergeable state not clean"
    RED_OVERRIDE=0
    if [ -n "$RED_CONDITION" ]; then
      if [ "$ALLOW_RED" -ne 1 ]; then
        echo "error: refusing to merge non-green PR $URL; pass --allow-red only with captain authorization" >&2
        printf '%s\n' "$CHECKS_OUTPUT" "$MERGEABLE_OUTPUT" >&2
        exit 1
      fi
      RED_OVERRIDE=1
    fi

    merge_output=
    if [ "$MISSING_REVIEW_OVERRIDE" -eq 1 ]; then
      record_missing_review_override || {
        echo "error: could not record the captain-authorized missing-Review override" >&2
        exit 1
      }
      echo "warning: captain-authorized override: merging Firstmate PR without an independent review" >&2
    elif grep -q '^missing_review_override_ts=' "$META"; then
      clear_missing_review_override || {
        echo "error: could not clear the stale missing-Review override receipt" >&2
        exit 1
      }
    fi
    if [ "$RED_OVERRIDE" -eq 1 ]; then
      record_red_override "$RED_CONDITION" || {
        echo "error: could not record the captain-authorized non-green merge override" >&2
        exit 1
      }
      printf 'warning: captain-authorized override: merging non-green %s at head %s (%s)\n' \
        "$URL" "$GH_LIVE_HEAD" "$RED_CONDITION" >&2
    elif grep -q '^red_override_' "$META"; then
      clear_red_override || {
        echo "error: could not clear the stale non-green merge override receipt" >&2
        exit 1
      }
    fi
    if merge_output=$(github_run_merge 2>&1); then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
    else
      merge_status=$?
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
          github_report_unmerged_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        fi
      fi
      exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      github_delete_head_branch
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      github_report_forge_output "$merge_output"
      printf 'error: %s entered the merge queue instead of merging: the queue lands whatever the head is when it reaches this pull request, so no reviewed commit is proved landed; the merge poll remains armed\n' \
        "$URL" >&2
      exit 1
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    # The same transaction GitHub takes, for the same reason: registration
    # above released its own lock, and a concurrent fm-pr-check.sh may
    # legitimately re-point the task and replace this merge request's poll.
    # Holding this keeps that from landing between the verified head and the
    # merge it authorizes, or between that merge and the outcome reported
    # against this record. The exit trap releases it on every refusing path.
    fm_pr_meta_lock "$META" || {
      echo "error: task metadata is unavailable" >&2
      exit 1
    }
    if ! grep -qxF "pr=$URL" "$META"; then
      echo "error: this task no longer names $URL; refusing to merge a merge request it is not bound to" >&2
      exit 1
    fi
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    # The parsed vector, not the caller's original words: what reaches glab is
    # exactly what this script read and accepted.
    # --auto-merge defaults to true in glab and is sent whenever the merge
    # request has a pipeline, so an ordinary request would schedule merge
    # authority for a later head. Immediate mode is stated rather than assumed,
    # and the caller cannot set this field.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --auto-merge=false --yes \
      "${FM_GITLAB_MERGE_ARGS[@]+"${FM_GITLAB_MERGE_ARGS[@]}"}"
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit "$gitlab_confirm_rc"
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
# The landed outcome is durable, so the task record is releasable again.
fm_pr_meta_unlock
# The merge landed: the actionable line above is the loud report for a failed
# outcome record, never a failed merge exit code. The armed poll and the
# durable wake row own at-least-once recovery of the record.
