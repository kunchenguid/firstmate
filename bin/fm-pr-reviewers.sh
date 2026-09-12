#!/usr/bin/env bash
# Suggest GitHub reviewers from recent authorship of a pull request's files.
#
# This is a read-only advisory command. It reads the pull request's exact file
# list, then the most recent 100 commits on its base commit for each path. A
# commit is counted once even when it touched multiple changed paths. Candidates
# use GitHub's own commit author.login mapping; names and email addresses are
# never converted or guessed. The pull-request author and Bot accounts are
# excluded.
#
# Usage: fm-pr-reviewers.sh <pr-url-or-number>
#   Prints candidates in descending unique-commit count as:
#     <github-login><tab><count> recent commit[s]
#   When no mapped author other than the pull-request author appears, prints no
#   candidate and explains that result. Lookup or usage refusal exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-reviewers: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-reviewers.sh <pr-url-or-number>"
command -v gh >/dev/null 2>&1 || die "gh is required"

INPUT=$1
if [[ "$INPUT" =~ ^[1-9][0-9]*$ ]]; then
  URL=$(gh pr view "$INPUT" --json url --jq .url) \
    || die "could not read pull request $INPUT"
else
  URL=$INPUT
fi
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL or positive pull-request number"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"
CORE=$(gh api "$ENDPOINT" --jq '"author=\(.user.login)", "base=\(.base.sha)"') \
  || die "could not read $URL"
AUTHOR=
BASE=
while IFS= read -r row; do
  case "$row" in
    author=*) AUTHOR=${row#author=} ;;
    base=*) BASE=${row#base=} ;;
  esac
done <<EOF
$CORE
EOF
[ -n "$AUTHOR" ] && [ -n "$BASE" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

FILES=$(gh api "$ENDPOINT/files?per_page=100" --paginate --jq '.[].filename') \
  || die "could not read changed files for $URL"
[ -n "$FILES" ] || {
  printf 'NO CANDIDATES: pull request changes no files\n'
  exit 0
}

EVIDENCE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-reviewers.XXXXXX") \
  || die "could not create temporary evidence file"
trap 'rm -f "$EVIDENCE"' EXIT INT TERM

while IFS= read -r file; do
  ROWS=$(gh api --method GET "/repos/$PATH_PART/commits" \
    -f sha="$BASE" \
    -f path="$file" \
    -F per_page=100 \
    --jq '.[] | select(.author.type != "Bot") | [.sha, (.author.login // "")] | @tsv') \
    || die "could not read recent commits for $file"
  [ -z "$ROWS" ] || printf '%s\n' "$ROWS" >> "$EVIDENCE"
done <<EOF
$FILES
EOF

CANDIDATES=$(awk -F '\t' -v author="$AUTHOR" '
  $2 != "" && $2 != author {
    key = $1 SUBSEP $2
    if (!seen[key]++) count[$2]++
  }
  END {
    for (login in count)
      printf "%s\t%d recent commit%s\n", login, count[login], (count[login] == 1 ? "" : "s")
  }
' "$EVIDENCE" | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1)

if [ -z "$CANDIDATES" ]; then
  printf 'NO CANDIDATES: no mapped author other than the PR author\n'
else
  printf '%s\n' "$CANDIDATES"
fi
