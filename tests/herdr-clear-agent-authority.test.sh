#!/usr/bin/env bash
# Wire-contract tests for the fixed-method Herdr Pi authority clearer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/backends/herdr-clear-agent-authority.py"
TMP_ROOT=$(fm_test_tmproot herdr-clear-agent-authority)
SERVER_PID=
SOCKET=
CAPTURE=

cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  rm -f /tmp/fm-hca-"$$"-*.sock 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

start_server() {  # <name> <response-json>
  local name=$1 response=$2 socket capture ready server_pid
  socket="/tmp/fm-hca-$$-$name.sock"
  capture="$TMP_ROOT/$name.request"
  ready="$TMP_ROOT/$name.ready"
  python3 - "$socket" "$capture" "$ready" "$response" >/dev/null 2>&1 <<'PY' &
import os
import socket
import sys

path, capture, ready, response = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
open(ready, "w").close()
conn, _ = server.accept()
data = b""
while b"\n" not in data:
    chunk = conn.recv(65536)
    if not chunk:
        break
    data += chunk
with open(capture, "wb") as out:
    out.write(data.split(b"\n", 1)[0] + b"\n")
conn.sendall(response.encode() + b"\n")
conn.close()
server.close()
PY
  server_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.01; done
  [ -e "$ready" ] || fail "authority-clear fixture server did not start"
  SOCKET=$socket
  CAPTURE=$capture
  SERVER_PID=$server_pid
}

start_server success '{"id":"fm-clear-stale-herdr-pi-authority","result":{"type":"ok"}}'
out=$("$HELPER" "$SOCKET" w7:p2 1788784402185000); rc=$?
expect_code 0 "$rc" "the exact ok response should confirm transport"$'\n'"$out"
wait "$SERVER_PID"; SERVER_PID=
request=$(cat "$CAPTURE")
printf '%s' "$request" | jq -e '
  .id == "fm-clear-stale-herdr-pi-authority"
  and .method == "pane.clear_agent_authority"
  and .params == {pane_id:"w7:p2", source:"herdr:pi", seq:1788784402185000}
' >/dev/null || fail "authority clearer emitted any payload except the fixed pane/source request: $request"
pass "Herdr authority clearer: emits only pane.clear_agent_authority for the exact pane and herdr:pi source"

for bad in '' '-1' '01' '18446744073709551616' 'not-a-number'; do
  rc=0
  "$HELPER" "$TMP_ROOT/missing.sock" w7:p2 "$bad" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "invalid sequence '$bad' should refuse as an argument error, got $rc"
done
for pane in 'w7' 'w7:p2;touch-x' 'w7:p2/other' $'w7:p2\nother'; do
  rc=0
  "$HELPER" "$TMP_ROOT/missing.sock" "$pane" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "invalid pane '$pane' should refuse as an argument error, got $rc"
done
: > "$TMP_ROOT/not-a-socket"
rc=0
"$HELPER" "$TMP_ROOT/not-a-socket" w7:p2 1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a regular file should never be treated as a Herdr socket"
start_server symlink '{"id":"fm-clear-stale-herdr-pi-authority","result":{"type":"ok"}}'
ln -s "$SOCKET" "$TMP_ROOT/socket-link"
rc=0
"$HELPER" "$TMP_ROOT/socket-link" w7:p2 1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a symlinked socket should be refused"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=
pass "Herdr authority clearer: rejects malformed panes, sequences, regular files, and socket symlinks before transport"

start_server mismatch '{"id":"other","result":{"type":"ok"}}'
rc=0
"$HELPER" "$SOCKET" w7:p2 2 >/dev/null 2>&1 || rc=$?
wait "$SERVER_PID"; SERVER_PID=
[ "$rc" = 4 ] || fail "a mismatched response id should fail response verification, got $rc"
start_server error '{"id":"fm-clear-stale-herdr-pi-authority","error":{"code":"refused"}}'
rc=0
"$HELPER" "$SOCKET" w7:p2 3 >/dev/null 2>&1 || rc=$?
wait "$SERVER_PID"; SERVER_PID=
[ "$rc" = 4 ] || fail "a Herdr error response should fail response verification, got $rc"
pass "Herdr authority clearer: protocol errors and response-identity mismatches are never mutation proof"

# Well-formed JSON that is not an object at all. The declared exit contract is
# 0/2/3/4, so these have to be reported as malformed responses rather than
# escaping as an uncaught exception - a caller that distinguishes a transport
# failure from a protocol failure would otherwise be told neither.
n=0
for shape in '[]' '[{"id":"fm-clear-stale-herdr-pi-authority","result":{"type":"ok"}}]' '"ok"' '42' 'null' 'true'; do
  n=$((n + 1))
  start_server "nonobject-$n" "$shape"
  rc=0
  out=$("$HELPER" "$SOCKET" w7:p2 "$n" 2>&1) || rc=$?
  wait "$SERVER_PID"; SERVER_PID=
  [ "$rc" = 4 ] || fail "the non-object response $shape should fail response verification as 4, got $rc: $out"
  assert_not_contains "$out" 'Traceback' "the non-object response $shape escaped the exit contract as an exception"
done
pass "Herdr authority clearer: list, scalar, and null responses are malformed, never crashes or mutation proof"
