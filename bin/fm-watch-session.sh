#!/usr/bin/env bash
# Durable, home-scoped active watcher runner.
#
# Use this in harnesses where a tracked background task is not durable enough.
# It creates one tmux window per FM_HOME/STATE pair and runs fm-watch-arm.sh in a
# loop there. The watcher itself remains the same singleton: it is still scoped by
# this home's state/.watch.lock, and no broad process matching is used. Wake output
# re-arms immediately; failed and quiet healthy no-op arms keep the retry delay.
# A Grok primary keeps the follower wait on Grok's tracked background arm: start
# and restart refuse unless FM_ALLOW_WATCH_SESSION_WITH_GROK=1 selects the emergency
# tmux fallback explicitly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WATCH_SESSION_DEFAULT_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_ROOT="${FM_ROOT_OVERRIDE:-$FM_WATCH_SESSION_DEFAULT_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_watch_primary_entry_trusted() {
  fm_verified_harness_ancestry_pid >/dev/null 2>&1 && return 0
  fm_session_lock_owned_by_self "$STATE"
}

fm_watch_primary_entry_trusted || {
  echo "watch-session: FAILED - primary harness or session-lock ownership is unproven" >&2
  exit 1
}

fm_worker_primary_attestation_load 2>/dev/null || true

write_primary_attestation() {
  fm_worker_primary_attestation_establish
}

case "${1:-start}" in
  start|--start|restart|--restart)
    if ! fm_worker_primary_bootstrap_proven; then
      fm_worker_refuse_primary_operation "watch session" || exit 1
      echo "watch-session: FAILED - primary bootstrap provenance is unproven" >&2
      exit 1
    fi
    write_primary_attestation || {
      echo "watch-session: FAILED - could not establish the primary launch attestation" >&2
      exit 1
    }
    ;;
esac
fm_worker_refuse_primary_operation "watch session" || exit 1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-detach-lib.sh
. "$SCRIPT_DIR/fm-detach-lib.sh"

refuse_grok_primary() {
  [ "${GROK_AGENT:-}" = "1" ] || return 0
  [ "${FM_ALLOW_WATCH_SESSION_WITH_GROK:-}" = "1" ] && return 0
  echo "watch-session: refusing Grok primary; Grok's tracked background arm must own the watcher wait (set FM_ALLOW_WATCH_SESSION_WITH_GROK=1 only for emergency fallback)" >&2
  return 1
}

SESSION_NAME=${FM_WATCH_SESSION_TMUX_SESSION:-firstmate-watch}
HASH=$(printf '%s\n%s\n' "$FM_HOME" "$STATE" | cksum | awk '{print $1}')
WINDOW_NAME=${FM_WATCH_SESSION_TMUX_WINDOW:-fm-watch-$HASH}
TARGET="$SESSION_NAME:$WINDOW_NAME"
SESSION_DIR="$STATE/.watch-session"
ENV_FILE="$SESSION_DIR/env.sh"
RUNNER_FILE="$SESSION_DIR/runner.sh"
STOP_FILE="$SESSION_DIR/stop"
WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
RETRY_DELAY=${FM_WATCH_SESSION_REARM_DELAY:-${FM_WATCH_SESSION_RETRY_DELAY:-1}}
AFK_DELAY=${FM_WATCH_SESSION_AFK_DELAY:-15}
STOP_WATCH_POLLS=${FM_WATCH_SESSION_STOP_POLLS:-60}

usage() {
  echo "usage: $(basename "$0") [start|--status|status|stop|restart]" >&2
}

shell_quote() {
  # POSIX single-quote escaping.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

tmux_window_exists() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 1
  tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -Fx "$WINDOW_NAME" >/dev/null
}

write_runner_files() {
  mkdir -p "$SESSION_DIR"
  {
    printf 'export FM_HOME=%s\n' "$(shell_quote "$FM_HOME")"
    printf 'export FM_ROOT_OVERRIDE=%s\n' "$(shell_quote "$FM_ROOT")"
    printf 'export FM_STATE_OVERRIDE=%s\n' "$(shell_quote "$STATE")"
    printf 'export FM_PRIMARY_ATTESTATION=%s\n' "$(shell_quote "$FM_PRIMARY_ATTESTATION")"
    printf 'export PATH=%s\n' "$(shell_quote "$PATH")"
  } > "$ENV_FILE"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '. %s\n' "$(shell_quote "$ENV_FILE")"
    printf 'rm -f %s\n' "$(shell_quote "$STOP_FILE")"
    printf 'while :; do\n'
    printf '  [ -e %s ] && exit 0\n' "$(shell_quote "$STOP_FILE")"
    # shellcheck disable=SC2016 # Generated runner expands FM_STATE_OVERRIDE at runtime.
    printf '  if [ -e "$FM_STATE_OVERRIDE/.afk" ]; then sleep %s; continue; fi\n' "$AFK_DELAY"
    printf '  arm_out=%s\n' "$(shell_quote "$SESSION_DIR/arm.out")"
    # shellcheck disable=SC2016 # Generated runner expands arm_out at runtime.
    printf '  rm -f "$arm_out"\n'
    # shellcheck disable=SC2016 # Generated runner expands arm_out at runtime.
    printf '  %s/fm-watch-arm.sh >"$arm_out"\n' "$(shell_quote "$SCRIPT_DIR")"
    printf '  rc=$?\n'
    # shellcheck disable=SC2016 # Generated runner expands arm_out at runtime.
    printf '  [ -s "$arm_out" ] && cat "$arm_out"\n'
    # shellcheck disable=SC2016 # Generated runner expands arm_out at runtime.
    printf '  [ -e %s ] && { rm -f "$arm_out"; exit 0; }\n' "$(shell_quote "$STOP_FILE")"
    # shellcheck disable=SC2016 # Generated runner expands rc at runtime.
    printf '  if [ "$rc" -ne 0 ]; then rm -f "$arm_out"; sleep %s; continue; fi\n' "$RETRY_DELAY"
    # shellcheck disable=SC2016 # Generated runner expands arm_out at runtime.
    printf '  if grep -Eq '\''^(signal:|stale:|check:|heartbeat($|:))'\'' "$arm_out"; then rm -f "$arm_out"; continue; fi\n'
    # shellcheck disable=SC2016 # Generated runner expands arm_out at runtime.
    printf '  rm -f "$arm_out"\n'
    printf '  sleep %s\n' "$RETRY_DELAY"
    printf 'done\n'
  } > "$RUNNER_FILE"
  chmod +x "$RUNNER_FILE"
}

start_runner() {
  local command
  write_primary_attestation || {
    echo "watch-session: FAILED - could not establish the primary launch attestation" >&2
    return 1
  }
  if ! command -v tmux >/dev/null 2>&1; then
    echo "watch-session: FAILED - tmux not found" >&2
    return 1
  fi
  if tmux_window_exists; then
    echo "watch-session: running target=$TARGET home=$FM_HOME"
    return 0
  fi
  command="bash $(shell_quote "$RUNNER_FILE")"
  write_runner_files
  rm -f "$STOP_FILE"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux new-window -d -t "$SESSION_NAME:" -n "$WINDOW_NAME" "$command" || {
      echo "watch-session: FAILED - could not start target=$TARGET" >&2
      return 1
    }
  else
    tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" "$command" || {
      echo "watch-session: FAILED - could not start target=$TARGET" >&2
      return 1
    }
  fi
  echo "watch-session: started target=$TARGET home=$FM_HOME"
}

status_runner() {
  if tmux_window_exists; then
    echo "watch-session: running target=$TARGET home=$FM_HOME"
    return 0
  fi
  echo "watch-session: stopped home=$FM_HOME"
  return 1
}

stop_home_watcher() {
  local pid start i=0 stop_failed=0
  [ -e "$STATE/.afk" ] && return 0
  while [ "$i" -lt "$STOP_WATCH_POLLS" ]; do
    pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && fm_pid_alive "$pid" && ! fm_pid_is_zombie "$pid" \
      && fm_watcher_lock_scope_matches "$WATCH_LOCK" "$FM_HOME" "$WATCH"; then
      start=$(cat "$WATCH_LOCK/pid-start" 2>/dev/null || true)
      if [ -z "$start" ]; then
        stop_failed=1
      elif ! fm_watcher_lock_matches_pid "$WATCH_LOCK" "$pid" "$FM_HOME" "$WATCH"; then
        stop_failed=1
      elif ! fm_detach_kill "$pid" "$start"; then
        if fm_pid_alive "$pid" && ! fm_pid_is_zombie "$pid"; then
          stop_failed=1
        fi
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && fm_pid_alive "$pid" && ! fm_pid_is_zombie "$pid" \
    && fm_watcher_lock_scope_matches "$WATCH_LOCK" "$FM_HOME" "$WATCH"; then
    stop_failed=1
  fi
  [ "$stop_failed" -eq 0 ]
}

stop_runner() {
  touch "$STOP_FILE" 2>/dev/null || true
  if tmux_window_exists; then
    tmux kill-window -t "$TARGET"
    if ! stop_home_watcher; then
      echo "watch-session: FAILED - watcher identity is not safely pinned for stop" >&2
      return 1
    fi
    echo "watch-session: stopped target=$TARGET home=$FM_HOME"
    return 0
  fi
  if ! stop_home_watcher; then
    echo "watch-session: FAILED - watcher identity is not safely pinned for stop" >&2
    return 1
  fi
  echo "watch-session: stopped home=$FM_HOME"
  return 0
}

mode=${1:-start}
case "$mode" in
  start|--start)
    refuse_grok_primary || exit 1
    start_runner
    ;;
  status|--status) status_runner ;;
  stop|--stop) stop_runner ;;
  restart|--restart)
    refuse_grok_primary || exit 1
    stop_runner >/dev/null || exit 1
    start_runner
    ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
