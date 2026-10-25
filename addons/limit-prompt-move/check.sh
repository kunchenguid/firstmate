#!/usr/bin/env bash
# limit-prompt-move watcher check: starts one pass detached, since a relaunch outlasts a check's
# time limit. The pass reports each move in the moved task's own status line, which wakes the home.
# Usage: check.sh <fm-home>
set -u
setsid -f "$(cd "$(dirname "$0")" && pwd)/limit-prompt-move" "$1" >/dev/null 2>&1 </dev/null
