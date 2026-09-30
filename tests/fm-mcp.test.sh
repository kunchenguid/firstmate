#!/usr/bin/env bash
# tests/fm-mcp.test.sh - the MCP server (bin/fm-mcp.py) over its real stdio protocol.
#
# Every case speaks newline-delimited JSON-RPC to the server exactly as Claude
# Desktop or Claude Code would, against a temporary fake FM_HOME, and the server
# runs firstmate's real scripts. The property worth protecting is the authority
# boundary: firstmate_send_note is the only tool that writes, and it writes only
# an inbox note that wakes firstmate. Every other tool is a read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-mcp)
H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/data/demo"
cat >"$H/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] demo - Demo task for the MCP tests (repo: demo) (kind: ship) (since 2026-09-30)
  Demo notes body.

## Queued
## Done
EOF
printf '# demo report\nall good\n' >"$H/data/demo/report.md"
printf 'kind=ship\nmode=local-only\nbranch=fm/demo\n' >"$H/state/demo.meta"
printf 'done [at=1790767000]: ready in branch fm/demo\n' >"$H/state/demo.status"
printf '{"schema":"fm-secondmate-home-summary.v1","active_children":[]}\n' >"$H/state/home-summary.json"
export FM_HOME="$H" FM_CREW_STATE_NO_FORGE=1

# rpc <request-json>... : one server session, one response per line on stdout.
rpc() {
  printf '%s\n' "$@" | python3 "$ROOT/bin/fm-mcp.py"
}

# jq_py <python-expr over r> : evaluate against the single JSON value on stdin.
jq_py() {
  python3 -c 'import json,sys; r=json.load(sys.stdin); v=eval(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v))' "$1"
}

# call <tool> [arguments-json] : prints isError on line 1, the text after it.
call() {
  rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":${2:-"{}"}}}" |
    jq_py '"%s\n%s" % (json.dumps(r["result"]["isError"]), r["result"]["content"][0]["text"])'
}

ok_text() {  # <label> <output of call> : asserts success, prints the text
  [ "$(printf '%s\n' "$2" | head -1)" = false ] || fail "$1: expected success, got: $2"
  printf '%s\n' "$2" | tail -n +2
}

is_error() {  # <label> <output of call>
  [ "$(printf '%s\n' "$2" | head -1)" = true ] || fail "$1: expected a tool error, got: $2"
}

# --- protocol ---------------------------------------------------------------

out=$(rpc '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":1,"method":"ping"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"resources/list"}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"firstmate_merge","arguments":{}}}' \
  'not json')
assert_equals "6" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "a notification gets no response, every request gets one"
line() { printf '%s\n' "$out" | sed -n "$1p"; }
assert_equals "2025-06-18" "$(line 1 | jq_py 'r["result"]["protocolVersion"]')" "initialize echoes a supported protocol version"
assert_equals "firstmate" "$(line 1 | jq_py 'r["result"]["serverInfo"]["name"]')" "initialize names the server"
assert_equals "{}" "$(line 2 | jq_py 'r["result"]')" "ping answers"
assert_equals \
  '["firstmate_send_note", "firstmate_note_replies", "firstmate_status", "firstmate_home_summary", "firstmate_backlog_list", "firstmate_backlog_show", "firstmate_crew_state", "firstmate_crew_report"]' \
  "$(line 3 | jq_py '[t["name"] for t in r["result"]["tools"]]')" "tools/list serves all eight tools"
assert_equals '["firstmate_send_note"]' \
  "$(line 3 | jq_py '[t["name"] for t in r["result"]["tools"] if not t["annotations"]["readOnlyHint"]]')" \
  "send_note is the only tool not annotated read-only"
assert_equals '["message", "request_id"]' \
  "$(line 3 | jq_py '[t for t in r["result"]["tools"] if t["name"] == "firstmate_send_note"][0]["inputSchema"]["required"]')" \
  "send_note requires a message and a client request_id"
assert_equals "-32601" "$(line 4 | jq_py 'r["error"]["code"]')" "an unsupported method is method-not-found"
assert_equals "-32602" "$(line 5 | jq_py 'r["error"]["code"]')" "an unknown tool is invalid-params, not a silent success"
assert_equals "-32700" "$(line 6 | jq_py 'r["error"]["code"]')" "a malformed line is a parse error and the session survives"
assert_equals "2025-11-25" \
  "$(rpc '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}' | jq_py 'r["result"]["protocolVersion"]')" \
  "an unknown protocol version falls back to the newest supported one"
pass "protocol: initialize, ping, tools/list, and error codes"

# --- the only write: an inbox note, idempotent per request_id ----------------

note=$(ok_text "send_note" "$(call firstmate_send_note '{"message":"please build X","request_id":"req-1"}')")
note_id=$(printf '%s' "$note" | jq_py 'r["id"]')
assert_equals "created true" "$(printf '%s' "$note" | jq_py '"%s %s" % (r["outcome"], json.dumps(r["announced"]))')" "send_note creates and announces the note"
assert_grep "inbox:$note_id" "$H/state/.wake-queue" "send_note wakes firstmate"
replay=$(ok_text "send_note replay" "$(call firstmate_send_note '{"message":"please build X","request_id":"req-1"}')")
assert_equals "replay $note_id" "$(printf '%s' "$replay" | jq_py '"%s %s" % (r["outcome"], r["id"])')" "a repeated request_id replays the original note"

pending=$(ok_text "note_replies pending" "$(call firstmate_note_replies "{\"note_id\":\"$note_id\"}")")
assert_equals "false null" "$(printf '%s' "$pending" | jq_py '"%s %s" % (json.dumps(r["acknowledged"]), json.dumps(r["reply"]))')" "an unhandled note has no reply yet"
assert_equals "[via firstmate MCP]|please build X" "$(printf '%s' "$pending" | jq_py '"|".join(r["body"].strip().splitlines())')" "a client request_id still gets the MCP provenance line"
assert_contains "$(ok_text "status" "$(call firstmate_status)")" "1 note(s) waiting" "status counts the waiting note"

"$ROOT/bin/fm-inbox.sh" drain --ack "$note_id" >/dev/null || fail "firstmate could not ack the note"
"$ROOT/bin/fm-inbox.sh" reply "$note_id" "on it" >/dev/null || fail "firstmate could not reply to the note"
handled=$(ok_text "note_replies handled" "$(call firstmate_note_replies "{\"note_id\":\"$note_id\"}")")
assert_equals "true on it" "$(printf '%s' "$handled" | jq_py '"%s %s" % (json.dumps(r["acknowledged"]), r["reply"]["body"])')" "the reply and acknowledgement come back"
assert_equals "on it" "$(ok_text "note_replies all" "$(call firstmate_note_replies)" | jq_py 'r["replies"][0]["body"]')" "receipts without a note id list the reply"
pass "send_note: one idempotent note, and firstmate's reply returns"

# More than one bound of replies: no cursor shows the newest, after pages forward.
for i in $(seq 1 24); do
  id=$(printf 'bulk %s' "$i" | "$ROOT/bin/fm-inbox.sh" note --json - | jq_py 'r["id"]')
  "$ROOT/bin/fm-inbox.sh" drain --ack "$id" >/dev/null || fail "could not ack bulk note $i"
  "$ROOT/bin/fm-inbox.sh" reply "$id" "answer $i" >/dev/null || fail "could not reply to bulk note $i"
done
latest=$(ok_text "note_replies newest" "$(call firstmate_note_replies)")
assert_equals "20 answer 5 answer 24" "$(printf '%s' "$latest" | jq_py '"%d %s %s" % (len(r["replies"]), r["replies"][0]["body"], r["replies"][-1]["body"])')" "no cursor returns the newest 20 replies"
assert_equals "[]" "$(printf '%s' "$latest" | jq_py '[o["reveal"] for o in r["omitted"] if "--" in o["reveal"]]')" "hints name only this tool's options"
first=$(printf '%s' "$latest" | jq_py 'r["replies"][0]["cursor"]')
assert_equals "answer 6" "$(ok_text "note_replies after" "$(call firstmate_note_replies "{\"after\":\"$first\"}")" | jq_py 'r["replies"][0]["body"]')" "after returns only newer replies"
assert_equals "[]" "$(ok_text "note_replies head" "$(call firstmate_note_replies "{\"after\":\"$(printf '%s' "$latest" | jq_py 'r["reply_cursor"]')\"}")" | jq_py 'r["replies"]')" "the newest reply_cursor has nothing newer"
pass "note_replies: newest replies first page, after cursor pages forward"

is_error "empty note" "$(call firstmate_send_note '{"message":"   ","request_id":"req-2"}')"
is_error "no request_id" "$(call firstmate_send_note '{"message":"no id given"}')"
is_error "unknown note" "$(call firstmate_note_replies '{"note_id":"nope"}')"
is_error "missing argument" "$(call firstmate_backlog_show)"
is_error "extra argument" "$(call firstmate_status '{"force":"yes"}')"
is_error "non-string argument" "$(call firstmate_send_note '{"message":42,"request_id":"req-3"}')"
pass "bad input is a tool error, never a note"

# --- reads ------------------------------------------------------------------

# A report reached through a symlink, at the file or a directory, is refused.
printf 'secret\n' >"$TMP_ROOT/outside.md"
mkdir -p "$H/data/filelink"
ln -s "$TMP_ROOT/outside.md" "$H/data/filelink/report.md"
mkdir -p "$TMP_ROOT/outside-dir"
cp "$TMP_ROOT/outside.md" "$TMP_ROOT/outside-dir/report.md"
ln -s "$TMP_ROOT/outside-dir" "$H/data/dirlink"

# home_sum : one digest over every path and file byte under the home.
home_sum() {
  python3 -c 'import hashlib,os,sys
h=hashlib.sha256()
for d,ds,fs in os.walk(sys.argv[1]):
    ds.sort()
    for n in [d]+sorted(os.path.join(d,f) for f in fs):
        h.update(n.encode()+b"\0")
        if n!=d and not os.path.islink(n): h.update(open(n,"rb").read())
print(h.hexdigest())' "$H"
}
before=$(home_sum)

st=$(ok_text "status" "$(call firstmate_status)")
assert_contains "$st" "demo" "status lists in-flight work"
assert_contains "$st" "fm-primary-ready.v1" "status includes firstmate's readiness"
assert_equals "fm-secondmate-home-summary.v1" "$(ok_text "summary" "$(call firstmate_home_summary)" | jq_py 'r["schema"]')" "home summary is served"
assert_contains "$(ok_text "backlog list" "$(call firstmate_backlog_list)")" "Demo task for the MCP tests" "backlog list"
assert_contains "$(ok_text "backlog show" "$(call firstmate_backlog_show '{"task_id":"demo"}')")" "Demo notes body" "backlog show includes notes"
crew=$(ok_text "crew state" "$(call firstmate_crew_state '{"task_id":"demo"}')")
case "$crew" in "state: "*) ;; *) fail "crew state did not report a state: $crew" ;; esac
assert_contains "$(ok_text "crew report" "$(call firstmate_crew_report '{"task_id":"demo"}')")" "all good" "crew report"
pass "reads: status, summary, backlog, crew state, and report"

traversal=$(call firstmate_crew_report '{"task_id":"../state"}')
is_error "traversal" "$traversal"
assert_contains "$traversal" "invalid task id" "a path-shaped id is refused before any read"
is_error "option-shaped id" "$(call firstmate_crew_state '{"task_id":"--help"}')"
is_error "missing report" "$(call firstmate_crew_report '{"task_id":"nosuch"}')"
for id in filelink dirlink; do
  linked=$(call firstmate_crew_report "{\"task_id\":\"$id\"}")
  is_error "symlinked report $id" "$linked"
  assert_not_contains "$linked" "secret" "a symlinked report ($id) is not read"
done
pass "ids and symlinks cannot escape the home"

# The reads above changed nothing anywhere in the home.
assert_equals "$before" "$(home_sum)" "no tool but send_note wrote to the home"
pass "authority boundary: reads leave the home byte-identical"

rm "$H/state/home-summary.json"
is_error "missing summary" "$(call firstmate_home_summary)"
pass "missing files are errors"
