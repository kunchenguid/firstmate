#!/usr/bin/env bash
# Append a Linear reference to a task's pull request so Linear links the two.
#
# Called by fm-pr-check.sh the moment a task's PR is reported, and safe to run by
# hand afterwards. Linear links a PR to an issue by branch name, by PR TITLE, or
# by a magic word plus the issue ID in the PR DESCRIPTION (verified against
# Linear's GitHub docs, 2026-08-02 - see docs/linear.md for the evidence).
# firstmate's branches are fm/<task-id>, which can never match Linear's own
# branch convention, so the PR body is the hook.
#
# Usage: fm-linear-pr-link.sh <task-id> <pr-url>
#
# CONTRACT: this NEVER fails a PR check. Every path - unconfigured, unreachable,
# unauthenticated, slow, no mirrored issue, gh refusing the edit - prints one line
# saying what did happen and exits 0. A mirrored issue is the exception, not the
# rule: only queued items were ever mirrored, so "no mirrored issue" is the
# normal case and is reported, not treated as an error.
#
# The body edit is strictly additive: the existing body is copied byte-for-byte
# and the reference block appended after it, then the result is checked to still
# start with the original bytes before it is pushed. The pipeline's evidence
# record in the PR body is never rewritten, truncated, or reordered.
#
# Idempotent: a body that already carries firstmate's marker comment or the issue
# identifier is left alone, so running the PR check twice links exactly once.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

if [ $# -lt 2 ]; then
  echo "usage: fm-linear-pr-link.sh <task-id> <pr-url>" >&2
  exit 2
fi
ID=$1
URL=$2

say() { printf 'linear: %s\n' "$1"; }

# An explicit kill switch for an operator who wants the rest of the PR check
# without any Linear traffic at all.
case "${FM_LINEAR_DISABLE:-}" in
  ''|0|false|no|off) ;;
  *) say "disabled by FM_LINEAR_DISABLE; nothing linked"; exit 0 ;;
esac

# shellcheck source=bin/fm-linear-lib.sh
. "$FM_ROOT/bin/fm-linear-lib.sh"
fml_load_config

# The PR path uses a tighter deadline than the default: a slow or hanging Linear
# must never hold up reporting a PR. Two requests at this bound is the worst case.
case "${FM_LINEAR_PR_TIMEOUT:-}" in
  ''|*[!0-9]*) pr_timeout=8 ;;
  *) pr_timeout=${FM_LINEAR_PR_TIMEOUT} ;;
esac
[ "$pr_timeout" -ge 1 ] 2>/dev/null || pr_timeout=8
[ "$pr_timeout" -le "$FML_TIMEOUT" ] || pr_timeout=$FML_TIMEOUT
FML_TIMEOUT=$pr_timeout

if ! fml_available; then
  say "$(fml_unavailable_reason); nothing linked"
  exit 0
fi

set +e
row=$(fml_find_issue "$ID")
rc=$?
set -e
case "$rc" in
  0) ;;
  1) say "no mirrored issue for $ID; nothing linked"; exit 0 ;;
  *) say "lookup unavailable (Linear did not answer within ${pr_timeout}s or rejected the request); nothing linked, PR unaffected"; exit 0 ;;
esac

IDENT=$(printf '%s' "$row" | cut -f1)
ISSUE_URL=$(printf '%s' "$row" | cut -f3)
if [ -z "$IDENT" ]; then
  say "lookup returned no issue identifier for $ID; nothing linked, PR unaffected"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  say "found $IDENT but gh is not installed; nothing linked, PR unaffected"
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-pr.XXXXXX") || {
  say "found $IDENT but could not create a temp dir; nothing linked, PR unaffected"
  exit 0
}
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 143' HUP INT TERM

if ! gh pr view "$URL" --json body -q .body > "$tmp/body" 2>"$tmp/err"; then
  say "found $IDENT but could not read the PR body ($(head -n1 "$tmp/err" 2>/dev/null)); nothing linked, PR unaffected"
  exit 0
fi

if fml_body_links "$tmp/body" "$IDENT"; then
  say "$IDENT already referenced in the PR body; left unchanged"
  exit 0
fi

if ! fml_append_reference "$tmp/body" "$IDENT" "$tmp/new"; then
  say "found $IDENT but could not compose the new PR body; nothing linked, PR unaffected"
  exit 0
fi

# Belt and braces on "strictly additive": the bytes we are about to push must
# still begin with exactly the bytes GitHub gave us. If that ever fails, push
# nothing - a lost evidence record is far worse than a missing link.
orig_bytes=$(wc -c < "$tmp/body" | tr -d '[:space:]')
if ! head -c "$orig_bytes" "$tmp/new" | cmp -s - "$tmp/body"; then
  say "refusing to edit the PR body: the composed body would not be a pure append; nothing linked, PR unaffected"
  exit 0
fi

if ! gh pr edit "$URL" --body-file "$tmp/new" >/dev/null 2>"$tmp/err2"; then
  say "found $IDENT but could not update the PR body ($(head -n1 "$tmp/err2" 2>/dev/null)); nothing linked, PR unaffected"
  exit 0
fi

say "linked $IDENT ($ISSUE_URL) - appended \"$(fml_reference_line "$IDENT")\" to the PR body"
