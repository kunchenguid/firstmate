#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# The merge poll does not stop at "merged": a merge is not shipped until its
# deploy goes Live. When the merged PR's project maps to a Render service, the
# poll hands its single check slot off to bin/fm-deploy-check.sh --arm, which
# rewrites state/<id>.check.sh to verify the merge commit reaches Live (see
# docs/render-deploy-verification.md). A project with no mapped service keeps the
# plain "merged" wake, unchanged.
# Usage: fm-pr-check.sh <task-id> <pr-url>
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
[ "\$state" = "MERGED" ] || exit 0
# Merged. Hand off to deploy verification when this project maps to a Render
# service - the deploy, not the merge, is the real ship signal. fm-deploy-check
# --arm resolves the service and, on success, overwrites this check.sh with the
# deploy probe. If no service maps or the merge commit can't be read, fall back
# to the plain merged wake exactly as before.
proj=\$(basename "\$(sed -n 's/^project=//p' "$META" 2>/dev/null | tail -1)" 2>/dev/null)
sha=\$(gh pr view "$URL" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)
if [ -n "\$sha" ] && [ -n "\$proj" ] && "$SCRIPT_DIR/fm-deploy-check.sh" --arm "$ID" "\$proj" "\$sha" >/dev/null 2>&1; then
  echo "merged, now verifying deploy of \$sha reaches Live"
else
  echo "merged"
fi
EOF
echo "armed: state/$ID.check.sh polls $URL"
