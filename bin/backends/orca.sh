#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
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

fm_backend_orca_json_succeeded() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok !== true) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

# Print error.code from an ok:false Orca JSON envelope on stdin; exit 1 when the
# envelope is not such a failure or names no code. Callers branch on this code
# rather than on the rendered prose, whose message field wins over the code.
fm_backend_orca_json_error_code() {
  node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  process.exit(1);
}
if (!data || data.ok !== false || !data.error || !data.error.code) process.exit(1);
process.stdout.write(String(data.error.code));
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

# --- recovery-grade agent state ---------------------------------------------
#
# Orca's per-terminal agentIdentity and title are sticky: a terminal keeps
# agentIdentity=pi and a "Pi ready" title after the agent has exited back to
# the shell (observed live on Orca 1.4.224), so no Orca display field can
# prove a stop. The classifier reads the pane's process tree instead, using
# Orca only to name that tree's root:
#   1. `orca terminal show` gives the terminal's ptyId plus whether that record
#      proves the pane is gone (a terminal `exitCause`, or a record reporting
#      itself neither connected nor writable). Orca's terminal_handle_stale
#      answer is its authoritative "no such terminal" (`missing`), and any
#      other failure is `unreadable`.
#   2. `orca diagnostics memory` (Orca's own host process sweep, ~0.3s) maps
#      that ptyId to the pty's root pid. A pty the sweep still names keeps the
#      process-tree verdict below, because a live process is the stronger fact;
#      one it no longer names is `missing` when the record proves the pane gone
#      and `unreadable` otherwise.
#   3. One `ps` snapshot gives every descendant of that root. Any descendant
#      the shared harness-name classifier (the tmux adapter's
#      fm_backend_tmux_classify_process_name) calls an agent is `alive`; a tree
#      holding nothing but shells below the root is `dead`; any other
#      descendant (an unrecognized process that could be a renamed harness) is
#      `ambiguous`, the same fail-safe fold the tmux adapter applies.
# Exit (bin/fm-control.sh) is the consumer; relaunch stays gated separately
# (bin/fm-control-lib.sh) until an Orca relaunch is proven end to end.

# fm_backend_orca_terminal_record <terminal>: prints "<ptyId>\t<closed>",
# where <closed> is 1 when the terminal's own record proves the pane is gone and
# 0 when it does not. Returns 3 for Orca's authoritative stale-handle answer, 1
# otherwise.
#
# Two shapes prove a gone pane: Orca's own terminal exit cause, and the
# connected/writable pair. Orca files an `exitCause` when a terminal stops, and
# only its `unknown` causes (the host could not verify the stop) and an
# unverified sentinel exit code are not proof - Orca's own contract treats those
# as "stop unverified", never as an observed death. Everything else, a
# deliberate `operator_close`, a signal, or a real exit code, leaves no process
# able to host an agent.
fm_backend_orca_terminal_record() {  # <terminal-id>
  local terminal=$1 out
  fm_backend_orca_tool_check 2>/dev/null || return 1
  out=$(orca terminal show --terminal "$terminal" --json 2>/dev/null || true)
  [ -n "$out" ] || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(1); }
if (data.ok === false) {
  const code = data.error && data.error.code;
  process.exit(code === "terminal_handle_stale" ? 3 : 1);
}
const t = (data.result && data.result.terminal) || {};
const id = typeof t.ptyId === "string" ? t.ptyId : "";
if (!id || /[\t\n]/.test(id)) process.exit(1);
const cause = t.exitCause;
let closed = false;
if (cause && typeof cause === "object") {
  if (cause.kind === "operator_close" || cause.kind === "signaled") {
    closed = true;
  } else if (cause.kind === "exited") {
    // Orca records an unverified stop as a negative sentinel exit code, so only
    // a non-negative code is a process exit the host actually observed.
    closed = typeof cause.exitCode === "number" && cause.exitCode >= 0;
  }
}
if (!closed) {
  const writable = typeof t.writable === "boolean" ? t.writable : t.writeable;
  if (t.connected === false && writable === false) closed = true;
}
process.stdout.write(id + "\t" + (closed ? "1" : "0"));
'
}

# fm_backend_orca_pty_root_pid <pty-id>: the root pid Orca's host process
# sweep records for that pty session. Returns 3 when the sweep itself succeeded
# and does not name that pty (an authoritative "no such session"), and 1 when
# the sweep could not be read at all - a distinction the callers need, because
# a failed read proves nothing about the pty.
fm_backend_orca_pty_root_pid() {  # <pty-id>
  local pty=$1 out
  out=$(orca diagnostics memory --json 2>/dev/null || true)
  [ -n "$out" ] || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
const want = process.argv[1];
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(1); }
if (data.ok === false) process.exit(1);
const worktrees = (data.result && data.result.worktrees) || [];
for (const w of worktrees) {
  for (const s of (w.sessions || [])) {
    if (s && s.sessionId === want && Number.isInteger(s.pid) && s.pid > 1) {
      process.stdout.write(String(s.pid));
      process.exit(0);
    }
  }
}
process.exit(3);
' "$pty"
}

# fm_backend_orca_tree_state <root-pid>: alive|dead|ambiguous|unreadable for
# the processes below <root-pid> (the root itself is Orca's pty wrapper, such
# as /usr/bin/login, and is never classified).
fm_backend_orca_tree_state() {  # <root-pid>
  local root=$1 snapshot tree pid comm verdict sep=$'\x1f' verdicts=$'\x1f' other=0
  case "$root" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
  fm_backend_source tmux || { printf 'unreadable'; return 0; }
  snapshot=$(LC_ALL=C ps -axo pid=,ppid=,comm= 2>/dev/null) || { printf 'unreadable'; return 0; }
  printf '%s\n' "$snapshot" | awk -v r="$root" '$1 == r { found = 1 } END { exit !found }' \
    || { printf 'unreadable'; return 0; }
  # Every descendant of the root as "<pid>\t<comm>", breadth-first.
  tree=$(printf '%s\n' "$snapshot" | awk -v r="$root" '
    {
      pid = $1; ppid = $2
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "")
      comm[pid] = $0; kids[ppid] = kids[ppid] " " pid
    }
    END {
      n = split(kids[r], q, " "); head = 1
      while (head <= n) {
        p = q[head++]
        if (p == "") continue
        print p "\t" comm[p]
        m = split(kids[p], more, " ")
        for (i = 1; i <= m; i++) if (more[i] != "") q[++n] = more[i]
      }
    }')
  while IFS=$'\t' read -r pid comm; do
    [ -n "$pid" ] || continue
    # Classify each distinct name once; every classification is a subshell.
    case "$verdicts" in
      *"$sep$comm=agent$sep"*) verdict=agent ;;
      *"$sep$comm=shell$sep"*) verdict=shell ;;
      *"$sep$comm=other$sep"*) verdict=other ;;
      *)
        verdict=$(fm_backend_tmux_classify_process_name "$comm")
        verdicts="$verdicts$comm=$verdict$sep"
        ;;
    esac
    case "$verdict" in
      agent) printf 'alive'; return 0 ;;
      shell) ;;
      *) other=1 ;;
    esac
  done <<< "$tree"
  if [ "$other" -eq 1 ]; then
    printf 'ambiguous'
  else
    printf 'dead'
  fi
}

fm_backend_orca_agent_state() {  # <terminal-id>
  local terminal=$1 record pty closed root rc=0
  case "$terminal" in ''|*[!A-Za-z0-9_-]*) printf 'unreadable'; return 0 ;; esac
  record=$(fm_backend_orca_terminal_record "$terminal") || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf 'missing'
    return 0
  fi
  [ "$rc" -eq 0 ] || { printf 'unreadable'; return 0; }
  pty=${record%%$'\t'*}
  closed=${record##*$'\t'}
  # A pty Orca's sweep still names is a live process tree, and that verdict is
  # the stronger fact: a record can lag the kernel, never outrank it.
  root=$(fm_backend_orca_pty_root_pid "$pty")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_backend_orca_tree_state "$root"
    return 0
  fi
  # A sweep that could not be read proves nothing, so a possibly live pty is
  # never declared gone on a transient diagnostics failure.
  [ "$rc" -eq 3 ] || { printf 'unreadable'; return 0; }
  # No swept pty plus a record that proves the pane gone is a terminal no agent
  # can be running in: the shape a closed Orca tab leaves behind, where the
  # record survives with connected=false, writable=false, and
  # exitCause=operator_close while the pty it names is gone. Calling that
  # `unreadable` told every consumer the endpoint could not be judged, so no
  # consumer ever replaced it.
  if [ "$closed" = 1 ]; then
    printf 'missing'
  else
    printf 'unreadable'
  fi
}
