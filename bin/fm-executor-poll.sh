#!/usr/bin/env bash
# Static watcher program for a kind=executor task (the executor-dispatch skill).
# It prints exactly one line when firstmate should wake and nothing otherwise:
#   executor-ready: PR <url> <draft|ready>       process exited, pull request on fm/<id>
#   executor-failed: no commits and no PR (verify likely failed before commit)
#   executor-failed: committed but no PR
#   executor-stale: running <N>m past the bound   process alive past FM_EXECUTOR_MAX_RUNTIME
# A gh failure exits non-zero and silent rather than being read as "no PR", and
# the watcher's FM_CHECK_TIMEOUT bounds the whole read. bin/fm-executor-lib.sh
# owns the classification and its two structural inputs (the pane shell's exit
# marker and the live pull-request read), and bin/fm-watch.sh owns once-per-
# outcome delivery through the executor-notified marker.
# state/<id>.check.sh is a byte copy of this file; task data is the validated
# state/<id>.meta record, which the watcher shape-checks and passes here as
# arguments (fm_executor_poll_snapshot_capture), so these bytes are identical
# for every task and no task data is ever interpolated into shell source.
# Usage (watcher only): fm-executor-poll.sh --validated <state> <id> <spawn_gen> <worktree> <backend> <target> <base-commit> <launched-epoch>
set -u
LC_ALL=C
export LC_ALL

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ "$#" -eq 9 ] && [ "$1" = --validated ] || exit 0
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-executor-lib.sh
. "$SCRIPT_DIR/fm-executor-lib.sh"

verdict=$(fm_executor_classify "$@")
rc=$?
case "$rc" in
  0) fm_executor_poll_line "$verdict" || exit 0 ;;
  2) exit 1 ;;
  *) exit 0 ;;
esac
# rc 1 (nothing to classify) and rc 3 (liveness unreadable) are silence: neither
# is evidence of an outcome, and the next poll reads again.
exit 0
