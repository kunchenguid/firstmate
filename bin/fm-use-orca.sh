#!/usr/bin/env bash
# bin/fm-use-orca.sh — switch firstmate to the orca backend, full setup.
#
# Idempotent. Safe to re-run. Goes from "nothing configured" to "orca
# daily-driver with supervised daemon + autostart + smoke-verified" in
# one call.
#
# Steps:
#   1. Verify prerequisites (orca CLI on PATH, daemon reachable via fmod
#      info, python3/fmod available for the adapter).
#   2. Stop any running orca supervisor (idempotent).
#   3. Write config/backend=orca (LOCAL, gitignored).
#   4. If config/crew-harness is absent or empty, write config/crew-harness=pi
#      (LOCAL, gitignored) so orca + pi is the working default pairing.
#   5. Start bin/fm-supervise-orca.sh so a dead daemon self-heals.
#   6. Install autostart (XDG) so the supervisor survives logout.
#   7. Run a trivial orca+pi spawn (smoke03-style) to verify end-to-end;
#      teardown after, report the spawn/teardown summary so the captain
#      sees a green check before they start using it.
#
# Usage:
#   bin/fm-use-orca.sh [start|status|stop|restart|autostart|smoke]
#     start     full setup (default; runs all steps above)
#     status    show current orca backend wiring + supervisor + autostart
#     stop      stop the supervisor and remove autostart
#     restart   stop + start
#     autostart install or remove the XDG autostart entry
#     smoke     run the trivial spawn test only
#
# Exit: 0 on full success; non-zero if any step failed (with a per-step
# summary at the end so the captain can act without re-reading logs).
#
# The orca backend is the most-capable Linux-friendly runtime firstmate
# has today: it owns both the task worktree and the terminal endpoint,
# the daemon-direct adapter (bin/fmod) bypasses the orca CLI's
# single-instance lock, and the supervisor self-heals the stale_bootstrap
# failure mode that hit Linux installs without a desktop session.

set -u

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PIDFILE="$STATE/.orca-supervisor.pid"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/fm-supervise-orca.desktop"

step() { printf '\n[fm-use-orca] %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
FAILS=0

desktop_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

require_orca() {
  command -v orca >/dev/null 2>&1 || { fail "orca binary not on PATH"; return 1; }
  ok "orca at $(command -v orca)"
  command -v python3 >/dev/null 2>&1 || { fail "python3 not on PATH (fmod and orca adapter use it)"; return 1; }
  ok "python3 at $(command -v python3)"
  if [ -x "$FM_ROOT/bin/fmod" ]; then
    ok "fmod at $FM_ROOT/bin/fmod"
  elif command -v fmod >/dev/null 2>&1; then
    ok "fmod at $(command -v fmod)"
  else
    fail "fmod not found (expected $FM_ROOT/bin/fmod or PATH)"
    return 1
  fi
  command -v setsid >/dev/null 2>&1 || { fail "setsid missing (install util-linux)"; return 1; }
  ok "setsid available"
  return 0
}

write_config_orca() {
  mkdir -p "$CONFIG" 2>/dev/null || true
  printf 'orca\n' > "$CONFIG/backend"
  ok "wrote $CONFIG/backend = orca"
  if [ ! -s "$CONFIG/crew-harness" ]; then
    printf 'pi\n' > "$CONFIG/crew-harness"
    ok "wrote $CONFIG/crew-harness = pi (default; override any time)"
  else
    local existing
    existing=$(tr -d '[:space:]' < "$CONFIG/crew-harness" 2>/dev/null || true)
    ok "kept $CONFIG/crew-harness = $existing (not empty; not overwriting)"
  fi
}

start_supervisor() {
  "$FM_ROOT/bin/fm-supervise-orca.sh" start
}

stop_supervisor() {
  "$FM_ROOT/bin/fm-supervise-orca.sh" stop
}

install_autostart() {
  local fm_home_arg supervisor_arg
  fm_home_arg=$(desktop_quote "FM_HOME=$FM_HOME")
  supervisor_arg=$(desktop_quote "$FM_ROOT/bin/fm-supervise-orca.sh")
  mkdir -p "$AUTOSTART_DIR" 2>/dev/null || { fail "cannot create $AUTOSTART_DIR"; return 1; }
  cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Firstmate Orca Supervisor
Comment=Keeps the orca terminal daemon alive so firstmate orca spawns never hit stale_bootstrap.
Exec=env $fm_home_arg $supervisor_arg start
Terminal=false
Categories=Development;Utility;
X-GNOME-Autostart-enabled=true
EOF
  ok "wrote $AUTOSTART_FILE"
  return 0
}

remove_autostart() {
  if [ -f "$AUTOSTART_FILE" ]; then
    rm -f "$AUTOSTART_FILE"
    ok "removed $AUTOSTART_FILE"
  else
    ok "no autostart present"
  fi
}

smoke() {
  step "smoke: trivial orca+pi spawn"
  local smoke_project candidate
  smoke_project=${FM_ORCA_SMOKE_PROJECT:-}
  if [ -z "$smoke_project" ] && [ -d "$FM_HOME/projects" ]; then
    for candidate in "$FM_HOME"/projects/*; do
      [ -d "$candidate/.git" ] || git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 || continue
      smoke_project=$candidate
      break
    done
  fi
  if [ -z "$smoke_project" ]; then
    fail "no smoke project found (set FM_ORCA_SMOKE_PROJECT or add a git repo under $FM_HOME/projects)"
    return 1
  fi
  mkdir -p "$FM_HOME/data/smoke-use-orca" 2>/dev/null || true
  cat > "$FM_HOME/data/smoke-use-orca/brief.md" <<'BRIEF'
# smoke-use-orca

Firstmate use-orca smoke. Confirm you are alive in one short sentence and identify the model/provider.
Do not modify any files.
BRIEF
  if ! out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-spawn.sh" smoke-use-orca "$smoke_project" --backend orca --harness pi 2>&1); then
    fail "spawn refused: $out"
    return 1
  fi
  ok "spawn: $out"
  # pi needs time to load + process a brief + complete a turn. Poll the
  # turn-end marker rather than sleeping a fixed duration so the smoke is
  # honest about whether the agent actually fired the extension.
  local waited=0
  while [ ! -f "$STATE/smoke-use-orca.turn-ended" ] && [ "$waited" -lt 60 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if [ -f "$STATE/smoke-use-orca.turn-ended" ]; then
    ok "turn-end extension fired after ${waited}s (state/smoke-use-orca.turn-ended exists)"
  else
    fail "turn-end extension did NOT fire within 60s (state/smoke-use-orca.turn-ended missing)"
  fi
  if FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-teardown.sh" smoke-use-orca 2>&1 | grep -q "complete"; then
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
  printf '  supervisor:       '
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    printf 'live pid=%s\n' "$(cat "$PIDFILE")"
  else
    printf 'not running\n'
  fi
  printf '  daemon:           '
  if timeout 5 "$FM_ROOT/bin/fmod" ping >/dev/null 2>&1; then
    printf 'reachable\n'
  else
    printf 'unreachable\n'
  fi
  printf '  autostart:        '
  if [ -f "$AUTOSTART_FILE" ]; then
    printf 'installed (%s)\n' "$AUTOSTART_FILE"
  else
    printf 'not installed\n'
  fi
}

start_all() {
  step "1. prerequisites"
  require_orca || return 1
  step "2. write config"
  write_config_orca
  step "3. start supervisor"
  # fm-supervise-orca.sh start returns 3 when a supervisor is already live; that
  # is idempotent success for use-orca's purposes (the daemon is supervised).
  start_supervisor; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "supervisor started"
  elif [ "$rc" -eq 3 ]; then
    ok "supervisor already live (idempotent)"
  else
    fail "supervisor failed to start (exit $rc)"
    return 1
  fi
  step "4. install autostart"
  install_autostart
  step "5. end-to-end smoke"
  smoke
  step "6. summary"
  if [ "$FAILS" -eq 0 ]; then
    ok "orca daily-driver ready"
    printf '  try: pi -p -c "echo hello" in a fresh wezterm pane\n'
    printf '  spawn: bin/fm-spawn.sh <id> <repo> --backend orca --harness pi\n'
    printf '  switch back: bin/fm-use-tmux.sh start\n'
    return 0
  fi
  fail "$FAILS step(s) failed; see above"
  return 1
}

case "${1:-start}" in
  start) start_all ;;
  status) status_report ;;
  stop)
    stop_supervisor || true
    remove_autostart
    ;;
  restart)
    stop_supervisor || true
    sleep 1
    start_all
    ;;
  autostart)
    case "${2:-install}" in
      install) install_autostart ;;
      remove) remove_autostart ;;
      *) echo "usage: $0 autostart [install|remove]" >&2; exit 64 ;;
    esac
    ;;
  smoke) smoke ;;
  *)
    echo "usage: $0 [start|status|stop|restart|autostart|smoke]" >&2
    exit 64
    ;;
esac
