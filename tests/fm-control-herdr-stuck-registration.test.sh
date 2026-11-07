#!/usr/bin/env bash
# tests/fm-control-herdr-stuck-registration.test.sh - the stuck Herdr
# registration class through bin/fm-control.sh's own interface, against
# canned fixtures (no live Herdr, no real agent).
#
# The class: a Herdr pane whose agent process exited while its registration
# stayed behind at agent_status=done. Two control-plane facts must hold
# end to end here:
#   1. `exit` - the relaunch preflight - verifies already-stopped from the
#      process-level corroboration (a registration over a proven shell-only
#      pane reads dead) and types NOTHING into the pane.
#   2. `clear-registration` is the one sanctioned repair: it clears only a
#      provably agent-less shell, and a pane with a live agent, a foreground
#      command or editor, or an unreadable process view refuses BEFORE the
#      clear request is ever sent. Its reported outcome is the post-clear
#      read, never the request's exit code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# This suite never launches anything, but a run from inside a Herdr pane
# inherits the pane identity anyway; drop it so no fixture resolves ambient
# Herdr state instead of its own.
herdr_forget_inherited_pane

CONTROL="$ROOT/bin/fm-control.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-herdr-stuck)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# new_case <name>: one case directory with an isolated home, a dispatching
# canned `herdr` on PATH, and a clear-request stub. The fake answers from
# $FM_HERDR_FIXTURES files and records every call, so a test can assert both
# what was asked and what was never asked.
new_case() {  # <name> -> echoes the case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fixtures" "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
: "${FM_HERDR_FIXTURES:?}"
printf '%s\n' "$*" >> "$FM_HERDR_FIXTURES/calls.log"
case "${1:-}:${2:-}" in
  pane:get) cat "$FM_HERDR_FIXTURES/pane.get.json" ;;
  pane:process-info)
    [ ! -e "$FM_HERDR_FIXTURES/process-info.fail" ] || exit 1
    cat "$FM_HERDR_FIXTURES/process-info.json"
    ;;
  agent:get)
    if [ -e "$FM_HERDR_FIXTURES/cleared" ]; then
      cat "$FM_HERDR_FIXTURES/agent-absent.json"
    else
      cat "$FM_HERDR_FIXTURES/agent.get.json"
    fi
    ;;
  status:--json)
    printf '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}\n'
    ;;
  api:schema) cat "$FM_HERDR_FIXTURES/schema.json" ;;
  session:list) cat "$FM_HERDR_FIXTURES/sessions.json" ;;
  *)
    printf '{"error":{"code":"unexpected","message":"unexpected herdr call: %s"}}\n' "$*" >&2
    exit 1
    ;;
esac
SH
  cat > "$dir/fakebin/clear-helper" <<'SH'
#!/usr/bin/env bash
set -u
: "${FM_HERDR_FIXTURES:?}"
printf '%s\n' "$*" >> "$FM_HERDR_FIXTURES/clear.calls"
if [ -n "${FM_HERDR_FIXTURES_HELPER_FAIL:-}" ]; then
  echo "injected helper failure" >&2
  exit 4
fi
: > "$FM_HERDR_FIXTURES/cleared"
SH
  chmod +x "$dir/fakebin/herdr" "$dir/fakebin/clear-helper"
  printf '%s\n' "$dir"
}

# add_herdr_task <dir> <id> [harness]: a task record bound to herdr pane
# default:w1:p2, the exact shape fm_backend_validate_task_endpoint requires.
add_herdr_task() {  # <dir> <id> [harness]
  local dir=$1 id=$2 harness=${3:-pi}
  {
    echo "window=default:w1:p2"
    echo "endpoint_task_id=$id"
    echo "backend=herdr"
    echo "herdr_session=default"
    echo "herdr_workspace_id=w1"
    echo "herdr_tab_id=w1:t2"
    echo "herdr_pane_id=w1:p2"
    echo "worktree=$dir/wt-$id"
    echo "project=$dir/proj-$id"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
  } > "$dir/home/state/$id.meta"
}

# seed_stuck_fixtures <dir> [agent_status]: the pane exists, the registration
# reads <agent_status> (default done), and the socket/schema/session reads the
# clear path needs are in place.
seed_stuck_fixtures() {  # <dir> [agent_status]
  local fx="$1/fixtures" status=${2:-done}
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$fx/pane.get.json"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"%s"}}}\n' "$status" > "$fx/agent.get.json"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$fx/agent-absent.json"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"pane.clear_agent_authority","type":"string"}},"required":["method","params"],"type":"object"}],"$defs":{"PaneClearAgentAuthorityParams":{"properties":{"pane_id":{"type":"string"}},"required":["pane_id"],"type":"object"}}}}}' > "$fx/schema.json"
  printf '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fm-clear-fake.sock"}]}\n' > "$fx/sessions.json"
}

# shell_process_info <pid>: canned `pane process-info` for a pane whose
# foreground is exactly one recognized shell with no agent anywhere - the
# proven agent-less shape, backed by a real process for the descendant walk.
shell_process_info() {  # <pid>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"],"cmdline":"-zsh"}]}}}' "$1" "$1" "$1"
}

agent_process_info() {
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi"],"cmdline":"pi"}]}}}'
}

editor_process_info() {
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4250,"foreground_processes":[{"pid":4250,"name":"vim","argv0":"vim","argv":["vim","notes.md"],"cmdline":"vim notes.md"}]}}}'
}

run_control() {  # <dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_HERDR_FIXTURES="$dir/fixtures" \
    FM_BACKEND_HERDR_CLEAR_AGENT_HELPER="$dir/fakebin/clear-helper" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

herdr_calls() {  # <dir>
  cat "$1/fixtures/calls.log" 2>/dev/null || true
}

# --- 1. the wire transport the clear path posts through ----------------------

# The helper posts exactly one pane.clear_agent_authority request over the
# session socket; the guard and the outcome live in the shell side, but the
# request itself must match the server's own schema or the whole path is a
# silent no-op. A local unix socket stands in for Herdr's control socket.
test_clear_agent_authority_helper_wire_contract() {
  local dir sock server rc out
  command -v python3 >/dev/null 2>&1 || { echo "skip - python3 not found"; return 0; }
  dir="$TMP_ROOT/helper-wire"; mkdir -p "$dir"
  sock="$dir/herdr.sock"
  cat > "$dir/server.py" <<'PY'
import json, socket, sys
path, out_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
srv.settimeout(10)
conn, _ = srv.accept()
buf = b""
while b"\n" not in buf:
    chunk = conn.recv(65536)
    if not chunk:
        break
    buf += chunk
with open(out_path, "wb") as fh:
    fh.write(buf)
if mode == "ok":
    resp = {"id": "fm-clear-agent-authority", "result": {"type": "ok"}}
elif mode == "error":
    resp = {"id": "fm-clear-agent-authority", "error": {"code": "pane_not_found", "message": "gone"}}
else:
    resp = {"id": "someone-else", "result": {"type": "ok"}}
try:
    conn.sendall((json.dumps(resp) + "\n").encode())
except OSError:
    pass
conn.close()
PY
  python3 "$dir/server.py" "$sock" "$dir/req.json" ok &
  server=$!
  rc=0
  for _ in $(seq 1 100); do [ -S "$sock" ] && break; sleep 0.05; done
  [ -S "$sock" ] || fail "the fixture socket never appeared"
  out=$(python3 "$ROOT/bin/backends/herdr-clear-agent-authority.py" "$sock" "w1:p2"); rc=$?
  wait "$server" 2>/dev/null || true
  expect_code 0 "$rc" "the helper must accept an ok response, got rc=$rc out=$out"
  jq -e '.method == "pane.clear_agent_authority"
         and .params.pane_id == "w1:p2"
         and .id == "fm-clear-agent-authority"' "$dir/req.json" >/dev/null \
    || fail "the helper posted the wrong request: $(cat "$dir/req.json")"

  rm -f "$sock"
  python3 "$dir/server.py" "$sock" "$dir/req-error.json" error &
  server=$!
  for _ in $(seq 1 100); do [ -S "$sock" ] && break; sleep 0.05; done
  [ -S "$sock" ] || fail "the fixture socket never appeared (error case)"
  python3 "$ROOT/bin/backends/herdr-clear-agent-authority.py" "$sock" "w1:p2" >/dev/null; rc=$?
  wait "$server" 2>/dev/null || true
  expect_code 4 "$rc" "an error response must exit 4, got $rc"

  # Argument validation happens before any connection, so no server is needed.
  python3 "$ROOT/bin/backends/herdr-clear-agent-authority.py" /nonexistent/fm.sock 'w1:p2; rm' >/dev/null; rc=$?
  expect_code 2 "$rc" "a malformed pane id must exit 2 without connecting, got $rc"
  pass "herdr-clear-agent-authority.py: exact schema-shaped request, ok/error verdicts, fail-closed arguments"
}

# --- 2. exit verifies the stuck class without typing --------------------------

test_exit_reads_already_stopped_on_a_stuck_registration() {
  local dir out rc sleep_bin shell_pid
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  dir=$(new_case exit-stuck)
  add_herdr_task "$dir" t1 pi
  seed_stuck_fixtures "$dir" "done"
  shell_process_info "$shell_pid" > "$dir/fixtures/process-info.json"
  out=$(run_control "$dir" t1 exit); rc=$?
  kill "$shell_pid" 2>/dev/null || true
  expect_code 0 "$rc" "exit on a registration-over-shell pane must succeed (already-stopped); output: $out"
  assert_contains "$out" "already-stopped t1 harness=pi backend=herdr" \
    "exit must verify already-stopped from the process-level corroboration, got: $out"
  assert_not_contains "$(herdr_calls "$dir")" "send-keys" \
    "exit on an already-stopped pane must send no lifecycle key"
  assert_not_contains "$(herdr_calls "$dir")" "send-text" \
    "exit on an already-stopped pane must type no exit command"
  pass "fm-control exit: a stuck done registration over a proven shell pane reads already-stopped and types nothing"
}

# --- 3. clear-registration ----------------------------------------------------

test_clear_registration_clears_a_stuck_agent_less_shell() {
  local dir out rc sleep_bin shell_pid
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  dir=$(new_case clear-stuck)
  add_herdr_task "$dir" t1 pi
  seed_stuck_fixtures "$dir" "done"
  shell_process_info "$shell_pid" > "$dir/fixtures/process-info.json"
  out=$(run_control "$dir" t1 clear-registration); rc=$?
  kill "$shell_pid" 2>/dev/null || true
  expect_code 0 "$rc" "clear-registration on a proven agent-less shell must succeed"
  assert_contains "$out" "cleared-registration t1 harness=pi backend=herdr endpoint=default:w1:p2" \
    "clear-registration must report the cleared outcome, got: $out"
  [ -e "$dir/fixtures/cleared" ] || fail "the clear request was never sent"
  assert_contains "$(cat "$dir/fixtures/clear.calls")" "/tmp/fm-clear-fake.sock w1:p2" \
    "the clear request must carry the session socket and the exact pane id"
  # Three reads: the presence check, the pre-clear session-ref capture, and the
  # post-clear verification.
  [ "$(grep -c '^agent get' "$dir/fixtures/calls.log")" -eq 3 ] \
    || fail "clear-registration must capture the session ref and verify with a post-clear agent get read"
  pass "fm-control clear-registration: a stuck registration over a proven agent-less shell is cleared and verified"
}

test_clear_registration_refuses_a_pane_that_is_not_agent_less() {
  local dir out rc label
  for label in live-agent open-editor unreadable; do
    dir=$(new_case "clear-refuse-$label")
    add_herdr_task "$dir" t1 pi
    seed_stuck_fixtures "$dir" "done"
    case "$label" in
      live-agent) agent_process_info > "$dir/fixtures/process-info.json" ;;
      open-editor) editor_process_info > "$dir/fixtures/process-info.json" ;;
      unreadable) : > "$dir/fixtures/process-info.fail" ;;
    esac
    out=$(run_control "$dir" t1 clear-registration); rc=$?
    expect_code 1 "$rc" "clear-registration must refuse a pane that is $label"
    assert_contains "$out" "refusing to clear task t1's agent registration" \
      "the refusal must be explicit, got: $out"
    [ ! -e "$dir/fixtures/clear.calls" ] \
      || fail "a $label pane must never receive the clear request: $(cat "$dir/fixtures/clear.calls")"
    [ ! -e "$dir/fixtures/cleared" ] || fail "a $label pane must not read as cleared"
  done
  pass "fm-control clear-registration: a live agent, an open editor, and an unreadable process view refuse before the request"
}

test_clear_registration_reports_already_clear_and_transport_failure() {
  local dir out rc sleep_bin shell_pid
  dir=$(new_case clear-already)
  add_herdr_task "$dir" t1 pi
  seed_stuck_fixtures "$dir" "done"
  cp "$dir/fixtures/agent-absent.json" "$dir/fixtures/agent.get.json"
  out=$(run_control "$dir" t1 clear-registration); rc=$?
  expect_code 0 "$rc" "an already-clear pane must be idempotent success"
  assert_contains "$out" "already-clear t1 harness=pi backend=herdr" \
    "already-clear must be reported as such, got: $out"
  [ ! -e "$dir/fixtures/clear.calls" ] || fail "already-clear must send no request"

  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  dir=$(new_case clear-transport-fail)
  add_herdr_task "$dir" t1 pi
  seed_stuck_fixtures "$dir" "done"
  shell_process_info "$shell_pid" > "$dir/fixtures/process-info.json"
  out=$(FM_HERDR_FIXTURES_HELPER_FAIL=1 run_control "$dir" t1 clear-registration); rc=$?
  kill "$shell_pid" 2>/dev/null || true
  expect_code 1 "$rc" "a failed clear request must not report success"
  assert_contains "$out" "did not take" \
    "a transport failure must report the concrete failure, got: $out"
  [ -e "$dir/fixtures/clear.calls" ] || fail "the failing request should still have been attempted"
  [ ! -e "$dir/fixtures/cleared" ] || fail "a failed request must not read as cleared"
  pass "fm-control clear-registration: already-clear is idempotent and a transport failure reports failure"
}

# --- 4. the verb's boundaries -------------------------------------------------

test_unknown_verb_refusal_lists_clear_registration() {
  local dir out rc
  dir=$(new_case verb-refusal)
  add_herdr_task "$dir" t1 pi
  out=$(run_control "$dir" t1 not-a-verb); rc=$?
  expect_code 2 "$rc" "an unknown verb must stay a usage error"
  assert_contains "$out" "clear-registration" \
    "the refusal must list clear-registration among the allowed verbs"
  assert_contains "$out" "is not a control verb" "the refusal must say so"
  pass "fm-control: the closed allowlist lists clear-registration and still refuses anything else"
}

# The list at the end of this file runs every case in order.
test_clear_agent_authority_helper_wire_contract
test_exit_reads_already_stopped_on_a_stuck_registration
test_clear_registration_clears_a_stuck_agent_less_shell
test_clear_registration_refuses_a_pane_that_is_not_agent_less
test_clear_registration_reports_already_clear_and_transport_failure
test_unknown_verb_refusal_lists_clear_registration
