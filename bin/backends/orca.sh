#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape and Ctrl-U
# are delivered as their raw --text control bytes (verified live); see
# fm_backend_orca_send_key.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
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

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
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
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

# --- Orca-managed secondmate home lifecycle ----------------------------------
#
# An Orca terminal can only be created inside an Orca-MANAGED worktree (verified:
# terminal create against a plain checkout, or one merely `repo add`ed or
# imported with `project setup-existing-folder`, fails selector_not_found). A
# secondmate home must therefore be an Orca-managed worktree. Orca places
# worktrees under the project setup's worktree base path; firstmate points that
# base OUTSIDE the firstmate repo so the home-isolation invariant in fm-spawn.sh
# (a secondmate home cannot live inside the firstmate repo) still holds. The home
# path is authoritative: its Orca worktree id is `<repo-id>::<path>` and stays
# re-resolvable from the path, so no extra durable id is stored for the home.

# fm_backend_orca_home_base_path: the firstmate-owned directory OUTSIDE any
# firstmate repo where Orca places firstmate-repo worktrees used as secondmate
# homes. Overridable for tests.
fm_backend_orca_home_base_path() {
  printf '%s' "${FM_ORCA_HOME_BASE:-${HOME:-/tmp}/.firstmate-orca-homes}"
}

# fm_backend_orca_setup_base_path_get: the worktree base path currently recorded
# for <setup-id>, or empty when unset. Read-only.
fm_backend_orca_setup_base_path_get() {  # <setup-id>
  fm_backend_orca_tool_check || return 1
  orca project setups --json 2>/dev/null | node -e '
const fs = require("fs");
const setup = process.argv[1];
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(0); }
const arr = (data.result && (data.result.setups || data.result.items)) || [];
let v = "";
for (const s of arr) {
  if (s && s.id === setup) { v = String(s.worktreeBasePath || ""); break; }
}
process.stdout.write(v);
' "$1"
}

# fm_backend_orca_ensure_home_base_path: make the firstmate project setup place
# its worktrees at the external home base path. Idempotent: writes only when the
# recorded value differs. Prints the resolved base path.
fm_backend_orca_ensure_home_base_path() {  # <setup-id>
  local setup=$1 base current
  base=$(fm_backend_orca_home_base_path)
  mkdir -p "$base" 2>/dev/null || true
  current=$(fm_backend_orca_setup_base_path_get "$setup" 2>/dev/null || true)
  if [ "$current" != "$base" ]; then
    fm_backend_orca_run_json orca project setup-update --setup "$setup" --worktree-base-path "$base" --json || return 1
  fi
  printf '%s' "$base"
}

# fm_backend_orca_home_create: create an Orca-managed worktree of the firstmate
# repo to host a secondmate home, at the external base path. Prints the home path.
fm_backend_orca_home_create() {  # <project-path> <name>
  local project=$1 name=$2 setup out wt_path
  setup=$(fm_backend_orca_repo_ensure "$project") || return 1
  fm_backend_orca_ensure_home_base_path "$setup" >/dev/null || return 1
  out=$(orca worktree create --repo "id:$setup" --name "$name" --no-parent --setup skip --json) || return 1
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for home $name" >&2
    return 1
  }
  printf '%s' "$wt_path"
}

# fm_backend_orca_home_terminal_create: a terminal inside an existing Orca-managed
# home worktree, addressed by its path. Prints the terminal handle.
fm_backend_orca_home_terminal_create() {  # <home-path> <title>
  local home=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "path:$home" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for home $home" >&2
    return 1
  }
  printf '%s' "$terminal"
}

# fm_backend_orca_home_remove: release a secondmate home worktree by path. The
# worktree id embeds the path, so path: addressing is exact.
fm_backend_orca_home_remove() {  # <home-path>
  local home=${1:-}
  [ -n "$home" ] || { echo "error: missing Orca home path; cannot remove home worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "path:$home" --force --json
}

# fm_backend_orca_worktree_id_for_path: resolve an Orca-managed worktree's id
# from its path. Used to record a secondmate home's orca_worktree_id in metadata
# without storing it separately at seed time.
fm_backend_orca_worktree_id_for_path() {  # <path>
  local path=${1:-} out id
  [ -n "$path" ] || { echo "error: missing path; cannot resolve Orca worktree id" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "path:$path" --json) || return 1
  id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree show did not return an id for $path" >&2
    return 1
  }
  printf '%s' "$id"
}

# --- native agent status (busy/idle + recovery-grade liveness) ---------------
#
# Orca's agent-status hooks post working|done|blocked to the runtime (the
# authoritative vocabulary, taken from Orca's own hook source), surfaced per
# worktree in `worktree ps agents[].state`. `terminal list` maps a task's
# terminal handle to its worktree and carries connected/orphaned/agentIdentity.
# A firstmate task owns exactly one terminal in one worktree, so at most one
# agent is correlated; if several are present the most-active state wins.

# fm_backend_orca_agent_snapshot: prints "liveness=<alive|dead|missing|ambiguous|unreadable> state=<working|done|blocked|none>".
fm_backend_orca_agent_snapshot() {  # <terminal-handle>
  local terminal=$1 tlist wps
  fm_backend_orca_tool_check || { printf 'liveness=unreadable state=none'; return 0; }
  tlist=$(orca terminal list --json 2>/dev/null) || { printf 'liveness=unreadable state=none'; return 0; }
  wps=$(orca worktree ps --json 2>/dev/null || printf '{}')
  FM_ORCA_TL="$tlist" FM_ORCA_WP="$wps" node -e '
const handle = process.argv[1];
let tl, wp;
try { tl = JSON.parse(process.env.FM_ORCA_TL || ""); }
catch (e) { process.stdout.write("liveness=unreadable state=none"); process.exit(0); }
if (tl && tl.ok === false) { process.stdout.write("liveness=unreadable state=none"); process.exit(0); }
try { wp = JSON.parse(process.env.FM_ORCA_WP || "{}"); } catch (e) { wp = {}; }
if (wp && wp.ok === false) wp = {};
const terms = (tl.result && tl.result.terminals) || [];
const t = terms.find(x => x && x.handle === handle);
if (!t) { process.stdout.write("liveness=missing state=none"); process.exit(0); }
const wtId = t.worktreeId || "";
const rank = { working: 3, blocked: 2, done: 1 };
let best = "none", bestRank = 0, hasAgent = false;
for (const w of ((wp.result && wp.result.worktrees) || [])) {
  if ((w.worktreeId || "") !== wtId) continue;
  for (const a of (w.agents || [])) {
    hasAgent = true;
    const r = rank[a.state] || 0;
    if (r > bestRank) { bestRank = r; best = a.state; }
  }
}
if (t.agentIdentity) hasAgent = true;
const down = (t.orphaned === true) || (t.connected === false);
let liveness;
if (hasAgent) liveness = "alive";
else if (down) liveness = "dead";
else liveness = "ambiguous";
process.stdout.write("liveness=" + liveness + " state=" + best);
' "$terminal"
}

# fm_backend_orca_busy_state: native busy/idle. working -> busy; done or blocked
# -> idle (an agent between turns or parked on a prompt is not mid-turn);
# anything unresolved -> unknown, so the caller falls back to the harness
# adapter's own lifecycle record.
fm_backend_orca_busy_state() {  # <terminal-handle>
  case "$(fm_backend_orca_agent_snapshot "$1")" in
    *"state=working"*) printf 'busy' ;;
    *"state=done"*|*"state=blocked"*) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_orca_agent_state: recovery-grade endpoint classifier (see the
# shared vocabulary in bin/fm-backend.sh). Only `dead` and `missing` license
# recovery; a connected terminal with no attributable agent stays `ambiguous`.
fm_backend_orca_agent_state() {  # <terminal-handle>
  case "$(fm_backend_orca_agent_snapshot "$1")" in
    *"liveness=missing"*) printf 'missing' ;;
    *"liveness=dead"*) printf 'dead' ;;
    *"liveness=alive"*) printf 'alive' ;;
    *"liveness=unreadable"*) printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_orca_capture: a bounded RENDERED-screen read of the live terminal.
# --screen is required: Orca's default stream mode returns accumulated output
# with repaints stacked into fragments (its own read docs call the default
# "unsuitable for verifying rendered output"), which garbled every TUI composer
# read the classifier depends on. --screen returns what the terminal actually
# renders; when no screen can be rendered Orca reports source=screen-unavailable
# and returns the accumulated tail instead, which fm_backend_orca_json_text
# still consumes. Verified live against Orca 1.4.x.
fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --screen --json) || return 1
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

# fm_backend_orca_send_key: one named special key.
# C-c uses Orca's dedicated --interrupt (SIGINT-style) primitive. Enter is an
# empty --enter send. Escape and C-u are delivered as their raw control bytes
# through --text, which passes bytes straight to the PTY (verified live: an ESC
# byte reaches a `cat -v` as ^[, and a C-u byte performs the tty line-kill).
# This matters because --interrupt is NOT a substitute for Escape: every
# harness except grok cancels a turn with Escape, not Ctrl-C (bin/fm-control-lib.sh),
# so aliasing them would mis-fire (e.g. exit Claude instead of interrupting it).
fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    Escape|escape|Esc|esc)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$(printf '\033')" --json
      ;;
    C-u|ctrl+u|Ctrl-u|Ctrl-U)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$(printf '\025')" --json
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

fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 0
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
