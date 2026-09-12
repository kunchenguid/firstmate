#!/usr/bin/env bash
# fm-continuous-supervision.sh - per-home attended supervision lifecycle.
#
# Usage: fm-continuous-supervision.sh enable|ensure|disable|status
#
# A regular file at config/continuous-supervision is the explicit opt-in.
# `ensure` is idempotent and is also called by mutable local bootstrap. It
# keeps one daemon in a dedicated detached tmux session, retargeting it when a
# relaunched Firstmate session has a different pane. The daemon continues to
# use the existing singleton lock, durable wake queue, composer guard, retry,
# and escalation machinery. `disable` removes only this opt-in and its exact
# recorded daemon terminal; it never touches task records or worktrees.
set -u

DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$DIR/.." && pwd)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
FLAG=$CONFIG/continuous-supervision
RECORD=$STATE/.continuous-supervision-terminal
LOCK=$STATE/.continuous-supervision-launch.lock
DAEMON=${FM_CONTINUOUS_DAEMON:-$DIR/fm-supervise-daemon.sh}

# shellcheck source=bin/fm-wake-lib.sh
. "$DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$DIR/fm-supervisor-target-lib.sh"

log() { printf 'continuous-supervision: %s\n' "$*" >&2; }

lock_acquire() {
  local i=0
  mkdir -p "$STATE" || return 1
  while [ "$i" -lt 50 ]; do
    i=$((i + 1))
    fm_lock_try_acquire "$LOCK" && return 0
    sleep 0.1
  done
  log "another lifecycle operation holds $LOCK"
  return 1
}

valid_record_field() {
  case "$1" in
    ''|*[!A-Za-z0-9_.:%+-]*) return 1 ;;
  esac
}

record_read() {
  REC_SESSION=''
  REC_TARGET=''
  [ -f "$RECORD" ] || return 1
  IFS=$(printf '\t') read -r REC_SESSION REC_TARGET < "$RECORD" || return 2
  valid_record_field "$REC_SESSION" && valid_record_field "$REC_TARGET" || return 2
}

session_alive() { tmux has-session -t "$1" 2>/dev/null; }

stop_recorded() {
  local rc
  record_read
  rc=$?
  [ "$rc" -ne 2 ] || { log "malformed terminal record; refusing to guess"; return 1; }
  [ "$rc" -eq 0 ] || return 0
  tmux kill-session -t "$REC_SESSION" 2>/dev/null || true
  if session_alive "$REC_SESSION"; then
    log "recorded daemon session $REC_SESSION is still alive"
    return 1
  fi
  rm -f "$RECORD"
}

wait_ready() {
  local i=0
  while [ "$i" -lt 100 ]; do
    i=$((i + 1))
    fm_afk_daemon_owns_supervision "$STATE" "$CONFIG" && return 0
    session_alive "$1" || return 1
    sleep 0.05
  done
  return 1
}

ensure() {
  local target session pending rc
  [ -f "$FLAG" ] || { printf 'continuous-supervision: disabled\n'; return 0; }
  command -v tmux >/dev/null 2>&1 || { log "tmux is required for the supported continuous supervisor service"; return 1; }
  target=$(discover_supervisor_target) || { log "no current supervisor pane identity; retry at the next session bootstrap"; return 1; }
  [ -n "${TMUX_PANE:-}" ] || [ "${FM_SUPERVISOR_BACKEND:-}" = tmux ] || {
    log "continuous supervision currently supports tmux supervisor sessions only"
    return 1
  }
  valid_record_field "$target" || {
    log "supervisor target '$target' cannot be recorded; use a pane id or a session:window target of [A-Za-z0-9_.:%+-]"
    return 1
  }
  lock_acquire || return 1
  record_read
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$REC_TARGET" = "$target" ] \
     && session_alive "$REC_SESSION" && fm_afk_daemon_owns_supervision "$STATE" "$CONFIG"; then
    fm_lock_release "$LOCK"
    printf 'continuous-supervision: running session=%s target=%s\n' "$REC_SESSION" "$REC_TARGET"
    return 0
  fi
  [ "$rc" -ne 2 ] || { fm_lock_release "$LOCK"; log "malformed terminal record; refusing to replace it"; return 1; }
  # A live daemon without this lifecycle's matching live terminal is another
  # owner (normally an away-mode launch or a surviving prior implementation).
  # Never kill, adopt, or race it. Its own lifecycle must reconcile it first.
  if fm_afk_daemon_owns_supervision "$STATE" "$CONFIG" \
     && { [ "$rc" -ne 0 ] || ! session_alive "$REC_SESSION"; }; then
    fm_lock_release "$LOCK"
    log "a live supervisor daemon exists without a matching continuous-supervision terminal; refusing a second owner"
    return 1
  fi
  stop_recorded || { fm_lock_release "$LOCK"; return 1; }
  session="fm-continuous-$(printf '%s' "$FM_HOME" | cksum | awk '{print $1}')-$$"
  if ! tmux new-session -d -s "$session" env FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$target" "$DAEMON"; then
    fm_lock_release "$LOCK"
    log "failed to launch daemon session $session"
    return 1
  fi
  pending=$(mktemp "$STATE/.continuous-supervision-terminal.pending.XXXXXX") || {
    tmux kill-session -t "$session" 2>/dev/null || true
    fm_lock_release "$LOCK"
    return 1
  }
  if ! printf '%s\t%s\n' "$session" "$target" > "$pending" || ! mv "$pending" "$RECORD"; then
    rm -f "$pending"
    tmux kill-session -t "$session" 2>/dev/null || true
    fm_lock_release "$LOCK"
    return 1
  fi
  if ! wait_ready "$session" || ! session_alive "$session"; then
    stop_recorded || true
    fm_lock_release "$LOCK"
    log "daemon did not become ready"
    return 1
  fi
  fm_lock_release "$LOCK"
  printf 'continuous-supervision: running session=%s target=%s\n' "$session" "$target"
}

main() {
  case "${1:-}" in
    enable)
      mkdir -p "$CONFIG" || return 1
      : > "$FLAG" || return 1
      ensure
      ;;
    ensure) ensure ;;
    disable)
      lock_acquire || return 1
      record_read
      rc=$?
      if [ "$rc" -eq 2 ]; then
        fm_lock_release "$LOCK"
        log "malformed terminal record; refusing to disable an unidentifiable service"
        return 1
      fi
      stop_recorded
      rc=$?
      if [ "$rc" -eq 0 ]; then
        rm -f "$FLAG" || rc=1
      fi
      fm_lock_release "$LOCK"
      [ "$rc" -eq 0 ] && printf 'continuous-supervision: disabled\n'
      return "$rc"
      ;;
    status)
      [ -f "$FLAG" ] || { printf 'continuous-supervision: disabled\n'; return 0; }
      if record_read && session_alive "$REC_SESSION" && fm_afk_daemon_owns_supervision "$STATE" "$CONFIG"; then
        printf 'continuous-supervision: running session=%s target=%s\n' "$REC_SESSION" "$REC_TARGET"
        return 0
      fi
      printf 'continuous-supervision: enabled but not running\n'
      return 1
      ;;
    *) echo "usage: $(basename "$0") enable|ensure|disable|status" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
