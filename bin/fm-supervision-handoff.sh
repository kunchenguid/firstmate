#!/usr/bin/env bash
# fm-supervision-handoff.sh <token> <predecessor-arm-pid>
# Private Claude host hand-back owner, enabled by config/supervision-handoff-ack.
# The host queues check: supervision-handoff:<token> and starts this detached
# child before returning its close. Only main's sequence-bound wake-drain ack
# removes .supervision-handoff-pending. Until then this owner replaces each
# closed one-shot arm and retries a record-backed watcher doorbell every 300s
# (FM_SUPERVISION_HANDOFF_RETRY_SECONDS). A retry never consumes queued work.
# .supervision-handoff-owner records this process's pid and identity. The next
# host stops it before taking over the arm recorded in .supervision-host-left.
# Ack and TERM both leave that verified arm for the next park, not a second arm.
#
# Automatic delivery is restricted to the inherited tmux pane on Claude. Its
# pane pid must be an ancestor of the pinned session-lock pid, that session
# must still be in the terminal's foreground group, and its composer must be
# empty with no busy signature. All other endpoints retain the queued wake
# and keep watching but need a normal turn or human message to resume main.
# No terminal text proves acknowledgement. Busy, unknown, or pending input is
# never overwritten. The existing backend submit primitive owns Enter retries.
# Removing the opt-in, losing the pinned session, or entering daemon-backed
# away mode stops retries and leaves the current arm for its next owner.
set -u
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_backend_source tmux || exit 1
TOKEN=${1:-}
PREDECESSOR=${2:-}
case "$TOKEN" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "$PREDECESSOR" in ''|*[!0-9]*) exit 2 ;; esac
PENDING="$STATE/.supervision-handoff-pending"
OWNER="$STATE/.supervision-handoff-owner"
LEFT="$STATE/.supervision-host-left"
LOG="$STATE/.supervision-handoff.log"
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
RETRY=${FM_SUPERVISION_HANDOFF_RETRY_SECONDS:-300}
case "$RETRY" in ''|0*|*[!0-9]*) RETRY=300 ;; esac
fm_session_lock_owned_by_self "$STATE" || exit 1
[ "$(cat "$PENDING" 2>/dev/null)" = "$TOKEN" ] || exit 1
SESSION=$(cat "$STATE/.lock" 2>/dev/null) || exit 1
SESSION_ID=$(fm_pid_identity "$SESSION") || exit 1
[ -n "$SESSION_ID" ] || exit 1
ARM=
OUT=
ARM_RECORDED=0
READY_PRINTED=0
IDENTITY=$(fm_pid_identity "$$") || exit 1
tmp=$(mktemp "$OWNER.XXXXXX") || exit 1
printf '%s\t%s\n' "$$" "$IDENTITY" > "$tmp" && mv -f "$tmp" "$OWNER" || exit 1

# shellcheck disable=SC2329 # EXIT trap.
cleanup() {
  if [ -n "$ARM" ]; then
    if [ "$ARM_RECORDED" -eq 1 ]; then
      disown "$ARM" 2>/dev/null || true
    else
      kill -TERM "$ARM" 2>/dev/null || true
      wait "$ARM" 2>/dev/null || true
    fi
  fi
  [ -z "$OUT" ] || rm -f "$OUT"
  [ "$(cut -f1 "$OWNER" 2>/dev/null)" != "$$" ] || rm -f "$OWNER"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

session_owned() {
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$SESSION" ] \
    && fm_pid_alive "$SESSION" \
    && [ "$(fm_pid_identity "$SESSION" 2>/dev/null)" = "$SESSION_ID" ]
}

retry_delivery() {
  local pane_pid ancestor message verdict=deferred tmp pgid tpgid
  # No fallback target: a guessed pane can belong to another home.
  if [ -n "${TMUX_PANE:-}" ] && session_owned; then
    pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null) || pane_pid=
    ancestor=$SESSION
    case "$pane_pid" in ''|*[!0-9]*) ancestor= ;; esac
    while [ -n "$ancestor" ] && [ "$ancestor" != 1 ] && [ "$ancestor" != "$pane_pid" ]; do
      ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
    done
    read -r pgid tpgid < <(ps -o pgid=,tpgid= -p "$SESSION" 2>/dev/null) || pgid=
    if [ -n "$ancestor" ] && [ "$ancestor" = "$pane_pid" ] \
      && [ -n "$pgid" ] && [ "$pgid" = "$tpgid" ] && [ "$pgid" -gt 0 ] 2>/dev/null \
      && fm_harness_pid_alive "$SESSION" \
      && [ "$(fm_pane_busy_state "$TMUX_PANE" claude 2>/dev/null)" = idle ] \
      && [ "$(fm_backend_composer_state tmux "$TMUX_PANE" 2>/dev/null)" = empty ] \
      && session_owned && [ "$(cat "$PENDING" 2>/dev/null)" = "$TOKEN" ]; then
      if fm_operational_record_write "$STATE" watcher \
        'check: supervision-handoff - the host hand-back is still unacknowledged. Run bin/fm-wake-drain.sh, handle its queued work, and run its exact WAKE_ACK_REQUIRED command. This is automatic supervision, not a captain return.' message; then
        verdict=$(fm_backend_send_text_submit tmux "$TMUX_PANE" "$message" 2 0.2 0.2 2>/dev/null) || verdict=unconfirmed
      fi
    fi
  fi
  printf '%s\tretry\t%s\t%s\n' "$(date +%s)" "$TOKEN" "$verdict" >> "$LOG"
  if [ "$(wc -l < "$LOG")" -gt 200 ]; then
    tmp=$(mktemp "$LOG.XXXXXX") || return 0
    tail -100 "$LOG" > "$tmp" && mv -f "$tmp" "$LOG"
  fi
}

NEXT_RETRY=$((SECONDS + RETRY))
while session_owned && [ -e "$CONFIG/supervision-handoff-ack" ] && [ ! -e "$STATE/.afk" ]; do
  OUT=$(mktemp "$STATE/.supervision-handoff-arm.XXXXXX") || exit 1
  # The arm must survive both this owner and the original hook's process group.
  set -m
  FM_WATCH_PREDECESSOR_ARM_PID="$PREDECESSOR" nohup "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 </dev/null &
  ARM=$!
  ARM_RECORDED=0
  set +m
  deadline=$((SECONDS + ${FM_SUPERVISION_HOST_READY_TIMEOUT:-25}))
  while ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" \
    || ! grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$OUT"; do
    if ! fm_pid_alive "$ARM" || [ "$SECONDS" -ge "$deadline" ]; then
      kill -TERM "$ARM" 2>/dev/null || true
      wait "$ARM" 2>/dev/null || true
      exit 1
    fi
    sleep 0.2
  done
  identity=$(fm_pid_identity "$ARM") || exit 1
  tmp=$(mktemp "$LEFT.XXXXXX") || exit 1
  printf '%s\t%s\n' "$ARM" "$identity" > "$tmp" && mv -f "$tmp" "$LEFT" || exit 1
  [ -f "$LEFT" ] && [ ! -L "$LEFT" ] \
    && [ "$(cat "$LEFT")" = "$ARM"$'\t'"$identity" ] || exit 1
  ARM_RECORDED=1
  if [ "$READY_PRINTED" -eq 0 ]; then
    grep -E -m1 '^watcher: (started|attached) pid=[0-9]+' "$OUT"
    READY_PRINTED=1
  fi
  while fm_pid_alive "$ARM"; do
    [ "$(cat "$PENDING" 2>/dev/null)" = "$TOKEN" ] || exit 0
    session_owned && [ -e "$CONFIG/supervision-handoff-ack" ] && [ ! -e "$STATE/.afk" ] || exit 0
    if [ "$SECONDS" -ge "$NEXT_RETRY" ]; then
      retry_delivery
      NEXT_RETRY=$((SECONDS + RETRY))
    fi
    sleep 1
  done
  wait "$ARM" 2>/dev/null || true
  PREDECESSOR=$ARM
  ARM=
  rm -f "$OUT"
  OUT=
done
