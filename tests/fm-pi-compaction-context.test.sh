#!/usr/bin/env bash
# Credential-free real-Pi regression for Firstmate's post-compaction context
# refresh. It drives the actual TUI against a local provider whose advertised
# and enforced context limits agree, and keeps every home, session, process,
# socket, and log inside one disposable lab.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || {
  echo "skip: pi not found for real local-provider compaction regression"
  exit 0
}
command -v tmux >/dev/null 2>&1 || {
  echo "skip: tmux not found for real TUI compaction regression"
  exit 0
}
command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 not found for local compaction provider"
  exit 0
}

LAB=$(fm_test_tmproot fm-pi-compaction-context)
SOCKET="fm-pi-compact-$$"
AGENT_DIR="$LAB/agent"
PORT_FILE="$LAB/provider.port"
REQUEST_LOG="$LAB/provider.requests.jsonl"
SERVER_PID=

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

cat > "$LAB/provider.py" <<'PY'
import json
import math
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, request_log = sys.argv[1:3]
context_tokens = 65536
hard_chars = context_tokens * 4
lock = threading.Lock()


def message_text(message):
    content = message.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            part.get("text", "") for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        )
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        payload = json.loads(body)
        messages = payload.get("messages", [])
        texts = [message_text(message) for message in messages]
        joined = "\n".join(texts)
        chars = len(json.dumps(messages, ensure_ascii=False, separators=(",", ":")))
        compact = "<conversation>" in joined
        over = chars > hard_chars
        record = {
            "path": self.path,
            "chars": chars,
            "compact": compact,
            "over": over,
            "auto": "AUTO_TRIGGER" in joined,
            "manual_next": "MANUAL_NEXT" in joined,
            "bounded_next": "BOUNDED_NEXT" in joined,
            "current_instructions": "AGENTS_MARKER=current" in joined,
            "truncated_refresh": "PI POST-COMPACTION REFRESH TRUNCATED FOR CONTEXT SAFETY" in joined,
        }
        with lock:
            with open(request_log, "a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, separators=(",", ":")) + "\n")
        if over:
            error = json.dumps({
                "error": {
                    "message": (
                        "This model's maximum context length is 65536 tokens. "
                        f"However, your messages resulted in approximately {math.ceil(chars / 4)} tokens."
                    ),
                    "type": "invalid_request_error",
                    "param": "messages",
                    "code": "context_length_exceeded",
                }
            }).encode()
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(error)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(error)
            return

        if compact:
            text = "## Goal\nKeep the isolated compaction test running.\n\n## Progress\nCompaction summary complete."
        elif "AUTO_NEXT" in joined:
            text = "AUTO_NEXT_OK"
        elif "AUTO_TRIGGER" in joined:
            text = "A" * 3000 + "\nAUTO_DONE"
        elif "MANUAL_NEXT" in joined:
            text = "MANUAL_NEXT_OK"
        elif "MANUAL_SEED" in joined:
            text = "M" * 3000 + "\nMANUAL_SEED_OK"
        elif "BOUNDED_NEXT" in joined:
            text = "BOUNDED_NEXT_OK"
        elif "BOUNDED_SEED" in joined:
            text = "B" * 3000 + "\nBOUNDED_SEED_OK"
        else:
            text = "OK"

        prompt_tokens = math.ceil(chars / 4)
        if "AUTO_TRIGGER" in joined and not compact:
            prompt_tokens = 65500
        completion_tokens = max(1, math.ceil(len(text) / 4))
        created = int(time.time())
        chunks = [
            {
                "id": "fm-local",
                "object": "chat.completion.chunk",
                "created": created,
                "model": "diag-model",
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}],
            },
            {
                "id": "fm-local",
                "object": "chat.completion.chunk",
                "created": created,
                "model": "diag-model",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": completion_tokens,
                    "total_tokens": prompt_tokens + completion_tokens,
                },
            },
        ]
        wire = "".join(f"data: {json.dumps(chunk, separators=(',', ':'))}\n\n" for chunk in chunks)
        wire += "data: [DONE]\n\n"
        encoded = wire.encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(len(encoded)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(encoded)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as stream:
    stream.write(str(server.server_port))
server.serve_forever()
PY

python3 "$LAB/provider.py" "$PORT_FILE" "$REQUEST_LOG" &
SERVER_PID=$!
i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 100 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "local compaction provider exited before publishing its port"
  sleep 0.05
  i=$((i + 1))
done
[ -s "$PORT_FILE" ] || fail "local compaction provider did not publish its port"
PORT=$(cat "$PORT_FILE")

mkdir -p "$AGENT_DIR"
cat > "$AGENT_DIR/models.json" <<EOF
{
  "providers": {
    "diag-mock": {
      "baseUrl": "http://127.0.0.1:$PORT/v1",
      "apiKey": "isolated-test-key",
      "api": "openai-completions",
      "models": [
        {
          "id": "diag-model",
          "name": "Isolated compaction model",
          "reasoning": false,
          "input": ["text"],
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
          "contextWindow": 65536,
          "maxTokens": 2048
        }
      ]
    }
  }
}
EOF
cat > "$AGENT_DIR/settings.json" <<'EOF'
{
  "defaultProvider": "diag-mock",
  "defaultModel": "diag-model",
  "defaultProjectTrust": "always"
}
EOF

make_project() {  # <name> <digest-bytes> <auto:on|off>
  local name=$1 digest_bytes=$2 auto=$3 project home
  project="$LAB/$name/project"
  home="$LAB/$name/home"
  mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$home/state" "$home/data" "$home/config"
  git init -q -b main "$project"
  git -C "$project" config user.email fmtest@example.invalid
  git -C "$project" config user.name fmtest
  printf '%s\n' 'AGENTS_MARKER=initial' > "$project/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$project/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$project/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$project/bin/"
  cat > "$project/bin/fm-sessionstart-run.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FM_HOME:?}/state/.test-sessionstart-sources"
printf 'CURRENT AGENTS.md - INSTRUCTION REFRESH\n'
cat '$project/AGENTS.md'
printf '\nFIRSTMATE_LARGE_DIGEST_PREFIX\n'
head -c '$digest_bytes' /dev/zero | tr '\\0' D
printf '\nFIRSTMATE_LARGE_DIGEST_SUFFIX\n'
: > "\${FM_HOME:?}/state/.test-sessionstart-complete"
SH
  for script in fm-turnend-guard.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
    cat > "$project/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$project/bin/"*.sh
  if [ "$auto" = on ]; then
    printf '%s\n' '{"compaction":{"enabled":true,"reserveTokens":1024,"keepRecentTokens":512}}' > "$project/.pi/settings.json"
  else
    printf '%s\n' '{"compaction":{"enabled":false,"reserveTokens":1024,"keepRecentTokens":512}}' > "$project/.pi/settings.json"
  fi
  git -C "$project" add -A
  git -C "$project" commit -q -m init
  printf '%s\n%s\n' "$project" "$home"
}

capture() { tmux -L "$SOCKET" capture-pane -p -t "$1" -S -500 2>/dev/null || true; }

wait_for_text() {  # <session> <text> [attempts]
  local session=$1 expected=$2 attempts=${3:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture "$session" | grep -Fq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  capture "$session" >&2
  return 1
}

send_line() {  # <session> <text>
  tmux -L "$SOCKET" send-keys -t "$1" -l "$2"
  tmux -L "$SOCKET" send-keys -t "$1" Enter
}

start_pi() {  # <session> <project> <home>
  local session=$1 project=$2 home=$3
  tmux -L "$SOCKET" new-session -d -s "$session" -c "$project" -x 220 -y 55 \
    "env PI_CODING_AGENT_DIR='$AGENT_DIR' PI_OFFLINE=1 FM_HOME='$home' FM_ROOT_OVERRIDE='$project' FM_GATE_REFUSE_BYPASS=1 pi --approve --no-context-files --no-tools -e '$project/.pi/extensions/fm-primary-turnend-guard.ts' --model diag-mock/diag-model" \
    || fail "$session: could not start isolated Pi TUI"
  i=0
  while { [ ! -s "$home/state/.pi-turnend-extension-loaded" ] || [ ! -e "$home/state/.test-sessionstart-complete" ]; } && [ "$i" -lt 240 ]; do
    sleep 0.25
    i=$((i + 1))
  done
  [ -s "$home/state/.pi-turnend-extension-loaded" ] || {
    capture "$session" >&2
    fail "$session: Firstmate extension did not load"
  }
  [ -e "$home/state/.test-sessionstart-complete" ] || {
    capture "$session" >&2
    fail "$session: Firstmate session-start digest did not finish"
  }
  sleep 0.5
}

normal_count() {
  python3 - "$REQUEST_LOG" <<'PY'
import json, sys
print(sum(1 for line in open(sys.argv[1], encoding="utf-8") if not json.loads(line)["compact"]))
PY
}

last_normal_field() {  # <field>
  python3 - "$REQUEST_LOG" "$1" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
rows = [row for row in rows if not row["compact"]]
print(json.dumps(rows[-1][sys.argv[2]]) if rows else "null")
PY
}

# Automatic threshold compaction: the refresh may rebuild local state, but it
# must not become a queued model request. The next real prompt gets the current,
# model-budgeted refresh and succeeds below the provider's hard limit.
mapfile -t auto_paths < <(make_project auto 250000 on)
auto_project=${auto_paths[0]}
auto_home=${auto_paths[1]}
start_pi auto "$auto_project" "$auto_home"
printf '%s\n' 'AGENTS_MARKER=current' > "$auto_project/AGENTS.md"
send_line auto AUTO_TRIGGER
wait_for_text auto AUTO_DONE || fail "auto: initial provider turn did not finish"
wait_for_text auto 'Compacted from' || fail "auto: Pi did not complete threshold compaction"
sleep 1
[ "$(normal_count)" -eq 1 ] || fail "auto: post-compaction refresh caused a model request without a new prompt"
send_line auto AUTO_NEXT
wait_for_text auto AUTO_NEXT_OK || fail "auto: next normal prompt did not succeed"
[ "$(normal_count)" -eq 2 ] || fail "auto: unexpected number of normal provider requests after the next prompt"
auto_compactions=$(grep -Fxc -- '--source compact' "$auto_home/state/.test-sessionstart-sources" || true)
[ "$auto_compactions" -eq 1 ] || fail "auto: expected one compact event, observed $auto_compactions"
[ "$(last_normal_field current_instructions)" = true ] || fail "auto: next prompt did not receive current AGENTS.md instructions"
[ "$(last_normal_field truncated_refresh)" = true ] || fail "auto: large digest was not bounded with model-readable omission accounting"
[ "$(last_normal_field over)" = false ] || fail "auto: bounded refresh still exceeded the provider limit"
pass "real Pi automatic compaction settles once without a refresh-only request and the next prompt succeeds"
tmux -L "$SOCKET" kill-session -t auto >/dev/null 2>&1 || true

# Manual /compact is submitted once. Success must not hide a persistent refill:
# no provider request occurs until MANUAL_NEXT, which then succeeds with current
# instructions and the same bounded large-digest marker.
: > "$REQUEST_LOG"
mapfile -t manual_paths < <(make_project manual 250000 off)
manual_project=${manual_paths[0]}
manual_home=${manual_paths[1]}
start_pi manual "$manual_project" "$manual_home"
send_line manual MANUAL_SEED
wait_for_text manual MANUAL_SEED_OK || fail "manual: seed turn did not finish"
printf '%s\n' 'AGENTS_MARKER=current' > "$manual_project/AGENTS.md"
send_line manual /compact
wait_for_text manual 'Compacted from' || fail "manual: one /compact submission did not complete"
sleep 1
[ "$(normal_count)" -eq 1 ] || fail "manual: compact refresh triggered an unexpected model request"
send_line manual MANUAL_NEXT
wait_for_text manual MANUAL_NEXT_OK || fail "manual: next prompt failed after a reported successful compaction"
[ "$(normal_count)" -eq 2 ] || fail "manual: unexpected number of normal provider requests"
[ "$(last_normal_field current_instructions)" = true ] || fail "manual: next prompt retained stale instructions"
[ "$(last_normal_field truncated_refresh)" = true ] || fail "manual: oversized refresh lacked omission accounting"
[ "$(last_normal_field over)" = false ] || fail "manual: next prompt exceeded the hard provider limit"
pass "real Pi manual /compact submits once, leaves headroom, refreshes instructions, and permits the next prompt"
tmux -L "$SOCKET" kill-session -t manual >/dev/null 2>&1 || true

# Bounded control: a small digest remains complete rather than taking the
# truncation path, and still survives a real manual compaction.
: > "$REQUEST_LOG"
mapfile -t bounded_paths < <(make_project bounded 50000 off)
bounded_project=${bounded_paths[0]}
bounded_home=${bounded_paths[1]}
start_pi bounded "$bounded_project" "$bounded_home"
send_line bounded BOUNDED_SEED
wait_for_text bounded BOUNDED_SEED_OK || fail "bounded: seed turn did not finish"
printf '%s\n' 'AGENTS_MARKER=current' > "$bounded_project/AGENTS.md"
send_line bounded /compact
wait_for_text bounded 'Compacted from' || fail "bounded: manual compaction did not complete"
send_line bounded BOUNDED_NEXT
wait_for_text bounded BOUNDED_NEXT_OK || fail "bounded: next prompt did not succeed"
[ "$(last_normal_field current_instructions)" = true ] || fail "bounded: current instruction refresh was absent"
[ "$(last_normal_field truncated_refresh)" = false ] || fail "bounded: small digest was truncated unnecessarily"
[ "$(last_normal_field over)" = false ] || fail "bounded: provider rejected a small refresh"
pass "real Pi bounded refresh control remains complete and below the provider limit"
tmux -L "$SOCKET" kill-session -t bounded >/dev/null 2>&1 || true

# Over-hard-limit control: the same provider rejects an actually oversized
# startup request, proving the successful cases are not using a permissive mock.
: > "$REQUEST_LOG"
mapfile -t over_paths < <(make_project over 300000 off)
over_project=${over_paths[0]}
over_home=${over_paths[1]}
start_pi over "$over_project" "$over_home"
send_line over OVER_HARD_LIMIT
wait_for_text over "maximum context length is 65536 tokens" || fail "over-limit: provider did not surface its enforced context rejection"
[ "$(last_normal_field over)" = true ] || fail "over-limit: request log did not record hard-limit enforcement"
pass "local provider hard-limit control rejects an oversized real Pi request"

pass "Pi and pi-signed share this extension path; other primary harnesses and runtime backends do not execute its compaction hook"
echo "# fm-pi-compaction-context.test.sh: all assertions passed"
