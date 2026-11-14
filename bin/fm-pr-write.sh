#!/usr/bin/env bash
# Run one write on a pull request after checking who authored it.
#
# Usage: fm-pr-write.sh <pr-url> -- <command> [args...]
#   Runs <command> with <pr-url> appended as its last argument when the check
#   allows the write and exits with its status. A command that names its own PR
#   (a pull request URL or a bare number) is refused with exit 2, so the write
#   targets exactly the checked PR.
#   A write is a review-thread resolve, a body or title edit, a comment,
#   or a review; merges go through fm-pr-merge.sh instead.
#   With config/pr-author-write-guard present, a PR that the signed-in account
#   did not author and no task of this home recorded as pr= is refused with exit
#   3 and the reason. Park that write as an owner decision rather than retrying
#   it another way. Without the flag the command runs unchecked.
#   fm_pr_write_author_check in fm-pr-lib.sh owns the check.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
if [ "$#" -lt 3 ] || [ "$2" != -- ]; then
  printf 'fm-pr-write: usage: fm-pr-write.sh <pr-url> -- <command> [args...]\n' >&2
  exit 2
fi

URL=$1
shift 2
for arg in "$@"; do
  if [[ $arg == */pull/* || $arg =~ ^[0-9]+$ ]]; then
    printf 'fm-pr-write: the command must not name its own PR: %s\n' "$arg" >&2
    exit 2
  fi
done
if ! fm_pr_write_author_check "$URL"; then
  printf 'fm-pr-write: refused: %s; park this write as an owner decision\n' "$FM_PR_WRITE_REFUSAL" >&2
  exit 3
fi
exec "$@" "$URL"
