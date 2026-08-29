#!/usr/bin/env bash
# Merge one task's canonical PR or MR through its guarded provider owner after
# bin/fm-pr-check.sh records pr= and the exact available pr_head=. The wrapper
# requires the caller to name the already-resolved captain-explicit or standing
# routine merge authority; destination identity never substitutes for authority.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. GitHub is addressed by
# derived owner/repository, while GitLab is addressed by URL-derived host,
# complete nested project path, and MR IID.
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
# GitLab accepts no caller merge behavior except one optional explicit
# --squash, which is consumed as confirmation of the sole supported strategy.
# Before provider access the wrapper rejects repository, hostname, head,
# authority, output, auto-merge, source-deletion, alternate-method, unknown,
# duplicate, and positional overrides rather than forwarding any of them.
#
# The wrapper records the exact source head from one bounded glab-axi MR view,
# re-resolves that URL/head/source/target immediately before mutation, and calls
# exactly one guarded glab-axi mr merge with URL-derived identity, durable head,
# exact branches, explicit authority, immediate squash, and JSON output. It never invokes plain
# glab, retries a merge, or falls back to another mutation path. A zero-exit
# result is accepted only as one strict glab-axi/ux-v1 JSON document whose
# action, identity, head, branches, successful pipeline, authority, and result
# commits all match. One task-bound guarded-squash receipt is then persisted for
# safe cleanup; an unprovable response leaves the poll armed and cleanup refused.
#
# bin/fm-merge-outcome-lib.sh owns a confirmed merge's destination, normal-case
# deduplication, and at-least-once recovery. A landed merge whose outcome cannot
# be written is reported loudly rather than misreported as a failed merge.
# Usage:
#   fm-pr-merge.sh <task-id> <pr-or-mr-url> \
#     --authority <captain-explicit|standing-yolo-green> \
#     [-- <provider merge args>]
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

usage() {
  cat <<'USAGE'
Usage:
  fm-pr-merge.sh <task-id> <pr-or-mr-url> \
    --authority <captain-explicit|standing-yolo-green> \
    [-- <provider merge args>]

Merge one task's canonical pull request or merge request through its guarded
provider owner. GitLab permits only immediate squash and accepts no provider
argument except an optional explicit --squash. GitHub keeps the existing
merge-method default and extra-argument behavior. A validated GitLab result
also records one task-bound guarded-squash receipt for later cleanup.
USAGE
}

invalid_request() {
  echo "error: invalid PR/MR merge request" >&2
  exit 2
}

if [ "$#" -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
  usage
  exit 0
fi
[ "$#" -ge 4 ] || invalid_request

ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  invalid_request
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = --authority ] && [ "$#" -ge 2 ] || invalid_request
AUTHORITY=$2
case "$AUTHORITY" in
  captain-explicit|standing-yolo-green) ;;
  *) invalid_request ;;
esac
shift 2
[ "${1:-}" = -- ] && shift

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

reject_authority_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --authority|--authority=*)
        echo "error: merge authority must be declared exactly once at the Firstmate boundary" >&2
        return 1
        ;;
    esac
  done
}

validate_gitlab_args() {
  local arg squash_count=0
  for arg in "$@"; do
    case "$arg" in
      --squash) squash_count=$((squash_count + 1)) ;;
      *)
        echo "error: GitLab merge arguments allow only one optional --squash" >&2
        return 1
        ;;
    esac
  done
  if [ "$squash_count" -gt 1 ]; then
    echo "error: GitLab merge arguments allow only one optional --squash" >&2
    return 1
  fi
}

gitlab_branch_guards_available() {
  local merge_help option
  merge_help=$(glab-axi mr merge --help 2>&1) || return 1
  for option in --expected-source --expected-target; do
    printf '%s\n' "$merge_help" \
      | grep -Eq -- "(^|[[:space:],])$option([=[:space:],]|$)" || return 1
  done
}

reject_repo_overrides "$@" || exit 1
reject_authority_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || validate_gitlab_args "$@" || exit 1

# Task-derived paths are constructed only after canonical task-ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] \
  || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
if [ "$PROVIDER" = gitlab ] && command -v glab-axi >/dev/null 2>&1 \
  && ! gitlab_branch_guards_available; then
  echo "error: guarded GitLab merge requires glab-axi support for --expected-source and --expected-target" >&2
  exit 1
fi

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
    echo "error: PR/MR metadata recording failed" >&2
    return 1
  }
}

validate_gitlab_merge_result() { # <json> <source> <target> <head>
  local output=$1 source=$2 target=$3 head=$4
  printf '%s\n' "$output" | jq -es \
    --arg host "$HOST" \
    --arg repo "$PROJECT_PATH" \
    --arg url "$URL" \
    --arg source "$source" \
    --arg target "$target" \
    --arg head "$head" \
    --arg authority "$AUTHORITY" \
    --argjson iid "$PR_NUMBER" '
      def sha:
        type == "string"
        and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
      .[0] as $result
      | length == 1
      and ($result | type) == "object"
      and $result.schema == "glab-axi/ux-v1"
      and $result.ok == true
      and $result.meta.backend == "official-glab"
      and $result.meta.host == $host
      and $result.meta.repo == $repo
      and $result.meta.complete == true
      and $result.meta.truncated == false
      and ($result.data.merge | type) == "object"
      and (["merged", "already_merged", "reconciled_merged"]
        | index($result.data.merge.action)) != null
      and ($result.data.merge.iid | type) == "number"
      and $result.data.merge.iid == ($result.data.merge.iid | floor)
      and $result.data.merge.iid == $iid
      and $result.data.merge.web_url == $url
      and $result.data.merge.source_branch == $source
      and $result.data.merge.target_branch == $target
      and $result.data.merge.source_head_sha == $head
      and $result.data.merge.authority == $authority
      and ($result.data.merge.pipeline | type) == "object"
      and ($result.data.merge.pipeline.id | type) == "number"
      and $result.data.merge.pipeline.id > 0
      and $result.data.merge.pipeline.id == ($result.data.merge.pipeline.id | floor)
      and $result.data.merge.pipeline.sha == $head
      and $result.data.merge.pipeline.status == "success"
      and ($result.data.merge.squash_commit_sha | sha)
      and (($result.data.merge.merge_commit_sha == null)
        or ($result.data.merge.merge_commit_sha | sha))
      and ($result.data.merge.result_commit_sha | sha)
      and $result.data.merge.result_commit_sha == (
        if $result.data.merge.merge_commit_sha == null
        then $result.data.merge.squash_commit_sha
        else $result.data.merge.merge_commit_sha
        end
      )
    ' >/dev/null 2>&1
}

record_gitlab_guarded_squash_receipt() { # <validated-json> <source> <target> <head>
  local output=$1 source=$2 target=$3 head=$4 receipt
  receipt=$(printf '%s\n' "$output" | jq -er \
    --arg id "$ID" \
    --arg url "$URL" \
    --arg authority "$AUTHORITY" \
    --arg head "$head" \
    --arg source "$source" \
    --arg target "$target" \
    '["v1", $id, $url, $authority, $head, $source, $target,
      .data.merge.squash_commit_sha, .data.merge.result_commit_sha] | join("|")') \
    || return 1
  fm_pr_gitlab_guarded_squash_receipt_valid "$receipt" || return 1
  (
    local meta_lock meta_tmp receipt_count head_count pr_count
    local meta_device state_device lock_held=0
    meta_lock=
    meta_tmp=
    cleanup_receipt_record() {
      [ -z "$meta_tmp" ] || rm -f -- "$meta_tmp"
      if [ "$lock_held" -eq 1 ]; then
        fm_lock_release "$meta_lock" || true
        lock_held=0
      fi
    }
    trap cleanup_receipt_record EXIT
    trap 'exit 1' HUP INT TERM
    meta_lock=$(fm_meta_lock_path "$META") || exit 1
    fm_lock_acquire_wait "$meta_lock" || exit 1
    lock_held=1
    [ -f "$META" ] && [ ! -L "$META" ] \
      && [ "$(fm_pr_file_link_count "$META")" = 1 ] || exit 1
    meta_device=$(fm_pr_file_device "$META") || exit 1
    state_device=$(fm_pr_file_device "$STATE") || exit 1
    [ "$meta_device" = "$state_device" ] || exit 1
    pr_count=$(grep -c '^pr=' "$META" || true)
    head_count=$(grep -c '^pr_head=' "$META" || true)
    receipt_count=$(grep -c '^gitlab_guarded_squash_receipt=' "$META" || true)
    [ "$pr_count" -eq 1 ] && [ "$head_count" -eq 1 ] \
      && [ "$receipt_count" -le 1 ] || exit 1
    grep -qxF "pr=$URL" "$META" || exit 1
    grep -qxF "pr_head=$head" "$META" || exit 1
    fm_pr_metadata_identity_parse "$META" || exit 1
    [ "$FM_PR_META_PROVIDER" = gitlab ] && [ "$FM_PR_META_URL" = "$URL" ] \
      && [ "$FM_PR_META_HOST" = "$HOST" ] \
      && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
      && [ "$FM_PR_META_NUMBER" = "$PR_NUMBER" ] || exit 1
    meta_tmp=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || exit 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        gitlab_guarded_squash_receipt=*) ;;
        *) printf '%s\n' "$line" >> "$meta_tmp" || exit 1 ;;
      esac
    done < "$META"
    printf 'gitlab_guarded_squash_receipt=%s\n' "$receipt" >> "$meta_tmp" || exit 1
    chmod 0600 "$meta_tmp" || exit 1
    fm_pr_private_file_valid "$meta_tmp" 600 "$state_device" || exit 1
    fm_pr_metadata_identity_parse "$meta_tmp" || exit 1
    [ "$FM_PR_META_PROVIDER" = gitlab ] && [ "$FM_PR_META_URL" = "$URL" ] \
      && [ "$FM_PR_META_HOST" = "$HOST" ] \
      && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
      && [ "$FM_PR_META_NUMBER" = "$PR_NUMBER" ] || exit 1
    fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || exit 1
    mv -f -- "$meta_tmp" "$META" || exit 1
    meta_tmp=
    fm_pr_private_file_valid "$META" 600 "$state_device" || exit 1
    fm_pr_metadata_identity_parse "$META" || exit 1
    grep -qxF "gitlab_guarded_squash_receipt=$receipt" "$META" || exit 1
    [ "$(grep -c '^gitlab_guarded_squash_receipt=' "$META" || true)" -eq 1 ] \
      || exit 1
    trap - EXIT HUP INT TERM
    cleanup_receipt_record
  )
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
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s --authority %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$AUTHORITY" "$queue_method" >&2
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
    PR_HEAD_COUNT=$(grep -c '^pr_head=' "$META" || true)
    if [ "$PR_HEAD_COUNT" -ne 1 ]; then
      echo "error: GitLab merge metadata has no single exact expected head" >&2
      exit 1
    fi
    EXPECTED_HEAD=$(grep '^pr_head=' "$META" | cut -d= -f2-)
    if ! fm_pr_head_valid "$EXPECTED_HEAD"; then
      echo "error: GitLab merge metadata has no single exact expected head" >&2
      exit 1
    fi
    if ! fm_pr_gitlab_mr_resolve "$URL"; then
      echo "error: glab-axi JSON could not revalidate the GitLab merge request before merging" >&2
      exit 1
    fi
    if [ "$FM_PR_RESOLVED_HEAD" != "$EXPECTED_HEAD" ]; then
      echo "error: GitLab merge request head changed after recording; refusing stale expected head" >&2
      exit 1
    fi
    EXPECTED_SOURCE=$FM_PR_RESOLVED_SOURCE_BRANCH
    EXPECTED_TARGET=$FM_PR_RESOLVED_TARGET_BRANCH

    MERGE_RC=0
    MERGE_OUTPUT=$(glab-axi mr merge "$PR_NUMBER" \
      --repo "$PROJECT_PATH" \
      --hostname "$HOST" \
      --expected-url "$URL" \
      --expected-head "$EXPECTED_HEAD" \
      --expected-source "$EXPECTED_SOURCE" \
      --expected-target "$EXPECTED_TARGET" \
      --authority "$AUTHORITY" \
      --squash \
      --format json) || MERGE_RC=$?
    if [ "$MERGE_RC" -ne 0 ]; then
      [ -z "$MERGE_OUTPUT" ] || printf '%s\n' "$MERGE_OUTPUT"
      exit "$MERGE_RC"
    fi
    if ! validate_gitlab_merge_result "$MERGE_OUTPUT" \
      "$EXPECTED_SOURCE" "$EXPECTED_TARGET" "$EXPECTED_HEAD"; then
      echo "error: glab-axi returned an unprovable GitLab merge result; merge state is ambiguous" >&2
      exit 1
    fi
    if ! record_gitlab_guarded_squash_receipt "$MERGE_OUTPUT" \
      "$EXPECTED_SOURCE" "$EXPECTED_TARGET" "$EXPECTED_HEAD"; then
      echo "error: could not persist the validated GitLab guarded-squash receipt" >&2
      exit 1
    fi
    printf '%s\n' "$MERGE_OUTPUT"
    ;;
  *) invalid_request ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused, failed, or ambiguous merge above, while its poll remains armed.
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
