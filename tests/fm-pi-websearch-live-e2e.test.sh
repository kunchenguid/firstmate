#!/usr/bin/env bash
# tests/fm-pi-websearch-live-e2e.test.sh - opt-in proof that the installed Pi
# actually registers and calls the web_search tool.
#
# Whether pi.registerTool() produces a tool the model can call is a fact about
# the vendor's binary, not about our code, so a stub agent could only confirm
# the assumption written into the stub. This runs the REAL installed Pi with the
# real extension and reads a structural signal: an HTTP request that only the
# tool's own execution path can produce.
#
# The endpoint is a local stub, which is what makes this cheap and repeatable -
# it spends no web-search quota, and it proves the harness half regardless of
# what the upstream service is doing. The upstream half is proven separately by
# tests/fm-ollama-websearch.test.sh and docs/verification/ollama-websearch.md.
set -u

if [ "${FM_PI_WEBSEARCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_WEBSEARCH_LIVE_E2E=1 to run the live Pi web-search regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found, so the live Pi web-search regression checked nothing"
command -v python3 >/dev/null 2>&1 || fail "python3 not found for the local endpoint stub"

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
MODEL=${FM_PI_WEBSEARCH_LIVE_MODEL:-ollama/deepseek-v4-flash:cloud}
MODEL_ID=${MODEL#*/}
EXT="$ROOT/bin/fm-pi-websearch-ext.ts"
SENTINEL='SENTINEL-TITLE-XYZ'
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-websearch-live.XXXXXX")
STUB_PID=

cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

[ -f "$EXT" ] || fail "the Pi web-search extension is missing at $EXT"
pi --list-models 2>/dev/null | grep -Fq "$MODEL_ID" ||
  fail "model $MODEL is not available to the installed Pi $PI_VERSION; set FM_PI_WEBSEARCH_LIVE_MODEL to one that is"

cat > "$LAB/stub.py" <<'PY'
"""Local stand-in for the web-search endpoint, recording what the tool sent."""
import http.server, json, sys

port_file, log_path, sentinel = sys.argv[1:4]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        with open(log_path, "a") as fh:
            fh.write(self.rfile.read(length).decode("utf-8", "replace") + "\n")
        payload = json.dumps({"results": [{
            "title": sentinel,
            "url": "https://stub.test/one",
            "content": "stub result body",
        }]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PY

python3 "$LAB/stub.py" "$LAB/port" "$LAB/requests.log" "$SENTINEL" >"$LAB/stub.out" 2>&1 &
STUB_PID=$!
i=0
while [ ! -s "$LAB/port" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$LAB/port" ] || fail "the local endpoint stub never reported a port"
PORT=$(cat "$LAB/port")

# A fixture key at a caller-supplied path: the real key stays untouched, and the
# proxy's own guard only opens the localhost redirect for a non-default file.
printf 'OLLAMA_API_KEY=sk-live-e2e-fixture-0123456789\n' > "$LAB/key.env"

mkdir -p "$LAB/project"
attempt=1
while [ "$attempt" -le 2 ]; do
  (
    cd "$LAB/project" || exit 1
    FM_OLLAMA_CLOUD_ENV="$LAB/key.env" \
      FM_OLLAMA_WEBSEARCH_URL="http://127.0.0.1:$PORT/api/web_search" \
      pi --print --no-session --no-context-files --no-extensions --no-skills \
        --no-builtin-tools -e "$EXT" \
        --model "$MODEL" --thinking off \
        "Call the web_search tool with the query: firstmate probe. Then report the first result title."
  ) > "$LAB/pi.out" 2>&1
  # A model that simply declines to call a tool is worth one retry; a tool that
  # is not registered at all fails the same way twice.
  [ -s "$LAB/requests.log" ] && break
  attempt=$((attempt + 1))
done

if [ ! -s "$LAB/requests.log" ]; then
  printf -- '--- pi output ---\n%s\n' "$(cat "$LAB/pi.out")" >&2
  fail "Pi $PI_VERSION on $MODEL never executed the registered web_search tool"
fi

sent=$(head -1 "$LAB/requests.log")
case "$sent" in
  *'"query"'*'firstmate probe'*) : ;;
  *) fail "Pi $PI_VERSION called the tool but sent an unexpected request: $sent" ;;
esac
printf 'ok - Pi %s registers web_search and executes it through the proxy\n' "$PI_VERSION"

# Corroborating, model-dependent signal: the results reached the conversation.
# The request above already proves the mechanism, so a paraphrasing model is
# reported rather than failed.
if grep -Fq "$SENTINEL" "$LAB/pi.out"; then
  printf 'ok - the search results reached the model\n'
else
  printf 'ok - tool executed; model did not quote the result verbatim (not a mechanism failure)\n'
fi
