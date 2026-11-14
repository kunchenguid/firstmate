#!/usr/bin/env bash
# Run one write on a pull request after checking who authored it.
#
# Usage: fm-pr-write.sh <pr-url> <action> [options]
#   edit [--title <text>] [--body-file <path>]
#   comment --body-file <path>
#   review --approve|--comment|--request-changes [--body-file <path>]
#   resolve-thread <thread-node-id>
#   The script builds the gh call itself, so the checked <pr-url> is the only PR
#   the write can reach. Title and body values pass through untouched. A
#   resolve-thread whose thread belongs to another PR is refused with no write.
#   Any other action or option is refused with exit 2. Merges go through
#   fm-pr-merge.sh instead.
#   With config/pr-author-write-guard present, a PR that the signed-in account
#   did not author and no task of this home recorded as pr= is refused with exit
#   3 and the reason. Park that write as an owner decision rather than retrying
#   it another way. Without the flag the action runs unchecked.
#   fm_pr_write_author_check in fm-pr-lib.sh owns the check.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die_usage() {
  printf 'fm-pr-write: %s\n' "$1" >&2
  printf 'fm-pr-write: usage: fm-pr-write.sh <pr-url> edit|comment|review|resolve-thread ... (see --help)\n' >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -ge 2 ] || die_usage 'a PR URL and an action are required'

URL=$1
ACTION=$2
shift 2
fm_pr_url_parse "$URL" && [ "$FM_PR_PROVIDER" = github ] || die_usage "not a GitHub pull request URL: $URL"

THREAD=
CMD=(gh pr "$ACTION" "$URL")
case $ACTION in
  edit)
    while [ "$#" -gt 0 ]; do
      case $1 in
        --title|--body-file) [ "$#" -ge 2 ] || die_usage "$1 needs a value"; CMD+=("$1" "$2"); shift 2 ;;
        *) die_usage "unknown option for edit: $1" ;;
      esac
    done
    [ "${#CMD[@]}" -gt 4 ] || die_usage 'edit needs --title or --body-file'
    ;;
  comment)
    [ "$#" -eq 2 ] && [ "$1" = --body-file ] || die_usage 'comment needs exactly --body-file <path>'
    CMD+=("$1" "$2")
    ;;
  review)
    kind=
    while [ "$#" -gt 0 ]; do
      case $1 in
        --approve|--comment|--request-changes) [ -z "$kind" ] || die_usage 'review takes one verdict'; kind=$1; CMD+=("$1"); shift ;;
        --body-file) [ "$#" -ge 2 ] || die_usage "$1 needs a value"; CMD+=("$1" "$2"); shift 2 ;;
        *) die_usage "unknown option for review: $1" ;;
      esac
    done
    [ -n "$kind" ] || die_usage 'review needs --approve, --comment, or --request-changes'
    ;;
  resolve-thread)
    [ "$#" -eq 1 ] && [ -n "$1" ] || die_usage 'resolve-thread needs one thread node id'
    THREAD=$1
    ;;
  *) die_usage "unknown action: $ACTION" ;;
esac

if ! fm_pr_write_author_check "$URL"; then
  printf 'fm-pr-write: refused: %s; park this write as an owner decision\n' "$FM_PR_WRITE_REFUSAL" >&2
  exit 3
fi

export GH_HOST=$FM_PR_HOST
if [ -n "$THREAD" ]; then
  thread_pr=$(gh api graphql -f query='query($id: ID!) { node(id: $id) { ... on PullRequestReviewThread { pullRequest { url } } } }' \
    -f id="$THREAD" --jq .data.node.pullRequest.url 2>/dev/null) || thread_pr=
  if [ "$thread_pr" != "$URL" ]; then
    printf 'fm-pr-write: refused: thread %s does not belong to %s; park this write as an owner decision\n' "$THREAD" "$URL" >&2
    exit 3
  fi
  exec gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }' -f id="$THREAD"
fi
exec "${CMD[@]}"
