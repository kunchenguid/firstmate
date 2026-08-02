#!/usr/bin/env bash
# Merge a task's PR after re-verifying the pull request's current head, then
# record pr= and any available pr_head= through bin/fm-pr-check.sh, so teardown
# can verify landed work after squash merges. The full canonical GitHub PR URL
# is parsed by bin/fm-pr-lib.sh and the derived owner/repository and PR number
# are passed to gh-axi as separate arguments.
#
# Verification re-reads the pull request rather than trusting any recorded
# value, because a PR can go red between an earlier check and the merge and
# state/<id>.meta may carry a stale pr_head=. An early read refuses without
# recording the PR or arming its poll, then a final authoritative read runs after
# fm-pr-check.sh and immediately before the verification metadata write and
# merge. Each `gh pr view` call reads the head, mergeability, review decision,
# and check rollup together, so every refusal names the exact head it evaluated.
# The merge is refused when:
#   * no check runs exist on that head - an empty rollup is never read as green,
#     which is the whole point of this guard: a cross-repo fork PR held at
#     action_required dispatches zero workflows and reports zero failures;
#   * any check run is not SUCCESS - a queued, in-progress, skipped, neutral,
#     cancelled, or failed run all refuse, so the guard fails closed on anything
#     that is not an observed pass;
#   * the pull request is not MERGEABLE - CONFLICTING and a not-yet-computed
#     UNKNOWN both refuse;
#   * a review requests changes.
#
# --allow-unverified is the captain's explicit override. It is never a default
# and never inferred from the environment: it skips verification entirely and
# records merge_verification=override in the task's meta so an unverified merge
# stays visible afterwards. A verified merge records merge_verification=verified
# and merge_verified_head=<sha>; absence of both keys means unknown, never
# verified. Both keys are written before pr= so the metadata identity contract in
# bin/fm-pr-lib.sh still parses. The flag is recognised only before the optional
# -- separator; after it, it is forwarded to gh-axi, which rejects it.
#
# The final verification is not atomically bound to the merge. It narrows the
# remaining race window to the verification metadata write, but a head can still
# change before the merge. Closing that race requires a server-side head
# precondition under decision
# pipeline-reports-green-on-absent-ci-decision-merge-atomic-binding. The real
# `gh pr merge` supports `--match-head-commit SHA`, but gh-axi constructs its gh
# arguments from a fixed allowlist of the method, --auto, --delete-branch, --body,
# and --subject and silently drops other flags. Adopting the precondition later
# therefore requires changing the single gh-axi invocation at the end.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-unverified] [-- <extra gh-axi pr merge args>]
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

ALLOW_UNVERIFIED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

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

# One read of the live pull request, so the head reported in a refusal is the
# same head the checks, mergeability, and review decision were read from.
PR_VERIFY_FIELDS=headRefOid,mergeable,reviewDecision,statusCheckRollup
# A CheckRun carries .conclusion (empty while queued or running); a legacy
# StatusContext carries .state instead. Neither is treated as a pass unless it
# says SUCCESS.
PR_VERIFY_QUERY='"head=\(.headRefOid // "")",
"mergeable=\(.mergeable // "")",
"review=\(.reviewDecision // "")",
"checks=\((.statusCheckRollup // []) | length)",
"unsuccessful=\((.statusCheckRollup // []) | map(select(((.conclusion // .state // "") | ascii_upcase) != "SUCCESS")) | length)"'

VERIFIED_HEAD=

verify_current_head() {
  local output line joined
  local head='' mergeable='' review='' checks='' unsuccessful=''
  local -a reasons=()

  command -v gh >/dev/null 2>&1 || {
    echo "error: refusing to merge: the pull request could not be verified because gh is not on PATH" >&2
    return 1
  }
  output=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json "$PR_VERIFY_FIELDS" -q "$PR_VERIFY_QUERY" 2>/dev/null) || {
    echo "error: refusing to merge: the pull request state could not be read from GitHub" >&2
    return 1
  }

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      head=*) head=${line#head=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      review=*) review=${line#review=} ;;
      checks=*) checks=${line#checks=} ;;
      unsuccessful=*) unsuccessful=${line#unsuccessful=} ;;
    esac
  done <<< "$output"

  fm_pr_head_valid "$head" || {
    echo "error: refusing to merge: the pull request head commit could not be read from GitHub" >&2
    return 1
  }
  # Each count is validated on its own. Concatenating them would let one empty
  # field hide behind the other's digits and reach the comparisons below as an
  # empty string, which compares as neither zero nor positive and would merge.
  if [ -z "$checks" ] || [ -n "${checks//[0-9]/}" ] \
    || [ -z "$unsuccessful" ] || [ -n "${unsuccessful//[0-9]/}" ]; then
    printf 'error: refusing to merge head %s: the check rollup could not be read from GitHub\n' \
      "$head" >&2
    return 1
  fi

  [ "$mergeable" = MERGEABLE ] \
    || reasons+=("the pull request is not mergeable (mergeable=${mergeable:-unreported})")
  [ "$review" != CHANGES_REQUESTED ] || reasons+=("a review requests changes")
  # Zero check runs and all-successful check runs both report zero failures, so
  # the empty rollup is refused on its own count and never folded into the
  # failure count below.
  if [ "$checks" -eq 0 ]; then
    reasons+=("no check runs exist on this head")
  elif [ "$unsuccessful" -gt 0 ]; then
    reasons+=("$unsuccessful of $checks check runs are not successful")
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    joined=$(printf '%s; ' "${reasons[@]}")
    printf 'error: refusing to merge head %s: %s\n' "$head" "${joined%; }" >&2
    return 1
  fi
  VERIFIED_HEAD=$head
}

MERGE_META_TMP=
merge_meta_cleanup() {
  [ -z "$MERGE_META_TMP" ] || rm -f -- "$MERGE_META_TMP"
  MERGE_META_TMP=
}
trap merge_meta_cleanup EXIT
trap 'exit 1' HUP INT TERM

# Record how this merge was authorised. The two keys are emitted before any
# pr=/pr_head= lines so fm_pr_metadata_identity_parse, which refuses any unknown
# key after pr=, still accepts the file at every instant.
record_merge_verification() {
  local status=$1 head=$2 line state_device meta_device
  state_device=$(fm_pr_file_device "$STATE") || return 1
  meta_device=$(fm_pr_file_device "$META") || return 1
  [ "$meta_device" = "$state_device" ] || return 1
  MERGE_META_TMP=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || return 1
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        merge_verification=*|merge_verified_head=*|pr=*|pr_head=*) ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$META"
    printf 'merge_verification=%s\n' "$status"
    [ -z "$head" ] || printf 'merge_verified_head=%s\n' "$head"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        pr=*|pr_head=*) printf '%s\n' "$line" ;;
      esac
    done < "$META"
  } > "$MERGE_META_TMP" || return 1
  chmod 0600 "$MERGE_META_TMP" || return 1
  fm_pr_private_file_valid "$MERGE_META_TMP" 600 "$state_device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || return 1
  mv -f -- "$MERGE_META_TMP" "$META" || return 1
  MERGE_META_TMP=
}

if [ "$ALLOW_UNVERIFIED" -ne 1 ]; then
  verify_current_head || exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$ALLOW_UNVERIFIED" -eq 1 ]; then
  MERGE_VERIFICATION=override
  VERIFIED_HEAD=
else
  VERIFIED_HEAD=
  verify_current_head || exit 1
  MERGE_VERIFICATION=verified
fi

record_merge_verification "$MERGE_VERIFICATION" "$VERIFIED_HEAD" || {
  echo "error: merge verification metadata could not be recorded" >&2
  exit 1
}
grep -qxF "merge_verification=$MERGE_VERIFICATION" "$META" || {
  echo "error: merge verification metadata could not be recorded" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
