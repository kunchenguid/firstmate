#!/usr/bin/env bash
# Herdr tracking pane for one cloud-placed crewmate.
#
# The crewmate itself runs on an elastic Azure worker; this process is the
# local endpoint that keeps it visible and reapable in the same Herdr
# workspace as local crewmates. It renders the durable lifecycle state
# (queue/assignment from the worker controller, then the bounded execute log)
# and exits when the digest-bound result lands, so the pane's lifetime tracks
# the crewmate's remote lifetime instead of ending at spawn time.
#
# Convergence duty: when the spawn-time reconcile left the request queued
# (transient admission evidence), a LATER reconcile assigns the worker after
# the spawn process is gone. This monitor is the surviving local owner, so on
# seeing status=assigned it dispatches the persisted entrypoint through the
# same bounded execute the spawn would have run. The dispatch marker file is
# claimed with O_EXCL and shared with fm-spawn.sh, so exactly one owner
# dispatches at a time; a claim whose bounded execute is provably over (marker
# older than the wall plus slack) with no result is reclaimed, which is safe
# because the lifecycle execute is digest-idempotent.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ID=${1:?task id}
GENERATION=${2:?task generation id}
FM_HOME=${FM_HOME:?FM_HOME is required}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONTROLLER=$STATE/azure-workers/controller.json
RESULT=$STATE/$ID.worker-result.json
EXEC_LOG=$STATE/$ID.worker-execute.log
ENTRYPOINT=$STATE/$ID.cloud-entrypoint
CLOUD_ENV=$STATE/$ID.cloud-env
DISPATCH_MARKER=$STATE/$ID.cloud-execute-dispatched
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

assignment_generation() {
  python3 - "$CONTROLLER" "$ID" "$GENERATION" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
if item.get("status") == "assigned" and item.get("assignment_generation"):
    print(item["assignment_generation"])
PY
}

persisted_wall_seconds() {
  local wall
  wall=$(sed -n 's/^export FM_SPAWN_CLOUD_WALL_SECONDS=//p' "$CLOUD_ENV" 2>/dev/null | head -1)
  case "$wall" in ''|*[!0-9]*) wall=3600 ;; esac
  printf '%s\n' "$wall"
}

reclaim_stale_dispatch() {
  # A held marker with no result after the bounded wall (plus slack) means
  # the claimed execute died, was refused, or the host rebooted mid-flight.
  # The lifecycle execute is digest-idempotent, so releasing the claim and
  # letting the next iteration redispatch is safe; a still-running execute
  # inside its wall is never touched.
  local mtime now wall
  [ -f "$DISPATCH_MARKER" ] || return 0
  [ ! -s "$RESULT" ] || return 0
  mtime=$(stat -f %m "$DISPATCH_MARKER" 2>/dev/null || stat -c %Y "$DISPATCH_MARKER" 2>/dev/null) || return 0
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  wall=$(persisted_wall_seconds)
  [ $((now - mtime)) -gt $((wall + 300)) ] || return 0
  echo "cloud-crewmate $ID: dispatch claim is stale (no result after its bounded wall); reclaiming"
  rm -f "$DISPATCH_MARKER"
}

dispatch_converged_execute() {
  # Claim first (O_EXCL): if the spawn process already dispatched, or a prior
  # monitor iteration did, stand down. The whole dispatch runs in a subshell
  # so the sourced persisted environment never leaks into the monitor loop.
  local assignment
  (set -C; : > "$DISPATCH_MARKER") 2>/dev/null || return 0
  assignment=$(assignment_generation) || assignment=
  if [ -z "$assignment" ]; then
    rm -f "$DISPATCH_MARKER"
    return 0
  fi
  (
    entry=$(cat "$ENTRYPOINT" 2>/dev/null) || entry=
    if [ -z "$entry" ]; then
      echo "cloud-crewmate $ID: assigned but the persisted entrypoint is empty; not dispatching"
      rm -f "$DISPATCH_MARKER"
      exit 0
    fi
    # The persisted environment carries the allowlisted FM_AZURE_* identity
    # (and optional provider-command override) the spawn ran with; the Herdr
    # server's closed pane environment has neither.
    # shellcheck source=/dev/null
    . "$CLOUD_ENV" 2>/dev/null || true
    wall=${FM_SPAWN_CLOUD_WALL_SECONDS:-3600}
    case "$wall" in ''|*[!0-9]*) wall=3600 ;; esac
    echo "cloud-crewmate $ID: reconcile converged assignment $assignment; dispatching bounded execute"
    payload_args=()
    if [ -d "$STATE/$ID.cloud-payload" ] && [ -d "$STATE/$ID.cloud-account" ]; then
      payload_args=(--payload-dir "$STATE/$ID.cloud-payload" --account-dir "$STATE/$ID.cloud-account")
    fi
    nohup env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-worker-lifecycle.sh" execute \
      --task "$ID" --task-generation "$GENERATION" \
      --assignment-generation "$assignment" --wall-seconds "$wall" \
      ${payload_args[@]+"${payload_args[@]}"} \
      --confirm-execute --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" \
      -- /bin/bash -lc "$entry" \
      > "$RESULT" 2> "$EXEC_LOG" < /dev/null &
  )
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
  if [ "$status" = assigned ]; then
    reclaim_stale_dispatch
    if [ ! -f "$DISPATCH_MARKER" ] && [ -f "$ENTRYPOINT" ] && [ -f "$CLOUD_ENV" ]; then
      dispatch_converged_execute
    fi
  fi
  if [ -f "$EXEC_LOG" ]; then
    size=$(wc -c < "$EXEC_LOG" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -lt "$shown_bytes" ]; then
      # A redispatch truncated the log; start rendering it from the top.
      shown_bytes=0
    fi
    if [ "$size" -gt "$shown_bytes" ]; then
      tail -c +"$((shown_bytes + 1))" "$EXEC_LOG" 2>/dev/null
      shown_bytes=$size
    fi
  fi
  sleep "$INTERVAL"
done
