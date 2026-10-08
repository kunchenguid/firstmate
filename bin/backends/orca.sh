#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.
# Send and send-key keep that id when it is live, so a healthy record is unchanged.
# A stale id is resolved at send time from the recorded window= alias, read-only:
# Orca does not accept a window title as --terminal, and `terminal list
# --worktree name:<window>` is the native selector because spawn stores that
# same alias as the worktree display name. Nothing here rewrites meta.
# A miss keeps today's failed send.

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

# fm_backend_orca_state_dir: the home whose meta names window= for a stale
# terminal. FM_STATE_OVERRIDE wins, matching fm-send; otherwise FM_HOME/state.
# Absent config means no resolution, which is today's failed send.
fm_backend_orca_state_dir() {
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$FM_STATE_OVERRIDE"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ]; then
    printf '%s/state' "$FM_HOME"
    return 0
  fi
  return 1
}

# Local reader so this adapter can resolve a window when sourced alone.
# fm_meta_get in bin/fm-backend.sh is the shared owner when the dispatcher
# has already loaded it; the two must keep the last-value rule.
fm_backend_orca_meta_value() {  # <file> <key>
  local file=$1 key=$2 line value=''
  if type fm_meta_get >/dev/null 2>&1; then
    value=$(fm_meta_get "$file" "$key")
    [ -n "$value" ] || return 1
    printf '%s' "$value"
    return 0
  fi
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$file"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# The window= alias recorded beside this terminal id, or failure when none
# or more than one distinct alias claims it. Never writes the meta file.
fm_backend_orca_window_for_terminal() {  # <terminal-id>
  local state meta term window found=''
  state=$(fm_backend_orca_state_dir) || return 1
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    term=$(fm_backend_orca_meta_value "$meta" terminal) || continue
    [ "$term" = "$1" ] || continue
    window=$(fm_backend_orca_meta_value "$meta" window) || continue
    if [ -n "$found" ] && [ "$found" != "$window" ]; then
      return 1
    fi
    found=$window
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

fm_backend_orca_attempt() {  # orca argv... ; 0 on accepted JSON, else stored diagnostics
  local out rc=0 errfile jok_err
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-orca-attempt.XXXXXX") || return 1
  out=$("$@" 2>"$errfile") || rc=$?
  FM_ORCA_LAST_STDOUT=$out
  if [ "$rc" -eq 0 ]; then
    jok_err=$(mktemp "${TMPDIR:-/tmp}/fm-orca-json.XXXXXX") || {
      rm -f "$errfile"
      return 1
    }
    if printf '%s' "$out" | fm_backend_orca_json_ok 2>"$jok_err"; then
      rm -f "$errfile" "$jok_err"
      FM_ORCA_LAST_STDERR=
      FM_ORCA_LAST_RC=0
      return 0
    else
      # An if whose condition fails is itself status 0, so the failure has to
      # be read inside else or a stale handle looks accepted.
      rc=$?
    fi
    FM_ORCA_LAST_STDERR=$(cat "$jok_err")
    rm -f "$jok_err"
  else
    FM_ORCA_LAST_STDERR=$(cat "$errfile")
  fi
  rm -f "$errfile"
  FM_ORCA_LAST_RC=$rc
  return "$rc"
}

fm_backend_orca_json_is_stale() {
  node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8").trim();
if (!raw) process.exit(1);
let data;
try { data = JSON.parse(raw); } catch (err) { process.exit(1); }
if (data.ok !== false) process.exit(1);
const err = data.error || {};
const code = String(err.code || "");
const msg = String(err.message || "");
if (code === "terminal_handle_stale" || code === "terminal_not_writable" || msg.indexOf("terminal_handle_stale") !== -1 || msg.indexOf("terminal handle stale") !== -1 || msg.indexOf("terminal_not_writable") !== -1) {
  process.exit(0);
}
process.exit(1);
'
}

fm_backend_orca_last_stale() {
  if printf '%s' "${FM_ORCA_LAST_STDOUT:-}" | fm_backend_orca_json_is_stale; then
    return 0
  fi
  case "${FM_ORCA_LAST_STDERR:-}" in
    *terminal_handle_stale*|*"terminal handle stale"*|*terminal_not_writable*) return 0 ;;
  esac
  return 1
}

fm_backend_orca_replay_last() {
  if [ -n "${FM_ORCA_LAST_STDERR:-}" ]; then
    printf '%s' "$FM_ORCA_LAST_STDERR" >&2
  fi
  return "${FM_ORCA_LAST_RC:-1}"
}

fm_backend_orca_pick_terminal() {
  node -e '
const fs = require("fs");
const stale = process.argv[1];
const raw = fs.readFileSync(0, "utf8").trim();
if (!raw) process.exit(1);
let data;
try { data = JSON.parse(raw); } catch (err) { process.exit(1); }
if (!data || data.ok === false) process.exit(1);
const result = data.result || {};
if (result.truncated === true) process.exit(1);
const terms = Array.isArray(result.terminals) ? result.terminals : [];
function usable(term) {
  if (!term || typeof term.handle !== "string" || !term.handle) return false;
  if (/[\s]/.test(term.handle) || term.handle === stale) return false;
  if (term.orphaned === true || term.connected === false || term.writable === false) return false;
  return true;
}
const live = terms.filter(usable);
if (live.length === 1) {
  process.stdout.write(live[0].handle);
  process.exit(0);
}
process.exit(1);
' "$1"
}

fm_backend_orca_resolve_live_terminal() {  # <stale-terminal-id>
  local stale=$1 window named_json
  window=$(fm_backend_orca_window_for_terminal "$stale") || return 1
  case "$window" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  named_json=$(orca terminal list --worktree "name:$window" --limit 200 --json 2>/dev/null) || return 1
  printf '%s' "$named_json" | fm_backend_orca_pick_terminal "$stale"
}

fm_backend_orca_check_replacement() {
  local cap dialog cstate
  if ! cap=$(fm_backend_orca_composer_capture "$1" 2>/dev/null); then
    if [ -n "${FM_TASK_INBOX_RING_LINE:-}" ]; then
      FM_ORCA_RESOLVED_TERMINAL=$1
      return 4
    fi
    return 0
  fi
  if dialog=$(fm_composer_blocking_dialog "$cap"); then
    echo "error: blocked on a prompt: $dialog" >&2
    return 1
  fi
  if [ -n "${FM_TASK_INBOX_RING_LINE:-}" ]; then
    cstate=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
    # The old endpoint's advisory read cannot authorize replacement input.
    # Unknown content must wait for a later ring, never receive text or Enter.
    case "$cstate" in
      empty|pending) ;;
      *) FM_ORCA_RESOLVED_TERMINAL=$1; return 4 ;;
    esac
    if printf '%s' "$cap" | fm_busy_lines_match \
       || [ "$(fm_backend_busy_state orca "$1" 2>/dev/null)" = busy ] \
       || ! fm_task_inbox_check_pending orca "$1" "$FM_TASK_INBOX_RING_LINE" "$cstate"; then
      FM_ORCA_RESOLVED_TERMINAL=$1
      return 4
    fi
    [ "$cstate" != pending ] || return 2
  fi
  return 0
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2 live rc=0 check_rc
  fm_backend_orca_tool_check || return 1
  FM_ORCA_RESOLVED_TERMINAL=
  if fm_backend_orca_attempt orca terminal send --terminal "$terminal" --text "$text" --json; then
    FM_ORCA_RESOLVED_TERMINAL=$terminal
    return 0
  else
    rc=$?
  fi
  if fm_backend_orca_last_stale; then
    live=$(fm_backend_orca_resolve_live_terminal "$terminal") || live=
    if [ -n "$live" ]; then
      check_rc=0
      fm_backend_orca_check_replacement "$live" || check_rc=$?
      case "$check_rc" in
        0) ;;
        2) FM_ORCA_RESOLVED_TERMINAL=$live; return 0 ;;
        *) return "$check_rc" ;;
      esac
      if fm_backend_orca_attempt orca terminal send --terminal "$live" --text "$text" --json; then
        FM_ORCA_RESOLVED_TERMINAL=$live
        return 0
      else
        fm_backend_orca_replay_last
        return $?
      fi
    fi
  fi
  fm_backend_orca_replay_last
  return "$rc"
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

fm_backend_orca_send_key_once() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_attempt orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_attempt orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2 live rc=0 check_rc
  FM_ORCA_RESOLVED_TERMINAL=
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C|Enter|enter) ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
  if fm_backend_orca_send_key_once "$terminal" "$key"; then
    return 0
  else
    rc=$?
  fi
  if fm_backend_orca_last_stale; then
    live=$(fm_backend_orca_resolve_live_terminal "$terminal") || live=
    if [ -n "$live" ]; then
      case "$key" in
        Enter|enter)
          check_rc=0
          fm_backend_orca_check_replacement "$live" || check_rc=$?
          case "$check_rc" in 0|2) ;; *) return "$check_rc" ;; esac
          ;;
      esac
      if fm_backend_orca_send_key_once "$live" "$key"; then
        FM_ORCA_RESOLVED_TERMINAL=$live
        return 0
      else
        fm_backend_orca_replay_last
        return $?
      fi
    fi
  fi
  fm_backend_orca_replay_last
  return "$rc"
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 target rc=0
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  # A stale recorded id is retried once through window= inside send_literal.
  # Enter and the composer read then use that live id, still typing the text once.
  fm_backend_orca_send_literal "$terminal" "$text" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 4 ] && [ -n "${FM_TASK_INBOX_RING_LINE:-}" ] && [ -n "${FM_ORCA_RESOLVED_TERMINAL:-}" ]; then
      printf 'inbox-deferred'
    else
      printf 'send-failed'
    fi
    return 0
  fi
  target=${FM_ORCA_RESOLVED_TERMINAL:-$terminal}
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$target" "$retries" "$sleep_s"
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
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
