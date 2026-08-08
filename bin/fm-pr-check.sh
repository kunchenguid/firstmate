#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and the forge's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# The PR URL's shape (fm-pr-url-lib.sh) picks the forge: a GitHub URL uses gh; a
# Gitea URL (any host, plural "pulls") uses tea, run with cwd inside the task's
# worktree so tea auto-discovers the right login/host from its origin remote; a
# Bitbucket URL (any host, plural "pull-requests") has no CLI equivalent here, so
# pr_head= is skipped and the armed poll stays silent - the merge happens manually
# in the browser and teardown's content-in-default fallback verifies it landed.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-url-lib.sh
. "$SCRIPT_DIR/fm-pr-url-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

WT=
fm_parse_pr_url "$URL" || true
FORGE=$FM_PR_FORGE

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if [ "$FORGE" = gitea ]; then
      if command -v tea >/dev/null 2>&1; then
        if REMOTE_HEAD=$(cd "$WT" && tea pulls "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" -o json 2>/dev/null | jq -r '.headSha // empty'); then
          [ -n "$REMOTE_HEAD" ] && PR_HEAD=$REMOTE_HEAD
        fi
      fi
    elif [ "$FORGE" != bitbucket ]; then
      if command -v gh >/dev/null 2>&1; then
        if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
          PR_HEAD=$REMOTE_HEAD
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

if [ "$FORGE" = gitea ]; then
  cat > "$STATE/$ID.check.sh" <<EOF
WT=\$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "\$WT" ] && [ -d "\$WT" ]; then
  state=\$(cd "\$WT" 2>/dev/null && tea pulls "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" -o json 2>/dev/null | jq -r '.hasMerged // false')
  [ "\$state" = "true" ] && echo "merged"
fi
EOF
elif [ "$FORGE" = bitbucket ]; then
  cat > "$STATE/$ID.check.sh" <<'EOF'
# Bitbucket PRs are merged manually in the browser; firstmate has no CLI merge
# poll for them, so this poll stays silent (the watcher's check contract) and
# teardown's content-in-default fallback verifies the merge landed.
exit 0
EOF
else
  cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
fi
echo "armed: state/$ID.check.sh polls $URL"
