#!/usr/bin/env bash
# Deterministic protocol-20 structural-launch coverage for Herdr.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-layout-apply)
SOCK="$TMP_ROOT/herdr.sock"
REQUEST="$TMP_ROOT/request.json"
APPLIED="$TMP_ROOT/applied"
REPORTED="$TMP_ROOT/reported"
CALLS="$TMP_ROOT/calls.log"
SERVER_PID=
MODE=ok

layout_schema() {
  cat <<'JSON'
{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"layout.apply"}}},{"properties":{"method":{"const":"pane.report_agent"}}}],"$defs":{"LayoutApplyParams":{"required":["root"],"properties":{"workspace_id":{"type":["string","null"]},"tab_id":{"type":["string","null"]}}},"LayoutNode":{"oneOf":[{"properties":{"type":{"const":"pane"},"command":{"type":["array","null"]},"cwd":{"type":["string","null"]},"env":{"type":"object"},"pane_id":{"type":["string","null"]}}}]},"PaneReportAgentParams":{"required":["pane_id","source","agent","state"],"properties":{"agent":{"type":"string"},"state":{"$ref":"#/schemas/request/$defs/PaneAgentState"}}}}}}}
JSON
}

start_server() { # <success|wrong-id|error|malformed>
  local response=$1
  rm -f "$SOCK" "$REQUEST" "$APPLIED"
  python3 - "$SOCK" "$REQUEST" "$APPLIED" "$response" <<'PY' &
import json
import socket
import sys

sock_path, request_path, applied_path, response_mode = sys.argv[1:]
server = socket.socket(socket.AF_UNIX)
server.bind(sock_path)
server.listen(1)
client, _ = server.accept()
data = b""
while b"\n" not in data:
    chunk = client.recv(65536)
    if not chunk:
        raise SystemExit("client closed before request")
    data += chunk
request = json.loads(data.split(b"\n", 1)[0])
with open(request_path, "w", encoding="utf-8") as stream:
    json.dump(request, stream, separators=(",", ":"))
with open(applied_path, "w", encoding="utf-8"):
    pass
if response_mode == "success":
    response = {"id": request["id"], "result": {"type": "layout_apply", "layout": {
        "workspace_id": "w1", "tab_id": "w1:t3", "focused_pane_id": "w1:p3",
        "root": {"type": "pane", "pane_id": "w1:p3"}}}}
elif response_mode == "wrong-id":
    response = {"id": "another-request", "result": {}}
elif response_mode == "error":
    response = {"id": request["id"], "error": {"code": "layout_apply_failed"}}
else:
    client.sendall(b"not-json\n")
    client.close()
    server.close()
    raise SystemExit(0)
client.sendall((json.dumps(response, separators=(",", ":")) + "\n").encode("utf-8"))
client.close()
server.close()
PY
  SERVER_PID=$!
  for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && return 0
    sleep 0.01
  done
  fail "fake Herdr protocol socket did not start"
}

wait_server() {
  wait "$SERVER_PID"
  SERVER_PID=
}

# The fake CLI is stateful only across the raw layout request and the public
# report-agent call. Every response carries exact workspace/tab/pane identity,
# so each refusal mode changes one independent proof.
fm_backend_herdr_cli() { # <session> <args...>
  local session=$1 pane
  shift
  printf '%s|%s\n' "$session" "$*" >> "$CALLS"
  [ "$session" = lab-structural ] || return 91
  case "$*" in
    "status --json")
      if [ "$MODE" = protocol ]; then
        printf '%s\n' '{"client":{"protocol":19},"server":{"protocol":20,"running":true}}'
      else
        printf '%s\n' '{"client":{"protocol":20},"server":{"protocol":20,"running":true}}'
      fi
      ;;
    "api schema --json")
      if [ "$MODE" = schema ]; then printf '%s\n' '{"schemas":{"request":{}}}'; else layout_schema; fi
      ;;
    "workspace list")
      if [ "$MODE" = workspace ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9"}]}}'
      else
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1"}]}}'
      fi
      ;;
    "tab get w1:t2")
      if [ "$MODE" = tab ]; then
        printf '%s\n' '{"result":{"tab":{"workspace_id":"w9","tab_id":"w1:t2"}}}'
      else
        printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2"}}}'
      fi
      ;;
    "pane get w1:p2")
      if [ "$MODE" = pane ]; then
        printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t9","pane_id":"w1:p2"}}}'
      else
        printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2"}}}'
      fi
      ;;
    "pane layout --pane w1:p2")
      if [ "$MODE" = layout ]; then
        printf '%s\n' '{"result":{"layout":{"workspace_id":"w1","tab_id":"w1:t2","focused_pane_id":"w1:p2","panes":[{"pane_id":"w1:p2","focused":true,"rect":{}},{"pane_id":"w1:p9","focused":false,"rect":{}}],"splits":[{}]}}}'
      else
        printf '%s\n' '{"result":{"layout":{"workspace_id":"w1","tab_id":"w1:t2","focused_pane_id":"w1:p2","panes":[{"pane_id":"w1:p2","focused":true,"rect":{}}],"splits":[]}}}'
      fi
      ;;
    "agent get w1:p2")
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      ;;
    "pane process-info --pane w1:p2")
      if [ "$MODE" = foreground ]; then
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"git","argv0":"git","argv":["git"]}]}}}'
      else
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash","argv":["bash"]}]}}}\n' "$$" "$$"
      fi
      ;;
    "session list --json")
      if [ "$MODE" = socket ]; then
        printf '%s\n' '{"sessions":[{"name":"other","running":true,"socket_path":"/tmp/other.sock"}]}'
      else
        printf '{"sessions":[{"name":"lab-structural","running":true,"socket_path":"%s"}]}\n' "$SOCK"
      fi
      ;;
    "tab get w1:t3")
      if [ "$MODE" = response_identity ]; then
        printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t9"}}}'
      else
        printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t3"}}}'
      fi
      ;;
    "pane get w1:p3")
      printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3"}}}'
      ;;
    "pane close w1:p3")
      printf '%s\n' '{"result":{"type":"pane_close","pane_id":"w1:p3"}}'
      ;;
    "pane process-info --pane w1:p3")
      if [ "$MODE" = wrong-agent ]; then
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"codex","argv0":"codex","argv":["codex"],"cmdline":"codex"}]}}}'
      else
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi","--model","fake"],"cmdline":"pi --model fake"}]}}}'
      fi
      ;;
    "pane report-agent w1:p3 --source firstmate-layout-apply --agent pi --state working")
      : > "$REPORTED"
      printf '%s\n' '{"result":{"type":"ok"}}'
      ;;
    "agent get w1:p3")
      if [ -f "$REPORTED" ]; then
        printf '%s\n' '{"result":{"agent":{"pane_id":"w1:p3","agent":"pi","agent_status":"working"}}}'
      else
        printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      fi
      ;;
    *)
      echo "unexpected fake Herdr call: $session $*" >&2
      return 92
      ;;
  esac
}

run_layout() {
  fm_backend_herdr_layout_apply \
    lab-structural:w1:p2 w1 w1:t2 w1:p2 "$TMP_ROOT/worktree" \
    '{"EXACT_ENV":"yes","STALE_TEXT":"must-not-run"}' \
    '["/bin/sh","-c","exec pi --model fake --flag literal"]'
}

mkdir -p "$TMP_ROOT/worktree"
: > "$CALLS"
start_server success
result=$(run_layout)
wait_server
[ "$result" = $'w1:t3\tw1:p3' ] || fail "layout adapter did not bind returned replacement ids: $result"
jq -e --arg cwd "$TMP_ROOT/worktree" '
  (.id | startswith("fm-layout-apply-"))
  and .method == "layout.apply"
  and .params.tab_id == "w1:t2"
  and .params.root == {
    type:"pane", pane_id:"w1:p2",
    command:["/bin/sh","-c","exec pi --model fake --flag literal"],
    cwd:$cwd, env:{EXACT_ENV:"yes",STALE_TEXT:"must-not-run"}}
' "$REQUEST" >/dev/null || fail "layout request changed cwd, environment, argv, or exact replacement identity"
[ "$(grep -c '^lab-structural|' "$CALLS")" -eq "$(wc -l < "$CALLS" | tr -d ' ')" ] \
  || fail "a structural-launch read escaped its exact named session"
pass "layout.apply preserves exact cwd/environment/argv and binds only response ids re-read from the named session"

for mode in protocol schema workspace tab pane layout foreground socket; do
  MODE=$mode
  rm -f "$REQUEST" "$APPLIED"
  if run_layout >/dev/null 2>&1; then
    fail "layout adapter accepted the $mode mismatch"
  fi
  [ ! -e "$APPLIED" ] || fail "layout adapter mutated Herdr before refusing the $mode mismatch"
done
MODE=ok
if fm_backend_herdr_layout_apply lab-structural:w1:p9 w1 w1:t2 w1:p2 \
  "$TMP_ROOT/worktree" '{}' '["pi"]' >/dev/null 2>&1; then
  fail "layout adapter accepted a target/pane identity mismatch"
fi
pass "layout.apply refuses every protocol, schema, socket, session, container, layout, and foreground identity mismatch before mutation"

MODE=response_identity
: > "$CALLS"
start_server success
if run_layout >/dev/null 2>&1; then
  fail "layout adapter accepted replacement ids that did not re-read from the selected session"
fi
wait_server
[ -f "$APPLIED" ] || fail "post-response identity case never exercised the mutation boundary"
[ "$(grep -c '^lab-structural|pane close w1:p3$' "$CALLS")" -eq 1 ] \
  || fail "post-mutation refusal did not close the exact returned pane once"
assert_no_grep 'pane close w1:p2' "$CALLS" \
  "post-mutation refusal targeted the stale pre-apply pane"
pass "layout.apply cleans only the exact returned pane after a post-mutation identity refusal"
MODE=ok

for response_mode in wrong-id error malformed; do
  start_server "$response_mode"
  if python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
    "$SOCK" w1 w1:t2 w1:p2 "$TMP_ROOT/worktree" '{}' '["pi"]' >/dev/null 2>&1; then
    fail "protocol client accepted a $response_mode response"
  fi
  wait_server
done
python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  relative.sock w1 w1:t2 w1:p2 "$TMP_ROOT/worktree" '{}' '["pi"]' >/dev/null 2>&1 \
  && fail "protocol client accepted a relative socket"
python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 relative '{}' '["pi"]' >/dev/null 2>&1 \
  && fail "protocol client accepted a relative cwd"
python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 "$TMP_ROOT/worktree" '[]' '["pi"]' >/dev/null 2>&1 \
  && fail "protocol client accepted a non-map environment"
python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 "$TMP_ROOT/worktree" '{}' '[]' >/dev/null 2>&1 \
  && fail "protocol client accepted an empty command argv"
pass "protocol client binds random response ids and refuses malformed endpoints, payloads, errors, and responses"

rm -f "$REPORTED"
MODE=ok
fm_backend_herdr_layout_report_pi lab-structural:w1:p3 \
  || fail "confirmed plain Pi was not registered through Herdr's public report-agent command"
[ -f "$REPORTED" ] || fail "report-agent command was not issued"
MODE=wrong-agent
rm -f "$REPORTED"
if fm_backend_herdr_layout_report_pi lab-structural:w1:p3 >/dev/null 2>&1; then
  fail "a non-Pi foreground process was registered as Pi"
fi
[ ! -e "$REPORTED" ] || fail "inventory mutated before exact Pi process confirmation"
pass "agent inventory registration requires exact plain-Pi process identity and is re-read from Herdr"

META="$TMP_ROOT/task.meta"
META_NEW="$TMP_ROOT/task.meta.new"
cat > "$META" <<'EOF'
window=lab-structural:w1:p2
endpoint_task_id=task-z1
backend=herdr
herdr_session=lab-structural
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
traceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01
EOF
fm_backend_herdr_layout_rebind_meta "$META" "$META_NEW" lab-structural w1:t3 w1:p3 \
  || fail "exact Herdr task metadata did not rebind"
assert_grep 'window=lab-structural:w1:p3' "$META_NEW" "window endpoint did not rebind"
assert_grep 'herdr_tab_id=w1:t3' "$META_NEW" "tab id did not rebind"
assert_grep 'herdr_pane_id=w1:p3' "$META_NEW" "pane id did not rebind"
assert_grep 'traceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01' "$META_NEW" \
  "metadata rebinding did not preserve trace context"
printf 'herdr_pane_id=duplicate\n' >> "$META"
fm_backend_herdr_layout_rebind_meta "$META" "$META_NEW" lab-structural w1:t4 w1:p4 >/dev/null 2>&1 \
  && fail "metadata rebinding accepted duplicate endpoint identity"
pass "task metadata rebinding is exact, preserves trace metadata, and refuses ambiguous records"

if ! fm_backend_herdr_process_matches_expected pi node pi '["pi","--model","fake"]'; then
  fail "plain Pi argv identity was not recognized"
fi
fm_backend_herdr_process_matches_expected pi node pi-signed '["pi-signed","--model","fake"]' \
  && fail "pi-signed was silently normalized to plain Pi"
fm_backend_herdr_process_matches_expected pi codex codex '["codex"]' \
  && fail "an unrelated recognized agent was accepted as plain Pi"
pass "exact harness confirmation distinguishes plain Pi from pi-signed and other agents"

UNSUPPORTED="$TMP_ROOT/unsupported"
UNSUPPORTED_HOME="$UNSUPPORTED/home"
UNSUPPORTED_PROJECT="$UNSUPPORTED/project"
UNSUPPORTED_WT="$UNSUPPORTED/worktree"
UNSUPPORTED_LOG="$UNSUPPORTED/tool.log"
UNSUPPORTED_FAKEBIN=$(fm_fakebin "$UNSUPPORTED/fake")
fm_test_spawn_home "$UNSUPPORTED_HOME" pi-signed
fm_test_spawn_brief "$UNSUPPORTED_HOME" unsupported-pi-signed-z1 "Refuse unproved Herdr harness normalization."
fm_git_worktree "$UNSUPPORTED_PROJECT" "$UNSUPPORTED_WT" unsupported-worktree
cat > "$UNSUPPORTED_FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "${FM_UNSUPPORTED_LOG:?}"
case "$*" in
  *"status --json"*) printf '%s\n' '{"client":{"protocol":20},"server":{"protocol":20,"running":true}}' ;;
esac
SH
cat > "$UNSUPPORTED_FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_UNSUPPORTED_LOG:?}"
printf '%s\n' "${FM_FAKE_PANE_PATH:?}"
SH
fm_fake_exit0 "$UNSUPPORTED_FAKEBIN" pi-signed
chmod +x "$UNSUPPORTED_FAKEBIN/herdr" "$UNSUPPORTED_FAKEBIN/treehouse"
: > "$UNSUPPORTED_LOG"
set +e
unsupported_out=$(FM_UNSUPPORTED_LOG="$UNSUPPORTED_LOG" HERDR_SESSION=lab-structural \
  fm_test_run_spawn "$UNSUPPORTED_HOME" "$UNSUPPORTED_WT" "$UNSUPPORTED_FAKEBIN" \
    unsupported-pi-signed-z1 "$UNSUPPORTED_PROJECT" --scout --harness pi-signed --backend herdr)
unsupported_status=$?
set -e
[ "$unsupported_status" -ne 0 ] || fail "pi-signed launch unexpectedly used the plain-Pi structural path"
assert_contains "$unsupported_out" "supports only the exact plain pi harness" \
  "unsupported Herdr harness refusal did not name its exact boundary"
assert_no_grep 'workspace create' "$UNSUPPORTED_LOG" "unsupported harness created a Herdr workspace"
assert_no_grep 'tab create' "$UNSUPPORTED_LOG" "unsupported harness created a Herdr tab"
assert_no_grep '^treehouse ' "$UNSUPPORTED_LOG" "unsupported harness acquired a local copy"
pass "unsupported Herdr harnesses refuse before endpoint or local-copy mutation without normalizing pi-signed"

printf '# all fm-herdr-layout-apply tests passed\n'
