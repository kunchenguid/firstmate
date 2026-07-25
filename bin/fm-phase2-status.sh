#!/usr/bin/env bash
# Ops view for Phase 2.
# Usage: fm-phase2-status.sh [--watch]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

render() {
  echo "=== FirstMate Phase 2 Status ($(date -Is)) ==="
  "$FM_HOME/scripts/firstmate-resume.sh" 2>/dev/null | sed -n '1,80p'
  echo
  echo "=== Watcher / wakes ==="
  if [ -L "$FM_HOME/state/.watch.lock" ] || [ -d "$FM_HOME/state/.watch.lock" ]; then
    echo "watch.lock: present"
    cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null | awk '{print "watcher_pid:", $0}'
  else
    echo "watch.lock: absent"
  fi
  echo -n "wake-queue bytes: "; wc -c < "$FM_HOME/state/.wake-queue" 2>/dev/null || echo 0
  echo -n "events pending: "; ls "$FM_HOME/state/events" 2>/dev/null | wc -l
  echo
  echo "=== Treehouse ==="
  treehouse status 2>/dev/null | head -20 || echo "(treehouse unavailable)"
  echo
  echo "=== tmux ==="
  tmux ls 2>/dev/null || echo "(no tmux)"
}

if [ "${1:-}" = "--watch" ]; then
  while true; do clear; render; sleep 5; done
else
  render
fi
