#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and a verified pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-cs-lib.sh
. "$SCRIPT_DIR/fm-cs-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
CODESPACE=
if [ -f "$META" ]; then
  CODESPACE=$(grep '^codespace=' "$META" | cut -d= -f2- || true)
fi

if [ -n "$CODESPACE" ]; then
  # Codespace crewmate: HEAD lives in the codespace; PR auth uses the scoped PAT.
  RDIR=$(grep '^repo_dir=' "$META" | cut -d= -f2- || true)
  LOCAL_HEAD=
  PR_HEAD=
  if [ -n "$RDIR" ]; then
    LOCAL_HEAD=$(cs_ssh "$CODESPACE" -- "cd '$RDIR' && git rev-parse --verify HEAD 2>/dev/null" 2>/dev/null || true)
  fi
  if [ -n "$LOCAL_HEAD" ]; then
    if REMOTE_HEAD=$(_cs_gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
      [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] && PR_HEAD=$LOCAL_HEAD
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then echo "pr=$URL" >> "$META"; fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then echo "pr_head=$PR_HEAD" >> "$META"; fi
  cat > "$STATE/$ID.check.sh" <<EOF
. "$FM_ROOT/bin/fm-cs-lib.sh"
state=\$(_cs_gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
  echo "armed: state/$ID.check.sh polls $URL (codespace task)"
  exit 0
fi

if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  LOCAL_HEAD=
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    LOCAL_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
    if [ -n "$LOCAL_HEAD" ] && command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
          PR_HEAD=$LOCAL_HEAD
        fi
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
