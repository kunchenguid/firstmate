#!/usr/bin/env bash
# Wrap a long-running command so its completion wakes the invoking worker.
# Usage: FM_HOME=<home> fm-babysit.sh [--fm-home <home>] [--timeout <seconds>] [--tail <lines>] [--log <path>] <task-id> -- <command> [<args>...]
# The command runs in the foreground of the invoking pane, so the pane stays honestly busy while it runs.
# Its stdout and stderr are captured to a log file: a fresh file under the TMPDIR scratch area by default, or a caller-chosen path under --log.
# The default log template keeps the mktemp Xs at the end so it works with both GNU and BSD mktemp.
# The log path is printed at start.
# When the command finishes, is killed, or hits --timeout, exactly one durable steering message is appended through fm-send.sh to <task-id>.
# That message reports the command, the completion status (completed, failed, signaled, timed-out, or interrupted), the exit code, the elapsed time, the log path, and the last --tail lines of the log (default 50, byte-capped).
# The inbox doorbell owned by bin/fm-task-inbox-lib.sh then wakes the worker.
# The send is best-effort with one exact retry: when both attempts fail, one fallback line is printed to the pane and nothing else is written, so a lost notification stays observable instead of silently dropped.
# The send home comes from --fm-home first and FM_HOME second; an absent or non-directory home is refused loudly before anything runs.
# The send binary defaults to the fm-send.sh beside this script and must be executable; FM_BABYSIT_SEND overrides it (a test hook).
# The child runs in its own process group, via setsid where available and via job-control monitor mode otherwise (FM_BABYSIT_NO_SETSID forces the fallback; a test hook).
# Group signals therefore never touch the caller's group.
# --timeout arms a timer that raises ALRM in this shell; ALRM and external TERM/INT all drive one bounded termination primitive: TERM the owned group, wait a bounded grace, KILL whatever owned members remain, then reap the leader and send the completion message.
# The KILL phase targets the recorded group whenever it still has members, independent of whether the leader is still alive, so a TERM-resistant descendant can never be orphaned by a dead leader or a cancelled grace.
# FM_BABYSIT_KILL_GRACE bounds the TERM-to-KILL grace in seconds (default 5, also a test hook).
# On timeout the wrapper exits 124; otherwise it exits with the child's own exit code, so exit 0 always follows a completed send attempt, never a skipped one.
# Only the log path, bounded /tmp scratch files, and the inbox record fm-send.sh owns are ever written; nothing is ever removed recursively.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

err() {
  local code=$1
  shift
  printf 'fm-babysit: error: %s\n' "$*" >&2
  exit "$code"
}

fm_format_elapsed() {
  local s=$1
  if [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm%02ds' "$((s / 60))" "$((s % 60))"
  else
    printf '%sh%02dm%02ds' "$((s / 3600))" "$(((s % 3600) / 60))" "$((s % 60))"
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_HOME_FLAG=""
TIMEOUT=""
TAIL_N=50
LOG_GIVEN=""
TASK_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --fm-home|--timeout|--tail|--log)
      [ $# -ge 2 ] || err 2 "--$1 requires a value"
      case "$1" in
        --fm-home) FM_HOME_FLAG=$2 ;;
        --timeout) TIMEOUT=$2 ;;
        --tail) TAIL_N=$2 ;;
        --log) LOG_GIVEN=$2 ;;
      esac
      shift 2
      ;;
    --fm-home=*) FM_HOME_FLAG=${1#--fm-home=} ; shift ;;
    --timeout=*) TIMEOUT=${1#--timeout=} ; shift ;;
    --tail=*) TAIL_N=${1#--tail=} ; shift ;;
    --log=*) LOG_GIVEN=${1#--log=} ; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) err 2 "unknown flag: $1" ;;
    *) break ;;
  esac
done

TASK_ID=${1:-}
[ -n "$TASK_ID" ] || err 2 "missing <task-id>"
case "$TASK_ID" in
  -*) err 2 "invalid <task-id>" ;;
esac
shift
[ "${1:-}" = "--" ] || err 2 "expected '--' after <task-id>"
shift
[ $# -gt 0 ] || err 2 "missing <command> after '--'"

case "$TIMEOUT" in
  '') ;;
  *[!0-9]*|0) err 2 "--timeout must be a positive integer number of seconds" ;;
esac
case "$TAIL_N" in
  *[!0-9]*|0) err 2 "--tail must be a positive integer number of lines" ;;
esac
case "$LOG_GIVEN" in
  -*) err 2 "--log must not start with '-'" ;;
esac

SEND_HOME=${FM_HOME_FLAG:-${FM_HOME:-}}
[ -n "$SEND_HOME" ] || err 1 "no send home: pass --fm-home <home> or set FM_HOME"
[ -d "$SEND_HOME" ] || err 1 "send home is not a directory: $SEND_HOME"

SEND_BIN=${FM_BABYSIT_SEND:-$SCRIPT_DIR/fm-send.sh}
[ -x "$SEND_BIN" ] || err 1 "send binary is not executable: $SEND_BIN"

KILL_GRACE=${FM_BABYSIT_KILL_GRACE:-5}
case "$KILL_GRACE" in
  *[!0-9]*) err 2 "FM_BABYSIT_KILL_GRACE must be a non-negative integer" ;;
esac

if [ -n "$LOG_GIVEN" ]; then
  LOG=$LOG_GIVEN
  : > "$LOG" || err 1 "cannot write log file: $LOG"
else
  LOG=$(mktemp "${TMPDIR:-/tmp}/fm-babysit-$TASK_ID.log.XXXXXX") || err 1 "cannot create scratch log file"
fi

CMD_TEXT=""
for cmd_arg in "$@"; do
  CMD_TEXT="${CMD_TEXT:+$CMD_TEXT }$cmd_arg"
done

printf "fm-babysit: running '%s' for task %s; log: %s\n" "$CMD_TEXT" "$TASK_ID" "$LOG"

START_EPOCH=$(date +%s)

CHILD=""
PGID=""
GROUPED=0
WATCHDOG=""
INTERRUPTED=""
TIMEOUT_FIRED=0
REAPED=0
CODE=0
TRAPPED=0

# shellcheck disable=SC2329 # Invoked indirectly by the termination primitive and the signal traps below.
babysit_owned_has_members() {
  [ "$GROUPED" -eq 1 ] && [ -n "$PGID" ] && kill -0 "-$PGID" 2>/dev/null
}

# shellcheck disable=SC2329 # Invoked indirectly by the termination primitive and the signal traps below.
babysit_signal_owned() {
  local sig=$1
  if [ "$GROUPED" -eq 1 ] && [ -n "$PGID" ]; then
    kill "-$sig" "-$PGID" 2>/dev/null || {
      kill -0 "$CHILD" 2>/dev/null && kill "-$sig" "$CHILD" 2>/dev/null || true
    }
  elif [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
    kill "-$sig" "$CHILD" 2>/dev/null || true
  fi
}

# The single bounded termination primitive: TERM the owned target, wait out
# the grace while owned members remain, then KILL whatever members remain.
# Reaping stays with the main wait loop, so the completion message always
# follows the final reap and no single signal can leave the wrapper waiting.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
babysit_terminate() {
  local waited=0 tenths
  tenths=$((KILL_GRACE * 10))
  babysit_signal_owned TERM
  while babysit_owned_has_members && [ "$waited" -lt "$tenths" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if babysit_owned_has_members; then
    babysit_signal_owned KILL
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the main wait loop below.
babysit_wait_leader() {
  local rc
  [ "$REAPED" -eq 1 ] && return 0
  wait "$CHILD" 2>/dev/null
  rc=$?
  if [ "$REAPED" -eq 0 ]; then
    CODE=$rc
    REAPED=1
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the ALRM trap below.
babysit_on_alarm() {
  [ "$REAPED" -eq 1 ] && return 0
  TIMEOUT_FIRED=1
  babysit_terminate
}

# shellcheck disable=SC2329 # Invoked indirectly by the TERM/INT traps below.
babysit_on_interrupt() {
  [ "$REAPED" -eq 1 ] && return 0
  TRAPPED=$((TRAPPED + 1))
  if [ "$TRAPPED" -gt 1 ]; then
    babysit_signal_owned KILL
  else
    INTERRUPTED=$1
    babysit_terminate
  fi
}

if [ -z "${FM_BABYSIT_NO_SETSID:-}" ] && command -v setsid >/dev/null 2>&1; then
  setsid "$@" >>"$LOG" 2>&1 &
  CHILD=$!
  PGID=$CHILD
  GROUPED=1
else
  set -m
  "$@" >>"$LOG" 2>&1 &
  CHILD=$!
  PGID=$CHILD
  GROUPED=1
fi

trap 'babysit_on_alarm' ALRM
trap 'babysit_on_interrupt TERM' TERM
trap 'babysit_on_interrupt INT' INT

if [ -n "$TIMEOUT" ]; then
  (
    sleep "$TIMEOUT"
    kill -ALRM "$$" 2>/dev/null || true
  ) &
  WATCHDOG=$!
fi

while :; do
  babysit_wait_leader
  kill -0 "$CHILD" 2>/dev/null || break
done

if [ -n "$WATCHDOG" ]; then
  kill "$WATCHDOG" 2>/dev/null || true
  wait "$WATCHDOG" 2>/dev/null || true
fi

if { [ "$TIMEOUT_FIRED" -eq 1 ] || [ -n "$INTERRUPTED" ]; } && babysit_owned_has_members; then
  babysit_signal_owned KILL
  waited=0
  tenths=$((KILL_GRACE * 10))
  while babysit_owned_has_members && [ "$waited" -lt "$tenths" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
fi

END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
[ "$ELAPSED" -ge 0 ] || ELAPSED=0
ELAPSED_TEXT=$(fm_format_elapsed "$ELAPSED")

EXIT_CODE=0
if [ "$TIMEOUT_FIRED" -eq 1 ] && [ "$CODE" -ne 0 ]; then
  STATUS="timed out after ${TIMEOUT}s; child killed"
  EXIT_CODE=124
elif [ -n "$INTERRUPTED" ]; then
  STATUS="interrupted by SIG${INTERRUPTED}; child killed"
  case "$INTERRUPTED" in
    TERM) EXIT_CODE=143 ;;
    INT) EXIT_CODE=130 ;;
    *) EXIT_CODE=$CODE ;;
  esac
elif [ "$CODE" -eq 0 ]; then
  STATUS="completed ok"
  EXIT_CODE=0
elif [ "$CODE" -gt 128 ]; then
  SIG_NUM=$((CODE - 128))
  SIG_NAME=$(kill -l "$SIG_NUM" 2>/dev/null || printf '%s' "$SIG_NUM")
  STATUS="killed by signal $SIG_NAME"
  EXIT_CODE=$CODE
else
  STATUS="failed"
  EXIT_CODE=$CODE
fi

TAIL_TEXT=$(tail -n "$TAIL_N" "$LOG" 2>/dev/null | tail -c 8000 || true)

MSG=$(printf "fm-babysit: '%s' %s (exit %s, elapsed %s, log %s)\n--- last %s lines of the log ---\n%s" \
  "$CMD_TEXT" "$STATUS" "$EXIT_CODE" "$ELAPSED_TEXT" "$LOG" "$TAIL_N" "$TAIL_TEXT")

SEND_OK=0
if FM_HOME="$SEND_HOME" "$SEND_BIN" "$TASK_ID" "$MSG" >/dev/null 2>&1; then
  SEND_OK=1
else
  sleep 2
  if FM_HOME="$SEND_HOME" "$SEND_BIN" "$TASK_ID" "$MSG" >/dev/null 2>&1; then
    SEND_OK=1
  fi
fi

if [ "$SEND_OK" -eq 1 ]; then
  printf 'fm-babysit: notified task %s: %s (exit %s, elapsed %s, log %s)\n' \
    "$TASK_ID" "$STATUS" "$EXIT_CODE" "$ELAPSED_TEXT" "$LOG"
else
  printf "fm-babysit: FAILED to notify task %s (send failed twice); '%s' %s (exit %s, elapsed %s, log %s)\n" \
    "$TASK_ID" "$CMD_TEXT" "$STATUS" "$EXIT_CODE" "$ELAPSED_TEXT" "$LOG"
fi

exit "$EXIT_CODE"
