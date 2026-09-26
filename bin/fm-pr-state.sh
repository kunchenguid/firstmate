#!/usr/bin/env bash
# Read current GitHub pull-request state without changing the forge.
#
# The one-argument form reports known blockers for one pull request. It reads
# reported required checks, submitted reviews, and review decision at invocation
# time. Empty output does not mean the pull request is ready to merge. Unreported
# required checks cannot be enumerated; when none have reported, that is printed
# rather than read as ready. Advisory checks do not block and are omitted. A
# pull request that only awaits approval is not reported as blocked. GitHub's
# reviewDecision owns whether reviews block; review history explains only
# CHANGES_REQUESTED, naming each reviewer's latest blocking verdict and marking
# it STALE when left at a superseded head. Unresolved review-thread state is out
# of scope.
#
# The --audit form reads the task's recorded GitHub PR and recorded pr_head,
# then reports fresh PR fields, required-check results, and the worker's current
# endpoint and state. A review-ready verdict requires a done worker, matching
# head, non-draft PR, and a provably complete passing required-check set for
# every delivery mode. Merge readiness requires that complete check set, a
# matching head, non-draft PR, mergeability, no changes-requested decision, and
# any required review to be approved. The
# reported-check interface cannot prove completeness, so those verdicts stay
# unverified when GitHub cannot prove the full set. The verdict is evidence for
# reporting, not merge authority.
#
# Usage: fm-pr-state.sh <pr-url>
#        fm-pr-state.sh --audit <task-id>
#   The first form prints blockers and otherwise stays silent. The audit form
#   prints a complete evidence report and verdict. Lookup or usage refusals exit
#   non-zero; neither form posts, requests, approves, or merges.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TASK_STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
AUDIT=0
AUDIT_ID=
META=
RECORDED_HEAD=
if [ "${1:-}" = --audit ]; then
  [ "$#" -eq 2 ] || die "usage: fm-pr-state.sh --audit <task-id>"
  AUDIT=1
  AUDIT_ID=$2
  fm_pr_task_id_valid "$AUDIT_ID" || die "invalid task id"
  META="$TASK_STATE_DIR/$AUDIT_ID.meta"
  [ -f "$META" ] && [ ! -L "$META" ] \
    && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
    || die "task metadata is unavailable"
  fm_pr_metadata_identity_parse "$META" \
    || die "task metadata does not contain a valid recorded PR identity"
  if [ "$FM_PR_META_PROVIDER" != github ]; then
    printf 'PR: %s\n' "$FM_PR_META_URL"
    printf 'VERDICT: UNVERIFIED (live audit supports GitHub pull requests only)\n'
    printf 'MERGE VERDICT: UNVERIFIED (live audit supports GitHub pull requests only)\n'
    exit 0
  fi
  URL=$FM_PR_META_URL
  RECORDED_HEAD=$(awk -F= '$1 == "pr_head" { count++; value = substr($0, index($0, "=") + 1) } END { if (count == 1) print value }' "$META")
  [ -z "$RECORDED_HEAD" ] || fm_pr_head_valid "$RECORDED_HEAD" \
    || die "task metadata contains an invalid recorded PR head"
else
  [ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url> | --audit <task-id>"
  URL=$1
  if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
    die "expected a GitHub pull-request URL"
  fi
fi
command -v gh >/dev/null 2>&1 || die "gh is required"

if [ "$AUDIT" -eq 1 ]; then
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision,closingIssuesReferences,milestone --jq '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")",
  "closing_issues=\([(.closingIssuesReferences // [])[]? | .url] | join(", "))",
  "milestone=\(.milestone.title // "")"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
CLOSING_ISSUES=
MILESTONE=
SEEN_CLOSING_ISSUES=0
SEEN_MILESTONE=0
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
    closing_issues=*) CLOSING_ISSUES=${row#closing_issues=}; SEEN_CLOSING_ISSUES=1 ;;
    milestone=*) MILESTONE=${row#milestone=}; SEEN_MILESTONE=1 ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] \
  || die "GitHub returned incomplete pull-request state for $URL"
if [ "$AUDIT" -eq 1 ] \
  && { [ "$SEEN_CLOSING_ISSUES" -ne 1 ] || [ "$SEEN_MILESTONE" -ne 1 ]; }; then
  die "GitHub returned incomplete decision-audit fields for $URL"
fi

if [ "$AUDIT" -eq 0 ]; then
  if [ -n "$MERGED_AT" ]; then
    printf 'STATE: merged at %s\n' "$MERGED_AT"
    exit 0
  elif [ "$STATE" != open ]; then
    printf 'STATE: %s\n' "$STATE"
    exit 0
  fi
  [ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
else
  printf 'PR: %s\n' "$URL"
  printf 'PR STATE: %s\n' "$STATE"
  printf 'LIVE HEAD: %s\n' "$HEAD"
  if [ -n "$RECORDED_HEAD" ]; then
    printf 'RECORDED PR HEAD: %s\n' "$RECORDED_HEAD"
    if [ "$RECORDED_HEAD" = "$HEAD" ]; then
      printf 'HEAD MATCH: yes\n'
    else
      printf 'HEAD MATCH: no\n'
    fi
  else
    printf 'RECORDED PR HEAD: none\nHEAD MATCH: unverified\n'
  fi
  printf 'DRAFT: %s\n' "$DRAFT"
  printf 'CLOSING ISSUE REFERENCES: %s\n' "${CLOSING_ISSUES:-none}"
  printf 'MILESTONE: %s\n' "${MILESTONE:-none}"
  printf 'REVIEW DECISION: %s\n' "${REVIEW_DECISION:-none}"
fi
case "$MERGEABILITY" in
  mergeable) [ "$AUDIT" -eq 0 ] || printf 'MERGEABILITY: mergeable\n' ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM
CHECKS_STATUS=unverified
CHECK_COUNT=0
CHECK_STATUS_NOTE=
if ! CHECK_ROWS=$(gh pr checks "$URL" --required --json name,state,bucket --jq '
  .[] | [.name, .state, .bucket] | @tsv' 2>"$GH_STDERR"); then
  # These two sentences are gh's own human-readable error text, verified against
  # gh 2.100.0 on 2026-09-12. gh reports "nothing reported" as an error rather
  # than as structured data, so matching its text is the only way to tell that
  # apart from a real lookup failure. An unrecognised message falls through to
  # the refusal below, so a reword degrades loudly rather than silently.
  if grep -q "^no checks reported on the '" "$GH_STDERR"; then
    CHECK_STATUS_NOTE="CHECKS: none reported yet"
  elif grep -q "^no required checks reported on the '" "$GH_STDERR"; then
    CHECK_STATUS_NOTE="CHECKS: no required check has reported; readiness unconfirmed"
  else
    cat "$GH_STDERR" >&2
    die "could not read required checks for $URL"
  fi
fi

if [ -n "$CHECK_STATUS_NOTE" ]; then
  if [ "$AUDIT" -eq 1 ]; then
    printf 'CHECK STATUS: %s\n' "${CHECK_STATUS_NOTE#CHECKS: }"
  else
    printf '%s\n' "$CHECK_STATUS_NOTE"
  fi
else
  while IFS=$'\t' read -r check_name check_state check_bucket; do
    [ -n "$check_name" ] || continue
    CHECK_COUNT=$((CHECK_COUNT + 1))
    if [ "$AUDIT" -eq 1 ]; then
      printf 'CHECK STATUS: %s (%s; %s)\n' "$check_name" "$check_state" "$check_bucket"
    fi
    case "$check_bucket" in
      pass|skipping) ;;
      *)
        CHECKS_STATUS=blocked
        [ "$AUDIT" -eq 1 ] || printf 'REQUIRED CHECK: %s (%s)\n' "$check_name" "$check_state"
        ;;
    esac
  done <<EOF_CHECKS
$CHECK_ROWS
EOF_CHECKS
  if [ "$CHECK_COUNT" -eq 0 ]; then
    CHECK_STATUS_NOTE="CHECKS: no required check result returned; readiness unconfirmed"
    [ "$AUDIT" -eq 1 ] && printf 'CHECK STATUS: no required check result returned; readiness unconfirmed\n' \
      || printf '%s\n' "$CHECK_STATUS_NOTE"
  elif [ "$CHECKS_STATUS" = unverified ]; then
    if [ "$AUDIT" -eq 1 ]; then
      printf 'CHECK STATUS: reported required check results are non-blocking, but completeness is unverified; unreported required checks cannot be enumerated\n'
    fi
  fi
fi

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
    .[]
    | select(.user.login != null and .commit_id != null and .submitted_at != null)
    | [.user.login, .state, .commit_id, .submitted_at]
    | @tsv') || die "could not read reviews for $URL"
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 4 && $1 != author && $2 != "COMMENTED" && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $4
      state[$1] = $2
      commit[$1] = $3
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head)
          printf "REVIEW: %s CHANGES_REQUESTED\n", reviewer
        else
          printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s\n", \
            reviewer, commit[reviewer]
      }
    }' | LC_ALL=C sort
fi

if [ "$AUDIT" -eq 1 ]; then
  MODE=$(fm_meta_get "$META" mode)
  WORKER_STATE=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$TASK_STATE_DIR" \
    "$FM_ROOT/bin/fm-crew-state.sh" "$AUDIT_ID" 2>/dev/null || true)
  case "$WORKER_STATE" in
    'state: '*) ;;
    *) WORKER_STATE='unavailable' ;;
  esac
  WORKER_STATE_KIND=$(printf '%s\n' "$WORKER_STATE" | sed -n 's/^state: \([^ ·]*\).*/\1/p')

  BACKEND=$(fm_backend_of_meta "$META")
  TARGET=$(fm_backend_target_of_meta "$META")
  REMOTE_HOST=$(fm_meta_get "$META" remote_host)
  if [ -n "$REMOTE_HOST" ]; then
    case "$WORKER_STATE" in
      *'remote endpoint alive on '*) WORKER_ENDPOINT=alive ;;
      *'remote endpoint dead on '*) WORKER_ENDPOINT=dead ;;
      *'remote endpoint missing on '*) WORKER_ENDPOINT=missing ;;
      *) WORKER_ENDPOINT=unverified ;;
    esac
  elif [ -n "$TARGET" ]; then
    WORKER_ENDPOINT=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null || printf unreadable)
  else
    WORKER_ENDPOINT=unverified
  fi
  printf 'WORKER ENDPOINT: %s\n' "$WORKER_ENDPOINT"
  printf 'WORKER STATE: %s\n' "$WORKER_STATE"
  printf 'DELIVERY MODE: %s\n' "${MODE:-unknown}"

  HEAD_MATCH=0
  [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" = "$HEAD" ] && HEAD_MATCH=1
  if [ -n "$MERGED_AT" ]; then
    printf 'VERDICT: MERGED at %s\n' "$MERGED_AT"
    printf 'MERGE VERDICT: already merged\n'
  elif [ "$STATE" = closed ]; then
    printf 'VERDICT: CLOSED\n'
    printf 'MERGE VERDICT: closed without a recorded merge\n'
  elif [ "$STATE" != open ]; then
    printf 'VERDICT: UNVERIFIED (unexpected PR state: %s)\n' "$STATE"
    printf 'MERGE VERDICT: UNVERIFIED\n'
  else
    REVIEW_REASONS=()
    REVIEW_UNKNOWN=()
    MERGE_REASONS=()
    MERGE_UNKNOWN=()
    if [ "$DRAFT" != false ]; then
      REVIEW_REASONS+=(draft)
      MERGE_REASONS+=(draft)
    fi
    if [ -z "$RECORDED_HEAD" ]; then
      REVIEW_UNKNOWN+=("recorded PR head is unavailable")
      MERGE_UNKNOWN+=("recorded PR head is unavailable")
    elif [ "$HEAD_MATCH" -ne 1 ]; then
      REVIEW_REASONS+=("recorded head is stale")
      MERGE_REASONS+=("recorded head is stale")
    fi
    case "$WORKER_STATE_KIND" in
      done) ;;
      working|parked|blocked|paused|failed)
        REVIEW_REASONS+=("worker is not currently done")
        MERGE_REASONS+=("worker is not currently done")
        ;;
      *)
        REVIEW_UNKNOWN+=("worker state is unavailable")
        MERGE_UNKNOWN+=("worker state is unavailable")
        ;;
    esac
    [ "$REVIEW_DECISION" != CHANGES_REQUESTED ] || REVIEW_REASONS+=("changes are requested")
    case "$CHECKS_STATUS" in
      blocked) REVIEW_REASONS+=("required checks are not all passing") ;;
      *) REVIEW_UNKNOWN+=("required check status is unverified") ;;
    esac
    case "$MODE" in
      no-mistakes|direct-PR) ;;
      *) REVIEW_UNKNOWN+=("delivery mode is unavailable or unsupported") ;;
    esac
    case "$CHECKS_STATUS" in
      blocked) MERGE_REASONS+=("required checks are not all passing") ;;
      *) MERGE_UNKNOWN+=("required check status is unverified") ;;
    esac
    case "$MERGEABILITY" in
      mergeable) ;;
      conflicting) MERGE_REASONS+=("PR has merge conflicts") ;;
      *) MERGE_UNKNOWN+=("PR mergeability is unverified") ;;
    esac
    [ "$REVIEW_DECISION" != CHANGES_REQUESTED ] || MERGE_REASONS+=("changes are requested")
    [ "$REVIEW_DECISION" != REVIEW_REQUIRED ] || MERGE_REASONS+=("required review is outstanding")

    if [ "${#REVIEW_REASONS[@]}" -gt 0 ]; then
      printf 'VERDICT: NOT READY FOR REVIEW (%s)\n' "$(IFS=', '; printf '%s' "${REVIEW_REASONS[*]}")"
    elif [ "${#REVIEW_UNKNOWN[@]}" -gt 0 ]; then
      printf 'VERDICT: UNVERIFIED (%s)\n' "$(IFS=', '; printf '%s' "${REVIEW_UNKNOWN[*]}")"
    else
      printf 'VERDICT: READY FOR REVIEW\n'
    fi
    if [ "${#MERGE_REASONS[@]}" -gt 0 ]; then
      printf 'MERGE VERDICT: NOT READY (%s)\n' "$(IFS=', '; printf '%s' "${MERGE_REASONS[*]}")"
    elif [ "${#MERGE_UNKNOWN[@]}" -gt 0 ]; then
      printf 'MERGE VERDICT: UNVERIFIED (%s)\n' "$(IFS=', '; printf '%s' "${MERGE_UNKNOWN[*]}")"
    else
      printf 'MERGE VERDICT: READY (merge authority still applies)\n'
    fi
  fi
fi
