#!/usr/bin/env bash
# Offline test for fm-cs-relay.sh demux logic, simulating the remote event stream
# with a local tail -F (no codespace auth). Run: test/cs-relay-test.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null' EXIT
export FM_STATE_OVERRIDE="$TMP/state"
mkdir -p "$FM_STATE_OVERRIDE"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: expected [$3] got [$2]"; fi; }

# --- 1. pure demux via stdin (deterministic) ---
printf 'working: cloning\nworking: building\nTURN-ENDED\ndone: PR ready\n' \
  | "$ROOT/bin/fm-cs-relay.sh" --demux task-a
ok "status lines"   "$(wc -l < "$FM_STATE_OVERRIDE/task-a.status" | tr -d ' ')" "3"
ok "first status"   "$(head -1 "$FM_STATE_OVERRIDE/task-a.status")" "working: cloning"
ok "last status"    "$(tail -1 "$FM_STATE_OVERRIDE/task-a.status")" "done: PR ready"
ok "turn-end file"  "$([ -f "$FM_STATE_OVERRIDE/task-a.turn-ended" ] && echo yes)" "yes"
ok "blank skipped"  "$(grep -c '^$' "$FM_STATE_OVERRIDE/task-a.status"; true)" "0"

# --- 2. live-style streaming via injected source command (tail -F a local file) ---
EVENTS="$TMP/remote-events"
: > "$EVENTS"
export FM_CS_RELAY_SOURCE_CMD="tail -n +1 -F '$EVENTS' 2>/dev/null"
"$ROOT/bin/fm-cs-relay.sh" task-b dummy-cs >/dev/null 2>&1 &
RELAY_PID=$!
sleep 0.5
printf 'working: started\n' >> "$EVENTS"
printf 'TURN-ENDED\n' >> "$EVENTS"
# Wait (bounded) for the relay to mirror the turn-end signal.
for _ in $(seq 1 30); do
  [ -f "$FM_STATE_OVERRIDE/task-b.turn-ended" ] && break
  sleep 0.2
done
TE_BEFORE=$( { stat -c %Y "$FM_STATE_OVERRIDE/task-b.turn-ended" 2>/dev/null || stat -f %m "$FM_STATE_OVERRIDE/task-b.turn-ended"; } )
ok "live status"     "$(head -1 "$FM_STATE_OVERRIDE/task-b.status" 2>/dev/null)" "working: started"
ok "live turn-end"   "$([ -f "$FM_STATE_OVERRIDE/task-b.turn-ended" ] && echo yes)" "yes"

# a SECOND turn-end must re-touch (update mtime) so the watcher re-fires.
sleep 1.1
printf 'TURN-ENDED\n' >> "$EVENTS"
for _ in $(seq 1 30); do
  TE_AFTER=$( { stat -c %Y "$FM_STATE_OVERRIDE/task-b.turn-ended" 2>/dev/null || stat -f %m "$FM_STATE_OVERRIDE/task-b.turn-ended"; } )
  [ "$TE_AFTER" != "$TE_BEFORE" ] && break
  sleep 0.2
done
ok "turn-end retouch" "$([ "$TE_AFTER" != "$TE_BEFORE" ] && echo yes)" "yes"

kill "$RELAY_PID" 2>/dev/null; RELAY_PID=

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
