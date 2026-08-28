#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, and a Forgejo pull request through forgejo-axi by that host as
# --base-url plus the derived owner and repository, so any instance of either
# self-hosted forge works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# The gh-axi merge abstraction always performs the merge; the outcome read that
# follows it never becomes a prerequisite for reaching that abstraction. After
# gh-axi returns success, GitHub's live state is read back and accepted only
# when the pull request is merged or in the merge queue. gh's GraphQL API
# supplies that queue-aware read when gh is on PATH; when gh is absent or its
# read fails, gh-axi's own view still proves a landed merge, and every outcome
# it cannot prove refuses, reporting the single failed read when gh is absent
# and naming both failed reads when gh is present and its own read failed.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# the exact -- --auto --<method> retry flags, unless the caller already passed
# that method with --auto to a merge command that returned success, in which
# case it reports instead that the accepted request has not entered the queue
# and the queue state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose. The observed state is judged the same way whichever
# read produced it, and a refusal built on the gh-axi view says the merge queue
# could not be observed at all rather than implying an unqueued pull request.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
# Forgejo has no such convention to preserve: its merge API requires the method
# in the request body, so some method is always chosen. This script therefore
# names the same --squash default GitHub gets, rather than inheriting
# forgejo-axi's own "merge" default, and a caller who wants another one passes
# -- --method merge|rebase. GitHub's --squash, --merge and --rebase spellings
# are not flags forgejo-axi takes, so they are refused by name before anything
# is recorded rather than suppressing that default and failing at the CLI.
# A repository that disallows the chosen method fails the merge loudly at the
# forge instead of landing something else.
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
# A Forgejo merge is refused the same way, from one live mergeability read taken
# at merge time: the pull request must be mergeable by the forge's own judgement
# and its checks must pass at the current head, with every failing condition and
# the forge's own reasons reported rather than only the first. The verified head
# is then passed to forgejo-axi as --expected-head, which re-reads it before the
# merge, sends it as the request's head_commit_id, and refuses to report a merge
# it cannot prove landed at that exact commit. A recorded pr_head that disagrees
# with the live head is reported rather than trusted. Reading that state needs
# forgejo-axi and jq, and either one absent stops the merge before any state is
# recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab or --expected-head on Forgejo because the head comes
# only from the live read, nor --base-url on Forgejo because the instance comes
# only from the URL, nor --squash, --merge or --rebase on Forgejo because that
# CLI names the method only as --method.
#
# On GitLab and Forgejo, this script confirms the request is actually merged
# before reporting it; an auto-merge-queued or unconfirmed request leaves the
# poll armed and records no landed outcome.
# bin/fm-merge-outcome-lib.sh owns a confirmed merge's destination, normal-case
# deduplication, and at-least-once recovery.
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
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
# forgejo-axi resolves the instance from --base-url. It accepts a pull request
# URL too, but reads only owner/repository/number out of one and still sends the
# request to whatever host its own configuration resolves, so the host is passed
# explicitly rather than left to an ambient default.
BASE_URL="https://$FM_PR_HOST"
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

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
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

# The flag each provider's CLI takes for the head commit, rejected in extra
# arguments because the head comes only from this run's own live read.
reject_head_overrides() {
  local flag=$1 arg
  shift
  for arg in "$@"; do
    case "$arg" in
      "$flag"|"$flag"=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_base_url_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --base-url|--base-url=*)
        echo "error: extra merge arguments must not override the forge instance" >&2
        return 1
        ;;
    esac
  done
}

# forgejo-axi names the merge method only as --method <name>. GitHub's own
# --squash, --merge and --rebase spellings are refused by name here rather than
# forwarded, because forgejo-axi rejects them as unknown flags after the live
# pre-merge read has already run, and they would first suppress this path's own
# --method squash default.
reject_github_merge_methods() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase)
        printf 'error: extra merge arguments must name a Forgejo merge method as --method squash|merge|rebase, not %s\n' \
          "$arg" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides --sha "$@" || exit 1
if [ "$PROVIDER" = forgejo ]; then
  reject_head_overrides --expected-head "$@" || exit 1
  reject_base_url_overrides "$@" || exit 1
  reject_github_merge_methods "$@" || exit 1
fi

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

FORGEJO_MISSING=
if [ "$PROVIDER" = forgejo ]; then
  command -v forgejo-axi >/dev/null 2>&1 || FORGEJO_MISSING="forgejo-axi"
  if ! command -v jq >/dev/null 2>&1; then
    FORGEJO_MISSING="${FORGEJO_MISSING:+$FORGEJO_MISSING and }jq"
  fi
  if [ -n "$FORGEJO_MISSING" ]; then
    echo "error: merging a Forgejo pull request requires $FORGEJO_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ] || [ "$PROVIDER" = forgejo ]; then
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
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
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

# Pre-merge conditions for a Forgejo pull request, read from one live
# mergeability view. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
forgejo_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local number='' view_url='' live_head='' forge_mergeable='' checks_pass='' mergeable='' reasons=''

  if ! json=$(forgejo-axi pr mergeability --base-url "$BASE_URL" \
      --repo "$PR_OWNER/$PR_REPO" "$PR_NUMBER" --json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi
  # One named field per line, the same shape the GitLab read uses. reasons is
  # joined into one line because it is reported rather than compared, and a
  # reason carrying a newline would otherwise split into a line no name matches
  # and fail the exact-field-count check below.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.mergeability | type == "object") then
        .mergeability |
        "number=" + ((.number // "") | tostring),
        "url=" + ((.url // "") | tostring),
        "head=" + ((.head_sha // "") | tostring),
        "forge_mergeable=" + (.forgejo_mergeable | tostring),
        "checks_pass=" + (.checks_pass | tostring),
        "mergeable=" + (.mergeable | tostring),
        "reasons=" + ((.reasons // []) | map(tostring | gsub("[\r\n]"; " ")) | join(", "))
      else
        error("mergeability payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      number=*) number=${line#number=} ;;
      url=*) view_url=${line#url=} ;;
      head=*) live_head=${line#head=} ;;
      forge_mergeable=*) forge_mergeable=${line#forge_mergeable=} ;;
      checks_pass=*) checks_pass=${line#checks_pass=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      reasons=*) reasons=${line#reasons=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the Forgejo pull request state before merging" >&2
    return 1
  fi

  # The forge's own answer has to be about the pull request this run named, so a
  # view that came back for another one refuses instead of authorizing a merge.
  if [ "$number" != "$PR_NUMBER" ] || [ "$view_url" != "$URL" ]; then
    printf 'error: the Forgejo pull request state read back as %s #%s, not %s\n' \
      "${view_url:-<no url>}" "${number:-<no number>}" "$URL" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the Forgejo pull request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$forge_mergeable" = true ] \
    || refusals="$refusals  - the forge reports mergeable as \"${forge_mergeable:-unreadable}\", not true
"
  [ "$checks_pass" = true ] \
    || refusals="$refusals  - the checks at head $live_head report passing as \"${checks_pass:-unreadable}\", not true
"
  [ "$mergeable" = true ] \
    || refusals="$refusals  - the merged verdict is \"${mergeable:-unreadable}\", not true
"
  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    [ -z "$reasons" ] || printf 'error:   - the forge names: %s\n' "$reasons" >&2
    return 1
  fi
  printf 'verified: %s is mergeable with passing checks at head %s\n' "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

# Confirm a Forgejo pull request actually landed after the merge command
# returned. forgejo-axi already refuses to report a merge it cannot prove, so
# this read is the independent second opinion: an unreadable answer is reported
# as unconfirmed rather than as a failure, which leaves the merge poll armed.
forgejo_confirm_merged() {
  local json merged url
  if ! json=$(forgejo-axi pr merged --base-url "$BASE_URL" \
      --repo "$PR_OWNER/$PR_REPO" "$PR_NUMBER" --json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: Forgejo accepted the merge for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! merged=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.proof | type == "object") and (.proof.merged | type == "boolean") then .proof.merged | tostring else error("invalid proof") end' \
    2>/dev/null) \
    || ! url=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.proof | type == "object") and (.proof.url | type == "string") then .proof.url else error("invalid proof") end' \
    2>/dev/null); then
    printf 'actionable: Forgejo accepted the merge for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$url" = "$URL" ] || {
    printf 'actionable: Forgejo accepted the merge for %s but answered for %s instead; the merge poll remains armed\n' \
      "$URL" "$url" >&2
    return 2
  }
  [ "$merged" = true ] || {
    printf 'actionable: Forgejo accepted the merge for %s but reads back as not merged; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  }
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

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

FM_PR_GITHUB_AUTO_REQUESTED=false
FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

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

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
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
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
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
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
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
  [ "$state" = merged ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
record_pr_metadata || exit 1

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if caller_requested_auto_merge "$@"; then
      FM_PR_GITHUB_AUTO_REQUESTED=true
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1); then
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
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  forgejo)
    forgejo_verify_mergeable || exit 1
    forgejo_args=()
    if ! caller_has_merge_method "$@"; then
      forgejo_args=(--method squash)
    fi
    # --expected-head binds the merge to the head this run verified: forgejo-axi
    # re-reads it before merging, sends it as the request's head_commit_id, and
    # refuses to report a merge it cannot prove landed at that exact commit, so a
    # push that lands in between is refused instead of merged unverified.
    forgejo-axi pr merge --base-url "$BASE_URL" --repo "$PR_OWNER/$PR_REPO" \
      "$PR_NUMBER" --expected-head "$FM_PR_MERGE_HEAD" \
      "${forgejo_args[@]+"${forgejo_args[@]}"}" "$@"
    forgejo_confirm_rc=0
    forgejo_confirm_merged || forgejo_confirm_rc=$?
    [ "$forgejo_confirm_rc" -eq 0 ] || exit 0
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
