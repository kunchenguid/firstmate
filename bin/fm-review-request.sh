#!/usr/bin/env bash
# Request exactly one OpenCode "/oc review" on a pull request's current head.
#
# A request is posted only when the pull request's repository carries the
# OpenCode caller workflow (.github/workflows/opencode.yml) on its default
# branch, the pull request is not a draft, and neither a request comment nor a
# completed OpenCode review already covers the current head. Re-running this
# after a push, a poll, or a restart therefore never posts a duplicate: a head
# is covered once any "/oc review" request or relay-auto-review command, or an
# OpenCode "oc-review: completed" reply, appears at or after that head's commit
# time. A later push moves the head past those comments, so the next run
# requests a fresh review for the new head.
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

HEAD_TIME=$(gh api "repos/$PROJECT/commits/$HEAD" --jq .commit.committer.date 2>/dev/null) \
  || refuse "could not read $URL's head commit time"

COMMENTS=$(gh api "repos/$PROJECT/issues/$NUMBER/comments?per_page=100" --paginate --slurp 2>/dev/null) \
  || refuse "could not read $URL's comments"

COVER=$(printf '%s' "$COMMENTS" | jq -r --arg head_time "$HEAD_TIME" '
  (add // []) as $c
  | ($head_time | fromdateiso8601) as $he
  | ($c | map(select(((.created_at // "") | fromdateiso8601? // 0) >= $he))) as $recent
  | if ($recent | any(.[]; (.body // "") | test("<!-- oc-review: completed -->"))) then "completed"
    elif ($recent | any(.[]; ((.body // "") | test("/oc review")) or ((.body // "") | test("<!-- relay-auto-review:")))) then "requested"
    else "" end
')

case "$COVER" in
  completed)
    printf 'skipped: a completed OpenCode review already covers %s %s\n' "$HEAD" "$URL"
    exit 0
    ;;
  requested)
    printf 'skipped: an OpenCode review is already requested for %s %s\n' "$HEAD" "$URL"
    exit 0
    ;;
esac

gh pr comment "$NUMBER" --repo "$PROJECT" --body "/oc review" >/dev/null 2>&1 \
  || refuse "could not post the review request on $URL"
printf 'requested /oc review on %s %s\n' "$HEAD" "$URL"
