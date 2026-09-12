#!/usr/bin/env bash
# Record one lane's size into the telemetry store at PR open.
# Usage: fm-lane-size-record.sh <task-id> <worktree> <base-ref> <pr-url>
#
# Joined to rounds and tokens by project and task id in the store, this is what
# turns "big diffs need more rounds" from an argument into a number.
#
# Exit is always 0: telemetry must never be able to fail a lane.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-diff-size-lib.sh
. "$SCRIPT_DIR/fm-diff-size-lib.sh"

[ $# -eq 4 ] || exit 0
TASK_ID=$1
WORKTREE=$2
BASE=$3
PR_URL=$4

DB="${TELEMETRY_DB:-${CLAUDE_HOME:-$HOME/.claude}/telemetry/usage.sqlite}"
[ -f "$DB" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# fm_diff_size fails open with "0 0" for a caller (the worker's own pre-run
# check) that must never block on a bad measurement. Telemetry has the
# opposite requirement: a "0 0" it cannot tell apart from a real zero-line
# lane would corrupt the size/rounds dataset, so an unresolved worktree or
# base ref is skipped here rather than measured and stored.
[ -d "$WORKTREE" ] || exit 0
RESOLVED_BASE=$(git -C "$WORKTREE" rev-parse --verify --quiet "$BASE" 2>/dev/null) || exit 0

read -r LINES FILES <<< "$(fm_diff_size "$WORKTREE" "$RESOLVED_BASE")"
HOST=$(uname -n | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
PROJECT=$(basename "$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null || echo "$WORKTREE")")
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

python3 - "$DB" "$HOST" "$PR_URL" "$PROJECT" "$TASK_ID" "$LINES" "$FILES" "$STAMP" <<'PY' 2>/dev/null || exit 0
import sqlite3, sys
db, host, pr, project, task, lines, files, stamp = sys.argv[1:9]
conn = sqlite3.connect(db)
conn.execute(
    "INSERT OR REPLACE INTO lanes (host, pr_url, project, task_id,"
    " changed_lines, files_changed, opened_at) VALUES (?,?,?,?,?,?,?)",
    (host, pr, project, task, int(lines), int(files), stamp))
conn.commit()
conn.close()
PY

echo "lane size: $LINES changed lines across $FILES files ($(fm_diff_size_verdict "$LINES"))"
exit 0
