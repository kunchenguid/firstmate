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
OLD_CLOSED="$TMP_ROOT/old-closed"
LABEL_CLEARED="$TMP_ROOT/label-cleared"
RENAME_BEFORE_RETIRE="$TMP_ROOT/rename-before-retire"
ATTEMPT="$TMP_ROOT/task.herdr-launch"
CALLS="$TMP_ROOT/calls.log"
SERVER_PID=
MODE=ok
CLOSE_READBACK=dead

layout_schema() {
  cat <<'JSON'
{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"layout.apply"}}},{"properties":{"method":{"const":"pane.report_agent"}}}],"$defs":{"LayoutApplyParams":{"required":["root"],"properties":{"workspace_id":{"type":["string","null"]},"tab_id":{"type":["string","null"]}}},"LayoutNode":{"oneOf":[{"properties":{"type":{"const":"pane"},"command":{"type":["array","null"]},"cwd":{"type":["string","null"]},"env":{"type":"object"},"label":{"type":["string","null"]},"pane_id":{"type":["string","null"]}}}]},"PaneReportAgentParams":{"required":["pane_id","source","agent","state"],"properties":{"agent":{"type":"string"},"state":{"$ref":"#/schemas/request/$defs/PaneAgentState"}}}}}}}
JSON
}

start_server() { # <success|wrong-id|error|malformed|timeout>
  local response=$1
  rm -f "$SOCK" "$REQUEST" "$APPLIED" "$CLOSED" "$LABEL_CLEARED" "$RENAME_BEFORE_RETIRE"
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
    restoring = request["params"]["root"]["label"].startswith("fm-restore-")
    tab_id = "w1:t4" if restoring else "w1:t3"
    pane_id = "w1:p4" if restoring else "w1:p3"
    response = {"id": request["id"], "result": {"type": "layout_apply", "layout": {
        "workspace_id": "w1", "tab_id": tab_id, "focused_pane_id": pane_id,
        "root": {"type": "pane", "pane_id": pane_id}}}}
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
      case "$MODE" in
        protocol) printf '%s\n' '{"client":{"protocol":19},"server":{"protocol":20,"running":true}}' ;;
        protocol22) printf '%s\n' '{"client":{"protocol":22},"server":{"protocol":22,"running":true}}' ;;
        *) printf '%s\n' '{"client":{"protocol":20},"server":{"protocol":20,"running":true}}' ;;
      esac
      ;;
    "api schema --json")
      if [ "$MODE" = schema ]; then printf '%s\n' '{"schemas":{"request":{}}}'; else layout_schema; fi
      ;;
    "workspace list")
      if [ "$MODE" = workspace ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9"}]}}'
      elif [ "$MODE" = reconcile_retain ] || [ "$MODE" = remove_original ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"anchor","focused":true,"active_tab_id":"anchor:t1"},{"workspace_id":"w1","focused":false,"active_tab_id":"w1:t3"}]}}'
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
      if [ -e "$OLD_CLOSED" ]; then
        printf '%s\n' '{"error":{"code":"pane_not_found"}}'
        return 0
      fi
      case "$MODE" in
        reconcile|reconcile_duplicate|reconcile_missing|reconcile_retain) return 1 ;;
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
    "tab list --workspace anchor")
      printf '%s\n' '{"result":{"tabs":[{"workspace_id":"anchor","tab_id":"anchor:t1","focused":true}]}}'
      ;;
    "tab list --workspace w1")
      printf '%s\n' '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","focused":false},{"workspace_id":"w1","tab_id":"w1:t3","focused":true}]}}'
      ;;
    "terminal title clear")
      printf '%s\n' '{"result":{"reason":"no_foreground_client"}}'
      ;;
    "tab get w1:t4")
      printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t4"}}}'
      ;;
    "pane list --workspace w1")
      case "$MODE" in
        remove_original)
          printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":null},{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p9","label":null}]}}'
          ;;
        reconcile_duplicate)
          printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"fm-launch-0123456789abcdef0123456789abcdef"},{"workspace_id":"w1","tab_id":"w1:t4","pane_id":"w1:p4","label":"fm-launch-0123456789abcdef0123456789abcdef"}]}}'
          ;;
        reconcile_missing) printf '%s\n' '{"result":{"panes":[]}}' ;;
        reconcile_retain)
          printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"fm-launch-0123456789abcdef0123456789abcdef"}]}}'
          ;;
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
      if [ -e "$CLOSED" ]; then
        if [ "$CLOSE_READBACK" = dead ]; then
          printf '%s\n' '{"error":{"code":"pane_not_found"}}'
        else
          printf '%s\n' 'unreadable response'
          return 1
        fi
      elif [ -e "$LABEL_CLEARED" ]; then
        printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":null}}}'
      else
        label=$(jq -r '.params.root.label // "fm-launch-0123456789abcdef0123456789abcdef"' "$REQUEST" 2>/dev/null || printf 'fm-launch-0123456789abcdef0123456789abcdef')
        printf '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"%s"}}}\n' "$label"
      fi
      ;;
    "pane rename w1:p3 --clear")
      [ ! -e "$ATTEMPT" ] || : > "$RENAME_BEFORE_RETIRE"
      [ "$MODE" != rename_failure ] || return 1
      : > "$LABEL_CLEARED"
      printf '%s\n' '{"result":{"type":"pane_rename","pane_id":"w1:p3"}}'
      ;;
    "pane close w1:p2")
      : > "$OLD_CLOSED"
      printf '%s\n' '{"result":{"type":"pane_close","pane_id":"w1:p2"}}'
      ;;
    "pane close w1:p3")
      : > "$CLOSED"
      printf '%s\n' '{"result":{"type":"pane_close","pane_id":"w1:p3"}}'
      ;;
    "pane get w1:p4")
      printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t4","pane_id":"w1:p4","label":"fm-restore-0123456789abcdef0123456789abcdef"}}}'
      ;;
    "pane process-info --pane w1:p3")
      if [ "$MODE" = wrong-agent ]; then
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"codex","argv0":"codex","argv":["codex"],"cmdline":"codex"}]}}}'
      else
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi","--model","fake"],"cmdline":"pi --model fake"}]}}}'
      fi
      ;;
    "pane process-info --pane w1:p4")
      printf '%s\n' "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p4\",\"shell_pid\":$$,\"foreground_processes\":[{\"pid\":$$,\"name\":\"sh\",\"argv0\":\"/bin/sh\",\"argv\":[\"/bin/sh\"]}]}}}"
      ;;
    "agent get w1:p4")
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      ;;
    "pane rename w1:p4 --clear")
      printf '%s\n' '{"result":{"type":"pane_rename","pane_id":"w1:p4"}}'
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
    "$ATTEMPT" 0123456789abcdef0123456789abcdef fresh task-z1 fm-task-z1
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
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 5 ] \
  || fail "successful layout attempt did not advance to exact replacement ids"
fm_backend_herdr_layout_attempt_commit "$ATTEMPT" \
  || fail "successful layout did not retire its exact attempt"
[ ! -e "$ATTEMPT" ] || fail "successful layout retained its attempt after exact commit"
[ ! -e "$RENAME_BEFORE_RETIRE" ] \
  || fail "successful layout cleared its correlation label before retiring the attempt"
rm -f "$LABEL_CLEARED"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 5 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef w1:t3 w1:p3
MODE=rename_failure
fm_backend_herdr_layout_attempt_commit "$ATTEMPT" \
  || fail "label-clear failure stranded an otherwise committed layout attempt"
[ ! -e "$ATTEMPT" ] || fail "label-clear failure retained a committed layout attempt"
MODE=ok
pass "layout.apply preserves exact cwd/environment/argv and binds only response ids re-read from the named session"

for mode in protocol protocol22 schema workspace tab pane layout foreground socket; do
  MODE=$mode
  rm -f "$REQUEST" "$APPLIED"
  if run_layout >/dev/null 2>&1; then
    fail "layout adapter accepted the $mode mismatch"
  fi
  [ ! -e "$APPLIED" ] || fail "layout adapter mutated Herdr before refusing the $mode mismatch"
done
MODE=ok
if fm_backend_herdr_layout_apply lab-structural:w1:p9 w1 w1:t2 w1:p2 \
  "$TMP_ROOT/worktree" '{}' '["pi"]' "$ATTEMPT" 0123456789abcdef0123456789abcdef \
  fresh task-z1 fm-task-z1 >/dev/null 2>&1; then
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
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 6 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = removed ] \
  || fail "confirmed cleanup did not resolve the structural attempt"
rm -f "$ATTEMPT"
pass "layout.apply cleans only the exact returned pane after a post-mutation identity refusal"
MODE=ok

CLOSE_READBACK=unreadable
rm -f "$CLOSED"
if fm_backend_herdr_layout_discard_response_pane lab-structural w1:p3 >/dev/null 2>&1; then
  fail "response-pane cleanup accepted an unreadable post-close pane response"
fi
rm -f "$CLOSED"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef
MODE=reconcile
if fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" >/dev/null 2>&1; then
  fail "quarantine reconciliation accepted an unreadable post-close pane response"
fi
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "unreadable post-close reconciliation lost its durable attempt"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 4 ] \
  || fail "unreadable post-close reconciliation advanced its durable attempt"
rm -f "$ATTEMPT" "$CLOSED"
MODE=ok
CLOSE_READBACK=dead
pass "structural cleanup advances only after explicit pane absence"

rm -f "$ATTEMPT" "$OLD_CLOSED"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 6 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef \
  w1:t2 w1:p2 not-applied
MODE=remove_original
: > "$CALLS"
fm_backend_herdr_layout_attempt_remove_original "$ATTEMPT" \
  || fail "fresh not-applied recovery did not close its original shell"
[ -e "$OLD_CLOSED" ] || fail "fresh not-applied recovery left its original shell open"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "fresh original-shell removal lost its durable attempt"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 6 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = removed ] \
  || fail "fresh original-shell removal did not publish its durable result"
[ "$(grep -c '^lab-structural|pane close w1:p2$' "$CALLS")" -eq 1 ] \
  || fail "fresh not-applied recovery did not close exactly one original pane"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 6 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef \
  w1:t2 w1:p2 not-applied
fm_backend_herdr_layout_attempt_remove_original "$ATTEMPT" \
  || fail "fresh original-shell recovery could not resume after a confirmed close"
[ "$(grep -c '^lab-structural|pane close w1:p2$' "$CALLS")" -eq 1 ] \
  || fail "fresh original-shell recovery repeated an already confirmed close"
rm -f "$ATTEMPT" "$OLD_CLOSED"
MODE=ok
pass "fresh not-applied recovery closes and durably retires its exact original shell"

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
  [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 4 ] \
    || fail "$response_mode response invented replacement ids"
  MODE=reconcile
  fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" \
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
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 4 ] || fail "crashed helper unexpectedly claimed replacement ids"
MODE=reconcile
fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" \
  || fail "one exact crash replacement was not safely reconciled"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" || fail "reconciliation erased ownership before lease cleanup"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 6 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = removed ] \
  || fail "successful reconciliation did not publish its safe terminal result"
rm -f "$ATTEMPT" "$CLOSED"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef
MODE=reconcile_duplicate
if fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" >/dev/null 2>&1; then
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

rm -f "$ATTEMPT"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 5 0123456789abcdef0123456789abcdef \
  relaunch task-z1 "$TMP_ROOT/worktree" - \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef w1:t3 w1:p3
MODE=reconcile_retain
start_server success
fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" \
  || fail "retained Pi replacement did not restore an inert shell"
wait_server
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "retained restoration lost its durable transaction"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 7 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = restored ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_NEW_TAB:$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_NEW_PANE" = "w1:t3:w1:p3" ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESTORE_TAB:$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESTORE_PANE" = "w1:t4:w1:p4" ] \
  || fail "retained restoration did not preserve source and restored identities"
jq -e --arg cwd "$TMP_ROOT/worktree" '
  .params.root.command == ["/bin/sh"]
  and .params.root.cwd == $cwd
  and .params.root.env == {}
  and .params.root.label == "fm-restore-0123456789abcdef0123456789abcdef"
' "$REQUEST" >/dev/null || fail "retained restoration launched an agent or transported environment values"
fm_backend_herdr_layout_attempt_commit_restored "$ATTEMPT" \
  || fail "verified inert-shell restoration did not retire its transaction"
[ ! -e "$ATTEMPT" ] || fail "restored attempt remained quarantined after exact commit"
MODE=ok
pass "retained relaunch restoration preserves source identity and creates one credential-free inert shell"

RELAUNCH_HOME="$TMP_ROOT/relaunch-home"
RELAUNCH_PROJECT="$TMP_ROOT/relaunch-project"
RELAUNCH_WT="$TMP_ROOT/relaunch-worktree"
RELAUNCH_ID=layout-relaunch
RELAUNCH_ATTEMPT="$RELAUNCH_HOME/state/$RELAUNCH_ID.herdr-launch"
RELAUNCH_FAKEBIN=$(fm_fakebin "$TMP_ROOT/relaunch-fake")
fm_git_worktree "$RELAUNCH_PROJECT" "$RELAUNCH_WT" "task-$RELAUNCH_ID"
mkdir -p "$RELAUNCH_HOME/state" "$RELAUNCH_HOME/data/$RELAUNCH_ID" "$RELAUNCH_HOME/config"
cat > "$RELAUNCH_HOME/data/$RELAUNCH_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise retained Herdr relaunch recovery.

## Firstmate spec
Preserve the task endpoint while restoring a safe shell.
EOF
cat > "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" <<EOF
window=lab-structural:w1:p3
endpoint_task_id=$RELAUNCH_ID
worktree=$RELAUNCH_WT
project=$RELAUNCH_PROJECT
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$RELAUNCH_ID
model=default
effort=default
backend=herdr
herdr_root=$ROOT
herdr_session=lab-structural
herdr_workspace_id=w1
herdr_tab_id=w1:t3
herdr_pane_id=w1:p3
EOF
fm_backend_herdr_layout_attempt_write "$RELAUNCH_ATTEMPT" 5 0123456789abcdef0123456789abcdef \
  relaunch "$RELAUNCH_ID" "$RELAUNCH_WT" - \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef w1:t3 w1:p3
cat > "$RELAUNCH_FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${*: -2:1}" = --session ]; then
  set -- "${@:1:$#-2}"
fi
case "$*" in
  "status --json")
    printf '%s\n' '{"client":{"version":"test","protocol":20},"server":{"protocol":20,"running":true}}'
    ;;
  "api schema --json")
    cat <<'JSON'
{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"layout.apply"}}}],"$defs":{"LayoutNode":{"oneOf":[{"properties":{"type":{"const":"pane"},"command":{"type":["array","null"]},"cwd":{"type":["string","null"]},"env":{"type":"object"},"label":{"type":["string","null"]},"pane_id":{"type":["string","null"]}}}]}}}}}
JSON
    ;;
  "session list --json")
    printf '{"sessions":[{"name":"lab-structural","running":true,"socket_path":"%s"}]}\n' "$FM_FAKE_HERDR_SOCKET"
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"anchor","focused":true,"active_tab_id":"anchor:t1"},{"workspace_id":"w1","focused":false,"active_tab_id":"w1:t3"}]}}'
    ;;
  "tab list --workspace anchor")
    printf '%s\n' '{"result":{"tabs":[{"workspace_id":"anchor","tab_id":"anchor:t1","focused":true}]}}'
    ;;
  "tab get w1:t4")
    printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t4"}}}'
    ;;
  "pane list --workspace w1")
    if [ -e "$FM_FAKE_HERDR_APPLIED" ]; then
      printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t4","pane_id":"w1:p4","label":"fm-restore-0123456789abcdef0123456789abcdef"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"fm-launch-0123456789abcdef0123456789abcdef"}]}}'
    fi
    ;;
  "pane get w1:p2")
    printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    exit 1
    ;;
  "pane get w1:p3")
    if [ -e "$FM_FAKE_HERDR_APPLIED" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    else
      printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"fm-launch-0123456789abcdef0123456789abcdef"}}}'
    fi
    ;;
  "pane get w1:p4")
    printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t4","pane_id":"w1:p4","label":"fm-restore-0123456789abcdef0123456789abcdef"}}}'
    ;;
  "pane process-info --pane w1:p3")
    printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi","--model","fake"]}]}}}'
    ;;
  "pane process-info --pane w1:p4")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p4","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash","argv":["bash"]}]}}}\n' "$FM_FAKE_HERDR_PARENT_PID" "$FM_FAKE_HERDR_PARENT_PID"
    ;;
  "agent get w1:p3")
    printf '%s\n' '{"result":{"agent":{"pane_id":"w1:p3","agent":"pi","agent_status":"working"}}}'
    ;;
  "agent get w1:p4")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    ;;
  "pane rename w1:p4 --clear")
    printf '%s\n' '{"result":{"type":"pane_rename","pane_id":"w1:p4"}}'
    ;;
  *)
    printf 'unexpected fake Herdr call: %s\n' "$*" >&2
    exit 92
    ;;
esac
SH
chmod +x "$RELAUNCH_FAKEBIN/herdr"
start_server success
set +e
relaunch_out=$(FM_FAKE_HERDR_SOCKET="$SOCK" FM_FAKE_HERDR_APPLIED="$APPLIED" \
  FM_FAKE_HERDR_PARENT_PID="$$" \
  fm_test_run_spawn "$RELAUNCH_HOME" "$RELAUNCH_WT" "$RELAUNCH_FAKEBIN" \
    "$RELAUNCH_ID" --relaunch --harness pi)
relaunch_status=$?
set -e
if [ -e "$APPLIED" ]; then
  wait_server
else
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
  fail "retained recovery did not reach structural restoration: $relaunch_out"
fi
[ "$relaunch_status" -ne 0 ] || fail "retained recovery unexpectedly launched before its explicit retry"
assert_contains "$relaunch_out" "inert shell endpoint was restored" \
  "relaunch did not reconcile its live rebound structural replacement"
assert_not_contains "$relaunch_out" "positively agent-free endpoint" \
  "generic liveness rejected the live rebound endpoint before structural reconciliation"
assert_grep 'window=lab-structural:w1:p4' "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" \
  "relaunch did not publish the restored inert-shell endpoint"
assert_grep 'herdr_tab_id=w1:t4' "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" \
  "relaunch did not publish the restored tab identity"
assert_grep 'herdr_pane_id=w1:p4' "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" \
  "relaunch did not publish the restored pane identity"
[ ! -e "$RELAUNCH_ATTEMPT" ] || fail "relaunch left a rebound structural attempt quarantined"
pass "fm-spawn reconciles a live retained replacement before ordinary relaunch liveness"

for ownership_mode in fresh relaunch secondmate; do
  lease_holder=-
  expected_policy=retain
  if [ "$ownership_mode" = fresh ]; then
    lease_holder=fm-task-z1
    expected_policy=release-fresh
  fi
  fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
    "$ownership_mode" task-z1 "$TMP_ROOT/worktree" "$lease_holder" \
    lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef \
    || fail "$ownership_mode ownership record was refused"
  fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
    || fail "$ownership_mode ownership record was unreadable"
  policy=$(fm_backend_herdr_layout_attempt_ownership_policy \
    "$ownership_mode" task-z1 "$TMP_ROOT/worktree") \
    || fail "$ownership_mode ownership policy was refused"
  [ "$policy" = "$expected_policy" ] \
    || fail "$ownership_mode ownership policy returned $policy"
  resolutions='restored not-applied'
  [ "$ownership_mode" != fresh ] || resolutions='removed not-applied'
  for resolution in $resolutions; do
    action=$(fm_backend_herdr_layout_attempt_recovery_action \
      "$ownership_mode" task-z1 "$TMP_ROOT/worktree" "$resolution") \
      || fail "$ownership_mode $resolution recovery action was refused"
    case "$ownership_mode:$resolution:$action" in
      fresh:removed:release-fresh|fresh:not-applied:release-fresh|\
      relaunch:restored:retain-retry|secondmate:restored:retain-retry|\
      relaunch:not-applied:retain-continue|secondmate:not-applied:retain-continue) ;;
      *) fail "$ownership_mode $resolution recovery action was unsafe: $action" ;;
    esac
  done
  rm -f "$ATTEMPT"
done
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" || fail "worktree mismatch fixture was unreadable"
rm -f "$CLOSED"
if fm_backend_herdr_layout_attempt_ownership_policy \
  fresh task-z1 "$TMP_ROOT/other-worktree" >/dev/null 2>&1; then
  fail "ownership policy accepted a stale attempt worktree"
fi
[ -e "$ATTEMPT" ] || fail "worktree mismatch refusal retired the attempt record"
[ ! -e "$CLOSED" ] || fail "worktree mismatch refusal closed a pane"
rm -f "$ATTEMPT"
if fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  relaunch task-z1 "$TMP_ROOT/worktree" fm-task-z1 \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef >/dev/null 2>&1; then
  fail "relaunch ownership record accepted fresh lease authority"
fi
if fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" - \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef >/dev/null 2>&1; then
  fail "fresh ownership record accepted missing lease authority"
fi
cat > "$ATTEMPT" <<EOF
version=3
attempt=0123456789abcdef0123456789abcdef
session=lab-structural
workspace=w1
old_tab=w1:t2
old_pane=w1:p2
label=fm-launch-0123456789abcdef0123456789abcdef
new_tab=w1:t3
new_pane=w1:p3
resolution=removed
EOF
if fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" >/dev/null 2>&1; then
  fail "legacy ownership-free attempt record was accepted"
fi
rm -f "$ATTEMPT"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  secondmate task-z1 "$TMP_ROOT/worktree" - \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef
printf '%s\n' 'unexpected=field' >> "$ATTEMPT"
if fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" >/dev/null 2>&1; then
  fail "contradictory attempt record was accepted"
fi
rm -f "$ATTEMPT"
pass "ownership records release only proven fresh leases and retain relaunch and secondmate work"

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

NON_PI="$TMP_ROOT/non-pi"
NON_PI_HOME="$NON_PI/home"
NON_PI_PROJECT="$NON_PI/project"
NON_PI_WT="$NON_PI/worktree"
NON_PI_LOG="$NON_PI/herdr.log"
NON_PI_STATE="$NON_PI/herdr-state.json"
NON_PI_SEND_FAIL="$NON_PI/send-fail"
NON_PI_FAKEBIN=$(fm_fakebin "$NON_PI/bin")
fm_test_spawn_home "$NON_PI_HOME" pi-signed
printf 'off\n' > "$NON_PI_HOME/config/herdr-presentation-spaces"
fm_test_spawn_brief "$NON_PI_HOME" non-pi-z1 "Preserve the existing interactive Herdr launch path."
fm_git_worktree "$NON_PI_PROJECT" "$NON_PI_WT" non-pi-worktree
# shellcheck source=tests/remote-herdr-fixture.sh
. "$ROOT/tests/remote-herdr-fixture.sh"
install_remote_herdr_fixture "$NON_PI" "$NON_PI_STATE" "$NON_PI_LOG" "$NON_PI_SEND_FAIL" "$SOCK"
ln -s ../herdr "$NON_PI_FAKEBIN/herdr"
cat > "$NON_PI_FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_PANE_PATH:?}"
SH
fm_fake_exit0 "$NON_PI_FAKEBIN" pi-signed
chmod +x "$NON_PI_FAKEBIN/treehouse"
set +e
non_pi_out=$(HERDR_SESSION=lab-structural \
  fm_test_run_spawn "$NON_PI_HOME" "$NON_PI_WT" "$NON_PI_FAKEBIN" \
    non-pi-z1 "$NON_PI_PROJECT" --scout --harness pi-signed --backend herdr)
non_pi_status=$?
set -e
[ "$non_pi_status" -eq 0 ] || fail "non-Pi Herdr launch no longer reaches its existing interactive path: $non_pi_out"
assert_grep 'pane send-text' "$NON_PI_LOG" "non-Pi Herdr launch did not type its launch command"
assert_grep 'pane send-keys' "$NON_PI_LOG" "non-Pi Herdr launch did not submit through the existing key path"
assert_not_contains "$non_pi_out" "structural Herdr launch" \
  "non-Pi Herdr launch was incorrectly routed through plain-Pi structural handling"
pass "non-Pi Herdr harnesses retain interactive launch behavior without Pi normalization"

printf '# all fm-herdr-layout-apply tests passed\n'
