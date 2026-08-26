#!/usr/bin/env bash
# Opt-in live guard for installed Hermes primary hooks and process identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

if [ "${FM_HERMES_PRIMARY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERMES_PRIMARY_LIVE_E2E=1 to test the installed Hermes primary"
  exit 0
fi

command -v hermes >/dev/null 2>&1 || fail "Hermes is not installed"
command -v script >/dev/null 2>&1 || fail "script(1) is required for the Hermes PTY smoke test"

TMP_ROOT=$(fm_test_tmproot fm-hermes-primary-live-e2e)
LIVE_ROOT="$TMP_ROOT/firstmate"
STATE=
HERMES_TEST_HOME="$TMP_ROOT/hermes-home"
TRANSCRIPT=
EVENTS="$TMP_ROOT/provider-events"
FIFO=
mkdir -p "$LIVE_ROOT/.hermes/plugins" "$HERMES_TEST_HOME/plugins"
cp "$ROOT/AGENTS.md" "$LIVE_ROOT/AGENTS.md"
cp -R "$ROOT/bin" "$LIVE_ROOT/bin"
cp -R "$ROOT/.hermes/plugins/firstmate-primary" "$LIVE_ROOT/.hermes/plugins/firstmate-primary"
git -C "$LIVE_ROOT" init -q
git -C "$LIVE_ROOT" add AGENTS.md bin .hermes/plugins/firstmate-primary
git -C "$LIVE_ROOT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
launcher_pid=
hermes_pid=
server_pid=
cleanup_pids=()

collect_process_tree() {
  local parent=$1 child
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    collect_process_tree "$child"
  done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent" '$2 == parent { print $1 }')
  cleanup_pids+=("$parent")
}

stop_live_cli() {
  local pid found=0
  { exec 3>&-; } 2>/dev/null || true
  cleanup_pids=()
  if [ -n "$launcher_pid" ]; then
    collect_process_tree "$launcher_pid"
  fi
  if [ -n "$hermes_pid" ]; then
    for pid in "${cleanup_pids[@]}"; do
      [ "$pid" != "$hermes_pid" ] || found=1
    done
    [ "$found" -eq 1 ] || cleanup_pids+=("$hermes_pid")
  fi
  if [ "${#cleanup_pids[@]}" -gt 0 ]; then
    kill -TERM "${cleanup_pids[@]}" 2>/dev/null || true
    sleep 1
    kill -KILL "${cleanup_pids[@]}" 2>/dev/null || true
  fi
  [ -z "$launcher_pid" ] || wait "$launcher_pid" 2>/dev/null || true
  launcher_pid=
  hermes_pid=
}

cleanup() {
  stop_live_cli
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

cat > "$TMP_ROOT/provider.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
events = root / "provider-events"

def record(event):
    with events.open("a", encoding="utf-8") as stream:
        stream.write(event + "\n")
        stream.flush()

def completion(handler, *, tool=False):
    if tool:
        delta = {
            "role": "assistant",
            "tool_calls": [{
                "index": 0,
                "id": "live-delegate",
                "type": "function",
                "function": {
                    "name": "delegate_task",
                    "arguments": json.dumps({"goal": "must be blocked"}),
                },
            }],
        }
        finish = "tool_calls"
    else:
        delta = {"role": "assistant", "content": "live smoke complete"}
        finish = "stop"
    chunk = {
        "id": "live-smoke",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": "live-smoke",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    body = ("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    try:
        handler.wfile.write(body)
    except BrokenPipeError:
        pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if not self.path.endswith("/models"):
            self.send_error(404)
            return
        body = json.dumps({
            "object": "list",
            "data": [{"id": "live-smoke", "object": "model", "created": 0, "owned_by": "test"}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        rendered = json.dumps(payload, ensure_ascii=False)
        messages = payload.get("messages", [])
        current = json.dumps(messages[-1], ensure_ascii=False) if messages else ""
        has_delegate = any(
            tool.get("function", {}).get("name") == "delegate_task"
            for tool in payload.get("tools", [])
        )

        if "FIRSTMATE_OP: v1 turn-end-guard:" in current:
            latest = max(
                (rendered.rfind(trigger), label)
                for trigger, label in (
                    ("LIVE_SUCCESS", "success"),
                    ("LIVE_FAILURE", "failure"),
                    ("LIVE_INTERRUPT", "interrupt"),
                )
            )[1]
            record("recovery-" + latest)
            completion(self)
            return

        if "Hermes built-in delegation is disabled in the Firstmate primary" in current:
            record("delegate-blocked")
            completion(self)
            return

        if "LIVE_SUCCESS" in current and has_delegate:
            record("delegate-request")
            completion(self, tool=True)
            return

        if "LIVE_FAILURE" in current and has_delegate:
            record("failure-request")
            chunk = {
                "id": "live-failure",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "live-smoke",
                "choices": [{
                    "index": 0,
                    "delta": {"role": "assistant", "content": ""},
                    "finish_reason": "length",
                }],
            }
            body = ("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if "LIVE_INTERRUPT" in current and has_delegate:
            record("interrupt-request")
            time.sleep(30)
            return

        completion(self)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "provider-port").write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY

python3 "$TMP_ROOT/provider.py" "$TMP_ROOT" &
server_pid=$!
i=0
while [ "$i" -lt 100 ] && [ ! -s "$TMP_ROOT/provider-port" ]; do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
[ -s "$TMP_ROOT/provider-port" ] || fail "the local no-model provider did not start"
provider_port=$(cat "$TMP_ROOT/provider-port")

ln -s "$LIVE_ROOT/.hermes/plugins/firstmate-primary" "$HERMES_TEST_HOME/plugins/firstmate-primary"
cat > "$HERMES_TEST_HOME/config.yaml" <<EOF_CONFIG
model:
  provider: lmstudio
  default: live-smoke
  base_url: http://127.0.0.1:$provider_port/v1
agent:
  api_max_retries: 1
plugins:
  enabled:
    - firstmate-primary
  disabled: []
EOF_CONFIG

(
  cd "$LIVE_ROOT" || exit 1
  HERMES_HOME="$HERMES_TEST_HOME" bin/fm-hermes-primary.sh --check >/dev/null
) || fail "the isolated Hermes primary plugin is not enabled"

start_live_cli() {
  local scenario=$1 i
  STATE="$TMP_ROOT/state-$scenario"
  TRANSCRIPT="$TMP_ROOT/hermes-$scenario.typescript"
  FIFO="$TMP_ROOT/hermes-$scenario-input"
  mkdir -p "$STATE"
  printf '%s\n' 'project=live-hermes-smoke' > "$STATE/live-worker.meta"
  mkfifo "$FIFO"
  exec 3<>"$FIFO"
  (
    cd "$LIVE_ROOT" || exit 1
    HERMES_HOME="$HERMES_TEST_HOME" FM_HOME="$LIVE_ROOT" FM_STATE_OVERRIDE="$STATE" \
      script -qefc "$LIVE_ROOT/bin/fm-hermes-primary.sh --provider lmstudio --model live-smoke" \
        "$TRANSCRIPT" < "$FIFO" >/dev/null 2>&1
  ) &
  launcher_pid=$!

  marker="$STATE/.hermes-primary-plugin-loaded"
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$marker" ]; do
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$marker" ] || {
    printf '%s\n' "Hermes transcript:" >&2
    tail -80 "$TRANSCRIPT" >&2 2>/dev/null || true
    fail "the real Hermes process did not publish its primary-plugin marker"
  }
  hermes_pid=$(sed -n '2p' "$marker")

  i=0
  while [ "$i" -lt 100 ]; do
    grep -F 'Welcome to Hermes Agent!' "$TRANSCRIPT" >/dev/null 2>&1 && break
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -F 'Welcome to Hermes Agent!' "$TRANSCRIPT" >/dev/null 2>&1 ||
    fail "the real Hermes classic prompt did not become ready"
  sleep 0.5
}

wait_for_event() {
  local expected_event=$1 label=$2 count=0
  while [ "$count" -lt 200 ]; do
    grep -Fx "$expected_event" "$EVENTS" >/dev/null 2>&1 && return 0
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 0.1
    count=$((count + 1))
  done
  printf '%s\n' "Hermes transcript:" >&2
  tail -100 "$TRANSCRIPT" >&2 2>/dev/null || true
  fail "$label"
}

start_live_cli success
version=$(sed -n '1p' "$marker")
expected=$(fm_adapter_file_version "$LIVE_ROOT/.hermes/plugins/firstmate-primary/__init__.py")
[ "$version" = "$expected" ] || fail "Hermes loaded a different primary plugin build"
case "$hermes_pid" in
  ''|*[!0-9]*) fail "Hermes primary marker has an invalid process id" ;;
esac
kill -0 "$hermes_pid" 2>/dev/null || fail "Hermes primary marker names a dead process"
args=$(ps -o args= -p "$hermes_pid" 2>/dev/null || true)
# shellcheck source=bin/fm-harness-process-lib.sh
. "$ROOT/bin/fm-harness-process-lib.sh"
fm_process_is_hermes_primary "$args" || fail "the live Hermes process does not match the primary identity contract"
printf '%s\n' "$hermes_pid" > "$STATE/.lock"
fm_adapter_loaded_marker_matches "$marker" "$expected" "$STATE/.lock" ||
  fail "Hermes marker and session-lock identity do not agree"
printf '%s\r' 'LIVE_SUCCESS: request built-in delegation' >&3
wait_for_event delegate-blocked "Hermes did not deliver pre_tool_call or block built-in delegation"
wait_for_event recovery-success "Hermes did not deliver on_session_end after a successful turn"
stop_live_cli

start_live_cli failure
printf '%s\r' 'LIVE_FAILURE: exercise provider failure finalization' >&3
wait_for_event failure-request "Hermes did not send the provider-failure probe"
wait_for_event recovery-failure "Hermes did not deliver on_session_end after a provider failure"
stop_live_cli

start_live_cli interrupt
printf '%s\r' 'LIVE_INTERRUPT: exercise interrupted finalization' >&3
wait_for_event interrupt-request "Hermes did not start the interruption probe"
printf '\003' >&3
wait_for_event recovery-interrupt "Hermes did not deliver on_session_end after an interrupted turn"

version_line=$(hermes --version | sed -n '1p')
pass "live Hermes native hooks covered tool, success, failure, and interruption paths ($version_line)"
