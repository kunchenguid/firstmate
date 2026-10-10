#!/usr/bin/env bash
# tests/fm-t3-mcp.test.sh - bin/fm-t3-mcp.mjs, the t3code backend's `/mcp`
# transport, driven through its CLI against tests/t3-fake-server.mjs: the
# captain-run sign-in, the capability gate, the environment-identity check,
# credential expiry and permissions, and every verb's result shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-mcp-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
HELPER="$ROOT/bin/fm-t3-mcp.mjs"
CRED="$TMP_ROOT/config/t3code-token"
WT="$TMP_ROOT/worktree"
SEL='{"instanceId":"claudeAgent","model":"claude-sonnet-5-5","options":[{"id":"effort","value":"low"}]}'
mkdir -p "$WT" "$TMP_ROOT/proj"

mcp() {  # <verb> [args...] -> stdout in OUT, stderr in ERR, exit in RC
  local errf="$TMP_ROOT/stderr"
  OUT=$(node "$HELPER" "$@" --token-file "$CRED" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
}

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v==null?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}

t3_fake_items() {  # <thread-id> <text> -> how many items of the thread carry <text>
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(w.threads[process.argv[2]].items.filter((i) => i.text === process.argv[3]).length))' "$T3_FAKE_WORLD" "$1" "$2"
}

fresh_case() {  # <name> [world-json]
  t3_fake_case "$TMP_ROOT/cases/$1" "${2:-}"
  t3_fake_credential "$CRED"
}

test_login_writes_private_credential_and_never_prints_token() {
  local cli
  t3_fake_case "$TMP_ROOT/cases/login"
  rm -f "$CRED"
  cli=$(t3_fake_t3_cli "$TMP_ROOT/cli")
  mcp login --url "$T3_FAKE_URL" --access full-access --t3 "$cli" --base-dir "$TMP_ROOT/t3home"
  expect_code 0 "$RC" "login should succeed against the fake server: $ERR"
  assert_equals true "$(field "$OUT" ok)" "login result should be ok"
  assert_equals env-fake-1 "$(field "$OUT" environmentId)" "login should record the server's environment id"
  assert_not_contains "$OUT$ERR" "tok-" "login must never print the access token"
  assert_not_contains "$OUT$ERR" "PAIR-OK" "login must never print the pairing code"
  [ "$(stat -c %a "$CRED" 2>/dev/null || stat -f %Lp "$CRED")" = 600 ] || fail "credential file must be mode 0600"
  assert_grep '"environment_id":"env-fake-1"' "$CRED" "credential must record the environment id"
  assert_grep '"origin":"'"$T3_FAKE_URL"'"' "$CRED" "credential must record the origin"
  assert_grep "auth pairing create --base-dir $TMP_ROOT/t3home --scope orchestration:read --scope orchestration:operate --ttl 2m" "$TMP_ROOT/cli/t3-cli.log" \
    "sign-in must mint a two-minute pairing code scoped to orchestration read and operate"
  assert_grep '"access":"full-access"' "$T3_FAKE_LOG" "the OAuth decision must carry the full-access ceiling"
  assert_grep '"pkce":true' "$T3_FAKE_LOG" "the token exchange must prove the PKCE verifier"
  pass "fm-t3-mcp login: PKCE sign-in writes a 0600 credential with the environment id and prints no secret"
}

test_login_origin_defaults() {
  local cli home
  t3_fake_case "$TMP_ROOT/cases/login-origin"
  cli=$(t3_fake_t3_cli "$TMP_ROOT/cli")
  home="$TMP_ROOT/user-home"
  mkdir -p "$home/.t3/userdata"
  printf '{"origin":"%s/"}\n' "$T3_FAKE_URL" > "$home/.t3/userdata/server-runtime.json"
  rm -f "$CRED"
  OUT=$(HOME="$home" FM_T3CODE_ORIGIN='' node "$HELPER" login --access full-access --t3 "$cli" --token-file "$CRED" 2>"$TMP_ROOT/stderr"); RC=$?
  expect_code 0 "$RC" "login should take the origin from T3's runtime file: $(cat "$TMP_ROOT/stderr")"
  assert_equals "$T3_FAKE_URL" "$(field "$OUT" origin)" "the runtime file's origin is normalized"
  rm -f "$CRED"
  OUT=$(HOME="$TMP_ROOT/nowhere" FM_T3CODE_ORIGIN='' node "$HELPER" login --access full-access --t3 "$cli" --token-file "$CRED" 2>"$TMP_ROOT/stderr"); RC=$?
  expect_code 2 "$RC" "login without any origin is invalid use"
  assert_contains "$(cat "$TMP_ROOT/stderr")" "FM_T3CODE_ORIGIN" "the refusal names the override"
  assert_contains "$(cat "$TMP_ROOT/stderr")" "server-runtime.json" "the refusal names the runtime file"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp login: the origin defaults to FM_T3CODE_ORIGIN, then T3's runtime file, else refuses naming both"
}

test_login_refuses_other_ceilings() {
  local before after
  before=$(wc -l < "$T3_FAKE_LOG")
  mcp login --url "$T3_FAKE_URL" --access auto-accept-edits --t3 /bin/false
  expect_code 2 "$RC" "a non-full-access ceiling is invalid use"
  assert_contains "$ERR" "only the full-access ceiling" "the refusal should explain the ceiling"
  after=$(wc -l < "$T3_FAKE_LOG")
  assert_equals "$before" "$after" "a refused ceiling must not reach the server"
  pass "fm-t3-mcp login: refuses every ceiling but full-access before any request"
}

test_status_gate_and_protocol() {
  fresh_case status
  mcp status
  expect_code 0 "$RC" "status should pass the gate: $ERR"
  assert_equals env-fake-1 "$(field "$OUT" environmentId)" "status should report the environment id"
  assert_equals 0.0.46-nightly.fake "$(field "$OUT" serverVersion)" "status should report the server version"
  assert_grep '"protocol":"2025-06-18"' "$T3_FAKE_LOG" "every MCP request must carry protocol version 2025-06-18"
  t3_fake_set 'w.sse = true'
  mcp status
  expect_code 0 "$RC" "status should parse SSE replies too: $ERR"
  pass "fm-t3-mcp status: gate passes over JSON and SSE replies with the 2025-06-18 protocol header"
}

test_gate_refuses_missing_tools() {
  fresh_case gate
  t3_fake_set 'w.tools = ["t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create","t3_environment_read"]'
  mcp status
  expect_code 4 "$RC" "a server without t3_thread_launch must be refused"
  assert_equals capability_gate "$(field "$OUT" error.code)" "the refusal should be the capability gate"
  assert_contains "$ERR" "t3_thread_launch" "the refusal should name the missing tool"
  t3_fake_set 'w.tools = ["t3_thread_launch","t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_thread_list","t3_thread_configuration","t3_project_list","t3_project_create","t3_pending_request_list","t3_pending_request_read","t3_pending_request_respond","orchestrator_capabilities"]'
  mcp status
  expect_code 4 "$RC" "a server without t3_environment_read cannot prove its identity"
  assert_contains "$ERR" "lacks t3_environment_read" "the refusal should name the missing identity tool"
  pass "fm-t3-mcp gate: refuses a server missing a required tool or its identity tool"
}

test_environment_mismatch_refused() {
  fresh_case env-mismatch '{"environmentId":"env-other"}'
  mcp status
  expect_code 4 "$RC" "a different environment behind the same origin must be refused"
  assert_equals environment_mismatch "$(field "$OUT" error.code)" "the refusal should be an environment mismatch"
  mcp state --thread mcp:none
  expect_code 4 "$RC" "every verb runs the environment check"
  pass "fm-t3-mcp: refuses a server whose environment id differs from the credential's"
}

test_expiry_and_permissions() {
  local before after
  fresh_case expiry
  t3_fake_credential "$CRED" env-fake-1 $(( ($(date +%s) - 60) * 1000 ))
  before=$(wc -l < "$T3_FAKE_LOG")
  mcp status
  expect_code 4 "$RC" "an expired credential must be refused"
  assert_equals credential_expired "$(field "$OUT" error.code)" "expired refusal code"
  after=$(wc -l < "$T3_FAKE_LOG")
  assert_equals "$before" "$after" "an expired credential must not reach the server"
  t3_fake_credential "$CRED" env-fake-1 $(( ($(date +%s) + 2 * 86400) * 1000 ))
  mcp status
  expect_code 0 "$RC" "a credential two days from expiry still works"
  assert_contains "$ERR" "warning: T3 credential expires in" "near expiry warns on stderr"
  assert_contains "$(field "$OUT" credentialWarning)" "expires in" "status reports the expiry warning"
  t3_fake_credential "$CRED" env-fake-1 "" 644
  mcp status
  expect_code 4 "$RC" "a credential readable by others must be refused"
  assert_equals credential_permissions "$(field "$OUT" error.code)" "permission refusal code"
  rm -f "$CRED"
  mcp status
  expect_code 4 "$RC" "a missing credential must be refused"
  assert_contains "$ERR" "fm-t3-mcp.mjs login --access full-access" "the missing-credential refusal names the captain's sign-in"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp credential: refuses expired, missing, and over-readable credentials, and warns before expiry"
}

test_revoked_credential_refused() {
  fresh_case revoked '{"revoked":true}'
  mcp status
  expect_code 4 "$RC" "a revoked credential must be refused"
  assert_equals unauthorized "$(field "$OUT" error.code)" "revoked refusal code"
  pass "fm-t3-mcp: a 401 from a revoked credential is a local refusal naming a fresh sign-in"
}

test_projects_by_real_path() {
  local project
  fresh_case projects
  mkdir -p "$TMP_ROOT/link-parent"
  ln -sfn "$TMP_ROOT/proj" "$TMP_ROOT/link-parent/proj-link"
  mcp project-ensure --root "$TMP_ROOT/link-parent/proj-link" --title fm-proj
  expect_code 0 "$RC" "project-ensure should create the project: $ERR"
  project=$(field "$OUT" projectId)
  assert_equals true "$(field "$OUT" created)" "first project-ensure creates"
  assert_equals "$(cd "$TMP_ROOT/proj" && pwd -P)" "$(field "$(t3_fake_calls t3_project_create)" workspaceRoot)" "the project is registered at its real path"
  mcp project-ensure --root "$TMP_ROOT/proj"
  assert_equals "$project" "$(field "$OUT" projectId)" "a second project-ensure finds the same project by real path"
  assert_equals false "$(field "$OUT" created)" "a second project-ensure does not create"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection = { instanceId: "claudeAgent", model: "claude-sonnet-5-5" }'
  mcp project-read --project "$project"
  expect_code 0 "$RC" "project-read: $ERR"
  assert_equals claude-sonnet-5-5 "$(field "$OUT" project.defaultModelSelection.model)" "project-read returns the default model selection"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).deletedAt = "2026-10-01T00:00:00Z"'
  mcp project-read --project "$project"
  expect_code 3 "$RC" "a deleted project reads as not found"
  assert_equals project_not_found "$(field "$OUT" error.code)" "project-read refusal code"
  mcp project-ensure --root "$TMP_ROOT/proj"
  assert_equals true "$(field "$OUT" created)" "a deleted project's root registers again"
  pass "fm-t3-mcp projects: matched by real path, deleted ones skipped, project-read returns the default model"
}

test_launch_binds_workspace() {
  local project call
  fresh_case launch
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title fm-a --model-selection "$SEL" --worktree "$WT" --branch fm/a
  expect_code 0 "$RC" "launch should create an idle thread: $ERR"
  case "$(field "$OUT" threadId)" in mcp:*) ;; *) fail "launch should print T3's thread id, got '$OUT'" ;; esac
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals full-access "$(field "$call" runtimeMode)" "launch must request full access"
  assert_equals existing_worktree "$(field "$call" workspaceStrategy.type)" "launch must bind an existing worktree"
  assert_equals "$WT" "$(field "$call" workspaceStrategy.worktreePath)" "launch must bind the given worktree"
  assert_equals fm/a "$(field "$call" workspaceStrategy.branch)" "launch carries the branch"
  assert_equals "$SEL" "$(field "$call" modelSelection)" "launch carries the model selection verbatim"
  assert_equals "" "$(field "$call" message)" "a launch without a message file creates an idle thread"
  mcp launch --project "$project" --title fm-home --model-selection "$SEL"
  expect_code 0 "$RC" "a worktree-less launch runs at the project root: $ERR"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals '{"type":"root"}' "$(field "$call" workspaceStrategy)" "a worktree-less launch uses the root strategy"
  pass "fm-t3-mcp launch: idle full-access thread on the existing worktree or the project root, with the given model selection"
}

test_launch_refusals() {
  local project
  fresh_case launch-refusals
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title x --model-selection '{"model":"m"}' --worktree "$WT"
  expect_code 2 "$RC" "a model selection without an instance is invalid use"
  t3_fake_set 'w.bindWorktree = "/somewhere/else"'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread bound to another worktree is refused"
  assert_equals binding_mismatch "$(field "$OUT" error.code)" "binding refusal code"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "a mis-bound thread is archived before refusing"
  t3_fake_set 'delete w.bindWorktree; w.bindInstance = "codex"'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread on another provider instance is refused"
  t3_fake_set 'delete w.bindInstance; w.bindRuntimeMode = "auto-accept-edits"'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread below full access is refused"
  t3_fake_set 'w.failTools = { t3_thread_organize: { code: "boom", message: "archive failed" } }'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a mis-bound thread whose archive failed is an uncertain outcome"
  assert_contains "$ERR" "archive it in T3 Code" "the uncertain refusal names the manual archive"
  t3_fake_set 'delete w.bindRuntimeMode; w.failTools = { t3_thread_read: { code: "thread_not_found", message: "not yet projected" } }'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launched thread whose binding read-back failed is an uncertain outcome"
  assert_equals binding_unconfirmed "$(field "$OUT" error.code)" "read-back failure refusal code"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "a thread with an unproven binding is archived before refusing"
  t3_fake_set 'w.failTools = {}; w.dropTools = { t3_thread_launch: 1 }'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launch whose reply was lost is an uncertain transport failure"
  pass "fm-t3-mcp launch: refuses a binding T3 did not honor, and reports a lost, unproven, or unarchivable launch as uncertain"
}

new_thread() {  # -> thread id
  local project
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title fm-t --model-selection "$SEL" --worktree "$WT"
  field "$OUT" threadId
}

test_send_state_capture_interrupt_archive() {
  local thread msg
  fresh_case thread-verbs
  thread=$(new_thread)
  msg="$TMP_ROOT/msg"
  printf 'hello worker' > "$msg"
  mcp state --thread "$thread"
  assert_equals idle "$(field "$OUT" status)" "a fresh thread is idle"
  assert_equals "" "$(field "$OUT" turnAt)" "a thread with no run has no turn time"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-1
  expect_code 0 "$RC" "send should start the idle thread: $ERR"
  assert_equals started "$(field "$OUT" delivery)" "an idle thread starts a turn"
  assert_contains "$(t3_fake_calls t3_thread_send | tail -1)" '"mode":"auto","clientRequestId":"req-1"' "send uses mode auto with the request id"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-1
  assert_equals started "$(field "$OUT" delivery)" "a repeated request id is the same message"
  mcp state --thread "$thread"
  assert_equals running "$(field "$OUT" status)" "a started thread runs"
  [ -n "$(field "$OUT" activeRunId)" ] || fail "a running thread has an active run"
  [ -n "$(field "$OUT" turnAt)" ] || fail "a running thread reports its turn time"
  mcp capture --thread "$thread" --lines 5
  expect_code 0 "$RC" "capture: $ERR"
  assert_contains "$OUT" "[user_message/completed] hello worker" "capture renders activity items"
  assert_equals "t3code: status=running run=$(field "$(node "$HELPER" state --thread "$thread" --token-file "$CRED")" activeRunId)" "$(printf '%s\n' "$OUT" | tail -1)" "capture ends with the thread's status line"
  mcp capture --thread "$thread" --lines 1
  case "$OUT" in 't3code: status=running run='*) ;; *) fail "the tightest capture bound still shows the status line, got '$OUT'" ;; esac
  mcp interrupt --thread "$thread"
  assert_equals confirmed "$(field "$OUT" cancel)" "interrupting a running turn is confirmed by the wait"
  mcp interrupt --thread "$thread"
  assert_equals not-running "$(field "$OUT" cancel)" "interrupting an idle thread reports not-running"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-2
  t3_fake_set 'w.waitTimesOut = true'
  mcp interrupt --thread "$thread" --timeout-ms 100
  assert_equals unconfirmed "$(field "$OUT" cancel)" "a wait that times out leaves the cancel unconfirmed"
  t3_fake_set 'w.archiveKeepsRun = true'
  mcp archive --thread "$thread" --timeout-ms 300
  expect_code 3 "$RC" "an archive that leaves an active run is not a proven close"
  assert_equals close_unproven "$(field "$OUT" error.code)" "unproven close code"
  t3_fake_set 'w.waitTimesOut = false; w.archiveKeepsRun = false'
  thread=$(new_thread)
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-3
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "archive should prove the close: $ERR"
  assert_equals true "$(field "$OUT" closed)" "archive reports a proven close"
  assert_equals true "$(field "$OUT" archived)" "archive reads back archived"
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "archiving an archived thread is the same end state"
  mcp state --thread "$thread"
  assert_equals true "$(field "$OUT" archived)" "state reports archived"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-4
  expect_code 3 "$RC" "an archived thread refuses messages as a typed T3 failure"
  assert_equals thread_not_sendable "$(field "$OUT" error.code)" "T3's own error code is carried"
  mcp archive --thread mcp:gone
  expect_code 0 "$RC" "a thread the verified server does not have is already closed"
  assert_equals true "$(field "$OUT" missing)" "archive of a missing thread reports missing"
  mcp state --thread mcp:gone
  assert_equals false "$(field "$OUT" exists)" "state of a missing thread reads exists:false"
  pass "fm-t3-mcp thread verbs: idempotent send, state and turn time, bounded capture, interrupt claims, and proven archive"
}

test_thread_for_root() {
  local project captain other
  fresh_case thread-for-root
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "no live thread on the root is exit 5"
  mcp launch --project "$project" --title worker --model-selection "$SEL" --worktree "$WT"
  printf 'go' > "$TMP_ROOT/msg"
  mcp send --thread "$(field "$OUT" threadId)" --message-file "$TMP_ROOT/msg" --client-request-id w
  mcp launch --project "$project" --title captain --model-selection "$SEL"
  captain=$(field "$OUT" threadId)
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "an idle root thread and a running worktree thread are not the supervisor"
  mcp send --thread "$captain" --message-file "$TMP_ROOT/msg" --client-request-id c
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "one running root thread resolves: $ERR"
  assert_equals "$captain" "$(field "$OUT" threadId)" "the running root thread is the supervisor"
  mcp launch --project "$project" --title other --model-selection "$SEL"
  other=$(field "$OUT" threadId)
  mcp send --thread "$other" --message-file "$TMP_ROOT/msg" --client-request-id o
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 6 "$RC" "two running root threads are ambiguous"
  assert_contains "$ERR" "FM_SUPERVISOR_TARGET" "the ambiguity names the pin"
  assert_contains "$(field "$OUT" error.threadIds)" "$captain" "the ambiguity lists the ids"
  mcp archive --thread "$other"
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "an archived root thread no longer counts"
  pass "fm-t3-mcp thread-for-root: only an unarchived, running, worktree-less thread on the root resolves"
}

test_typed_failure_and_transport_errors() {
  local thread
  fresh_case failures
  thread=$(new_thread)
  printf 'x' > "$TMP_ROOT/msg"
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "invalid_request", message: "nope" } }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-x
  expect_code 3 "$RC" "a tool error is a typed T3 failure"
  assert_equals invalid_request "$(field "$OUT" error.code)" "typed failure code"
  t3_fake_credential "$CRED" env-fake-1 "" 600 http://127.0.0.1:9
  mcp status
  expect_code 1 "$RC" "an unreachable server is a transport failure"
  assert_equals transport "$(field "$OUT" error.code)" "transport failure code"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp: tool errors exit 3 with T3's code, an unreachable server exits 1"
}

test_telemetry_reported() {
  local tdir="$TMP_ROOT/telemetry"
  t3_fake_stop
  t3_fake_start "$tdir" T3CODE_TELEMETRY_ENABLED=false
  fresh_case telemetry-off
  mcp status
  expect_code 0 "$RC" "status against a telemetry-off server: $ERR"
  if command -v lsof >/dev/null 2>&1; then
    assert_equals off "$(field "$OUT" telemetry)" "a loopback server started with telemetry off reads off"
    assert_not_contains "$ERR" "telemetry" "telemetry off warns nothing"
  fi
  t3_fake_stop
  t3_fake_start "$tdir"
  fresh_case telemetry-default
  mcp status
  expect_code 0 "$RC" "status against a default server: $ERR"
  assert_not_equals off "$(field "$OUT" telemetry)" "a server without the setting is not reported off"
  assert_contains "$ERR" "T3CODE_TELEMETRY_ENABLED=false" "telemetry not proven off warns with the fix"
  pass "fm-t3-mcp status: reports telemetry off only when the server process proves it, and warns otherwise"
}

test_read_limit_matches_t3_cap() {
  local thread
  fresh_case read-limit
  thread=$(new_thread)
  mcp read --thread "$thread" --limit 100
  expect_code 0 "$RC" "a read at T3's cap of 100 succeeds: $ERR"
  : > "$T3_FAKE_LOG"
  mcp read --thread "$thread" --limit 101
  expect_code 2 "$RC" "a read above T3's cap of 100 is invalid use"
  assert_contains "$ERR" "up to 100" "the refusal names the cap"
  [ -z "$(t3_fake_calls t3_thread_read)" ] || fail "an over-cap read must not reach the server"
  pass "fm-t3-mcp read: --limit is capped at T3's own 100"
}

# Run A is still active while a later queued run B was already cancelled; T3
# interrupts A (its latest active run), so only A's end confirms the cancel.
test_interrupt_confirms_only_the_interrupted_run() {
  local call
  fresh_case interrupt-exact
  t3_fake_set 'w.threads = { "thread-a": { threadId: "thread-a", projectId: "p", status: "running", activeRunId: "run-a", archived: false, worktreePath: null, pendingRequestCount: 0, items: [],
    runs: [{ runId: "run-b", ordinal: 2, status: "cancelled" }, { runId: "run-a", ordinal: 1, status: "running" }] } }; w.interruptStuck = true'
  mcp interrupt --thread thread-a --timeout-ms 300
  expect_code 0 "$RC" "interrupt: $ERR"
  assert_equals run-a "$(field "$OUT" runId)" "the interrupt reports the run T3 stopped"
  assert_equals unconfirmed "$(field "$OUT" cancel)" "a still-active interrupted run is unconfirmed even though a later run is terminal"
  call=$(t3_fake_calls t3_thread_wait | tail -1)
  assert_equals run-a "$(field "$call" runId)" "the confirming wait names the interrupted run exactly"
  t3_fake_set 'w.interruptStuck = false; w.threads["thread-a"].runs = [{ runId: "run-a", ordinal: 1, status: "running" }]; w.queueAfterInterrupt = "queued next"'
  mcp interrupt --thread thread-a --timeout-ms 2000
  assert_equals confirmed "$(field "$OUT" cancel)" "the interrupted run's end confirms the cancel even after a queued run starts"
  mcp state --thread thread-a
  assert_equals running "$(field "$OUT" status)" "the queued run did start behind the interrupt"
  mcp wait --thread thread-a --run run-a --timeout-ms 100
  assert_equals interrupted "$(field "$OUT" status)" "wait --run reads that exact run"
  assert_equals run-a "$(field "$(t3_fake_calls t3_thread_wait | tail -1)" runId)" "wait --run passes the run id"
  pass "fm-t3-mcp interrupt: confirmation waits on exactly the run T3 interrupted, never a later run"
}

# T3 commits a send before it replies; a reply lost after the request went out
# is uncertain, and only the same client request id is a safe retry.
test_send_lost_reply_is_unconfirmed_and_retry_is_one_delivery() {
  local thread
  fresh_case send-lost-reply
  thread=$(new_thread)
  printf 'deliver once' > "$TMP_ROOT/msg"
  t3_fake_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-lost
  expect_code 7 "$RC" "a lost send reply is an unconfirmed delivery (exit 7)"
  assert_equals delivery_unconfirmed "$(field "$OUT" error.code)" "the lost reply is named as unconfirmed delivery"
  assert_contains "$ERR" "retry only with client request id req-lost" "the refusal names the only safe retry"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-lost
  expect_code 0 "$RC" "the retry with the same id succeeds: $ERR"
  [ -n "$(field "$OUT" messageId)" ] || fail "the accepted send reports T3's message id"
  [ "$(t3_fake_items "$thread" 'deliver once')" = 1 ] || fail "the committed send and its retry must be one delivery"
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "thread_busy", message: "no" } }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-refused
  expect_code 3 "$RC" "T3's own refusal stays a proven typed failure"
  pass "fm-t3-mcp send: a reply lost after commit exits 7, and the same-id retry lands as one delivery"
}

# Away-mode discovery must read every page and treat a fork as an ordinary
# conversation while excluding a delegated subagent.
test_thread_for_root_pages_and_forks() {
  local project
  fresh_case thread-for-root-pages
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  FM_T3_P="$project" t3_fake_set '
const mk = (id, extra) => ({ threadId: id, projectId: process.env.FM_T3_P, status: "running", activeRunId: "r-" + id, archived: false, worktreePath: null, pendingRequestCount: 0, parentThreadId: null, relationshipToParent: null, items: [], runs: [], ...extra });
w.threads = { "root-a": mk("root-a") };
for (let i = 0; i < 99; i++) w.threads["wt-" + i] = mk("wt-" + i, { worktreePath: "/wt/" + i });
w.threads["root-b"] = mk("root-b");'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 6 "$RC" "a second supervisor candidate on page two is ambiguous, not a unique match: $OUT"
  assert_contains "$(field "$OUT" error.threadIds)" "root-b" "the page-two candidate is named"
  [ "$(t3_fake_calls t3_thread_list | wc -l)" -ge 2 ] || fail "discovery must follow nextCursor"
  t3_fake_set 'delete w.threads["root-a"]; w.threads["root-b"].parentThreadId = "root-x"; w.threads["root-b"].relationshipToParent = "fork"'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "a forked root conversation is a supervisor candidate: $ERR"
  assert_equals root-b "$(field "$OUT" threadId)" "the fork resolves"
  t3_fake_set 'w.threads["root-b"].relationshipToParent = "subagent"'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "a delegated subagent is never the supervisor"
  pass "fm-t3-mcp thread-for-root: every page is read, forks count, subagents do not"
}

test_resolve_selection_uses_t3_catalog() {
  local project
  fresh_case resolve-selection
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection = { instanceId: "codex", model: "gpt-5.6-sol", options: [{ id: "reasoningEffort", value: "low" }, { id: "serviceTier", value: "priority" }] }'
  mcp resolve-selection --harness codex --instance codex --model default --effort high --project "$project"
  expect_code 0 "$RC" "resolve-selection: $ERR"
  assert_equals '{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"high"},{"id":"serviceTier","value":"priority"}]}' \
    "$(field "$OUT" selection)" "an effort override replaces only the reasoning option and keeps the service tier"
  mcp resolve-selection --harness claude --instance codex --model gpt-5.6-sol --effort high --project "$project"
  expect_code 4 "$RC" "a claude harness mapped to a codex instance is refused"
  assert_equals driver_mismatch "$(field "$OUT" error.code)" "the refusal names the driver mismatch"
  mcp resolve-selection --harness codex --instance codex --model gpt-5.6-sol --effort max --project "$project"
  expect_code 4 "$RC" "an effort the model's catalog lacks is refused"
  assert_contains "$ERR" "low, medium, high, xhigh" "the refusal lists the catalog's values"
  mcp resolve-selection --harness codex --instance codex --model no-such-model --effort default --project "$project"
  expect_code 4 "$RC" "a model the instance does not list is refused"
  t3_fake_set 'w.providers = [{ providerInstanceId: "codex", driverKind: "codex", constraints: ["Provider instance is disabled."], models: [] }]'
  mcp resolve-selection --harness codex --instance codex --model gpt-5.6-sol --effort default --project "$project"
  expect_code 4 "$RC" "a disabled instance is refused"
  assert_contains "$ERR" "Provider instance is disabled." "the refusal carries T3's constraint"
  pass "fm-t3-mcp resolve-selection: driver, model, and options come from T3's catalog; an effort override keeps other options"
}

test_launch_reads_back_full_configuration() {
  local project sel='{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"high"},{"id":"serviceTier","value":"priority"}]}'
  fresh_case launch-config
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title ok --model-selection "$sel" --worktree "$WT"
  expect_code 0 "$RC" "a launch whose configuration reads back exactly succeeds: $ERR"
  t3_fake_set 'w.bindOptions = [{ id: "reasoningEffort", value: "high" }]'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title dropped --model-selection "$sel" --worktree "$WT"
  expect_code 4 "$RC" "a launch that dropped a requested option is refused"
  assert_contains "$ERR" "option serviceTier=none" "the refusal names the missing option"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the mis-configured thread is archived"
  t3_fake_set 'delete w.bindOptions; w.bindModel = "gpt-6-luna"'
  mcp launch --project "$project" --title model --model-selection "$sel" --worktree "$WT"
  expect_code 4 "$RC" "a launch on another model is refused"
  pass "fm-t3-mcp launch: t3_thread_configuration must read back the instance, model, and every requested option"
}

test_requests_and_respond() {
  fresh_case requests
  t3_fake_set 'w.threads = { "thread-q": { threadId: "thread-q", projectId: "p", status: "running", activeRunId: "run-q", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-q", ordinal: 1, status: "running" }],
    runtimeRequests: [
      { id: "req-question", kind: "user_input", status: "pending", questions: [{ id: "q1", header: "Pick", question: "Which?", options: [{ label: "a", description: "A" }] }] },
      { id: "req-approval", kind: "approval", status: "pending" } ] } }'
  mcp state --thread thread-q
  assert_equals 2 "$(field "$OUT" pendingRequestCount)" "state counts every pending request"
  mcp requests --thread thread-q
  expect_code 0 "$RC" "requests: $ERR"
  assert_equals req-question "$(field "$OUT" questions.0.requestId)" "the question is listed by id"
  assert_equals Which? "$(field "$OUT" questions.0.questions.0.question)" "the question's content is read"
  assert_equals 1 "$(field "$OUT" approvals)" "the approval the question tools cannot see is counted"
  printf '{"q1":"a"}' > "$TMP_ROOT/answers"
  mcp respond --thread thread-q --request req-question --answers-file "$TMP_ROOT/answers"
  expect_code 0 "$RC" "respond: $ERR"
  assert_equals '{"q1":"a"}' "$(field "$(t3_fake_calls t3_pending_request_respond)" answers)" "the answers reach t3_pending_request_respond"
  mcp respond --thread thread-q --request req-approval --answers-file "$TMP_ROOT/answers"
  expect_code 3 "$RC" "a permission approval cannot be answered through the question tools"
  mcp requests --thread thread-q
  assert_equals "" "$(field "$OUT" questions.0.requestId)" "the answered question is no longer pending"
  pass "fm-t3-mcp requests/respond: questions are read and answered by id; approvals are counted, never answered"
}

test_watch_is_event_driven_and_bounded() {
  local start elapsed sig ender
  fresh_case watch
  t3_fake_set 'w.threads = { "thread-w": { threadId: "thread-w", projectId: "p", status: "running", activeRunId: "run-w", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-w", ordinal: 1, status: "running" }] }, "thread-idle": { threadId: "thread-idle", projectId: "p", status: "completed", activeRunId: null, archived: false, worktreePath: null, items: [], runs: [] } }'
  ( sleep 0.5; t3_fake_set 'w.threads["thread-w"].runs[0].status = "completed"; w.threads["thread-w"].activeRunId = null; w.threads["thread-w"].status = "completed"' ) &
  ender=$!
  start=$(date +%s)
  mcp watch --thread thread-w --thread thread-idle --timeout-ms 20000
  elapsed=$(( $(date +%s) - start ))
  wait "$ender"
  expect_code 0 "$RC" "watch: $ERR"
  assert_equals run-ended "$(field "$OUT" event)" "a run reaching a terminal status ends the wait"
  assert_equals run-w "$(field "$OUT" runId)" "the ended run is named"
  [ "$elapsed" -lt 10 ] || fail "the run end must wake the wait promptly, took ${elapsed}s"
  assert_equals run-w "$(field "$(t3_fake_calls t3_thread_wait | tail -1)" runId)" "the wait names the exact active run"
  : > "$T3_FAKE_LOG"
  mcp watch --thread thread-w --thread thread-idle --timeout-ms 20000
  assert_equals none "$(field "$OUT" event)" "with no active run the watch returns none instead of waiting"
  [ -z "$(t3_fake_calls t3_thread_wait)" ] || fail "an idle watch must not call t3_thread_wait"
  t3_fake_set 'w.threads["thread-w"].runtimeRequests = [{ id: "req-1", kind: "user_input", status: "pending", questions: [] }]'
  mcp watch --thread thread-w --timeout-ms 200
  assert_equals blocked "$(field "$OUT" event)" "a pending question is a blocked event"
  sig=$(field "$OUT" signature)
  assert_equals 'q:req-1;a:0' "$sig" "the signature names the question ids and approval count"
  mcp watch --thread thread-w --timeout-ms 200 --escalated "thread-w=$sig"
  assert_equals none "$(field "$OUT" event)" "an already-escalated request does not block again"
  t3_fake_set 'w.threads["thread-w"].runtimeRequests[0].status = "resolved"'
  mcp watch --thread thread-w --timeout-ms 200 --escalated "thread-w=$sig"
  assert_equals thread-w "$(field "$OUT" cleared.0)" "an answered request clears the escalation"
  pass "fm-t3-mcp watch: exact-run waits end on a terminal run, idle threads never wait, and pending requests block once per signature"
}

t3_fake_start "$TMP_ROOT/server"
test_login_writes_private_credential_and_never_prints_token
test_login_origin_defaults
test_login_refuses_other_ceilings
test_status_gate_and_protocol
test_gate_refuses_missing_tools
test_environment_mismatch_refused
test_expiry_and_permissions
test_revoked_credential_refused
test_projects_by_real_path
test_launch_binds_workspace
test_launch_refusals
test_send_state_capture_interrupt_archive
test_thread_for_root
test_typed_failure_and_transport_errors
test_telemetry_reported
test_read_limit_matches_t3_cap
test_interrupt_confirms_only_the_interrupted_run
test_send_lost_reply_is_unconfirmed_and_retry_is_one_delivery
test_thread_for_root_pages_and_forks
test_resolve_selection_uses_t3_catalog
test_launch_reads_back_full_configuration
test_requests_and_respond
test_watch_is_event_driven_and_bounded
