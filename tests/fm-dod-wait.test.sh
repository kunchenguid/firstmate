#!/usr/bin/env bash
# The no-mistakes Definition of done must not tell a worker to sleep.
set -u
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

BLOCK=$(fm_dod_block no-mistakes demo-task)

case "$BLOCK" in
  *"sleep 600"*) echo "FAIL - the block still prescribes a foreground sleep"; FAIL=1 ;;
  *) echo "ok - no foreground sleep prescribed" ;;
esac

case "$BLOCK" in
  *"END YOUR TURN"*) echo "ok - the worker is told to end its turn" ;;
  *) echo "FAIL - the block does not tell the worker to end its turn"; FAIL=1 ;;
esac

case "$BLOCK" in
  *"when-nm-state-demo-task"*) echo "ok - the block names this task's watch" ;;
  *) echo "FAIL - the block does not name the watch source"; FAIL=1 ;;
esac

case "$BLOCK" in
  *"paused: no-mistakes run in progress"*) echo "ok - the declared wait is unchanged" ;;
  *) echo "FAIL - the declared-wait line was lost"; FAIL=1 ;;
esac

case "$BLOCK" in
  *"Background that one call"*)
    echo "FAIL - the block still prescribes backgrounding a single drive call"
    FAIL=1
    ;;
  *) echo "ok - the block does not prescribe backgrounding a single drive call" ;;
esac

case "$BLOCK" in
  *"--wait"*"8m0s"*) echo "ok - the block names the bounded foreground hold and its default" ;;
  *) echo "FAIL - the block does not name --wait's bounded foreground hold"; FAIL=1 ;;
esac

exit "$FAIL"
