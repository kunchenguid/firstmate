#!/usr/bin/env bash
# Print the active PropPlane sandbox worktree for this home (Cursor pane / local agent).
#
# Owner: config/proplane-active-sandbox (one branch name per line, e.g. cursor-2)
# and config/proplane-agent-branches (branch → worktree → port).
#
# Usage:
#   fm-proplane-active-worktree.sh              # worktree path
#   fm-proplane-active-worktree.sh --branch     # branch name
#   fm-proplane-active-worktree.sh --port       # localhost port
#   fm-proplane-active-worktree.sh --url        # http://localhost:<port>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

ACTIVE_FILE="${FM_HOME}/config/proplane-active-sandbox"
DEFAULT_BRANCH="cursor-2"

branch="$DEFAULT_BRANCH"
if [ -f "$ACTIVE_FILE" ]; then
  read -r line _ <"$ACTIVE_FILE" || true
  line=$(printf '%s' "$line" | sed 's/#.*//' | tr -d '[:space:]')
  [ -n "$line" ] && branch="$line"
fi

worktree=""
port=""
while IFS=$'\t' read -r b wt p; do
  [ "$b" = "$branch" ] || continue
  worktree=$wt
  port=$p
  break
done < <(fm_proplane_agent_rows)

if [ -z "$worktree" ]; then
  echo "fm-proplane-active-worktree: unknown branch $branch (set $ACTIVE_FILE)" >&2
  exit 1
fi

case "${1:-}" in
  --branch) printf '%s\n' "$branch" ;;
  --port) printf '%s\n' "$port" ;;
  --url) printf 'http://localhost:%s\n' "$port" ;;
  --help|-h)
    echo "usage: fm-proplane-active-worktree.sh [--branch|--port|--url]"
    exit 0
    ;;
  "") printf '%s\n' "$worktree" ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
esac
