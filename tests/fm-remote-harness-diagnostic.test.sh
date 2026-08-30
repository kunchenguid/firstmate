#!/usr/bin/env bash
# Read-only remote Herdr harness-diagnostic coverage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the Herdr diagnostic parses JSON)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-harness-diagnostic)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
export FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/fixture-proc-unavailable"

test_remote_harness_diagnostic_reports_herdr_foreground_ancestry() {
  local dir home fakebin out
  dir="$TMP_ROOT/foreground"
  home="$dir/home"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$home/state/parent-route"
  cat > "$home/state/parent-route/alienware-ml.meta" <<'EOF'
window=fm-remote:w3:p2
endpoint_task_id=alienware-ml
worktree=/home/think/fm-homes/alienware-ml
project=/home/think/firstmate
backend=herdr
herdr_session=fm-remote
herdr_workspace_id=w3
herdr_tab_id=t3
herdr_pane_id=w3:p2
harness=codex
EOF
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' pane process-info '*)
    printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":701,"foreground_processes":[{"pid":702}]}}}'
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  701:comm=) printf '%s\n' bash ;;
  701:args=) printf '%s\n' 'bash -l' ;;
  701:ppid=) printf '%s\n' 1 ;;
  702:comm=) printf '%s\n' node ;;
  702:args=) printf '%s\n' 'node /opt/openai/node_modules/@openai/codex/bin/codex.js' ;;
  702:ppid=) printf '%s\n' 701 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr" "$fakebin/ps"
  cat > "$home/state/.fm-codex-session-binding-required" <<EOF
harness=codex
home=$home
spawn_gen=s1.2.3
EOF

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-remote-harness-diagnostic.sh" alienware-ml) \
    || fail "read-only remote diagnostic could not inspect a valid Herdr endpoint"
  assert_contains "$out" 'schema=fm-remote-harness-diagnostic.v1' \
    "diagnostic identifies its public output protocol"
  assert_contains "$out" 'source=herdr-pane-process-info foreground_pids=702' \
    "diagnostic reports Herdr's foreground process evidence"
  assert_contains "$out" 'candidate_pid=702' \
    "diagnostic inspects the live foreground candidate rather than its own worker process"
  assert_contains "$out" 'comm=node' \
    "diagnostic retains the observed kernel command name"
  assert_contains "$out" 'args=redacted' \
    "diagnostic redacts the observed process arguments"
  assert_not_contains "$out" 'node\ /opt/openai/node_modules/@openai/codex/bin/codex.js' \
    "diagnostic does not expose the fixture command line"
  assert_contains "$out" 'result=verified-harness-found' \
    "diagnostic delegates classification to the shared matcher"
  pass "remote harness diagnostic: Herdr foreground process ancestry is inspected without a remote write"
}

test_remote_harness_diagnostic_rejects_invalid_process_info_envelopes() {
  local dir home fakebin response out status
  dir="$TMP_ROOT/invalid-envelope"
  home="$dir/home"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$home/state/parent-route"
  cat > "$home/state/parent-route/alienware-ml.meta" <<'EOF'
window=fm-remote:w3:p2
endpoint_task_id=alienware-ml
worktree=/home/think/fm-homes/alienware-ml
project=/home/think/firstmate
backend=herdr
herdr_session=fm-remote
herdr_workspace_id=w3
herdr_tab_id=t3
herdr_pane_id=w3:p2
harness=codex
EOF
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_HERDR_RESPONSE"
SH
  chmod +x "$fakebin/herdr"

  for response in \
    '{"result":{"type":"other","process_info":{"pane_id":"w3:p2","shell_pid":701,"foreground_processes":[]}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w9:p9","shell_pid":701,"foreground_processes":[]}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":701}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":701,"foreground_processes":{}}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":701.9,"foreground_processes":[]}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":1,"foreground_processes":[]}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":701,"foreground_processes":[{"pid":702.9}]}}}' \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w3:p2","shell_pid":701,"foreground_processes":[{"pid":1}]}}}'
  do
    status=0
    out=$(FM_TEST_HERDR_RESPONSE="$response" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-remote-harness-diagnostic.sh" alienware-ml 2>&1) \
      || status=$?
    [ "$status" -ne 0 ] || fail "diagnostic accepted an invalid Herdr process-info envelope"
    assert_contains "$out" 'error: Herdr process information envelope did not match pane w3:p2' \
      "diagnostic names the rejected Herdr pane-process envelope"
    assert_not_contains "$out" 'schema=fm-remote-harness-diagnostic.v1' \
      "diagnostic emits no evidence for an invalid Herdr process-info envelope"
  done
  pass "remote harness diagnostic: malformed or mismatched Herdr process-info envelopes are rejected"
}

test_remote_harness_diagnostic_reports_herdr_foreground_ancestry
test_remote_harness_diagnostic_rejects_invalid_process_info_envelopes
