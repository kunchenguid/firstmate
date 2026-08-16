#!/usr/bin/env bash
# Herdr tracking pane for one cloud-placed crewmate.
#
# The crewmate itself runs on an elastic Azure worker; this process is the
# local endpoint that keeps it visible and reapable in the same Herdr
# workspace as local crewmates. It renders the durable lifecycle state
# (queue/assignment from the worker controller, then the bounded execute log)
# and exits when the digest-bound result lands, so the pane's lifetime tracks
# the crewmate's remote lifetime instead of ending at spawn time.
set -u

ID=${1:?task id}
GENERATION=${2:?task generation id}
STATE=${FM_HOME:?FM_HOME is required}/state
CONTROLLER=$STATE/azure-workers/controller.json
RESULT=$STATE/$ID.worker-result.json
EXEC_LOG=$STATE/$ID.worker-execute.log
INTERVAL=${FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS:-30}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=30 ;; esac

queue_status() {
  python3 - "$CONTROLLER" "$ID" "$GENERATION" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    print("controller-unreadable")
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
print(item.get("status") or "unqueued")
PY
}

shown_bytes=0
while :; do
  if [ -s "$RESULT" ]; then
    echo "cloud-crewmate $ID: worker result landed"
    python3 -m json.tool "$RESULT" 2>/dev/null | head -40 || cat "$RESULT"
    exit 0
  fi
  status=$(queue_status)
  printf '%s cloud-crewmate %s worker=%s\n' "$(date -u +%H:%M:%SZ)" "$ID" "$status"
  if [ -f "$EXEC_LOG" ]; then
    size=$(wc -c < "$EXEC_LOG" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt "$shown_bytes" ]; then
      tail -c +"$((shown_bytes + 1))" "$EXEC_LOG" 2>/dev/null
      shown_bytes=$size
    fi
  fi
  sleep "$INTERVAL"
done
