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

REGISTER_LINE=$(printf '%s\n' "$BLOCK" | grep 'register-clone')
# shellcheck disable=SC2016  # single quotes are deliberate: this is a literal sed pattern, not meant to expand
REGISTER_CMD=$(printf '%s\n' "$REGISTER_LINE" | sed -n 's/.*`\([^`]*register-clone[^`]*\)`.*/\1/p')
if [ -z "$REGISTER_CMD" ]; then
  echo "FAIL - the block does not tell an out-of-worktree lane to register its clone"; FAIL=1
else
  REGISTER_SCRIPT=$(printf '%s\n' "$REGISTER_CMD" | awk '{print $1}')
  REGISTER_TASK_ID=$(printf '%s\n' "$REGISTER_CMD" | awk '{print $3}')
  REGISTER_OUT=$("$REGISTER_SCRIPT" register-clone "$REGISTER_TASK_ID" /nonexistent-fm-dod-wait-clone 2>&1) || true
  case "$REGISTER_OUT" in
    *"no task record for $REGISTER_TASK_ID"*)
      echo "ok - the register-clone command in the block resolves to the real watch script wired to this task id" ;;
    *)
      echo "FAIL - the register-clone command in the block does not resolve to working behavior: $REGISTER_OUT"; FAIL=1 ;;
  esac
fi

exit "$FAIL"
