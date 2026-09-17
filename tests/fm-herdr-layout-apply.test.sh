#!/usr/bin/env bash
# Deterministic protocol-20 structural-launch coverage for Herdr.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-layout-apply)
SOCK="$TMP_ROOT/herdr.sock"
REQUEST="$TMP_ROOT/request.json"
APPLIED="$TMP_ROOT/applied"
REPORTED="$TMP_ROOT/reported"
CLOSED="$TMP_ROOT/closed"
LABEL_CLEARED="$TMP_ROOT/label-cleared"
ATTEMPT="$TMP_ROOT/task.herdr-launch"
CALLS="$TMP_ROOT/calls.log"
SERVER_PID=
MODE=ok

layout_schema() {
  cat <<'JSON'
{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"layout.apply"}}},{"properties":{"method":{"const":"pane.report_agent"}}}],"$defs":{"LayoutApplyParams":{"required":["root"],"properties":{"workspace_id":{"type":["string","null"]},"tab_id":{"type":["string","null"]}}},"LayoutNode":{"oneOf":[{"properties":{"type":{"const":"pane"},"command":{"type":["array","null"]},"cwd":{"type":["string","null"]},"env":{"type":"object"},"label":{"type":["string","null"]},"pane_id":{"type":["string","null"]}}}]},"PaneReportAgentParams":{"required":["pane_id","source","agent","state"],"properties":{"agent":{"type":"string"},"state":{"$ref":"#/schemas/request/$defs/PaneAgentState"}}}}}}}
JSON
}

start_server() { # <success|wrong-id|error|malformed|timeout>
  local response=$1
  rm -f "$SOCK" "$REQUEST" "$APPLIED" "$CLOSED" "$LABEL_CLEARED"
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
elif response_mode == "timeout":
    import time
    time.sleep(1)
    client.close()
    server.close()
    raise SystemExit(0)
elif response_mode == "wrong-id":
    response = {"id": "another-request", "result": {}}
elif response_mode == "error":
    response = {"id": request["id"], "error": {"code": "layout_apply_failed"}}
else:
    client.sendall(b"not-json\n")
    client.close()
    server.close()
    raise SystemExit(0)
try:
    client.sendall((json.dumps(response, separators=(",", ":")) + "\n").encode("utf-8"))
except BrokenPipeError:
    pass
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
  local session=$1 pane label
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
      case "$MODE" in
        reconcile|reconcile_duplicate|reconcile_missing) return 1 ;;
        pane) printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t9","pane_id":"w1:p2"}}}' ;;
        *) printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2"}}}' ;;
      esac
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
    "pane list --workspace w1")
      case "$MODE" in
        reconcile_duplicate)
          printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"fm-launch-0123456789abcdef0123456789abcdef"},{"workspace_id":"w1","tab_id":"w1:t4","pane_id":"w1:p4","label":"fm-launch-0123456789abcdef0123456789abcdef"}]}}'
          ;;
        reconcile_missing) printf '%s\n' '{"result":{"panes":[]}}' ;;
        *)
          if [ -e "$CLOSED" ]; then
            printf '%s\n' '{"result":{"panes":[]}}'
          else
            printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"fm-launch-0123456789abcdef0123456789abcdef"}]}}'
          fi
          ;;
      esac
      ;;
    "pane get w1:p3")
      [ ! -e "$CLOSED" ] || return 1
      if [ -e "$LABEL_CLEARED" ]; then
        printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":null}}}'
      else
        label=$(jq -r '.params.root.label // "fm-launch-0123456789abcdef0123456789abcdef"' "$REQUEST" 2>/dev/null || printf 'fm-launch-0123456789abcdef0123456789abcdef')
        printf '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"%s"}}}\n' "$label"
      fi
      ;;
    "pane rename w1:p3 --clear")
      : > "$LABEL_CLEARED"
      printf '%s\n' '{"result":{"type":"pane_rename","pane_id":"w1:p3"}}'
      ;;
    "pane close w1:p3")
      : > "$CLOSED"
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
    '["/bin/sh","-c","exec pi --model fake --flag literal"]' \
    "$ATTEMPT" 0123456789abcdef0123456789abcdef
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
    label:"fm-launch-0123456789abcdef0123456789abcdef",
    command:["/bin/sh","-c","exec pi --model fake --flag literal"],
    cwd:$cwd, env:{EXACT_ENV:"yes",STALE_TEXT:"must-not-run"}}
' "$REQUEST" >/dev/null || fail "layout request changed cwd, environment, argv, or exact replacement identity"
[ "$(grep -c '^lab-structural|' "$CALLS")" -eq "$(wc -l < "$CALLS" | tr -d ' ')" ] \
  || fail "a structural-launch read escaped its exact named session"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "successful layout did not leave one durable bound attempt"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 2 ] \
  || fail "successful layout attempt did not advance to exact replacement ids"
fm_backend_herdr_layout_attempt_commit "$ATTEMPT" \
  || fail "successful layout did not clear its temporary attempt label"
[ ! -e "$ATTEMPT" ] || fail "successful layout retained its attempt after exact commit"
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
  "$TMP_ROOT/worktree" '{}' '["pi"]' "$ATTEMPT" 0123456789abcdef0123456789abcdef >/dev/null 2>&1; then
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
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "post-response refusal lost its durable attempt"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 3 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = removed ] \
  || fail "confirmed cleanup did not resolve the structural attempt"
rm -f "$ATTEMPT"
pass "layout.apply cleans only the exact returned pane after a post-mutation identity refusal"
MODE=ok

HELPER_PAYLOAD="$TMP_ROOT/helper-payload.json"
printf '%s\n' '{"cwd":"/tmp/worktree","env":{"OPENAI_API_KEY":"credential-must-stay-off-argv"},"command":["pi"]}' > "$HELPER_PAYLOAD"
for response_mode in wrong-id error malformed; do
  start_server "$response_mode"
  set +e
  python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
    "$SOCK" w1 w1:t2 w1:p2 11111111111111111111111111111111 fm-launch-11111111111111111111111111111111 --stdin-v1 \
    < "$HELPER_PAYLOAD" >/dev/null 2>&1
  helper_status=$?
  set -e
  [ "$helper_status" -eq 3 ] || fail "protocol client did not classify $response_mode as an uncertain post-send result"
  wait_server
done
set +e
printf '%s\n' '{"cwd":"relative","env":{},"command":["pi"]}' | python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 11111111111111111111111111111111 fm-launch-11111111111111111111111111111111 --stdin-v1 >/dev/null 2>&1
helper_status=$?
set -e
[ "$helper_status" -eq 2 ] || fail "protocol client did not reject a relative cwd before send"
set +e
printf '%s\n' '{"cwd":"/tmp/worktree","env":[],"command":["pi"]}' | python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 11111111111111111111111111111111 fm-launch-11111111111111111111111111111111 --stdin-v1 >/dev/null 2>&1
helper_status=$?
set -e
[ "$helper_status" -eq 2 ] || fail "protocol client accepted a non-map environment"
set +e
printf '%s\n' '{"cwd":"/tmp/worktree","env":{},"command":[]}' | python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 11111111111111111111111111111111 fm-launch-11111111111111111111111111111111 --stdin-v1 >/dev/null 2>&1
helper_status=$?
set -e
[ "$helper_status" -eq 2 ] || fail "protocol client accepted an empty command argv"
start_server timeout
FM_HERDR_LAYOUT_APPLY_TIMEOUT_SECS=0.5 python3 "$ROOT/bin/backends/herdr-layout-apply.py" \
  "$SOCK" w1 w1:t2 w1:p2 11111111111111111111111111111111 fm-launch-11111111111111111111111111111111 --stdin-v1 \
  < "$HELPER_PAYLOAD" >/dev/null 2>&1 &
HELPER_PID=$!
for _ in $(seq 1 100); do
  [ -e "$APPLIED" ] && break
  sleep 0.005
done
[ -e "$APPLIED" ] || fail "credential argv probe never crossed the request-send boundary"
helper_args=$(ps -p "$HELPER_PID" -o args= 2>/dev/null || true)
assert_not_contains "$helper_args" 'credential-must-stay-off-argv' \
  "protocol helper exposed a credential through its process arguments"
set +e
wait "$HELPER_PID"
helper_status=$?
set -e
[ "$helper_status" -eq 3 ] || fail "protocol client did not quarantine a timed-out post-send request"
wait_server
pass "protocol client keeps payload values off argv and quarantines malformed, wrong-id, error, and timeout responses"

for response_mode in wrong-id error malformed timeout; do
  rm -f "$ATTEMPT" "$CLOSED"
  start_server "$response_mode"
  set +e
  if [ "$response_mode" = timeout ]; then
    FM_HERDR_LAYOUT_APPLY_TIMEOUT_SECS=0.05 run_layout >/dev/null 2>&1
  else
    run_layout >/dev/null 2>&1
  fi
  adapter_status=$?
  set -e
  [ "$adapter_status" -eq 3 ] || fail "adapter did not quarantine its $response_mode response"
  wait_server
  fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
    || fail "$response_mode response lost its durable attempt"
  [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 1 ] \
    || fail "$response_mode response invented replacement ids"
  MODE=reconcile
  fm_backend_herdr_layout_attempt_reconcile_remove "$ATTEMPT" \
    || fail "$response_mode response could not remove its exact replacement"
  rm -f "$ATTEMPT" "$CLOSED"
  MODE=ok
done
pass "uncertain responses preserve durable ownership until exact replacement cleanup"

CRASH_HELPER="$TMP_ROOT/crash-helper.py"
cat > "$CRASH_HELPER" <<'PY'
import json
import os
import socket
import sys
_, socket_path, workspace, tab, pane, attempt, label, contract = sys.argv
payload = json.load(sys.stdin)
request = {"id": "fm-layout-apply-" + attempt, "method": "layout.apply", "params": {
    "tab_id": tab, "root": {"type": "pane", "pane_id": pane, "label": label,
    "command": payload["command"], "cwd": payload["cwd"], "env": payload["env"]}}}
client = socket.socket(socket.AF_UNIX)
client.connect(socket_path)
client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
os._exit(99)
PY
rm -f "$ATTEMPT" "$CLOSED"
start_server success
set +e
FM_BACKEND_HERDR_LAYOUT_APPLY_HELPER="$CRASH_HELPER" run_layout >/dev/null 2>&1
crash_status=$?
set -e
wait_server
[ "$crash_status" -eq 3 ] || fail "crashed helper did not produce an uncertain adapter result"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" || fail "crashed helper lost its durable attempt"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 1 ] || fail "crashed helper unexpectedly claimed replacement ids"
MODE=reconcile
fm_backend_herdr_layout_attempt_reconcile_remove "$ATTEMPT" \
  || fail "one exact crash replacement was not safely reconciled"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" || fail "reconciliation erased ownership before lease cleanup"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 3 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = removed ] \
  || fail "successful reconciliation did not publish its safe terminal result"
rm -f "$ATTEMPT" "$CLOSED"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 1 0123456789abcdef0123456789abcdef \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef
MODE=reconcile_duplicate
if fm_backend_herdr_layout_attempt_reconcile_remove "$ATTEMPT" >/dev/null 2>&1; then
  fail "duplicate attempt labels were accepted for destructive reconciliation"
fi
[ ! -e "$CLOSED" ] || fail "duplicate reconciliation closed an ambiguous pane"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "duplicate refusal did not preserve quarantine"
rm -f "$ATTEMPT"
MODE=ok
start_server success
result=$(run_layout)
wait_server
[ "$result" = $'w1:t3\tw1:p3' ] || fail "safe retry did not launch after exact reconciliation"
rm -f "$ATTEMPT"
pass "crash quarantine refuses duplicates, reconciles one exact replacement, and permits a safe retry"

LEASE_LOG="$TMP_ROOT/lease-return.log"
LEASE_BIN=$(fm_fakebin "$TMP_ROOT/lease-bin")
cat > "$LEASE_BIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_LEASE_LOG:?}"
SH
chmod +x "$LEASE_BIN/treehouse"
: > "$LEASE_LOG"
PATH="$LEASE_BIN:$PATH" FM_LEASE_LOG="$LEASE_LOG" \
  fm_treehouse_lease_return_exact "$TMP_ROOT" "$TMP_ROOT/worktree" fm-task-z1 >/dev/null \
  || fail "holder-bound Treehouse return failed"
[ "$(cat "$LEASE_LOG")" = "return --force --if-lease-holder fm-task-z1 $TMP_ROOT/worktree" ] \
  || fail "Treehouse return was not bound to the exact lease holder"
if PATH="$LEASE_BIN:$PATH" FM_LEASE_LOG="$LEASE_LOG" \
  fm_treehouse_lease_return_exact "$TMP_ROOT" "$TMP_ROOT/worktree" '../other' >/dev/null 2>&1; then
  fail "invalid Treehouse lease holder reached the return command"
fi
[ "$(wc -l < "$LEASE_LOG" | tr -d ' ')" -eq 1 ] || fail "invalid holder issued a Treehouse return"
pass "aborted structural leases return only through their exact holder"

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
