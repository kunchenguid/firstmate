#!/usr/bin/env bash
# Send one line of literal text to a crewmate window, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare window name (fm-xyz) or session:window.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
set -eu

"$(dirname "${BASH_SOURCE[0]}")/fm-guard.sh" || true

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

T=$(resolve "$1")
shift

if [ "${1:-}" = "--key" ]; then
  tmux send-keys -t "$T" "$2"
else
  tmux send-keys -t "$T" -l "$*"
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
  tmux send-keys -t "$T" Enter
fi
