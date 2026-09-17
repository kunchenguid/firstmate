#!/usr/bin/env bash
# Report the blockers this command can see on one GitHub pull request.
#
# This is a one-shot, read-only command. It reads the current pull request,
# reported checks, submitted reviews, and review decision from GitHub at
# invocation time. It never posts, requests, approves, or merges.
# It reports on checks that have reported. A required context that has never
# reported on this head is absent from what this command reads and cannot be
# enumerated here. Empty output therefore means that no reported required check
# is failing or pending; it does not mean the pull request is ready to merge.
# When nothing has reported, or nothing required has, that is printed rather
# than read as ready. Advisory checks do not block and are omitted.
# A pull request that only awaits an approval (reviewDecision REVIEW_REQUIRED)
# is not reported as blocked. GitHub's reviewDecision owns whether reviews
# block; review history is printed only to explain CHANGES_REQUESTED, naming
# each reviewer whose latest verdict still requests changes and marking it
# STALE when it was left at a superseded head.
# A closed or merged pull request reports that terminal state and nothing else.
# Unresolved review-thread state is out of this command's scope.
#
# Usage: fm-pr-state.sh <pr-url>
#   Prints one line per blocker it can see and nothing when it sees none.
#   Blockers do not change the successful exit status; lookup or usage refusal
#   exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
[ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"

URL=$1
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

if [ -n "$MERGED_AT" ]; then
  printf 'STATE: merged at %s\n' "$MERGED_AT"
  exit 0
elif [ "$STATE" != open ]; then
  printf 'STATE: %s\n' "$STATE"
  exit 0
fi
[ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM
if ! REQUIRED=$(gh pr checks "$URL" --required --json name,state,bucket --jq '
  .[]
  | select(.bucket != "pass" and .bucket != "skipping")
  | "REQUIRED CHECK: \(.name) (\(.state))"' 2>"$GH_STDERR"); then
  # These two sentences are gh's own human-readable error text, verified against
  # gh 2.100.0 on 2026-09-12. gh reports "nothing reported" as an error rather
  # than as structured data, so matching its text is the only way to tell that
  # apart from a real lookup failure. An unrecognised message falls through to
  # the refusal below, so a reword degrades loudly rather than silently.
  if grep -q "^no checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: none reported yet"
  elif grep -q "^no required checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: no required check has reported; readiness unconfirmed"
  else
    cat "$GH_STDERR" >&2
    die "could not read required checks for $URL"
  fi
fi
[ -z "$REQUIRED" ] || printf '%s\n' "$REQUIRED"

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
