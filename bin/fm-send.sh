#!/usr/bin/env bash
# Send one line of literal text to a crewmate window, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

"$SCRIPT_DIR/fm-guard.sh" || true

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    fm-*)
      meta="$STATE/${1#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $1 in $STATE; pass session:window to target a window outside this firstmate home" >&2
        exit 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; exit 1; }
      echo "$window"
      ;;
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
