#!/usr/bin/env bash
# Prove preservation of a legacy Firstmate task worktree for recovery relaunch.
# Usage: fm-adopt-worktree.sh <task-id>
# The task record must name a ship or scout whose endpoint is recovery-grade
# dead or missing and whose isolated worktree still belongs to the same project.
# The pool entry must already be durably leased to the expected fm-<task-id>
# holder. Every other pool state refuses without changing the task copy.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" = 1 ] || { usage >&2; exit 2; }
ID=$1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worktree-lease-lib.sh
. "$SCRIPT_DIR/fm-worktree-lease-lib.sh"

field() {
  [ "$(grep -c "^$1=" "$META" 2>/dev/null || true)" = 1 ] || return 1
  grep "^$1=" "$META" | cut -d= -f2-
}

refuse() {
  echo "error: cannot adopt worktree for $ID: $1" >&2
  exit 1
}

[ -f "$META" ] && [ ! -L "$META" ] && [ -r "$META" ] || refuse "task record is not a readable regular file"
KIND=$(field kind) || refuse "task record has no single kind entry"
case "$KIND" in ship|scout) ;; *) refuse "recorded kind $KIND is not ship or scout" ;; esac
PROJECT=$(field project) || refuse "task record has no single project entry"
WORKTREE=$(field worktree) || refuse "task record has no single worktree entry"
PROJECT_REAL=$(cd "$PROJECT" 2>/dev/null && pwd -P) || refuse "recorded project cannot be inspected"
WORKTREE_REAL=$(cd "$WORKTREE" 2>/dev/null && pwd -P) || refuse "recorded worktree cannot be inspected"
[ "$WORKTREE_REAL" != "$PROJECT_REAL" ] || refuse "recorded worktree is the primary checkout"
TOP=$(git -C "$WORKTREE_REAL" rev-parse --show-toplevel 2>/dev/null || true)
TOP_REAL=$(cd "$TOP" 2>/dev/null && pwd -P) || TOP_REAL=
[ "$TOP_REAL" = "$WORKTREE_REAL" ] || refuse "recorded worktree is not an isolated worktree root"
COMMON=$(git -C "$WORKTREE_REAL" rev-parse --git-common-dir 2>/dev/null || true)
COMMON_REAL=$(cd "$WORKTREE_REAL" && cd "$COMMON" 2>/dev/null && pwd -P) || COMMON_REAL=
PROJECT_COMMON=$(git -C "$PROJECT_REAL" rev-parse --git-common-dir 2>/dev/null || true)
PROJECT_COMMON_REAL=$(cd "$PROJECT_REAL" && cd "$PROJECT_COMMON" 2>/dev/null && pwd -P) || PROJECT_COMMON_REAL=
[ -n "$PROJECT_COMMON_REAL" ] && [ "$COMMON_REAL" = "$PROJECT_COMMON_REAL" ] \
  || refuse "recorded worktree does not belong to the recorded project"
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || refuse "task record has no endpoint to inspect"
AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET")
case "$AGENT_STATE" in dead|missing) ;; *) refuse "recorded endpoint $TARGET is $AGENT_STATE" ;; esac

EXPECTED="fm-$ID"
fm_worktree_pool_lookup "$PROJECT_REAL" "$WORKTREE_REAL" || refuse "treehouse pool state is unreadable"
[ "$FM_WORKTREE_POOL_RESULT" = present ] || refuse "worktree is absent from the treehouse pool"
[ "$FM_WORKTREE_POOL_STATUS" = leased ] \
  || refuse "worktree has pool status $FM_WORKTREE_POOL_STATUS, not a durable $EXPECTED lease"
[ "$FM_WORKTREE_POOL_HOLDER" = "$EXPECTED" ] \
  || refuse "worktree is leased to ${FM_WORKTREE_POOL_HOLDER:-an unknown holder}, not $EXPECTED"
echo "verified: $WORKTREE_REAL is durably leased to $EXPECTED"
