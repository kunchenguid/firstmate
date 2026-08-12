#!/usr/bin/env bash
# tests/fm-backend-paseo.test.sh - unit tests for Paseo session-provider adapter
# (bin/backends/paseo.sh) and dispatcher integration (bin/fm-backend.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the paseo adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)

make_paseo_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/paseo" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_PASEO_LOG:?}"
RESP="${FM_PASEO_RESPONSES:?}"
COUNT_FILE="$RESP/.count"

{
  printf 'PASEO_CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = inspect ] && [ "${2:-}" = agent-parent-for-test ]; then
  printf '{"model":"test/provider-model"}\n'
  exit 0
fi

if [ "${1:-}" = status ]; then
  if [ -f "$RESP/status.exit" ]; then
    exit "$(cat "$RESP/status.exit")"
  fi
  if [ -f "$RESP/status.out" ]; then
    cat "$RESP/status.out"
    exit 0
  fi
  printf '{"localDaemon":"running","connectedDaemon":"reachable"}\n'
  exit 0
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
if [ -f "$RESP/$n.out" ]; then
  cat "$RESP/$n.out"
fi
exit 0
SH
  chmod +x "$fb/paseo"

  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
wt="${FM_FAKE_WORKTREE:-/tmp/fake-worktree-root}"
mkdir -p "$wt"
if [ "${1:-}" = "get" ] && [ "${2:-}" = "--lease" ]; then
  printf '🌳 Setting up worktree...\n' >&2
  printf '%s\n' "$wt"
  exit 0
fi
exit 0
SH
  chmod +x "$fb/treehouse"

  printf '%s\n' "$fb"
}

SETUP_DIR="$TMP_ROOT/setup"
mkdir -p "$SETUP_DIR/responses"
FAKEBIN=$(make_paseo_fakebin "$SETUP_DIR")
export PATH="$FAKEBIN:$PATH"
export FM_PASEO_LOG="$SETUP_DIR/paseo.log"
export FM_PASEO_RESPONSES="$SETUP_DIR/responses"
# Explicit fallback models are required when the fake parent has no inspectable identity.
export PASEO_MODEL_FALLBACK="test/provider-model"

reset_responses() {
  rm -f "$FM_PASEO_RESPONSES"/* "$FM_PASEO_RESPONSES"/.count "$FM_PASEO_RESPONSES"/.exit
}

# Source the backend functions
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source paseo

# Test 1: Known and spawn-supported backends contain paseo
if fm_backend_is_known paseo && fm_backend_validate_spawn paseo >/dev/null 2>&1; then
  pass "paseo registered in FM_BACKEND_KNOWN and FM_BACKEND_SPAWN"
else
  fail "paseo missing from FM_BACKEND_KNOWN or FM_BACKEND_SPAWN"
fi

# Test 2: Required tools for paseo
req_tools=$(fm_backend_required_tools paseo)
if [ "$req_tools" = "paseo jq treehouse" ]; then
  pass "fm_backend_required_tools paseo returned expected toolset"
else
  fail "unexpected required tools for paseo: $req_tools"
fi

# Test 3: Auto-detection via PASEO_AGENT_ID
run_paseo_detection_test() {
  unset TMUX HERDR_ENV CMUX_WORKSPACE_ID
  export PASEO_AGENT_ID="agent-12345"
  detected=$(fm_backend_detect)
  if [ "$detected" = "paseo" ]; then
    pass "fm_backend_detect detected paseo via PASEO_AGENT_ID"
  else
    fail "fm_backend_detect failed to detect paseo: '$detected'"
  fi
}
run_paseo_detection_test

# Test 4: fm_backend_paseo_parent_id
run_paseo_parent_env_test() {
  export PASEO_AGENT_ID="agent-parent-1"
  pid=$(fm_backend_paseo_parent_id)
  if [ "$pid" = "agent-parent-1" ]; then
    pass "fm_backend_paseo_parent_id returned PASEO_AGENT_ID from env"
  else
    fail "unexpected parent_id: '$pid'"
  fi
  unset PASEO_AGENT_ID
}
run_paseo_parent_env_test

run_paseo_parent_fallback_test() {
  reset_responses
  unset PASEO_AGENT_ID
  # Call 1 response for paseo ls --json
  printf '[{"id":"agent-fallback-99","status":"running"}]\n' > "$FM_PASEO_RESPONSES/1.out"
  pid=$(fm_backend_paseo_parent_id)
  if [ "$pid" = "agent-fallback-99" ]; then
    pass "fm_backend_paseo_parent_id fell back to paseo ls"
  else
    fail "unexpected fallback parent_id: '$pid'"
  fi
}
run_paseo_parent_fallback_test

reset_responses

# Test 5: fm_backend_paseo_create_task
run_paseo_create_task_test() {
  local proj_dir brief_file task_tmp out agent_id wt sm_dir out_sm agent_id_sm wt_sm
  proj_dir="$TMP_ROOT/proj"
  brief_file="$TMP_ROOT/brief.md"
  task_tmp="$TMP_ROOT/tasktmp"
  mkdir -p "$proj_dir" "$task_tmp"
  echo "Task instructions" > "$brief_file"
  export FM_FAKE_WORKTREE="$TMP_ROOT/wt-paseo-1"

  # Parent identity is supplied by the runtime; the run response is call 1.
  export PASEO_AGENT_ID="agent-parent-for-test"
  printf '{"id":"paseo-agent-001"}\n' > "$FM_PASEO_RESPONSES/1.out"

  out=$(fm_backend_paseo_create_task "fm-test-task" "$proj_dir" "$brief_file" "$task_tmp" "traceparent-123")
  read -r agent_id wt <<EOF
$out
EOF
  if [ "$agent_id" = "paseo-agent-001" ] && [ "$wt" = "$TMP_ROOT/wt-paseo-1" ] && \
     grep -q "PASEO_CALL.*run.*--env.*GOTMPDIR=$task_tmp/gotmp" "$FM_PASEO_LOG" && \
     grep -q "PASEO_CALL.*run.*--env.*TRACEPARENT=traceparent-123" "$FM_PASEO_LOG"; then
    pass "fm_backend_paseo_create_task allocated worktree, passed env, and spawned agent"
  else
    fail "unexpected task creation output or call log: '$out'"
  fi

  reset_responses

  sm_dir="$TMP_ROOT/sm-home"
  mkdir -p "$sm_dir"
  touch "$sm_dir/.fm-secondmate-home"
  printf '{"id":"paseo-agent-sm-1"}\n' > "$FM_PASEO_RESPONSES/1.out"
  out_sm=$(fm_backend_paseo_create_task "fm-sm-task" "$sm_dir" "$brief_file" "$task_tmp" "traceparent-123" "secondmate")
  read -r agent_id_sm wt_sm <<EOF
$out_sm
EOF
  if [ "$agent_id_sm" = "paseo-agent-sm-1" ] && [ "$wt_sm" = "$sm_dir" ]; then
    pass "fm_backend_paseo_create_task used secondmate home directly as worktree"
  else
    fail "unexpected secondmate task creation output: '$out_sm'"
  fi
  unset FM_FAKE_WORKTREE PASEO_AGENT_ID
}
run_paseo_create_task_test

reset_responses

# Test 6: fm_backend_paseo_capture
(
  printf 'log line 1\nlog line 2\n' > "$FM_PASEO_RESPONSES/1.out"
  cap=$(fm_backend_paseo_capture "paseo-agent-001" 10)
  if [ "$cap" = $'log line 1\nlog line 2' ]; then
    pass "fm_backend_paseo_capture returned log output"
  else
    fail "unexpected capture output: '$cap'"
  fi
)

reset_responses

# Test 7: fm_backend_paseo_send_text_submit
(
  # Call 1: paseo send
  printf '{"status":"ok"}\n' > "$FM_PASEO_RESPONSES/1.out"
  res=$(fm_backend_paseo_send_text_submit "paseo-agent-001" "hello agent")
  if [ "$res" = "" ]; then
    pass "fm_backend_paseo_send_text_submit returned success"
  else
    fail "unexpected send_text_submit output: '$res'"
  fi
)

reset_responses

# Test 8: fm_backend_paseo_send_key
(
  # Call 1: paseo stop for Escape
  printf '' > "$FM_PASEO_RESPONSES/1.out"
  fm_backend_paseo_send_key "paseo-agent-001" "Escape"

  # Verify invocation log contains stop
  if grep -q "PASEO_CALL.stop.paseo-agent-001" "$FM_PASEO_LOG"; then
    pass "fm_backend_paseo_send_key Escape issued paseo stop"
  else
    fail "paseo stop not found in call log"
  fi
)

reset_responses

# Test 9: fm_backend_paseo_kill
(
  # Call 1: stop, Call 2: archive
  printf '' > "$FM_PASEO_RESPONSES/1.out"
  printf '' > "$FM_PASEO_RESPONSES/2.out"
  fm_backend_paseo_kill "paseo-agent-001"

  if grep -q "PASEO_CALL.archive.--force.paseo-agent-001" "$FM_PASEO_LOG"; then
    pass "fm_backend_paseo_kill archived agent"
  else
    fail "paseo archive not found in call log"
  fi
)

reset_responses

# Test 10: fm_backend_paseo_busy_state & composer_state
(
  # Call 1: running -> busy / pending
  printf '{"status":"running"}\n' > "$FM_PASEO_RESPONSES/1.out"
  st1=$(fm_backend_paseo_busy_state "paseo-agent-001")
  reset_responses

  printf '{"status":"idle"}\n' > "$FM_PASEO_RESPONSES/1.out"
  st2=$(fm_backend_paseo_busy_state "paseo-agent-001")
  reset_responses

  printf '{"status":"closed"}\n' > "$FM_PASEO_RESPONSES/1.out"
  st3=$(fm_backend_paseo_busy_state "paseo-agent-001")
  reset_responses

  if [ "$st1" = "busy" ] && [ "$st2" = "idle" ] && [ "$st3" = "dead" ]; then
    pass "fm_backend_paseo_busy_state correctly mapped status"
  else
    fail "unexpected busy states: st1=$st1 st2=$st2 st3=$st3"
  fi
)

reset_responses

# Test 11: fm_backend_paseo_agent_state
(
  printf '{"status":"running"}\n' > "$FM_PASEO_RESPONSES/1.out"
  ast1=$(fm_backend_paseo_agent_state "paseo-agent-001")
  reset_responses

  printf '{"status":"failed"}\n' > "$FM_PASEO_RESPONSES/1.out"
  ast2=$(fm_backend_paseo_agent_state "paseo-agent-001")
  reset_responses

  # Exit 1 -> missing
  echo "1" > "$FM_PASEO_RESPONSES/1.exit"
  ast3=$(fm_backend_paseo_agent_state "paseo-nonexistent")
  reset_responses

  # Exit 1 + daemon offline -> unreadable
  echo "1" > "$FM_PASEO_RESPONSES/1.exit"
  echo "1" > "$FM_PASEO_RESPONSES/status.exit"
  ast4=$(fm_backend_paseo_agent_state "paseo-unreachable")
  reset_responses

  if [ "$ast1" = "alive" ] && [ "$ast2" = "dead" ] && [ "$ast3" = "missing" ] && [ "$ast4" = "unreadable" ]; then
    pass "fm_backend_paseo_agent_state returned recovery-grade states"
  else
    fail "unexpected agent states: ast1=$ast1 ast2=$ast2 ast3=$ast3 ast4=$ast4"
  fi
)

reset_responses

# Test 12: fm_backend_paseo_current_path
(
  printf '{"cwd":"/tmp/worktree-123"}\n' > "$FM_PASEO_RESPONSES/1.out"
  cwd=$(fm_backend_paseo_current_path "paseo-agent-001")
  if [ "$cwd" = "/tmp/worktree-123" ]; then
    pass "fm_backend_paseo_current_path returned working directory"
  else
    fail "unexpected current path: '$cwd'"
  fi
)

reset_responses

# Test 13: fm_backend_paseo_list_live
(
  printf '[{"id":"agent-1","name":"fm-task-1","status":"running"},{"id":"agent-2","name":"fm-task-2","status":"closed"}]\n' > "$FM_PASEO_RESPONSES/1.out"
  list=$(fm_backend_paseo_list_live)
  if [ "$list" = $'agent-1\tfm-task-1' ]; then
    pass "fm_backend_paseo_list_live filtered live agents"
  else
    fail "unexpected list_live output: '$list'"
  fi
)

reset_responses

# Test 14: Metadata endpoint validation via fm_backend_validate_task_endpoint
(
  state_dir="$TMP_ROOT/state"
  mkdir -p "$state_dir"
  meta_file="$state_dir/t1.meta"

  cat > "$meta_file" <<EOF
window=paseo-agent-99
endpoint_task_id=t1
worktree=/tmp/wt-1
project=/tmp/proj-1
harness=pi
kind=ship
backend=paseo
paseo_agent_id=paseo-agent-99
EOF

  if fm_backend_validate_task_endpoint "$meta_file" "t1"; then
    pass "fm_backend_validate_task_endpoint accepted valid paseo metadata"
  else
    fail "fm_backend_validate_task_endpoint refused valid paseo metadata"
  fi
)

# Test 15: Generic dispatcher routing for paseo
(
  reset_responses
  printf '{"status":"running"}\n' > "$FM_PASEO_RESPONSES/1.out"
  st=$(fm_backend_busy_state paseo "paseo-agent-001")
  if [ "$st" = "busy" ]; then
    pass "generic fm_backend_busy_state routed to paseo"
  else
    fail "generic dispatch failed for paseo busy_state: '$st'"
  fi
)

# Test 16: fm-spawn.sh with backend=paseo passes TASK_TMP and suppresses unintended send commands
run_paseo_spawn_test() {
  local spawn_origin spawn_proj spawn_wt out rc meta_file tasktmp_val
  reset_responses
  : > "$FM_PASEO_LOG"
  spawn_origin="$TMP_ROOT/spawn-origin.git"
  spawn_proj="$TMP_ROOT/spawn-proj"
  spawn_wt="$TMP_ROOT/wt-spawn-1"
  git init --bare -q "$spawn_origin"
  mkdir -p "$spawn_proj"
  git -C "$spawn_proj" init -q 2>/dev/null || true
  git -C "$spawn_proj" config user.email "test@example.com"
  git -C "$spawn_proj" config user.name "Test"
  touch "$spawn_proj/README"
  git -C "$spawn_proj" add README
  git -C "$spawn_proj" commit -qm "init"
  git -C "$spawn_proj" remote add origin "$spawn_origin"
  git -C "$spawn_proj" push -q origin HEAD
  git -C "$spawn_proj" worktree add -q -b branch-spawn-1 "$spawn_wt"

  export FM_HOME="$TMP_ROOT/fm-home"
  export FM_ROOT="$ROOT"
  export FM_FAKE_WORKTREE="$spawn_wt"
  export PASEO_AGENT_ID="agent-parent-for-test"
  mkdir -p "$FM_HOME/state" "$FM_HOME/data/paseo-task-1"
  printf 'Test brief instructions\n' > "$FM_HOME/data/paseo-task-1/brief.md"

  printf '{"id":"paseo-agent-spawn-1"}\n' > "$FM_PASEO_RESPONSES/1.out"

  out=$( "$ROOT/bin/fm-spawn.sh" paseo-task-1 "$spawn_proj" --backend paseo --mode no-mistakes --yolo off 2>&1 )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    meta_file="$FM_HOME/state/paseo-task-1.meta"
    if [ -f "$meta_file" ]; then
      tasktmp_val=$(grep '^tasktmp=' "$meta_file" | cut -d= -f2-)
      if [ "$tasktmp_val" = "/tmp/fm-paseo-task-1" ]; then
        pass "fm-spawn.sh with backend=paseo bound TASK_TMP in metadata"
      else
        fail "unexpected tasktmp in metadata: '$tasktmp_val'"
      fi
    else
      fail "meta file missing after paseo spawn"
    fi

    if grep -q "PASEO_CALL.*run.*--env.*GOTMPDIR=/tmp/fm-paseo-task-1/gotmp" "$FM_PASEO_LOG"; then
      pass "fm-spawn.sh passed bound GOTMPDIR env to paseo run"
    else
      fail "GOTMPDIR env missing from paseo run invocation log"
    fi

    if grep -q "PASEO_CALL.*send" "$FM_PASEO_LOG"; then
      fail "fm-spawn.sh incorrectly invoked paseo send during paseo backend launch"
    else
      pass "fm-spawn.sh suppressed shell send commands for paseo backend"
    fi
  else
    fail "fm-spawn.sh failed with exit code $rc: $out"
  fi
  unset FM_FAKE_WORKTREE PASEO_AGENT_ID
}
run_paseo_spawn_test

echo "All tests passed!"
