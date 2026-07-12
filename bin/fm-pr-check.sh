#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
#
# It also runs bin/fm-pr-body-check.sh against the LIVE PR body, so firstmate
# reads what was published instead of trusting the crewmate to have checked it.
# That scan is SURFACE-ONLY and never blocks: pr=/pr_head= are recorded and the
# merge poll is armed whatever it says, it never edits the PR, and a scan that
# fails or is unavailable is reported loudly rather than passed off as clean.
# Flagged lines are for firstmate to READ and judge, not a verdict.
#
# bin/fm-pr-merge.sh runs this script again at merge time (with
# FM_PR_CHECK_CONTEXT=merge, which only adjusts the failure wording). That
# merge-time scan prevents nothing: the body has been public since the PR
# opened, and the merge follows in the same invocation with nothing pausing to
# read this output. It is a post-hoc record of what was actually published -
# its value is catching a body edited between PR-ready and merge, and leaving a
# durable verdict for firstmate to read. Leak prevention lives earlier: at
# PR-open, in the crewmate's verify-before-done step, and at PR-ready, where
# firstmate reads this scan before relaying the PR.
#
# The scan itself always runs. Only the PRINT is deduped, keyed on the URL plus
# the scan output, so ANY repeat invocation for the same PR with an unchanged
# verdict - a second PR-ready run as much as the merge - points at
# state/<id>.body-scan instead of re-printing the lines. A failed or
# unavailable scan is never deduped.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"

case "${FM_PR_CHECK_CONTEXT:-}" in
  merge) UNCHECKED="read it yourself before MERGING" ;;
  *) UNCHECKED="read it yourself before relaying the PR" ;;
esac

BODY_CHECK="$FM_ROOT/bin/fm-pr-body-check.sh"
RECORD="$STATE/$ID.body-scan"
if [ -x "$BODY_CHECK" ]; then
  BODY_CODE=0
  BODY_OUT=$("$BODY_CHECK" "$URL" 2>&1) || BODY_CODE=$?
  SCANNED=$(printf '%s\n%s' "$URL" "$BODY_OUT")
  PREV=""
  [ -f "$RECORD" ] && PREV=$(cat "$RECORD")
  case "$BODY_CODE" in
    0) printf '%s\n' "$SCANNED" > "$RECORD" ;;
    1)
      # The scan always runs - a body edited since the last check must still be
      # caught - but re-printing an unchanged verdict on any repeat run of the
      # same PR is noise, so only the print is deduped.
      if [ "$PREV" = "$SCANNED" ]; then
        echo "PR body scan: same flagged lines as the last check of this PR; nothing new. Read them in state/$ID.body-scan."
      else
        printf '%s\n' "$BODY_OUT"
        printf '%s\n' "$SCANNED" > "$RECORD"
      fi
      ;;
    *)
      rm -f "$RECORD"
      echo "PR BODY SCAN FAILED (exit $BODY_CODE): the published body was NOT checked - $UNCHECKED." >&2
      printf '%s\n' "$BODY_OUT" >&2
      ;;
  esac
else
  rm -f "$RECORD"
  echo "PR BODY SCAN UNAVAILABLE: $BODY_CHECK is missing or not executable; the published body was NOT checked - $UNCHECKED." >&2
fi
