#!/usr/bin/env bash
# tests/fm-backend-t3code.test.sh - fake-T3-server unit tests for the T3 Code
# adapter primitives in bin/backends/t3code.sh and their dispatcher routing.
# The fake is a node http server on 127.0.0.1:0 answering from a per-case
# world.json and logging every request; FM_T3CODE_ORIGIN points the adapter at
# it, so no test ever reads ~/.t3 or reaches a live server.
# shellcheck disable=SC2016  # $1/$2 inside single quotes belong to the bash -c snippet t3_run forwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-t3code-tests)
SERVER_DIR="$TMP_ROOT/server"
mkdir -p "$SERVER_DIR"
cat > "$SERVER_DIR/t3-fake.js" <<'JS'
const http = require("http");
const fs = require("fs");
const path = require("path");
const dir = process.argv[2];
const state = () => fs.readFileSync(path.join(dir, "case"), "utf8").trim();
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => {
    const caseDir = state();
    const world = JSON.parse(fs.readFileSync(path.join(caseDir, "world.json"), "utf8"));
    const url = new URL(req.url, "http://fake");
    const parsed = body ? JSON.parse(body) : null;
    // probe: whether world.probePath existed when this request arrived, so a
    // test can prove a call happened before a directory was removed.
    fs.appendFileSync(path.join(caseDir, "requests.log"), JSON.stringify({
      method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams),
      auth: req.headers.authorization || "", body: parsed,
      probe: world.probePath ? fs.existsSync(world.probePath) : null,
    }) + "\n");
    const send = (status, obj) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    if (url.pathname === "/.well-known/t3/environment") return send(200, world.descriptor);
    if ((req.headers.authorization || "") !== `Bearer ${world.token}`) {
      return send(401, { _tag: "EnvironmentUnauthorizedError", code: "unauthorized", reason: "bearer rejected" });
    }
    if (url.pathname === "/api/orchestration/shell") return send(200, world.shell);
    const thread = url.pathname.match(/^\/api\/orchestration\/threads\/([^/]+)$/);
    if (thread) {
      const hit = (world.threads || {})[thread[1]];
      if (!hit) return send(404, { _tag: "EnvironmentThreadNotFound", code: "thread_not_found", reason: "no such thread" });
      return send(200, { thread: hit });
    }
    if (url.pathname === "/api/orchestration/dispatch") {
      const reply = (world.dispatch || {})[parsed.type] || { status: 200, body: { sequence: 1 } };
      const target = (world.threads || {})[parsed.threadId];
      if (reply.status === 200 && parsed.type === "thread.create" && world.recordCreatedThreads) {
        world.threads = world.threads || {};
        world.threads[parsed.threadId] = { id: parsed.threadId, projectId: parsed.projectId, archivedAt: null, session: null, messages: [] };
        fs.writeFileSync(path.join(caseDir, "world.json"), JSON.stringify(world));
      }
      if (reply.status === 200 && target) {
        if (parsed.type === "thread.session.stop" && target.session) target.session.status = "stopped";
        if (parsed.type === "thread.archive") target.archivedAt = new Date().toISOString();
        fs.writeFileSync(path.join(caseDir, "world.json"), JSON.stringify(world));
      }
      return send(reply.status, reply.body);
    }
    send(404, { reason: "unknown path" });
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(path.join(dir, "port"), String(server.address().port));
});
JS
printf '%s' "$TMP_ROOT" > "$SERVER_DIR/case"
node "$SERVER_DIR/t3-fake.js" "$SERVER_DIR" &
SERVER_PID=$!
WATCH_PID=
cleanup() {
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  kill "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
for _ in $(seq 1 100); do
  [ -s "$SERVER_DIR/port" ] && break
  sleep 0.1
done
[ -s "$SERVER_DIR/port" ] || fail "fake T3 server did not publish its port"
ORIGIN="http://127.0.0.1:$(cat "$SERVER_DIR/port")"
TOKEN=tok-firstmate
# A claude spawn writes workspace trust into the launching user's own store
# (${CLAUDE_CONFIG_DIR:-$HOME}), so both are pinned to a throwaway home.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

# t3_case <name> [session-status-or-empty] -> sets CASE_DIR, CONFIG, LOG, REPO
# The default world has one project rooted at $REPO with a Claude default
# model, one thread `thread-live` in the given session status, and the token.
t3_case() {
  local name=$1 status=${2:-ready}
  CASE_DIR="$TMP_ROOT/$name"
  CONFIG="$CASE_DIR/config"
  LOG="$CASE_DIR/requests.log"
  REPO="$CASE_DIR/repo"
  mkdir -p "$CONFIG" "$REPO"
  : > "$LOG"
  printf '%s\n' "$TOKEN" > "$CONFIG/t3code-token"
  printf '%s' "$CASE_DIR" > "$SERVER_DIR/case"
  t3_world "$(t3_thread_json thread-live "$status" null)"
}

t3_thread_json() {  # <id> <session-status|none> <archivedAt-json>
  local id=$1 status=$2 archived=$3 session
  if [ "$status" = none ]; then session=null; else session="{\"threadId\":\"$id\",\"status\":\"$status\",\"activeTurnId\":null,\"lastError\":null}"; fi
  printf '{"id":"%s","projectId":"proj-1","archivedAt":%s,"latestTurn":{"turnId":"turn-1","state":"completed"},"session":%s,"messages":[{"id":"m1","role":"user","text":"do the thing"},{"id":"m2","role":"assistant","text":"done"}]}' \
    "$id" "$archived" "$session"
}

t3_world() {  # <threads-json-entries...> (each a thread object; keyed by its id)
  local entries='' t
  for t in "$@"; do
    [ -z "$entries" ] || entries="$entries,"
    entries="$entries\"$(printf '%s' "$t" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).id)')\":$t"
  done
  cat > "$CASE_DIR/world.json" <<EOF
{"token":"$TOKEN",
 "descriptor":{"serverVersion":"0.0.41-nightly.20260914.1707","capabilities":{"threadSettlement":true}},
 "shell":{"projects":[{"id":"proj-1","title":"repo","workspaceRoot":"$REPO","deletedAt":null,"defaultModelSelection":{"instanceId":"claudeAgent","model":"claude-sonnet-5"}}],"threads":[]},
 "threads":{$entries},
 "dispatch":{}}
EOF
}

t3_world_set() {  # <js-mutation over `w`>
  node -e '
const fs = require("fs");
const file = process.argv[1];
const w = JSON.parse(fs.readFileSync(file, "utf8"));
eval(process.argv[2]);
fs.writeFileSync(file, JSON.stringify(w));
' "$CASE_DIR/world.json" "$1"
}

# A treehouse stub: `get --lease` prints the prepared worktree, every call is
# logged as a JSON line into the same request log as the fake server so the
# order of T3 calls against treehouse calls is provable.
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
  FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code || exit 1; '"$snippet" "$ROOT" "$@"
}

t3_request() {  # <line-number> <js expression over `r`>
  sed -n "${1}p" "$LOG" | node -e '
const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
const v = eval(process.argv[1]);
process.stdout.write(typeof v === "string" ? v : String(JSON.stringify(v)));
' "$2"
}

t3_dispatch_types() {
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
process.stdout.write(lines.filter((r) => r.path === "/api/orchestration/dispatch").map((r) => r.body.type).join(" "));
' "$LOG"
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

test_missing_token_names_mint_command() {
  local out status
  t3_case missing-token
  rm -f "$CONFIG/t3code-token"
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail without a token"
  assert_contains "$out" "npx t3@0.0.41-nightly.20260914.1707 auth session issue --json --ttl 30d --label firstmate" \
    "a missing token must name the mint command with the live server version"
  assert_contains "$out" "$CONFIG/t3code-token" "a missing token must name the token file"
  pass "fm_backend_t3code_runtime_check: a missing token names the mint command"
}

test_rejected_token_names_mint_command() {
  local out status
  t3_case bad-token
  printf 'stale\n' > "$CONFIG/t3code-token"
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail on 401"
  assert_contains "$out" "401" "a rejected token must surface the 401"
  assert_contains "$out" "npx t3@0.0.41-nightly.20260914.1707 auth session issue --json" \
    "a rejected token must name the mint command"
  pass "fm_backend_t3code_runtime_check: a 401 names the mint command"
}

test_missing_origin_names_runtime_file() {
  local out status
  t3_case no-origin
  out=$(FM_T3CODE_ORIGIN='' HOME="$CASE_DIR" FM_CONFIG_OVERRIDE="$CONFIG" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_runtime_check' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail without an origin"
  assert_contains "$out" "$CASE_DIR/.t3/userdata/server-runtime.json" "the refusal must name the runtime file"
  assert_contains "$out" "FM_T3CODE_ORIGIN" "the refusal must name the override"
  pass "fm_backend_t3code_runtime_check: no origin names the runtime file and the override"
}

test_version_floor_refuses_old_server() {
  local out status
  t3_case old-server
  t3_world_set 'w.descriptor.serverVersion = "0.0.40"'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must refuse a server below 0.0.41"
  assert_contains "$out" "requires a T3 server >= 0.0.41-nightly.20260914.1707; this one reports 0.0.40" "the floor refusal must name both versions"
  t3_world_set 'w.descriptor.serverVersion = "0.0.41-nightly.20260914.1707"; w.descriptor.capabilities = {}'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must refuse a server without threadSettlement"
  assert_contains "$out" "threadSettlement" "the capability refusal must name the capability"
  t3_world_set 'w.descriptor.capabilities = { threadSettlement: true }'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1) || fail "runtime_check must accept the verified nightly: $out"
  assert_contains "$(cat "$LOG")" '"path":"/api/orchestration/shell"' "runtime_check must prove authorization against the shell snapshot"
  local version
  for version in 0.0.41-nightly.20260914.1706 0.0.41-alpha 0.0.41-nightly.20260914 0.0.41-nightly.020260914.1707 garbage 0.0.41.1; do
    t3_world_set "w.descriptor.serverVersion = '$version'"
    if out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1); then
      fail "runtime_check accepted $version below the strict floor"
    fi
    assert_contains "$out" "$version" "version refusal must name the installed version"
  done
  for version in 0.0.41-nightly.20260914.1707 0.0.41-nightly.20260914.1722 0.0.41-nightly.20260914.1707+build 0.0.41 0.0.42-alpha; do
    t3_world_set "w.descriptor.serverVersion = '$version'"
    out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1) || fail "runtime_check refused $version: $out"
  done
  pass "fm_backend_t3code_runtime_check: version floor, capability, and authorization gates"
}

test_project_ensure_matches_realpath_or_creates() {
  local out id
  t3_case project-ensure
  mkdir -p "$CASE_DIR/link-parent"
  ln -s "$REPO" "$CASE_DIR/link-parent/repo-link"
  out=$(t3_run 'fm_backend_t3code_project_ensure "$1"' "$CASE_DIR/link-parent/repo-link") || fail "project_ensure failed: $out"
  [ "$out" = proj-1 ] || fail "project_ensure should match the existing project through the symlink, got '$out'"
  [ -z "$(t3_dispatch_types)" ] || fail "a matched project must not dispatch project.create"
  mkdir -p "$CASE_DIR/other"
  id=$(t3_run 'fm_backend_t3code_project_ensure "$1"' "$CASE_DIR/other") || fail "project_ensure create failed"
  case "$id" in ????????-????-????-????-????????????) ;; *) fail "project_ensure should print a uuid for a new project, got '$id'" ;; esac
  [ "$(t3_dispatch_types)" = project.create ] || fail "an unmatched project must dispatch project.create"
  [ "$(t3_request 3 'r.body.projectId')" = "$id" ] || fail "project.create must carry the printed project id"
  [ "$(t3_request 3 'r.body.workspaceRoot')" = "$CASE_DIR/other" ] || fail "project.create must carry the realpath workspaceRoot"
  [ "$(t3_request 3 'r.body.title')" = fm-other ] || fail "project.create title should be the fm- prefixed directory name, got '$(t3_request 3 'r.body.title')'"
  [ -n "$(t3_request 3 'r.body.commandId')" ] && [ -n "$(t3_request 3 'r.body.createdAt')" ] || fail "project.create must carry commandId and createdAt"
  pass "fm_backend_t3code_project_ensure: matches by realpath, otherwise creates with the verified payload"
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
  out=$(t3_run 'fm_backend_t3code_model_selection pi x high proj-1' 2>&1) && fail "a non-T3 harness must be refused"
  assert_contains "$out" "only the claude and codex harnesses" "the harness refusal must name the supported set"
  t3_world_set 'w.shell.projects[0].defaultModelSelection = null'
  out=$(t3_run 'fm_backend_t3code_model_selection claude default default proj-1' 2>&1) && fail "model default with no project default must be refused"
  assert_contains "$out" "has no default model; pass --model" "the default-model refusal must name the fix"
  printf 'claude=claude-pool\n' > "$CONFIG/t3code-instances"
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-fable-5-1 default proj-1')
  [ "$out" = '{"instanceId":"claude-pool","model":"claude-fable-5-1"}' ] || fail "config/t3code-instances must override the instance id, got '$out'"
  pass "fm_backend_t3code_model_selection: effort option ids per harness, default handling, instances file"
}

test_thread_create_and_turn_start_payloads() {
  local id selection
  t3_case thread-lifecycle
  selection='{"instanceId":"claudeAgent","model":"claude-sonnet-5"}'
  id=$(t3_run 'fm_backend_t3code_thread_create proj-1 fm-task1 fm/task1 "$1" "$2"' "$REPO" "$selection") || fail "thread_create failed"
  case "$id" in ????????-????-????-????-????????????) ;; *) fail "thread_create should print a uuid, got '$id'" ;; esac
  [ "$(t3_request 1 'r.body.type')" = thread.create ] || fail "thread_create must dispatch thread.create"
  [ "$(t3_request 1 'r.body.threadId')" = "$id" ] || fail "thread.create must carry the printed thread id"
  [ "$(t3_request 1 'r.body.branch')" = fm/task1 ] || fail "thread.create must carry the branch"
  [ "$(t3_request 1 'r.body.worktreePath')" = "$REPO" ] || fail "thread.create must carry the worktree path"
  [ "$(t3_request 1 'r.body.runtimeMode')" = full-access ] || fail "thread.create must run full-access"
  [ "$(t3_request 1 'r.body.interactionMode')" = default ] || fail "thread.create must use the default interaction mode"
  [ "$(t3_request 1 'r.body.modelSelection')" = "$selection" ] || fail "thread.create must carry the model selection verbatim"
  [ "$(t3_request 1 'r.auth')" = "Bearer $TOKEN" ] || fail "dispatch must carry the configured bearer"
  t3_run 'fm_backend_t3code_turn_start "$1" "$(printf "line one\nline two")" "$2"' "$id" "$selection" || fail "turn_start failed"
  [ "$(t3_request 2 'r.body.type')" = thread.turn.start ] || fail "turn_start must dispatch thread.turn.start"
  [ "$(t3_request 2 'r.body.message.text')" = $'line one\nline two' ] || fail "turn_start must carry the text verbatim"
  [ "$(t3_request 2 'r.body.message.role')" = user ] || fail "turn_start message role must be user"
  [ "$(t3_request 2 'r.body.message.attachments')" = '[]' ] || fail "turn_start must send empty attachments"
  [ -n "$(t3_request 2 'r.body.message.messageId')" ] || fail "turn_start must mint a messageId"
  [ "$(t3_request 2 'r.body.modelSelection')" = "$selection" ] || fail "turn_start must forward the model selection when given"
  t3_run 'fm_backend_t3code_turn_start "$1" steer' "$id" || fail "turn_start without selection failed"
  [ "$(t3_request 3 'r.body.modelSelection')" = undefined ] || fail "a steer without a selection must omit modelSelection"
  t3_run 'fm_backend_t3code_thread_create proj-1 fm-home "" "" "$1"' "$selection" >/dev/null || fail "thread_create without a worktree failed"
  [ "$(t3_request 4 'r.body.worktreePath')" = null ] || fail "an empty worktree must send worktreePath null (an empty string is an HTTP 400), got '$(t3_request 4 'r.body.worktreePath')'"
  [ "$(t3_request 4 'r.body.branch')" = null ] || fail "an empty branch must send branch null"
  pass "fm_backend_t3code_thread_create/turn_start: verified command payloads"
}

test_thread_for_home_zero_one_and_ambiguous() {
  local out status home
  t3_case thread-for-home
  home="$CASE_DIR/link-parent/home-link"
  mkdir -p "$CASE_DIR/link-parent"
  ln -s "$REPO" "$home"
  shell_thread() {  # <id> <projectId> <status|none> <archivedAt-json> <worktreePath-json>
    local session
    if [ "$3" = none ]; then session=null; else session="{\"threadId\":\"$1\",\"status\":\"$3\",\"activeTurnId\":null,\"lastError\":null}"; fi
    printf '{"id":"%s","projectId":"%s","archivedAt":%s,"worktreePath":%s,"session":%s}' "$1" "$2" "$4" "$5" "$session"
  }
  FM_T3_THREADS="[$(shell_thread t-worker proj-1 running null "\"$REPO/wt\""),$(shell_thread t-archived proj-1 running '"2026-09-14T00:00:00.000Z"' null),$(shell_thread t-ready proj-1 ready null null),$(shell_thread t-other proj-2 running null null)]" \
    t3_world_set 'w.shell.projects.push({ id: "proj-2", title: "fm-elsewhere", workspaceRoot: "/nowhere", deletedAt: null }); w.shell.threads = JSON.parse(process.env.FM_T3_THREADS)'
  out=$(t3_run 'fm_backend_t3code_thread_for_home "$1"' "$home" 2>&1)
  status=$?
  [ "$status" -eq 1 ] && [ -z "$out" ] || fail "no live thread on the home must print nothing and return 1 (worktree threads, archived, ready, and other projects excluded), got status $status '$out'"
  FM_T3_THREAD="$(shell_thread t-captain proj-1 running null null)" t3_world_set 'w.shell.threads.push(JSON.parse(process.env.FM_T3_THREAD))'
  out=$(t3_run 'fm_backend_t3code_thread_for_home "$1"' "$home" 2>&1) || fail "one live thread must resolve: $out"
  [ "$out" = t-captain ] || fail "the one live worktree-less thread on the home should resolve through the symlinked path, got '$out'"
  FM_T3_THREAD="$(shell_thread t-second proj-1 starting null null)" t3_world_set 'w.shell.threads.push(JSON.parse(process.env.FM_T3_THREAD))'
  out=$(t3_run 'fm_backend_t3code_thread_for_home "$1"' "$home" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "two live threads must return 2, got $status"
  assert_contains "$out" "t-captain, t-second" "the ambiguity error must name the thread ids"
  assert_contains "$out" "FM_SUPERVISOR_TARGET" "the ambiguity error must tell the operator how to pin the target"
  out=$(FM_T3CODE_ORIGIN=http://127.0.0.1:9 FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_thread_for_home "$1"' "$ROOT" "$home" 2>&1)
  status=$?
  [ "$status" -eq 1 ] && [ -z "$out" ] || fail "an unreachable server must be silent and return 1, got status $status '$out'"
  pass "fm_backend_t3code_thread_for_home: zero, one, ambiguous, and unreachable"
}

test_autodetect_t3_home_and_precedence() {
  local out
  t3_case autodetect
  FM_T3_HOME="$REPO" t3_world_set 'w.shell.threads=[{id:"captain",projectId:"proj-1",worktreePath:null,archivedAt:null,session:{status:"running"}}]'
  # Disable host cmux ancestry while retaining all explicit marker precedence.
  detect() {
    t3_run 'FM_HOME="$1"; unset TMUX HERDR_ENV CMUX_WORKSPACE_ID FM_BACKEND; fm_backend_detect_cmux_fallback() { return 1; }; eval "$2"; fm_backend_name' "$REPO" "$1"
  }
  out=$(detect '' 2>"$CASE_DIR/notice")
  [ "$out" = t3code ] || fail "a unique live home thread must auto-detect T3, got $out"
  assert_grep 'auto-detected t3code' "$CASE_DIR/notice" "T3 detection must announce its opt-out"
  for setting in 'TMUX=socket' 'HERDR_ENV=1' 'CMUX_WORKSPACE_ID=workspace' 'FM_BACKEND=tmux'; do
    out=$(detect "$setting" 2>/dev/null)
    [ "$out" != t3code ] || fail "$setting must win over T3 discovery"
  done
  printf 'zellij\n' > "$CONFIG/backend"
  [ "$(detect '' 2>/dev/null)" = zellij ] || fail 'explicit config/backend must win'
  rm "$CONFIG/backend"
  t3_world_set 'w.shell.threads[0].worktreePath="/other"'
  [ "$(detect '')" = tmux ] || fail 'a worker worktree must not identify the home supervisor'
  t3_world_set 'w.shell.threads[0].worktreePath=null; w.shell.threads.push({...w.shell.threads[0],id:"other"})'
  [ "$(detect '')" = tmux ] || fail 'ambiguous home threads must not auto-detect T3'
  t3_world_set 'w.shell.threads.pop()'
  rm "$CONFIG/t3code-token"
  : > "$LOG"
  [ "$(detect '')" = tmux ] || fail 'missing bearer must not auto-detect T3'
  [ ! -s "$LOG" ] || fail 'unconfigured T3 discovery must make no HTTP request'
  pass 'T3 auto-detection: unique cwd match, configured credentials, explicit overrides, and existing marker precedence'
}

test_capture_renders_messages_and_status() {
  local out
  t3_case capture running
  out=$(t3_run 'fm_backend_t3code_capture thread-live 40')
  [ "$out" = $'[user] do the thing\n[assistant] done\nt3code: session=running turn=completed' ] \
    || fail "capture should render [role] text then the status line, got '$out'"
  out=$(t3_run 'fm_backend_t3code_capture thread-live 1')
  [ "$out" = 't3code: session=running turn=completed' ] || fail "capture must honour the line bound, got '$out'"
  [ "$(t3_request 1 'r.query.turnLimit')" = 5 ] || fail "capture must read with turnLimit=5"
  t3_run 'fm_backend_t3code_capture thread-gone 40' 2>/dev/null && fail "capture of a missing thread must fail"
  pass "fm_backend_t3code_capture: renders the transcript tail and the session line"
}

test_send_key_mapping() {
  local out
  t3_case send-key running
  t3_run 'fm_backend_t3code_send_key thread-live Escape; fm_backend_t3code_send_key thread-live C-c' || fail "Escape and C-c should succeed"
  [ "$(t3_dispatch_types)" = "thread.turn.interrupt thread.turn.interrupt" ] || fail "Escape and C-c must each dispatch thread.turn.interrupt, got '$(t3_dispatch_types)'"
  [ "$(t3_request 1 'r.body.threadId')" = thread-live ] || fail "interrupt must name the thread"
  t3_run 'fm_backend_t3code_send_key thread-live Enter' || fail "Enter must be a no-op success"
  [ "$(t3_dispatch_types)" = "thread.turn.interrupt thread.turn.interrupt" ] || fail "Enter must dispatch nothing"
  out=$(t3_run 'fm_backend_t3code_send_key thread-live C-u' 2>&1) && fail "C-u must be refused"
  assert_contains "$out" "unsupported T3 key 'C-u'" "the refusal must name the key"
  pass "fm_backend_t3code_send_key: Escape and C-c interrupt, Enter no-ops, others refuse"
}

test_send_text_submit_verdicts() {
  local out
  t3_case send-text ready
  out=$(t3_run 'fm_backend_t3code_send_text_submit thread-live "hello" 3 0.01 0.01')
  [ "$out" = empty ] || fail "an accepted turn.start must report empty, got '$out'"
  t3_world_set 'w.dispatch["thread.turn.start"] = { status: 409, body: { _tag: "X", code: "session_busy", reason: "turn already queued" } }'
  out=$(t3_run 'fm_backend_t3code_send_text_submit thread-live "hello" 3 0.01 0.01' 2>/dev/null)
  [ "$out" = send-failed ] || fail "a rejected turn.start must report send-failed, got '$out'"
  pass "fm_backend_t3code_send_text_submit: empty on accept, send-failed on rejection"
}

test_status_table() {
  local status expect got
  t3_case status-table
  for status in starting:busy:alive running:busy:alive ready:idle:alive idle:idle:alive interrupted:idle:alive stopped:idle:dead error:unknown:dead none:idle:alive; do
    t3_world "$(t3_thread_json thread-live "${status%%:*}" null)"
    expect=${status#*:}
    got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
    [ "$got" = "$expect" ] || fail "session ${status%%:*} should classify $expect, got $got"
  done
  t3_world "$(t3_thread_json thread-live ready '"2026-09-14T00:00:00.000Z"')"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
  [ "$got" = unknown:missing ] || fail "an archived thread should classify unknown:missing, got $got"
  t3_run 'fm_backend_t3code_target_exists thread-live' && fail "an archived thread must not exist"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = unknown ] || fail "an archived thread's composer is unknown"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-gone'):$(t3_run 'fm_backend_t3code_agent_state thread-gone')"
  [ "$got" = unknown:missing ] || fail "HTTP 404 should classify unknown:missing, got $got"
  got="$(FM_T3CODE_ORIGIN=http://127.0.0.1:9 FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; printf "%s:%s" "$(fm_backend_t3code_busy_state thread-live)" "$(fm_backend_t3code_agent_state thread-live)"' "$ROOT")"
  [ "$got" = unknown:unreadable ] || fail "an unreachable server should classify unknown:unreadable, got $got"
  t3_world "$(t3_thread_json thread-live ready null)"
  t3_run 'fm_backend_t3code_target_exists thread-live' || fail "a live thread must exist"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = empty ] || fail "a live thread's composer is always empty"
  pass "t3code status table: every session status, archived, 404, and unreachable rows"
}

test_kill_stops_then_archives_and_tolerates_gone() {
  t3_case kill running
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of a live thread should succeed"
  [ "$(t3_dispatch_types)" = "thread.session.stop thread.archive" ] || fail "kill must stop then archive, got '$(t3_dispatch_types)'"
  [ "$(t3_request 2 'r.body.threadId')" = thread-live ] && [ -n "$(t3_request 2 'r.body.createdAt')" ] || fail "session.stop must carry threadId and createdAt"
  [ "$(t3_request 3 'r.body.createdAt')" = undefined ] || fail "thread.archive carries no createdAt"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-gone' || fail "kill of a deleted thread (404) is success"
  [ -z "$(t3_dispatch_types)" ] || fail "a 404 thread must dispatch nothing"
  t3_world "$(t3_thread_json thread-live ready '"2026-09-14T00:00:00.000Z"')"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of an archived thread is success"
  [ -z "$(t3_dispatch_types)" ] || fail "an archived thread must dispatch nothing"
  t3_world "$(t3_thread_json thread-live running null)"
  t3_world_set 'w.dispatch["thread.archive"] = { status: 500, body: { reason: "boom" } }'
  t3_run 'fm_backend_t3code_kill thread-live' 2>/dev/null && fail "a failed archive must fail the kill"
  pass "fm_backend_t3code_kill: stop then archive, idempotent on archived and 404, loud on failure"
}

test_dispatcher_routes_and_validates_t3code_meta() {
  local state id out thread=1b6d0a1e-1e5a-4c2a-9c3b-0123456789ab
  t3_case dispatcher ready
  t3_world "$(t3_thread_json "$thread" ready null)"
  id=t3taskz1
  state="$CASE_DIR/state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "harness=claude" "kind=scout" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-1"
  out=$(t3_run 'fm_backend_capture t3code "$1" 1' "$thread") || fail "dispatcher capture failed"
  [ "$out" = 't3code: session=ready turn=completed' ] || fail "dispatcher must route capture to the adapter, got '$out'"
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
  t3_run 'fm_backend_validate_task_endpoint "$1" "$2"' "$state/$id.meta" "$id" 2>/dev/null && fail "a thread id outside the uuid charset must refuse"
  [ "$(t3_run 'fm_backend_required_tools t3code')" = 'node treehouse' ] || fail "t3code requires node and treehouse"
  pass "fm-backend dispatcher: routes every t3code primitive, validates and resolves t3_thread_id records"
}

test_harness_admission_and_typing_refusals() {
  local op out
  t3_case shared-spawn ready
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
  out=$(FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$ROOT" "$id" "$state")
  [ "$out" = "busy t3code-native" ] || fail "a running t3code session with no record must classify busy t3code-native, got '$out'"
  t3_world "$(t3_thread_json thread-live ready null)"
  out=$(FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$ROOT" "$id" "$state")
  [ "$out" = "idle t3code-native" ] || fail "a ready t3code session with no record must classify idle t3code-native, got '$out'"
  t3_world "$(t3_thread_json thread-live error null)"
  out=$(FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$ROOT" "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "an error session must fall through to unknown missing, got '$out'"
  pass "fm_busy_classify: t3code native busy and idle are both trusted without a record"
}

test_stale_classifier_resolves_t3_thread() {
  local state out declaration
  t3_case stale-task-mapping ready
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

# Drive the real watcher with an unchanged transcript and an expired wedge
# timer. The pipeline fixture binds to a real repository's branch and HEAD,
# so fm-crew-state.sh performs its ordinary run attribution.
test_t3_stale_watcher() {  # <session-status> <absorb|surface|dead> [harness]
  local session=$1 expected=$2 harness=${3:-codex} state fb hash out i
  local thread=6a0e1f2b-3c4d-4a5b-8c6d-0123456789ab
  t3_case "watch-$session-$harness" "$session"
  t3_world "$(t3_thread_json "$thread" "$session" null)"
  if [ "$session" = running ]; then
    t3_world_set 'Object.values(w.threads)[0].latestTurn.state = "running"'
  fi
  state="$CASE_DIR/state"; fb="$CASE_DIR/fakebin"; out="$CASE_DIR/watch.out"
  mkdir -p "$state" "$fb" "$CASE_DIR/data"
  fm_git_init_commit "$REPO"
  git -C "$REPO" checkout -qb fm/worker
  fm_write_meta "$state/worker.meta" "window=fm-worker" "backend=t3code" \
    "t3_thread_id=$thread" "worktree=$REPO" "project=$REPO" "harness=$harness" "kind=ship"
  touch -t 200001010000 "$state/worker.meta"
  # No validation run is attributed: the deferral reads the T3 session alone.
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
  printf '%s' "$hash" > "$state/.hash-$thread"
  printf '%s' "$hash" > "$state/.stale-$thread"
  printf '3\n' > "$state/.count-$thread"
  printf '1\n' > "$state/.stale-since-$thread"
  printf '3\n' > "$state/.wedge-escalations-$thread"
  PATH="$fb:$PATH" FM_T3_TEST_RUN="$CASE_DIR/run.toon" FM_T3CODE_ORIGIN="$ORIGIN" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$CASE_DIR/data" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS=1 \
    FM_STALE_ESCALATE_SECS=1 FM_WEDGE_DEMAND_INSPECT_COUNT=3 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  for i in $(seq 1 600); do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    if [ "$expected" = absorb ] && [ "$(cat "$state/.stale-since-$thread" 2>/dev/null)" != 1 ] \
        && [ -s "$state/.stale-since-$thread" ]; then break; fi
    sleep 0.1
  done
  if [ "$expected" = absorb ]; then
    kill -0 "$WATCH_PID" 2>/dev/null || fail "a running T3 session woke firstmate: $(cat "$out")"
    [ "$(cat "$state/.stale-since-$thread" 2>/dev/null)" != 1 ] || fail "watcher never reset the expired timer"
    # Like the other deferrals, the consult resets the idle timer and leaves
    # the escalation count to the next transcript change.
    assert_absent "$state/.wake-queue" "a running T3 session must not queue a wake"
    kill "$WATCH_PID" 2>/dev/null || true
  elif [ "$expected" = dead ]; then
    # A stopped or failed session is a dead agent: the shared dead-record probe
    # reports it once instead of aging it on the wedge ladder.
    assert_contains "$(cat "$out")" 'agent dead' "a stopped or failed T3 session must be reported as a dead agent"
  else
    assert_contains "$(cat "$out")" 'demand-deep-inspection' "a T3 session that is not running must still escalate"
  fi
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  pass "T3 stale watcher: harness=$harness session=$session -> $expected"
}

test_control_lib_tables() {
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_supports_key t3code Escape && fm_control_backend_supports_key t3code Enter && fm_control_backend_supports_key t3code C-c && ! fm_control_backend_supports_key t3code C-u && fm_control_backend_state_verified t3code' "$ROOT" \
    || fail "control-lib must accept Enter/Escape/C-c, refuse C-u, and treat t3code as state-verified"
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_native_exit t3code && ! fm_control_backend_native_exit tmux && ! fm_control_backend_native_exit herdr' "$ROOT" \
    || fail "control-lib must name t3code, and only t3code, as a native-exit backend"
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_relaunch_supported tmux && fm_control_backend_relaunch_supported herdr && ! fm_control_backend_relaunch_supported t3code' "$ROOT" \
    || fail "control-lib must keep replacement launches on tmux and herdr and refuse them on t3code"
  pass "fm-control-lib: t3code key set, state-verified, native-exit, and no-replacement membership"
}

# A recorded t3code scout for the control plane: the fake thread in the given
# session status, the ordinary meta lines, and a brief so relaunch's own
# checks are the ones that decide.
make_t3_control_task() {  # <case-name> <id> <thread-id> <session-status>
  t3_case "$1" "$4"
  t3_world "$(t3_thread_json "$3" "$4" null)"
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
  FM_T3CODE_ORIGIN="$ORIGIN" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_control_exit_stops_session_natively() {
  local id out rc thread=7a1b2c3d-4e5f-4a6b-8c7d-0123456789ab
  id="t3exitz1"
  make_t3_control_task control-exit "$id" "$thread" ready
  out=$(run_t3_control "$id" exit); rc=$?
  expect_code 0 "$rc" "exit on an idle t3code task should succeed"$'\n'"$out"
  assert_contains "$out" "stopped $id harness=claude backend=t3code endpoint=$thread" "exit must report the stop with the thread as the endpoint"
  [ "$(t3_dispatch_types)" = "thread.session.stop" ] || fail "exit must be exactly one thread.session.stop and never a typed turn, got '$(t3_dispatch_types)'"
  assert_present "$CTRL_STATE/$id.meta" "exit preserves the task record"
  [ "$(t3_run 'fm_backend_agent_state t3code "$1"' "$thread")" = dead ] || fail "the stopped session must classify dead"
  out=$(run_t3_control "$id" exit); rc=$?
  expect_code 0 "$rc" "a second exit should be idempotent"$'\n'"$out"
  assert_contains "$out" "already-stopped $id" "a stopped session reports already-stopped"
  [ "$(t3_dispatch_types)" = "thread.session.stop" ] || fail "an already stopped session must not be stopped again, got '$(t3_dispatch_types)'"
  pass "fm-control.sh exit backend=t3code: one thread.session.stop, proven by the session reading stopped, idempotent"
}

test_control_relaunch_refused_before_any_dispatch() {
  local id out rc thread=8b2c3d4e-5f6a-4b7c-9d8e-123456789abc fb
  id="t3relaunchz1"
  make_t3_control_task control-relaunch "$id" "$thread" running
  out=$(run_t3_control "$id" relaunch --note "why"); rc=$?
  expect_code 1 "$rc" "relaunch on a t3code task must refuse"$'\n'"$out"
  assert_contains "$out" "bound to its driver" "the refusal must name the driver binding"
  [ -z "$(t3_dispatch_types)" ] || fail "a refused relaunch must send nothing to T3, got '$(t3_dispatch_types)'"
  assert_present "$CTRL_STATE/$id.meta" "a refused relaunch preserves the task record"
  assert_absent "$CTRL_STATE/$id.control-relaunch" "a refused relaunch opens no transaction journal"
  [ "$(t3_run 'fm_backend_agent_state t3code "$1"' "$thread")" = alive ] || fail "the running agent must be untouched"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$CTRL_WT" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CTRL_STATE" FM_DATA_OVERRIDE="$CTRL_DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
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
  t3_case spawn-codex-tracked ready
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$proj/.codex" "$data/$id" "$state" "$CASE_DIR/home/state"
  printf '[shell_environment_policy]\ninherit = "all"\n' > "$proj/.codex/config.toml"
  git -C "$proj" add .codex/config.toml
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm "track codex config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.shell.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
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
  t3_case spawn-codex-tracked-compatible ready
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
  FM_T3_PROJ="$proj" t3_world_set 'w.shell.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
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
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" FM_T3CODE_ORIGIN="$ORIGIN" \
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
  t3_case spawn-claude-tracked ready
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  printf 'project instructions\n' > "$proj/CLAUDE.local.md"
  git -C "$proj" add CLAUDE.local.md
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm "track local instructions"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.shell.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --scout --model claude-sonnet-5 --backend t3code 2>&1 ); rc=$?
  expect_code 1 "$rc" "a claude t3code spawn must refuse a project that tracks CLAUDE.local.md"$'\n'"$out"
  assert_contains "$out" "tracks CLAUDE.local.md" "the refusal must name the tracked file"
  [ -z "$(t3_dispatch_types)" ] || fail "the refusal must come before any T3 mutation, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "the refusal must come before the slot is leased"
  assert_absent "$state/$id.meta" "a refused spawn records nothing"
  pass "fm-spawn.sh --backend t3code claude: refuses to overwrite a project's tracked CLAUDE.local.md before any mutation"
}

test_spawn_leases_slot_creates_thread_and_starts_launch_turn() {
  local proj wt data state id out fb thread
  id="t3spawnz1"
  t3_case spawn ready
  proj="$CASE_DIR/spawn-project"
  wt="$CASE_DIR/spawn-wt"
  data="$CASE_DIR/data"
  state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  FM_T3_PROJ="$proj" t3_world_set 'w.shell.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
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
  case "$thread" in ????????-????-????-????-????????????) ;; *) fail "meta t3_thread_id should be a uuid, got '$thread'" ;; esac
  [ "$(t3_dispatch_types)" = "thread.create thread.turn.start" ] || fail "spawn must dispatch thread.create then thread.turn.start, got '$(t3_dispatch_types)'"
  [ "$(t3_log_line_of 'r.tool === "treehouse" && r.args === "get --lease --lease-holder '"$id"'" && r.cwd === "'"$proj"'"')" -gt 0 ] \
    || fail "spawn must lease the slot with treehouse get --lease --lease-holder <id> from the project"
  local create turn
  create=$(t3_log_line_of 'r.body && r.body.type === "thread.create"')
  turn=$(t3_log_line_of 'r.body && r.body.type === "thread.turn.start"')
  [ "$(t3_request "$create" 'r.body.threadId')" = "$thread" ] || fail "thread.create must carry the recorded thread id"
  [ "$(t3_request "$create" 'r.body.worktreePath')" = "$wt" ] || fail "thread.create must point at the leased worktree"
  [ "$(t3_request "$create" 'r.body.branch')" = "fm/$id" ] || fail "thread.create must carry the slot's branch"
  [ "$(t3_request "$create" 'r.body.title')" = "fm-$id" ] || fail "thread.create title should be the window alias"
  [ "$(t3_request "$create" 'r.body.modelSelection')" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "thread.create must carry --model/--effort as the model selection"
  [ "$(t3_request "$turn" 'r.body.threadId')" = "$thread" ] || fail "turn.start must target the created thread"
  assert_contains "$(t3_request "$turn" 'r.body.message.text')" "FIRSTMATE_OP: v1 launch-brief:" "turn.start must carry the encoded launch brief"
  assert_contains "$(t3_request "$turn" 'r.body.message.text')" "Verify the T3 lifecycle behavior under test." "turn.start must carry the brief body"
  assert_present "$wt/.claude/settings.local.json" "spawn must still arm the Claude busy hooks in the worktree before the launch turn"
  local settings="$wt/.claude/settings.local.json"
  [ "$(t3_json_field "$settings" 'Object.keys(d.hooks).sort().join(" ")')" = "SessionEnd Stop StopFailure UserPromptSubmit" ] \
    || fail "the env merge must keep the busy hooks, got hooks '$(t3_json_field "$settings" 'Object.keys(d.hooks || {})')'"
  [ "$(t3_json_field "$settings" 'd.env.GOTMPDIR')" = "/tmp/fm-$id/gotmp" ] || fail "settings env must carry GOTMPDIR, got '$(t3_json_field "$settings" 'd.env')'"
  [ "$(t3_json_field "$settings" 'd.env.FM_TASK_ID')" = "$id" ] || fail "a ship worker's settings env must carry FM_TASK_ID"
  [ "$(t3_json_field "$settings" 'd.env.TRACEPARENT')" = undefined ] || fail "TRACEPARENT must be absent when trace context is off"
  [ "$(t3_json_field "$settings" 'd.env.COMPACT_ADVISER_DISABLE')" = 1 ] || fail "settings env must carry the compact-adviser kill switch every launch carries"
  [ "$(t3_json_field "$settings" 'Object.keys(d.env).sort().join(" ")')" = "COMPACT_ADVISER_DISABLE FM_TASK_ID GOTMPDIR" ] || fail "a worker env block carries exactly GOTMPDIR, COMPACT_ADVISER_DISABLE, and FM_TASK_ID"
  t3_excluded "$wt" .claude/settings.local.json || fail "the settings file must be git-excluded"
  assert_present "$wt/CLAUDE.local.md" "a claude worker gets the task-worker channel statement as CLAUDE.local.md"
  assert_grep "task worker launched by Firstmate" "$wt/CLAUDE.local.md" "CLAUDE.local.md must carry the channel statement"
  assert_grep "first-party task instructions" "$wt/CLAUDE.local.md" "CLAUDE.local.md must name the brief and inbox as first-party"
  assert_grep "link_pull_request, list_thread_pull_requests, or unlink_pull_request" "$wt/CLAUDE.local.md" "CLAUDE.local.md must prohibit T3's PR-linking tools"
  assert_grep "done: PR <url> status line" "$wt/CLAUDE.local.md" "CLAUDE.local.md must name Firstmate's PR-recording channel"
  t3_excluded "$wt" CLAUDE.local.md || fail "CLAUDE.local.md must be git-excluded"
  [ "$(t3_log_line_of 'r.body && r.body.type === "thread.turn.start"')" -gt "$(t3_log_line_of 'r.tool === "treehouse"')" ] \
    || fail "the launch turn must follow the lease"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code: leases the slot, creates the thread on it, records metadata, starts the launch turn"
}

test_spawn_codex_scout_writes_toml_env_with_traceparent() {
  local proj wt data state id out fb toml tp
  t3_require_tomllib test_spawn_codex_scout_writes_toml_env_with_traceparent || return 0
  id="t3codexz1"
  t3_case spawn-codex ready
  proj="$CASE_DIR/spawn-project"; wt="$CASE_DIR/spawn-wt"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  # A worker's trace context is this home's frozen session decision
  # (bin/fm-trace-context-lib.sh): the session lock pid plus an `on` record.
  printf '%s\n' "$$" > "$state/.lock"
  printf '%s on\n' "$$" > "$state/.trace-context-effective"
  FM_T3_PROJ="$proj" t3_world_set 'w.shell.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --scout --model gpt-5.6-sol --backend t3code 2>&1 )
  expect_code 0 $? "a codex scout on t3code should spawn against the fake T3 server"$'\n'"$out"
  toml="$wt/.codex/config.toml"
  assert_present "$toml" "a codex worker gets .codex/config.toml in its worktree"
  [ "$(t3_toml_env "$toml" GOTMPDIR)" = "/tmp/fm-$id/gotmp" ] || fail "config.toml must set GOTMPDIR, got '$(cat "$toml")'"
  [ "$(t3_toml_env "$toml" FM_TASK_ID)" = "$id" ] || fail "a scout's config.toml must set FM_TASK_ID"
  [ "$(t3_toml_env "$toml" COMPACT_ADVISER_DISABLE)" = 1 ] || fail "config.toml must set the compact-adviser kill switch"
  tp=$(t3_toml_env "$toml" TRACEPARENT)
  case "$tp" in 00-????????????????????????????????-????????????????-??) ;; *) fail "config.toml must set a W3C TRACEPARENT when trace context is on, got '$(cat "$toml")'" ;; esac
  grep -qxF "traceparent=$tp" "$state/$id.meta" || fail "the delivered TRACEPARENT must be the one recorded in the meta, got '$(grep '^traceparent=' "$state/$id.meta")'"
  assert_absent "$wt/.claude/settings.local.json" "a codex worker writes no Claude settings"
  assert_absent "$wt/CLAUDE.local.md" "a codex worker gets no Claude channel statement"
  t3_excluded "$wt" .codex/config.toml || fail "config.toml must be git-excluded"
  [ "$(t3_dispatch_types)" = "thread.create thread.turn.start" ] || fail "spawn must dispatch thread.create then thread.turn.start, got '$(t3_dispatch_types)'"
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
  HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' FM_T3CODE_ORIGIN="$ORIGIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_DATA_OVERRIDE="$CASE_DIR/home/data" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$CASE_DIR/home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "$harness" --model "$model" --backend t3code --secondmate 2>&1
}

# The twelve variables a t3code secondmate must find in its environment: the
# nine of the pane launch prefix, value for value, the compact-adviser kill
# switch, plus its supervisor identity.
assert_t3_secondmate_env() {  # <reader "<file>"> <label> <home> <thread> <supervision-model>
  local read=$1 label=$2 home=$3 thread=$4 model=$5 name expect
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
EOF
  [ "$($read FM_TASK_ID)" = undefined ] || fail "$label: a secondmate is not a task worker and must not carry FM_TASK_ID"
  [ "$($read TRACEPARENT)" = undefined ] || fail "$label: TRACEPARENT must be absent when trace context is off"
}

test_spawn_secondmate_runs_thread_in_home_with_env() {
  local id home out thread project create turn settings
  id="t3smz1"
  t3_case spawn-secondmate ready
  home="$CASE_DIR/sm-home"
  make_t3_secondmate_home "$home" "$id"
  out=$(spawn_t3_secondmate "$id" "$home" claude claude-sonnet-5)
  expect_code 0 $? "fm-spawn.sh --backend t3code --secondmate should succeed against the fake T3 server"$'\n'"$out"
  [ "$(t3_dispatch_types)" = "project.create thread.create thread.turn.start" ] \
    || fail "a secondmate spawn must create the home's project, then the thread, then start the launch turn, got '$(t3_dispatch_types)'"
  create=$(t3_log_line_of 'r.body && r.body.type === "project.create"')
  [ "$(t3_request "$create" 'r.body.title')" = fm-sm-home ] || fail "the home's T3 project must carry the fm- prefixed title, got '$(t3_request "$create" 'r.body.title')'"
  [ "$(t3_request "$create" 'r.body.workspaceRoot')" = "$(cd "$home" && pwd -P)" ] || fail "the home's T3 project workspaceRoot must be the home"
  project=$(t3_request "$create" 'r.body.projectId')
  create=$(t3_log_line_of 'r.body && r.body.type === "thread.create"')
  thread=$(t3_request "$create" 'r.body.threadId')
  [ "$(t3_request "$create" 'r.body.projectId')" = "$project" ] || fail "the thread must be created on the home's project"
  [ "$(t3_request "$create" 'r.body.worktreePath')" = null ] || fail "a secondmate thread runs in the home: worktreePath must be null, got '$(t3_request "$create" 'r.body.worktreePath')'"
  [ "$(t3_request "$create" 'r.body.branch')" = sm/home ] || fail "thread.create must carry the home's current branch, got '$(t3_request "$create" 'r.body.branch')'"
  [ "$(t3_request "$create" 'r.body.title')" = "fm-$id" ] || fail "thread.create title should be the window alias"
  [ "$(t3_request "$create" 'r.body.modelSelection')" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5"}' ] || fail "thread.create must carry the secondmate's model selection"
  turn=$(t3_log_line_of 'r.body && r.body.type === "thread.turn.start"')
  [ "$(t3_request "$turn" 'r.body.threadId')" = "$thread" ] || fail "the launch turn must target the created thread"
  assert_contains "$(t3_request "$turn" 'r.body.message.text')" "FIRSTMATE_OP: v1 launch-brief:" "the launch turn must carry the encoded brief"
  assert_contains "$(t3_request "$turn" 'r.body.message.text')" "Run the fleet for the T3 secondmate test." "the launch turn must carry the charter body"
  assert_grep "backend=t3code" "$CASE_DIR/home/state/$id.meta" "meta missing backend=t3code"
  assert_grep "kind=secondmate" "$CASE_DIR/home/state/$id.meta" "meta missing kind=secondmate"
  assert_grep "home=$home" "$CASE_DIR/home/state/$id.meta" "meta missing home="
  assert_absent "$home/CLAUDE.local.md" "a secondmate runs under its own supervisor contract and gets no task-worker statement"
  assert_grep "t3_thread_id=$thread" "$CASE_DIR/home/state/$id.meta" "meta missing the created thread id"
  assert_grep "t3_project_id=$project" "$CASE_DIR/home/state/$id.meta" "meta missing the created project id"
  settings="$home/.claude/settings.local.json"
  assert_present "$settings" "a claude secondmate home gets .claude/settings.local.json"
  [ "$(t3_json_field "$settings" 'd.hooks')" = undefined ] || fail "a secondmate home carries no busy hooks"
  [ "$(t3_json_field "$settings" 'Object.keys(d.env).length')" = 13 ] || fail "the env block should carry GOTMPDIR plus the twelve secondmate variables, got $(t3_json_field "$settings" 'Object.keys(d.env)')"
  [ "$(t3_json_field "$settings" 'd.env.GOTMPDIR')" = "/tmp/fm-$id/gotmp" ] || fail "settings env must carry GOTMPDIR"
  read_settings() { t3_json_field "$settings" "d.env[\"$1\"]"; }
  assert_t3_secondmate_env read_settings "claude secondmate settings env" "$home" "$thread" autoarm
  t3_excluded "$home" .claude/settings.local.json || fail "the settings file must be git-excluded in the home"
  assert_absent "$home/.codex/config.toml" "a claude secondmate writes no codex config"
  [ -L "$home/config/t3code-token" ] || fail "the secondmate home must link the primary's bearer, not copy it"
  [ "$(cat "$home/config/t3code-token")" = "$TOKEN" ] || fail "the home's bearer link must resolve to the primary's token"
  printf 'rotated\n' > "$CONFIG/t3code-token"
  [ "$(cat "$home/config/t3code-token")" = rotated ] || fail "a re-minted primary token must reach the secondmate home"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code --secondmate: project on the home, worktree-less thread, charter turn, launch prefix as settings env"
}

test_spawn_codex_secondmate_writes_toml_env() {
  local id home out thread toml
  t3_require_tomllib test_spawn_codex_secondmate_writes_toml_env || return 0
  id="t3smz2"
  t3_case spawn-secondmate-codex ready
  home="$CASE_DIR/sm-home-codex"
  make_t3_secondmate_home "$home" "$id"
  out=$(spawn_t3_secondmate "$id" "$home" codex gpt-5.6-sol)
  expect_code 0 $? "a codex secondmate on t3code should spawn against the fake T3 server"$'\n'"$out"
  [ "$(t3_dispatch_types)" = "project.create thread.create thread.turn.start" ] || fail "unexpected dispatches '$(t3_dispatch_types)'"
  thread=$(t3_request "$(t3_log_line_of 'r.body && r.body.type === "thread.create"')" 'r.body.threadId')
  toml="$home/.codex/config.toml"
  assert_present "$toml" "a codex secondmate home gets .codex/config.toml"
  [ "$(t3_toml_env "$toml" GOTMPDIR)" = "/tmp/fm-$id/gotmp" ] || fail "config.toml must set GOTMPDIR, got '$(cat "$toml")'"
  read_toml() { t3_toml_env "$toml" "$1"; }
  assert_t3_secondmate_env read_toml "codex secondmate config.toml" "$home" "$thread" persistent
  t3_excluded "$home" .codex/config.toml || fail "config.toml must be git-excluded in the home"
  assert_absent "$home/.claude/settings.local.json" "a codex secondmate writes no Claude settings"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3code --secondmate codex: launch prefix as .codex/config.toml shell_environment_policy"
}

test_spawn_refuses_t3code_when_token_rejected() {
  local proj data state id out status fb
  id="t3authz1"
  t3_case spawn-bad-token ready
  printf 'stale\n' > "$CONFIG/t3code-token"
  proj="$CASE_DIR/project"; data="$CASE_DIR/data"; state="$CASE_DIR/state"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$CASE_DIR/home/state"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$proj" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3code 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend t3code should refuse when the T3 server rejects the bearer"
  assert_contains "$out" "npx t3@0.0.41-nightly.20260914.1707 auth session issue --json" "the refusal must name the mint command"
  assert_absent "$state/$id.meta" "a runtime refusal must not record metadata"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "spawn must refuse before leasing a slot"
  [ -z "$(t3_dispatch_types)" ] || fail "spawn must refuse before dispatching anything"
  pass "fm-spawn.sh --backend t3code: refuses before mutation when the bearer is rejected"
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
  FM_T3_PROJ="$WORKER_PROJ" t3_world_set 'w.shell.projects[0].workspaceRoot = process.env.FM_T3_PROJ'
}

# t3_worker_spawn <id> <harness> [spawn-arg ...] -> output; status in $?.
t3_worker_spawn() {
  local id=$1 harness=$2 fb
  shift 2
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$WORKER_WT" \
    FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$CASE_DIR/state" FM_DATA_OVERRIDE="$CASE_DIR/data" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$WORKER_PROJ" "$harness" --scout --backend t3code "$@" 2>&1
}

test_spawn_refuses_launch_settings_t3_cannot_honor() {  # <config-file> <content> <expected-error>
  local file=$1 content=$2 expect=$3 id out rc
  id="t3cfgz-$file"
  t3_case "spawn-refuse-$file" ready
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

test_spawn_abort_returns_lease_only_after_archive() {  # <stop-status>
  local stop=$1 id out rc return_line
  id="t3abortz$stop"
  t3_case "spawn-abort-$stop" ready
  t3_world_set 'w.recordCreatedThreads = true'
  [ "$stop" = 200 ] || t3_world_set 'w.dispatch["thread.session.stop"] = { status: 500, body: { reason: "boom" } }'
  # A regular file where the Claude hooks go aborts the spawn after the
  # thread exists and before its record is published.
  t3_worker_setup "$id"
  printf 'blocker\n' > "$WORKER_WT/.claude"
  out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
  [ "$rc" -ne 0 ] || fail "the blocked spawn should abort"$'\n'"$out"
  return_line=$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')
  if [ "$stop" = 200 ]; then
    [ "$(t3_dispatch_types)" = "thread.create thread.session.stop thread.archive" ] || fail "an abort must stop and archive the thread, got '$(t3_dispatch_types)'"
    [ "$return_line" -gt "$(t3_log_line_of 'r.body && r.body.type === "thread.archive"')" ] || fail "an abort must return the lease after the archive"$'\n'"$out"
    pass "fm-spawn.sh --backend t3code: an abort archives the thread, then returns the lease"
  else
    [ "$return_line" -eq 0 ] || fail "an abort whose archive failed must keep the lease a live thread still points at"
    assert_contains "$out" "stays leased" "the warning must say the lease was kept"
    assert_contains "$out" "treehouse return --force" "the warning must name the manual return"
    pass "fm-spawn.sh --backend t3code: an abort that cannot archive the thread keeps the lease"
  fi
}

test_scout_teardown_stops_and_archives_before_slot_return() {
  local proj wt data state id out rc neutral fb thread=2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345
  id="t3teardownz1"
  t3_case teardown running
  t3_world "$(t3_thread_json "$thread" running null)"
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
  printf '[shell_environment_policy]\nset = { FM_TASK_ID = "%s" }\n' "$id" > "$wt/.codex/config.toml"
  printf 'statement\n' > "$wt/CLAUDE.local.md"
  fb=$(make_treehouse_fakebin "$CASE_DIR")
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" FM_T3CODE_ORIGIN="$ORIGIN" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  expect_code 0 "$rc" "t3code scout teardown should succeed once the report exists"$'\n'"$out"
  assert_absent "$wt/.codex/config.toml" "teardown must remove the codex env config before the slot is reused"
  assert_absent "$wt/CLAUDE.local.md" "teardown must remove the channel statement before the slot is reused"
  [ "$(t3_dispatch_types)" = "thread.session.stop thread.archive" ] || fail "teardown must stop then archive exactly once, got '$(t3_dispatch_types)'"
  local archive_line return_line
  archive_line=$(t3_log_line_of 'r.body && r.body.type === "thread.archive"')
  return_line=$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return --force") === 0')
  [ "$return_line" -gt 0 ] || fail "teardown must return the slot through treehouse"
  [ "$archive_line" -lt "$return_line" ] || fail "the thread must be archived before the slot is returned (archive line $archive_line, return line $return_line)"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=t3code: stops and archives the thread, then returns the slot"
}

test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete() {
  local home data state config id out rc thread=4e0f2a6b-9d3c-4b5e-af4f-0123456789cd archive_line harness=${1:-claude} journal=
  t3_require_tomllib test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete || return 0
  id="t3smtdz1-$harness"
  t3_case "teardown-secondmate-$harness" running
  t3_world "$(t3_thread_json "$thread" running null)"
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
  out=$( FM_T3CODE_ORIGIN="$ORIGIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
  rc=$?
  expect_code 0 "$rc" "t3code secondmate teardown should succeed"$'\n'"$out"
  [ "$(t3_dispatch_types)" = "thread.session.stop thread.archive" ] || fail "secondmate teardown must stop then archive exactly once and never delete the project, got '$(t3_dispatch_types)'"
  archive_line=$(t3_log_line_of 'r.body && r.body.type === "thread.archive"')
  [ "$(t3_request "$archive_line" 'r.probe')" = true ] || fail "the thread must be archived while the home still exists"
  assert_absent "$home" "teardown should remove the secondmate home"
  [ -z "$journal" ] || assert_absent "$journal" "secondmate cleanup must retire its tracked Codex overlay before removing the home"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=t3code secondmate: stops and archives before the home is removed, leaves the T3 project"
}

test_teardown_refuses_when_t3_is_unreachable() {
  local proj wt data state id out rc neutral fb thread=3d9e1f5a-8c2b-4a4d-8f3e-fedcba543210
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
  out=$( PATH="$fb:$PATH" FM_T3_TREEHOUSE_LOG="$LOG" FM_T3_TREEHOUSE_WT="$wt" FM_T3CODE_ORIGIN=http://127.0.0.1:9 \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown must refuse when the T3 server cannot be reached"
  assert_contains "$out" "could not stop and archive T3 thread $thread" "the refusal must name the thread and the fix"
  [ "$(t3_log_line_of 'r.tool === "treehouse"')" -eq 0 ] || fail "a refused teardown must not return the slot"
  assert_present "$state/$id.meta" "a refused teardown must preserve metadata"
  pass "fm-teardown.sh backend=t3code: refuses to return a slot a live thread still points at"
}

test_stale_classifier_resolves_t3_thread
test_t3_stale_watcher running absorb
test_t3_stale_watcher running absorb claude
test_t3_stale_watcher starting surface
test_t3_stale_watcher ready surface
test_t3_stale_watcher stopped dead
test_t3_stale_watcher error dead
test_missing_token_names_mint_command
test_rejected_token_names_mint_command
test_missing_origin_names_runtime_file
test_version_floor_refuses_old_server
test_project_ensure_matches_realpath_or_creates
test_model_selection_table
test_thread_create_and_turn_start_payloads
test_thread_for_home_zero_one_and_ambiguous
test_autodetect_t3_home_and_precedence
test_capture_renders_messages_and_status
test_send_key_mapping
test_send_text_submit_verdicts
test_status_table
test_kill_stops_then_archives_and_tolerates_gone
test_dispatcher_routes_and_validates_t3code_meta
test_harness_admission_and_typing_refusals
test_busy_classify_trusts_native_idle_and_busy
test_control_lib_tables
test_control_exit_stops_session_natively
test_control_relaunch_refused_before_any_dispatch
test_spawn_leases_slot_creates_thread_and_starts_launch_turn
test_spawn_codex_preserves_tracked_codex_config
test_tracked_codex_overlay_recovery
test_spawn_codex_refuses_tracked_codex_config
test_spawn_claude_refuses_tracked_claude_local_md
test_spawn_codex_scout_writes_toml_env_with_traceparent
test_spawn_secondmate_runs_thread_in_home_with_env
test_spawn_codex_secondmate_writes_toml_env
test_spawn_refuses_t3code_when_token_rejected
test_scout_teardown_stops_and_archives_before_slot_return
test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete
test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete codex
test_teardown_refuses_when_t3_is_unreachable
test_spawn_refuses_launch_settings_t3_cannot_honor claude-permission-mode auto "config/claude-permission-mode=auto"
test_spawn_refuses_launch_settings_t3_cannot_honor launch-env-allowlist HOME "config/launch-env-allowlist"
test_spawn_abort_returns_lease_only_after_archive 200
test_spawn_abort_returns_lease_only_after_archive 500
