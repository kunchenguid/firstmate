#!/usr/bin/env bash
# tests/fm-ollama-websearch.test.sh - behavior contract for the key-holding web
# search proxy that gives Pi scouts a web_search tool.
#
# The first block is the reason this feature is allowed to exist at all: the
# Ollama key must not become readable by the agent that triggers the search.
# Those cases drive the real script against a real curl and a local endpoint and
# then look for the key everywhere an agent could actually look - the script's
# stdout and stderr, its child's argument vector, its child's environment - and
# confirm the ONE channel that is supposed to carry it does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found for the local endpoint stub"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

PROXY="$ROOT/bin/fm-ollama-websearch.sh"
TMP_ROOT=$(fm_test_tmproot fm-ollama-websearch)
KEY='sk-fixture-KEYVALUE-0123456789abcdef'
# Every stub is started inside a command substitution, so its pid has to be
# recorded in a FILE: an array append would land in that subshell and die with
# it, leaving the server running after the suite exits (tests/lib.sh documents
# the same constraint for its own cleanup registry).
STUB_PIDS="$TMP_ROOT/stub.pids"
: > "$STUB_PIDS"

cleanup() {
  local pid
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$STUB_PIDS"
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

cat > "$TMP_ROOT/stub.py" <<'PY'
"""Local stand-in for the Ollama web-search endpoint.

Records every request it receives (headers and body) so a test can assert what
actually went over the wire, and replies with whatever the case asked for.
"""
import http.server, json, os, sys, threading

port_file, log_path, status, body_path = sys.argv[1:5]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        with open(log_path, "a") as fh:
            fh.write(json.dumps({
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                "header_names": sorted(k.lower() for k in self.headers.keys()),
                "body": raw,
            }) + "\n")
        payload = open(body_path, "rb").read()
        self.send_response(int(status))
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

# start_stub <case> [http-status] [response-json] -> echoes the endpoint URL.
start_stub() {
  local case_name=$1 status=${2:-200} body=${3:-} dir port_file port i=0
  dir="$TMP_ROOT/$case_name"
  mkdir -p "$dir"
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$dir/response.json"
  else
    printf '%s' '{"results":[{"title":"Result one","url":"https://example.test/one","content":"short body"}]}' \
      > "$dir/response.json"
  fi
  port_file="$dir/port"
  # Redirect the stub's own streams: this function is called through a command
  # substitution, which would otherwise wait for the long-lived server to close
  # the inherited stdout before returning the URL.
  python3 "$TMP_ROOT/stub.py" "$port_file" "$dir/requests.log" "$status" "$dir/response.json" \
    >"$dir/stub.out" 2>&1 &
  printf '%s\n' "$!" >> "$STUB_PIDS"
  while [ ! -s "$port_file" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$port_file" ] || fail "$case_name: local endpoint stub never reported a port"
  port=$(cat "$port_file")
  printf 'http://127.0.0.1:%s/api/web_search\n' "$port"
}

# write_key_file <path> [value]
write_key_file() {
  local path=$1 value=${2:-$KEY}
  mkdir -p "$(dirname "$path")"
  printf 'OLLAMA_API_KEY=%s\n' "$value" > "$path"
}

# run_search <key-file> <url> [args...] - runs the proxy with the localhost seam
# open, capturing stdout and stderr separately into RUN_OUT/RUN_ERR/RUN_CODE.
RUN_OUT=''
RUN_ERR=''
RUN_CODE=''
run_search() {
  local key_file=$1 url=$2 errfile
  shift 2
  errfile=$(mktemp "$TMP_ROOT/stderr.XXXXXX")
  set +e
  RUN_OUT=$(FM_OLLAMA_CLOUD_ENV="$key_file" FM_OLLAMA_WEBSEARCH_URL="$url" \
    "$PROXY" search "$@" 2>"$errfile")
  RUN_CODE=$?
  set -e
  RUN_ERR=$(cat "$errfile")
}

# --- the key must not become readable through this script -------------------

case_dir="$TMP_ROOT/nokeyleak"
write_key_file "$case_dir/ollama-cloud.env"
url=$(start_stub nokeyleak)
run_search "$case_dir/ollama-cloud.env" "$url" --query "leak check"
expect_code 0 "$RUN_CODE" "a search against the local endpoint should succeed"
assert_not_contains "$RUN_OUT" "$KEY" "the key must never appear on stdout"
assert_not_contains "$RUN_ERR" "$KEY" "the key must never appear on stderr"
pass "a successful search prints results without the key"

# The one channel that is SUPPOSED to carry it: the request itself. Asserting
# this keeps the no-leak cases above honest - without it they would also pass if
# the script quietly stopped authenticating at all.
recorded=$(cat "$TMP_ROOT/nokeyleak/requests.log")
assert_contains "$recorded" "Bearer $KEY" "the key must reach the endpoint as a bearer token"
assert_contains "$recorded" "application/json" "the request must be sent as JSON"
pass "the key reaches the endpoint, and only the endpoint"

# What an agent can actually inspect about a running child: its argument vector
# (ps) and its environment (ps -E). Both must be clean; stdin, which no other
# process can read, must be where the credential travels.
case_dir="$TMP_ROOT/childsurface"
mkdir -p "$case_dir"
write_key_file "$case_dir/ollama-cloud.env"
fakebin=$(fm_fakebin "$case_dir")
cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
# Stand-in curl that records every surface a concurrent process could inspect.
printf '%s\n' "\$@" > "$case_dir/argv.log"
env > "$case_dir/env.log"
cat > "$case_dir/stdin.log"
printf '%s\n200' '{"results":[]}'
SH
chmod +x "$fakebin/curl"
set +e
child_out=$(PATH="$fakebin:$PATH" FM_OLLAMA_CLOUD_ENV="$case_dir/ollama-cloud.env" \
  "$PROXY" search --query "child surface" 2>&1)
child_code=$?
set -e
expect_code 0 "$child_code" "the search should succeed against the recording curl"
assert_not_contains "$child_out" "$KEY" "the key must not surface in output"
assert_no_grep "$KEY" "$case_dir/argv.log" "the key must never be passed in a child's argument vector"
assert_no_grep "$KEY" "$case_dir/env.log" "the key must never be exported into a child's environment"
assert_grep "$KEY" "$case_dir/stdin.log" "the key must travel through the child's stdin configuration"
pass "the key is absent from the child's argv and environment, and present only on its stdin"

# A search must not leave the credential, or anything else, behind on disk.
case_dir="$TMP_ROOT/nofiles"
write_key_file "$case_dir/ollama-cloud.env"
url=$(start_stub nofiles)
private_tmp="$case_dir/tmp"
mkdir -p "$private_tmp"
TMPDIR="$private_tmp" run_search "$case_dir/ollama-cloud.env" "$url" --query "no files"
expect_code 0 "$RUN_CODE" "the search should succeed"
leftovers=$(find "$private_tmp" -mindepth 1 2>/dev/null | head -5)
[ -z "$leftovers" ] || fail "a search must write no files, found: $leftovers"
pass "a search writes nothing to disk"

# --- the real key can only ever go to Ollama --------------------------------
#
# The redirect seam exists so these tests can drive the real script against a
# real endpoint. It must be unreachable for a key that lives at a default
# location, which is where the real one lives.
case_dir="$TMP_ROOT/defaultpath"
mkdir -p "$case_dir/home"
write_key_file "$case_dir/home/Library/Application Support/firstmate/ollama-cloud.env"
url=$(start_stub defaultpath)
set +e
redirect_out=$(env -u FM_OLLAMA_CLOUD_ENV HOME="$case_dir/home" FM_OLLAMA_WEBSEARCH_URL="$url" \
  "$PROXY" search --query "redirect" 2>&1)
redirect_code=$?
set -e
expect_code 2 "$redirect_code" "a redirect must be refused for a key at a default location"
assert_contains "$redirect_out" "refused" "the refusal should say so plainly"
assert_absent "$TMP_ROOT/defaultpath/requests.log" "no request may be made when the redirect is refused"
pass "a key at a default location is never sent anywhere but Ollama"

# The same refusal applies to the explicit default path, so naming the default
# file rather than letting it be discovered is not a way around the rule.
set +e
explicit_default_msg=$(HOME="$case_dir/home" \
  FM_OLLAMA_CLOUD_ENV="$case_dir/home/Library/Application Support/firstmate/ollama-cloud.env" \
  FM_OLLAMA_WEBSEARCH_URL="$url" "$PROXY" search --query "redirect" 2>&1)
explicit_default_code=$?
set -e
expect_code 2 "$explicit_default_code" "naming the default key file must not open the redirect"
assert_contains "$explicit_default_msg" "refused" "the refusal should say so plainly"
pass "naming the default key file explicitly does not open the redirect"

# Even with a caller-supplied key file, the redirect stays on localhost, so the
# seam cannot be turned into a general credential forwarder.
case_dir="$TMP_ROOT/offhost"
write_key_file "$case_dir/ollama-cloud.env"
run_search "$case_dir/ollama-cloud.env" "https://attacker.example/api" --query "offhost"
expect_code 2 "$RUN_CODE" "an off-host redirect must be refused"
assert_contains "$RUN_ERR" "localhost" "the refusal should name the constraint"
pass "the redirect seam cannot point off the local machine"

# --- what the agent gets back -----------------------------------------------

case_dir="$TMP_ROOT/shape"
write_key_file "$case_dir/ollama-cloud.env"
url=$(start_stub shape 200 \
  '{"results":[{"title":"One","url":"https://example.test/1","content":"alpha"},{"title":"Two","url":"https://example.test/2","content":"beta"}]}')
run_search "$case_dir/ollama-cloud.env" "$url" --query "shape" --max-results 2
expect_code 0 "$RUN_CODE" "the search should succeed"
[ "$(printf '%s' "$RUN_OUT" | jq '.results | length')" = 2 ] ||
  fail "both results should be returned"
[ "$(printf '%s' "$RUN_OUT" | jq -r '.results[0].title')" = One ] ||
  fail "the result title should be preserved"
[ "$(printf '%s' "$RUN_OUT" | jq -r '.results[0].url')" = "https://example.test/1" ] ||
  fail "the result url should be preserved"
[ "$(printf '%s' "$RUN_OUT" | jq -r '.results[1].content')" = beta ] ||
  fail "the result content should be preserved"
sent=$(jq -r '.body' "$TMP_ROOT/shape/requests.log" | head -1)
[ "$(printf '%s' "$sent" | jq -r '.query')" = shape ] || fail "the query should be sent upstream"
[ "$(printf '%s' "$sent" | jq -r '.max_results')" = 2 ] || fail "max_results should be sent upstream"
pass "results come back as structured JSON and the request carries the query"

# A query is attacker-influenced text the moment a scout searches something a
# prompt injection suggested, and it is embedded in the same configuration that
# carries the key. It must survive intact and change nothing else.
case_dir="$TMP_ROOT/hostilequery"
write_key_file "$case_dir/ollama-cloud.env"
url=$(start_stub hostilequery)
hostile='say "hi" \ then header = "X-Evil: 1"'
run_search "$case_dir/ollama-cloud.env" "$url" --query "$hostile"
expect_code 0 "$RUN_CODE" "a query with quotes and backslashes should still search"
sent=$(jq -r '.body' "$TMP_ROOT/hostilequery/requests.log" | head -1)
[ "$(printf '%s' "$sent" | jq -r '.query')" = "$hostile" ] ||
  fail "the query must arrive byte-for-byte, got: $(printf '%s' "$sent" | jq -r '.query')"
# The query text legitimately contains "header = ..." as DATA; what must not
# happen is that text becoming a header of the request that carries the key.
header_names=$(jq -r '.header_names | join(",")' "$TMP_ROOT/hostilequery/requests.log" | head -1)
assert_not_contains "$header_names" "x-evil" "a query must not be able to inject a request header"
assert_contains "$header_names" "authorization" "the intended headers should still be present"
pass "a query carrying quotes and backslashes cannot rewrite the request"

# Upstream content fields are whole-page dumps, so the proxy truncates and says
# that it did. Silent truncation would let a scout quote a cut-off page as whole.
case_dir="$TMP_ROOT/truncate"
write_key_file "$case_dir/ollama-cloud.env"
long=$(printf 'x%.0s' $(seq 1 900))
url=$(start_stub truncate 200 \
  "{\"results\":[{\"title\":\"Long\",\"url\":\"https://example.test/long\",\"content\":\"$long\"},{\"title\":\"Short\",\"url\":\"https://example.test/short\",\"content\":\"tiny\"}]}")
run_search "$case_dir/ollama-cloud.env" "$url" --query "truncate" --max-chars 200
expect_code 0 "$RUN_CODE" "the search should succeed"
[ "$(printf '%s' "$RUN_OUT" | jq -r '.results[0].truncated')" = true ] ||
  fail "an over-long result must be reported as truncated"
[ "$(printf '%s' "$RUN_OUT" | jq -r '.results[1].truncated')" = false ] ||
  fail "a short result must not be reported as truncated"
kept=$(printf '%s' "$RUN_OUT" | jq -r '.results[0].content')
case "$kept" in
  *"[truncated]") : ;;
  *) fail "a truncated result should say so in its content" ;;
esac
[ "${#kept}" -lt 400 ] || fail "a truncated result should actually be shortened, got ${#kept} chars"
pass "over-long results are truncated and marked, short ones are left alone"

# --- refusals ---------------------------------------------------------------

case_dir="$TMP_ROOT/nokey"
mkdir -p "$case_dir"
set +e
nokey_out=$(FM_OLLAMA_CLOUD_ENV="$case_dir/absent.env" "$PROXY" search --query x 2>&1)
nokey_code=$?
set -e
expect_code 3 "$nokey_code" "a search without a configured key should report it, not crash"
assert_contains "$nokey_out" "no Ollama key file found" "the message should name the missing key file"

set +e
status_out=$(FM_OLLAMA_CLOUD_ENV="$case_dir/absent.env" "$PROXY" status 2>&1)
status_code=$?
set -e
expect_code 3 "$status_code" "status should report an unconfigured home with its own code"
assert_contains "$status_out" "unconfigured" "status should say the home is unconfigured"

write_key_file "$case_dir/present.env"
set +e
status_ok=$(FM_OLLAMA_CLOUD_ENV="$case_dir/present.env" "$PROXY" status 2>&1)
status_ok_code=$?
set -e
expect_code 0 "$status_ok_code" "status should succeed when a key is configured"
assert_contains "$status_ok" "configured" "status should say the home is configured"
assert_not_contains "$status_ok" "$KEY" "status must not print the key it found"
pass "status reports availability without disclosing the key"

# A key that would need escaping into curl's configuration syntax is refused
# rather than escaped, because a mis-escape there is how a credential ends up
# somewhere unintended.
write_key_file "$case_dir/hostile.env" 'abc"def with spaces'
set +e
hostile_out=$(FM_OLLAMA_CLOUD_ENV="$case_dir/hostile.env" "$PROXY" search --query x 2>&1)
hostile_code=$?
set -e
expect_code 3 "$hostile_code" "a malformed key should be refused"
assert_not_contains "$hostile_out" 'abc"def' "a refusal must not echo the malformed key back"
pass "a malformed key is refused without being echoed"

case_dir="$TMP_ROOT/upstream"
write_key_file "$case_dir/ollama-cloud.env"
url=$(start_stub unauthorized 401 '{"error":"unauthorized"}')
run_search "$case_dir/ollama-cloud.env" "$url" --query "rejected"
expect_code 4 "$RUN_CODE" "an upstream rejection should be a distinct failure"
assert_contains "$RUN_ERR" "401" "the failure should name the status"
assert_not_contains "$RUN_ERR" "$KEY" "an upstream rejection must not echo the key"

url=$(start_stub notjson 200 '<html>not json</html>')
run_search "$case_dir/ollama-cloud.env" "$url" --query "garbage"
expect_code 4 "$RUN_CODE" "a non-JSON response should fail rather than be relayed"
assert_not_contains "$RUN_OUT" "not json" "a non-JSON response must not be handed to the agent"
pass "upstream rejections and malformed responses fail loudly and quietly"

# --- argument surface -------------------------------------------------------
#
# The agent reaches this script through a tool, but nothing stops a worker from
# calling it directly, so its option surface stays closed: no pass-through to
# curl, no way to ask it to be verbose about the request it just built.
case_dir="$TMP_ROOT/args"
write_key_file "$case_dir/ollama-cloud.env"
for bad in "--verbose" "--config" "-v"; do
  set +e
  bad_out=$(FM_OLLAMA_CLOUD_ENV="$case_dir/ollama-cloud.env" "$PROXY" search --query x "$bad" 2>&1)
  bad_code=$?
  set -e
  expect_code 2 "$bad_code" "search should refuse the unknown option $bad"
  assert_contains "$bad_out" "unknown search option" "the refusal should name the option"
done

for bad in 0 11 abc ""; do
  set +e
  FM_OLLAMA_CLOUD_ENV="$case_dir/ollama-cloud.env" "$PROXY" search --query x --max-results "$bad" >/dev/null 2>&1
  bad_code=$?
  set -e
  expect_code 2 "$bad_code" "search should refuse --max-results $bad"
done

set +e
FM_OLLAMA_CLOUD_ENV="$case_dir/ollama-cloud.env" "$PROXY" search --query "" >/dev/null 2>&1
empty_code=$?
set -e
expect_code 2 "$empty_code" "search should refuse an empty query"

set +e
unknown_out=$("$PROXY" frobnicate 2>&1)
unknown_code=$?
set -e
expect_code 2 "$unknown_code" "an unknown command should be refused"
assert_contains "$unknown_out" "unknown command" "the refusal should name the command"

set +e
help_out=$(env -u FM_OLLAMA_CLOUD_ENV HOME="$TMP_ROOT/emptyhome" "$PROXY" --help 2>&1)
help_code=$?
set -e
expect_code 0 "$help_code" "--help should work on a home with no key at all"
assert_contains "$help_out" "fm-ollama-websearch.sh" "help should describe the script"
pass "the option surface is closed and help works without a key"

printf 'ok - fm-ollama-websearch behavior contract\n'
