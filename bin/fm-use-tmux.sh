#!/usr/bin/env bash
# bin/fm-use-tmux.sh — switch firstmate back to the tmux backend.
#
# Symmetric counterpart to bin/fm-use-orca.sh. Stops the orca supervisor
# and removes its autostart entry, then verifies tmux is available and
# writes config/backend (or removes it so tmux auto-detection wins).
#
# Steps:
#   1. Stop the orca supervisor (idempotent).
#   2. Remove the orca autostart entry (idempotent).
#   3. Verify tmux is installed; refuse to switch if absent.
#   4. Verify we are inside (or can attach to) a tmux session — firstmate's
#      tmux backend requires it; refuse if neither is true.
#   5. Clear config/backend so tmux auto-detection wins, OR write tmux
#      explicitly if the captain wants the choice durable.
#   6. Run a trivial tmux+pi spawn as a smoke (skip with --no-smoke).
#
# Usage:
#   bin/fm-use-tmux.sh [start|status|stop|restart] [--no-smoke]
#     start     full switchover (default)
#     status    show current backend wiring
#     stop      stop the orca supervisor only; do not change config
#     restart   stop + start
#     --no-smoke skip the trivial spawn test

set -u

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PIDFILE="$STATE/.orca-supervisor.pid"
AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/fm-supervise-orca.desktop"
SMOKE=1

for a in "$@"; do
  case "$a" in
    --no-smoke) SMOKE=0 ;;
  esac
done

step() { printf '\n[fm-use-tmux] %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
FAILS=0

stop_orca_supervisor() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    "$FM_ROOT/bin/fm-supervise-orca.sh" stop && ok "stopped orca supervisor"
  else
    ok "no orca supervisor running"
  fi
}

remove_orca_autostart() {
  if [ -f "$AUTOSTART_FILE" ]; then
    rm -f "$AUTOSTART_FILE" && ok "removed $AUTOSTART_FILE"
  else
    ok "no orca autostart present"
  fi
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || { fail "tmux not on PATH"; return 1; }
  ok "tmux at $(command -v tmux) ($(tmux -V))"
  if [ -z "${TMUX:-}" ] && [ -z "${TMUX_PANE:-}" ]; then
    fail "not inside a tmux session (firstmate's tmux backend requires TMUX/TMUX_PANE)"
    printf '    hint: tmux new-session -d -s firstmate && tmux attach -t firstmate\n'
    return 1
  fi
  ok "inside tmux session"
  return 0
}

write_config_tmux() {
  mkdir -p "$CONFIG" 2>/dev/null || true
  printf 'tmux\n' > "$CONFIG/backend"
  ok "wrote $CONFIG/backend = tmux"
}

clear_config_backend() {
  if [ -f "$CONFIG/backend" ]; then
    rm -f "$CONFIG/backend"
    ok "removed $CONFIG/backend (tmux is the default; auto-detection wins)"
  else
    ok "$CONFIG/backend already absent"
  fi
}

smoke() {
  step "smoke: trivial tmux+pi spawn"
  local smoke_project candidate
  smoke_project=${FM_TMUX_SMOKE_PROJECT:-}
  if [ -z "$smoke_project" ] && [ -d "$FM_HOME/projects" ]; then
    for candidate in "$FM_HOME"/projects/*; do
      [ -d "$candidate/.git" ] || git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 || continue
      smoke_project=$candidate
      break
    done
  fi
  if [ -z "$smoke_project" ]; then
    fail "no smoke project found (set FM_TMUX_SMOKE_PROJECT or add a git repo under $FM_HOME/projects)"
    return 1
  fi
  mkdir -p "$DATA/smoke-use-tmux" 2>/dev/null || true
  cat > "$DATA/smoke-use-tmux/brief.md" <<'BRIEF'
# smoke-use-tmux

Firstmate use-tmux smoke. Confirm you are alive in one short sentence.
Do not modify any files.
BRIEF
  if ! out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-spawn.sh" smoke-use-tmux "$smoke_project" --harness pi 2>&1); then
    fail "spawn refused: $out"
    return 1
  fi
  ok "spawn: $out"
  sleep 8
  if [ -f "$STATE/smoke-use-tmux.turn-ended" ]; then
    ok "turn-end extension fired"
  else
    fail "turn-end extension did NOT fire"
  fi
  if FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-teardown.sh" smoke-use-tmux 2>&1 | grep -q "complete"; then
    ok "teardown clean"
  else
    fail "teardown reported an issue"
  fi
  return 0
}

status_report() {
  step "current state"
  printf '  config/backend:   '
  if [ -f "$CONFIG/backend" ]; then
    printf '%s\n' "$(tr -d '[:space:]' < "$CONFIG/backend" 2>/dev/null)"
  else
    printf '(unset; defaults to tmux)\n'
  fi
  printf '  config/crew-harness: '
  if [ -f "$CONFIG/crew-harness" ]; then
    printf '%s\n' "$(tr -d '[:space:]' < "$CONFIG/crew-harness" 2>/dev/null)"
  else
    printf '(unset; mirrors firstmate)\n'
  fi
  printf '  orca supervisor:  '
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    printf 'live (will be stopped by this command)\n'
  else
    printf 'not running\n'
  fi
  printf '  orca autostart:   '
  if [ -f "$AUTOSTART_FILE" ]; then
    printf 'installed (will be removed)\n'
  else
    printf 'not installed\n'
  fi
}

start_all() {
  step "1. stop orca supervisor"
  stop_orca_supervisor
  step "2. remove orca autostart"
  remove_orca_autostart
  step "3. verify tmux"
  require_tmux || return 1
  step "4. clear orca config"
  clear_config_backend
  if [ "$SMOKE" -eq 1 ]; then
    step "5. end-to-end smoke"
    smoke
  else
    ok "smoke skipped (--no-smoke)"
  fi
  step "summary"
  if [ "$FAILS" -eq 0 ]; then
    ok "tmux daily-driver ready"
    printf '  wezterm+tmux pane: pi -p -c "echo hello" for a quick check\n'
    printf '  spawn: bin/fm-spawn.sh <id> <repo> --harness pi\n'
    printf '  switch to orca: bin/fm-use-orca.sh start\n'
    return 0
  fi
  fail "$FAILS step(s) failed"
  return 1
}

case "${1:-start}" in
  start) start_all ;;
  status) status_report ;;
  stop)
    stop_orca_supervisor
    remove_orca_autostart
    ;;
  restart)
    stop_orca_supervisor
    remove_orca_autostart
    start_all
    ;;
  *)
    echo "usage: $0 [start|status|stop|restart] [--no-smoke]" >&2
    exit 64
    ;;
esac
