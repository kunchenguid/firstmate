#!/usr/bin/env bash
# fm-fleet-manager.sh - supervised manager heartbeat daemon for one fleet shard.
#
# Usage: fm-fleet-manager.sh <fleet-root> <manager-id>
#
# This process is the live authority placeholder for one FirstMate manager.
# It holds that manager's per-home lease, publishes a periodic heartbeat with
# model-wait, blocked, progress, and activity signals, and exits cleanly on
# SIGTERM so fleet status can distinguish a clean stop from a crash.
# A real reasoning FirstMate session replaces this daemon by stopping it first
# and holding the same lease; inspection-only attach never takes the lease.
# Marker files driving the heartbeat live under <home>/state and are owned by
# bin/fm-fleet.sh: .fleet-wait (model/provider wait), .fleet-blocked (blocked
# with an optional first-line reason). bin/fm-fleet.sh owns the registry and
# status derivation; this file owns only lease holding and heartbeat writes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  echo "usage: fm-fleet-manager.sh <fleet-root> <manager-id>" >&2
}

[ $# -eq 2 ] || { usage; exit 2; }
FLEET_ROOT=$1
MANAGER_ID=$2

HOME_DIR=$(python3 - "$FLEET_ROOT" "$MANAGER_ID" <<'PY'
import json, sys
root, mid = sys.argv[1], sys.argv[2]
with open(root.rstrip("/") + "/fleet.json") as fh:
    reg = json.load(fh)
for mgr in reg.get("managers", []):
    if mgr.get("id") == mid:
        print(mgr.get("home", ""))
        break
PY
) || { echo "fm-fleet-manager: cannot read registry $FLEET_ROOT/fleet.json" >&2; exit 1; }
[ -n "$HOME_DIR" ] || { echo "fm-fleet-manager: unknown manager $MANAGER_ID" >&2; exit 1; }

# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_ROOT/bin/fm-session-lock-lib.sh"

STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" 2>/dev/null || {
  echo "fm-fleet-manager: cannot create home directories under $HOME_DIR" >&2
  exit 1
}

LEASE="$STATE/.fleet-lease"
PIDFILE="$STATE/.fleet-manager.pid"
HEARTBEAT="$STATE/.fleet-heartbeat.json"
LOG="$STATE/.fleet-manager.log"
POLL="${FM_FLEET_POLL:-2}"

is_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null || true)
  if is_alive "$old"; then
    echo "fm-fleet-manager: duplicate live authority for $MANAGER_ID (pid $old); refusing" >&2
    exit 1
  fi
fi

LOCK_STATUS=$(FM_HOME="$HOME_DIR" "$FM_ROOT/bin/fm-lock.sh" status 2>/dev/null || true)
case "$LOCK_STATUS" in
  "lock: held by live"*)
    echo "fm-fleet-manager: $HOME_DIR session lock is held by a live session; refusing" >&2
    exit 1
    ;;
esac

case "${FM_FLEET_POLL:-2}" in
  ''|*[!0-9]*)
    echo "fm-fleet-manager: invalid FM_FLEET_POLL ${FM_FLEET_POLL:-2}; want a positive integer" >&2
    exit 1
    ;;
esac

STARTUP_LOCK="$STATE/.fleet-manager.startup.d"
if ! mkdir "$STARTUP_LOCK" 2>/dev/null; then
  echo "fm-fleet-manager: another $MANAGER_ID startup is in progress; refusing" >&2
  exit 1
fi

ME=$$
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$ME" > "$PIDFILE" 2>/dev/null || {
  echo "fm-fleet-manager: cannot write pidfile $PIDFILE" >&2
  rmdir "$STARTUP_LOCK" 2>/dev/null || true
  exit 1
}
python3 - "$LEASE" "$MANAGER_ID" "$ME" "$STARTED" <<'PY'
import json, sys
path, mid, pid, started = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(path, "w") as fh:
    json.dump({"manager_id": mid, "pid": pid, "started_at": started}, fh)
PY
rmdir "$STARTUP_LOCK" 2>/dev/null || true

printf 'fm-fleet manager %s: running (home %s, pid %s, poll %ss). Tab shell execed into this loop; no shell remains, any prompt above is pre-start scrollback.\n' "$MANAGER_ID" "$HOME_DIR" "$ME" "${FM_FLEET_POLL:-2}"

write_heartbeat() {
  local hint=$1
  local wait=0 blocked=0 reason=""
  [ -f "$STATE/.fleet-wait" ] && wait=1
  if [ -f "$STATE/.fleet-blocked" ]; then
    blocked=1
    reason=$(head -n 1 "$STATE/.fleet-blocked" 2>/dev/null || true)
  fi
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 - "$HEARTBEAT" "$STATE/.fleet-progress.json" "$MANAGER_ID" "$HOME_DIR" "$ME" "$STARTED" "$now" "$wait" "$blocked" "$reason" "$hint" <<'PY'
import json, os, sys
(path, prog_path, mid, home, pid, started, now,
 wait, blocked, reason, hint) = sys.argv[1:12]
prior = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            prior = json.load(fh)
    except (OSError, ValueError):
        prior = {}
marked = {}
if os.path.exists(prog_path):
    try:
        with open(prog_path) as fh:
            marked = json.load(fh)
    except (OSError, ValueError):
        marked = {}
doc = {
    "manager_id": mid, "home": home, "pid": int(pid),
    "started_at": started, "updated_at": now,
    "last_progress": marked.get("last_progress") or prior.get("last_progress") or started,
    "active_tasks": marked.get("active_tasks", prior.get("active_tasks", 0)),
    "last_note": marked.get("last_note", prior.get("last_note", "")),
    "provider_wait": wait == "1", "blocked": blocked == "1",
    "blocked_reason": reason, "state_hint": hint,
}
try:
    doc["active_tasks"] = int(doc["active_tasks"])
except (TypeError, ValueError):
    doc["active_tasks"] = 0
with open(path, "w") as fh:
    json.dump(doc, fh)
PY
}

STOPPING=0
on_term() {
  STOPPING=1
}
trap on_term TERM INT HUP

write_heartbeat "running"
while [ "$STOPPING" -eq 0 ]; do
  sleep "$POLL" 2>/dev/null || true
  [ "$STOPPING" -eq 0 ] || break
  lp=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lp" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$lp" != "$ME" ] && fm_harness_pid_alive "$lp" 2>/dev/null; then
        echo "fm-fleet-manager: live session $lp holds $HOME_DIR; yielding" >> "$LOG" 2>/dev/null || true
        break
      fi
      ;;
  esac
  write_heartbeat "running" || echo "fm-fleet-manager: heartbeat write failed for $MANAGER_ID" >> "$LOG" 2>/dev/null || true
done

write_heartbeat "stopped" 2>/dev/null || true
rm -f "$PIDFILE" 2>/dev/null || true
exit 0
