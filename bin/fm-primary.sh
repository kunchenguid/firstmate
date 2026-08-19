#!/usr/bin/env bash
# Launch a Claude Firstmate primary with automatic reset-safe context handoffs.
# Usage:
#   fm-primary.sh [--firstmate-initial-prompt <text>] [--] [claude-options...]
#
# The first launch receives the optional Firstmate-owned initial prompt plus all
# forwarded Claude options. A context handoff restarts a fresh conversation with
# the same options and one typed resume prompt, but never replays the original
# initial prompt. Resume-bearing Claude options are refused because they would
# restore the context this wrapper is responsible for discarding.
#
# Claude normally exits straight through with its original status. It restarts
# only after the child has exited and state/.context-restart-crossing carries a
# reset-safe ready sentinel with this generation's private token. The wrapper
# then serializes against session-lock acquisition, removes only that exact dead
# harness owner's lock, retires the sentinel, and launches the successor in the
# same terminal. An accidental exit without the sentinel never becomes a loop.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.context-restart-crossing"
SESSION_LOCK="$STATE/.lock"
SESSION_CLAIM="$STATE/.lock.acquire"
CLAUDE_BIN=${FM_CLAUDE_BIN:-}
INITIAL_PROMPT=
CLAUDE_ARGS=()
SUCCESSOR_BODY='A reset-safe context handoff completed. The native SessionStart hook has already run the full digest before this turn. Read that digest as startup and recovery input, reconcile it under AGENTS.md, resume work already under way, then wait silently if no action remains.'

# shellcheck source=bin/fm-context-restart-lib.sh
. "$SCRIPT_DIR/fm-context-restart-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,3{s/^# \{0,1\}//;p;}' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firstmate-initial-prompt)
      [ "$#" -ge 2 ] && [ -z "$INITIAL_PROMPT" ] || { usage >&2; exit 2; }
      INITIAL_PROMPT=$2
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        CLAUDE_ARGS+=("$1")
        shift
      done
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      CLAUDE_ARGS+=("$1")
      shift
      ;;
  esac
done

for arg in "${CLAUDE_ARGS[@]}"; do
  case "$arg" in
    -c|--continue|-r|--resume|--resume=*|--session-id|--session-id=*|\
    --fork-session|--from-pr|--from-pr=*|--teleport|--teleport=*)
      echo "fm-primary: '$arg' would restore prior conversation context; launch it outside this fresh-session wrapper" >&2
      exit 2
      ;;
  esac
done

if [ -z "$CLAUDE_BIN" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
fi
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || {
  echo "fm-primary: claude executable not found" >&2
  exit 127
}

if [ -L "$STATE" ]; then
  echo "fm-primary: state directory is symlinked" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  mkdir -p "$STATE" 2>/dev/null || {
    echo "fm-primary: could not create state directory $STATE" >&2
    exit 1
  }
fi

new_token() {
  local token
  token=$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || token=
  case "$token" in
    ????????????????????????????????*) printf '%s\n' "$token" ;;
    *) return 1 ;;
  esac
}

FIRST=1
while :; do
  TOKEN=$(new_token) || {
    echo "fm-primary: could not create a private handoff token" >&2
    exit 1
  }
  RC=0
  if [ "$FIRST" -eq 1 ]; then
    if [ -n "$INITIAL_PROMPT" ]; then
      FM_CONTEXT_RESTART_WRAPPER_TOKEN="$TOKEN" \
        "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" "$INITIAL_PROMPT" || RC=$?
    else
      FM_CONTEXT_RESTART_WRAPPER_TOKEN="$TOKEN" \
        "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" || RC=$?
    fi
  else
    SUCCESSOR_PROMPT=$(printf '%s' "$SUCCESSOR_BODY" \
      | "$SCRIPT_DIR/fm-operational-input.sh" encode session-start) || {
        echo "fm-primary: could not construct the successor resume prompt" >&2
        exit 1
      }
    FM_CONTEXT_RESTART_WRAPPER_TOKEN="$TOKEN" \
      "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" "$SUCCESSOR_PROMPT" || RC=$?
  fi
  FIRST=0

  if ! fm_context_restart_record_read "$RECORD" >/dev/null 2>&1 \
    || [ "$FM_CONTEXT_RESTART_RECORD_PHASE" != ready ] \
    || [ "$FM_CONTEXT_RESTART_RECORD_MODE" != automatic ] \
    || [ "$FM_CONTEXT_RESTART_RECORD_TOKEN" != "$TOKEN" ]; then
    exit "$RC"
  fi

  OLD_PID=$FM_CONTEXT_RESTART_RECORD_LOCK_PID
  if fm_harness_pid_alive "$OLD_PID"; then
    echo "fm-primary: prepared Claude session still owns the home; refusing an overlapping successor" >&2
    exit 1
  fi

  fm_lock_acquire_wait "$SESSION_CLAIM"
  SESSION_CLAIM_HELD=1
  release_session_claim() {
    if [ "${SESSION_CLAIM_HELD:-0}" -eq 1 ]; then
      fm_lock_release "$SESSION_CLAIM"
      SESSION_CLAIM_HELD=0
    fi
  }
  trap release_session_claim EXIT HUP INT TERM

  CURRENT_PID=$(cat "$SESSION_LOCK" 2>/dev/null || true)
  if [ ! -f "$SESSION_LOCK" ] || [ -L "$SESSION_LOCK" ] \
    || [ "$CURRENT_PID" != "$OLD_PID" ] || fm_harness_pid_alive "$OLD_PID"; then
    release_session_claim
    trap - EXIT HUP INT TERM
    echo "fm-primary: session-lock ownership changed before restart; refusing an overlapping successor" >&2
    exit 1
  fi
  if ! rm -f "$SESSION_LOCK" 2>/dev/null; then
    release_session_claim
    trap - EXIT HUP INT TERM
    echo "fm-primary: could not release the exited session's lock" >&2
    exit 1
  fi
  if ! rm -f "$RECORD" 2>/dev/null; then
    release_session_claim
    trap - EXIT HUP INT TERM
    echo "fm-primary: could not retire the completed handoff sentinel" >&2
    exit 1
  fi
  release_session_claim
  trap - EXIT HUP INT TERM

  echo "Firstmate context handoff complete; starting a fresh Claude session." >&2
done
