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
TEST_LEASE_HOLDER=fm-task-z1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

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
elif response_mode == "misdirected":
    response = {"id": request["id"], "result": {"type": "layout_apply", "layout": {
        "workspace_id": "w1", "tab_id": "w1:t8", "focused_pane_id": "w1:p8",
        "root": {"type": "pane", "pane_id": "w1:p8"}}}}
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
      elif [ "$MODE" = reconcile_retain ] || [ "$MODE" = reconcile_shell ] || [ "$MODE" = remove_original ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"anchor","focused":true,"active_tab_id":"anchor:t1"},{"workspace_id":"w1","focused":false,"active_tab_id":"w1:t3"}]}}'
      elif [ "$MODE" = focused_cleanup ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","focused":true,"active_tab_id":"w1:t3"}]}}'
      elif [ "$MODE" = token_workspace ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","label":"└ task-z1 · p:abcdefghijklmnopqrstuv","focused":true,"active_tab_id":"w9:t3"}]}}'
      elif [ "$MODE" = renamed_workspace ]; then
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"renamed-by-user","focused":true,"active_tab_id":"w1:t9","pane_count":2}]}}'
      else
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","focused":true,"active_tab_id":"w1:t2"}]}}'
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
        reconcile|reconcile_duplicate|reconcile_missing|reconcile_retain|reconcile_shell|focused_cleanup) return 1 ;;
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
      if [ "$MODE" = focused_cleanup ]; then
        printf '%s\n' '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","focused":false},{"workspace_id":"w1","tab_id":"w1:t3","focused":true}]}}'
      else
        printf '%s\n' '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","focused":true},{"workspace_id":"w1","tab_id":"w1:t3","focused":false}]}}'
      fi
      ;;
    "terminal title clear")
      if [ "$MODE" = focused_cleanup ]; then
        printf '%s\n' '{"result":{"reason":"cleared"}}'
      else
        printf '%s\n' '{"result":{"reason":"no_foreground_client"}}'
      fi
      ;;
    "tab get w1:t4")
      printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t4"}}}'
      ;;
    "tab get w1:t8")
      printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t8"}}}'
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
        reconcile_retain|reconcile_shell|focused_cleanup)
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
    "pane get w1:p8")
      printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t8","pane_id":"w1:p8","label":"captain-pane"}}}'
      ;;
    "pane close w1:p8")
      fail "adapter attempted to close an unverified response-named pane"
      ;;
    "pane process-info --pane w1:p3")
      if [ "$MODE" = wrong-agent ]; then
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"codex","argv0":"codex","argv":["codex"],"cmdline":"codex"}]}}}'
      elif [ "$MODE" = reconcile_shell ]; then
        printf '%s\n' "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p3\",\"shell_pid\":$$,\"foreground_processes\":[{\"pid\":$$,\"name\":\"sh\",\"argv0\":\"/bin/sh\",\"argv\":[\"/bin/sh\"]}]}}}"
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
    "$ATTEMPT" 0123456789abcdef0123456789abcdef fresh task-z1 "$TEST_LEASE_HOLDER"
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
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef w1:t3 w1:p3
MODE=rename_failure
fm_backend_herdr_layout_attempt_commit "$ATTEMPT" \
  || fail "label-clear failure stranded an otherwise committed layout attempt"
[ ! -e "$ATTEMPT" ] || fail "label-clear failure retained a committed layout attempt"
MODE=ok
pass "layout.apply preserves exact cwd/environment/argv and binds only response ids re-read from the named session"

for mode in protocol protocol22 schema workspace tab pane layout foreground socket; do
  MODE=$mode
  rm -f "$REQUEST" "$APPLIED" "$ATTEMPT"
  if run_layout >/dev/null 2>&1; then
    fail "layout adapter accepted the $mode mismatch"
  fi
  [ ! -e "$APPLIED" ] || fail "layout adapter mutated Herdr before refusing the $mode mismatch"
  fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
    || fail "layout adapter did not preserve durable ownership across the $mode refusal"
  [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 4 ] \
    || fail "layout adapter advanced ownership despite the $mode pre-send refusal"
done
rm -f "$ATTEMPT"
MODE=ok
if fm_backend_herdr_layout_apply lab-structural:w1:p9 w1 w1:t2 w1:p2 \
  "$TMP_ROOT/worktree" '{}' '["pi"]' "$ATTEMPT" 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TEST_LEASE_HOLDER" >/dev/null 2>&1; then
  fail "layout adapter accepted a target/pane identity mismatch"
fi
pass "layout.apply refuses every protocol, schema, socket, session, container, layout, and foreground identity mismatch before mutation"

REJECT_HELPER="$TMP_ROOT/reject-helper.py"
cat > "$REJECT_HELPER" <<'PY'
import sys
sys.exit(2)
PY
rm -f "$ATTEMPT"
MODE=ok
set +e
FM_BACKEND_HERDR_LAYOUT_APPLY_HELPER="$REJECT_HELPER" run_layout >/dev/null 2>&1
reject_status=$?
set -e
[ "$reject_status" -eq 2 ] || fail "pre-send helper refusal returned the wrong classification"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "pre-send helper refusal discarded its durable recovery marker"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 4 ] \
  || fail "pre-send helper refusal advanced ownership without sending"
rm -f "$ATTEMPT"
pass "known pre-send refusals retain their durable structural recovery marker"

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
pass "layout.apply reconciles only the independently verified launch label after an identity refusal"
MODE=misdirected
rm -f "$ATTEMPT" "$CLOSED"
: > "$CALLS"
start_server misdirected
if run_layout >/dev/null 2>&1; then
  fail "layout adapter accepted a response naming an unrelated pane"
fi
wait_server
assert_no_grep 'pane close w1:p8' "$CALLS" \
  "post-mutation refusal closed the unverified response-named pane"
[ "$(grep -c '^lab-structural|pane close w1:p3$' "$CALLS")" -eq 1 ] \
  || fail "post-mutation refusal did not reconcile the independently labeled replacement"
rm -f "$ATTEMPT" "$CLOSED"
MODE=focused_cleanup
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef
if fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" >/dev/null 2>&1; then
  fail "quarantine reconciliation closed the active tab viewed by a foreground client"
fi
[ ! -e "$CLOSED" ] || fail "quarantine focus refusal still closed its target pane"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "focus refusal lost its durable structural attempt"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 4 ] \
  || fail "focus refusal advanced structural ownership without cleanup"
rm -f "$ATTEMPT"
MODE=ok
pass "structural cleanup preserves quarantine while its target tab is actively viewed"

MODE=reconcile_retain
CLOSE_READBACK=dead
rm -f "$CLOSED"
: > "$OLD_CLOSED"
fm_backend_herdr_projection_cleanup_exact lab-structural w1:p3 w1:p2 1 \
  || fail "spawn abort cleanup quarantined an already-pruned seeded pane"
[ -e "$CLOSED" ] || fail "spawn abort cleanup skipped its live task pane"
rm -f "$CLOSED"
if fm_backend_herdr_projection_cleanup_exact lab-structural w1:p3 w1:p2 0 >/dev/null 2>&1; then
  fail "spawn abort cleanup ignored an unconfirmed seeded pane"
fi
rm -f "$CLOSED" "$OLD_CLOSED"
CLOSE_READBACK=unreadable
if fm_backend_herdr_projection_cleanup_exact lab-structural w1:p3 '' >/dev/null 2>&1; then
  fail "spawn abort cleanup accepted an unreadable post-close task pane response"
fi
rm -f "$CLOSED"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
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
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
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
fm_backend_herdr_layout_attempt_mark_released "$ATTEMPT" \
  || fail "fresh cleanup did not publish its terminal released receipt"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 8 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = released ] \
  || fail "fresh cleanup terminal receipt did not remain readable"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 6 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef \
  w1:t2 w1:p2 not-applied
fm_backend_herdr_layout_attempt_remove_original "$ATTEMPT" \
  || fail "fresh original-shell recovery could not resume after a confirmed close"
[ "$(grep -c '^lab-structural|pane close w1:p2$' "$CALLS")" -eq 1 ] \
  || fail "fresh original-shell recovery repeated an already confirmed close"
rm -f "$ATTEMPT" "$OLD_CLOSED"
MODE=ok
pass "fresh not-applied recovery closes and durably retires its exact original shell"

JOURNAL="$TMP_ROOT/task.herdr-presentation"
TOKEN=abcdefghijklmnopqrstuv
WORKSPACE_LABEL=$(fm_backend_herdr_projection_workspace_label task-z1 "$TOKEN")
printf 'version=1\ntask_id=task-z1\nprojection_id=%s\n' "$TOKEN" > "$JOURNAL"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 6 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef \
  w1:t3 w1:p3 removed
fm_backend_herdr_projection_journal_write_v2 \
  "$JOURNAL" task-z1 "$TOKEN" "$TMP_ROOT" lab-structural w1 w1:t9 w1:p9 \
  anchor firstmate "$WORKSPACE_LABEL" fm-task-z1
: > "$CLOSED"
: > "$OLD_CLOSED"
if fm_backend_herdr_projection_journal_retire_removed_attempt \
  "$JOURNAL" task-z1 "$ATTEMPT" >/dev/null 2>&1; then
  fail "fresh recovery retired a presentation journal bound to another endpoint"
fi
[ -e "$JOURNAL" ] || fail "mismatched presentation journal was not preserved"
fm_backend_herdr_projection_journal_write_v2 \
  "$JOURNAL" task-z1 "$TOKEN" "$TMP_ROOT" lab-structural w1 w1:t2 w1:p2 \
  anchor firstmate "$WORKSPACE_LABEL" fm-task-z1
fm_backend_herdr_projection_journal_retire_removed_attempt \
  "$JOURNAL" task-z1 "$ATTEMPT" \
  || fail "fresh recovery did not retire its exact removed endpoint's presentation journal"
[ ! -e "$JOURNAL" ] || fail "fresh recovery left its correlated presentation journal behind"
printf 'version=1\ntask_id=task-z1\nprojection_id=%s\n' "$TOKEN" > "$JOURNAL"
MODE=token_workspace
if fm_backend_herdr_projection_journal_retire_removed_attempt \
  "$JOURNAL" task-z1 "$ATTEMPT" >/dev/null 2>&1; then
  fail "fresh recovery retired an unbound presentation journal while its token workspace remained"
fi
[ -e "$JOURNAL" ] || fail "live token workspace lost its unbound presentation journal"
MODE=renamed_workspace
if fm_backend_herdr_projection_journal_retire_removed_attempt \
  "$JOURNAL" task-z1 "$ATTEMPT" >/dev/null 2>&1; then
  fail "fresh recovery retired an unbound journal while its renamed exact workspace remained"
fi
[ -e "$JOURNAL" ] || fail "renamed exact workspace with concurrent panes lost its unbound journal"
MODE=workspace
fm_backend_herdr_projection_journal_retire_removed_attempt \
  "$JOURNAL" task-z1 "$ATTEMPT" \
  || fail "fresh recovery did not retire its absent token workspace's unbound presentation journal"
[ ! -e "$JOURNAL" ] || fail "absent token workspace left its unbound presentation journal behind"
MODE=ok
printf 'version=1\ntask_id=task-z1\nprojection_id=%s\n' "$TOKEN" > "$JOURNAL"
fm_backend_herdr_projection_journal_write_v2 \
  "$JOURNAL" task-z1 "$TOKEN" "$TMP_ROOT" lab-structural w1 w1:t3 w1:p3 \
  anchor firstmate "$WORKSPACE_LABEL" fm-task-z1
fm_backend_herdr_projection_journal_retire_closed_endpoint \
  "$JOURNAL" task-z1 lab-structural w1 w1:p3 \
  || fail "confirmed post-commit endpoint cleanup did not retire its presentation journal"
[ ! -e "$JOURNAL" ] || fail "post-commit cleanup left its exact presentation journal behind"
rm -f "$ATTEMPT" "$CLOSED" "$OLD_CLOSED"
pass "confirmed endpoint cleanup retires only its exact presentation journal"

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
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
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
MODE=reconcile_shell
rm -f "$APPLIED"
start_server success
fm_backend_herdr_layout_attempt_reconcile "$ATTEMPT" \
  || fail "retained launch shell did not pass through structural restoration"
wait_server
[ -e "$APPLIED" ] || fail "retained launch shell bypassed structural restoration"
jq -e --arg env_bin "$(command -v env)" '
  .params.root.command == [$env_bin, "-i", "/bin/sh"]
  and .params.root.env == {}
  and .params.root.label == "fm-restore-0123456789abcdef0123456789abcdef"
' "$REQUEST" >/dev/null || fail "retained launch shell restoration inherited destination environment values"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  || fail "launch-shell restoration lost its durable transaction"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 7 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESTORE_PANE" = w1:p4 ] \
  || fail "launch-shell restoration accepted the credential-bearing source shell as restored"
rm -f "$ATTEMPT"
MODE=ok
pass "retained launch shells are structurally replaced with credential-free inert shells"

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
jq -e --arg cwd "$TMP_ROOT/worktree" --arg env_bin "$(command -v env)" '
  .params.root.command == [$env_bin, "-i", "/bin/sh"]
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
rm -f "$APPLIED" "$REQUEST"
set +e
relaunch_out=$(FM_FAKE_HERDR_SOCKET="$SOCK" FM_FAKE_HERDR_APPLIED="$APPLIED" \
  FM_FAKE_HERDR_PARENT_PID="$$" \
  fm_test_run_spawn "$RELAUNCH_HOME" "$RELAUNCH_WT" "$RELAUNCH_FAKEBIN" \
    "$RELAUNCH_ID" --relaunch --harness pi)
relaunch_status=$?
set -e
[ "$relaunch_status" -eq 0 ] || fail "retained committed receipt recovery failed: $relaunch_out"
[ ! -e "$APPLIED" ] || fail "retained committed receipt recovery launched a replacement shell"
assert_contains "$relaunch_out" "already-committed structural Herdr worker" \
  "relaunch did not recognize its exact rebound live Pi as committed"
assert_grep 'window=lab-structural:w1:p3' "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" \
  "relaunch changed its committed rebound endpoint"
assert_grep 'herdr_tab_id=w1:t3' "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" \
  "relaunch changed its committed tab identity"
assert_grep 'herdr_pane_id=w1:p3' "$RELAUNCH_HOME/state/$RELAUNCH_ID.meta" \
  "relaunch changed its committed pane identity"
[ ! -e "$RELAUNCH_ATTEMPT" ] || fail "relaunch left its committed receipt quarantined"
pass "fm-spawn preserves exact live retained workers during receipt recovery"

for ownership_mode in fresh relaunch secondmate; do
  lease_holder=-
  expected_policy=retain
  if [ "$ownership_mode" = fresh ]; then
    lease_holder=$TEST_LEASE_HOLDER
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
  fresh task-z1 "$TMP_ROOT/worktree" "$TEST_LEASE_HOLDER" \
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
EQUALS_WORKTREE="$TMP_ROOT/team=alpha/worktree"
mkdir -p "$EQUALS_WORKTREE"
fm_backend_herdr_layout_attempt_write "$ATTEMPT" 4 0123456789abcdef0123456789abcdef \
  fresh task-z1 "$EQUALS_WORKTREE" "$TEST_LEASE_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 fm-launch-0123456789abcdef0123456789abcdef \
  || fail "fresh ownership record rejected an absolute worktree path containing equals"
fm_backend_herdr_layout_attempt_snapshot "$ATTEMPT" \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_WORKTREE" = "$EQUALS_WORKTREE" ] \
  || fail "fresh ownership record did not preserve a worktree path containing equals"
rm -f "$ATTEMPT"
pass "ownership records release only proven fresh leases and preserve valid paths"

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

STRUCT_HOME="$TMP_ROOT/structural-home"
STRUCT_PROJECT="$TMP_ROOT/structural-project"
STRUCT_POOL="$TMP_ROOT/structural-pool"
STRUCT_WT="$STRUCT_POOL/slot/repo"
STRUCT_FAKEBIN=$(fm_fakebin "$TMP_ROOT/structural-bin")
STRUCT_TASK_CREATED="$TMP_ROOT/structural-task-created"
STRUCT_TASK_LABEL="$TMP_ROOT/structural-task-label"
STRUCT_CLOSED="$TMP_ROOT/structural-closed"
STRUCT_CLOSE_LOG="$TMP_ROOT/structural-close.log"
STRUCT_TREEHOUSE_LOG="$TMP_ROOT/structural-treehouse.log"
STRUCT_TREEHOUSE_STATE="$TMP_ROOT/structural-treehouse-state"
STRUCT_LEASE_ID=11111111111111111111111111111111
fm_test_spawn_home "$STRUCT_HOME" pi
printf 'off\n' > "$STRUCT_HOME/config/herdr-presentation-spaces"
fm_git_worktree "$STRUCT_PROJECT" "$STRUCT_WT" structural-worktree
printf '{}\n' > "$STRUCT_POOL/treehouse-state.json"
STRUCT_WORKSPACE_LABEL=$(FM_HOME="$STRUCT_HOME" fm_backend_herdr_workspace_label)
cat > "$STRUCT_FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FM_FAKE_STRUCT_TREEHOUSE_LOG:?}"
state=${FM_FAKE_STRUCT_TREEHOUSE_STATE:?}
case "${1:-}" in
  get)
    holder=
    previous=
    for arg in "$@"; do
      [ "$previous" != --lease-holder ] || holder=$arg
      previous=$arg
    done
    jq -cn --arg path "${FM_FAKE_STRUCT_WT:?}" --arg id "${FM_FAKE_STRUCT_LEASE_ID:?}" --arg holder "$holder" \
      '{name:"slot",path:$path,status:"leased",lease_id:$id,lease_holder:$holder}' > "$state"
    jq -cn --arg path "${FM_FAKE_STRUCT_WT:?}" --arg id "${FM_FAKE_STRUCT_LEASE_ID:?}" --arg holder "$holder" \
      '{path:$path,lease_id:$id,lease_holder:$holder,leased_at:"2026-01-01T00:00:00Z",base_branch:"main"}'
    ;;
  status)
    if [ -f "$state" ]; then
      jq -cs '.' "$state"
    else
      printf '%s\n' '[]'
    fi
    ;;
  return)
    previous=
    lease_id=
    for arg in "$@"; do
      [ "$previous" != --if-lease-id ] || lease_id=$arg
      previous=$arg
    done
    [ -f "$state" ]
    [ "$lease_id" = "$(jq -r '.lease_id' "$state")" ]
    if [ -n "${FM_FAKE_STRUCT_RETURN_FAIL_ONCE:-}" ] \
      && [ -e "$FM_FAKE_STRUCT_RETURN_FAIL_ONCE" ]; then
      rm -f "$FM_FAKE_STRUCT_RETURN_FAIL_ONCE"
      exit 75
    fi
    rm -f "$state"
    ;;
esac
SH
cat > "$STRUCT_FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -ge 2 ] && [ "${*: -2:1}" = --session ]; then
  set -- "${@:1:$#-2}"
fi
pane=${3:-}
case "$*" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.8.2","protocol":20},"server":{"version":"0.8.2","protocol":20,"running":true,"compatible":true}}'
    ;;
  "server start") ;;
  "session list --json")
    printf '{"sessions":[{"name":"lab-structural","running":true,"socket_path":"%s"}]}\n' "${FM_FAKE_STRUCT_SOCKET:?}"
    ;;
  "workspace list")
    if [ -e "${FM_FAKE_STRUCT_APPLIED:?}" ]; then active=w1:t3; else active=w1:t2; fi
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"%s","focused":true,"active_tab_id":"%s"}]}}\n' \
      "${FM_FAKE_STRUCT_WORKSPACE_LABEL:?}" "$active"
    ;;
  "tab list --workspace w1")
    if [ ! -e "${FM_FAKE_STRUCT_TASK_CREATED:?}" ] || [ -e "${FM_FAKE_STRUCT_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"tabs":[]}}'
    elif [ -e "${FM_FAKE_STRUCT_APPLIED:?}" ]; then
      printf '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t3","label":"%s","focused":true}]}}\n' "$(cat "${FM_FAKE_STRUCT_TASK_LABEL:?}")"
    else
      printf '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","label":"%s","focused":true}]}}\n' "$(cat "${FM_FAKE_STRUCT_TASK_LABEL:?}")"
    fi
    ;;
  "tab create --workspace w1 "*)
    label=
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      [ "${args[$i]}" != --label ] || label=${args[$((i+1))]}
    done
    printf '%s\n' "$label" > "${FM_FAKE_STRUCT_TASK_LABEL:?}"
    : > "${FM_FAKE_STRUCT_TASK_CREATED:?}"
    printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "tab get w1:t2")
    printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2"}}}'
    ;;
  "tab get w1:t3")
    printf '%s\n' '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t3"}}}'
    ;;
  "pane get w1:p2")
    if [ -e "${FM_FAKE_STRUCT_APPLIED:?}" ] || [ -e "${FM_FAKE_STRUCT_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    else
      printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2"}}}'
    fi
    ;;
  "pane get w1:p3")
    if [ -e "${FM_FAKE_STRUCT_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    else
      label=$(jq -r '.params.root.label' "${FM_FAKE_STRUCT_REQUEST:?}")
      printf '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"%s"}}}\n' "$label"
    fi
    ;;
  "pane list --workspace w1")
    if [ ! -e "${FM_FAKE_STRUCT_TASK_CREATED:?}" ] || [ -e "${FM_FAKE_STRUCT_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"panes":[]}}'
    elif [ -e "${FM_FAKE_STRUCT_APPLIED:?}" ]; then
      label=$(jq -r '.params.root.label' "${FM_FAKE_STRUCT_REQUEST:?}")
      printf '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"%s"}]}}\n' "$label"
    else
      printf '%s\n' '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":null}]}}'
    fi
    ;;
  "pane layout --pane w1:p2")
    printf '%s\n' '{"result":{"layout":{"workspace_id":"w1","tab_id":"w1:t2","focused_pane_id":"w1:p2","panes":[{"pane_id":"w1:p2","focused":true,"rect":{}}],"splits":[]}}}'
    ;;
  "pane process-info --pane w1:p2")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash","argv":["bash"]}]}}}\n' \
      "${FM_FAKE_STRUCT_PARENT_PID:?}" "${FM_FAKE_STRUCT_PARENT_PID:?}"
    ;;
  "pane process-info --pane w1:p3")
    if [ "${FM_FAKE_STRUCT_MODE:?}" = success ]; then
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi"]}]}}}'
    else
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"codex","argv0":"codex","argv":["codex"]}]}}}'
    fi
    ;;
  "agent get w1:p2")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    ;;
  "agent get w1:p3")
    if [ "${FM_FAKE_STRUCT_MODE:?}" = success ]; then
      printf '%s\n' '{"result":{"agent":{"pane_id":"w1:p3","agent":"pi","agent_status":"working"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  "pane report-agent w1:p3 --source firstmate-layout-apply --agent pi --state working")
    printf '%s\n' '{"result":{"type":"pane_report_agent","pane_id":"w1:p3"}}'
    ;;
  "terminal title clear")
    if [ "${FM_FAKE_STRUCT_MODE:?}" = preapply-focused ]; then
      printf '%s\n' '{"result":{"reason":"cleared"}}'
    else
      printf '%s\n' '{"result":{"reason":"no_foreground_client"}}'
    fi
    ;;
  "pane close w1:p2"|"pane close w1:p3")
    printf '%s\n' "$pane" >> "${FM_FAKE_STRUCT_CLOSE_LOG:?}"
    : > "${FM_FAKE_STRUCT_CLOSED:?}"
    printf '{"result":{"type":"pane_close","pane_id":"%s"}}\n' "$pane"
    ;;
  "api schema --json")
    case "${FM_FAKE_STRUCT_MODE:?}" in
    preapply*)
      printf '%s\n' '{"schemas":{"request":{}}}'
      ;;
    *)
      cat <<'JSON'
{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"layout.apply"}}},{"properties":{"method":{"const":"pane.report_agent"}}}],"$defs":{"LayoutApplyParams":{"required":["root"],"properties":{"workspace_id":{"type":["string","null"]},"tab_id":{"type":["string","null"]}}},"LayoutNode":{"oneOf":[{"properties":{"type":{"const":"pane"},"command":{"type":["array","null"]},"cwd":{"type":["string","null"]},"env":{"type":"object"},"label":{"type":["string","null"]},"pane_id":{"type":["string","null"]}}}]},"PaneReportAgentParams":{"required":["pane_id","source","agent","state"],"properties":{"agent":{"type":"string"},"state":{"$ref":"#/schemas/request/$defs/PaneAgentState"}}}}}}}
JSON
      ;;
    esac
    ;;
  *)
    printf 'unexpected structural fake Herdr call: %s\n' "$*" >&2
    exit 92
    ;;
esac
SH
fm_fake_exit0 "$STRUCT_FAKEBIN" pi
fm_test_fake_sleep_noop "$STRUCT_FAKEBIN"
cat > "$STRUCT_FAKEBIN/rm" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_STRUCT_FAIL_LAUNCH_RECEIPT_RM:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in *.herdr-launch) exit 75 ;; esac
  done
fi
exec /bin/rm "$@"
SH
chmod +x "$STRUCT_FAKEBIN/treehouse" "$STRUCT_FAKEBIN/herdr" "$STRUCT_FAKEBIN/rm"
export FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG"
export FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE"
export FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID"
export FM_FAKE_STRUCT_WT="$STRUCT_WT"
LEASE_TX="$TMP_ROOT/lease-transaction"
LEASE_TX_OTHER="$TMP_ROOT/lease-transaction-other"
STRUCT_PROJECT_LINK="$TMP_ROOT/structural-project-link"
STRUCT_WT_LINK="$TMP_ROOT/structural-worktree-link"
ln -s "${STRUCT_PROJECT##*/}" "$STRUCT_PROJECT_LINK"
ln -s "${STRUCT_WT#$TMP_ROOT/}" "$STRUCT_WT_LINK"
: > "$STRUCT_TREEHOUSE_LOG"
rm -f "$STRUCT_TREEHOUSE_STATE" "$LEASE_TX" "$LEASE_TX_OTHER"
if fm_treehouse_lease_transaction_write "$LEASE_TX" intent lease-z1 fm-lease-z1 \
  "$STRUCT_PROJECT" - - >/dev/null 2>&1; then
  fail "lease transaction accepted a cross-home-colliding holder"
fi
fm_treehouse_lease_transaction_write "$LEASE_TX" intent lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "$STRUCT_PROJECT" - - || fail "lease transaction did not publish holder intent"
fm_treehouse_lease_transaction_snapshot "$LEASE_TX" \
  && [ "$FM_TREEHOUSE_LEASE_TX_PHASE" = intent ] \
  || fail "lease transaction intent was not durable"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_reconcile \
  "$LEASE_TX" lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$STRUCT_PROJECT" \
  && [ "$FM_TREEHOUSE_LEASE_TX_RESULT" = retry ] \
  && [ ! -e "$LEASE_TX" ] \
  || fail "pre-acquisition crash recovery did not retire an unspent intent"
jq -cn --arg path "$STRUCT_WT" --arg id 22222222222222222222222222222222 \
  --arg holder fm-lease-z1-cccccccccccccccccccccccccccccccc \
  '{name:"slot",path:$path,status:"leased",lease_id:$id,lease_holder:$holder}' > "$STRUCT_TREEHOUSE_STATE"
fm_treehouse_lease_transaction_write "$LEASE_TX_OTHER" intent lease-z1 \
  fm-lease-z1-dddddddddddddddddddddddddddddddd "$STRUCT_PROJECT" - - \
  || fail "second home could not persist its distinct lease intent"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_reconcile \
  "$LEASE_TX_OTHER" lease-z1 fm-lease-z1-dddddddddddddddddddddddddddddddd "$STRUCT_PROJECT" \
  && [ "$FM_TREEHOUSE_LEASE_TX_RESULT" = retry ] \
  && [ ! -e "$LEASE_TX_OTHER" ] \
  || fail "same-task intent adopted another home's uniquely held lease"
rm -f "$STRUCT_TREEHOUSE_STATE"
fm_treehouse_lease_transaction_write "$LEASE_TX" intent lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "$STRUCT_PROJECT_LINK" - - || fail "lease transaction rejected a symlinked project spelling"
fm_treehouse_lease_transaction_snapshot "$LEASE_TX" \
  && [ "$FM_TREEHOUSE_LEASE_TX_PROJECT" = "$STRUCT_PROJECT" ] \
  || fail "lease transaction did not persist canonical project identity"
jq -cn --arg path "$STRUCT_WT_LINK" --arg id "$STRUCT_LEASE_ID" \
  --arg holder fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  '{name:"slot",path:$path,status:"leased",lease_id:$id,lease_holder:$holder}' > "$STRUCT_TREEHOUSE_STATE"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_reconcile \
  "$LEASE_TX" lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$STRUCT_PROJECT_LINK" \
  && [ "$FM_TREEHOUSE_LEASE_TX_RESULT" = acquired ] \
  && [ "$FM_TREEHOUSE_LEASE_TX_WORKTREE" = "$STRUCT_WT" ] \
  && [ "$FM_TREEHOUSE_LEASE_TX_ID" = "$STRUCT_LEASE_ID" ] \
  || fail "post-acquisition recovery did not bind canonical project and worktree identities"
fm_treehouse_lease_transaction_write "$LEASE_TX" cleanup lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "$STRUCT_PROJECT_LINK" "$STRUCT_WT_LINK" "$STRUCT_LEASE_ID" \
  || fail "lease transaction did not persist cleanup intent"
printf 'task=other-z1\nhome=%s\n' "$TMP_ROOT/other-home" > "$STRUCT_POOL/slot/.fm-slot-owner"
jq -cn --arg path "$STRUCT_WT" --arg id 33333333333333333333333333333333 \
  --arg holder fm-other-z1-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  '{name:"slot",path:$path,status:"leased",lease_id:$id,lease_holder:$holder}' > "$STRUCT_TREEHOUSE_STATE"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_reconcile \
  "$LEASE_TX" lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$STRUCT_PROJECT_LINK" \
  && [ "$FM_TREEHOUSE_LEASE_TX_RESULT" = returned ] \
  && [ "$FM_TREEHOUSE_LEASE_TX_PHASE" = returned ] \
  || fail "post-return crash recovery was blocked by slot reassignment"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_reconcile \
  "$LEASE_TX" lease-z1 fm-lease-z1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$STRUCT_PROJECT" \
  && [ "$FM_TREEHOUSE_LEASE_TX_RESULT" = returned ] \
  || fail "confirmed lease return was not idempotent"
RETURNED_HISTORY="$TMP_ROOT/returned-history"
mkdir -p "$RETURNED_HISTORY"
fm_treehouse_lease_transaction_write "$LEASE_TX_OTHER" cleanup history-z1 \
  fm-history-z1-ffffffffffffffffffffffffffffffff "$STRUCT_PROJECT_LINK" \
  "$RETURNED_HISTORY" 44444444444444444444444444444444 \
  || fail "cleanup history could not be persisted"
rmdir "$RETURNED_HISTORY"
fm_treehouse_lease_transaction_snapshot "$LEASE_TX_OTHER" \
  && PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_reconcile \
    "$LEASE_TX_OTHER" history-z1 fm-history-z1-ffffffffffffffffffffffffffffffff "$STRUCT_PROJECT_LINK" \
  && [ "$FM_TREEHOUSE_LEASE_TX_RESULT" = returned ] \
  || fail "pruned post-return worktree history became unreadable"
rm -f "$LEASE_TX" "$LEASE_TX_OTHER" "$STRUCT_TREEHOUSE_STATE" "$STRUCT_POOL/slot/.fm-slot-owner"
pass "Treehouse lease transactions isolate homes and recover canonical crash states"
: > "$STRUCT_CLOSE_LOG"
rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$STRUCT_TREEHOUSE_STATE" "$APPLIED" "$REQUEST"
fm_test_spawn_brief "$STRUCT_HOME" preapply-z1 "Clean a flat structural pane after pre-apply refusal."
set +e
struct_pre_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=preapply FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    preapply-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
struct_pre_status=$?
set -e
[ "$struct_pre_status" -ne 0 ] || fail "pre-apply schema refusal unexpectedly launched a worker"
assert_contains "$struct_pre_out" "failed before worker readiness" \
  "pre-apply schema refusal did not reach structural launch"
[ "$(cat "$STRUCT_CLOSE_LOG")" = w1:p2 ] \
  || fail "pre-apply refusal did not close exactly its original flat pane"
[ ! -e "$STRUCT_HOME/state/preapply-z1.meta" ] \
  || fail "pre-apply cleanup retained task metadata after confirming pane removal"
assert_grep "return --force --if-lease-id $STRUCT_LEASE_ID $STRUCT_WT" "$STRUCT_TREEHOUSE_LOG" \
  "pre-apply cleanup did not return its exact Treehouse lease identity"
pass "flat structural pre-apply refusals close their original pane and release ownership"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
fm_test_spawn_brief "$STRUCT_HOME" postapply-z1 "Reconcile a post-apply refusal exactly once."
start_server success
set +e
struct_post_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=postapply FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT_LINK" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    postapply-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
struct_post_status=$?
set -e
wait_server
[ "$struct_post_status" -ne 0 ] || fail "post-apply process refusal unexpectedly launched a worker"
assert_contains "$struct_post_out" "did not produce the expected Pi process" \
  "post-apply refusal did not reach exact process validation"
[ "$(cat "$STRUCT_CLOSE_LOG")" = w1:p3 ] \
  || fail "post-apply reconciliation did not close its replacement exactly once"
[ ! -e "$STRUCT_HOME/state/postapply-z1.meta" ] \
  || fail "post-apply reconciliation retained metadata after confirmed cleanup"
[ ! -e "$STRUCT_HOME/state/postapply-z1.herdr-launch" ] \
  || fail "post-apply reconciliation retained its resolved attempt"
assert_grep "return --force --if-lease-id $STRUCT_LEASE_ID $STRUCT_WT" "$STRUCT_TREEHOUSE_LOG" \
  "post-apply reconciliation did not return its exact Treehouse lease identity"
[ "$(jq -r '.params.root.cwd' "$REQUEST")" = "$STRUCT_WT" ] \
  || fail "post-apply structural launch did not canonicalize its symlinked leased worktree"
pass "post-apply abort reconciliation canonicalizes symlinked ownership and completes cleanup"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$STRUCT_TREEHOUSE_STATE" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
: > "$STRUCT_TREEHOUSE_LOG"
INTERRUPTED_RETURN="$TMP_ROOT/interrupted-return"
: > "$INTERRUPTED_RETURN"
fm_test_spawn_brief "$STRUCT_HOME" interrupted-z1 "Keep cleanup recovery proof across an interrupted lease return."
start_server success
set +e
interrupted_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=postapply FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_RETURN_FAIL_ONCE="$INTERRUPTED_RETURN" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    interrupted-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
interrupted_status=$?
set -e
wait_server
[ "$interrupted_status" -ne 0 ] || fail "interrupted lease return unexpectedly launched a worker"
INTERRUPTED_META="$STRUCT_HOME/state/interrupted-z1.meta"
INTERRUPTED_TX="$STRUCT_HOME/state/interrupted-z1.herdr-lease"
INTERRUPTED_ATTEMPT="$STRUCT_HOME/state/interrupted-z1.herdr-launch"
[ -e "$INTERRUPTED_META" ] && [ -e "$INTERRUPTED_TX" ] && [ -e "$INTERRUPTED_ATTEMPT" ] \
  || fail "interrupted lease return discarded correlated recovery records"
fm_backend_herdr_layout_attempt_snapshot "$INTERRUPTED_ATTEMPT" \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 6 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = removed ] \
  || fail "interrupted lease return lost its resolved structural launch proof"
INTERRUPTED_ATTEMPT_ID=$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_ID
INTERRUPTED_HOLDER=$(sed -n 's/^treehouse_lease_holder=//p' "$INTERRUPTED_META")
fm_treehouse_lease_transaction_snapshot "$INTERRUPTED_TX" \
  && [ "$FM_TREEHOUSE_LEASE_TX_PHASE" = cleanup ] \
  || fail "interrupted lease return lost its retryable cleanup receipt"
set +e
interrupted_retry_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=postapply FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    interrupted-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
interrupted_retry_status=$?
set -e
[ "$interrupted_retry_status" -ne 0 ] || fail "interruption retry unexpectedly launched through the stale fixture"
if [ -e "$INTERRUPTED_ATTEMPT" ]; then
  fm_backend_herdr_layout_attempt_snapshot "$INTERRUPTED_ATTEMPT" \
    || fail "interruption retry left a malformed structural receipt"
  [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_ID" != "$INTERRUPTED_ATTEMPT_ID" ] \
    || fail "interruption retry preserved the resolved launch receipt"
fi
if [ -e "$INTERRUPTED_TX" ]; then
  fm_treehouse_lease_transaction_snapshot "$INTERRUPTED_TX" \
    || fail "interruption retry left a malformed lease receipt"
  [ "$FM_TREEHOUSE_LEASE_TX_HOLDER" != "$INTERRUPTED_HOLDER" ] \
    || fail "interruption retry preserved the returned lease receipt"
fi
if [ -e "$INTERRUPTED_TX" ] && [ -e "$INTERRUPTED_META" ]; then
  RETRY_HOLDER=$(sed -n 's/^treehouse_lease_holder=//p' "$INTERRUPTED_META")
  PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_return \
    "$INTERRUPTED_TX" interrupted-z1 "$RETRY_HOLDER" "$STRUCT_PROJECT" >/dev/null \
    || fail "could not clean the interruption retry lease fixture"
  fm_treehouse_slot_owner_release "$STRUCT_WT" interrupted-z1 "$RETRY_HOLDER"
fi
rm -f "$INTERRUPTED_META" "$INTERRUPTED_TX" "$INTERRUPTED_ATTEMPT" "$STRUCT_TREEHOUSE_STATE"
pass "abort cleanup retains resolved launch proof through lease retirement"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$STRUCT_TREEHOUSE_STATE" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
: > "$STRUCT_TREEHOUSE_LOG"
fm_test_spawn_brief "$STRUCT_HOME" success-z1 "Keep the committed structural worker's lease active."
start_server success
set +e
struct_success_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    success-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
struct_success_status=$?
set -e
wait_server
[ "$struct_success_status" -eq 0 ] || fail "successful structural launch failed: $struct_success_out"
SUCCESS_META="$STRUCT_HOME/state/success-z1.meta"
SUCCESS_TX="$STRUCT_HOME/state/success-z1.herdr-lease"
SUCCESS_HOLDER=$(sed -n 's/^treehouse_lease_holder=//p' "$SUCCESS_META")
[ -f "$STRUCT_TREEHOUSE_STATE" ] \
  && [ "$(jq -r '.lease_holder' "$STRUCT_TREEHOUSE_STATE")" = "$SUCCESS_HOLDER" ] \
  || fail "successful structural launch returned its live Treehouse lease on exit"
fm_treehouse_lease_transaction_snapshot "$SUCCESS_TX" \
  && [ "$FM_TREEHOUSE_LEASE_TX_PHASE" = acquired ] \
  || fail "successful structural launch retired its active lease transaction"
assert_no_grep 'return --force' "$STRUCT_TREEHOUSE_LOG" \
  "successful structural launch invoked Treehouse return during normal exit"
assert_grep "lease_holder=$SUCCESS_HOLDER" "$STRUCT_POOL/slot/.fm-slot-owner" \
  "successful structural launch did not bind its slot claim to the unique lease holder"
SUCCESS_LABEL=$(jq -r '.params.root.label' "$REQUEST")
SUCCESS_ATTEMPT_ID=${SUCCESS_LABEL#fm-launch-}
fm_backend_herdr_layout_attempt_write "$STRUCT_HOME/state/success-z1.herdr-launch" 5 \
  "$SUCCESS_ATTEMPT_ID" fresh success-z1 "$STRUCT_WT" "$SUCCESS_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 "$SUCCESS_LABEL" w1:t3 w1:p3 \
  || fail "could not stage the post-commit crash receipt"
SUCCESS_GETS=$(grep -c '^get ' "$STRUCT_TREEHOUSE_LOG" || true)
set +e
struct_recovery_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    success-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
struct_recovery_status=$?
set -e
[ "$struct_recovery_status" -eq 0 ] \
  || fail "post-commit receipt recovery failed: $struct_recovery_out"
[ ! -e "$STRUCT_HOME/state/success-z1.herdr-launch" ] \
  || fail "post-commit receipt recovery did not retire the exact receipt"
[ "$(grep -c '^get ' "$STRUCT_TREEHOUSE_LOG" || true)" -eq "$SUCCESS_GETS" ] \
  || fail "post-commit receipt recovery allocated a duplicate Treehouse lease"
[ -f "$SUCCESS_META" ] && [ -f "$SUCCESS_TX" ] && [ -f "$STRUCT_TREEHOUSE_STATE" ] \
  || fail "post-commit receipt recovery retired committed worker ownership"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_return \
  "$SUCCESS_TX" success-z1 "$SUCCESS_HOLDER" "$STRUCT_PROJECT" >/dev/null \
  || fail "successful structural launch fixture cleanup could not return its lease"
fm_treehouse_slot_owner_release "$STRUCT_WT" success-z1 "$SUCCESS_HOLDER"
rm -f "$SUCCESS_META" "$SUCCESS_TX"
pass "successful structural launches retain their live lease after spawn exits"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$STRUCT_TREEHOUSE_STATE" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
: > "$STRUCT_TREEHOUSE_LOG"
fm_test_spawn_brief "$STRUCT_HOME" receipt-fail-z1 "Preserve a committed worker when receipt retirement fails."
start_server success
set +e
receipt_fail_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  FM_FAKE_STRUCT_FAIL_LAUNCH_RECEIPT_RM=1 \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    receipt-fail-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
receipt_fail_status=$?
set -e
wait_server
[ "$receipt_fail_status" -ne 0 ] || fail "receipt retirement failure unexpectedly reported a successful spawn"
assert_contains "$receipt_fail_out" "receipt could not be retired" \
  "receipt retirement failure did not report preserved retry authority"
RECEIPT_FAIL_META="$STRUCT_HOME/state/receipt-fail-z1.meta"
RECEIPT_FAIL_TX="$STRUCT_HOME/state/receipt-fail-z1.herdr-lease"
RECEIPT_FAIL_ATTEMPT="$STRUCT_HOME/state/receipt-fail-z1.herdr-launch"
RECEIPT_FAIL_HOLDER=$(sed -n 's/^treehouse_lease_holder=//p' "$RECEIPT_FAIL_META")
[ -f "$RECEIPT_FAIL_META" ] && [ -f "$RECEIPT_FAIL_TX" ] \
  && [ -f "$RECEIPT_FAIL_ATTEMPT" ] && [ -f "$STRUCT_TREEHOUSE_STATE" ] \
  || fail "receipt retirement failure discarded committed worker recovery state"
assert_grep 'herdr_pane_id=w1:p3' "$RECEIPT_FAIL_META" \
  "receipt retirement failure lost the committed endpoint binding"
assert_no_grep 'w1:p3' "$STRUCT_CLOSE_LOG" \
  "receipt retirement failure closed the committed worker"
fm_treehouse_lease_transaction_snapshot "$RECEIPT_FAIL_TX" \
  && [ "$FM_TREEHOUSE_LEASE_TX_PHASE" = acquired ] \
  || fail "receipt retirement failure changed the committed lease transaction"
set +e
receipt_retry_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    receipt-fail-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
receipt_retry_status=$?
set -e
[ "$receipt_retry_status" -eq 0 ] || fail "receipt retirement retry failed: $receipt_retry_out"
[ ! -e "$RECEIPT_FAIL_ATTEMPT" ] \
  || fail "receipt retirement retry left the committed receipt behind"
[ -f "$RECEIPT_FAIL_META" ] && [ -f "$RECEIPT_FAIL_TX" ] && [ -f "$STRUCT_TREEHOUSE_STATE" ] \
  || fail "receipt retirement retry discarded committed worker ownership"
assert_no_grep 'w1:p3' "$STRUCT_CLOSE_LOG" \
  "receipt retirement retry closed the committed worker"
PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_return \
  "$RECEIPT_FAIL_TX" receipt-fail-z1 "$RECEIPT_FAIL_HOLDER" "$STRUCT_PROJECT" >/dev/null \
  || fail "receipt retirement failure fixture cleanup could not return its lease"
fm_treehouse_slot_owner_release "$STRUCT_WT" receipt-fail-z1 "$RECEIPT_FAIL_HOLDER"
rm -f "$RECEIPT_FAIL_META" "$RECEIPT_FAIL_TX" "$RECEIPT_FAIL_ATTEMPT"
pass "receipt retirement failures preserve committed workers and retry receipts"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$STRUCT_TREEHOUSE_STATE" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
: > "$STRUCT_TREEHOUSE_LOG"
RETAINED_ID=retained-success-z1
fm_test_spawn_brief "$STRUCT_HOME" "$RETAINED_ID" "Retire a successful retained launch receipt."
cat > "$STRUCT_HOME/state/$RETAINED_ID.meta" <<EOF
window=lab-structural:w1:p2
endpoint_task_id=$RETAINED_ID
worktree=$STRUCT_WT
project=$STRUCT_PROJECT
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$RETAINED_ID
model=default
effort=default
backend=herdr
herdr_root=$ROOT
herdr_session=lab-structural
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
EOF
start_server success
set +e
retained_success_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  FM_FAKE_STRUCT_FAIL_LAUNCH_RECEIPT_RM=1 \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    "$RETAINED_ID" --relaunch --harness pi)
retained_success_status=$?
set -e
if [ -e "$APPLIED" ]; then
  wait_server
else
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
fi
[ "$retained_success_status" -ne 0 ] \
  || fail "retained receipt retirement failure unexpectedly reported success"
RETAINED_ATTEMPT="$STRUCT_HOME/state/$RETAINED_ID.herdr-launch"
[ -f "$RETAINED_ATTEMPT" ] \
  || fail "retained receipt retirement failure discarded retry authority"
assert_grep 'herdr_pane_id=w1:p3' "$STRUCT_HOME/state/$RETAINED_ID.meta" \
  "retained receipt retirement failure lost its replacement endpoint"
assert_no_grep 'w1:p3' "$STRUCT_CLOSE_LOG" \
  "retained receipt retirement failure closed its committed worker"
set +e
retained_retry_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    "$RETAINED_ID" --relaunch --harness pi)
retained_retry_status=$?
set -e
[ "$retained_retry_status" -eq 0 ] || fail "retained receipt retry failed: $retained_retry_out"
[ ! -e "$RETAINED_ATTEMPT" ] \
  || fail "retained receipt retry left its verified receipt behind"
assert_grep 'herdr_pane_id=w1:p3' "$STRUCT_HOME/state/$RETAINED_ID.meta" \
  "retained receipt retry replaced its committed endpoint"
assert_no_grep 'w1:p3' "$STRUCT_CLOSE_LOG" \
  "retained receipt retry closed its committed worker"
rm -f "$STRUCT_HOME/state/$RETAINED_ID.meta"
pass "retained receipt retries preserve committed workers and retire receipts"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$STRUCT_TREEHOUSE_STATE" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
: > "$STRUCT_TREEHOUSE_LOG"
fm_test_spawn_brief "$STRUCT_HOME" unrebound-z1 "Recover an applied launch that crashed before endpoint rebinding."
start_server success
set +e
unrebound_seed_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=success FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    unrebound-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
unrebound_seed_status=$?
set -e
wait_server
[ "$unrebound_seed_status" -eq 0 ] || fail "unrebound recovery fixture could not launch: $unrebound_seed_out"
UNREBOUND_META="$STRUCT_HOME/state/unrebound-z1.meta"
UNREBOUND_TX="$STRUCT_HOME/state/unrebound-z1.herdr-lease"
UNREBOUND_HOLDER=$(sed -n 's/^treehouse_lease_holder=//p' "$UNREBOUND_META")
UNREBOUND_LABEL=$(jq -r '.params.root.label' "$REQUEST")
UNREBOUND_ATTEMPT_ID=${UNREBOUND_LABEL#fm-launch-}
fm_backend_herdr_layout_attempt_write "$STRUCT_HOME/state/unrebound-z1.herdr-launch" 5 \
  "$UNREBOUND_ATTEMPT_ID" fresh unrebound-z1 "$STRUCT_WT" "$UNREBOUND_HOLDER" \
  lab-structural w1 w1:t2 w1:p2 "$UNREBOUND_LABEL" w1:t3 w1:p3 \
  || fail "could not stage an applied pre-rebind launch receipt"
awk '
  /^window=/ { print "window=lab-structural:w1:p2"; next }
  /^herdr_tab_id=/ { print "herdr_tab_id=w1:t2"; next }
  /^herdr_pane_id=/ { print "herdr_pane_id=w1:p2"; next }
  { print }
' "$UNREBOUND_META" > "$UNREBOUND_META.tmp"
mv "$UNREBOUND_META.tmp" "$UNREBOUND_META"
set +e
unrebound_recovery_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=postapply FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    unrebound-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
unrebound_recovery_status=$?
set -e
[ "$unrebound_recovery_status" -ne 0 ] || fail "post-recovery validation mismatch unexpectedly launched"
assert_not_contains "$unrebound_recovery_out" "committed structural worker could not be verified" \
  "an applied pre-rebind receipt was misclassified as committed"
if [ -e "$STRUCT_HOME/state/unrebound-z1.herdr-launch" ]; then
  fm_backend_herdr_layout_attempt_snapshot "$STRUCT_HOME/state/unrebound-z1.herdr-launch" \
    || fail "the retry left a malformed structural receipt"
  [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_ID" != "$UNREBOUND_ATTEMPT_ID" ] \
    || fail "applied pre-rebind recovery preserved the crashed receipt"
fi
if [ -e "$UNREBOUND_TX" ]; then
  fm_treehouse_lease_transaction_snapshot "$UNREBOUND_TX" \
    || fail "the retry left a malformed lease transaction"
  [ "$FM_TREEHOUSE_LEASE_TX_HOLDER" != "$UNREBOUND_HOLDER" ] \
    || fail "applied pre-rebind recovery preserved the crashed lease transaction"
fi
assert_grep 'w1:p3' "$STRUCT_CLOSE_LOG" \
  "applied pre-rebind recovery did not close its exact replacement"
if [ -e "$STRUCT_TREEHOUSE_STATE" ]; then
  [ "$(jq -r '.lease_holder' "$STRUCT_TREEHOUSE_STATE")" != "$UNREBOUND_HOLDER" ] \
    || fail "applied pre-rebind recovery left the crashed Treehouse lease live"
fi
if [ -e "$UNREBOUND_TX" ] && [ -e "$UNREBOUND_META" ]; then
  RETRY_HOLDER=$(sed -n 's/^treehouse_lease_holder=//p' "$UNREBOUND_META")
  PATH="$STRUCT_FAKEBIN:$PATH" fm_treehouse_lease_transaction_return \
    "$UNREBOUND_TX" unrebound-z1 "$RETRY_HOLDER" "$STRUCT_PROJECT" >/dev/null \
    || fail "could not clean the retry lease fixture"
  fm_treehouse_slot_owner_release "$STRUCT_WT" unrebound-z1 "$RETRY_HOLDER"
fi
rm -f "$UNREBOUND_META" "$UNREBOUND_TX" "$STRUCT_HOME/state/unrebound-z1.herdr-launch" "$STRUCT_TREEHOUSE_STATE"
pass "pre-rebind structural receipts recover instead of impersonating committed workers"

rm -f "$STRUCT_TASK_CREATED" "$STRUCT_TASK_LABEL" "$STRUCT_CLOSED" "$APPLIED" "$REQUEST"
: > "$STRUCT_CLOSE_LOG"
fm_test_spawn_brief "$STRUCT_HOME" preapply-held-z1 "Keep durable ownership when focused cleanup refuses."
set +e
struct_held_out=$(HERDR_SESSION=lab-structural \
  FM_FAKE_STRUCT_MODE=preapply-focused FM_FAKE_STRUCT_SOCKET="$SOCK" \
  FM_FAKE_STRUCT_APPLIED="$APPLIED" FM_FAKE_STRUCT_REQUEST="$REQUEST" \
  FM_FAKE_STRUCT_TASK_CREATED="$STRUCT_TASK_CREATED" FM_FAKE_STRUCT_TASK_LABEL="$STRUCT_TASK_LABEL" \
  FM_FAKE_STRUCT_CLOSED="$STRUCT_CLOSED" FM_FAKE_STRUCT_CLOSE_LOG="$STRUCT_CLOSE_LOG" \
  FM_FAKE_STRUCT_TREEHOUSE_LOG="$STRUCT_TREEHOUSE_LOG" FM_FAKE_STRUCT_TREEHOUSE_STATE="$STRUCT_TREEHOUSE_STATE" \
  FM_FAKE_STRUCT_LEASE_ID="$STRUCT_LEASE_ID" FM_FAKE_STRUCT_WT="$STRUCT_WT" \
  FM_FAKE_STRUCT_WORKSPACE_LABEL="$STRUCT_WORKSPACE_LABEL" FM_FAKE_STRUCT_PARENT_PID="$$" \
  fm_test_run_spawn "$STRUCT_HOME" "$STRUCT_WT" "$STRUCT_FAKEBIN" \
    preapply-held-z1 "$STRUCT_PROJECT" --scout --harness pi --backend herdr)
struct_held_status=$?
set -e
[ "$struct_held_status" -ne 0 ] || fail "focused pre-apply refusal unexpectedly launched a worker"
assert_contains "$struct_held_out" "preserving task preapply-held-z1's record and Treehouse lease" \
  "focused pre-apply refusal did not preserve ownership"
[ ! -s "$STRUCT_CLOSE_LOG" ] || fail "focused pre-apply refusal closed the actively viewed pane"
[ -e "$STRUCT_HOME/state/preapply-held-z1.meta" ] \
  || fail "focused pre-apply refusal discarded its task record"
HELD_ATTEMPT="$STRUCT_HOME/state/preapply-held-z1.herdr-launch"
fm_backend_herdr_layout_attempt_snapshot "$HELD_ATTEMPT" \
  || fail "focused pre-apply refusal lost its durable recovery marker"
[ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_VERSION" = 6 ] \
  && [ "$FM_BACKEND_HERDR_LAYOUT_ATTEMPT_RESOLUTION" = not-applied ] \
  || fail "focused pre-apply refusal did not preserve its non-mutating recovery state"
[ -f "$STRUCT_TREEHOUSE_STATE" ] \
  && [ "$(jq -r '.lease_holder' "$STRUCT_TREEHOUSE_STATE")" = "$(sed -n 's/^treehouse_lease_holder=//p' "$STRUCT_HOME/state/preapply-held-z1.meta")" ] \
  || fail "focused pre-apply refusal lost its exact live Treehouse lease"
fm_treehouse_lease_transaction_snapshot "$STRUCT_HOME/state/preapply-held-z1.herdr-lease" \
  && [ "$FM_TREEHOUSE_LEASE_TX_PHASE" = acquired ] \
  && [ "$FM_TREEHOUSE_LEASE_TX_ID" = "$STRUCT_LEASE_ID" ] \
  || fail "focused pre-apply refusal lost its durable acquired lease state"
pass "pre-apply focus refusals preserve durable ownership for exact recovery"

NON_PI="$TMP_ROOT/non-pi"
NON_PI_HOME="$NON_PI/home"
NON_PI_PROJECT="$NON_PI/project"
NON_PI_WT="$NON_PI/worktree"
NON_PI_LOG="$NON_PI/herdr.log"
NON_PI_STATE="$NON_PI/herdr-state.json"
NON_PI_SEND_FAIL="$NON_PI/send-fail"
NON_PI_TREEHOUSE_LOG="$NON_PI/treehouse.log"
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
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
printf '%s\n' "${FM_FAKE_PANE_PATH:?}"
SH
fm_fake_exit0 "$NON_PI_FAKEBIN" pi-signed
fm_test_fake_sleep_noop "$NON_PI_FAKEBIN"
chmod +x "$NON_PI_FAKEBIN/treehouse"
: > "$NON_PI_TREEHOUSE_LOG"
set +e
non_pi_out=$(HERDR_SESSION=lab-structural FM_FAKE_TREEHOUSE_LOG="$NON_PI_TREEHOUSE_LOG" \
  fm_test_run_spawn "$NON_PI_HOME" "$NON_PI_WT" "$NON_PI_FAKEBIN" \
    non-pi-z1 "$NON_PI_PROJECT" --scout --harness pi-signed --backend herdr)
non_pi_status=$?
set -e
[ "$non_pi_status" -eq 0 ] || fail "non-Pi Herdr launch no longer reaches its existing interactive path: $non_pi_out"
assert_grep 'treehouse get' "$NON_PI_LOG" \
  "non-Pi Herdr launch did not enter its isolated worktree interactively"
assert_grep 'pane send-text' "$NON_PI_LOG" "non-Pi Herdr launch did not type its launch command"
assert_grep 'pane send-keys' "$NON_PI_LOG" "non-Pi Herdr launch did not submit through the existing key path"
assert_no_grep 'get --lease' "$NON_PI_TREEHOUSE_LOG" \
  "non-Pi Herdr launch acquired the structural path's direct lease"
assert_grep "worktree=$NON_PI_WT" "$NON_PI_HOME/state/non-pi-z1.meta" \
  "non-Pi Herdr launch did not record its interactive isolated worktree"
assert_not_contains "$non_pi_out" "structural Herdr launch" \
  "non-Pi Herdr launch was incorrectly routed through plain-Pi structural handling"
NON_PI_PANE=$(sed -n 's/^herdr_pane_id=//p' "$NON_PI_HOME/state/non-pi-z1.meta")
jq --arg pane "$NON_PI_PANE" --arg cwd "$NON_PI_PROJECT" '
  .typed = {} | .working = {}
  | .tabs |= map(if .pane_id == $pane then .foreground_cwd = $cwd else . end)
' "$NON_PI_STATE" > "$NON_PI_STATE.tmp"
mv "$NON_PI_STATE.tmp" "$NON_PI_STATE"
: > "$NON_PI_LOG"
set +e
non_pi_relaunch_out=$(HERDR_SESSION=lab-structural FM_FAKE_TREEHOUSE_LOG="$NON_PI_TREEHOUSE_LOG" \
  fm_test_run_spawn "$NON_PI_HOME" "$NON_PI_WT" "$NON_PI_FAKEBIN" \
    non-pi-z1 --relaunch --harness pi-signed)
non_pi_relaunch_status=$?
set -e
[ "$non_pi_relaunch_status" -eq 0 ] \
  || fail "non-Pi Herdr relaunch did not restore its interactive worktree cwd: $non_pi_relaunch_out"
assert_grep 'cd -- ' "$NON_PI_LOG" \
  "non-Pi Herdr relaunch did not correct its shell cwd before launch"
assert_grep 'pane send-text' "$NON_PI_LOG" \
  "non-Pi Herdr relaunch did not retain interactive launch submission"
pass "non-Pi Herdr harnesses retain interactive isolated-worktree launch and relaunch behavior"

printf '# all fm-herdr-layout-apply tests passed\n'
