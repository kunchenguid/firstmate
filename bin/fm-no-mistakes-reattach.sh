#!/usr/bin/env bash
# fm-no-mistakes-reattach.sh - retry one task's existing AXI run without
# deliberately requesting no-mistakes daemon lifecycle changes.
#
# Usage:
#   FM_HOME=<firstmate-home> bin/fm-no-mistakes-reattach.sh <task-id>
#
# The helper is deliberately reattach-only: it invokes `no-mistakes axi run`
# without --intent, so no-mistakes refuses when there is no active run matching
# the task worktree's branch and HEAD.
# It retries only the observed transient reconciliation signature:
#   drive run: reconcile run ...: read response: ... socket: i/o timeout
# Other failures return immediately.
# Before every attempt it uses the read-only AXI home view to require a running
# daemon. Ordinary `axi run` calls EnsureDaemon after that preflight, leaving a
# check-to-use race in which a daemon that stops between the two calls may be
# started. A strict no-start guarantee requires an upstream attach-only mode.
# Task metadata, canonical worktree, and branch identity are resolved from the
# selected FM_HOME, which confines the remedy to that home's recorded lane.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:-}
if [ -z "$ID" ] || [ "$#" -ne 1 ]; then
  echo "usage: fm-no-mistakes-reattach.sh <task-id>" >&2
  exit 2
fi
case "$ID" in
  *[!A-Za-z0-9._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac

MAX_ATTEMPTS=${FM_NM_REATTACH_MAX_ATTEMPTS:-5}
BACKOFF_BASE=${FM_NM_REATTACH_BACKOFF_BASE:-2}
BACKOFF_CAP=${FM_NM_REATTACH_BACKOFF_CAP:-30}
case "$MAX_ATTEMPTS" in ''|*[!0-9]*|0) echo "error: FM_NM_REATTACH_MAX_ATTEMPTS must be a positive integer" >&2; exit 2 ;; esac
case "$BACKOFF_BASE" in ''|*[!0-9]*) echo "error: FM_NM_REATTACH_BACKOFF_BASE must be a non-negative integer" >&2; exit 2 ;; esac
case "$BACKOFF_CAP" in ''|*[!0-9]*) echo "error: FM_NM_REATTACH_BACKOFF_CAP must be a non-negative integer" >&2; exit 2 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task metadata for $ID in this firstmate home" >&2; exit 1; }

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
MODE=$(meta_value mode)
[ "$KIND" = ship ] || { echo "error: task $ID is not a ship lane" >&2; exit 1; }
[ "$MODE" = no-mistakes ] || { echo "error: task $ID is not in no-mistakes mode" >&2; exit 1; }
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: recorded worktree is unavailable for $ID" >&2; exit 1; }

WT_REAL=$(cd "$WT" 2>/dev/null && pwd -P) || WT_REAL=
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$WT_REAL" ] || [ "$WT_TOP" != "$WT_REAL" ]; then
  echo "error: recorded worktree for $ID is not its canonical Git top-level" >&2
  exit 1
fi

EXPECTED_REF=$(meta_value worktree_git_ref)
[ -n "$EXPECTED_REF" ] || EXPECTED_REF="refs/heads/fm/$ID"
CURRENT_REF=$(git -C "$WT" symbolic-ref --quiet HEAD 2>/dev/null || true)
if [ "$CURRENT_REF" != "$EXPECTED_REF" ]; then
  echo "error: task $ID worktree changed branch identity (expected $EXPECTED_REF, found ${CURRENT_REF:-detached})" >&2
  exit 1
fi

command -v no-mistakes >/dev/null 2>&1 || { echo "error: no-mistakes command not found" >&2; exit 1; }

transient_reconcile_timeout() {  # <axi-output>
  local output=$1
  printf '%s\n' "$output" | grep -q 'drive run:' || return 1
  printf '%s\n' "$output" | grep -q 'reconcile run ' || return 1
  printf '%s\n' "$output" | grep -q 'read response:' || return 1
  printf '%s\n' "$output" | grep -q 'socket: i/o timeout'
}

daemon_state() {  # <axi-home-output>
  local state
  state=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*daemon:[[:space:]]*//p' | head -1)
  case "$state" in
    \"*\") state=${state#\"}; state=${state%\"} ;;
  esac
  printf '%s' "$state"
}

retry_delay() {  # <failed-attempt>
  local failed_attempt=$1 delay=$BACKOFF_BASE n=1 jitter
  while [ "$n" -lt "$failed_attempt" ] && [ "$delay" -lt "$BACKOFF_CAP" ]; do
    delay=$((delay * 2))
    n=$((n + 1))
  done
  [ "$delay" -le "$BACKOFF_CAP" ] || delay=$BACKOFF_CAP
  if [ "$delay" -gt 0 ]; then
    jitter=$((${#ID} % (delay + 1)))
    delay=$((delay + jitter))
    [ "$delay" -le "$BACKOFF_CAP" ] || delay=$BACKOFF_CAP
  fi
  printf '%s' "$delay"
}

attempt=1
last_output=
last_rc=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  home_output=$(cd "$WT" && no-mistakes axi 2>/dev/null) || {
    echo "error: could not read no-mistakes AXI home state; refusing reattach" >&2
    exit 1
  }
  daemon=$(daemon_state "$home_output")
  if [ "$daemon" != running ]; then
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      echo "error: no-mistakes daemon is not reporting running; refusing to start or restart the shared daemon" >&2
      exit 1
    fi
    delay=$(retry_delay "$attempt")
    echo "reattach preflight $attempt/$MAX_ATTEMPTS: daemon is not reporting running; rechecking in ${delay}s without lifecycle changes" >&2
    [ "$delay" -eq 0 ] || sleep "$delay"
    attempt=$((attempt + 1))
    continue
  fi

  last_output=$(cd "$WT" && no-mistakes axi run 2>&1)
  last_rc=$?
  if [ "$last_rc" -eq 0 ]; then
    printf '%s\n' "$last_output"
    exit 0
  fi
  if ! transient_reconcile_timeout "$last_output"; then
    printf '%s\n' "$last_output"
    exit "$last_rc"
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    printf '%s\n' "$last_output"
    echo "error: reattach exhausted $MAX_ATTEMPTS transient reconciliation attempts; preflight cannot guarantee no daemon start because axi run calls EnsureDaemon" >&2
    exit "$last_rc"
  fi
  delay=$(retry_delay "$attempt")
  echo "reattach attempt $attempt/$MAX_ATTEMPTS hit a transient socket read timeout; retrying in ${delay}s after read-only daemon preflight (strict no-start guarantee unavailable)" >&2
  [ "$delay" -eq 0 ] || sleep "$delay"
  attempt=$((attempt + 1))
done

printf '%s\n' "$last_output"
exit "$last_rc"
