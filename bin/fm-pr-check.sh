#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and the PR/MR head pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR/MR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# Host-aware: the git host is inferred from the PR/MR URL via bin/fm-git-host-lib.sh
# (no registry field). A GitHub PR URL resolves pr_head via `gh pr view --json
# headRefOid` and polls MERGED; a GitLab MR URL resolves pr_head via `glab mr view
# <iid> -R <repo> -F json` (.sha) and polls the LOWERCASE `merged` state (.state).
# The pr=/pr_head= meta contract is host-agnostic and unchanged: a GitLab MR URL is
# a valid pr= value and its head SHA a valid pr_head= value (docs/glab-backend.md).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-git-host-lib.sh
. "$SCRIPT_DIR/fm-git-host-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    case "$(fm_git_host_classify "$URL")" in
      gitlab)
        # Host/namespace/iid come from the parsed MR URL, never ambient glab
        # config; -R carries the host so self-hosted instances resolve correctly.
        if parsed=$(fm_pr_url_parse "$URL") \
          && command -v glab >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
          MR_HOST=$(printf '%s' "$parsed" | cut -f2)
          MR_NS=$(printf '%s' "$parsed" | cut -f3)
          MR_IID=$(printf '%s' "$parsed" | cut -f4)
          if REMOTE_HEAD=$(cd "$WT" && glab mr view "$MR_IID" -R "https://$MR_HOST/$MR_NS" -F json 2>/dev/null | jq -r '.sha // empty' 2>/dev/null) \
            && [ -n "$REMOTE_HEAD" ]; then
            PR_HEAD=$REMOTE_HEAD
          fi
        fi
        ;;
      *)
        if command -v gh >/dev/null 2>&1; then
          if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
            PR_HEAD=$REMOTE_HEAD
          fi
        fi
        ;;
    esac
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

case "$(fm_git_host_classify "$URL")" in
  gitlab)
    parsed=$(fm_pr_url_parse "$URL") || { echo "error: cannot parse GitLab MR URL: $URL" >&2; exit 1; }
    MR_HOST=$(printf '%s' "$parsed" | cut -f2)
    MR_NS=$(printf '%s' "$parsed" | cut -f3)
    MR_IID=$(printf '%s' "$parsed" | cut -f4)
    cat > "$STATE/$ID.check.sh" <<EOF
state=\$(glab mr view '$MR_IID' -R 'https://$MR_HOST/$MR_NS' -F json 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
[ "\$state" = "merged" ] && echo "merged"
EOF
    ;;
  *)
    cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
    ;;
esac
echo "armed: state/$ID.check.sh polls $URL"
