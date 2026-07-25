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
' || return 1
  fm_backend_orca_authority_capabilities_check
}

fm_backend_orca_authority_capabilities_check() {
  if [ "${FM_ORCA_TEST_LAB:-}" = firstmate-orca-test-lab-v1 ] \
    && [ "${FM_ORCA_TEST_AUTHORITY_CAPABILITIES:-}" = verified-v1 ]; then
    return 0
  fi
  echo "error: Orca lifecycle authority is disabled because no empirically verified terminal/worktree identity and inventory capability is available" >&2
  return 1
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle terminal-title worktree-terminal-handle repo-id
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
if (field === "terminal-title") v = scalar((explicitTerm || r).title) || scalar((explicitTerm || r).name) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || wt.repoId ||
  (wt.repo && (wt.repo.id || wt.repo.repoId)) || r.repoId || "";
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
  local project=$1 name=$2 repo_id out wt_id wt_path terminal status proof
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  if out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json); then
    status=0
  else
    status=$?
  fi
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id 2>/dev/null || true)
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path 2>/dev/null || true)
  proof=unproven
  [ -z "$terminal" ] || proof=recorded
  printf '%s\t%s\t%s\t%s\t%s' "$wt_id" "$wt_path" "$terminal" "$proof" "$repo_id"
  if [ "$status" -ne 0 ] || [ -z "$wt_id" ] || [ -z "$wt_path" ]; then
    echo "error: orca worktree create returned incomplete or unsuccessful authority for $name" >&2
    return 2
  fi
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
  echo "error: unbound Orca worktree removal is disabled" >&2
  return 1
}

fm_backend_orca_remove_worktree_bound() {  # <worktree-id> <expected-path> <boundary-token>
  local worktree_id=${1:-} expected_path=${2:-} boundary_token=${3:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  case "$expected_path" in /*) ;; *) echo "error: missing absolute Orca worktree removal path" >&2; return 1 ;; esac
  [ "${#boundary_token}" -eq 64 ] || {
    echo "error: missing Orca worktree filesystem-boundary token" >&2
    return 1
  }
  case "$boundary_token" in *[!0-9a-f]*)
    echo "error: malformed Orca worktree filesystem-boundary token" >&2
    return 1
    ;;
  esac
  if [ "${FM_ORCA_TEST_LAB:-}" != firstmate-orca-test-lab-v1 ] \
      || [ "${FM_ORCA_TEST_BOUND_REMOVAL_CAPABILITIES:-}" != verified-v1 ]; then
    echo "error: Orca worktree removal lacks an identity-bound provider capability" >&2
    return 1
  fi
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm \
    --worktree "id:$worktree_id" \
    --expected-path "$expected_path" \
    --expected-boundary-token "$boundary_token" \
    --force --json
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

fm_backend_orca_terminal_state() {  # <terminal-id> [expected-worktree-id] [expected-label] -> present|absent|unknown
  local terminal=$1 expected_worktree_id=${2:-} expected_label=${3:-} out status
  if [ -n "$expected_worktree_id" ] || [ -n "$expected_label" ]; then
    fm_backend_orca_authority_capabilities_check >/dev/null 2>&1 || {
      printf 'unknown'
      return 0
    }
  fi
  fm_backend_orca_tool_check || { printf 'unknown'; return 0; }
  if out=$(orca terminal read --terminal "$terminal" --limit 1 --json 2>/dev/null); then
    status=0
  else
    status=$?
  fi
  printf '%s' "$out" | node -e '
const fs = require("fs");
const status = Number(process.argv[1]);
const expectedWorktreeId = process.argv[2] || "";
const expectedLabel = process.argv[3] || "";
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (_) {
  process.stdout.write("unknown");
  process.exit(0);
}
if (data.ok === false) {
  const code = data.error && data.error.code;
  process.stdout.write(code === "terminal_handle_stale" ? "absent" : "unknown");
  process.exit(0);
}
const r = data.result;
const terminal = r && typeof r === "object" && r.terminal && typeof r.terminal === "object"
  ? r.terminal
  : null;
const knownTerminal =
  r && typeof r === "object" &&
  (terminal ||
   Array.isArray(r.tail) ||
   ["text", "output", "content", "preview"].some((key) => typeof r[key] === "string"));
if (status === 0 && expectedWorktreeId) {
  if (!terminal) {
    process.stdout.write("unknown");
    process.exit(0);
  }
  const worktree = terminal.worktree;
  const actualWorktreeId =
    (typeof terminal.worktreeId === "string" ? terminal.worktreeId : "") ||
    (typeof worktree === "string" ? worktree : "") ||
    (worktree && typeof worktree.id === "string" ? worktree.id : "") ||
    (typeof r.worktreeId === "string" ? r.worktreeId : "") ||
    (r.worktree && typeof r.worktree.id === "string" ? r.worktree.id : "");
  if (!actualWorktreeId || actualWorktreeId !== expectedWorktreeId) {
    process.stdout.write("unknown");
    process.exit(0);
  }
}
if (status === 0 && expectedLabel) {
  if (!terminal) {
    process.stdout.write("unknown");
    process.exit(0);
  }
  const actualLabel =
    (typeof terminal.title === "string" ? terminal.title : "") ||
    (typeof terminal.name === "string" ? terminal.name : "") ||
    (typeof r.title === "string" ? r.title : "");
  if (!actualLabel || actualLabel !== expectedLabel) {
    process.stdout.write("unknown");
    process.exit(0);
  }
}
if (status === 0 && data.ok !== false && knownTerminal) {
  process.stdout.write("present");
  process.exit(0);
}
process.stdout.write("unknown");
' "$status" "$expected_worktree_id" "$expected_label"
}

fm_backend_orca_worktree_terminal_state() {
  local worktree_id=$1 expected_label=${2:-} out
  [ -n "$worktree_id" ] || { printf 'unknown'; return 0; }
  fm_backend_orca_authority_capabilities_check >/dev/null 2>&1 || {
    printf 'unknown'
    return 0
  }
  fm_backend_orca_tool_check || { printf 'unknown'; return 0; }
  out=$(orca worktree show --worktree "id:$worktree_id" --json 2>/dev/null) || {
    printf 'unknown'
    return 0
  }
  printf '%s' "$out" | node -e '
const fs = require("fs");
const expected = process.argv[1];
const expectedLabel = process.argv[2] || "";
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (_) {
  process.stdout.write("unknown");
  process.exit(0);
}
if (data.ok === false) {
  process.stdout.write("unknown");
  process.exit(0);
}
const r = data.result || {};
const worktree = r.worktree || r.item || r;
const id = String(worktree.id || worktree.worktreeId || r.worktreeId || "");
const label = String(worktree.name || worktree.title || r.worktreeName || "");
const terminals = Array.isArray(worktree.terminals)
  ? worktree.terminals
  : (Array.isArray(r.terminals) ? r.terminals : null);
const identitiesValid = terminals !== null && terminals.every((terminal) => {
  if (!terminal || typeof terminal !== "object") return false;
  const handle = String(terminal.handle || terminal.id || "");
  const label = String(terminal.title || terminal.name || "");
  return Boolean(handle) && (!expectedLabel || label === expectedLabel);
});
if (id !== expected || (expectedLabel && label !== expectedLabel) ||
    terminals === null || !identitiesValid) {
  process.stdout.write("unknown");
} else {
  process.stdout.write(terminals.length === 0 ? "absent" : "present");
}
' "$worktree_id" "$expected_label"
}

fm_backend_orca_worktree_terminals() {
  local worktree_id=$1 expected_label=$2 out
  [ -n "$worktree_id" ] && [ -n "$expected_label" ] || return 1
  fm_backend_orca_authority_capabilities_check || return 1
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
const expectedId = process.argv[1];
const expectedLabel = process.argv[2];
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (_) {
  process.exit(1);
}
if (data.ok === false) process.exit(1);
const r = data.result || {};
const worktree = r.worktree || r.item || r;
const id = String(worktree.id || worktree.worktreeId || r.worktreeId || "");
const label = String(worktree.name || worktree.title || r.worktreeName || "");
const terminals = Array.isArray(worktree.terminals)
  ? worktree.terminals
  : (Array.isArray(r.terminals) ? r.terminals : null);
if (id !== expectedId || label !== expectedLabel || terminals === null) process.exit(1);
for (const terminal of terminals) {
  if (!terminal || typeof terminal !== "object") process.exit(1);
  const handle = String(terminal.handle || terminal.id || "");
  const label = String(terminal.title || terminal.name || "");
  if (!handle || label !== expectedLabel || /[\r\n]/.test(handle)) process.exit(1);
  process.stdout.write(handle + "\n");
}
' "$worktree_id" "$expected_label"
}

fm_backend_orca_worktree_terminal_contains() {
  local worktree_id=$1 expected_label=$2 expected_terminal=$3 terminals terminal found=0
  [ -n "$expected_terminal" ] || return 1
  terminals=$(fm_backend_orca_worktree_terminals "$worktree_id" "$expected_label") || return 1
  while IFS= read -r terminal; do
    [ "$terminal" != "$expected_terminal" ] || found=$((found + 1))
  done <<EOF
$terminals
EOF
  [ "$found" -eq 1 ]
}

fm_backend_orca_quiesce_terminal() {  # <terminal-id> [expected-worktree-id] [expected-label]
  local terminal=$1 expected_worktree_id=${2:-} expected_label=${3:-} state
  [ -n "$terminal" ] || return 1
  if [ -n "$expected_worktree_id" ] || [ -n "$expected_label" ]; then
    state=$(fm_backend_orca_terminal_state "$terminal" "$expected_worktree_id" "$expected_label")
    [ "$state" = present ] || {
      echo "error: Orca terminal $terminal does not match the expected task authority" >&2
      return 1
    }
  fi
  fm_backend_orca_kill "$terminal" || {
    echo "error: failed to close Orca terminal $terminal" >&2
    return 1
  }
  for _ in 1 2 3 4 5; do
    state=$(fm_backend_orca_terminal_state "$terminal" "$expected_worktree_id" "$expected_label")
    [ "$state" != absent ] || return 0
    sleep 0.1
  done
  echo "error: Orca terminal $terminal is not proven absent after close" >&2
  return 1
}

fm_backend_orca_quiesce_worktree_terminals() {
  local worktree_id=$1 expected_label=$2 known_terminal=${3:-} terminals terminal known_state
  terminals=$(fm_backend_orca_worktree_terminals "$worktree_id" "$expected_label") || {
    echo "error: Orca worktree terminal authority is unproven for $worktree_id" >&2
    return 1
  }
  if [ -n "$known_terminal" ]; then
    known_state=$(fm_backend_orca_terminal_state "$known_terminal" "$worktree_id" "$expected_label")
    case "$known_state" in
      present)
        fm_backend_orca_worktree_terminal_contains "$worktree_id" "$expected_label" "$known_terminal" || {
          echo "error: Orca terminal inventory disagrees with the recorded live terminal for $worktree_id" >&2
          return 1
        }
        ;;
      absent)
        if fm_backend_orca_worktree_terminal_contains "$worktree_id" "$expected_label" "$known_terminal"; then
          echo "error: Orca terminal inventory contains a terminal reported absent for $worktree_id" >&2
          return 1
        fi
        ;;
      *)
        echo "error: recorded Orca terminal authority is unproven for $worktree_id" >&2
        return 1
        ;;
    esac
  fi
  while IFS= read -r terminal; do
    [ -n "$terminal" ] || continue
    fm_backend_orca_quiesce_terminal "$terminal" "$worktree_id" "$expected_label" || return 1
  done <<EOF
$terminals
EOF
  [ "$(fm_backend_orca_worktree_terminal_state "$worktree_id" "$expected_label")" = absent ] || {
    echo "error: Orca worktree $worktree_id still has terminals or cannot prove their absence" >&2
    return 1
  }
  if [ -n "$known_terminal" ]; then
    [ "$(fm_backend_orca_terminal_state "$known_terminal" "$worktree_id" "$expected_label")" = absent ] || {
      echo "error: recorded Orca terminal $known_terminal is not proven absent" >&2
      return 1
    }
  fi
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

fm_backend_orca_json_field() {  # <field> <json>
  local field=$1
  printf '%s' "$2" | node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) process.exit(2);
const r = data.result || {};
const term = r.terminal || {};
function scalar(v) {
  return (typeof v === "string" || typeof v === "number" || typeof v === "boolean") ? String(v) : "";
}
let v = "";
if (field === "limited") v = scalar(r.limited ?? term.limited);
if (field === "oldestCursor") v = scalar(r.oldestCursor || term.oldestCursor);
if (field === "nextCursor") v = scalar(r.nextCursor || term.nextCursor);
if (field === "latestCursor") v = scalar(r.latestCursor || term.latestCursor);
if (!v) process.exit(1);
process.stdout.write(v);
' "$field"
}

fm_backend_orca_read_text_paged() {  # <terminal-id> <limit>
  local terminal=$1 limit=${2:-200} out limited oldest cursor_out text older_text
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$limit" --json) || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok || return 1
  text=$(fm_backend_orca_json_text "$out") || return 1
  limited=$(fm_backend_orca_json_field limited "$out" 2>/dev/null || true)
  oldest=$(fm_backend_orca_json_field oldestCursor "$out" 2>/dev/null || true)
  if [ "$limited" = true ] && [ -n "$oldest" ]; then
    cursor_out=$(orca terminal read --terminal "$terminal" --cursor "$oldest" --limit "$limit" --json) || return 1
    printf '%s' "$cursor_out" | fm_backend_orca_json_ok || return 1
    older_text=$(fm_backend_orca_json_text "$cursor_out") || return 1
    text="${older_text}"$'\n'"${text}"
  fi
  printf '%s' "$text"
}

FM_BACKEND_ORCA_COMPOSER_LINES=${FM_BACKEND_ORCA_COMPOSER_LINES:-200}
FM_BACKEND_ORCA_IDLE_RE=${FM_BACKEND_ORCA_IDLE_RE:-'^Type a message\.\.\.$'}

# fm_backend_orca_composer_state: classify the composer's own bordered row as
# empty|pending|unknown. Real text stays pending, including a slash-command
# popup that closed by filling an argument-hint placeholder into the composer;
# that first Enter selected the popup item, it did not submit the command.
fm_backend_orca_composer_state() {  # <terminal-id> -> empty|pending|unknown
  local terminal=$1 cap line trimmed stripped="" found=0
  cap=$(fm_backend_orca_read_text_paged "$terminal" "$FM_BACKEND_ORCA_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') : ;;
      *) continue ;;
    esac
    stripped=$trimmed
    found=1
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A row was found only by the bordered shape above, so content came from a
  # genuine composer box - delegate to the shared owner with bordered=1. A bare
  # dead-shell prompt has no bordered row and already returned 'unknown' above.
  fm_composer_classify_content 1 "$stripped" "$FM_BACKEND_ORCA_IDLE_RE"
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

# fm_backend_orca_send_text_submit: type <text> once, then retry Enter until
# the composer row reads empty. Retries send only Enter, so a slash-command
# popup placeholder fill gets the required second Enter without duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_orca_send_key "$terminal" Enter || true
    sleep "$sleep_s"
    state=$(fm_backend_orca_composer_state "$terminal")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal close --terminal "$1" --json
}
