#!/usr/bin/env bash
# Behavior tests for the read-only Linear process-event adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-linear-tests)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
HOME_DIR="$TMP_ROOT/home"
SERVER="$TMP_ROOT/fake-linear.py"
CONFIG="$TMP_ROOT/linear-poll.json"
PHASE="$TMP_ROOT/phase"
REQUESTS="$TMP_ROOT/requests.jsonl"
PORT_FILE="$TMP_ROOT/port"
RUNNER_LOG="$TMP_ROOT/runner.log"
RUNNER_PID=''
mkdir -p "$HOME_DIR/state"

cat > "$SERVER" <<'PY'
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

phase_path = pathlib.Path(sys.argv[1])
requests_path = pathlib.Path(sys.argv[2])
port_path = pathlib.Path(sys.argv[3])

issue = {
    "id": "issue-immutable-id",
    "identifier": "HAN-28",
    "title": "Make M14 the default and first CameraOnboarding profile",
    "url": "https://linear.app/hanzireader/issue/HAN-28/make-m14-the-default-and-first-cameraonboarding-profile",
    "updatedAt": "2026-08-30T12:00:00.000Z",
    "project": {"id": "project-id", "name": "Messsucher", "slugId": "messsucher-729853ec4ffb"},
    "state": {"name": "Todo", "type": "unstarted"},
}

# A second Todo whose blocking relation only shows up on the second page of
# inverseRelations (51 total, page size 50). Regression coverage for the
# unpaginated blocker check that could silently dispatch a blocked Todo.
blocked_issue = {
    "id": "issue-blocked-id",
    "identifier": "HAN-29",
    "title": "Issue with a blocker beyond the first inverseRelations page",
    "url": "https://linear.app/hanzireader/issue/HAN-29/issue-with-a-blocker-beyond-the-first-page",
    "updatedAt": "2026-08-30T12:00:00.000Z",
    "project": {"id": "project-id", "name": "Messsucher", "slugId": "messsucher-729853ec4ffb"},
    "state": {"name": "Todo", "type": "unstarted"},
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(size))
        query = body.get("query", "")
        with requests_path.open("a", encoding="utf-8") as output:
            output.write(json.dumps({"query": query, "variables": body.get("variables")}) + "\n")
        if query.lstrip().startswith("mutation"):
            self.send_response(409)
            self.end_headers()
            return
        variables = body.get("variables") or {}
        if "FirstmateLinearIssues" in query:
            data = {"issues": {"nodes": [issue, blocked_issue], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
        elif "FirstmateLinearComments" in query:
            comments = [{"id": "comment-existing", "createdAt": "2026-08-29T10:00:00.000Z", "updatedAt": "2026-08-29T10:00:00.000Z"}]
            if phase_path.exists() and phase_path.read_text(encoding="utf-8").strip() == "new-comment":
                comments.append({"id": "comment-new", "createdAt": "2026-08-30T13:00:00.000Z", "updatedAt": "2026-08-30T13:00:00.000Z"})
            data = {"issue": {"comments": {"nodes": comments, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        elif "FirstmateLinearInverseRelations" in query:
            if variables.get("issueId") == "issue-blocked-id":
                if variables.get("after"):
                    nodes = [{"type": "blocks", "issue": {"id": "blocker-2", "identifier": "HAN-30", "state": {"name": "In Progress", "type": "started"}}}]
                    page_info = {"hasNextPage": False, "endCursor": None}
                else:
                    nodes = [
                        {"type": "blocks", "issue": {"id": f"blocker-page1-{n}", "identifier": f"HAN-{100 + n}", "state": {"name": "Done", "type": "completed"}}}
                        for n in range(50)
                    ]
                    page_info = {"hasNextPage": True, "endCursor": "page2"}
                data = {"issue": {"inverseRelations": {"nodes": nodes, "pageInfo": page_info}}}
            else:
                data = {"issue": {"inverseRelations": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        else:
            self.send_response(400)
            self.end_headers()
            return
        payload = json.dumps({"data": data}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
PY

cat > "$CONFIG" <<'JSON'
{
  "schema": "fm-linear-poll.v1",
  "projects": [
    {
      "linearProjectSlug": "messsucher-729853ec4ffb",
      "linearProjectName": "Messsucher",
      "firstmateProject": "FilmLeica"
    }
  ],
  "allowIssues": ["HAN-28", "HAN-29"]
}
JSON

python3 "$SERVER" "$PHASE" "$REQUESTS" "$PORT_FILE" &
SERVER_PID=$!
cleanup() {
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  [ -z "$RUNNER_PID" ] || kill "$RUNNER_PID" >/dev/null 2>&1 || true
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.02
done
[ -s "$PORT_FILE" ] || fail "fake Linear GraphQL server did not start"
URL="http://127.0.0.1:$(cat "$PORT_FILE")/graphql"

linear() {
  FM_HOME="$HOME_DIR" FM_LINEAR_GRAPHQL_URL="$URL" FM_LINEAR_POLL_INTERVAL=1 \
    LINEAR_API_KEY=test-key "$ROOT/bin/fm-procevent-linear.sh" "$@"
}

out=$(linear poll-once "$CONFIG")
assert_contains "$out" '"eventType":"todo.detected"' "first observation emits the eligible Todo"
assert_contains "$out" '"issueId":"issue-immutable-id"' "event carries the immutable Linear issue id"
assert_contains "$out" '"url":"https://linear.app/hanzireader/issue/HAN-28/make-m14-the-default-and-first-cameraonboarding-profile"' \
  "event preserves the exact API-provided Linear URL"
assert_not_contains "$out" comment-existing "existing comments are baselined without an event"
assert_not_contains "$out" '"identifier":"HAN-29"' \
  "a Todo whose blocker is only on the second inverseRelations page is excluded, not wrongly dispatched"
pass "eligible Todo detection is exact and existing comments are baselined"

out=$(linear poll-once "$CONFIG")
[ -z "$out" ] || fail "unchanged snapshot produced output: $out"
pass "an unchanged Linear snapshot is silent"

linear arm "$CONFIG" >/dev/null
source_id=$(linear source-id "$CONFIG")
FM_HOME="$HOME_DIR" FM_LINEAR_GRAPHQL_URL="$URL" FM_LINEAR_POLL_INTERVAL=1 LINEAR_API_KEY=test-key \
  "$ROOT/bin/fm-procevent.sh" start "$source_id" > "$RUNNER_LOG" 2>&1 &
RUNNER_PID=$!
sleep 0.3
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "unchanged polling created a wake"
[ -z "$(find "$HOME_DIR/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null)" ] \
  || fail "unchanged polling created a process result"
pass "unchanged background polling creates no wake or model-triggering result"

printf 'new-comment\n' > "$PHASE"
for _ in $(seq 1 50); do
  [ -s "$HOME_DIR/state/.wake-queue" ] && break
  sleep 0.1
done
if [ ! -s "$HOME_DIR/state/.wake-queue" ]; then
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" list >&2 || true
  tail -40 "$RUNNER_LOG" >&2 || true
  fail "new comment did not produce a wake"
fi
result=$(find "$HOME_DIR/state/procevent-inbox" -type f -name '*.result' -print | head -1)
[ -n "$result" ] || fail "new comment wake had no durable result"
out=$(linear read "$result")
assert_contains "$out" "event_type: comment.detected" "new comment is classified in the durable result"
assert_contains "$out" "identifier: HAN-28" "new comment retains the assigned issue identifier"
assert_contains "$out" "comment_id: comment-new" "new comment retains its immutable id"
assert_contains "$out" "url: https://linear.app/hanzireader/issue/HAN-28/make-m14-the-default-and-first-cameraonboarding-profile" \
  "comment event preserves the exact API URL"
pass "a new comment becomes one durable process event"

linear retire "$CONFIG" >/dev/null
if jq -e -s 'any(.[]; (.query | ltrimstr(" ") | startswith("mutation")))' "$REQUESTS" >/dev/null; then
  fail "poller attempted a GraphQL mutation"
fi
[ "$(jq -r -s '[.[].query | capture("^(?<kind>[A-Za-z]+)").kind] | unique | join(",")' "$REQUESTS")" = query ] \
  || fail "poller sent a non-query GraphQL operation"
pass "the fake GraphQL server observed query operations only"

printf 'ok: Linear process-event adapter behavior tests passed\n'
