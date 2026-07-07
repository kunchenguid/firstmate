#!/usr/bin/env bash
# Record a PR-ready task and arm the watcher's merge-attribution poll.
#
# Appends pr=<url> and GitHub's pr_head=<sha> to state/<id>.meta when available,
# records pr_checks=<N|unknown> (the count of CI checks on the PR, so the merge
# path can tell real CI from a vacuous "green" on a repo with no PR CI), then
# writes state/<id>.check.sh - the watcher's per-task poll (its check contract:
# output = wake firstmate, silence = keep sleeping).
#
# The generated check.sh ATTRIBUTES rather than merely detects: it sources
# bin/fm-merge-attribution-lib.sh and, when the PR is MERGED, compares the merge
# against the merged_by_firstmate marker that fm-pr-merge.sh writes before its own
# merges. A merge firstmate performed stays silent; a merge firstmate did NOT
# perform emits a distinct unattributed-merge: wake for firstmate to confirm and
# reconcile (never fight - prime directive 4). An unreadable PR state emits a
# merge-state-unknown: warning rather than assuming the PR is still open.
#
# Arm this as soon as a tracked ship task has an open PR (see AGENTS.md section 7
# Validate), not only at checks-green, so an out-of-band merge is caught for the
# PR's whole lifetime.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

ATTRIB_LIB="$SCRIPT_DIR/fm-merge-attribution-lib.sh"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  # Default to unknown, not 0: a worktree we cannot stat or a failed gh read must
  # never masquerade as a definite "0 checks" (which would read as a valid
  # no-CI posture). unknown makes the merge gate refuse an unattended merge.
  PR_CHECKS=unknown
  if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
    if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
      PR_HEAD=$REMOTE_HEAD
    fi
    if CN=$(cd "$WT" && gh pr view "$URL" --json statusCheckRollup -q '.statusCheckRollup | length' 2>/dev/null); then
      case "$CN" in
        ''|*[!0-9]*) PR_CHECKS=unknown ;;
        *)           PR_CHECKS=$CN ;;
      esac
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
  # pr_checks can change as checks register (0 -> N), so replace rather than
  # append-if-absent: the latest read is what the merge gate must see.
  if grep -q '^pr_checks=' "$META"; then
    { grep -v '^pr_checks=' "$META" || true; } > "$META.tmp" && mv "$META.tmp" "$META"
  fi
  echo "pr_checks=$PR_CHECKS" >> "$META"
fi

{
  printf '. %s\n' "$(shell_quote "$ATTRIB_LIB")"
  printf 'url=%s\n' "$(shell_quote "$URL")"
  printf 'meta=%s\n' "$(shell_quote "$META")"
  cat <<'EOF'
case "$(fm_merge_attribution "$url" "$meta")" in
  unattributed)
    by=$(fm_merge_probe_mergedby "$url")
    echo "unattributed-merge: PR $url merged${by:+ by $by}, no firstmate merge on record" ;;
  unknown)
    echo "merge-state-unknown: could not read PR state for $url (gh empty or unreadable); not assuming unmerged" ;;
  # attributed (firstmate merged it) and open/closed-unmerged: silent, nothing to wake for.
esac
EOF
} > "$STATE/$ID.check.sh"
echo "armed: state/$ID.check.sh attributes merges of $URL"
