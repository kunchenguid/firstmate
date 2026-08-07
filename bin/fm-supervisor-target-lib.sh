#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - operator-session and delivery-endpoint discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need identical resolution, it lives here once.
# Operator-session identity and escalation-delivery identity are deliberately
# separate: a primary harness process on a plain Ghostty TTY is a real operator
# session, but that TTY is not an addressable agent composer.

FM_SUPERVISOR_TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_SUPERVISOR_TARGET_DIR/fm-session-lock-lib.sh"

supervisor_delivery_backend_supported() {  # <backend>
  case "$1" in tmux|herdr) return 0 ;; esac
  return 1
}

fm_supervisor_unverified() {  # <reason>
  printf 'UNVERIFIED(%s)' "$1"
  return 1
}

# discover_operator_session_identity: identify the primary operator session
# without requiring tmux. A directly addressable tmux/herdr endpoint is already
# a complete identity. Otherwise the existing per-home session lock supplies
# the live primary-harness pid, and its controlling TTY distinguishes a Ghostty
# terminal session from every sibling session. The harness pid remains the
# identity if the kernel cannot expose a TTY; that field is reported explicitly
# as unverified rather than confidently absent.
discover_operator_session_identity() {
  local state lock pid tty
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ] && [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf 'backend=%s;target=%s' "$FM_SUPERVISOR_BACKEND" "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'backend=tmux;target=%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'backend=herdr;target=%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi

  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    state=$FM_STATE_OVERRIDE
  elif [ -n "${FM_HOME:-}" ]; then
    state=$FM_HOME/state
  else
    fm_supervisor_unverified no-state-root
    return
  fi
  lock="$state/.lock"
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    fm_supervisor_unverified no-regular-session-lock
    return
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    fm_supervisor_unverified unreadable-session-lock
    return
  }
  case "$pid" in
    ''|*[!0-9]*) fm_supervisor_unverified malformed-session-lock; return ;;
  esac
  if ! fm_harness_pid_alive "$pid"; then
    fm_supervisor_unverified session-lock-holder-not-live-harness
    return
  fi
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | awk 'NR == 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }')
  case "$tty" in
    ''|'?'|'??'|'-') tty='UNVERIFIED(no-controlling-terminal)' ;;
    /dev/*) ;;
    *) tty="/dev/$tty" ;;
  esac
  printf 'harness-pid=%s;tty=%s' "$pid" "$tty"
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. Explicit UNVERIFIED result. A guessed target is never returned.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  fm_supervisor_unverified no-supported-delivery-target
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. Explicit UNVERIFIED result. A guessed backend is never returned.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  fm_supervisor_unverified no-supported-delivery-backend
}
