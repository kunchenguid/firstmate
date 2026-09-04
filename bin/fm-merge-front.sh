#!/usr/bin/env bash
# Own the per-project structural merge-front queue and the only initial
# Greptile retrigger gate.
#
# Commands:
#   fm-merge-front.sh enqueue <project-key> <task-id> <pr-url>
#   fm-merge-front.sh status <project-key>
#   fm-merge-front.sh promote <project-key>
#   fm-merge-front.sh greptile-kick <project-key>
#
# Each project has exactly one ordered queue. Its first entry is the front and
# every later entry is parked. enqueue is idempotent for one exact task/URL pair
# and refuses a task or URL rebound to another pair. promote reuses the canonical
# merge poll to fail closed until the front is confirmed merged, then removes
# exactly that entry and exposes the next one. The shared already-confirmed
# merge-outcome path uses an identity-bound variant and refuses to remove an
# out-of-order merged entry.
#
# Durable private state lives at state/merge-front/<project-key>.queue under a
# mode-0700 directory. Each single-link mode-0600 file has this schema:
#   fm-merge-front-v1
#   project=<project-key>
#   task=<task-id><TAB>url=<canonical-pr-url>
#   ...
# The task rows are queue order. Writers hold the per-project lock, validate the
# complete old state, publish a complete same-device temporary by atomic rename,
# and validate the result. Project keys and task IDs are confined path-safe
# slugs; PR/MR URLs use bin/fm-pr-lib.sh's canonical parser. PR registration
# derives the project key from the basename of the task metadata's project= path.
#
# status reports one front= row plus zero or more parked= rows. It never grants
# authority by itself: only the front may be updated from main or retriggered.
# greptile-kick holds the project lock through its live GitHub reads and comment.
# It refuses unless the queued PR is the first entry (therefore has no preceding
# entry), is open against main, has behind_by=0 compared with main, has every
# non-Greptile required check at SUCCESS, and has no pending Greptile check. Any
# unreadable or unrecognised state fails closed. Its sole action is one explicit
# `gh pr comment <number> --repo <owner/repo> --body "@greptile review"`.
# Greploop's separate follow-up trigger remains unchanged: a finished Greptile
# review below 5/5 may ask this owner to attempt another gated kick.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-merge-front-lib.sh
. "$SCRIPT_DIR/fm-merge-front-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  enqueue)
    [ "$#" -eq 4 ] || { echo 'error: invalid merge-front enqueue request' >&2; exit 2; }
    fm_merge_front_enqueue "$STATE" "$2" "$3" "$4" || exit $?
    ;;
  status)
    [ "$#" -eq 2 ] || { echo 'error: invalid merge-front status request' >&2; exit 2; }
    fm_merge_front_status "$STATE" "$2" || exit $?
    ;;
  promote)
    [ "$#" -eq 2 ] || { echo 'error: invalid merge-front promote request' >&2; exit 2; }
    fm_merge_front_promote "$STATE" "$2" || exit $?
    ;;
  greptile-kick)
    [ "$#" -eq 2 ] || { echo 'error: invalid merge-front Greptile request' >&2; exit 2; }
    fm_merge_front_greptile_kick "$STATE" "$2" || exit $?
    ;;
  *)
    echo 'error: expected enqueue, status, promote, or greptile-kick' >&2
    exit 2
    ;;
esac
