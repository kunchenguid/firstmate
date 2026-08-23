#!/usr/bin/env bash
# fm-totmann.sh - quota-free dead-man revival for the firstmate session (plan v3 U1.7).
#
# Usage:
#   fm-totmann.sh check      probe, and revive when the session is dead (timer entry point)
#   fm-totmann.sh status     report the verdict without acting; exit 0 alive, 1 dead
#   fm-totmann.sh --help
#
# Verdict, from structural evidence only - no vendor command names (L11/L28):
#   1. $FM_HOME/state/.lock carries the session lock holder's pid (owner:
#      bin/fm-lock.sh). A live lock pid means the session is alive, wherever
#      its window lives.
#   2. Otherwise the tmux pane $FM_TOTMANN_TARGET (default firstmate:0) is
#      alive when its pane_pid either has a live child process or is itself no
#      shell: a dead session leaves a bare shell with no children.
#      pane_current_command is deliberately not read - version-named harness
#      binaries broke that check and produced duplicate sessions (W3).
#   3. Neither holds -> dead: after the debounce the revival types
#      $FM_TOTMANN_RELAUNCH_CMD (default `claude4 --continue`) into the target
#      window, creating session and window when missing, and notifies the
#      captain best-effort via the notifier.
#
# The fleet stop does NOT gate this revival: after the nightly day-close reboot
# the leadership session must return, and state/.fleet-stop then keeps
# everything else from starting (plan v3 U1.7). Workers and officers are NEVER
# woken: the tool only ever touches the one configured target window.
#
# State (this header is the single owner):
#   $FM_HOME/state/.totmann-last-restart   epoch seconds of the last revival (debounce)
#
# Environment:
#   FM_TOTMANN_TARGET        tmux target pane (default firstmate:0)
#   FM_TOTMANN_RELAUNCH_CMD  command typed to revive (default: claude4 --continue;
#                            follows the firstmate seat - account 4 since O-0006, 23.08.2026)
#   FM_TOTMANN_TMUX          extra tmux args, e.g. "-L testsock" (tests)
#   FM_TOTMANN_DEBOUNCE      seconds between revivals (default 1800)
#   FM_TOTMANN_NOTIFY        notifier executable (default claw-notify; "" disables)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
TARGET="${FM_TOTMANN_TARGET:-firstmate:0}"
SESSION="${TARGET%%:*}"
RELAUNCH="${FM_TOTMANN_RELAUNCH_CMD:-claude4 --continue}"
DEBOUNCE="${FM_TOTMANN_DEBOUNCE:-1800}"
NOTIFY="${FM_TOTMANN_NOTIFY-claw-notify}"
read -r -a TMUX_EXTRA <<< "${FM_TOTMANN_TMUX:-}"

usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
tmx() { tmux ${TMUX_EXTRA[@]+"${TMUX_EXTRA[@]}"} "$@"; }

is_shell_comm() { # the stable system shells; anything else in a pane is a live program
  case "$1" in
    bash|sh|dash|zsh|fish|ksh|-bash|-sh|-zsh) return 0 ;;
    *) return 1 ;;
  esac
}

verdict() { # prints the reason; exit 0 alive, 1 dead
  local lock_pid pane_pid comm
  lock_pid="$(cat "$STATE/.lock" 2>/dev/null || true)"
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "alive: session lock pid $lock_pid is running"
    return 0
  fi
  pane_pid="$(tmx display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null || true)"
  if [ -n "$pane_pid" ]; then
    if pgrep -P "$pane_pid" >/dev/null 2>&1; then
      echo "alive: pane $TARGET (pid $pane_pid) has a live child process"
      return 0
    fi
    comm="$(cat "/proc/$pane_pid/comm" 2>/dev/null || true)"
    if [ -n "$comm" ] && ! is_shell_comm "$comm"; then
      echo "alive: pane $TARGET runs '$comm' directly"
      return 0
    fi
    echo "dead: pane $TARGET is a bare shell (pid $pane_pid, comm ${comm:-unknown}) and no lock holder is alive"
    return 1
  fi
  echo "dead: no live lock holder and no pane $TARGET"
  return 1
}

cmd="${1:-check}"
case "$cmd" in
  status)
    if verdict; then exit 0; fi
    exit 1
    ;;
  check)
    if verdict; then exit 0; fi
    mkdir -p "$STATE"
    now="$(date +%s)"
    last="$(cat "$STATE/.totmann-last-restart" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "$DEBOUNCE" ]; then
      echo "dead, but debounced: last revival $((now - last))s ago (< ${DEBOUNCE}s)"
      exit 0
    fi
    echo "$now" > "$STATE/.totmann-last-restart"
    if ! tmx has-session -t "$SESSION" 2>/dev/null; then
      tmx new-session -d -s "$SESSION" -c "$FM_HOME"
    fi
    tmx send-keys -t "$TARGET" "$RELAUNCH" Enter
    echo "revived: typed relaunch into $TARGET"
    if [ -n "$NOTIFY" ] && command -v "$NOTIFY" >/dev/null 2>&1; then
      stop_note=""
      [ -f "$STATE/.fleet-stop" ] && stop_note=" Der Flottenstopp steht weiter - ausser der Fuehrung startet nichts."
      "$NOTIFY" "Firstmate war stehen geblieben und wurde automatisch wiederbelebt.${stop_note} Der naechste Startlauf bestaetigt den Zustand." \
        --prio warn --projekt default >/dev/null 2>&1 || true
    fi
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
