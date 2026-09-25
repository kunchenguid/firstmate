#!/usr/bin/env bash
# bin/backends/t3code.sh - the T3 Code orchestration-server adapter.
#
# T3 owns the agent session (it launches Claude or Codex itself) while
# Treehouse still owns the task worktree. Firstmate drives the T3 server over
# its HTTP orchestration API with a CLI-issued bearer. There is no terminal:
# nothing is typed, a steer is a thread.turn.start, and Escape/Ctrl-C are a
# thread.turn.interrupt.
#
# Target string shape: the T3 thread id (uuid).
#
# T3 sets environment variables per provider instance, never per thread, so
# every fact firstmate would type into a pane before launch (GOTMPDIR,
# COMPACT_ADVISER_DISABLE, optional LAVISH_AXI_HOST, FM_TASK_ID, TRACEPARENT,
# and a secondmate's FM_* launch prefix) travels
# instead as per-directory harness config that bin/fm-spawn.sh writes into the
# launch directory before the first turn: `.claude/settings.local.json` `env`
# for Claude, `.codex/config.toml` `[shell_environment_policy] set` for Codex.
#
# Config (gitignored config/ of the active home):
#   t3code-token      the bearer, one line, mode 0600
#   t3code-instances  optional `harness=instanceId` lines (claude=claudeAgent,
#                     codex=codex by default)
# FM_T3CODE_ORIGIN overrides the origin read from ~/.t3/userdata/server-runtime.json.

FM_BACKEND_T3CODE_MIN_VERSION=0.0.41-nightly.20260914.1707

# Sourced only through fm_backend_source in bin/fm-backend.sh, which owns
# FM_BACKEND_CONFIG_DIR.
fm_backend_t3code_config_dir() {
  printf '%s' "$FM_BACKEND_CONFIG_DIR"
}

fm_backend_t3code_runtime_file() {
  printf '%s/.t3/userdata/server-runtime.json' "${HOME:-}"
}

fm_backend_t3code_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'node' is not installed" >&2; return 1; }
  command -v treehouse >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'treehouse' is not installed" >&2; return 1; }
}

# fm_backend_t3code_api <GET|POST> <path> - one HTTP call against the T3
# server; a POST body is read from stdin. Prints the response body. Exit codes:
# 0 on 2xx, 4 on HTTP 404 (a legitimate "thread gone" answer for probes), 2 on
# a missing token or HTTP 401 (the message names the mint command with the live
# server version), 3 when no origin can be resolved, 1 otherwise. Every failure
# prints one line on stderr carrying the server's JSON `reason` when it sent one.
# shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
FM_BACKEND_T3CODE_API_JS='
const fs = require("fs");
const [method, path] = process.argv.slice(1);
const originEnv = process.env.FM_T3CODE_ORIGIN || "";
const runtimeFile = process.env.FM_T3CODE_RUNTIME_FILE;
const tokenFile = process.env.FM_T3CODE_TOKEN_FILE;
function fail(code, msg) { console.error(msg); process.exit(code); }
let origin = originEnv;
if (!origin) {
  let raw;
  try { raw = fs.readFileSync(runtimeFile, "utf8"); }
  catch (err) { fail(3, `error: backend=t3code cannot find the T3 server origin: ${runtimeFile} is unreadable (${err.message}); start T3 Code so it writes that file, or set FM_T3CODE_ORIGIN`); }
  try { origin = JSON.parse(raw).origin || ""; }
  catch (err) { fail(3, `error: backend=t3code cannot parse ${runtimeFile}: ${err.message}`); }
  if (!origin) fail(3, `error: backend=t3code found no origin in ${runtimeFile}`);
}
origin = origin.replace(/\/+$/, "");
const needsAuth = !path.startsWith("/.well-known/");
async function serverVersion() {
  try {
    const res = await fetch(origin + "/.well-known/t3/environment");
    const data = await res.json();
    return data.serverVersion || "<serverVersion>";
  } catch { return "<serverVersion>"; }
}
async function mintHint() {
  return `mint one with: npx t3@${await serverVersion()} auth session issue --json --ttl 30d --label firstmate` +
    `, then write its token field to ${tokenFile} (mode 0600)`;
}
(async () => {
  const headers = { "content-type": "application/json" };
  if (needsAuth) {
    let token = "";
    try { token = fs.readFileSync(tokenFile, "utf8").trim(); } catch { token = ""; }
    if (!token) fail(2, `error: backend=t3code has no bearer token at ${tokenFile}; ${await mintHint()}`);
    headers.authorization = `Bearer ${token}`;
  }
  const init = { method, headers };
  if (method === "POST") init.body = fs.readFileSync(0, "utf8");
  let res;
  try { res = await fetch(origin + path, init); }
  catch (err) { fail(1, `error: backend=t3code cannot reach the T3 server at ${origin}: ${err.message}; start T3 Code and retry`); }
  const text = await res.text();
  if (res.ok) { process.stdout.write(text); return; }
  let reason = text;
  try { const data = JSON.parse(text); reason = data.reason || data.message || data.code || text; } catch {}
  if (res.status === 401) fail(2, `error: the T3 server rejected the bearer at ${tokenFile} (401: ${reason}); ${await mintHint()}`);
  fail(res.status === 404 ? 4 : 1, `error: T3 ${method} ${path} failed (${res.status}): ${reason}`);
})();
'

fm_backend_t3code_api() {  # <GET|POST> <path>
  FM_T3CODE_RUNTIME_FILE=$(fm_backend_t3code_runtime_file) \
  FM_T3CODE_TOKEN_FILE="$(fm_backend_t3code_config_dir)/t3code-token" \
    node -e "$FM_BACKEND_T3CODE_API_JS" "$1" "$2"
}

# fm_backend_t3code_command <type> [field ...] - build one dispatch body with
# a fresh commandId. `key=value` is a string, `key:=json` is raw JSON, and
# `key=@now` is the current ISO time.
fm_backend_t3code_command() {
  node -e '
const crypto = require("crypto");
const [type, ...fields] = process.argv.slice(1);
const cmd = { type, commandId: crypto.randomUUID() };
for (const field of fields) {
  const eq = field.indexOf("=");
  const raw = field.slice(0, eq).endsWith(":");
  const key = raw ? field.slice(0, eq - 1) : field.slice(0, eq);
  const value = field.slice(eq + 1);
  if (raw) cmd[key] = JSON.parse(value);
  else if (value === "@now") cmd[key] = new Date().toISOString();
  else cmd[key] = value;
}
process.stdout.write(JSON.stringify(cmd));
' "$@"
}

fm_backend_t3code_dispatch() {  # <command-json>
  printf '%s' "$1" | fm_backend_t3code_api POST /api/orchestration/dispatch
}

fm_backend_t3code_uuid() {
  node -e 'process.stdout.write(require("crypto").randomUUID())'
}

fm_backend_t3code_runtime_check() {
  fm_backend_t3code_tool_check || return 1
  local descriptor
  descriptor=$(fm_backend_t3code_api GET /.well-known/t3/environment) || return 1
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$descriptor" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
const min = process.argv[1];
const version = String(data.serverVersion || "");
const parse = (v) => {
  const m = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(v);
  if (!m) return null;
  const pre = m[4] ? m[4].split(".") : [];
  if (pre.some((id) => /^0[0-9]+$/.test(id))) return null;
  return { core: m.slice(1, 4).map(BigInt), pre };
};
const compare = (a, b) => {
  for (let i = 0; i < 3; i++) if (a.core[i] !== b.core[i]) return a.core[i] > b.core[i] ? 1 : -1;
  if (!a.pre.length || !b.pre.length) return Number(!a.pre.length) - Number(!b.pre.length);
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    const x = a.pre[i], y = b.pre[i];
    if (x === y) continue;
    if (x === undefined || y === undefined) return x === undefined ? -1 : 1;
    const xn = /^[0-9]+$/.test(x), yn = /^[0-9]+$/.test(y);
    if (xn !== yn) return xn ? -1 : 1;
    return (xn ? BigInt(x) > BigInt(y) : x > y) ? 1 : -1;
  }
  return 0;
};
const have = parse(version), want = parse(min);
const ok = have && want && compare(have, want) >= 0;
if (!ok) { console.error(`error: backend=t3code requires a T3 server >= ${min}; this one reports ${version || "no version"}; upgrade T3 Code`); process.exit(1); }
if (!(data.capabilities && data.capabilities.threadSettlement === true)) { console.error(`error: backend=t3code requires the threadSettlement capability; T3 ${version} does not report it; upgrade T3 Code`); process.exit(1); }
' "$FM_BACKEND_T3CODE_MIN_VERSION" || return 1
  fm_backend_t3code_api GET /api/orchestration/shell >/dev/null || return 1
}

fm_backend_t3code_project_ensure() {  # <project-path> -> project id
  local project=$1 real shell id title cmd
  real=$(cd "$project" 2>/dev/null && pwd -P) || { echo "error: project path $project is not a directory" >&2; return 1; }
  shell=$(fm_backend_t3code_api GET /api/orchestration/shell) || return 1
  id=$(printf '%s' "$shell" | node -e '
const fs = require("fs");
const want = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const real = (p) => { try { return fs.realpathSync(p); } catch { return p; } };
const hit = (data.projects || []).find((p) => !p.deletedAt && real(p.workspaceRoot) === want);
process.stdout.write(hit ? hit.id : "");
' "$real") || return 1
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  id=$(fm_backend_t3code_uuid) || return 1
  # The fm- prefix keeps firstmate's projects apart from the owner's own T3
  # project names; matching stays by real path, so the title never binds.
  title="fm-$(basename "$real")"
  cmd=$(fm_backend_t3code_command project.create "projectId=$id" "title=$title" "workspaceRoot=$real" createdAt=@now) || return 1
  fm_backend_t3code_dispatch "$cmd" >/dev/null || return 1
  printf '%s' "$id"
}

# The harness -> T3 provider-option id table. Codex takes reasoningEffort and
# refuses max; Claude takes effort up to max. Anything else is not a T3 harness.
fm_backend_t3code_effort_option() {  # <harness> <effort> -> "<option-id> <value>"
  case "$1:$2" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max) printf 'effort %s' "$2" ;;
    codex:low|codex:medium|codex:high|codex:xhigh) printf 'reasoningEffort %s' "$2" ;;
    claude:*|codex:*) echo "error: backend=t3code cannot pass effort '$2' to harness '$1' (claude: low|medium|high|xhigh|max; codex: low|medium|high|xhigh)" >&2; return 1 ;;
    *) echo "error: backend=t3code supports only the claude and codex harnesses, not '$1'" >&2; return 1 ;;
  esac
}

fm_backend_t3code_instance_id() {  # <harness>
  local harness=$1 file line value
  case "$harness" in
    claude) value=claudeAgent ;;
    codex) value=codex ;;
    *) echo "error: backend=t3code supports only the claude and codex harnesses, not '$harness'" >&2; return 1 ;;
  esac
  file="$(fm_backend_t3code_config_dir)/t3code-instances"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$harness="*) value=${line#*=} ;; esac
    done < "$file"
  fi
  [ -n "$value" ] || { echo "error: $file maps harness '$harness' to an empty instance id" >&2; return 1; }
  printf '%s' "$value"
}

fm_backend_t3code_model_selection() {  # <harness> <model> <effort> <project-id> -> JSON
  local harness=$1 model=$2 effort=$3 project_id=$4 instance option='' shell
  instance=$(fm_backend_t3code_instance_id "$harness") || return 1
  if [ "$effort" != default ] && [ -n "$effort" ]; then
    option=$(fm_backend_t3code_effort_option "$harness" "$effort") || return 1
  fi
  if [ "$model" = default ] || [ -z "$model" ]; then
    shell=$(fm_backend_t3code_api GET /api/orchestration/shell) || return 1
    # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
    printf '%s' "$shell" | node -e '
const [projectId, option] = process.argv.slice(1);
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
const project = (data.projects || []).find((p) => p.id === projectId);
const selection = project && project.defaultModelSelection;
if (!selection) { console.error(`error: T3 project ${projectId} has no default model; pass --model with a slug from the T3 model catalog`); process.exit(1); }
const out = { instanceId: selection.instanceId, model: selection.model };
if (option) { const [id, value] = option.split(" "); out.options = [{ id, value }]; }
else if (selection.options !== undefined) out.options = selection.options;
process.stdout.write(JSON.stringify(out));
' "$project_id" "$option"
    return
  fi
  node -e '
const [instanceId, model, option] = process.argv.slice(1);
const out = { instanceId, model };
if (option) { const [id, value] = option.split(" "); out.options = [{ id, value }]; }
process.stdout.write(JSON.stringify(out));
' "$instance" "$model" "$option"
}

# An empty worktree sends worktreePath null, which puts the agent in the
# project's workspaceRoot (a secondmate home); an empty string is an HTTP 400.
fm_backend_t3code_thread_create() {  # <project-id> <title> <branch> <worktree> <model-selection-json> -> thread id
  local project_id=$1 title=$2 branch=$3 worktree=$4 selection=$5 id cmd branch_field worktree_field
  id=$(fm_backend_t3code_uuid) || return 1
  if [ -n "$branch" ]; then branch_field="branch=$branch"; else branch_field='branch:=null'; fi
  if [ -n "$worktree" ]; then worktree_field="worktreePath=$worktree"; else worktree_field='worktreePath:=null'; fi
  cmd=$(fm_backend_t3code_command thread.create "threadId=$id" "projectId=$project_id" "title=$title" \
    "modelSelection:=$selection" runtimeMode=full-access interactionMode=default \
    "$branch_field" "$worktree_field" createdAt=@now) || return 1
  fm_backend_t3code_dispatch "$cmd" >/dev/null || return 1
  printf '%s' "$id"
}

# fm_backend_t3code_thread_for_home <home>: the live T3 thread running the
# firstmate whose home is <home>, for away-mode supervisor discovery. T3 puts
# no thread id into the agent's environment, so the only self-discovery is a
# cwd match: a project whose workspaceRoot is <home> by real path, and on it a
# thread that is not archived, has no worktree of its own (worktreePath null),
# and whose session is starting or running (the daemon is started from inside
# the captain's own turn). Exactly one match prints its id (0); none prints
# nothing (1); more than one is an error naming the ids (2); an unreadable
# server is silent (1) so the caller falls through to its default.
fm_backend_t3code_thread_for_home() {  # <home> -> thread id
  local home=$1 real shell out rc
  real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  shell=$(fm_backend_t3code_api GET /api/orchestration/shell 2>/dev/null) || return 1
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  out=$(printf '%s' "$shell" | node -e '
const fs = require("fs");
const want = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const real = (p) => { try { return fs.realpathSync(p); } catch { return p; } };
const projects = new Set((data.projects || []).filter((p) => !p.deletedAt && real(p.workspaceRoot) === want).map((p) => p.id));
const live = (data.threads || []).filter((t) => projects.has(t.projectId) && !t.archivedAt && t.worktreePath === null
  && t.session && (t.session.status === "starting" || t.session.status === "running")).map((t) => t.id);
if (live.length === 1) { process.stdout.write(live[0]); process.exit(0); }
if (live.length === 0) process.exit(1);
console.error(`error: ${live.length} live T3 threads run in ${want} (${live.join(", ")}); set FM_SUPERVISOR_TARGET to the captain thread id`);
process.exit(2);
' "$real") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || printf '%s' "$out"
  return "$rc"
}

fm_backend_t3code_turn_start() {  # <thread-id> <text> [model-selection-json]
  local thread=$1 text=$2 selection=${3:-} message cmd
  # The brief rides stdin: it is the one value too large to trust to argv.
  message=$(printf '%s' "$text" | node -e '
const crypto = require("crypto");
const text = require("fs").readFileSync(0, "utf8");
process.stdout.write(JSON.stringify({ messageId: crypto.randomUUID(), role: "user", text, attachments: [] }));
') || return 1
  if [ -n "$selection" ]; then
    cmd=$(fm_backend_t3code_command thread.turn.start "threadId=$thread" "message:=$message" "modelSelection:=$selection" \
      runtimeMode=full-access interactionMode=default createdAt=@now) || return 1
  else
    cmd=$(fm_backend_t3code_command thread.turn.start "threadId=$thread" "message:=$message" \
      runtimeMode=full-access interactionMode=default createdAt=@now) || return 1
  fi
  fm_backend_t3code_dispatch "$cmd" >/dev/null
}

fm_backend_t3code_thread_read() {  # <thread-id> <turn-limit>
  fm_backend_t3code_api GET "/api/orchestration/threads/$1?turnLimit=$2"
}

# fm_backend_t3code_probe: one word naming the thread's row in the status
# table: a session status, `archived`, `http-404`, or `http-failure`. A thread
# with no session yet (just created) reads `idle`.
fm_backend_t3code_probe() {  # <thread-id>
  local out rc
  out=$(fm_backend_t3code_thread_read "$1" 1 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0) ;;
    4) printf 'http-404'; return 0 ;;
    *) printf 'http-failure'; return 0 ;;
  esac
  printf '%s' "$out" | node -e '
const t = JSON.parse(require("fs").readFileSync(0, "utf8")).thread || {};
process.stdout.write(t.archivedAt ? "archived" : (t.session && t.session.status) || "idle");
' 2>/dev/null || printf 'http-failure'
}

# The one status table: "<busy_state> <agent_state>" per probe row.
fm_backend_t3code_state_row() {  # <probe-row>
  case "$1" in
    starting|running) printf 'busy alive' ;;
    ready|idle|interrupted) printf 'idle alive' ;;
    stopped) printf 'idle dead' ;;
    error) printf 'unknown dead' ;;
    archived|http-404) printf 'unknown missing' ;;
    *) printf 'unknown unreadable' ;;
  esac
}

fm_backend_t3code_busy_state() {  # <thread-id>
  local row
  row=$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$1")")
  printf '%s' "${row%% *}"
}

fm_backend_t3code_agent_state() {  # <thread-id>
  local row
  row=$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$1")")
  printf '%s' "${row#* }"
}

fm_backend_t3code_target_exists() {  # <thread-id>
  case "$(fm_backend_t3code_agent_state "$1")" in
    alive|dead) return 0 ;;
  esac
  return 1
}

# T3 has no composer to clear, so a live thread is always ready for a steer.
fm_backend_t3code_composer_state() {  # <thread-id> [expected-label] -> empty|unknown
  case "$(fm_backend_t3code_probe "$1")" in
    archived|http-404|http-failure) printf 'unknown' ;;
    *) printf 'empty' ;;
  esac
}

fm_backend_t3code_capture() {  # <thread-id> <lines>
  local thread=$1 lines=${2:-40} out
  out=$(fm_backend_t3code_thread_read "$thread" 5) || return 1
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const t = JSON.parse(require("fs").readFileSync(0, "utf8")).thread || {};
const lines = (t.messages || []).map((m) => `[${m.role}] ${m.text}`);
const session = t.archivedAt ? "archived" : (t.session && t.session.status) || "none";
lines.push(`t3code: session=${session} turn=${(t.latestTurn && t.latestTurn.state) || "none"}`);
process.stdout.write(lines.join("\n"));
' | tail -n "$lines"
}

fm_backend_t3code_send_text_submit() {  # <thread-id> <text> <retries> <enter-sleep> <settle>
  if fm_backend_t3code_turn_start "$1" "$2"; then
    printf 'empty'
  else
    printf 'send-failed'
  fi
}

fm_backend_t3code_send_key() {  # <thread-id> <key>
  local thread=$1 key=$2 cmd
  case "$key" in
    Escape|escape|Esc|esc|C-c|ctrl+c|Ctrl-c|Ctrl-C)
      cmd=$(fm_backend_t3code_command thread.turn.interrupt "threadId=$thread" createdAt=@now) || return 1
      fm_backend_t3code_dispatch "$cmd" >/dev/null
      ;;
    Enter|enter) return 0 ;;
    *)
      echo "error: unsupported T3 key '$key'" >&2
      return 1
      ;;
  esac
}

# Stop the session and leave the thread where it is: the control plane's
# `exit`. T3 has no composer to type an exit command into, and a stopped
# session reads `stopped` (dead) in the status table, which is the proof the
# control plane waits for. A later turn restarts the same agent with its
# transcript (verified live; docs/verification/runtime-backends.md "T3 Code").
# Idempotent: a thread with no session to stop is already the end state.
fm_backend_t3code_agent_stop() {  # <thread-id>
  local cmd rc
  cmd=$(fm_backend_t3code_command thread.session.stop "threadId=$1" createdAt=@now) || return 1
  fm_backend_t3code_dispatch "$cmd" >/dev/null && rc=0 || rc=$?
  case "$rc" in 0|4) return 0 ;; *) return 1 ;; esac
}

# Stop the session, then archive the thread so it can never re-create its
# worktree at a returned slot. Archiving keeps the transcript visible in T3.
# Idempotent: an archived or deleted thread is already the end state.
fm_backend_t3code_kill() {  # <thread-id>
  local thread=$1 cmd rc
  case "$(fm_backend_t3code_probe "$thread")" in
    archived|http-404) return 0 ;;
  esac
  fm_backend_t3code_agent_stop "$thread" || return 1
  cmd=$(fm_backend_t3code_command thread.archive "threadId=$thread") || return 1
  fm_backend_t3code_dispatch "$cmd" >/dev/null && rc=0 || rc=$?
  case "$rc" in 0|4) return 0 ;; *) return 1 ;; esac
}

# Native shell stream, bounded by the watcher's existing poll budget. Node's
# built-in WebSocket is optional: an older Node retains the HTTP poll path.
fm_backend_t3code_events_capable() {  # [session]
  node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null || return 1
  fm_backend_t3code_runtime_check >/dev/null 2>&1
}

fm_backend_t3code_event_reader_cmd() {
  printf 'node\n%s/t3code-eventwait.cjs\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

# The stream carries the same session row as HTTP plus explicit pending-human
# flags. Only those flags add blocked; a stopped/error/absent thread cannot
# become actionable merely because an old request flag survived.
fm_backend_t3code_normalize_event() {  # <thread> <project> <session-status> <pending> <instance>
  local state row
  row=$(fm_backend_t3code_state_row "$3")
  case "$row" in
    'busy alive') state=working ;;
    'idle alive') state=idle ;;
    *) state=unknown ;;
  esac
  if [ "${row#* }" = alive ] && [ "$4" = true ]; then state=blocked; fi
  fm_transition_record "$1" "$2" '' "$state" "$5"
}

fm_backend_t3code_escalation_marker() {  # <state-dir> <thread>
  printf '%s/.t3code-escalated-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

fm_backend_t3code_commit_transition() {  # <state-dir> <session> <record>
  local thread
  thread=$(fm_transition_pane_id "$3")
  [ -n "$thread" ] || return 1
  : > "$(fm_backend_t3code_escalation_marker "$1" "$thread")"
}

fm_backend_t3code_clear_transition() {  # <state-dir> <thread>
  [ -n "$2" ] || return 0
  rm -f "$(fm_backend_t3code_escalation_marker "$1" "$2")"
}

# Returns 0 with one normalized actionable record, 1 after a clean full-budget
# wait, or 2 for polling fallback. Snapshot rows reconcile reconnect gaps;
# dedupe is committed only after the watcher durably queues the wake.
fm_backend_t3code_wait_transition() {  # <session> <timeout> <state-dir> <thread...>
  local timeout=$2 state=$3
  shift 3
  [ "$#" -gt 0 ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_t3code_events_capable || return 2
  fi
  # shellcheck source=bin/fm-transition-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../fm-transition-lib.sh"
  local reader=() word dir pid line record marker action rc=1 reader_rc=0
  while IFS= read -r word; do reader+=("$word"); done < <(fm_backend_t3code_event_reader_cmd)
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3code-eventwait.XXXXXX") || return 2
  mkfifo "$dir/events" || { rmdir "$dir"; return 2; }
  FM_T3CODE_RUNTIME_FILE=$(fm_backend_t3code_runtime_file) \
  FM_T3CODE_TOKEN_FILE="$(fm_backend_t3code_config_dir)/t3code-token" \
    "${reader[@]}" "$timeout" "$@" > "$dir/events" 2>/dev/null &
  pid=$!
  exec 9< "$dir/events"
  if ! IFS= read -r line <&9 || [ "$line" != subscribed ]; then rc=2; fi
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    record=$(fm_backend_t3code_normalize_event \
      "$(printf '%s' "$line" | cut -f1)" "$(printf '%s' "$line" | cut -f2)" \
      "$(printf '%s' "$line" | cut -f3)" "$(printf '%s' "$line" | cut -f4)" \
      "$(printf '%s' "$line" | cut -f5)")
    marker=$(fm_backend_t3code_escalation_marker "$state" "$(fm_transition_pane_id "$record")")
    action=$(fm_transition_policy "$(fm_transition_to_status "$record")")
    case "$action" in
      actionable)
        if [ ! -e "$marker" ]; then printf '%s' "$record"; rc=0; fi
        ;;
      absorb) rm -f "$marker" ;;
    esac
  done
  if [ "$rc" -ne 1 ]; then kill "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$dir"
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 2 ] && [ "$reader_rc" -eq 0 ] && return 1
  return 2
}

fm_backend_t3code_validate_harness() {  # <harness>
  case "$1" in
    claude|codex) return 0 ;;
    *) echo "error: backend=t3code runs only the claude and codex harnesses, not '$1'" >&2; return 1 ;;
  esac
}

# There is no pane: bin/fm-spawn.sh's launch-time typing helpers land here.
fm_backend_t3code_send_literal() {
  echo "error: backend=t3code has no pane to type into" >&2
  return 1
}
