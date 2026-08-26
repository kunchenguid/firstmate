#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. send_key delivers
# only Enter and Ctrl-C: `terminal send --text` can carry a raw ESC byte, but a
# lone ESC is not a verified turn-cancel on Orca (its agent model does not even
# observe it - docs/orca-backend.md "Active limits"), so Escape is deliberately
# not mapped as a control-plane interrupt.
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

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
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
# capability model in bin/fm-composer-lib.sh). Real smoke against Orca v1.4.188
# (2026-08-26) proved `orca terminal read --json` returns a plain-text tail with
# no ANSI escapes, so styled=0 reflects Orca's actual behavior, not a
# conservative fallback (see docs/verification/runtime-backends.md "Orca").
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

# fm_backend_orca_agent_tracked_harness: whether Orca populates its structured
# `worktree ps` agents[] model for <harness>. Orca tracks an agent through a
# per-harness hook, and it ships hooks for exactly claude and codex
# (`~/.orca/agent-hooks/` holds claude-hook.sh and codex-hook.sh only; a live pi
# produced zero agents[] entries - verified v1.4.188). For a tracked harness the
# agent's presence and disappearance are observable, so agents[] is recovery
# grade; for any other harness Orca gives no structured agent signal, so
# agents[]-absence must NOT be read as `dead`. Matches the recorded basename the
# same prefix way bin/fm-control-lib.sh's fm_control_harness_family does.
fm_backend_orca_agent_tracked_harness() {  # <harness>
  case "${1-}" in
    claude*|codex*) return 0 ;;
  esac
  return 1
}

# fm_backend_orca_probe: correlate one terminal's endpoint liveness with Orca's
# own structured agent model in a single pass. Prints "<endpoint> <agent>":
#   endpoint - alive|dead|no-agent|missing|ambiguous|unreadable.
#   agent    - the Orca `worktree ps` agents[] `state` for this exact pane
#              (working|done|blocked|...), or "-" when no agent entry applies.
# `dead` is a confidently gone endpoint (disconnected or exited); `no-agent` is
# a still-connected terminal with no agents[] entry for its pane - which means
# "agent exited to a shell" ONLY for an Orca-tracked harness, and "Orca does not
# track this harness" otherwise. fm_backend_orca_agent_state resolves that with
# the harness; the probe stays harness-blind.
# The correlation key is the pane key `tabId:leafId`, which `terminal show` and
# `worktree ps` agents[] share. That structured array - not a rendered title or
# `terminal wait --for tui-idle`, which cannot separate a busy agent from a
# plain shell because both simply time out - is Orca's only agent-presence
# signal, and it exists only for tracked harnesses. Verified against Orca
# v1.4.188 (docs/verification/runtime-backends.md "Orca").
# One `terminal show` plus one `worktree ps`, reduced in one Node pass; the
# 0x1e record separator joins the two payloads without colliding with JSON.
fm_backend_orca_probe() {  # <terminal-id> -> "<endpoint> <agent>"
  local terminal=$1 show ps
  command -v orca >/dev/null 2>&1 || { printf 'unreadable -'; return 0; }
  # `orca terminal show` exits non-zero for a stale handle but still prints the
  # `ok:false` body carrying `terminal_handle_stale`, which the reducer needs to
  # tell `missing` (gone endpoint) from `unreadable` (transient failure). Keep
  # the body regardless of exit code and treat only an empty read as unreadable.
  show=$(orca terminal show --terminal "$terminal" --json 2>/dev/null)
  [ -n "$show" ] || { printf 'unreadable -'; return 0; }
  ps=$(orca worktree ps --json 2>/dev/null || true)
  printf '%s\x1e%s' "$show" "$ps" | node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8");
const sep = raw.indexOf("\x1e");
const showRaw = sep < 0 ? raw : raw.slice(0, sep);
const psRaw = sep < 0 ? "" : raw.slice(sep + 1);
let show;
try { show = JSON.parse(showRaw); } catch (e) { process.stdout.write("unreadable -"); process.exit(0); }
if (show.ok === false) {
  const code = show.error && show.error.code;
  if (code === "terminal_handle_stale" || code === "tab_not_found") process.stdout.write("missing -");
  else process.stdout.write("unreadable -");
  process.exit(0);
}
const t = show.result && show.result.terminal;
if (!t) { process.stdout.write("unreadable -"); process.exit(0); }
// A closed or exited endpoint is confidently agent-free.
if (t.connected === false || t.exitCause) { process.stdout.write("dead -"); process.exit(0); }
// Only a positively connected endpoint can be attributed further.
if (t.connected !== true) { process.stdout.write("ambiguous -"); process.exit(0); }
if (!t.tabId || !t.leafId) { process.stdout.write("ambiguous -"); process.exit(0); }
const paneKey = t.tabId + ":" + t.leafId;
let ps;
try { ps = JSON.parse(psRaw); } catch (e) { process.stdout.write("unreadable -"); process.exit(0); }
if (!ps || ps.ok === false || !ps.result || !Array.isArray(ps.result.worktrees)) {
  // Endpoint is connected but the agent model could not be read, so agent
  // presence cannot be proven either way.
  process.stdout.write("unreadable -");
  process.exit(0);
}
let agent = null;
for (const w of ps.result.worktrees) {
  for (const a of (w.agents || [])) {
    if (a && a.paneKey === paneKey) agent = a;
  }
}
if (!agent) {
  // Connected terminal with no agents[] entry. Whether this is "agent exited to
  // a shell" (dead) or "Orca does not track this harness" is harness-dependent,
  // so leave it to fm_backend_orca_agent_state.
  process.stdout.write("no-agent -");
  process.exit(0);
}
const st = (typeof agent.state === "string" && agent.state) ? agent.state : "unknown";
process.stdout.write("alive " + st);
'
}

# fm_backend_orca_agent_state: the recovery-grade endpoint classifier for one
# recorded terminal (see bin/fm-backend.sh fm_backend_agent_state for the shared
# vocabulary). Recovery grade ONLY for an Orca-tracked harness (claude, codex),
# whose agents[] entry disappearing proves the agent stopped. For any other
# harness - or when the harness is unknown - a still-connected terminal with no
# agents[] entry is NOT proof of death (Orca just does not track it), so it is
# reported `unverified` rather than a false `dead`. `alive` (an agents[] entry
# is present) and the terminal-level `dead`/`missing` verdicts are
# harness-independent.
fm_backend_orca_agent_state() {  # <terminal-id> [harness] -> alive|dead|missing|ambiguous|unreadable|unverified
  local probe endpoint
  probe=$(fm_backend_orca_probe "$1") || { printf 'unreadable'; return 0; }
  endpoint=${probe%% *}
  if [ "$endpoint" = no-agent ]; then
    if fm_backend_orca_agent_tracked_harness "${2-}"; then
      printf 'dead'
    else
      printf 'unverified'
    fi
    return 0
  fi
  printf '%s' "$endpoint"
}

# fm_backend_orca_busy_state: semantic busy state from Orca's native agent
# model. Only a positively connected endpoint carrying a live agent entry has a
# busy verdict; a `working` turn is busy, a settled `done` turn is idle, a
# `blocked` agent (a trust or update modal) is blocked, and anything else -
# including an endpoint with no agent - is unknown. The fleet-wide busy fold
# (bin/fm-busy-lib.sh fm_busy_classify) trusts only the BUSY verdict as a
# fallback, matching the herdr-native contract.
fm_backend_orca_busy_state() {  # <terminal-id> -> busy|idle|blocked|unknown
  local probe
  probe=$(fm_backend_orca_probe "$1") || { printf 'unknown'; return 0; }
  [ "${probe%% *}" = alive ] || { printf 'unknown'; return 0; }
  case "${probe#* }" in
    working) printf 'busy' ;;
    done) printf 'idle' ;;
    blocked) printf 'blocked' ;;
    *) printf 'unknown' ;;
  esac
}

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
