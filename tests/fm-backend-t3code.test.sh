#!/usr/bin/env bash
# tests/fm-backend-t3code.test.sh - fake-T3-server unit tests for the T3 Code
# adapter primitives in bin/backends/t3code.sh and their dispatcher routing.
# The fake is tests/t3-fake-server.mjs, an Orchestrator V2 `/mcp` server on
# 127.0.0.1:0 answering from a per-case world.json and logging every request;
# each case's config/t3code-token is a credential for it, so no test ever
# reads ~/.t3 or reaches a live server.
# shellcheck disable=SC2016  # $1/$2 inside single quotes belong to the bash -c snippet t3_run forwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-t3code-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# Lifecycle cases install their own recording stub before this dependency stub.
fm_fake_exit0 "$FAKEBIN" treehouse
export PATH="$FAKEBIN:$PATH"
t3_fake_start "$TMP_ROOT/server"
WATCH_PID=
cleanup() {
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT
# A claude spawn writes workspace trust into the launching user's own store
# (${CLAUDE_CONFIG_DIR:-$HOME}), so both are pinned to a throwaway home.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

# t3_case <name> [thread-status] -> sets CASE_DIR, CONFIG, LOG, REPO
# The default world has one project rooted at $REPO with a Claude default
# model, one thread `thread-live` in the given V2 status, and a credential.
t3_case() {
  local name=$1 status=${2:-completed}
  CASE_DIR="$TMP_ROOT/$name"
  CONFIG="$CASE_DIR/config"
  REPO="$CASE_DIR/repo"
  mkdir -p "$CONFIG" "$REPO"
  t3_fake_case "$CASE_DIR"
  LOG=$T3_FAKE_LOG
  t3_world "$(t3_thread_json thread-live "$status" false)"
  t3_fake_credential "$CONFIG/t3code-token"
}

t3_thread_json() {  # <id> <status> <archived true|false>
  local id=$1 status=$2 archived=$3 run=null
  case "$status" in
    idle) ;;
    preparing|queued|starting|running|waiting) run='"run-1"' ;;
  esac
  printf '{"threadId":"%s","projectId":"proj-1","status":"%s","activeRunId":%s,"archived":%s,"worktreePath":null,"pendingRequestCount":0,"providerInstanceId":"claudeAgent","runtimeMode":"full-access","parentThreadId":null,"items":[{"type":"user_message","status":"completed","text":"do the thing"},{"type":"assistant_message","status":"completed","text":"done"}],"runs":[{"runId":"run-1","status":"%s","requestedAt":"2026-09-14T00:00:00.000Z","startedAt":"2026-09-14T00:00:00.000Z","completedAt":null}]}' \
    "$id" "$status" "$run" "$archived" "$status"
}

# t3_world <thread-json...>: a fresh world (each thread keyed by its id) that
# keeps the case's accepted credentials.
t3_world() {
  FM_T3_THREADS="[$(IFS=,; printf '%s' "$*")]" FM_T3_REPO="$REPO" t3_fake_set '
w = { tokens: w.tokens || [],
  projects: [{ id: "proj-1", title: "repo", workspaceRoot: process.env.FM_T3_REPO, deletedAt: null,
    defaultModelSelection: { instanceId: "claudeAgent", model: "claude-sonnet-5" } }],
  threads: Object.fromEntries(JSON.parse(process.env.FM_T3_THREADS).map((t) => [t.threadId, t])) };'
}

t3_world_set() {  # <js-mutation over `w`>
  t3_fake_set "$1"
}

# t3_down_config: a config dir whose credential names an unreachable server.
t3_down_config() {
  local dir="$CASE_DIR/config-down"
  t3_fake_credential "$dir/t3code-token" env-fake-1 "" 600 http://127.0.0.1:9
  printf '%s' "$dir"
}

# t3_unknown <status>: leave the busy state unknown for a thread in <status>:
# a failed run reads unknown on its own; any other thread's read fails.
t3_unknown() {
  if [ "$1" = failed ]; then
    t3_world_set 'w.failTools = {}'
  else
    t3_world_set 'w.failTools = { t3_thread_read: { code: "unavailable", message: "read unavailable" } }'
  fi
}

make_treehouse_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '{"tool":"treehouse","args":"%s","cwd":"%s"}\n' "$*" "$PWD" >> "${FM_T3_TREEHOUSE_LOG:?}"
case "${1:-}" in
  get) printf '%s\n' "${FM_T3_TREEHOUSE_WT:?}" ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse"
  printf '%s\n' "$fb"
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-guard.sh"
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

write_spawn_brief() {  # <data-dir> <id>
  cat > "$1/$2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise T3 dispatch.

## Firstmate spec
Verify the T3 lifecycle behavior under test.
EOF
}

t3_log_line_of() {  # <js predicate over r> -> 1-based line number of the first match
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
const i = lines.findIndex((r) => eval(process.argv[2]));
process.stdout.write(String(i + 1));
' "$LOG" "$1"
}


t3_run() {  # <bash snippet run after sourcing fm-backend.sh with t3code loaded> [positional args...]
  local snippet=$1
  shift
  FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$CASE_DIR/state}" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code || exit 1; '"$snippet" "$ROOT" "$@"
}

t3_request() {  # <line-number> <js expression over `r`>
  sed -n "${1}p" "$LOG" | node -e '
const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
const v = eval(process.argv[1]);
process.stdout.write(typeof v === "string" ? v : String(JSON.stringify(v)));
' "$2"
}

# t3_dispatch_types: the mutating T3 tool calls in order (a dropped call ends
# in `!`).
t3_dispatch_types() {
  t3_fake_mutations
}

# t3_excluded <dir> <relative path>: the path is in <dir>'s git info/exclude.
t3_excluded() {
  local excl
  excl=$(git -C "$1" rev-parse --git-path info/exclude)
  case "$excl" in /*) ;; *) excl="$1/$excl" ;; esac
  grep -qxF "$2" "$excl"
}

t3_json_field() {  # <file> <js expression over the parsed document d>
  node -e '
const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const v = eval(process.argv[2]);
process.stdout.write(v === undefined ? "undefined" : typeof v === "string" ? v : JSON.stringify(v));
' "$1" "$2"
}

# The TOML cases need a Python with tomllib (3.11+), chosen the way
# bin/fm-t3code-codex-env.sh chooses it; a case that needs one and finds none
# reports itself skipped instead of passing vacuously.
T3_PYTHON=
for t3_python_candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$t3_python_candidate" >/dev/null 2>&1 && "$t3_python_candidate" -c 'import tomllib' >/dev/null 2>&1; then
    T3_PYTHON=$t3_python_candidate
    break
  fi
done
t3_require_tomllib() {  # <case-name>
  [ -z "$T3_PYTHON" ] || return 0
  printf 'note: %s skipped: no Python 3.11+ (tomllib) interpreter on PATH\n' "$1"
  return 1
}

# Parse the emitted configuration as TOML, as Codex does.
t3_toml_env() {  # <file> <NAME>
  "$T3_PYTHON" - "$1" "$2" <<'PYTHON'
import sys, tomllib
with open(sys.argv[1], "rb") as stream:
    env = tomllib.load(stream)["shell_environment_policy"]["set"]
print(env.get(sys.argv[2], "undefined"), end="")
PYTHON
}

# A token-free guard against changes in Codex's real project config loader and
# shell environment. The subshell confines fm_live_gate's capability skip.
t3_verify_live_codex_env() (  # <worktree> <task-id> <isolated-codex-home>
  fm_live_gate default-on FM_T3_CODEX_CONFIG_LIVE codex "$T3_PYTHON"
  "$T3_PYTHON" - "$1" "$2" "$3" <<'PYTHON'
import json, os, pathlib, selectors, subprocess, sys
worktree, task, home = sys.argv[1:]
home = pathlib.Path(home)
home.mkdir()
(home / "config.toml").write_text(f"[projects.{json.dumps(worktree)}]\ntrust_level = \"trusted\"\n")
version = subprocess.check_output(["codex", "--version"], text=True).strip()
with (home / "stderr.log").open("w") as errors:
    server = subprocess.Popen(["codex", "app-server", "--stdio"], cwd=worktree,
        env=dict(os.environ, CODEX_HOME=str(home)), stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=errors, text=True)
    try:
        def request(number, method, params):
            server.stdin.write(json.dumps(dict(id=number, method=method, params=params)) + "\n")
            server.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                while selector.select(20):
                    response = json.loads(server.stdout.readline())
                    if response.get("id") == number:
                        assert "error" not in response, (version, response)
                        return response["result"]
            raise TimeoutError(f"{version}: {method}")
        request(1, "initialize", {"clientInfo": {"name": "fm-config-test", "version": "1"}})
        result = request(2, "config/read", {"cwd": worktree, "includeLayers": True})
        assert result["config"]["model"] == "gpt-5.6-sol", (version, result)
        assert result["config"]["shell_environment_policy"]["set"]["FM_TASK_ID"] == task, version
        result = request(3, "command/exec", {"cwd": worktree,
            "command": ["/usr/bin/printenv", "FM_TASK_ID"], "timeoutMs": 10000,
            "sandboxPolicy": {"type": "dangerFullAccess"}})
        assert result == {"exitCode": 0, "stdout": task + "\n", "stderr": ""}, (version, result)
        print(f"ok - {version}: project config retained; shell FM_TASK_ID={task}")
    finally:
        server.terminate()
        server.wait(timeout=10)
PYTHON
)


test_missing_credential_names_signin() {
  local out status
  t3_case missing-token
  rm -f "$CONFIG/t3code-token"
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail without a credential"
  assert_contains "$out" "fm-t3-mcp.mjs login --access full-access" "a missing credential must name the captain's sign-in"
  assert_contains "$out" "$CONFIG/t3code-token" "a missing credential must name the token file"
  [ ! -s "$LOG" ] || fail "a missing credential must not reach the server"
  pass "fm_backend_t3code_runtime_check: a missing credential names the sign-in"
}

test_revoked_credential_names_signin() {
  local out status
  t3_case revoked-token
  t3_world_set 'w.revoked = true'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail on 401"
  assert_contains "$out" "rejected the credential (HTTP 401)" "a revoked credential must surface the 401"
  assert_contains "$out" "signs in again" "a revoked credential must name the fresh sign-in"
  pass "fm_backend_t3code_runtime_check: a 401 names the fresh sign-in"
}

test_capability_gate_refuses_control() {
  local out
  t3_case gate running
  t3_run 'fm_backend_t3code_runtime_check' || fail "runtime_check must pass the full V2 tool set"
  assert_grep '"method":"tools/list"' "$LOG" "runtime_check must list the server's tools"
  assert_grep '"tool":"t3_environment_read"' "$LOG" "runtime_check must read the environment identity"
  t3_world_set 'w.tools = ["t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create","t3_environment_read"]'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1) && fail "a server without t3_thread_launch must be refused"
  assert_contains "$out" "lacks t3_thread_launch" "the gate refusal must name the missing tool"
  out=$(t3_run 'fm_backend_t3code_kill thread-live' 2>&1) && fail "teardown must refuse a server the gate refuses"
  t3_world_set 'delete w.tools; w.environmentId = "env-other"'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1) && fail "another environment behind the origin must be refused"
  assert_contains "$out" "not the env-fake-1 this credential was issued by" "the identity refusal must name both environments"
  out=$(t3_run 'fm_backend_t3code_kill thread-live' 2>&1) && fail "teardown must refuse another environment"
  [ -z "$(t3_dispatch_types)" ] || fail "a refused gate must not mutate anything, got '$(t3_dispatch_types)'"
  pass "fm_backend_t3code_runtime_check: the tools/list gate and environment pin refuse control and teardown without a mutation"
}

test_project_ensure_matches_realpath_or_creates() {
  local out id create
  t3_case project-ensure
  mkdir -p "$CASE_DIR/link-parent"
  ln -s "$REPO" "$CASE_DIR/link-parent/repo-link"
  out=$(t3_run 'fm_backend_t3code_project_ensure "$1"' "$CASE_DIR/link-parent/repo-link") || fail "project_ensure failed: $out"
  [ "$out" = proj-1 ] || fail "project_ensure should match the existing project through the symlink, got '$out'"
  [ -z "$(t3_dispatch_types)" ] || fail "a matched project must not call t3_project_create"
  mkdir -p "$CASE_DIR/other"
  id=$(t3_run 'fm_backend_t3code_project_ensure "$1"' "$CASE_DIR/other") || fail "project_ensure create failed"
  case "$id" in mcp:proj-*) ;; *) fail "project_ensure should print T3's id for a new project, got '$id'" ;; esac
  [ "$(t3_dispatch_types)" = t3_project_create ] || fail "an unmatched project must call t3_project_create"
  create=$(t3_log_line_of 'r.tool === "t3_project_create"')
  [ "$(t3_request "$create" 'r.arguments.workspaceRoot')" = "$(cd "$CASE_DIR/other" && pwd -P)" ] || fail "t3_project_create must carry the realpath workspaceRoot"
  [ "$(t3_request "$create" 'r.arguments.title')" = fm-other ] || fail "the project title should be the fm- prefixed directory name, got '$(t3_request "$create" 'r.arguments.title')'"
  pass "fm_backend_t3code_project_ensure: matches by realpath, otherwise creates with the fm- title"
}

test_model_selection_table() {
  local out
  t3_case model-selection
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-fable-5-1 high proj-1')
  [ "$out" = '{"instanceId":"claudeAgent","model":"claude-fable-5-1","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "claude effort should ride options id effort, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection codex gpt-5.6-sol xhigh proj-1')
  [ "$out" = '{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"xhigh"}]}' ] \
    || fail "codex effort should ride options id reasoningEffort, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-sonnet-5 default proj-1')
  [ "$out" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5"}' ] || fail "effort default must omit options, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection claude default max proj-1')
  [ "$out" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5","options":[{"id":"effort","value":"max"}]}' ] \
    || fail "model default should take the project default and still apply effort, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection codex gpt-5.6-sol max proj-1' 2>&1) && fail "codex max must be refused"
  assert_contains "$out" "cannot pass effort 'max' to harness 'codex'" "the codex max refusal must name the harness and value"
  t3_world_set 'w.projects[0].defaultModelSelection = { instanceId: "codex", model: "gpt-5.6-sol", options: [{ id: "reasoningEffort", value: "low" }, { id: "serviceTier", value: "priority" }] }'
  printf 'codex=codex\n' > "$CONFIG/t3code-instances"
  out=$(t3_run 'fm_backend_t3code_model_selection codex default high proj-1')
  [ "$out" = '{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"high"},{"id":"serviceTier","value":"priority"}]}' ] \
    || fail "an effort override must keep the project's other default options, got '$out'"
  printf 'claude=codex\n' > "$CONFIG/t3code-instances"
  out=$(t3_run 'fm_backend_t3code_model_selection claude gpt-5.6-sol high proj-1' 2>&1) && fail "a claude harness mapped onto a codex instance must be refused"
  assert_contains "$out" "runs the codex driver, not claudeAgent" "the refusal names the driver T3's catalog reports"
  rm -f "$CONFIG/t3code-instances"
  t3_world_set 'w.projects[0].defaultModelSelection = { instanceId: "claudeAgent", model: "claude-sonnet-5" }'
  out=$(t3_run 'fm_backend_t3code_model_selection pi x high proj-1' 2>&1) && fail "a non-T3 harness must be refused"
  assert_contains "$out" "only the claude and codex harnesses" "the harness refusal must name the supported set"
  t3_world_set 'w.projects[0].defaultModelSelection = null'
  out=$(t3_run 'fm_backend_t3code_model_selection claude default default proj-1' 2>&1) && fail "model default with no project default must be refused"
  assert_contains "$out" "has no default model; pass --model" "the default-model refusal must name the fix"
  printf 'claude=claude-pool\n' > "$CONFIG/t3code-instances"
  t3_world_set 'w.providers = [{ providerInstanceId: "claude-pool", driverKind: "claudeAgent", constraints: [], models: ["claude-sonnet-5", "claude-fable-5-1"].map((id) => ({ id, options: [{ id: "effort", type: "select", options: ["low", "high", "max"].map((v) => ({ id: v })) }] })) }]'
  t3_world_set 'w.projects[0].defaultModelSelection = { instanceId: "claudeAgent", model: "claude-sonnet-5" }'
  out=$(t3_run 'fm_backend_t3code_model_selection claude default default proj-1' 2>&1) && fail "default model on another instance must refuse"
  assert_contains "$out" "pass --model explicitly" "mismatched default must name the remedy"
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-fable-5-1 default proj-1')
  [ "$out" = '{"instanceId":"claude-pool","model":"claude-fable-5-1"}' ] || fail "config/t3code-instances must override the instance id, got '$out'"
  t3_world_set 'w.projects[0].defaultModelSelection.instanceId = "claude-pool"'
  out=$(t3_run 'fm_backend_t3code_model_selection claude default default proj-1')
  [ "$out" = '{"instanceId":"claude-pool","model":"claude-sonnet-5"}' ] || fail "matching default must use the configured instance, got '$out'"
  pass "fm_backend_t3code_model_selection: T3's catalog decides driver, model, and effort; overrides keep other options; default handling, instances file"
}

test_thread_create_and_turn_start_payloads() {
  local id selection launch send
  t3_case thread-lifecycle
  selection='{"instanceId":"claudeAgent","model":"claude-sonnet-5"}'
  id=$(t3_run 'fm_backend_t3code_thread_create proj-1 fm-task1 fm/task1 "$1" "$2"' "$REPO" "$selection") || fail "thread_create failed"
  case "$id" in mcp:*) ;; *) fail "thread_create must print the thread id T3 assigned, got '$id'" ;; esac
  launch=$(t3_log_line_of 'r.tool === "t3_thread_launch"')
  [ "$(t3_request "$launch" 'r.arguments.projectId')" = proj-1 ] || fail "the launch must target the project"
  [ "$(t3_request "$launch" 'r.arguments.title')" = fm-task1 ] || fail "the launch must carry the title"
  [ "$(t3_request "$launch" 'r.arguments.workspaceStrategy')" = "{\"type\":\"existing_worktree\",\"worktreePath\":\"$REPO\",\"branch\":\"fm/task1\"}" ] \
    || fail "the launch must bind the existing worktree and branch, got '$(t3_request "$launch" 'r.arguments.workspaceStrategy')'"
  [ "$(t3_request "$launch" 'r.arguments.runtimeMode')" = full-access ] || fail "the launch must run full-access"
  [ "$(t3_request "$launch" 'r.arguments.interactionMode')" = default ] || fail "the launch must use the default interaction mode"
  [ "$(t3_request "$launch" 'r.arguments.modelSelection')" = "$selection" ] || fail "the launch must carry the model selection verbatim"
  [ "$(t3_request "$launch" 'r.arguments.message')" = undefined ] || fail "the launch creates an idle thread"
  [ -n "$(t3_request "$launch" 'r.auth')" ] || fail "the launch must carry the credential"
  t3_run 'fm_backend_t3code_turn_start "$1" "$(printf "line one\nline two")" "$2"' "$id" "$selection" || fail "turn_start failed"
  send=$(t3_log_line_of 'r.tool === "t3_thread_send"')
  [ "$(t3_request "$send" 'r.arguments.threadId')" = "$id" ] || fail "turn_start must target the thread"
  [ "$(t3_request "$send" 'r.arguments.message')" = $'line one\nline two' ] || fail "turn_start must carry the text verbatim"
  [ "$(t3_request "$send" 'r.arguments.mode')" = auto ] || fail "turn_start must start or steer (mode auto)"
  case "$(t3_request "$send" 'r.arguments.clientRequestId')" in fm-*) ;; *) fail "turn_start must send an idempotency key" ;; esac
  [ "$(t3_dispatch_types)" = "t3_thread_launch t3_thread_send" ] || fail "unexpected mutations '$(t3_dispatch_types)'"
  id=$(t3_run 'fm_backend_t3code_thread_create proj-1 fm-home "" "" "$1"' "$selection") || fail "thread_create without a worktree failed"
  launch=$(t3_log_line_of 'r.tool === "t3_thread_launch" && r.arguments.title === "fm-home"')
  [ "$(t3_request "$launch" 'r.arguments.workspaceStrategy')" = '{"type":"root"}' ] || fail "an empty worktree must launch at the project root, got '$(t3_request "$launch" 'r.arguments.workspaceStrategy')'"
  pass "fm_backend_t3code_thread_create/turn_start: verified t3_thread_launch and t3_thread_send payloads"
}

test_thread_create_uncertain_and_refused_outcomes() {
  local out rc selection='{"instanceId":"claudeAgent","model":"claude-sonnet-5"}'
  t3_case create-outcomes
  t3_world_set 'w.dropTools = { t3_thread_launch: 1 }'
  out=$(t3_run 'fm_backend_t3code_thread_create proj-1 fm-lost "" "$1" "$2"' "$REPO" "$selection" 2>&1); rc=$?
  expect_code 1 "$rc" "a launch whose reply was lost is uncertain (exit 1)"
  [ "$(t3_dispatch_types)" = 't3_thread_launch!' ] || fail "a lost launch must not be retried without an idempotency key, got '$(t3_dispatch_types)'"
  : > "$LOG"
  t3_world_set 'w.bindWorktree = "/somewhere/else"'
  out=$(t3_run 'fm_backend_t3code_thread_create proj-1 fm-bound "" "$1" "$2"' "$REPO" "$selection" 2>&1); rc=$?
  expect_code 4 "$rc" "a thread T3 bound elsewhere is archived and refused (exit 4)"
  assert_contains "$out" "archived it" "the binding refusal must say the thread was archived"
  [ "$(t3_dispatch_types)" = 't3_thread_launch t3_thread_organize' ] || fail "the mis-bound thread must be archived, got '$(t3_dispatch_types)'"
  pass "fm_backend_t3code_thread_create: a lost reply is uncertain and never retried; a mis-bound thread is archived and refused"
}

test_thread_for_home_zero_one_and_ambiguous() {
  local out status home down
  t3_case thread-for-home
  home="$CASE_DIR/link-parent/home-link"
  mkdir -p "$CASE_DIR/link-parent"
  ln -s "$REPO" "$home"
  FM_T3_REPO="$REPO" t3_world_set '
const base = w.threads["thread-live"];
const mk = (id, extra) => ({ ...base, threadId: id, ...extra });
w.projects.push({ id: "proj-2", title: "fm-elsewhere", workspaceRoot: "/nowhere", deletedAt: null, defaultModelSelection: null });
w.threads = {
  "t-worker": mk("t-worker", { status: "running", activeRunId: "r", worktreePath: process.env.FM_T3_REPO + "/wt" }),
  "t-archived": mk("t-archived", { status: "running", activeRunId: "r", archived: true }),
  "t-ready": mk("t-ready", { status: "completed" }),
  "t-other": mk("t-other", { status: "running", activeRunId: "r", projectId: "proj-2" }),
};'
  out=$(t3_run 'fm_backend_t3code_thread_for_home "$1"' "$home" 2>&1)
  status=$?
  [ "$status" -eq 1 ] && [ -z "$out" ] || fail "no live thread on the home must print nothing and return 1 (worktree threads, archived, finished, and other projects excluded), got status $status '$out'"
  t3_world_set 'w.threads["t-captain"] = { ...w.threads["t-ready"], threadId: "t-captain", status: "running", activeRunId: "r" }'
  out=$(t3_run 'fm_backend_t3code_thread_for_home "$1"' "$home" 2>&1) || fail "one live thread must resolve: $out"
  [ "$out" = t-captain ] || fail "the one live worktree-less thread on the home should resolve through the symlinked path, got '$out'"
  t3_world_set 'w.threads["t-second"] = { ...w.threads["t-captain"], threadId: "t-second", status: "starting" }'
  out=$(t3_run 'fm_backend_t3code_thread_for_home "$1"' "$home" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "two live threads must return 2, got $status"
  assert_contains "$out" "t-captain, t-second" "the ambiguity error must name the thread ids"
  assert_contains "$out" "FM_SUPERVISOR_TARGET" "the ambiguity error must tell the operator how to pin the target"
  down=$(t3_down_config)
  out=$(FM_CONFIG_OVERRIDE="$down" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_thread_for_home "$1"' "$ROOT" "$home" 2>&1)
  status=$?
  [ "$status" -eq 1 ] && [ -z "$out" ] || fail "an unreachable server must be silent and return 1, got status $status '$out'"
  pass "fm_backend_t3code_thread_for_home: zero, one, ambiguous, and unreachable"
}

test_explicit_t3_selection_and_precedence() {
  local out
  t3_case autodetect running
  # Disable host cmux ancestry while retaining all explicit marker precedence.
  detect() {
    t3_run 'FM_HOME="$1"; unset TMUX HERDR_ENV CMUX_WORKSPACE_ID FM_BACKEND; fm_backend_detect_cmux_fallback() { return 1; }; eval "$2"; fm_backend_name' "$REPO" "$1"
  }
  out=$(detect '' 2>"$CASE_DIR/notice")
  [ "$out" = tmux ] || fail "T3 must require explicit selection, got $out"
  [ ! -s "$LOG" ] || fail "implicit backend detection must make no T3 request"
  for setting in 'TMUX=socket' 'HERDR_ENV=1' 'CMUX_WORKSPACE_ID=workspace' 'FM_BACKEND=tmux'; do
    out=$(detect "$setting" 2>/dev/null)
    [ "$out" != t3code ] || fail "$setting must win over T3 discovery"
  done
  printf 'zellij\n' > "$CONFIG/backend"
  [ "$(detect '' 2>/dev/null)" = zellij ] || fail 'explicit config/backend must win'
  rm "$CONFIG/backend"
  rm "$CONFIG/t3code-token"
  : > "$LOG"
  [ "$(detect '')" = tmux ] || fail 'a missing credential must not auto-detect T3'
  [ ! -s "$LOG" ] || fail 'unconfigured T3 discovery must make no request'
  pass 'T3 requires explicit selection and does not query the server during runtime detection'
}

test_capture_renders_activity_and_status() {
  local out read
  t3_case capture running
  out=$(t3_run 'fm_backend_t3code_capture thread-live 40')
  [ "$out" = $'[user_message/completed] do the thing\n[assistant_message/completed] done\nt3code: status=running run=run-1' ] \
    || fail "capture should render [type/status] text then the status line, got '$out'"
  out=$(t3_run 'fm_backend_t3code_capture thread-live 1')
  [ "$out" = 't3code: status=running run=run-1' ] || fail "capture must honour the line bound, got '$out'"
  read=$(t3_log_line_of 'r.tool === "t3_thread_read" && r.arguments.view === "activity"')
  [ -n "$read" ] || fail "capture must read the activity view"
  # T3 pages oldest-first, so a thread longer than one page must still show its newest items.
  t3_fake_set 'w.threads["thread-live"].items = Array.from({ length: 250 }, (_, i) => ({ type: "assistant_message", status: "completed", text: `item ${i}` }));'
  out=$(t3_run 'fm_backend_t3code_capture thread-live 3')
  [ "$out" = $'[assistant_message/completed] item 248\n[assistant_message/completed] item 249\nt3code: status=running run=run-1' ] \
    || fail "capture must show the newest items of a long thread, got '$out'"
  t3_run 'fm_backend_t3code_capture thread-gone 40' >/dev/null 2>&1 && fail "capture of a missing thread must fail"
  pass "fm_backend_t3code_capture: renders the activity tail and the thread's status line"
}

test_send_key_mapping() {
  local out interrupt
  t3_case send-key running
  t3_run 'fm_backend_t3code_send_key thread-live Escape; fm_backend_t3code_send_key thread-live C-c' || fail "Escape and C-c should succeed"
  [ "$(t3_dispatch_types)" = "t3_thread_interrupt t3_thread_interrupt" ] || fail "Escape and C-c must each call t3_thread_interrupt, got '$(t3_dispatch_types)'"
  interrupt=$(t3_log_line_of 'r.tool === "t3_thread_interrupt"')
  [ "$(t3_request "$interrupt" 'r.arguments.threadId')" = thread-live ] || fail "interrupt must name the thread"
  [ "$(t3_log_line_of 'r.tool === "t3_thread_wait"')" -gt "$interrupt" ] || fail "interrupt must be confirmed by T3's run wait"
  t3_run 'fm_backend_t3code_send_key thread-live Enter' || fail "Enter must be a no-op success"
  [ "$(t3_dispatch_types)" = "t3_thread_interrupt t3_thread_interrupt" ] || fail "Enter must call nothing"
  out=$(t3_run 'fm_backend_t3code_send_key thread-live C-u' 2>&1) && fail "C-u must be refused"
  assert_contains "$out" "unsupported T3 key 'C-u'" "the refusal must name the key"
  pass "fm_backend_t3code_send_key: Escape and C-c interrupt, Enter no-ops, others refuse"
}

test_send_text_submit_verdicts() {
  local out
  t3_case send-text
  out=$(t3_run 'fm_backend_t3code_send_text_submit thread-live "hello" 3 0.01 0.01')
  [ "$out" = empty ] || fail "an accepted message must report empty, got '$out'"
  t3_world_set 'w.failTools = { t3_thread_send: { code: "thread_busy", message: "turn already queued" } }'
  out=$(t3_run 'fm_backend_t3code_send_text_submit thread-live "hello" 3 0.01 0.01' 2>/dev/null)
  [ "$out" = send-failed ] || fail "a rejected message must report send-failed, got '$out'"
  pass "fm_backend_t3code_send_text_submit: empty on accept, send-failed on rejection"
}

test_status_table() {
  local status expect got down
  t3_case status-table
  for status in preparing:busy:alive queued:busy:alive starting:busy:alive running:busy:alive waiting:busy:alive \
      idle:idle:alive completed:idle:alive interrupted:idle:alive cancelled:idle:alive rolled_back:idle:alive \
      failed:unknown:dead; do
    t3_world "$(t3_thread_json thread-live "${status%%:*}" false)"
    expect=${status#*:}
    got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
    [ "$got" = "$expect" ] || fail "thread status ${status%%:*} should classify $expect, got $got"
  done
  t3_world "$(t3_thread_json thread-live running false)"
  t3_world_set 'w.threads["thread-live"].runtimeRequests = [{ id: "req-q", kind: "user_input", status: "pending", questions: [] }]'
  [ "$(t3_run 'fm_backend_t3code_probe thread-live')" = blocked ] || fail "a running thread with a pending request must probe blocked"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
  [ "$got" = idle:alive ] || fail "a thread waiting on a pending request is not busy progress, got $got"
  t3_world "$(t3_thread_json thread-live completed true)"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
  [ "$got" = unknown:missing ] || fail "an archived thread should classify unknown:missing, got $got"
  t3_run 'fm_backend_t3code_target_exists thread-live' && fail "an archived thread must not exist"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = unknown ] || fail "an archived thread's composer is unknown"
  t3_world "$(t3_thread_json thread-live running true)"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
  [ "$got" = unknown:unreadable ] || fail "an archived thread whose run still drains is not proven closed and must classify unknown:unreadable, got $got"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = unknown ] || fail "an archived thread whose run still drains has an unknown composer"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-gone'):$(t3_run 'fm_backend_t3code_agent_state thread-gone')"
  [ "$got" = unknown:missing ] || fail "a thread the verified server lacks should classify unknown:missing, got $got"
  down=$(t3_down_config)
  got="$(FM_CONFIG_OVERRIDE="$down" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; printf "%s:%s" "$(fm_backend_t3code_busy_state thread-live)" "$(fm_backend_t3code_agent_state thread-live)"' "$ROOT")"
  [ "$got" = unknown:unreadable ] || fail "an unreachable server should classify unknown:unreadable, got $got"
  t3_world "$(t3_thread_json thread-live completed false)"
  t3_world_set 'w.failTools = { t3_thread_read: { code: "unavailable", message: "read unavailable" } }'
  got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
  [ "$got" = unknown:unreadable ] || fail "a failed thread read should classify unknown:unreadable, got $got"
  t3_world_set 'w.failTools = {}'
  t3_run 'fm_backend_t3code_target_exists thread-live' || fail "a live thread must exist"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = empty ] || fail "a live thread's composer is always empty"
  pass "t3code status table: every V2 thread status, a pending request, archived, archived-but-draining, missing, unreachable, and unreadable rows"
}

test_unreadable_thread_defers_like_busy() {
  local got state harness
  t3_case read-failure completed
  t3_world_set 'w.failTools = { t3_thread_read: { code: "unavailable", message: "read unavailable" } }'
  [ "$(t3_run 'fm_backend_t3code_busy_state thread-live')" = unknown ] || fail "a failed thread read must leave busy state unknown"
  state="$CASE_DIR/state"
  mkdir -p "$state"
  # A previously idle hook record must not override native uncertainty.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" worker --state idle --source claude-hook --event stop >/dev/null
  fm_write_meta "$state/worker.meta" "window=fm-worker" "backend=t3code" "t3_thread_id=thread-live" "harness=claude"
  for harness in claude codex; do
    got=$(t3_run '. "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live "$1" worker "$2"' "$harness" "$state")
    [ "$got" = 'unknown t3code-native' ] || fail "$harness must preserve native uncertainty, got $got"
    got=$(t3_run '. "$0/bin/fm-pending-reply-lib.sh"; fm_pending_reply_backend_observation t3code thread-live fm-worker "$1"' "$harness")
    [ "$got" = unknown ] || fail "$harness reply tracking must preserve native uncertainty, got $got"
  done
  got=$(t3_run '
    . "$0/bin/fm-supervise-daemon.sh"
    FM_SUPERVISOR_TARGET=thread-live FM_SUPERVISOR_BACKEND=t3code FM_DAEMON_PRIMARY_HARNESS=claude
    afk_enter "$1"
    inject_msg "worker needs attention" "$1"; rc=$?
    printf "%s:%s:%s" "$rc" "$INJECT_SUBMIT_ATTEMPTED" "$INJECT_LAST_FAILURE"
  ' "$state")
  case "$got" in 1:0:*) ;; *) fail "an unreadable thread must refuse away-mode injection before submitting, got $got" ;; esac
  got=$(t3_run '. "$0/bin/fm-supervise-daemon.sh"; stale_window_is_busy thread-live "$1"; printf "%s" "$?"' "$state")
  [ "$got" = 3 ] || fail "the stale recheck must preserve uncertainty, got $got"
  [ -z "$(t3_dispatch_types)" ] || fail "an unreadable thread must not be sent a message"
  pass "t3code: a failed thread read reports unknown busy state, submits no away-mode injection, and keeps stale rechecks uncertain"
}

# A digest whose T3 reply was lost may already be delivered. Its generation is
# frozen and retried verbatim under its own request id, even after an outage
# longer than an hour, and an event arriving meanwhile goes out in the next
# digest, so every event lands exactly once.
test_daemon_unconfirmed_digest_is_frozen_and_retried_verbatim() {
  local state got
  t3_case daemon-digest-freeze completed
  state="$CASE_DIR/state"
  mkdir -p "$state"
  t3_world_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  got=$(t3_run '
    . "$0/bin/fm-supervise-daemon.sh"
    FM_SUPERVISOR_TARGET=thread-live FM_SUPERVISOR_BACKEND=t3code FM_DAEMON_PRIMARY_HARNESS=codex
    afk_enter "$1"
    escalate_add "$1" "event-one"
    escalate_add "$1" "event-two"
    escalate_flush "$1"; printf "first=%s\n" "$?"
    find "$1" -type f -exec touch -d "2 hours ago" {} +
    escalate_add "$1" "event-three"
    node -e "
const fs = require(\"fs\"), f = process.argv[1], w = JSON.parse(fs.readFileSync(f, \"utf8\"));
const t = w.threads[\"thread-live\"]; t.status = \"completed\"; t.activeRunId = null;
fs.writeFileSync(f, JSON.stringify(w));
" "$2"
    escalate_flush "$1"; printf "second=%s\n" "$?"
  ' "$state" "$T3_FAKE_WORLD" 2>&1)
  assert_contains "$got" "first=1" "an unconfirmed digest is not reported delivered: $got"
  assert_contains "$got" "second=0" "the frozen digest and the next generation are delivered: $got"
  [ ! -s "$state/.subsuper-escalations" ] || fail "every event was delivered, buffer still holds '$(cat "$state/.subsuper-escalations")'"
  [ ! -e "$state/.subsuper-escalations.frozen" ] || fail "a confirmed frozen generation must be cleared"
  [ "$(t3_fake_calls t3_thread_send | node -e '
const ids = require("fs").readFileSync(0, "utf8").trim().split("\n").map((l) => JSON.parse(l).clientRequestId);
process.stdout.write(ids.length === 3 && ids[0] === ids[1] && ids[1] !== ids[2] ? "ok" : ids.join(","));
')" = ok ] || fail "the frozen digest must be retried with its request id, then the new event sent once, got '$(t3_fake_calls t3_thread_send)'"
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const texts = w.threads["thread-live"].items.filter((i) => i.type === "user_message").map((i) => i.text);
const count = (s) => texts.filter((t) => t.includes(s)).length;
if (count("event-one") !== 1 || count("event-two") !== 1 || count("event-three") !== 1) {
  console.error(JSON.stringify(texts)); process.exit(1);
}
' "$T3_FAKE_WORLD" || fail "each event must reach the supervisor thread exactly once"
  pass "away daemon on T3: an unconfirmed digest is frozen and retried verbatim; a later event goes in the next digest, each event once"
}

test_kill_interrupts_then_archives_and_tolerates_gone() {
  local archive down
  t3_case kill
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of an idle thread should succeed"
  [ "$(t3_dispatch_types)" = t3_thread_organize ] || fail "kill of an idle thread must only archive, got '$(t3_dispatch_types)'"
  archive=$(t3_log_line_of 'r.tool === "t3_thread_organize"')
  [ "$(t3_request "$archive" 'r.arguments.action')" = archive ] || fail "kill must archive, never delete"
  [ "$(t3_log_line_of 'r.tool === "t3_thread_read" && r.arguments.threadId === "thread-live"')" -gt 0 ] || fail "kill must read the close back"
  t3_world "$(t3_thread_json thread-live running false)"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of a running thread should succeed"
  [ "$(t3_dispatch_types)" = "t3_thread_interrupt t3_thread_organize" ] || fail "kill must interrupt a running turn, then archive, got '$(t3_dispatch_types)'"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-gone' || fail "kill of a thread the server lacks is success"
  [ -z "$(t3_dispatch_types)" ] || fail "a missing thread must call nothing"
  t3_world "$(t3_thread_json thread-live completed true)"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of an archived thread is success"
  [ -z "$(t3_dispatch_types)" ] || fail "an archived thread must call nothing"
  t3_world "$(t3_thread_json thread-live running false)"
  t3_world_set 'w.archiveKeepsRun = true; w.waitTimesOut = true'
  t3_run 'fm_backend_t3code_kill thread-live' >/dev/null 2>&1 && fail "an archive that leaves a run active must fail the kill"
  t3_world "$(t3_thread_json thread-live completed false)"
  t3_world_set 'w.failTools = { t3_thread_organize: { code: "boom", message: "archive failed" } }'
  t3_run 'fm_backend_t3code_kill thread-live' 2>/dev/null && fail "a failed archive must fail the kill"
  down=$(t3_down_config)
  FM_CONFIG_OVERRIDE="$down" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_kill thread-live' "$ROOT" 2>/dev/null \
    && fail "an unreachable server must fail the kill"
  pass "fm_backend_t3code_kill: interrupt then archive with a proven close, idempotent on archived and missing, loud on failure"
}

test_dispatcher_routes_and_validates_t3code_meta() {
  local state id out thread=mcp:1b6d0a1e-1e5a-4c2a-9c3b-0123456789ab
  t3_case dispatcher
  t3_world "$(t3_thread_json "$thread" completed false)"
  id=t3taskz1
  state="$CASE_DIR/state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "harness=claude" "kind=scout" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-1"
  out=$(t3_run 'fm_backend_capture t3code "$1" 1' "$thread") || fail "dispatcher capture failed"
  [ "$out" = 't3code: status=completed run=none' ] || fail "dispatcher must route capture to the adapter, got '$out'"
  t3_run 'fm_backend_target_exists t3code "$1"' "$thread" || fail "dispatcher target_exists must route to the adapter"
  [ "$(t3_run 'fm_backend_busy_state t3code "$1"' "$thread")" = idle ] || fail "dispatcher busy_state must route to the adapter"
  [ "$(t3_run 'fm_backend_agent_state t3code "$1"' "$thread")" = alive ] || fail "dispatcher agent_state must route to the adapter"
  [ "$(t3_run 'fm_backend_composer_state t3code "$1" fm-x' "$thread")" = empty ] || fail "dispatcher composer_state must route to the adapter"
  [ "$(t3_run 'fm_backend_send_text_submit t3code "$1" hi 1 0 0 fm-x' "$thread")" = empty ] || fail "dispatcher send_text_submit must route to the adapter"
  out=$(t3_run 'fm_backend_validate_task_endpoint "$1" "$2" && printf "%s %s" "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"' "$state/$id.meta" "$id") \
    || fail "a well-formed t3code record must validate: $out"
  [ "$out" = "t3code $thread" ] || fail "validation must bind the thread id as the target, got '$out'"
  [ "$(t3_run 'fm_backend_resolve_selector "$1" "$2"' "fm-$id" "$state")" = "$thread" ] || fail "fm-<id> must resolve to t3_thread_id"
  [ "$(t3_run 'fm_backend_of_selector "$1" "$1" "$2"' "$thread" "$state")" = t3code ] || fail "a raw thread id selector must inherit backend=t3code"
  fm_write_meta "$state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "backend=t3code"
  out=$(t3_run 'fm_backend_validate_task_endpoint "$1" "$2"' "$state/$id.meta" "$id" 2>&1) && fail "a record without t3_thread_id must refuse"
  assert_contains "$out" "missing t3_thread_id" "the refusal must name the missing field"
  fm_write_meta "$state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "backend=t3code" "t3_thread_id=thread;rm"
  t3_run 'fm_backend_validate_task_endpoint "$1" "$2"' "$state/$id.meta" "$id" 2>/dev/null && fail "a thread id outside the id charset must refuse"
  [ "$(t3_run 'fm_backend_required_tools t3code')" = 'node treehouse' ] || fail "t3code requires node and treehouse"
  t3_run 'fm_backend_has_push t3code' || fail "t3code pushes through its bounded t3_thread_wait event wait"
  [ "$(t3_run 'fm_backend_event_session t3code "$1"' "$thread")" = t3code ] || fail "every T3 thread shares the home's one event session"
  [ "$(t3_run 'fm_backend_transition_target t3code t3code "$1"' "$thread")" = "$thread" ] || fail "a T3 transition names the thread id itself"
  pass "fm-backend dispatcher: routes every t3code primitive, validates and resolves t3_thread_id records, and joins the push wait"
}

test_harness_admission_and_typing_refusals() {
  local op out
  t3_case shared-spawn
  : > "$LOG"
  if out=$(t3_run 'fm_backend_t3code_send_literal thread-live text' 2>&1); then
    fail 'launch-time typing must refuse on T3'
  fi
  [ "$out" = 'error: backend=t3code has no pane to type into' ] || fail "the typing refusal changed: $out"
  [ ! -s "$LOG" ] || fail 'refused typing must not dispatch or read a thread'
  t3_run 'fm_backend_send_key t3code thread-live Enter' || fail 'runtime Enter remains a no-op'
  t3_run 'fm_backend_validate_harness t3code claude; fm_backend_validate_harness t3code codex' || fail 'T3 supported harnesses changed'
  for op in opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin; do
    if out=$(t3_run 'fm_backend_validate_harness t3code "$1"' "$op" 2>&1); then fail "T3 must refuse harness $op"; fi
    assert_contains "$out" "not '$op'" 'harness refusal must name the unsupported adapter'
  done
  pass 'T3 harness admission refuses every non-T3 adapter and launch-time typing refuses without a thread read'
}

test_busy_classify_trusts_native_idle_and_busy() {
  local state id out
  t3_case busy-classify running
  id=t3busyz1
  state="$CASE_DIR/state"; mkdir -p "$state"
  out=$(t3_run '. "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$id" "$state")
  [ "$out" = "busy t3code-native" ] || fail "a running t3code thread with no record must classify busy t3code-native, got '$out'"
  t3_world "$(t3_thread_json thread-live completed false)"
  out=$(t3_run '. "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$id" "$state")
  [ "$out" = "idle t3code-native" ] || fail "a finished t3code thread with no record must classify idle t3code-native, got '$out'"
  t3_world "$(t3_thread_json thread-live failed false)"
  out=$(t3_run '. "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$id" "$state")
  [ "$out" = "unknown t3code-native" ] || fail "a failed run must preserve native uncertainty, got '$out'"
  pass "fm_busy_classify: t3code native busy, idle, and unknown are trusted without a record"
}

test_stale_classifier_resolves_t3_thread() {
  local state out declaration
  t3_case stale-task-mapping
  state="$CASE_DIR/state"; mkdir -p "$state"
  fm_write_meta "$state/worker.meta" "window=fm-worker" "backend=t3code" "t3_thread_id=thread-live"
  for declaration in 'paused: waiting for upstream release' 'captain-held: awaiting captain review'; do
    printf '%s\n' "$declaration" > "$state/worker.status"
    out=$(t3_run '. "$0/bin/fm-supervise-daemon.sh"; classify_stale thread-live "$1"' "$state")
    assert_contains "$out" "pause|" "a T3 thread must resolve its task's declared wait"
    assert_contains "$out" "$declaration" "stale classification must read the task status"
  done
  pass "T3 stale lookup honors paused and captain-held declarations"
}

test_native_restart_rearms_undelivered_stale_warning() {
  local session state home marker first out
  for session in completed failed; do
    t3_case "restart-unknown-$session" "$session"
    t3_unknown "$session"
    home="$CASE_DIR/home"; state="$home/state"
    mkdir -p "$state"
    marker="$state/.subsuper-stale-worker"
    fm_write_meta "$state/worker.meta" "window=fm-worker" "backend=t3code" \
      "t3_thread_id=thread-live" "harness=claude"
    printf 'working: waiting for results\n' > "$state/worker.status"
    (
      export FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$CONFIG"
      export FM_TEST_HARNESS=grok
      export FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5 FM_MAX_DEFER_SECS=0
      "$ROOT/bin/fm-afk-launch.sh" enter --words 'supervise pending work' >/dev/null \
        && "$ROOT/bin/fm-afk-launch.sh" start-native || exit 1
      t3_run '
        . "$0/bin/fm-supervise-daemon.sh"
        _now() { printf 1000; }
        LOG="$1/daemon.log"
        handle_wake "stale: thread-live" "$1"
        printf 1 > "$1/.subsuper-stale-worker"
        housekeeping "$1"
      ' "$state" || exit 1
      [ -s "$state/.subsuper-escalations" ] || exit 1
      # The native daemon has stopped without delivering its buffer.
      "$ROOT/bin/fm-afk-launch.sh" stop || exit 1
      [ -s "$state/.subsuper-escalations" ] || exit 1
      [ -f "$state/.subsuper-reported-stale-worker" ] || exit 1
      # A warning already delivered for another condition must stay suppressed.
      printf 900 > "$state/.subsuper-reported-stale-delivered"
      "$ROOT/bin/fm-afk-launch.sh" enter --words 'supervise pending work' >/dev/null || exit 1
      first=$(cat "$state/.subsuper-escalations")
      # Failed startup must restore both the queue and its suppression markers.
      bash -c '
        . "$0/bin/fm-afk-launch.sh"
        fm_afk_launch_record_write() { return 1; }
        ! fm_afk_launch_main start-native
      ' "$ROOT" || exit 1
      [ "$(cat "$state/.subsuper-escalations")" = "$first" ] || exit 1
      [ -f "$state/.subsuper-reported-stale-worker" ] || exit 1
      "$ROOT/bin/fm-afk-launch.sh" start-native || exit 1
      assert_absent "$state/.subsuper-escalations" "fresh startup must discard the old queue"
      assert_absent "$state/.subsuper-reported-stale-worker" "discarding an undelivered warning must re-arm reporting"
      assert_present "$state/.subsuper-reported-stale-delivered" "startup must preserve suppression of delivered warnings"
      [ "$(cat "$marker")" = 1 ] || fail "restart must preserve the stale condition's age"
      out=$(t3_run 'fm_backend_t3code_busy_state thread-live')
      [ "$out" = unknown ] || fail "the restarted thread must remain unknown"
      t3_run '
        . "$0/bin/fm-supervise-daemon.sh"
        _now() { printf 1000; }
        LOG="$1/daemon.log"
        housekeeping "$1"
        _now() { printf 1100; }
        housekeeping "$1"
        housekeeping "$1"
      ' "$state" || exit 1
      [ "$(wc -l < "$state/.subsuper-escalations" | tr -d "[:space:]")" = 1 ] \
        || fail "persistent uncertainty must queue exactly one replacement warning"
      assert_contains "$(cat "$state/.subsuper-escalations")" \
        'stale persisted 999s (possible wedge): thread-live' "restart must report the retained stale condition"
      # Once that replacement is delivered, uncertainty must not report again.
      t3_run '
        . "$0/bin/fm-supervise-daemon.sh"
        _now() { printf 1200; }
        LOG="$1/daemon.log"
        inject_msg() { printf "%s\n" "$1" >> "$2/delivered.log"; }
        escalate_flush "$1" || exit 1
        housekeeping "$1"
        housekeeping "$1"
      ' "$state" || exit 1
      [ ! -s "$state/.subsuper-escalations" ] || fail "a delivered warning must stay suppressed"
      [ "$(wc -l < "$state/delivered.log" | tr -d "[:space:]")" = 1 ] || exit 1
    ) || fail "$session restart lost or duplicated the stale warning"
  done
  pass "native restart re-arms discarded T3 stale warnings exactly once and preserves delivered suppression"
}

test_housekeeping_preserves_unknown_stale_recheck() {
  local session state marker out first
  for session in completed failed; do
    t3_case "housekeeping-unknown-$session" "$session"
    t3_unknown "$session"
    state="$CASE_DIR/state"; mkdir -p "$state"
    marker="$state/.subsuper-stale-worker"
    fm_write_meta "$state/worker.meta" "window=fm-worker" "backend=t3code" \
      "t3_thread_id=thread-live" "harness=claude"
    printf 'working: waiting for results\n' > "$state/worker.status"
    out=$(t3_run 'fm_backend_t3code_busy_state thread-live')
    [ "$out" = unknown ] || fail "$session fixture must have unknown busy state, got $out"
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      afk_enter "$1"
      handle_wake "stale: thread-live" "$1"
      printf 1 > "$1/.subsuper-stale-worker"
      housekeeping "$1"
    ' "$state" || fail "$session housekeeping failed"
    assert_present "$marker" "$session uncertainty must preserve the pending stale recheck"
    [ "$(cat "$marker")" = 1 ] || fail "$session uncertainty must not reset stale aging"
    assert_contains "$(cat "$state/.subsuper-escalations")" \
      'stale persisted 999s (possible wedge): thread-live' \
      "$session uncertainty must report the overdue possible wedge"
    first=$(cat "$state/.subsuper-escalations")
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
      housekeeping "$1"
    ' "$state" || fail "repeated $session housekeeping failed"
    [ "$(cat "$state/.subsuper-escalations")" = "$first" ] \
      || fail "$session uncertainty must not grow the escalation buffer on repeated passes"
    : > "$state/.subsuper-escalations"
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "post-delivery $session housekeeping failed"
    [ ! -s "$state/.subsuper-escalations" ] \
      || fail "$session uncertainty must not repeat the alert after the buffer is delivered"
    assert_present "$marker" "$session recheck must remain pending after reporting"

    # A transient read failure is uncertainty, not thread removal.
    t3_world_set 'w.failTools = { t3_thread_read: { code: "unavailable", message: "read unavailable" } }'
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
      handle_wake "stale: thread-live" "$1"
    ' "$state" || fail "read-failure $session housekeeping failed"
    t3_unknown "$session"
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "post-read-failure $session housekeeping failed"
    assert_present "$marker" "a transient $session read failure must keep the stale recheck pending"
    assert_present "$state/.subsuper-reported-stale-worker" "a transient $session read failure must keep the report marker"
    [ ! -s "$state/.subsuper-escalations" ] \
      || fail "a transient $session read failure must not report the same wedge again"

    # Only positive resumed-work proof can clear the retained marker.
    t3_world_set 'w.failTools = {}; w.threads["thread-live"].status = "running"; w.threads["thread-live"].activeRunId = "run-1"'
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "resumed $session housekeeping failed"
    assert_absent "$marker" "a confirmed running thread must clear stale tracking"
    # A subsequent unknown condition must report again after resumed work.
    FM_T3_STATUS="$session" t3_world_set 'w.threads["thread-live"].status = process.env.FM_T3_STATUS; w.threads["thread-live"].activeRunId = null'
    t3_unknown "$session"
    printf 1 > "$marker"
    : > "$state/.subsuper-escalations"
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "rearmed $session housekeeping failed"
    assert_contains "$(cat "$state/.subsuper-escalations")" 'possible wedge' \
      "$session uncertainty after resumed work must re-arm reporting"
    t3_world_set 'w.failTools = {}; delete w.threads["thread-live"]'
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "gone $session housekeeping failed"
    assert_absent "$marker" "a gone thread must clear stale tracking"
    assert_absent "$state/.subsuper-reported-stale-worker" "a gone thread must re-arm reporting"
    t3_world "$(t3_thread_json thread-live "$session" true)"
    printf 1 > "$marker"
    : > "$state/.subsuper-escalations"
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "archived $session housekeeping failed"
    assert_absent "$marker" "an archived thread must clear stale tracking"
    [ ! -s "$state/.subsuper-escalations" ] || fail "an archived $session thread must not report a possible wedge"
    t3_world "$(t3_thread_json thread-live "$session" false)"
    t3_unknown "$session"
    printf 1 > "$marker"
    : > "$state/.subsuper-escalations"
    t3_run '
      . "$0/bin/fm-supervise-daemon.sh"
      _now() { printf 1000; }
      LOG="$1/daemon.log"
      FM_STATE_OVERRIDE=$1 FM_ESCALATE_BATCH_SECS=999999 FM_STALE_ESCALATE_SECS=5
      housekeeping "$1"
    ' "$state" || fail "recreated $session housekeeping failed"
    assert_contains "$(cat "$state/.subsuper-escalations")" 'possible wedge' \
      "$session uncertainty after a dead thread must re-arm reporting"
  done
  pass "away housekeeping preserves unknown stale rechecks and reports possible wedges until work resumes"
}

# Drive the real watcher with an unchanged transcript and an expired wedge
# timer. The pipeline fixture binds to a real repository's branch and HEAD,
# so fm-crew-state.sh performs its ordinary run attribution.
# [turn] is `hung` to age the latest turn boundary past the busy-turn bound.
test_t3_stale_watcher() {  # <thread-status> <absorb|surface|dead> [harness] [fresh] [turn]
  local session=$1 expected=$2 harness=${3:-codex} state fb hash out _
  local fresh=${4:-} turn=${5:-} busy_bound=3600 turn_at
  local thread=mcp:6a0e1f2b-3c4d-4a5b-8c6d-0123456789ab key
  # The watcher's per-window marker key turns `:` into `_` (fm-watch.sh window_key).
  key=${thread//:/_}
  t3_case "watch-$session-$harness-$fresh-$turn" "$session"
  t3_world "$(t3_thread_json "$thread" "$session" false)"
  # The spawn record below is aged past the bound, so only T3's own run
  # boundary can keep a running thread under it.
  turn_at=$(node -e 'process.stdout.write(new Date().toISOString())')
  [ "$turn" != hung ] || turn_at=2000-01-01T00:00:00.000Z
  FM_T3_TURN_AT="$turn_at" t3_world_set 'const run = Object.values(w.threads)[0].runs[0]; run.startedAt = process.env.FM_T3_TURN_AT; run.completedAt = Object.values(w.threads)[0].activeRunId ? null : process.env.FM_T3_TURN_AT'

  state="$CASE_DIR/state"; fb="$CASE_DIR/fakebin"; out="$CASE_DIR/watch.out"
  mkdir -p "$state" "$fb" "$CASE_DIR/data"
  fm_git_init_commit "$REPO"
  git -C "$REPO" checkout -qb fm/worker
  fm_write_meta "$state/worker.meta" "window=fm-worker" "backend=t3code" \
    "t3_thread_id=$thread" "worktree=$REPO" "project=$REPO" "harness=$harness" "kind=ship"
  if [ "$fresh" = fresh ]; then
    busy_bound=999999
  else
    touch -t 200001010000 "$state/worker.meta"
  fi
  # No validation run is attributed: the deferral reads the T3 thread alone.
  : > "$CASE_DIR/run.toon"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'axi status'*) cat "$FM_T3_TEST_RUN" ;;
  'daemon status') printf 'daemon running (pid 4242)\n' ;;
esac
SH
  chmod +x "$fb/no-mistakes"
  hash=$(t3_run 'fm_backend_capture t3code "$1" 40' "$thread")
  hash=$(printf '%s' "$hash" | { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi; })
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '%s' "$hash" > "$state/.stale-$key"
  printf '3\n' > "$state/.count-$key"
  printf '1\n' > "$state/.stale-since-$key"
  printf '3\n' > "$state/.wedge-escalations-$key"
  PATH="$fb:$PATH" FM_T3_TEST_RUN="$CASE_DIR/run.toon" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$CASE_DIR/data" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS="$busy_bound" \
    FM_STALE_ESCALATE_SECS=1 FM_WEDGE_DEMAND_INSPECT_COUNT=3 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  for _ in $(seq 1 600); do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    if [ "$fresh" = fresh ] && [ ! -e "$state/.stale-since-$key" ]; then
      fail "an unknown busy verdict erased the errored thread's pending recheck"
    fi
    if [ "$expected" = absorb ] && [ "$(cat "$state/.stale-since-$key" 2>/dev/null)" != 1 ] \
        && [ -s "$state/.stale-since-$key" ]; then break; fi
    sleep 0.1
  done
  if [ "$expected" = absorb ]; then
    kill -0 "$WATCH_PID" 2>/dev/null || fail "a running T3 session woke firstmate: $(cat "$out")"
    [ "$(cat "$state/.stale-since-$key" 2>/dev/null)" != 1 ] || fail "watcher never reset the expired timer"
    # Like the other deferrals, the consult resets the idle timer and leaves
    # the escalation count to the next transcript change.
    assert_absent "$state/.wake-queue" "a running T3 session must not queue a wake"
    kill "$WATCH_PID" 2>/dev/null || true
  elif [ "$expected" = dead ]; then
    # A stopped or failed session is a dead agent: the shared dead-record probe
    # reports it once instead of aging it on the wedge ladder.
    assert_contains "$(cat "$out")" 'agent dead' "a stopped or failed T3 session must be reported as a dead agent"
  else
    assert_contains "$(cat "$out")" 'demand-deep-inspection' "a T3 thread that is not running must still escalate"
  fi
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  pass "T3 stale watcher: harness=$harness status=$session turn=${turn:-fresh} -> $expected"
}

test_control_lib_tables() {
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_supports_key t3code Escape && fm_control_backend_supports_key t3code Enter && fm_control_backend_supports_key t3code C-c && ! fm_control_backend_supports_key t3code C-u && fm_control_backend_state_verified t3code' "$ROOT" \
    || fail "control-lib must accept Enter/Escape/C-c, refuse C-u, and treat t3code as state-verified"
  bash -c '. "$0/bin/fm-control-lib.sh"; ! fm_control_backend_exit_supported t3code && fm_control_backend_exit_supported tmux && fm_control_backend_exit_supported herdr' "$ROOT" \
    || fail "control-lib must refuse exit on t3code, and only on t3code"
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_relaunch_supported tmux && fm_control_backend_relaunch_supported herdr && ! fm_control_backend_relaunch_supported t3code' "$ROOT" \
    || fail "control-lib must keep replacement launches on tmux and herdr and refuse them on t3code"
  pass "fm-control-lib: t3code key set, state-verified, no-exit, and no-replacement membership"
}

# A recorded t3code scout for the control plane: the fake thread in the given
# V2 status, the ordinary meta lines, and a brief so relaunch's own checks are
# the ones that decide.
make_t3_control_task() {  # <case-name> <id> <thread-id> <thread-status>
  t3_case "$1" "$4"
  t3_world "$(t3_thread_json "$3" "$4" false)"
  CTRL_PROJ="$CASE_DIR/project"; CTRL_WT="$CASE_DIR/wt"; CTRL_DATA="$CASE_DIR/data"; CTRL_STATE="$CASE_DIR/state"
  fm_git_worktree "$CTRL_PROJ" "$CTRL_WT" "fm/$2"
  mkdir -p "$CTRL_DATA/$2" "$CTRL_STATE" "$CASE_DIR/home/state"
  write_spawn_brief "$CTRL_DATA" "$2"
  touch "$CTRL_STATE/.last-watcher-beat"
  fm_write_meta "$CTRL_STATE/$2.meta" \
    "window=fm-$2" "endpoint_task_id=$2" "worktree=$CTRL_WT" "project=$CTRL_PROJ" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=t3code" "t3_thread_id=$3" "t3_project_id=proj-1" \
    "decisions_reviewed=1" "decision_keys="
}

run_t3_control() {  # <id> <verb> [args...]
  FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_control_exit_refused_before_any_call() {
  local id out rc thread=mcp:7a1b2c3d-4e5f-4a6b-8c7d-0123456789ab
  id="t3exitz1"
  make_t3_control_task control-exit "$id" "$thread" running
  out=$(run_t3_control "$id" exit); rc=$?
  expect_code 1 "$rc" "exit on a t3code task must refuse"$'\n'"$out"
  assert_contains "$out" "no session stop" "the refusal must name the missing session stop"
  assert_contains "$out" "'interrupt' ends the running turn" "the refusal must name the verb that works"
  [ -z "$(t3_dispatch_types)" ] || fail "a refused exit must send nothing to T3, not even an interrupt, got '$(t3_dispatch_types)'"
  assert_present "$CTRL_STATE/$id.meta" "a refused exit preserves the task record"
  [ "$(t3_run 'fm_backend_busy_state t3code "$1"' "$thread")" = busy ] || fail "the running turn must be untouched"
  out=$(run_t3_control "$id" interrupt); rc=$?
  expect_code 0 "$rc" "interrupt on a t3code task should succeed"$'\n'"$out"
  case "$(t3_dispatch_types)" in t3_thread_interrupt*) ;; *) fail "interrupt must call t3_thread_interrupt, got '$(t3_dispatch_types)'" ;; esac
  assert_contains "$out" "cancel=confirmed" "T3's own confirmation of the run's end must reach the interrupt verdict"
  [ "$(t3_run 'fm_backend_busy_state t3code "$1"' "$thread"):$(t3_run 'fm_backend_agent_state t3code "$1"' "$thread")" = idle:alive ] \
    || fail "an interrupted thread is idle and alive"
  pass "fm-control.sh backend=t3code: exit refuses before any call (V2 has no session stop); interrupt ends the turn natively"
}

test_control_relaunch_refused_before_any_dispatch() {
  local id out rc thread=mcp:8b2c3d4e-5f6a-4b7c-9d8e-123456789abc fb
  id="t3relaunchz1"
  make_t3_control_task control-relaunch "$id" "$thread" running
  out=$(run_t3_control "$id" relaunch --note "why"); rc=$?
  expect_code 1 "$rc" "relaunch on a t3code task must refuse"$'\n'"$out"
  assert_contains "$out" "keeps its conversation" "the refusal must name why no fresh agent can replace it"
  [ -z "$(t3_dispatch_types)" ] || fail "a refused relaunch must send nothing to T3, got '$(t3_dispatch_types)'"
  assert_present "$CTRL_STATE/$id.meta" "a refused relaunch preserves the task record"
  assert_absent "$CTRL_STATE/$id.control-relaunch" "a refused relaunch opens no transaction journal"
  [ "$(t3_run 'fm_backend_agent_state t3code "$1"' "$thread")" = alive ] || fail "the running agent must be untouched"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$CTRL_WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1 ); rc=$?
  expect_code 1 "$rc" "fm-spawn --relaunch on a t3code task must refuse on its own"$'\n'"$out"
  assert_contains "$out" "cannot launch a replacement agent" "the launch owner's refusal must name the missing replacement"
  [ -z "$(t3_dispatch_types)" ] || fail "the launch owner's refusal must send nothing to T3, got '$(t3_dispatch_types)'"
  pass "fm-control.sh relaunch backend=t3code: refused before anything is stopped, by the control plane and by the launch owner"
}

test_spawn_codex_refuses_tracked_codex_config() {
  local proj wt data state id out rc fb
  id="t3codextrk1"
  t3_case spawn-codex-tracked
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$proj/.codex" "$data/$id" "$state" "$CASE_DIR/home/state"
  printf '[shell_environment_policy]\ninherit = "all"\n' > "$proj/.codex/config.toml"
  git -C "$proj" add .codex/config.toml
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm "track codex config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --scout --model gpt-5.6-sol --backend t3code 2>&1 ); rc=$?
  expect_code 1 "$rc" "a codex t3code spawn must refuse a project that tracks .codex/config.toml"$'\n'"$out"
  assert_contains "$out" ".codex/config.toml" "the refusal must name the tracked file"
  assert_contains "$out" "[shell_environment_policy]" "the refusal must name the policy table"
  [ -z "$(t3_dispatch_types)" ] || fail "the refusal must come before any T3 mutation, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "the refusal must come before the slot is leased"
  assert_absent "$state/$id.meta" "a refused spawn records nothing"
  pass "fm-spawn.sh --backend t3code codex: refuses to overwrite a project's tracked .codex/config.toml before any mutation"
}

test_spawn_codex_preserves_tracked_codex_config() {
  local proj wt data state id out rc fb neutral original
  t3_require_tomllib test_spawn_codex_preserves_tracked_codex_config || return 0
  id="t3codextrk2"
  t3_case spawn-codex-tracked-compatible
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$proj/.codex" "$data/$id" "$state" "$CASE_DIR/home/state"
  original="$CASE_DIR/original.toml"
  printf '# Project settings, preserved verbatim\r\nmodel = "gpt-5.6-sol"\r\n[features]\r\n# shell_environment_policy in a comment is harmless\r\nweb_search_request = true' > "$original"
  cp "$original" "$proj/.codex/config.toml"
  git -C "$proj" add .codex/config.toml
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm "track codex config"
  git -C "$proj" push -q origin main
  git -C "$wt" merge --ff-only -q main
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --scout --model gpt-5.6-sol --backend t3code 2>&1 ); rc=$?
  expect_code 0 "$rc" "a codex t3code spawn must accept compatible tracked configuration"$'\n'"$out"
  [ "$(t3_toml_env "$wt/.codex/config.toml" FM_TASK_ID)" = "$id" ] || fail "tracked config must deliver FM_TASK_ID"
  "$T3_PYTHON" - "$original" "$wt/.codex/config.toml" <<'CHECK'
import pathlib, sys, tomllib
original, installed = (pathlib.Path(p).read_bytes() for p in sys.argv[1:])
assert installed.startswith(original), "project bytes must remain an unchanged prefix"
assert tomllib.loads(installed.decode())["model"] == "gpt-5.6-sol"
CHECK
  expect_code 0 $? "merged config must be valid TOML and retain the project settings"
  t3_verify_live_codex_env "$wt" "$id" "$CASE_DIR/codex-home" || fail "installed Codex failed the tracked configuration guard"
  [ -z "$(git -C "$proj" status --porcelain -- .codex/config.toml)" ] || fail "the primary checkout must not inherit the overlay"
  [ "$(git -C "$proj" ls-files -v -- .codex/config.toml)" = "H .codex/config.toml" ] || fail "skip-worktree must stay private to the leased worktree"
  [ -z "$(git -C "$wt" status --porcelain -- .codex/config.toml)" ] || fail "the environment overlay must not appear as a tracked edit"
  printf 'worker change\n' > "$wt/worker.txt"
  git -C "$wt" add -A
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qam "worker change"
  git -C "$wt" show HEAD:.codex/config.toml > "$CASE_DIR/committed.toml"
  cmp -s "$original" "$CASE_DIR/committed.toml" || fail "git add -A and commit -a must not commit the environment overlay"
  printf 'report\n' > "$data/$id/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$state/$id.meta"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 ); rc=$?
  expect_code 0 "$rc" "teardown must restore the tracked config"$'\n'"$out"
  cmp -s "$original" "$wt/.codex/config.toml" || fail "cleanup must restore the exact tracked bytes"
  [ -z "$(git -C "$wt" status --porcelain -- .codex/config.toml)" ] || fail "cleanup must leave the tracked config clean"
  "$ROOT/bin/fm-t3code-codex-env.sh" cleanup "$wt" || fail "repeated cleanup must succeed"
  cmp -s "$original" "$wt/.codex/config.toml" || fail "repeated cleanup changed tracked bytes"
  printf '\n# visible after cleanup\n' >> "$wt/.codex/config.toml"
  [ -n "$(git -C "$wt" status --porcelain -- .codex/config.toml)" ] || fail "cleanup must restore ordinary Git tracking"
  pass "fm-spawn.sh backend=t3code: compatible tracked Codex config launches, stays out of commits, and survives cleanup"
}

test_tracked_codex_overlay_recovery() {
  local proj out rc original unicode_value
  t3_require_tomllib test_tracked_codex_overlay_recovery || return 0
  t3_case codex-overlay-recovery
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  mkdir "$proj/.codex"
  original="$CASE_DIR/original.toml"
  printf 'model = "gpt-5.6-sol"\n' > "$original"
  cp "$original" "$proj/.codex/config.toml"
  git -C "$proj" add .codex/config.toml
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm config
  unicode_value=$'space "quote" \\ path-🧭\nnext line'
  "$ROOT/bin/fm-t3code-codex-env.sh" install "$proj" FM_TASK_ID=recovery "FM_HOME=$unicode_value" || fail "install recovery overlay"
  [ "$(t3_toml_env "$proj/.codex/config.toml" FM_HOME)" = "$unicode_value" ] || fail "TOML encoding must preserve Unicode, quotes, backslashes, and newlines"
  printf '\n# worker edit\n' >> "$proj/.codex/config.toml"
  cp "$proj/.codex/config.toml" "$CASE_DIR/edited.toml"
  out=$("$ROOT/bin/fm-t3code-codex-env.sh" cleanup "$proj" 2>&1); rc=$?
  expect_code 1 "$rc" "cleanup must refuse unexpected configuration edits"
  assert_contains "$out" "configuration changed" "cleanup must explain the conflict"
  cmp -s "$CASE_DIR/edited.toml" "$proj/.codex/config.toml" || fail "refused cleanup must preserve edits"
  # Simulate interruption after restoring the file but before restoring Git flags.
  cp "$original" "$proj/.codex/config.toml"
  "$ROOT/bin/fm-t3code-codex-env.sh" cleanup "$proj" || fail "interrupted restoration must converge"
  [ "$(git -C "$proj" ls-files -v -- .codex/config.toml)" = "H .codex/config.toml" ] || fail "recovered cleanup must clear skip-worktree"
  cmp -s "$original" "$proj/.codex/config.toml" || fail "recovery must preserve original bytes"
  # TOML syntax, rather than textual spelling, determines policy ownership.
  for policy in '["shell_environment_policy"]' 'shell_environment_policy.set.FOO = "bar"' 'shell_environment_policy = { set = { FOO = "bar" } }'; do
    printf '%s\n' "$policy" > "$proj/.codex/config.toml"
    out=$("$ROOT/bin/fm-t3code-codex-env.sh" check "$proj" 2>&1); rc=$?
    expect_code 1 "$rc" "every TOML spelling of a project policy must refuse"
    assert_contains "$out" "[shell_environment_policy]" "policy conflict must name the table"
  done
  pass "tracked Codex overlay: edited files survive refusal, interrupted restoration recovers, quoted and dotted policy keys refuse"
}

test_spawn_claude_refuses_tracked_claude_local_md() {
  local proj wt data state id out rc fb
  id="t3claudetrk1"
  t3_case spawn-claude-tracked
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  printf 'project instructions\n' > "$proj/CLAUDE.local.md"
  git -C "$proj" add CLAUDE.local.md
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm "track local instructions"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --scout --model claude-sonnet-5 --backend t3code 2>&1 ); rc=$?
  expect_code 1 "$rc" "a claude t3code spawn must refuse a project that tracks CLAUDE.local.md"$'\n'"$out"
  assert_contains "$out" "tracks CLAUDE.local.md" "the refusal must name the tracked file"
  [ -z "$(t3_dispatch_types)" ] || fail "the refusal must come before any T3 mutation, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "the refusal must come before the slot is leased"
  assert_absent "$state/$id.meta" "a refused spawn records nothing"
  pass "fm-spawn.sh --backend t3code claude: refuses to overwrite a project's tracked CLAUDE.local.md before any mutation"
}

test_spawn_claude_refuses_worktree_symlink() {
  local proj wt data state id out rc fb target exclude
  id=t3claudelink
  t3_case spawn-claude-symlink
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  target="$CASE_DIR/project-instructions"
  printf 'keep these instructions\n' > "$target"
  ln -s "$target" "$wt/CLAUDE.local.md"
  exclude=$(git -C "$wt" rev-parse --git-path info/exclude)
  printf 'CLAUDE.local.md\n' >> "$exclude"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --scout --model claude-sonnet-5 --backend t3code 2>&1 ); rc=$?
  expect_code 1 "$rc" "a symlinked worktree channel must refuse"
  assert_contains "$out" "CLAUDE.local.md already exists" "refusal must name the channel"
  [ "$(cat "$target")" = 'keep these instructions' ] || fail "symlink target was changed"
  [ -L "$wt/CLAUDE.local.md" ] || fail "symlink must remain after refused spawn"
  pass "Claude channel refuses a symlink in the leased worktree without following it"
}

test_untracked_codex_config_is_preserved() {
  local proj out rc
  t3_case untracked-codex
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  mkdir -p "$proj/.codex"
  printf 'model = "captain-model"\n' > "$proj/.codex/config.toml"
  out=$("$ROOT/bin/fm-t3code-codex-env.sh" check "$proj" 2>&1); rc=$?
  expect_code 1 "$rc" "pre-existing untracked Codex config must refuse"
  assert_contains "$out" "untracked configuration already exists" "refusal must explain ownership"
  "$ROOT/bin/fm-t3code-codex-env.sh" cleanup "$proj" || fail "cleanup must leave a pre-existing config alone"
  [ "$(cat "$proj/.codex/config.toml")" = 'model = "captain-model"' ] || fail "cleanup changed the captain's config"
  printf '# Generated by Firstmate T3 Code\n[shell_environment_policy]\n' > "$proj/.codex/config.toml"
  "$ROOT/bin/fm-t3code-codex-env.sh" check "$proj" || fail "marked config should be accepted"
  "$ROOT/bin/fm-t3code-codex-env.sh" cleanup "$proj" || fail "marked config should be removed"
  [ ! -e "$proj/.codex/config.toml" ] || fail "cleanup left a Firstmate config behind"
  pass "untracked Codex config is preserved unless Firstmate's marker owns it"
}

test_spawn_leases_slot_creates_thread_and_starts_launch_turn() {
  local proj wt data state id out fb thread
  id="t3spawnz1"
  t3_case spawn
  proj="$CASE_DIR/spawn-project"
  wt="$CASE_DIR/spawn-wt"
  data="$CASE_DIR/data"
  state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --model claude-sonnet-5 --effort high --backend t3code 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend t3code should succeed against the fake T3 server"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing the T3 window alias and worktree summary"
  assert_grep "backend=t3code" "$state/$id.meta" "meta missing backend=t3code"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing the stable window alias"
  assert_grep "t3_project_id=proj-1" "$state/$id.meta" "meta missing the matched T3 project id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing the leased worktree"
  thread=$(bash -c '. "$1"; fm_meta_get "$2" t3_thread_id' _ "$ROOT/bin/fm-backend.sh" "$state/$id.meta")
  case "$thread" in mcp:*) ;; *) fail "meta t3_thread_id should be the id T3 assigned, got '$thread'" ;; esac
  [ "$(t3_dispatch_types)" = "t3_thread_launch t3_thread_send" ] || fail "spawn must launch an idle thread, then send the brief, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse" && r.args === "get --lease --lease-holder '"$id"'" && r.cwd === "'"$proj"'"')" -gt 0 ] \
    || fail "spawn must lease the slot with treehouse get --lease --lease-holder <id> from the project"
  local create turn
  create=$(t3_log_line_of 'r.tool === "t3_thread_launch"')
  turn=$(t3_log_line_of 'r.tool === "t3_thread_send"')
  [ "$(t3_request "$create" 'r.arguments.workspaceStrategy.type')" = existing_worktree ] || fail "the launch must bind an existing worktree"
  [ "$(t3_request "$create" 'r.arguments.workspaceStrategy.worktreePath')" = "$wt" ] || fail "the launch must point at the leased worktree"
  [ "$(t3_request "$create" 'r.arguments.workspaceStrategy.branch')" = "fm/$id" ] || fail "the launch must carry the slot's branch"
  [ "$(t3_request "$create" 'r.arguments.title')" = "fm-$id" ] || fail "the launch title should be the window alias"
  [ "$(t3_request "$create" 'r.arguments.runtimeMode')" = full-access ] || fail "the launch must run full-access"
  [ "$(t3_request "$create" 'r.arguments.modelSelection')" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "the launch must carry --model/--effort as the model selection"
  [ "$(t3_request "$turn" 'r.arguments.threadId')" = "$thread" ] || fail "the brief must go to the launched thread"
  assert_contains "$(t3_request "$turn" 'r.arguments.message')" "FIRSTMATE_OP: v1 launch-brief:" "the first message must carry the encoded launch brief"
  assert_contains "$(t3_request "$turn" 'r.arguments.message')" "Verify the T3 lifecycle behavior under test." "the first message must carry the brief body"
  assert_present "$wt/.claude/settings.local.json" "spawn must still arm the Claude busy hooks in the worktree before the launch turn"
  local settings="$wt/.claude/settings.local.json"
  [ "$(t3_json_field "$settings" 'Object.keys(d.hooks).sort().join(" ")')" = "SessionEnd Stop StopFailure UserPromptSubmit" ] \
    || fail "the env merge must keep the busy hooks, got hooks '$(t3_json_field "$settings" 'Object.keys(d.hooks || {})')'"
  [ "$(t3_json_field "$settings" 'd.env.GOTMPDIR')" = "/tmp/fm-$id/gotmp" ] || fail "settings env must carry GOTMPDIR, got '$(t3_json_field "$settings" 'd.env')'"
  [ "$(t3_json_field "$settings" 'd.env.FM_TASK_ID')" = "$id" ] || fail "a ship worker's settings env must carry FM_TASK_ID"
  [ "$(t3_json_field "$settings" 'd.env.FM_TASK_INBOX')" = "$state/$id.inbox" ] || fail "a ship worker's settings env must carry its steering inbox"
  [ "$(t3_json_field "$settings" 'd.env.GIT_CONFIG_VALUE_0')" = "$state/$id.git-hooks" ] || fail "T3 workers must select the installed Git hook"
  [ "$(t3_json_field "$settings" 'd.env.GIT_CONFIG_KEY_0')" = core.hooksPath ] || fail "T3 workers must select core.hooksPath"
  [ "$(t3_json_field "$settings" 'd.env.GIT_CONFIG_COUNT')" = 1 ] || fail "T3 workers must select one Git config override"
  [ "$(t3_json_field "$settings" 'd.env.TRACEPARENT')" = undefined ] || fail "TRACEPARENT must be absent when trace context is off"
  [ "$(t3_json_field "$settings" 'd.env.COMPACT_ADVISER_DISABLE')" = 1 ] || fail "settings env must carry the compact-adviser kill switch every launch carries"
  [ "$(t3_json_field "$settings" 'Object.keys(d.env).sort().join(" ")')" = "COMPACT_ADVISER_DISABLE FM_TASK_ID FM_TASK_INBOX GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GOTMPDIR" ] || fail "a worker env block carries the task inbox and Git hook with the launch environment"
  t3_excluded "$wt" .claude/settings.local.json || fail "the settings file must be git-excluded"
  assert_present "$wt/CLAUDE.local.md" "a claude worker gets the task-worker channel statement as CLAUDE.local.md"
  assert_grep "task worker launched by Firstmate" "$wt/CLAUDE.local.md" "CLAUDE.local.md must carry the channel statement"
  assert_grep "first-party task instructions" "$wt/CLAUDE.local.md" "CLAUDE.local.md must name the brief and inbox as first-party"
  assert_grep "link_pull_request, list_thread_pull_requests, and unlink_pull_request tools were verified" "$wt/CLAUDE.local.md" \
    "on a server older than the verified build CLAUDE.local.md must steer the worker off T3's PR tools"
  assert_grep "done: PR <url> status line" "$wt/CLAUDE.local.md" "CLAUDE.local.md must name Firstmate's PR-recording channel"
  t3_excluded "$wt" CLAUDE.local.md || fail "CLAUDE.local.md must be git-excluded"
  [ "$(t3_log_line_of 'r.tool === "t3_thread_launch"')" -gt "$(t3_log_line_of 'r.tool === "treehouse"')" ] \
    || fail "the thread launch must follow the lease"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code: leases the slot, launches the thread on it, records metadata, sends the launch brief"
}

test_spawn_codex_scout_writes_toml_env_with_traceparent() {
  local proj wt data state id out fb toml tp
  t3_require_tomllib test_spawn_codex_scout_writes_toml_env_with_traceparent || return 0
  id="t3codexz1"
  t3_case spawn-codex
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  # A worker's trace context is this home's frozen session decision
  # (bin/fm-trace-context-lib.sh): the session lock pid plus an `on` record.
  printf '%s\n' "$$" > "$state/.lock"
  printf '%s on\n' "$$" > "$state/.trace-context-effective"
  FM_T3_PROJ="$proj" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --scout --model gpt-5.6-sol --backend t3code 2>&1 )
  expect_code 0 $? "a codex scout on t3code should spawn against the fake T3 server"$'\n'"$out"
  toml="$wt/.codex/config.toml"
  assert_present "$toml" "a codex worker gets .codex/config.toml in its worktree"
  [ "$(t3_toml_env "$toml" GOTMPDIR)" = "/tmp/fm-$id/gotmp" ] || fail "config.toml must set GOTMPDIR, got '$(cat "$toml")'"
  [ "$(t3_toml_env "$toml" FM_TASK_ID)" = "$id" ] || fail "a scout's config.toml must set FM_TASK_ID"
  [ "$(t3_toml_env "$toml" FM_TASK_INBOX)" = "$state/$id.inbox" ] || fail "a scout's config.toml must set FM_TASK_INBOX"
  [ "$(t3_toml_env "$toml" GIT_CONFIG_VALUE_0)" = "$state/$id.git-hooks" ] || fail "a scout's config.toml must select the installed Git hook"
  [ "$(t3_toml_env "$toml" COMPACT_ADVISER_DISABLE)" = 1 ] || fail "config.toml must set the compact-adviser kill switch"
  tp=$(t3_toml_env "$toml" TRACEPARENT)
  case "$tp" in 00-????????????????????????????????-????????????????-??) ;; *) fail "config.toml must set a W3C TRACEPARENT when trace context is on, got '$(cat "$toml")'" ;; esac
  grep -qxF "traceparent=$tp" "$state/$id.meta" || fail "the delivered TRACEPARENT must be the one recorded in the meta, got '$(grep '^traceparent=' "$state/$id.meta")'"
  assert_absent "$wt/.claude/settings.local.json" "a codex worker writes no Claude settings"
  assert_absent "$wt/CLAUDE.local.md" "a codex worker gets no Claude channel statement"
  t3_excluded "$wt" .codex/config.toml || fail "config.toml must be git-excluded"
  [ "$(t3_dispatch_types)" = "t3_thread_launch t3_thread_send" ] || fail "spawn must launch then send the brief, got '$(t3_dispatch_types)'"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code codex: writes .codex/config.toml with GOTMPDIR, FM_TASK_ID, and TRACEPARENT"
}

# A seeded secondmate home on its own git branch, with the charter the launch
# turn must carry (validate_firstmate_home_for_spawn needs the marker,
# AGENTS.md, and bin/). The primary home is $CASE_DIR/home with the case's
# config dir, so the bearer is read from there.
make_t3_secondmate_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Charter\nRun the fleet for the T3 secondmate test.\n' > "$home/data/charter.md"
  git -C "$home" init -q -b sm/home
  git -C "$home" add -A
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm seed
}

# spawn_t3_secondmate <id> <home> <harness> <model> -> spawn output; status in $?
spawn_t3_secondmate() {
  local id=$1 home=$2 harness=$3 model=$4
  mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/home/data"
  touch "$CASE_DIR/home/state/.last-watcher-beat"
  HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_DATA_OVERRIDE="$CASE_DIR/home/data" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$CASE_DIR/home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "$harness" --model "$model" --backend t3code --secondmate 2>&1
}

# A t3code secondmate receives the pane launch facts plus its supervisor,
# steering inbox, and Git hook identity through the per-directory environment.
assert_t3_secondmate_env() {  # <reader "<file>"> <label> <home> <thread> <supervision-model> <id>
  local read=$1 label=$2 home=$3 thread=$4 model=$5 id=$6 name expect
  while IFS='=' read -r name expect; do
    [ "$($read "$name")" = "$expect" ] || fail "$label: $name should be '$expect', got '$($read "$name")'"
  done <<EOF
FM_ROOT_OVERRIDE=
FM_STATE_OVERRIDE=
FM_DATA_OVERRIDE=
FM_PROJECTS_OVERRIDE=
FM_CONFIG_OVERRIDE=
COMPACT_ADVISER_DISABLE=1
FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$CASE_DIR/home
FM_HOME=$home
FM_TRACE_CONTEXT=off
FM_SUPERVISION_MODEL=$model
FM_SUPERVISOR_BACKEND=t3code
FM_SUPERVISOR_TARGET=$thread
FM_TASK_INBOX=$CASE_DIR/home/state/$id.inbox
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=core.hooksPath
GIT_CONFIG_VALUE_0=$CASE_DIR/home/state/$id.git-hooks
EOF
  [ "$($read FM_TASK_ID)" = undefined ] || fail "$label: a secondmate is not a task worker and must not carry FM_TASK_ID"
  [ "$($read TRACEPARENT)" = undefined ] || fail "$label: TRACEPARENT must be absent when trace context is off"
}

test_spawn_secondmate_runs_thread_in_home_with_env() {
  local id home out thread project create turn settings
  id="t3smz1"
  t3_case spawn-secondmate
  home="$CASE_DIR/sm-home"
  make_t3_secondmate_home "$home" "$id"
  out=$(spawn_t3_secondmate "$id" "$home" claude claude-sonnet-5)
  expect_code 0 $? "fm-spawn.sh --backend t3code --secondmate should succeed against the fake T3 server"$'\n'"$out"
  [ "$(t3_dispatch_types)" = "t3_project_create t3_thread_launch t3_thread_send" ] \
    || fail "a secondmate spawn must create the home's project, then launch the thread, then send the charter, got '$(t3_dispatch_types)'"
  create=$(t3_log_line_of 'r.tool === "t3_project_create"')
  [ "$(t3_request "$create" 'r.arguments.title')" = fm-sm-home ] || fail "the home's T3 project must carry the fm- prefixed title, got '$(t3_request "$create" 'r.arguments.title')'"
  [ "$(t3_request "$create" 'r.arguments.workspaceRoot')" = "$(cd "$home" && pwd -P)" ] || fail "the home's T3 project workspaceRoot must be the home"
  project=$(bash -c '. "$1"; fm_meta_get "$2" t3_project_id' _ "$ROOT/bin/fm-backend.sh" "$CASE_DIR/home/state/$id.meta")
  thread=$(bash -c '. "$1"; fm_meta_get "$2" t3_thread_id' _ "$ROOT/bin/fm-backend.sh" "$CASE_DIR/home/state/$id.meta")
  create=$(t3_log_line_of 'r.tool === "t3_thread_launch"')
  [ "$(t3_request "$create" 'r.arguments.projectId')" = "$project" ] || fail "the thread must be launched on the home's project"
  [ "$(t3_request "$create" 'r.arguments.workspaceStrategy')" = '{"type":"root","branch":"sm/home"}' ] || fail "a secondmate thread runs at the home's root on its current branch, got '$(t3_request "$create" 'r.arguments.workspaceStrategy')'"
  [ "$(t3_request "$create" 'r.arguments.title')" = "fm-$id" ] || fail "the launch title should be the window alias"
  [ "$(t3_request "$create" 'r.arguments.modelSelection')" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5"}' ] || fail "the launch must carry the secondmate's model selection"
  turn=$(t3_log_line_of 'r.tool === "t3_thread_send"')
  [ "$(t3_request "$turn" 'r.arguments.threadId')" = "$thread" ] || fail "the charter must go to the launched thread"
  assert_contains "$(t3_request "$turn" 'r.arguments.message')" "FIRSTMATE_OP: v1 launch-brief:" "the first message must carry the encoded brief"
  assert_contains "$(t3_request "$turn" 'r.arguments.message')" "Run the fleet for the T3 secondmate test." "the first message must carry the charter body"
  assert_grep "backend=t3code" "$CASE_DIR/home/state/$id.meta" "meta missing backend=t3code"
  assert_grep "kind=secondmate" "$CASE_DIR/home/state/$id.meta" "meta missing kind=secondmate"
  assert_grep "home=$home" "$CASE_DIR/home/state/$id.meta" "meta missing home="
  assert_absent "$home/CLAUDE.local.md" "a secondmate runs under its own supervisor contract and gets no task-worker statement"
  assert_grep "t3_thread_id=$thread" "$CASE_DIR/home/state/$id.meta" "meta missing the created thread id"
  assert_grep "t3_project_id=$project" "$CASE_DIR/home/state/$id.meta" "meta missing the created project id"
  settings="$home/.claude/settings.local.json"
  assert_present "$settings" "a claude secondmate home gets .claude/settings.local.json"
  [ "$(t3_json_field "$settings" 'd.hooks')" = undefined ] || fail "a secondmate home carries no busy hooks"
  [ "$(t3_json_field "$settings" 'Object.keys(d.env).length')" = 17 ] || fail "the env block should carry GOTMPDIR plus the secondmate environment, got $(t3_json_field "$settings" 'Object.keys(d.env)')"
  [ "$(t3_json_field "$settings" 'd.env.GOTMPDIR')" = "/tmp/fm-$id/gotmp" ] || fail "settings env must carry GOTMPDIR"
  read_settings() { t3_json_field "$settings" "d.env[\"$1\"]"; }
  assert_t3_secondmate_env read_settings "claude secondmate settings env" "$home" "$thread" autoarm "$id"
  t3_excluded "$home" .claude/settings.local.json || fail "the settings file must be git-excluded in the home"
  assert_absent "$home/.codex/config.toml" "a claude secondmate writes no codex config"
  [ -L "$home/config/t3code-token" ] || fail "the secondmate home must link the primary's credential, not copy it"
  cmp -s "$home/config/t3code-token" "$CONFIG/t3code-token" || fail "the home's credential link must resolve to the primary's credential"
  printf 'rotated\n' > "$CONFIG/t3code-token"
  [ "$(cat "$home/config/t3code-token")" = rotated ] || fail "a fresh primary sign-in must reach the secondmate home"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code --secondmate: project on the home, root-strategy thread, charter message, launch prefix as settings env"
}

test_spawn_codex_secondmate_writes_toml_env() {
  local id home out thread toml
  t3_require_tomllib test_spawn_codex_secondmate_writes_toml_env || return 0
  id="t3smz2"
  t3_case spawn-secondmate-codex
  home="$CASE_DIR/sm-home-codex"
  make_t3_secondmate_home "$home" "$id"
  out=$(spawn_t3_secondmate "$id" "$home" codex gpt-5.6-sol)
  expect_code 0 $? "a codex secondmate on t3code should spawn against the fake T3 server"$'\n'"$out"
  [ "$(t3_dispatch_types)" = "t3_project_create t3_thread_launch t3_thread_send" ] || fail "unexpected mutations '$(t3_dispatch_types)'"
  thread=$(bash -c '. "$1"; fm_meta_get "$2" t3_thread_id' _ "$ROOT/bin/fm-backend.sh" "$CASE_DIR/home/state/$id.meta")
  toml="$home/.codex/config.toml"
  assert_present "$toml" "a codex secondmate home gets .codex/config.toml"
  [ "$(t3_toml_env "$toml" GOTMPDIR)" = "/tmp/fm-$id/gotmp" ] || fail "config.toml must set GOTMPDIR, got '$(cat "$toml")'"
  read_toml() { t3_toml_env "$toml" "$1"; }
  assert_t3_secondmate_env read_toml "codex secondmate config.toml" "$home" "$thread" persistent "$id"
  t3_excluded "$home" .codex/config.toml || fail "config.toml must be git-excluded in the home"
  assert_absent "$home/.claude/settings.local.json" "a codex secondmate writes no Claude settings"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code --secondmate codex: launch prefix as .codex/config.toml shell_environment_policy"
}

test_spawn_refuses_t3code_when_token_rejected() {
  local proj data state id out status fb
  id="t3authz1"
  t3_case spawn-bad-token
  t3_world_set 'w.revoked = true'
  proj="$CASE_DIR/project"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$proj" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3code 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend t3code should refuse when the T3 server rejects the credential"
  assert_contains "$out" "signs in again" "the refusal must name the fresh sign-in"
  assert_absent "$state/$id.meta" "a runtime refusal must not record metadata"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "spawn must refuse before leasing a slot"
  [ -z "$(t3_dispatch_types)" ] || fail "spawn must refuse before dispatching anything"
  pass "fm-spawn.sh --backend t3code: refuses before mutation when the credential is rejected"
}

# t3_worker_setup <id> -> sets WORKER_PROJ and WORKER_WT: a project and the
# worktree the fake treehouse leases for it, in the current case.
t3_worker_setup() {
  local id=$1
  WORKER_PROJ="$CASE_DIR/spawn-project"; WORKER_WT="$CASE_DIR/spawn-wt"
  fm_git_worktree "$WORKER_PROJ" "$WORKER_WT" "fm/$id"
  mkdir -p "$CASE_DIR/data/$id" "$CASE_DIR/state" "$CASE_DIR/home/state"
  write_spawn_brief "$CASE_DIR/data" "$id"
  touch "$CASE_DIR/state/.last-watcher-beat"
  FM_T3_PROJ="$WORKER_PROJ" t3_world_set 'w.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
}

# t3_worker_spawn <id> <harness> [spawn-arg ...] -> output; status in $?.
t3_worker_spawn() {
  local id=$1 harness=$2 fb
  shift 2
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$WORKER_WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CASE_DIR/state" FM_DATA_OVERRIDE="$CASE_DIR/data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$WORKER_PROJ" "$harness" --scout --backend t3code "$@" 2>&1
}

test_spawn_refuses_launch_settings_t3_cannot_honor() {  # <config-file> <content> <expected-error>
  local file=$1 content=$2 expect=$3 id out rc
  id="t3cfgz-$file"
  t3_case "spawn-refuse-$file"
  printf '%s\n' "$content" > "$CONFIG/$file"
  t3_worker_setup "$id"
  out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
  expect_code 1 "$rc" "a t3code spawn must refuse config/$file=$content"$'\n'"$out"
  assert_contains "$out" "$expect" "the refusal must name config/$file"
  [ -z "$(t3_dispatch_types)" ] || fail "the refusal must come before any T3 mutation, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "the refusal must come before the slot is leased"
  assert_absent "$CASE_DIR/state/$id.meta" "a refused spawn records nothing"
  pass "fm-spawn.sh --backend t3code: refuses config/$file it cannot honor before any mutation"
}

test_spawn_abort_returns_lease_only_after_archive() {  # <ok|fail>
  local archive=$1 id out rc return_line
  id="t3abortz$archive"
  t3_case "spawn-abort-$archive"
  [ "$archive" = ok ] || t3_world_set 'w.failTools = { t3_thread_organize: { code: "boom", message: "archive failed" } }'
  # A regular file where the Claude hooks go aborts the spawn after the
  # thread exists and before its record is published.
  t3_worker_setup "$id"
  printf 'blocker\n' > "$WORKER_WT/.claude"
  out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
  [ "$rc" -ne 0 ] || fail "the blocked spawn should abort"$'\n'"$out"
  return_line=$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')
  if [ "$archive" = ok ]; then
    [ "$(t3_dispatch_types)" = "t3_thread_launch t3_thread_organize" ] || fail "an abort must archive the idle thread, got '$(t3_dispatch_types)'"
    [ "$return_line" -gt "$(t3_log_line_of 'r.tool === "t3_thread_organize"')" ] || fail "an abort must return the lease after the archive"$'\n'"$out"
    pass "fm-spawn.sh --backend t3code: an abort archives the thread, then returns the lease"
  else
    [ "$return_line" -eq 0 ] || fail "an abort whose archive failed must keep the lease a live thread still points at"
    assert_contains "$out" "stays leased" "the warning must say the lease was kept"
    assert_contains "$out" "treehouse return --force" "the warning must name the manual return"
    pass "fm-spawn.sh --backend t3code: an abort that cannot archive the thread keeps the lease"
  fi
}

test_uncertain_thread_launch_keeps_lease() {
  local id out rc
  id=t3uncertain
  t3_case spawn-uncertain
  t3_world_set 'w.dropTools = { t3_thread_launch: 1 }'
  t3_worker_setup "$id"
  out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
  expect_code 1 "$rc" "a lost launch response must abort spawn"
  [ "$(t3_dispatch_types)" = 't3_thread_launch!' ] || fail "a launch without an idempotency key must not be retried, got '$(t3_dispatch_types)'"
  assert_contains "$out" "did not report an outcome" "an uncertain launch must say so"
  assert_contains "$out" "stays leased until any thread T3 bound to it is found" "an uncertain launch must retain the slot"
  [ "$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')" -eq 0 ] || fail "an uncertain launch returned the lease"
  assert_absent "$CASE_DIR/state/$id.meta" "an uncertain launch must not publish metadata"
  pass "fm-spawn.sh --backend t3code: a launch whose response was lost keeps the lease"
}

test_misbound_thread_launch_returns_lease() {
  local id=t3misbound out rc
  t3_case spawn-misbound
  t3_world_set 'w.bindWorktree = "/somewhere/else"'
  t3_worker_setup "$id"
  out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
  expect_code 1 "$rc" "a thread T3 bound to another worktree must abort spawn"$'\n'"$out"
  [ "$(t3_dispatch_types)" = "t3_thread_launch t3_thread_organize" ] || fail "the mis-bound thread must be archived, got '$(t3_dispatch_types)'"
  assert_not_contains "$out" "did not report an outcome" "an archived mis-bound thread is not an uncertain launch"
  [ "$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')" -gt \
    "$(t3_log_line_of 'r.tool === "t3_thread_organize"')" ] || fail "the lease must return after the archive"$'\n'"$out"
  pass "fm-spawn.sh --backend t3code: a thread T3 bound elsewhere is archived and the lease returned"
}

test_uncertain_launch_message_keeps_task_record() {
  local id=t3uncertainturn out rc thread
  t3_case spawn-uncertain-turn
  t3_world_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  t3_worker_setup "$id"
  out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
  expect_code 1 "$rc" "a launch brief whose reply was lost must still fail the spawn"$'\n'"$out"
  assert_not_contains "$out" "T3 refused the launch turn" "a possibly delivered brief must never be reported as refused"
  assert_contains "$out" "may already have been delivered" "a lost launch reply must say the brief may have landed"
  assert_contains "$out" "resend only the identical brief text, which reuses its request id" "the error must name the only safe resend"
  assert_present "$CASE_DIR/state/$id.meta" "a possibly delivered launch must keep its task record"
  thread=$(bash -c '. "$1"; fm_meta_get "$2" t3_thread_id' _ "$ROOT/bin/fm-backend.sh" "$CASE_DIR/state/$id.meta")
  assert_contains "$out" "T3 thread $thread" "the error must name the thread to inspect"
  [ "$(t3_fake_calls t3_thread_send | grep -c .)" = 1 ] || fail "the launch brief must never be retried automatically"
  [ "$(t3_dispatch_types)" = "t3_thread_launch t3_thread_send" ] || fail "the thread must be neither archived nor relaunched, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')" -eq 0 ] || fail "a possibly running worker must keep its lease"
  [ -d "$CASE_DIR/state/$id.git-hooks" ] || fail "an uncertain accepted launch must keep the Git hook directory its thread uses"$'\n'"$out"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code: a launch brief whose reply is lost is reported unconfirmed and keeps its task record"
}

test_scout_teardown_stops_and_archives_before_slot_return() {
  local proj wt data state id out rc neutral fb thread=mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345
  id="t3teardownz1"
  t3_case teardown running
  t3_world "$(t3_thread_json "$thread" running false)"
  proj="$CASE_DIR/project"; wt="$CASE_DIR/wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=codex" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-1" \
    "decisions_reviewed=1" "decision_keys="
  mkdir -p "$wt/.codex"
  printf '# Generated by Firstmate T3 Code\n[shell_environment_policy]\nset = { FM_TASK_ID = "%s" }\n' "$id" > "$wt/.codex/config.toml"
  printf 'statement\n' > "$wt/CLAUDE.local.md"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  expect_code 0 "$rc" "t3code scout teardown should succeed once the report exists"$'\n'"$out"
  assert_absent "$wt/.codex/config.toml" "teardown must remove the codex env config before the slot is reused"
  assert_absent "$wt/CLAUDE.local.md" "teardown must remove the channel statement before the slot is reused"
  [ "$(t3_dispatch_types)" = "t3_thread_interrupt t3_thread_organize" ] || fail "teardown must interrupt then archive exactly once, got '$(t3_dispatch_types)'"
  local archive_line return_line
  archive_line=$(t3_log_line_of 'r.tool === "t3_thread_organize"')
  return_line=$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')
  [ "$return_line" -gt 0 ] || fail "teardown must return the slot through treehouse"
  [ "$archive_line" -lt "$return_line" ] || fail "the thread must be archived before the slot is returned (archive line $archive_line, return line $return_line)"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=t3code: interrupts and archives the thread with a proven close, then returns the slot"
}

test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete() {
  local home data state config id out rc thread=mcp:4e0f2a6b-9d3c-4b5e-af4f-0123456789cd archive_line harness=${1:-claude} journal='' provider
  t3_require_tomllib test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete || return 0
  id="t3smtdz1-$harness"
  t3_case "teardown-secondmate-$harness" running
  t3_world "$(t3_thread_json "$thread" running false)"
  home="$CASE_DIR/sm-home"; data="$CASE_DIR/data"; state="$CASE_DIR/state"; config="$CONFIG"
  if [ "$harness" = codex ]; then
    fm_git_worktree "$CASE_DIR/home-project" "$home" "fm/$id"
    mkdir "$home/.codex"
    printf 'model = "gpt-5.6-sol"\n' > "$home/.codex/config.toml"
    git -C "$home" add .codex/config.toml
    git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm config
    "$ROOT/bin/fm-t3code-codex-env.sh" install "$home" "FM_HOME=$home" || fail "install secondmate overlay"
    journal=$(git -C "$home" rev-parse --git-path fm-t3code-codex-env.json)
  fi
  mkdir -p "$data" "$state" "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin" "$home/.claude"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '{"env":{"FM_HOME":"%s"}}\n' "$home" > "$home/.claude/settings.local.json"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$home" "project=$home" \
    "harness=$harness" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-sm" "home=$home"
  FM_T3_HOME="$home" t3_world_set 'w.probePath = process.env.FM_T3_HOME'
  # T3 detaches the provider asynchronously after the archive reads back, so a
  # process rooted in the home can outlive the proven archive.
  (cd "$home/state" && exec sleep 300) &
  provider=$!
  if command -v lsof >/dev/null 2>&1; then
    local nolsof="$CASE_DIR/nolsof"
    mkdir -p "$nolsof"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$nolsof/lsof"
    chmod +x "$nolsof/lsof"
    out=$( PATH="$nolsof:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" \
      FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
      "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
    rc=$?
    [ "$rc" -ne 0 ] || fail "teardown must refuse when it cannot prove the home's processes ended"$'\n'"$out"
    assert_contains "$out" "cannot determine leaked processes" "the refusal names the unproven process scan"
    assert_present "$home/AGENTS.md" "an unproven shutdown keeps the secondmate home"
    assert_present "$state/$id.meta" "an unproven shutdown keeps the endpoint record"
    kill -0 "$provider" 2>/dev/null || fail "the refused teardown must not have touched the provider"
  fi
  out=$( FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
  rc=$?
  expect_code 0 "$rc" "t3code secondmate teardown should succeed"$'\n'"$out"
  if command -v lsof >/dev/null 2>&1; then
    kill -0 "$provider" 2>/dev/null && { kill "$provider"; fail "a provider process rooted in the home must be ended before the home is removed"; }
  fi
  wait "$provider" 2>/dev/null || true
  [ "$(t3_dispatch_types)" = "t3_thread_interrupt t3_thread_organize" ] \
    || fail "secondmate teardown must interrupt then archive exactly once and never delete the project, got '$(t3_dispatch_types)'"
  archive_line=$(t3_log_line_of 'r.tool === "t3_thread_organize"')
  [ "$(t3_request "$archive_line" 'r.probe')" = true ] || fail "the thread must be archived while the home still exists"
  assert_absent "$home" "teardown should remove the secondmate home"
  [ -z "$journal" ] || assert_absent "$journal" "secondmate cleanup must retire its tracked Codex overlay before removing the home"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=t3code secondmate: interrupts and archives, then ends the home's lingering provider process before the home is removed; an unprovable scan keeps the home"
}

test_teardown_refuses_when_t3_is_unreachable() {
  local proj wt data state id out rc neutral fb down thread=mcp:3d9e1f5a-8c2b-4a4d-8f3e-fedcba543210
  id="t3teardownz2"
  t3_case teardown-unreachable running
  proj="$CASE_DIR/project"; wt="$CASE_DIR/wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-1" \
    "decisions_reviewed=1" "decision_keys="
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  down=$(t3_down_config)
  out=$( PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$down" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown must refuse when the T3 server cannot be reached"
  assert_contains "$out" "is unreachable" "the early runtime gate must explain the refusal"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "a refused teardown must not return the slot"
  assert_present "$state/$id.meta" "a refused teardown must preserve metadata"
  t3_world_set 'w.tools = ["t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create","t3_environment_read"]'
  out=$( PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 ); rc=$?
  expect_code 1 "$rc" "a server the capability gate refuses must stop teardown before cleanup"
  assert_contains "$out" "lacks t3_thread_launch" "the gate refusal must name the missing tool"
  [ -z "$(t3_dispatch_types)" ] || fail "a gate-refused teardown must not mutate"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "a gate-refused teardown must not return the slot"
  assert_present "$state/$id.meta" "a gate-refused teardown must preserve metadata"
  pass "fm-teardown.sh backend=t3code: an unreachable or gate-refused server keeps the slot a live thread still points at"
}

# t3_item_count <thread-id> <text>: how many items of the fake thread carry <text>.
t3_item_count() {
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String((w.threads[process.argv[2]].items || []).filter((i) => i.text === process.argv[3]).length))' "$T3_FAKE_WORLD" "$1" "$2"
}

# T3 commits a send before replying. A reply lost after the request went out
# must read unconfirmed, through the adapter and through fm-send, and a resend
# must reuse the request id so the message lands once.
test_lost_send_reply_is_unconfirmed_and_resend_is_idempotent() {
  local id out rc sends accepted down thread=mcp:5c6d7e8f-0a1b-4c2d-9e3f-23456789abcd
  t3_case send-lost-reply
  t3_world "$(t3_thread_json "$thread" completed false)"
  t3_world_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  out=$(t3_run 'fm_backend_t3code_send_text_submit "$1" "deliver once" 3 0.01 0.01' "$thread" 2>/dev/null)
  [ "$out" = unconfirmed ] || fail "a reply lost after commit must read unconfirmed, not a proven failure, got '$out'"
  # A retry that fails before its request goes out proves nothing about the
  # committed attempt: it stays unconfirmed and keeps the request id.
  down=$(t3_down_config)
  out=$(FM_CONFIG_OVERRIDE="$down" FM_STATE_OVERRIDE="$CASE_DIR/state" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_send_text_submit "$1" "deliver once" 3 0.01 0.01' "$ROOT" "$thread" 2>/dev/null)
  [ "$out" = unconfirmed ] || fail "a retry against an unreachable server must stay unconfirmed, got '$out'"
  t3_world_set 'w.failTools = { t3_environment_read: { code: "unavailable", message: "starting up" } }'
  out=$(t3_run 'fm_backend_t3code_send_text_submit "$1" "deliver once" 3 0.01 0.01' "$thread" 2>/dev/null)
  [ "$out" = unconfirmed ] || fail "a retry whose gate read fails must stay unconfirmed, got '$out'"
  t3_world_set 'w.failTools = {}'
  out=$(t3_run 'fm_backend_t3code_send_text_submit "$1" "deliver once" 3 0.01 0.01' "$thread" 2>/dev/null)
  [ "$out" = empty ] || fail "the resend must succeed, got '$out'"
  [ "$(t3_item_count "$thread" "deliver once")" = 1 ] || fail "the committed send and its resend must be one delivery"
  [ "$(t3_fake_calls t3_thread_send | node -e 'const ids=new Set(require("fs").readFileSync(0,"utf8").trim().split("\n").map((l)=>JSON.parse(l).clientRequestId)); process.stdout.write(String(ids.size))')" = 1 ] \
    || fail "the resend must reuse the logical delivery's request id"
  sends="$CASE_DIR/state/t3code-sends"
  accepted=$(find "$sends" -name '*.accepted')
  [ "$(printf '%s\n' "$accepted" | grep -c .)" = 1 ] || fail "the accepted delivery's outcome must be retained, got '$accepted'"
  node -e '
const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const id = require("path").basename(process.argv[1], ".accepted");
if (o.clientRequestId !== id || !/^msg:/.test(o.messageId || "") || !o.runId || o.delivery !== "started") process.exit(1);
' "$accepted" || fail "the retained outcome must carry the request id, messageId, runId, and delivery, got '$(cat "$accepted")'"
  out=$(t3_run 'fm_backend_t3code_send_text_submit "$1" "deliver once" 3 0.01 0.01' "$thread" 2>/dev/null)
  [ "$(t3_item_count "$thread" "deliver once")" = 2 ] || fail "after a proven delivery the same text later is a new delivery"
  [ "$(find "$sends" -name '*.accepted' | grep -c .)" = 2 ] || fail "each accepted delivery keeps its own outcome"
  [ -z "$(find "$sends" -type f ! -name '*.accepted')" ] || fail "a proven delivery leaves no in-flight record behind"
  touch -d '2 days ago' "$accepted"
  t3_run 'fm_backend_t3code_send_text_submit "$1" "another" 3 0.01 0.01' "$thread" >/dev/null 2>&1
  [ ! -e "$accepted" ] || fail "an accepted outcome older than a day is pruned"

  id=t3sendlost1
  make_t3_control_task send-lost-fm-send "$id" "$thread" completed
  t3_world_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  out=$(FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-send.sh" "$id" "/compact now" 2>&1); rc=$?
  expect_code 3 "$rc" "fm-send must report a lost T3 reply as delivered-unconfirmed (exit 3), never as not sent"$'\n'"$out"
  assert_contains "$out" "verdict=unconfirmed" "fm-send names the unconfirmed verdict"
  assert_not_contains "$out" "text not sent" "a possibly delivered message must never be reported as not sent"
  out=$(FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-send.sh" "$id" "/compact now" 2>&1); rc=$?
  expect_code 0 "$rc" "the identical resend through fm-send succeeds"$'\n'"$out"
  [ "$(t3_item_count "$thread" "/compact now")" = 1 ] || fail "fm-send's resend after a lost reply must land as one delivery"
  pass "t3code send: a reply lost after commit is unconfirmed through the adapter and fm-send, and the resend lands once"
}

# A marked secondmate request on the typed plane (a slash command) carries a
# fresh correlation on every plain rerun, so a lost reply must never be
# answered with advice to resend the same text.
test_lost_send_reply_to_secondmate_names_armed_correlation() {
  local id=t3smlost1 out rc thread=mcp:1c2d3e4f-6a7b-4c8d-9e0f-89abcdef0123
  make_t3_control_task send-lost-secondmate "$id" "$thread" completed
  fm_write_meta "$CTRL_STATE/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "home=$CASE_DIR/sm-home" "project=$CTRL_PROJ" \
    "harness=claude" "kind=secondmate" "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-1"
  t3_world_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  out=$(FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-send.sh" "$id" "/status" 2>&1); rc=$?
  expect_code 3 "$rc" "a lost reply to a typed secondmate request is delivered-unconfirmed (exit 3)"$'\n'"$out"
  assert_contains "$out" "verdict=unconfirmed" "fm-send names the unconfirmed verdict"
  assert_not_contains "$out" "resend only the identical text" "a marked request must not be told to resend: a rerun mints a new correlation"
  assert_contains "$out" "do not resend" "a marked request is told not to resend"
  assert_contains "$out" "stays armed" "the armed correlation is named"
  pass "t3code send: a lost reply to a secondmate names its armed correlation instead of advising a resend"
}

# t3_watch_cycles <state-dir> <n>: source the real watcher (its guard returns
# before the lock and loop) and run <n> of its event-wait cycles at a one-second
# interval, recording each wake reason in $CASE_DIR/wakes.
t3_watch_cycles() {
  FM_STATE_OVERRIDE="$1" FM_CONFIG_OVERRIDE="$CONFIG" FM_ROOT_OVERRIDE="$ROOT" WAKES="$CASE_DIR/wakes" \
    bash -c '. "$0/bin/fm-watch.sh"; POLL=1; wake() { printf "%s\n" "$1" >> "$WAKES"; }; for _ in $(seq "$1"); do event_wait_or_sleep; done' "$ROOT" "$2"
}

# A pending question surfaces through the watcher's push splice at once, once
# per request, with the way to answer it; a run's end wakes the wait early.
test_push_wait_escalates_pending_question_once() {
  local thread=mcp:6d7e8f9a-1b2c-4d3e-8f4a-3456789abcde state
  t3_case push-pending running
  t3_world "$(t3_thread_json "$thread" running false)"
  FM_T3_T="$thread" t3_world_set 'w.threads[process.env.FM_T3_T].runtimeRequests = [{ id: "req-q1", kind: "user_input", status: "pending", questions: [{ id: "q1", header: "h", question: "Which?", options: [] }] }, { id: "req-perm", kind: "approval", status: "pending" }]'
  state="$CASE_DIR/state"
  mkdir -p "$state"
  fm_write_meta "$state/t3push1.meta" "window=fm-t3push1" "backend=t3code" "t3_thread_id=$thread" "kind=ship" "harness=claude"
  t3_watch_cycles "$state" 2 || fail "the watcher's event wait failed"
  [ "$(wc -l < "$CASE_DIR/wakes")" -eq 1 ] || fail "one pending request set must wake exactly once, got: $(cat "$CASE_DIR/wakes")"
  assert_grep "$thread (t3code: agent blocked - waiting on human" "$CASE_DIR/wakes" "the wake names the T3 worker and the blocked cause"
  assert_grep "T3 question req-q1 pending - read and answer with bin/fm-t3-answer.sh" "$CASE_DIR/wakes" "the wake names the question and how to answer it"
  assert_grep "1 T3 permission approval(s) pending - only T3 Code itself can approve" "$CASE_DIR/wakes" "the wake separates the approval the question tools cannot answer"
  assert_grep "$thread" "$state/.wake-queue" "the escalation is durably queued"
  [ "$(t3_fake_calls t3_thread_wait | tail -1 | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).runId||"")')" = run-1 ] \
    || fail "the event wait must wait on the exact active run"
  # Answering clears the escalation; the next distinct request escalates again.
  FM_T3_T="$thread" t3_world_set 'w.threads[process.env.FM_T3_T].runtimeRequests = []'
  t3_watch_cycles "$state" 1 || fail "the watcher's event wait failed after the answer"
  [ ! -e "$state/.t3code-escalated-mcp_6d7e8f9a-1b2c-4d3e-8f4a-3456789abcde" ] || fail "an answered request must clear its escalation marker"
  [ "$(wc -l < "$CASE_DIR/wakes")" -eq 1 ] || fail "with nothing pending there is no new wake"
  pass "t3code push wait: a pending question wakes the supervisor once with how to answer it, approvals are named apart, and answering clears it"
}

test_answer_script_reads_and_answers_questions() {
  local id=t3answer1 thread=mcp:7e8f9a0b-2c3d-4e4f-9a5b-456789abcdef out rc
  make_t3_control_task answer "$id" "$thread" running
  FM_T3_T="$thread" t3_world_set 'w.threads[process.env.FM_T3_T].runtimeRequests = [{ id: "req-q1", kind: "user_input", status: "pending", questions: [{ id: "q1", header: "h", question: "Ship it?", options: [{ label: "yes", description: "y" }] }] }]'
  run_answer() { FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_CONFIG_OVERRIDE="$CONFIG" "$ROOT/bin/fm-t3-answer.sh" "$@" 2>&1; }
  out=$(run_answer "$id"); rc=$?
  expect_code 0 "$rc" "listing pending questions: $out"
  assert_contains "$out" '"requestId":"req-q1"' "the question id is listed"
  assert_contains "$out" "Ship it?" "the question's content is listed"
  out=$(run_answer "$id" req-q1 '{"q1":"yes"}'); rc=$?
  expect_code 0 "$rc" "answering: $out"
  [ "$(t3_fake_calls t3_pending_request_respond | tail -1)" = "{\"threadId\":\"$thread\",\"requestId\":\"req-q1\",\"answers\":{\"q1\":\"yes\"}}" ] \
    || fail "the answer must reach t3_pending_request_respond, got '$(t3_fake_calls t3_pending_request_respond)'"
  fm_write_meta "$CTRL_STATE/tmuxtask.meta" "window=s:w" "kind=ship"
  out=$(run_answer tmuxtask); rc=$?
  expect_code 1 "$rc" "a non-T3 task has no pending requests to answer"
  pass "fm-t3-answer.sh: lists a T3 worker's pending questions and answers one by request id"
}

# A secondmate whose last T3 run failed still has a readable thread; recovery
# continues it there instead of archiving it and launching a second thread.
test_failed_t3_secondmate_is_resumed_in_place() {
  local thread=mcp:8f9a0b1c-3d4e-4f5a-8b6c-56789abcdef0 state out
  t3_case secondmate-failed failed
  t3_world "$(t3_thread_json "$thread" failed false)"
  state="$CASE_DIR/state"
  mkdir -p "$state"
  fm_write_meta "$state/smfail.meta" "window=fm-smfail" "kind=secondmate" "harness=claude" "backend=t3code" "t3_thread_id=$thread" "home=$CASE_DIR/sm-home"
  out=$(STATE="$state" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$CONFIG" FM_HOME="$CASE_DIR/home" bash -c '
. "$0/bin/fm-secondmate-liveness-lib.sh"
fm_secondmate_liveness_probe "$1" smfail poll
printf "probe=%s resume=%s kill=%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_RESUME" "$FM_SM_LIVE_KILL"
fm_secondmate_liveness_relaunch "$1" smfail && echo relaunched=yes || echo relaunched=no
' "$ROOT" "$state/smfail.meta" 2>&1)
  assert_contains "$out" "probe=relaunchable resume=1 kill=0" "a failed T3 run is resumed in place, never killed: $out"
  assert_contains "$out" "relaunched=yes" "the resume succeeds: $out"
  [ "$(t3_dispatch_types)" = t3_thread_send ] || fail "recovery must only send a resume turn to the existing thread (no archive, no launch), got '$(t3_dispatch_types)'"
  [ "$(t3_request "$(t3_log_line_of 'r.tool === "t3_thread_send"')" 'r.arguments.threadId')" = "$thread" ] || fail "the resume turn goes to the recorded thread"
  assert_grep "t3_thread_id=$thread" "$state/smfail.meta" "the endpoint record is unchanged"
  assert_grep relaunched "$state/.secondmate-relaunch-smfail" "the resume is recorded in the relaunch ledger"
  pass "secondmate liveness backend=t3code: a failed run is resumed on its own thread, never archived and replaced"
}

# A secondmate whose thread was archived while its run still drains is not
# proven closed: recovery leaves it in place instead of launching a second
# supervisor beside the draining one.
test_draining_archived_t3_secondmate_is_not_relaunched() {
  local thread=mcp:0b1c2d3e-5f6a-4b7c-8d9e-789abcdef012 state out
  t3_case secondmate-draining running
  t3_world "$(t3_thread_json "$thread" running true)"
  state="$CASE_DIR/state"
  mkdir -p "$state"
  fm_write_meta "$state/smdrain.meta" "window=fm-smdrain" "kind=secondmate" "harness=claude" "backend=t3code" "t3_thread_id=$thread" "home=$CASE_DIR/sm-home"
  out=$(STATE="$state" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$CONFIG" FM_HOME="$CASE_DIR/home" bash -c '
. "$0/bin/fm-secondmate-liveness-lib.sh"
fm_secondmate_liveness_probe "$1" smdrain poll
printf "probe=%s state=%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE"
' "$ROOT" "$state/smdrain.meta" 2>&1)
  assert_not_contains "$out" "probe=relaunchable" "an archived thread with an active run must not be relaunchable: $out"
  assert_contains "$out" "state=unreadable" "an archived thread with an active run reads unreadable: $out"
  [ -z "$(t3_dispatch_types)" ] || fail "probing a draining thread must dispatch nothing, got '$(t3_dispatch_types)'"
  pass "secondmate liveness backend=t3code: an archived thread whose run still drains is left in place, not replaced"
}

# A pooled secondmate home (a Treehouse slot of the Firstmate root) is
# returned only after the provider process T3 detaches asynchronously has
# ended, so the next holder never shares the slot with it.
test_pooled_t3_secondmate_home_returned_only_after_provider_exits() {
  local id=t3smpool1 thread=mcp:9a0b1c2d-4e5f-4a6b-9c7d-6789abcdef01 root home state data fb out rc provider
  command -v lsof >/dev/null 2>&1 || { printf 'note: %s skipped: lsof is required to prove a process left the home\n' "${FUNCNAME[0]}"; return 0; }
  t3_case teardown-secondmate-pooled running
  t3_world "$(t3_thread_json "$thread" running false)"
  root="$CASE_DIR/fm-root"; home="$CASE_DIR/pool-slot"; state="$CASE_DIR/state"; data="$CASE_DIR/data"
  fm_git_worktree "$root" "$home" "fm/$id"
  mkdir -p "$data" "$state" "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$home" "project=$home" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-sm" "home=$home"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  (cd "$home/state" && exec sleep 300) &
  provider=$!
  cat > "$fb/treehouse" <<TH
#!/usr/bin/env bash
if kill -0 $provider 2>/dev/null; then printf 'provider-alive\n'; else printf 'provider-gone\n'; fi >> '$CASE_DIR/return.log'
exit 0
TH
  chmod +x "$fb/treehouse"
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$CASE_DIR/home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
  rc=$?
  kill "$provider" 2>/dev/null || true
  wait "$provider" 2>/dev/null || true
  expect_code 0 "$rc" "pooled t3code secondmate teardown should succeed"$'\n'"$out"
  [ "$(cat "$CASE_DIR/return.log" 2>/dev/null)" = provider-gone ] \
    || fail "the slot must be returned exactly once, after the provider process ended, got '$(cat "$CASE_DIR/return.log" 2>/dev/null)'"$'\n'"$out"
  pass "fm-teardown.sh backend=t3code pooled secondmate: the slot returns only after the home's provider process ended"
}

# The Claude PR-tool clause is scoped to servers older than the first build
# on which T3's pull-request tools were verified safe in a Claude session.
test_claude_pr_tool_clause_version_boundary() {
  local version
  t3_case pr-tool-boundary
  for version in 0.0.46-nightly.20261010.2935:yes 0.0.46-nightly.20261011.1:yes 0.0.46:yes 0.0.47-nightly.20261001.1:yes \
      0.0.46-nightly.20261010.2934:no 0.0.46-nightly.20261008.2833:no 0.0.45:no 0.0.46-nightly.fake:no; do
    FM_T3_V="${version%%:*}" t3_world_set 'w.serverVersion = process.env.FM_T3_V'
    if t3_run 'fm_backend_t3code_claude_pr_tools_verified'; then
      [ "${version#*:}" = yes ] || fail "T3 ${version%%:*} predates the verified build, so its Claude workers keep the PR-tool clause"
    else
      [ "${version#*:}" = no ] || fail "T3 ${version%%:*} is at or past the verified build, so its Claude workers need no PR-tool clause"
    fi
  done
  t3_world_set 'w.serverVersion = "0.0.46-nightly.20261010.2935"; w.revoked = true'
  t3_run 'fm_backend_t3code_claude_pr_tools_verified' && fail "an unreadable server must keep the safer clause"
  pass "t3code Claude PR-tool clause: dropped only at or past the verified T3 build, kept for older or unreadable servers"
}

# A T3 secondmate whose thread reads missing (archived) re-proves the close
# through the idempotent kill before any replacement thread is launched; when
# that proof fails, the thread and its record stay and nothing is spawned.
test_t3_secondmate_missing_thread_reproves_close_before_replacement() {
  local thread=mcp:0b1c2d3e-5f6a-4b7c-8d9e-789abcdef012 root state out between
  t3_case secondmate-missing completed
  t3_world "$(t3_thread_json "$thread" completed true)"
  root="$CASE_DIR/fake-root"
  mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\nprintf "SPAWN %%s\\n" "$*" >> "%s"\n' "$CASE_DIR/spawns" > "$root/bin/fm-spawn.sh"
  chmod +x "$root/bin/fm-spawn.sh"
  run_relaunch() {  # <state-dir> <js run between probe and relaunch>
    mkdir -p "$1"
    fm_write_meta "$1/smgone.meta" "window=fm-smgone" "kind=secondmate" "harness=claude" "backend=t3code" "t3_thread_id=$thread" "home=$CASE_DIR/sm-home"
    STATE="$1" FM_STATE_OVERRIDE="$1" FM_CONFIG_OVERRIDE="$CONFIG" FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$root" \
      WORLD="$T3_FAKE_WORLD" BETWEEN="$2" bash -c '
. "$0/bin/fm-secondmate-liveness-lib.sh"
fm_secondmate_liveness_probe "$1" smgone poll
printf "probe=%s kill=%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_KILL"
node -e "const fs=require(\"fs\"); let w=JSON.parse(fs.readFileSync(process.env.WORLD,\"utf8\")); eval(process.env.BETWEEN); fs.writeFileSync(process.env.WORLD, JSON.stringify(w))"
fm_secondmate_liveness_relaunch "$1" smgone && echo relaunched=yes || echo "relaunched=no status=$FM_SM_LIVE_STATUS reason=$FM_SM_LIVE_REASON"
' "$ROOT" "$1/smgone.meta" 2>&1
  }
  out=$(run_relaunch "$CASE_DIR/state-ok" '')
  assert_contains "$out" "probe=relaunchable kill=1" "a missing T3 thread must re-prove its close before replacement: $out"
  assert_contains "$out" "relaunched=yes" "a proven archive lets the replacement launch: $out"
  assert_grep "SPAWN smgone --secondmate" "$CASE_DIR/spawns" "the guarded secondmate spawn runs after the proven close"
  : > "$CASE_DIR/spawns"
  out=$(run_relaunch "$CASE_DIR/state-fail" 'w.failTools = { t3_thread_read: { code: "unavailable", message: "read unavailable" } }')
  assert_contains "$out" "relaunched=no status=skipped reason=could not prove the old t3code endpoint $thread closed" "an unproved close must stop recovery: $out"
  [ ! -s "$CASE_DIR/spawns" ] || fail "no replacement may be spawned after an unproved close, got $(cat "$CASE_DIR/spawns")"
  assert_grep "t3_thread_id=$thread" "$CASE_DIR/state-fail/smgone.meta" "the endpoint record is kept"
  assert_grep failed "$CASE_DIR/state-fail/.secondmate-relaunch-smgone" "the refused attempt is recorded in the relaunch ledger"
  pass "secondmate liveness backend=t3code: a missing thread re-proves its archive before replacement, and an unproved close spawns nothing"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit
fi


test_native_restart_rearms_undelivered_stale_warning
test_housekeeping_preserves_unknown_stale_recheck
test_t3_stale_watcher failed dead codex fresh
test_unreadable_thread_defers_like_busy
test_stale_classifier_resolves_t3_thread
test_t3_stale_watcher running absorb
test_t3_stale_watcher running absorb claude
test_t3_stale_watcher waiting absorb
test_t3_stale_watcher starting surface
test_t3_stale_watcher completed surface
test_t3_stale_watcher failed dead
test_t3_stale_watcher running surface codex '' hung
test_missing_credential_names_signin
test_revoked_credential_names_signin
test_capability_gate_refuses_control
test_project_ensure_matches_realpath_or_creates
test_model_selection_table
test_thread_create_and_turn_start_payloads
test_thread_create_uncertain_and_refused_outcomes
test_thread_for_home_zero_one_and_ambiguous
test_explicit_t3_selection_and_precedence
test_capture_renders_activity_and_status
test_send_key_mapping
test_send_text_submit_verdicts
test_lost_send_reply_is_unconfirmed_and_resend_is_idempotent
test_lost_send_reply_to_secondmate_names_armed_correlation
test_status_table
test_push_wait_escalates_pending_question_once
test_answer_script_reads_and_answers_questions
test_failed_t3_secondmate_is_resumed_in_place
test_t3_secondmate_missing_thread_reproves_close_before_replacement
test_daemon_unconfirmed_digest_is_frozen_and_retried_verbatim
test_draining_archived_t3_secondmate_is_not_relaunched
test_kill_interrupts_then_archives_and_tolerates_gone
test_dispatcher_routes_and_validates_t3code_meta
test_harness_admission_and_typing_refusals
test_busy_classify_trusts_native_idle_and_busy
test_control_lib_tables
test_control_exit_refused_before_any_call
test_control_relaunch_refused_before_any_dispatch
test_spawn_leases_slot_creates_thread_and_starts_launch_turn
test_claude_pr_tool_clause_version_boundary
test_spawn_codex_preserves_tracked_codex_config
test_tracked_codex_overlay_recovery
test_spawn_codex_refuses_tracked_codex_config
test_spawn_claude_refuses_tracked_claude_local_md
test_spawn_claude_refuses_worktree_symlink
test_untracked_codex_config_is_preserved
test_spawn_codex_scout_writes_toml_env_with_traceparent
test_spawn_secondmate_runs_thread_in_home_with_env
test_spawn_codex_secondmate_writes_toml_env
test_spawn_refuses_t3code_when_token_rejected
test_scout_teardown_stops_and_archives_before_slot_return
test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete
test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete codex
test_pooled_t3_secondmate_home_returned_only_after_provider_exits
test_teardown_refuses_when_t3_is_unreachable
test_spawn_refuses_launch_settings_t3_cannot_honor claude-permission-mode auto "config/claude-permission-mode=auto"
test_spawn_refuses_launch_settings_t3_cannot_honor launch-env-allowlist HOME "config/launch-env-allowlist"
test_spawn_abort_returns_lease_only_after_archive ok
test_spawn_abort_returns_lease_only_after_archive fail
test_uncertain_thread_launch_keeps_lease
test_misbound_thread_launch_returns_lease
test_uncertain_launch_message_keeps_task_record
