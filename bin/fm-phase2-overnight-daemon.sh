#!/usr/bin/env bash
# Overnight / AFK Phase 2 controller: poll for done crews, auto-continue, recover stale.
# Usage: fm-phase2-overnight-daemon.sh [--programme <id>] [--interval 45]
# Stop: touch state/.phase2-overnight.stop  OR  systemctl --user stop firstmate-phase2-overnight.service
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"

PROGRAMME="${FM_PHASE2_PROGRAMME:-overnight-gallery}"
INTERVAL="${FM_PHASE2_OVERNIGHT_INTERVAL:-45}"
while [ $# -gt 0 ]; do
  case "$1" in
    --programme) PROGRAMME="${2:?}"; shift 2 ;;
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    *) shift ;;
  esac
done

STATE="$FM_HOME/state"
STOP="$STATE/.phase2-overnight.stop"
LOG="$STATE/.phase2-overnight.log"
PIDFILE="$STATE/.phase2-overnight.pid"
mkdir -p "$STATE"
rm -f "$STOP"
echo $$ > "$PIDFILE"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "overnight-daemon start programme=$PROGRAMME interval=$INTERVAL pid=$$"

# Ensure AFK marker so primary can sleep; daemon owns routine wakes when AFK mode is on
if [ ! -f "$STATE/.afk" ]; then
  date -Is > "$STATE/.afk"
  log "wrote state/.afk (away mode marker)"
fi

cleanup() {
  log "overnight-daemon stop"
  rm -f "$PIDFILE"
}
trap cleanup EXIT

while [ ! -f "$STOP" ]; do
  "$FM_HOME/bin/fm-phase2-heartbeat.sh" scan --recover >>"$LOG" 2>&1 || true
  "$FM_HOME/bin/fm-phase2-continue.sh" --programme "$PROGRAMME" >>"$LOG" 2>&1 || true

  # If nothing ready/assigned/implementing, note idle (do not exit — captain may add tasks)
  snap=$("$FM_HOME/bin/fm-phase2-registry.sh" snapshot --programme "$PROGRAMME" 2>/dev/null || echo '{}')
  python3 -c "
import json,sys
s=json.loads(sys.argv[1])
active=[t for t in s.get('tasks') or [] if t.get('status') in
  {'ready','assigned','implementing','awaiting_tests','awaiting_review','awaiting_ci','changes_requested'}]
print(len(active))
" "$snap" >/dev/null

  sleep "$INTERVAL"
done

log "stop file seen; exiting"
