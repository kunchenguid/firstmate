#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and the PR head sha (pr_head=<sha>) to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Provider (GitHub or Azure DevOps) is auto-detected from the PR URL and the host
# calls are routed through bin/fm-scm-lib.sh; see docs/ado-backend.md.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2
PROVIDER=$(fm_scm_provider_of_url "$URL")

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    REMOTE_HEAD=$(fm_scm_pr_head "$PROVIDER" "$WT" "$URL" 2>/dev/null || true)
    [ -n "$REMOTE_HEAD" ] && PR_HEAD=$REMOTE_HEAD
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

WT_FOR_CHECK=${WT:-}
cat > "$STATE/$ID.check.sh" <<EOF
state=\$("$SCRIPT_DIR/fm-scm-lib.sh" pr-state "$PROVIDER" "$WT_FOR_CHECK" "$URL" 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
