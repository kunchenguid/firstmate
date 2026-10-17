#!/usr/bin/env bash
# Exercise local Pi readiness and task-scoped shadow/outcome evidence through the executable.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work=$(fm_test_tmproot dispatch-evidence)
mkdir -p "$work/home/data/job" "$work/pi" "$work/bin"
export FM_TEST_TS_STATUS="$work/tailscale-status"
cat > "$work/bin/tailscale" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] && [ "${2:-}" = --json ] || exit 2
[ -f "$FM_TEST_TS_STATUS" ] || exit 1
cat "$FM_TEST_TS_STATUS"
SH
chmod +x "$work/bin/tailscale"
export PATH="$work/bin:$PATH"
port_file="$work/port"
mode_file="$work/mode"
cat > "$work/server.py" <<'PY'
import http.server
import json
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            if open(sys.argv[2]).read().strip() == 'redirect':
                self.send_response(302)
                self.send_header('Location', 'https://example.com/health')
                self.end_headers()
                return
            body = {'status': 'loading' if open(sys.argv[2]).read().strip() == 'loading' else 'ok'}
        elif self.path == '/v1/models':
            body = {'data': [{'id': 'local-model', 'revision': 'pinned-revision', 'context_length': 32768}]}
        else:
            self.send_error(404)
            return
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        if self.path != '/v1/chat/completions':
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if request['model'] != 'local-model' or request['tool_choice']['function']['name'] != 'probe':
            self.send_error(400)
            return
        value = 'wrong' if open(sys.argv[2]).read().strip() == 'bad-tool' else 'ready'
        body = {'choices': [{'finish_reason': 'tool_calls', 'message': {'tool_calls': [{'function': {'name': 'probe', 'arguments': json.dumps({'value': value})}}]}}]}
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        pass

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as stream:
    stream.write(str(server.server_port))
server.serve_forever()
PY
: > "$mode_file"
python3 "$work/server.py" "$port_file" "$mode_file" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 1 50); do
  [ -s "$port_file" ] && break
  sleep 0.1
done
[ -s "$port_file" ] || fail 'test endpoint did not start'
port=$(cat "$port_file")
base="http://127.0.0.1:$port/v1"
cat > "$work/pi/models.json" <<JSON
{"providers":{"local":{"baseUrl":"$base","api":"openai-completions","models":[{"id":"local-model","contextWindow":32768,"maxTokens":8192}]}}}
JSON

check=$(FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" --expected-url "$base")
printf '%s' "$check" | jq -e '.selector == "local/local-model" and .served_model == "local-model" and .served_revision == "pinned-revision" and .served_context_window == 32768 and .tool_canary == "passed"' >/dev/null || fail 'exact local canary evidence missing'
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" --expected-url "$base" --canary >"$work/out" 2>"$work/err"; then
  fail 'optional non-canary interface remained available'
fi
printf 'loading\n' > "$mode_file"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" --expected-url "$base" >"$work/out" 2>"$work/err"; then
  fail 'loading endpoint was accepted'
fi
printf 'redirect\n' > "$mode_file"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" --expected-url "$base" >"$work/out" 2>"$work/err"; then
  fail 'redirecting endpoint was accepted'
fi
printf 'bad-tool\n' > "$mode_file"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" --expected-url "$base" >"$work/out" 2>"$work/err"; then
  fail 'incorrect tool arguments were accepted'
fi
: > "$mode_file"

sed 's/"contextWindow":32768/"contextWindow":65536/' "$work/pi/models.json" > "$work/pi/oversized.json"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/oversized.json" --expected-url "$base" >"$work/out" 2>"$work/err"; then
  fail 'catalog context larger than serving slot was accepted'
fi
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" --expected-url http://127.0.0.1:9/v1 >"$work/out" 2>"$work/err"; then
  fail 'expected URL mismatch was accepted'
fi
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/other --catalog "$work/pi/models.json" --expected-url "$base" >"$work/out" 2>"$work/err"; then
  fail 'catalog model mismatch was accepted'
fi
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/models.json" >"$work/out" 2>"$work/err"; then
  fail 'missing independent expected URL was accepted'
fi
sed "s@127.0.0.1:$port@8.8.8.8:8000@" "$work/pi/models.json" > "$work/pi/public.json"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/public.json" --expected-url http://8.8.8.8:8000/v1 >"$work/out" 2>"$work/err"; then
  fail 'public endpoint was accepted as local'
fi
tailnet_base='http://100.64.0.42:1/v1'
sed "s@127.0.0.1:$port@100.64.0.42:1@" "$work/pi/models.json" > "$work/pi/tailnet.json"
printf '%s\n' '{"BackendState":"Running","Peer":{"node-a":{"TailscaleIPs":["100.64.0.43"]}}}' > "$FM_TEST_TS_STATUS"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/tailnet.json" --expected-url "$tailnet_base" >"$work/out" 2>"$work/err"; then
  fail 'unlisted CGNAT address was accepted as a Tailnet peer'
fi
grep -Fq 'not a verified Tailnet peer' "$work/err" || fail 'unlisted CGNAT address did not fail at identity proof'
printf '%s\n' '{"BackendState":"Running","Peer":{"node-a":{"TailscaleIPs":["100.64.0.42"]}}}' > "$FM_TEST_TS_STATUS"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/tailnet.json" --expected-url "$tailnet_base" >"$work/out" 2>"$work/err"; then
  fail 'unreachable verified peer was accepted as ready'
fi
grep -Fq 'local endpoint unavailable' "$work/err" || fail 'verified peer did not proceed to endpoint health'
rm "$FM_TEST_TS_STATUS"
if FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" check-local local/local-model --catalog "$work/pi/tailnet.json" --expected-url "$tailnet_base" >"$work/out" 2>"$work/err"; then
  fail 'unavailable Tailnet proof was accepted'
fi
grep -Fq 'cannot verify local endpoint as a Tailnet peer' "$work/err" || fail 'unavailable proof did not fail closed'

printf '%s\n' '{"task_class":"bounded coding","proposed":"local/local-model","selected":"codex/gpt","confidence":0.9}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record job shadow >/dev/null
printf '%s\n' '{"run_id":"trial-1","task_class":"bounded coding","provider":"local","model":"local-model","accepted":true,"elapsed_seconds":30,"interventions":0,"rework_minutes":0,"input_tokens":1000,"output_tokens":200,"ttft_seconds":1.5,"decode_tps":20,"cloud_egress":false,"head":"abc123"}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record job outcome >/dev/null
jq -s -e 'length == 2 and .[0].kind == "shadow" and .[1].kind == "outcome" and .[1].head == "abc123" and .[1].decode_tps == 20 and .[1].cloud_egress == false' "$work/home/data/job/dispatch-evidence.jsonl" >/dev/null || fail 'dispatch evidence rows missing'
mkdir -p "$work/home/data/Fix.1" "$work/home/escape"
printf '%s\n' '{"task_class":"bounded coding","proposed":"local/local-model","selected":"codex/gpt"}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record Fix.1 shadow >/dev/null
printf '%s\n' '{"run_id":"trial-2","task_class":"bounded coding","provider":"local","model":"local-model","accepted":true,"elapsed_seconds":30,"interventions":0,"rework_minutes":0}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record Fix.1 outcome >/dev/null
jq -s -e 'length == 2 and all(.[]; .task == "Fix.1") and .[0].kind == "shadow" and .[1].kind == "outcome"' "$work/home/data/Fix.1/dispatch-evidence.jsonl" >/dev/null || fail 'valid mixed-case task evidence missing'
if printf '%s\n' '{"task_class":"bounded coding","proposed":"local/local-model","selected":"codex/gpt"}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record ../escape shadow >"$work/out" 2>"$work/err"; then
  fail 'unsafe task id was accepted'
fi
[ ! -e "$work/home/escape/dispatch-evidence.jsonl" ] || fail 'unsafe task id wrote outside the task directory'
if printf '%s\n' '{"task_class":"x","proposed":"x","selected":"y","prompt":"secret"}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record job shadow >"$work/out" 2>"$work/err"; then
  fail 'free-form prompt was accepted into evidence'
fi
[ "$(wc -l < "$work/home/data/job/dispatch-evidence.jsonl" | tr -d ' ')" = 2 ] || fail 'invalid row changed durable evidence'
if printf '%s\n' '{"run_id":"trial-2","task_class":"bounded coding","provider":"local","model":"local-model","accepted":true,"elapsed_seconds":NaN,"interventions":0,"rework_minutes":0}' \
  | FM_HOME="$work/home" "$ROOT/bin/fm-dispatch-evidence.sh" record job outcome >"$work/out" 2>"$work/err"; then
  fail 'nonfinite duration was accepted into evidence'
fi
[ "$(wc -l < "$work/home/data/job/dispatch-evidence.jsonl" | tr -d ' ')" = 2 ] || fail 'nonfinite row changed durable evidence'
pass 'dispatch evidence checks exact local Pi identity and records bounded rows'
