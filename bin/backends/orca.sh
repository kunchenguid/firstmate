#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.
#
# Optional paired-environment targeting:
#   config/orca-environment  one line: environment display name or id from
#                            `orca environment list` (local gitignored)
#   FM_ORCA_ENVIRONMENT      spawn-time override of that config value
#   FM_ORCA_TASK_ENVIRONMENT per-task binding from meta orca_environment=;
#                            wins over config for every CLI call once set
# Local (unset) keeps today's path-based repo ensure on the default runtime.
# A configured environment creates via --project + --host runtime:<id> because
# the local Mac path is not the remote checkout path.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

# Prefer the same config root fm-backend.sh already resolved for config/backend.
FM_ORCA_CONFIG_DIR="${FM_BACKEND_CONFIG_DIR:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}}/config}}"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

# fm_backend_orca_configured_environment: spawn-time preference only.
# Empty means the default local Orca runtime.
fm_backend_orca_configured_environment() {
  local raw path line
  if [ -n "${FM_ORCA_ENVIRONMENT+x}" ]; then
    raw=$FM_ORCA_ENVIRONMENT
  else
    path="$FM_ORCA_CONFIG_DIR/orca-environment"
    [ -f "$path" ] || return 0
    line=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|\#*) continue ;;
      esac
      raw=$line
      break
    done < "$path"
  fi
  raw=${raw#"${raw%%[![:space:]]*}"}
  raw=${raw%"${raw##*[![:space:]]}"}
  case "$raw" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*)
      echo "error: config/orca-environment must be one single-line environment name or id" >&2
      return 1
      ;;
  esac
  printf '%s' "$raw"
}

# Active environment for CLI calls: task binding first, then spawn config.
fm_backend_orca_active_environment() {
  if [ -n "${FM_ORCA_TASK_ENVIRONMENT+x}" ]; then
    printf '%s' "$FM_ORCA_TASK_ENVIRONMENT"
    return 0
  fi
  fm_backend_orca_configured_environment
}

# Run orca with optional --environment for the active paired runtime.
fm_backend_orca_cli() {
  local env
  env=$(fm_backend_orca_active_environment) || return 1
  if [ -n "$env" ]; then
    orca --environment "$env" "$@"
  else
    orca "$@"
  fi
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out env
  env=$(fm_backend_orca_configured_environment) || return 1
  if [ -n "$env" ]; then
    out=$(orca --environment "$env" status --json 2>/dev/null) || {
      echo "error: backend=orca selected for environment '$env' but 'orca status --json' failed; start that Orca runtime and wait for it to be ready" >&2
      return 1
    }
  else
    out=$(orca status --json 2>/dev/null) || {
      echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
      return 1
    }
  fi
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

# Resolve github:owner/repo from a local clone's origin URL for remote creates.
fm_backend_orca_project_id_from_path() {  # <project-path>
  local project=$1 url
  [ -d "$project" ] || {
    echo "error: Orca project path is not a directory: $project" >&2
    return 1
  }
  url=$(git -C "$project" remote get-url origin 2>/dev/null) || {
    echo "error: cannot resolve Orca project id; $project has no git origin remote" >&2
    return 1
  }
  printf '%s' "$url" | node -e '
const fs = require("fs");
let url = fs.readFileSync(0, "utf8").trim();
url = url.replace(/\.git$/i, "");
let m = url.match(/github\.com[:/]([^/]+)\/([^/]+)$/i);
if (m) {
  process.stdout.write("github:" + m[1] + "/" + m[2]);
  process.exit(0);
}
m = url.match(/^git@([^:]+):([^/]+)\/([^/]+)$/i);
if (m && /github/i.test(m[1])) {
  process.stdout.write("github:" + m[2] + "/" + m[3]);
  process.exit(0);
}
console.error("error: cannot derive an Orca project id from origin remote: " + url + "; expected a github.com remote when config/orca-environment is set");
process.exit(1);
'
}

# Map config name/id to the paired environment id for --host runtime:<id>.
fm_backend_orca_resolve_environment_id() {  # <name-or-id>
  local want=$1 out
  fm_backend_orca_tool_check || return 1
  out=$(orca environment list --json 2>/dev/null) || {
    echo "error: orca environment list failed while resolving '$want'" >&2
    return 1
  }
  printf '%s' "$out" | node -e '
const fs = require("fs");
const want = process.argv[1];
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca environment list JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: orca environment list failed" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const envs = (data.result && data.result.environments) || data.environments || [];
const match = envs.find((e) => e && (e.id === want || e.name === want));
if (!match || !match.id) {
  console.error("error: Orca environment " + JSON.stringify(want) + " is not paired on this host; run orca environment list");
  process.exit(1);
}
process.stdout.write(String(match.id));
' "$want"
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(fm_backend_orca_cli repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal env env_id project_id
  env=$(fm_backend_orca_configured_environment) || return 1
  if [ -n "$env" ]; then
    # Task ops after spawn bind from meta; seed the active env for create/cleanup.
    export FM_ORCA_TASK_ENVIRONMENT=$env
    env_id=$(fm_backend_orca_resolve_environment_id "$env") || return 1
    project_id=$(fm_backend_orca_project_id_from_path "$project") || return 1
    out=$(fm_backend_orca_cli worktree create       --project "$project_id"       --host "runtime:$env_id"       --name "$name"       --no-parent       --setup skip       --json) || return 1
  else
    repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
    out=$(fm_backend_orca_cli worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  fi
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_cli terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
