#!/usr/bin/env bash
# Create or attach a read-only tmux dashboard for one FirstMate session.
# Usage: fm-dashboard.sh <target-session> [--observer NAME] [--interval SECONDS] [--no-attach]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=${1:-}
[ -n "$TARGET" ] || { echo "error: target session is required" >&2; exit 2; }
shift
case "$TARGET" in *[!A-Za-z0-9_.:-]*) echo "error: target session contains unsafe characters" >&2; exit 2 ;; esac
OBSERVER="fm-dashboard-${TARGET#fm-}"
INTERVAL=3
ATTACH=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --observer) OBSERVER=${2:?missing observer}; shift 2 ;;
    --interval) INTERVAL=${2:?missing interval}; shift 2 ;;
    --no-attach) ATTACH=0; shift ;;
    -h|--help)
      sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$OBSERVER" in ''|*[!A-Za-z0-9_.:-]*) echo "error: observer session contains unsafe characters" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: interval must be a positive integer" >&2; exit 2 ;; esac
command -v tmux >/dev/null 2>&1 || { echo "error: tmux is required" >&2; exit 1; }
tmux has-session -t "$TARGET" 2>/dev/null || { echo "error: target session '$TARGET' does not exist" >&2; exit 1; }

if ! tmux has-session -t "$OBSERVER" 2>/dev/null; then
  tmux new-session -d -s "$OBSERVER" -n dashboard \
    "$SCRIPT_DIR/fm-dashboard-loop.sh coordinator '$TARGET' '$INTERVAL'"
  tmux split-window -h -p 48 -t "$OBSERVER:dashboard.0" \
    "$SCRIPT_DIR/fm-dashboard-loop.sh roster '$TARGET' '$INTERVAL'"
  tmux split-window -v -p 50 -t "$OBSERVER:dashboard.1" \
    "$SCRIPT_DIR/fm-dashboard-loop.sh details '$TARGET' '$INTERVAL'"
fi

printf 'status: ready\n'
printf 'observer: %s\n' "$OBSERVER"
printf 'target: %s\n' "$TARGET"
printf 'attach: "tmux attach -t %s"\n' "$OBSERVER"
printf 'detach: "Ctrl-b d"\n'
printf 'mutation: false\n'

if [ "$ATTACH" -eq 1 ]; then
  exec tmux attach-session -t "$OBSERVER"
fi
