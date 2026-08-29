#!/usr/bin/env bash
# bin/backends/superset.sh - the Superset workspace/terminal session-provider
# adapter (EXPERIMENTAL).
#
# Superset owns both the task worktree (a workspace) and the terminal
# endpoint, exactly like Orca (docs/orca-backend.md) - unlike the
# session-provider-only backends (herdr/zellij/cmux), which still hand
# worktree ownership to treehouse. Unlike Orca's single terminal handle, a
# Superset terminal is addressed by TWO ids - the owning workspace and the
# terminal within it - so the target string shape here is
# "<workspace_uuid>:<terminal_uuid>", split on the FIRST colon exactly like
# cmux's "<workspace_uuid>:<surface_uuid>" (bin/backends/cmux.sh); neither id
# embeds a colon, so the split is unambiguous.
#
# Empirical findings, live-verified against the real `superset` CLI v1.23.0
# during this adapter's authoring (dated evidence in
# docs/verification/runtime-backends.md "Superset"), several of which shaped
# the design below:
#
#   1. `superset ws create` does NOT return `worktreePath` for a
#      project-backed (type=worktree) workspace - only `superset ws get`
#      does. Worktree creation therefore always makes a follow-up `ws get`
#      call to resolve the path, unlike Orca's single-call worktree create.
#   2. A project-backed `ws create` response includes an implicit
#      "Workspace Setup" terminal (running the project's configured setup
#      command, if any) in its `terminals` array. This is NOT a general
#      shell - reusing it the way Orca reuses its implicit terminal would
#      race the setup script or inherit its exit state. This adapter always
#      creates its OWN terminal explicitly instead of reusing that one.
#   3. `superset ws delete` performs NO dirty-worktree or unlanded-work
#      check of its own - verified live: deleting a workspace with an
#      uncommitted tracked file silently discarded it, no warning, no
#      `--force` needed. Firstmate's own teardown safety gate
#      (bin/fm-teardown.sh's validate_worktree_teardown_safety, which runs
#      for every backend before any fm_backend_remove_worktree call) is the
#      ONLY protection here; this adapter adds none of its own, matching
#      every other backend's posture that the shared gate - not the backend
#      CLI - owns that check.
#   4. `terminals send --text` rejects an empty string outright ("text: Too
#      small: expected string to have >=1 characters"), and an embedded
#      newline or carriage-return byte in --text is inserted as literal
#      text, NOT interpreted as pressing Enter (verified: staging text then
#      sending "\n" or "\r" with --no-submit left the staged command
#      un-executed). A bare Enter press therefore sends a single space as
#      --text without --no-submit: the CLI's normal "type then submit"
#      behavior presses Enter after it, and a lone trailing space is inert
#      to every shell and agent composer this adapter targets. There is no
#      true "press Enter only" primitive: a space+DEL (0x20 0x7f) compensation
#      was tried live to neutralize the injected space before submit, and
#      verified NOT to work - 0x7f is inserted as a literal DEL control byte
#      (rendered ^?), not interpreted as a backspace/delete-previous-character
#      edit, so it strictly worsens the injection rather than canceling it.
#      Known caveat: bin/fm-composer-lib.sh's fm_composer_submit_retry_core
#      calls this adapter's send-key(Enter) again on every retry without
#      retyping the original text, so if an intermediate Enter is swallowed by
#      a popup/autocomplete instead of submitting, each retry injects one more
#      stray space into whatever is still staged in the composer (e.g. a
#      slash-command popup argument placeholder), rather than being a no-op.
#   5. Unlike embedded text bytes, \x03 (Ctrl-C) IS specially recognized by
#      `terminals send --text` and delivers a real interrupt - verified
#      live: sending it to a terminal running `sleep 60` produced the
#      shell's own ^C and a [130] (SIGINT) exit prompt. \x15 (Ctrl-U) was
#      tested the same way and did NOT map to a line-kill - it was inserted
#      as literal text - so this adapter claims Ctrl-C only, not Ctrl-U or
#      Escape, matching Orca's "claim only what is proven" posture
#      (docs/orca-backend.md).
#   6. `superset terminals read` returns plain, unstyled text (a `text`
#      field with no ANSI escapes) - confirmed live, so this adapter
#      declares styled=0 exactly like Orca and cmux.
#   7. A freshly created terminal (zero prior writes) reads back correctly
#      on the very first `terminals read` call - verified live. This
#      adapter needs none of cmux's fresh-surface liveness workaround
#      (bin/backends/cmux.sh's fm_backend_cmux_target_ready header).
#
# NOT live-verified: `superset projects create`'s exact JSON response shape.
# There is no `projects delete` command to clean up a throwaway
# registration, so this adapter does not auto-register an unregistered
# project the way Orca's fm_backend_orca_repo_ensure does - it requires the
# project already registered with Superset and fails loudly, naming the
# exact command to run, rather than guess at an unverified shape that could
# leave orphaned registrations on error.
#
# Requires: the `superset` CLI, node (for JSON parsing, exactly like Orca's
# adapter). Bootstrap detects this only when superset is the resolved
# backend (fm_backend_required_tools).

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_superset_tool_check() {
  command -v superset >/dev/null 2>&1 || { echo "error: backend=superset selected but the 'superset' CLI is not installed" >&2; return 1; }
}

# fm_backend_superset_runtime_check: refuse loudly unless the local Superset
# host service is up and healthy. Mirrors fm_backend_orca_runtime_check's
# fail-fast posture, checked once at spawn time before any mutation.
fm_backend_superset_runtime_check() {
  fm_backend_superset_tool_check || return 1
  local out
  out=$(superset status --json 2>/dev/null) || {
    echo "error: backend=superset selected but 'superset status' failed; start the Superset host service and try again" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Superset status JSON: " + err.message);
  process.exit(1);
}
if (data.running === true && data.healthy === true) process.exit(0);
console.error(`error: backend=superset requires a running, healthy host service (running=${String(data.running)}, healthy=${String(data.healthy)})`);
process.exit(1);
'
}

# fm_backend_superset_json_get: <field> from JSON on stdin. Superset's own
# JSON is flat and already live-verified per call site (see the header
# findings), so this is a thin per-field switch, not Orca's defensive
# multi-shape parser. Fields: create-workspace-id worktree-path terminal-id
# text.
fm_backend_superset_json_get() {  # <field>
  local field=$1
  # shellcheck disable=SC2016
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
let v = "";
if (field === "create-workspace-id") v = (data.workspace || {}).id || "";
if (field === "worktree-path") v = data.worktreePath || "";
if (field === "terminal-id") v = data.terminalId || "";
if (field === "text") v = (typeof data.text === "string") ? data.text : "";
if (field !== "text" && !v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

# fm_backend_superset_project_id_for_path: the registered Superset project id
# whose path matches <project-path>, or empty (not found). Never mutates -
# see the header's "not live-verified" note on why this adapter does not
# auto-register. Resolved with plain `pwd`, NOT `pwd -P`: callers always pass
# fm-spawn.sh's own PROJ_ABS, which is itself resolved with plain `pwd`
# (bin/fm-spawn.sh), so matching that exact convention - rather than also
# resolving symlink components - is what keeps this lookup consistent with
# every path firstmate ever actually passes in.
fm_backend_superset_project_id_for_path() {  # <project-path>
  local path=$1 canon out
  canon=$(cd "$path" 2>/dev/null && pwd) || return 1
  out=$(superset projects list --json 2>/dev/null) || return 1
  # shellcheck disable=SC2016
  printf '%s' "$out" | node -e '
const fs = require("fs");
const canon = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const hit = (Array.isArray(data) ? data : []).find(p => p && p.path === canon);
if (!hit || !hit.id) process.exit(1);
process.stdout.write(String(hit.id));
' "$canon"
}

fm_backend_superset_project_ensure() {  # <project-path>
  local path=$1 id
  fm_backend_superset_tool_check || return 1
  id=$(fm_backend_superset_project_id_for_path "$path") || {
    echo "error: backend=superset selected but no Superset project is registered for $path; register it first with 'superset projects create --local --name <name> --import $path'" >&2
    return 1
  }
  printf '%s' "$id"
}

# fm_backend_superset_remove_worktree: delete the workspace, which also
# releases the worktree - Superset has no separate worktree-id from
# workspace-id, unlike Orca's repo/worktree split. See header finding #3:
# this performs NO dirty-check of its own; firstmate's teardown gate is the
# only safety net and MUST run before this is ever called.
fm_backend_superset_remove_worktree() {  # <workspace-id>
  local ws_id=${1:-}
  [ -n "$ws_id" ] || { echo "error: missing Superset workspace id; cannot remove worktree" >&2; return 1; }
  fm_backend_superset_tool_check || return 1
  superset ws delete "$ws_id" --local --json >/dev/null
}

fm_backend_superset_worktree_path() {  # <workspace-id>
  local ws_id=${1:-} out
  [ -n "$ws_id" ] || { echo "error: missing Superset workspace id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_superset_tool_check || return 1
  out=$(superset ws get "$ws_id" --json) || return 1
  printf '%s' "$out" | fm_backend_superset_json_get worktree-path || {
    echo "error: superset ws get did not return a worktreePath for $ws_id" >&2
    return 1
  }
}

# fm_backend_superset_worktree_create: create a project-backed workspace for
# <name> under <project-path>'s registered Superset project, resolve its
# worktree path with a follow-up `ws get` (finding #1), and print
# "<workspace-id>\t<worktree-path>". --skip-branch-prefix keeps the branch
# name exactly <name>, matching every other backend's naming. Never reuses
# the implicit "Workspace Setup" terminal (finding #2) - callers create their
# own via fm_backend_superset_terminal_create.
#
# On success: prints "<workspace-id>\t<worktree-path>", returns 0.
# On a workspace created but path-unresolvable: self-attempts cleanup
# (mirrors fm_backend_orca_worktree_create's contract exactly). If cleanup
# succeeds, prints nothing and returns 1 (nothing left for the caller to
# preserve). If cleanup itself fails, prints "<workspace-id>\t" and returns
# 2, so the caller can preserve the orphaned workspace id in task metadata.
fm_backend_superset_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 project_id out ws_id wt_path
  project_id=$(fm_backend_superset_project_ensure "$project") || return 1
  out=$(superset ws create --local --project "$project_id" --name "$name" --branch "$name" --skip-branch-prefix --json) || return 1
  ws_id=$(printf '%s' "$out" | fm_backend_superset_json_get create-workspace-id) || {
    echo "error: superset ws create did not return a workspace id for $name" >&2
    return 1
  }
  wt_path=$(fm_backend_superset_worktree_path "$ws_id" 2>/dev/null) || wt_path=
  if [ -n "$wt_path" ]; then
    printf '%s\t%s' "$ws_id" "$wt_path"
    return 0
  fi
  echo "error: superset ws get did not return a worktreePath for $ws_id" >&2
  if fm_backend_superset_remove_worktree "$ws_id" >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\t' "$ws_id"
  return 2
}

fm_backend_superset_terminal_create() {  # <workspace-id> [title (unused; no CLI primitive)]
  local ws_id=$1 out
  fm_backend_superset_tool_check || return 1
  out=$(superset terminals create --workspace "$ws_id" --json) || return 1
  printf '%s' "$out" | fm_backend_superset_json_get terminal-id || {
    echo "error: superset terminals create did not return a terminal id for workspace $ws_id" >&2
    return 1
  }
}

# fm_backend_superset_parse_target: split "<workspace_uuid>:<terminal_uuid>"
# on the FIRST colon (mirrors bin/backends/cmux.sh's identical convention;
# neither id embeds a colon). Sets FM_BACKEND_SUPERSET_WORKSPACE and
# FM_BACKEND_SUPERSET_TERMINAL for the caller.
fm_backend_superset_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_SUPERSET_WORKSPACE=${target%%:*}
  FM_BACKEND_SUPERSET_TERMINAL=${target#*:}
  [ -n "$FM_BACKEND_SUPERSET_WORKSPACE" ] && [ -n "$FM_BACKEND_SUPERSET_TERMINAL" ] && [ "$FM_BACKEND_SUPERSET_TERMINAL" != "$target" ]
}

fm_backend_superset_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-40} out
  fm_backend_superset_parse_target "$1" || return 1
  fm_backend_superset_tool_check || return 1
  out=$(superset terminals read --workspace "$FM_BACKEND_SUPERSET_WORKSPACE" --terminal "$FM_BACKEND_SUPERSET_TERMINAL" --max-lines "$lines" --json) || return 1
  printf '%s' "$out" | fm_backend_superset_json_get text
}

# fm_backend_superset_send_literal: type TEXT as unsubmitted input - the
# caller sends Enter separately. Matches every other backend's
# literal-then-separate-Enter contract.
fm_backend_superset_send_literal() {  # <target> <text>
  fm_backend_superset_parse_target "$1" || return 1
  fm_backend_superset_tool_check || return 1
  superset terminals send --workspace "$FM_BACKEND_SUPERSET_WORKSPACE" --terminal "$FM_BACKEND_SUPERSET_TERMINAL" --text "$2" --no-submit --json >/dev/null
}

fm_backend_superset_send_text_line() {  # <target> <text>
  fm_backend_superset_parse_target "$1" || return 1
  fm_backend_superset_tool_check || return 1
  superset terminals send --workspace "$FM_BACKEND_SUPERSET_WORKSPACE" --terminal "$FM_BACKEND_SUPERSET_TERMINAL" --text "$2" --json >/dev/null
}

# fm_backend_superset_send_key: Enter and Ctrl-C only - see header findings
# #4 and #5 for why Enter sends a single space (the CLI rejects an empty
# --text and does not treat an embedded newline as a keypress) and why
# Ctrl-U/Escape are refused rather than guessed at.
fm_backend_superset_send_key() {  # <target> <key>
  fm_backend_superset_parse_target "$1" || return 1
  fm_backend_superset_tool_check || return 1
  local key=$2
  case "$key" in
    Enter|enter)
      # Single space is the only non-empty --text the CLI accepts (finding #4);
      # a live-verified space+DEL compensation does not neutralize it (0x7f
      # inserts as a literal control byte, not a backspace). A retry from
      # fm_composer_submit_retry_core re-sends this space on top of whatever
      # is still staged, so it is a no-op only when the prior Enter submitted.
      superset terminals send --workspace "$FM_BACKEND_SUPERSET_WORKSPACE" --terminal "$FM_BACKEND_SUPERSET_TERMINAL" --text " " --json >/dev/null
      ;;
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      superset terminals send --workspace "$FM_BACKEND_SUPERSET_WORKSPACE" --terminal "$FM_BACKEND_SUPERSET_TERMINAL" --text "$(printf '\x03')" --json >/dev/null
      ;;
    *)
      echo "error: unsupported Superset key '$key'" >&2
      return 1
      ;;
  esac
}

fm_backend_superset_kill() {  # <target>
  fm_backend_superset_parse_target "$1" || return 0
  fm_backend_superset_tool_check || return 0
  superset terminals close --workspace "$FM_BACKEND_SUPERSET_WORKSPACE" --terminal "$FM_BACKEND_SUPERSET_TERMINAL" --json >/dev/null 2>&1 || true
}

# fm_backend_superset_target_ready: cheap read-only existence probe - a
# bounded 1-line capture, mirroring fm_backend_orca_capture's identical use
# in fm-backend.sh's fm_backend_target_exists dispatch (finding #7: no
# fresh-terminal liveness pitfall to work around here, unlike cmux).
fm_backend_superset_target_ready() {  # <target> [expected-label]
  fm_backend_superset_capture "$1" 1 >/dev/null 2>&1
}

# fm_backend_superset_composer_capture: the Superset composer screen - a
# bounded plain-text tail of the terminal.
fm_backend_superset_composer_capture() {  # <target> [expected-label]
  fm_backend_superset_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_superset_composer_caps: static capability facts (see the
# capability model in bin/fm-composer-lib.sh). styled=0 per header finding #6.
fm_backend_superset_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_superset_composer_state: thin adapter - capture plus
# capabilities in, shared verdict out. Every shape lives in
# bin/fm-composer-lib.sh, so a new harness shape is taught there once and
# never here.
fm_backend_superset_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_superset_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_superset_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_superset_send_text_submit: type <text> into <target> once
# (unsubmitted, via send_literal), then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter
# without duplicating text. Echoes empty|pending|unknown|send-failed.
fm_backend_superset_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_superset_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_superset_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_superset_send_key fm_backend_superset_composer_state \
    "$target" "$retries" "$sleep_s"
}
