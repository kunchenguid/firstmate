#!/usr/bin/env bash
# Request exactly one OpenCode "/oc review" on a pull request's current head.
#
# A request is posted only when the repository carries the OpenCode caller
# workflow (.github/workflows/opencode.yml) on its default branch, the pull
# request is not a draft, and no request comment already carries the durable,
# head-bound marker for the current head. The request comment is itself the
# per-head record: its body embeds
#   <!-- fm-review-request head=<40-hex head sha> -->
# so coverage is bound to the exact head SHA, never to a timestamp or to an
# arbitrary substring. A new head has no marker, so the next run requests a
# fresh review; the same head has one, so a poll or restart never duplicates
# it. A human comment or a Relay command is never treated as a completed
# OpenCode review, because only this mechanism's own head marker suppresses a
# request.
#
# This command performs exactly one forge write at most - the single request
# comment it reports as "requested". It never merges, never approves, never
# edits, and never deletes anything. It is GitHub-only; another forge address
# is refused rather than guessed at.
#
# Usage: fm-review-request.sh <pr-url>
#   Prints exactly one line and exits 0 for either outcome:
#     requested /oc review on <head> <url>
#     skipped: <reason>
#   A forge lookup or write failure exits 1; a usage or address refusal exits 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-review-request: %s\n' "$*" >&2
  exit 2
}

refuse() {
  printf 'fm-review-request: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-review-request.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

URL=$1
if ! fm_pr_url_parse "$URL"; then
  die "expected a pull-request URL"
fi
[ "$FM_PR_PROVIDER" = github ] || die "OpenCode review requests are GitHub-only"
PROJECT=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

PR_JSON=$(gh api "repos/$PROJECT/pulls/$NUMBER" 2>/dev/null) || refuse "could not read $URL"
HEAD=$(printf '%s' "$PR_JSON" | jq -er '.head.sha | select(test("^[0-9a-f]{40}$"))' 2>/dev/null) \
  || refuse "could not read $URL's head commit"
DRAFT=$(printf '%s' "$PR_JSON" | jq -r 'if .draft == true then "true" else "false" end' 2>/dev/null || printf 'false')

DEFAULT_BRANCH=$(gh api "repos/$PROJECT" --jq .default_branch 2>/dev/null) \
  || refuse "could not read $PROJECT's default branch"

# The 404 test distinguishes a genuinely absent caller from an unreadable
# repository: only a definite 404 lets the request be skipped as unnecessary.
CALLER_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-review-request.XXXXXX") || die "could not create a scratch file"
trap 'rm -f -- "$CALLER_ERR"' EXIT
if ! gh api "repos/$PROJECT/contents/.github/workflows/opencode.yml?ref=$DEFAULT_BRANCH" --jq .path >/dev/null 2>"$CALLER_ERR"; then
  if grep -q '404' "$CALLER_ERR"; then
    printf 'skipped: no OpenCode caller workflow on %s %s\n' "$DEFAULT_BRANCH" "$URL"
    exit 0
  fi
  refuse "could not read $PROJECT's workflow files"
fi

if [ "$DRAFT" = true ]; then
  printf 'skipped: %s is a draft\n' "$URL"
  exit 0
fi

COMMENTS=$(gh api "repos/$PROJECT/issues/$NUMBER/comments?per_page=100" --paginate --slurp 2>/dev/null) \
  || refuse "could not read $URL's comments"

MARKER="<!-- fm-review-request head=$HEAD -->"
if printf '%s' "$COMMENTS" | jq -r --arg marker "$MARKER" \
  'if ((add // []) | any(.[]; (.body // "") | contains($marker))) then "covered" else "" end' | grep -q covered; then
  printf 'skipped: an OpenCode review is already requested for %s %s\n' "$HEAD" "$URL"
  exit 0
fi

# The head-bound marker travels inside the review command as an HTML comment the
# OpenCode caller ignores but a later run reads back.
gh pr comment "$NUMBER" --repo "$PROJECT" \
  --body "/oc review

$MARKER" >/dev/null 2>&1 \
  || refuse "could not post the review request on $URL"
printf 'requested /oc review on %s %s\n' "$HEAD" "$URL"
