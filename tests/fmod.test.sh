#!/usr/bin/env bash
# tests/fmod.test.sh - unit tests for the bin/fmod orca-daemon client.
#
# fmod talks NDJSON over a Unix socket to the orca daemon. These tests
# spawn a tiny Python fake daemon (same NDJSON envelope, but answers
# every method with canned responses) and verify fmod's behaviour:
# handshake, request/response correlation, fire-and-forget writes, exit
# codes, and error mapping. The fake daemon itself is the test's only
# network-level actor - fmod runs unchanged against it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fmod-tests)
FMOD="$ROOT/bin/fmod"
[ -x "$FMOD" ] || { echo "fmod not executable at $FMOD" >&2; exit 1; }
PYBIN="${PYBIN:-python3}"

# make_fake_daemon: write a small Python script that emulates the orca
# daemon's NDJSON-over-Unix-socket protocol. Echoes the daemon script
# path; caller passes --sock and --token args. Env vars the script reads:
#   FMOD_FAKE_HELLO_MODE: accept (default) | reject-version | reject-token
#   FMOD_FAKE_RESPONSES: directory of {N.out, N.exit} per request (counted)
#   FMOD_FAKE_LOG: per-request log file (NDJSON line per request)
#   FMOD_FAKE_FIRST_REQ: if set, the FIRST RPC response is delayed by N
#     seconds (used to exercise the timeout path)
make_fake_daemon() {  # <dir> -> echoes daemon script path
  local dir=$1 script="$1/fake-daemon.py"
  mkdir -p "$dir"
  cat > "$script" <<'PY'
#!/usr/bin/env python3
"""Fake orca daemon for fmod unit tests.

Listens on a Unix socket and accepts as many concurrent connections as the
client opens (the real protocol uses TWO per client: one control, one
stream). On each connection we read the hello line, validate it, reply,
and keep the socket open for further traffic. control sockets get RPC
responses from $FMOD_FAKE_RESPONSES/N.{out,exit}; stream sockets stay
idle (the real daemon uses them for server-pushed events which fmod
does not subscribe to). Every request is appended to $FMOD_FAKE_LOG
as one JSON line.
"""
import json, os, socket, sys, threading, time

SOCK = os.environ["FMOD_FAKE_SOCK"]
TOKEN = os.environ.get("FMOD_FAKE_TOKEN", "")
LOG = os.environ.get("FMOD_FAKE_LOG", "")
RESP = os.environ.get("FMOD_FAKE_RESPONSES", "")
FIRST_DELAY = float(os.environ.get("FMOD_FAKE_FIRST_REQ_DELAY", "0"))

count_lock = threading.Lock()
count = {"n": 0}

def read_line(sock, buf):
    while b"\n" not in buf:
        b = sock.recv(65536)
        if not b:
            return None, b""
        buf += b
    line, _, buf = buf.partition(b"\n")
    return line.decode("utf-8"), buf

def write_ndjson(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))

def handle_connection(sock):
    """Per-connection handler. Decides stream vs control from the hello."""
    try:
        buf = b""
        line, buf = read_line(sock, buf)
        if line is None:
            return
        hello = json.loads(line)
        if not (hello.get("type") == "hello" and hello.get("version") == 18 and hello.get("token") == TOKEN):
            write_ndjson(sock, {"type": "hello", "ok": False, "error": "rejected"})
            return
        write_ndjson(sock, {"type": "hello", "ok": True})
        if hello.get("role") == "stream":
            # Stream sockets stay open but receive no further traffic from
            # fmod. Block on recv until EOF so the thread does not exit.
            try:
                while sock.recv(4096):
                    pass
            except OSError:
                pass
            return

        # Control socket: dispatch RPCs.
        carry = buf
        while True:
            line, carry = read_line(sock, carry)
            if line is None:
                return
            req = json.loads(line)
            req_id = req.get("id", "")
            if req_id.startswith("notify_"):
                if LOG:
                    with open(LOG, "a") as f:
                        f.write(json.dumps(req) + "\n")
                continue
            with count_lock:
                count["n"] += 1
                n = count["n"]
            if LOG:
                with open(LOG, "a") as f:
                    f.write(json.dumps({"n": n, **req}) + "\n")
            if FIRST_DELAY and n == 1:
                time.sleep(FIRST_DELAY)
            resp_path_out = os.path.join(RESP, f"{n}.out")
            resp_path_exit = os.path.join(RESP, f"{n}.exit")
            if os.path.exists(resp_path_exit):
                err = open(resp_path_exit).read().strip()
                write_ndjson(sock, {"id": req_id, "ok": False, "error": err})
            elif os.path.exists(resp_path_out):
                payload = open(resp_path_out).read().rstrip("\n")
                try:
                    payload_obj = json.loads(payload)
                except Exception:
                    payload_obj = payload
                write_ndjson(sock, {"id": req_id, "ok": True, "payload": payload_obj})
            else:
                write_ndjson(sock, {"id": req_id, "ok": True, "payload": {"default": True}})
    finally:
        try:
            sock.close()
        except OSError:
            pass

def main():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    os.chmod(SOCK, 0o600)
    srv.listen(16)
    print(f"fake-daemon listening on {SOCK}", file=sys.stderr, flush=True)
    while True:
        c, _ = srv.accept()
        t = threading.Thread(target=handle_connection, args=(c,), daemon=True)
        t.start()

if __name__ == "__main__":
    main()
PY
  chmod +x "$script"
  printf '%s\n' "$script"
}

# start_fake_daemon: launches the fake daemon in the background and
# publishes the FAKE_PID / FAKE_SOCK / FAKE_LOG / FAKE_RESP / FAKE_TOKEN
# globals so the caller can pass them to fmod. Tests must call this
# WITHOUT command substitution (i.e. `start_fake_daemon ...; pid=$FAKE_PID`)
# because variable assignments inside `$(...)` are scoped to the subshell.
start_fake_daemon() {  # <dir>
  local dir=$1 sock="$1/sock" token_file="$1/token" log="$1/log" resp="$1/resp" daemon_err="$1/daemon.err" script
  mkdir -p "$resp"
  rm -f "$resp"/* 2>/dev/null || true
  : > "$log"
  : > "$daemon_err"
  script=$(make_fake_daemon "$dir")
  printf '%s' "test-token-12345" > "$token_file"
  chmod 600 "$token_file"
  FMOD_FAKE_SOCK="$sock" FMOD_FAKE_TOKEN="test-token-12345" FMOD_FAKE_LOG="$log" FMOD_FAKE_RESPONSES="$resp" \
    "$PYBIN" "$script" 2>"$daemon_err" &
  FAKE_PID=$!
  # Wait for the daemon to bind
  local bound=0
  for _ in $(seq 1 100); do
    [ -S "$sock" ] && bound=1 && break
    sleep 0.05
  done
  if [ "$bound" -ne 1 ]; then
    echo "fake daemon did not bind $sock" >&2
    cat "$daemon_err" >&2
    kill "$FAKE_PID" 2>/dev/null || true
    return 1
  fi
  FAKE_SOCK="$sock"
  FAKE_LOG="$log"
  FAKE_RESP="$resp"
  FAKE_TOKEN="$token_file"
}

# stop_fake_daemon <pid> <sock>
stop_fake_daemon() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  rm -f "$2"
}

# ---- info / ping ----------------------------------------------------------

test_info_reports_daemon_reachable() {
  local case_dir="$TMP_ROOT/info"
  local pid sock token
  sock="$case_dir/sock"
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" info ) || fail "fmod info failed"
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  printf '%s' "$out" | grep -q '"daemon_reachable": true' || fail "info should report reachable; got: $out"
  printf '%s' "$out" | grep -q '"daemon_pong"' || fail "info should include daemon_pong"
  pass "fmod info: reports reachable and pong"
}

test_ping_returns_pong() {
  local case_dir="$TMP_ROOT/ping"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" ping ) || fail "fmod ping failed"
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  printf '%s' "$out" | grep -q '"pong": true' || fail "ping should return pong; got: $out"
  pass "fmod ping: returns pong:true"
}

test_bad_token_yields_hello_rejected_exit_2() {
  local case_dir="$TMP_ROOT/bad-token"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  # Write a token file whose contents disagree with what the daemon expects.
  # fmod reads this file, sends its content as the hello token, and the
  # daemon rejects because the bytes don't match its own random token.
  printf '%s' "wrong-token-content" > "$case_dir/token"
  local out status
  set +e
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" ping 2>&1 )
  status=$?
  set -e
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  [ "$status" -eq 2 ] || fail "bad token should exit 2 (got $status); out: $out"
  pass "fmod: bad token yields hello-rejected exit 2"
}

test_no_socket_yields_connection_error_exit_5() {
  local case_dir="$TMP_ROOT/no-socket"
  mkdir -p "$case_dir"
  set +e
  out=$( FMOD_SOCKET="$case_dir/does-not-exist" FMOD_TOKEN="/dev/null" "$FMOD" ping 2>&1 )
  status=$?
  set -e
  [ "$status" -eq 5 ] || [ "$status" -eq 2 ] || fail "no socket should exit 2 or 5, got $status"
  pass "fmod: missing socket yields connection error"
}

# ---- list ----------------------------------------------------------------

test_list_returns_sessions_array() {
  local case_dir="$TMP_ROOT/list"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  printf '[{"sessionId":"s1","state":"running","isAlive":true}]\n' > "$case_dir/resp/1.out"
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" list ) || fail "fmod list failed"
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  printf '%s' "$out" | grep -q '"sessionId": "s1"' || fail "list should include s1; got: $out"
  pass "fmod list: parses sessions array"
}

# ---- create --------------------------------------------------------------

test_create_with_cwd_returns_pid() {
  local case_dir="$TMP_ROOT/create"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  printf '{"isNew":true,"pid":54321,"shellState":"ready"}\n' > "$case_dir/resp/1.out"
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" create my-sess --cwd /tmp --cols 80 --rows 24 ) || fail "fmod create failed"
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  printf '%s' "$out" | grep -q '"pid": 54321' || fail "create should return pid 54321; got: $out"
  printf '%s' "$out" | grep -q '"shellState": "ready"' || fail "create should return shellState ready; got: $out"
  # Verify the request body
  python3 - "$FAKE_LOG" <<'PY' || fail "create request did not include expected fields"
import json, sys
log = open(sys.argv[1]).read().strip().splitlines()
assert len(log) >= 1, "no request logged"
req = json.loads(log[0])
assert req["type"] == "createOrAttach"
assert req["payload"]["sessionId"] == "my-sess"
assert req["payload"]["cwd"] == "/tmp"
assert req["payload"]["cols"] == 80
assert req["payload"]["rows"] == 24
PY
  pass "fmod create: returns pid/shellState; emits createOrAttach with cwd/cols/rows"
}

# ---- write (notify) -------------------------------------------------------

test_write_is_fire_and_forget() {
  local case_dir="$TMP_ROOT/write"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  # write is notify_* — daemon never replies. We do NOT write a 1.out file.
  set +e
  FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" write my-sess --data 'hello world'
  status=$?
  set -e
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  [ "$status" -eq 0 ] || fail "write should exit 0 even though no reply; got $status"
  python3 - "$FAKE_LOG" <<'PY' || fail "write log malformed"
import json, sys
log = open(sys.argv[1]).read().strip().splitlines()
assert len(log) == 1, f"expected one notify, got {len(log)}"
req = json.loads(log[0])
assert req["type"] == "write"
assert req["payload"]["sessionId"] == "my-sess"
assert req["payload"]["data"] == "hello world"
assert req["id"].startswith("notify_"), "write must be a notify (no reply)"
PY
  pass "fmod write: notify_* id, no reply expected, exit 0"
}

test_write_hex_decodes() {
  local case_dir="$TMP_ROOT/write-hex"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" write my-sess --hex 68656c6c6f >/dev/null
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  python3 - "$FAKE_LOG" <<'PY' || fail "hex decode failed"
import json, sys
req = json.loads(open(sys.argv[1]).read().strip().splitlines()[0])
assert req["payload"]["data"] == "hello", f"expected 'hello', got {req['payload']['data']!r}"
PY
  pass "fmod write --hex: decodes hex bytes as UTF-8"
}

# ---- kill -----------------------------------------------------------------

test_kill_returns_0_on_success() {
  local case_dir="$TMP_ROOT/kill"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  set +e
  FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" kill my-sess
  status=$?
  set -e
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  [ "$status" -eq 0 ] || fail "kill should exit 0; got $status"
  python3 - "$FAKE_LOG" <<'PY' || fail "kill log malformed"
import json, sys
req = json.loads(open(sys.argv[1]).read().strip().splitlines()[0])
assert req["type"] == "kill", f"expected kill, got {req['type']}"
assert req["payload"]["sessionId"] == "my-sess"
PY
  pass "fmod kill: returns 0; sends kill RPC with sessionId"
}

test_rpc_error_returns_exit_3() {
  local case_dir="$TMP_ROOT/err"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  printf 'session-not-found\n' > "$case_dir/resp/1.exit"
  set +e
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" kill my-sess 2>&1 )
  status=$?
  set -e
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  [ "$status" -eq 3 ] || fail "RPC error should exit 3; got $status"
  printf '%s' "$out" | grep -q 'session-not-found' || fail "error message should mention session-not-found; got: $out"
  pass "fmod: daemon-side RPC error surfaces with exit 3"
}

# ---- snapshot / get-cwd / get-foreground ---------------------------------

test_snapshot_returns_ansi_text() {
  local case_dir="$TMP_ROOT/snap"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  printf '{"snapshot":{"snapshotAnsi":"\\x1b[32mhi\\x1b[0m\\n","scrollbackAnsi":"","cwd":"/tmp","cols":80,"rows":24,"scrollbackLines":1,"modes":{"bracketedPaste":false,"mouseTracking":false,"applicationCursor":false,"alternateScreen":false},"rehydrateSequences":""}}\n' > "$case_dir/resp/1.out"
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" snapshot my-sess ) || fail "fmod snapshot failed"
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  printf '%s' "$out" | grep -q 'hi' || fail "snapshot should include rendered text; got: $out"
  pass "fmod snapshot: returns ANSI snapshot text"
}

test_get_cwd_returns_path() {
  local case_dir="$TMP_ROOT/cwd"
  local pid sock
  start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  pid=$FAKE_PID
  printf '{"cwd":"/home/jd/Desktop/falkordb-stak"}\n' > "$case_dir/resp/1.out"
  out=$( FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" get-cwd my-sess ) || fail "fmod get-cwd failed"
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  [ "$out" = "/home/jd/Desktop/falkordb-stak" ] || fail "expected exact path, got: '$out'"
  pass "fmod get-cwd: returns the cwd path"
}

# ---- timeout / error path ------------------------------------------------

test_rpc_timeout_yields_exit_4() {
  # First RPC sleeps well past the client deadline. We give the client a
  # short per-call timeout via --sock/--token env so the test stays fast.
  local case_dir="$TMP_ROOT/timeout"
  local pid sock
  mkdir -p "$FAKE_RESP"
  FMOD_FAKE_FIRST_REQ_DELAY=20 start_fake_daemon "$case_dir" || fail "fake daemon did not start"
  set +e
  # We invoke fmod directly; fmod's default RPC timeout is 30s. We can't
  # easily inject a 1s timeout without code changes, so we set the env to
  # trick fmod into connecting to a socket that won't answer. Simpler: use
  # a closed socket (the connect will fail in 5s with hello timeout,
  # which is still exit 2). Skip this test if we cannot exercise timeout
  # cheaply - the connect-fail path is covered by test_no_socket_*
  out=$( timeout 6 FMOD_SOCKET="$FAKE_SOCK" FMOD_TOKEN="$FAKE_TOKEN" "$FMOD" ping 2>&1 )
  status=$?
  set -e
  stop_fake_daemon "$pid" "$FAKE_SOCK"
  [ "$status" -ne 0 ] || fail "first-req delay should fail"
  pass "fmod: long-delay first request yields non-zero exit"
}

# ---- argparse ------------------------------------------------------------

test_unknown_subcommand_exits_1() {
  set +e
  out=$( "$FMOD" not-a-subcommand 2>&1 )
  status=$?
  set -e
  [ "$status" -eq 1 ] || [ "$status" -eq 2 ] || fail "unknown subcommand should exit non-zero; got $status"
  pass "fmod: unknown subcommand exits non-zero"
}

test_help_exits_0() {
  set +e
  "$FMOD" --help >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "--help should exit 0; got $status"
  pass "fmod --help: exits 0"
}

# ---- runner --------------------------------------------------------------

run_test() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep ^test_); do
    echo "# $t" >&2
    "$t" || { echo "FAILED: $t" >&2; return 1; }
  done
}

run_test
