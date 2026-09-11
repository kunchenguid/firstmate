#!/usr/bin/env bash
# Behavioral coverage for the opt-in, read-only localhost status endpoint:
# bin/fm-status-server.sh and its bin/fm_status_server.py backend.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

SERVER="$ROOT/bin/fm-status-server.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-server)
FAKE_ROOT="$TMP_ROOT/root"
FM_HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$FM_HOME_DIR/state"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SRV_PID=

mkdir -p "$FAKE_ROOT/bin" "$STATE_DIR"

cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill -KILL "$SRV_PID" >/dev/null 2>&1 || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Stub fm-crew-state.sh under the fake FM_ROOT: the server invokes it by full
# path (bin/fm-status-server.sh's own contract), never through PATH.
cat > "$FAKE_ROOT/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · fixture task %s\n' "${1:-}"
SH
chmod +x "$FAKE_ROOT/bin/fm-crew-state.sh"

# Stub quota-axi on PATH: the server invokes it by bare name.
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"schemaVersion":5,"providers":[{"provider":"fixture","windows":[]}]}\n'
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$STATE_DIR/home-summary.json" <<'JSON'
{
  "schema": "fm-secondmate-home-summary.v1",
  "hold_classifier_schema": "fm-captain-hold-buckets.v1",
  "generated": "2026-01-01T00:00:00Z",
  "generated_epoch": 1,
  "home": "/fixture/home",
  "valid": true,
  "reason": null,
  "invalidity": {"kind": null, "ids": []},
  "state": "active_child_work",
  "active_children": [{"id": "task1", "kind": "ship", "state": "working"}],
  "decisions_open": [],
  "holds": [],
  "queued": [],
  "landed": [],
  "endpoints": [],
  "counts": {"active_children": 1, "decisions_open": 0, "holds": 0, "queued": 0, "landed": 0, "endpoints": 0},
  "omitted": []
}
JSON

# A decoy secret file placed next to the ledger: the endpoint must never read
# or echo arbitrary state-dir contents, only the specific sources it names.
printf 'FM_TEST_SECRET_TOKEN=do-not-leak\n' > "$STATE_DIR/.env"

PORT=$(python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')

PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$FAKE_ROOT" \
  FM_HOME="$FM_HOME_DIR" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  "$SERVER" --port "$PORT" --interval 1 >"$TMP_ROOT/server.log" 2>&1 &
SRV_PID=$!

ready=0
for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/status"; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || fail "status server never came up (see $TMP_ROOT/server.log)"

BODY=$(curl -s "http://127.0.0.1:$PORT/status")

printf '%s' "$BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["home_summary"]["active_children"][0]["id"] == "task1", d
assert d["live_crew_state"]["task1"].startswith("state: working"), d
assert d["quota"]["providers"][0]["provider"] == "fixture", d
' || fail "/status did not combine crew-state, home-summary, and quota as expected"
pass "/status combines fm-crew-state.sh, home-summary.json, and quota-axi output"

case "$BODY" in
  *do-not-leak*) fail "/status leaked the decoy .env secret" ;;
esac
pass "/status never echoes arbitrary state-dir file contents"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/status")
[ "$STATUS" = 405 ] || fail "POST /status expected 405, got $STATUS"
pass "POST /status is refused (405, read-only)"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope")
[ "$STATUS" = 404 ] || fail "GET /nope expected 404, got $STATUS"
pass "unknown paths are refused (404)"

SSE=$(curl -s --max-time 3 -N "http://127.0.0.1:$PORT/events" | head -n 1)
case "$SSE" in
  data:*task1*) pass "GET /events streams the same combined document over SSE" ;;
  *) fail "GET /events did not stream the expected SSE payload (got: $SSE)" ;;
esac

if command -v lsof >/dev/null 2>&1; then
  LISTEN_LINE=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2)
  case "$LISTEN_LINE" in
    *"127.0.0.1:$PORT"*) pass "status server binds 127.0.0.1 only" ;;
    *) fail "status server is not listening on 127.0.0.1:$PORT (got: $LISTEN_LINE)" ;;
  esac
else
  echo "skip: lsof not found, cannot verify bind address"
fi
