#!/usr/bin/env bash
# bin/backends/thurbox.sh - the thurbox session-provider adapter (EXPERIMENTAL).
#
# Design: docs/thurbox-backend.md carries the live verification pass this
# adapter is built on (real thurbox-cli 2.11.0 and 2.11.1, Linux x86_64,
# 2026-09-01 and 2026-09-02). Dated notes below naming 2.11.0 record when a
# behaviour was first observed; the supported floor is 2.11.1.
# thurbox is a session provider ONLY, exactly like herdr/zellij/cmux: the
# worktree provider stays treehouse. Sourced only through bin/fm-backend.sh's
# fm_backend_source in normal operation; the unit tests source it directly.
#
# What makes this adapter different from its neighbours: thurbox is the first
# backend whose event stream, agent state, and driver key/value store are all
# first-class CLI verbs, so three things other adapters synthesize are read
# here instead of derived.
#
#   1. NATIVE EVENT PUSH WITH NO SIDECAR READER. herdr needs a raw-socket
#      subscriber (bin/backends/herdr-eventwait.py) because its events ride a
#      protocol socket. `thurbox-cli watch --json` IS the subscriber: one
#      newline-delimited JSON object per transition on stdout. The wait path
#      below therefore has no Python dependency and no schema probe - the
#      capability gate is the version floor alone.
#   2. NATIVE AGENT STATE. `state` on a session row is thurbox's own
#      working/blocked/done/idle verdict, reported by the agent's hooks
#      through `thurbox-cli session signal`. That is a semantic signal, not a
#      rendering, so busy-state does not go through pane regex - PROVIDED the
#      agent actually reports. See the hook-coverage gate in
#      fm_backend_thurbox_busy_state: an agent firstmate launched by typing
#      into a shell carries no thurbox hook wiring, so this adapter treats a
#      non-hook state source as unknown rather than trusting a stale row.
#   3. LIVE FOREGROUND IDENTITY. `session capture --json` returns
#      foreground_process, foreground_command and foreground_cwd for the
#      pane's tty right now. tmux reconstructs the same facts with a ps walk
#      (fm_backend_tmux_foreground_comms) and every other adapter simply has
#      no answer. This makes thurbox the only non-tmux backend that can offer
#      the composer classifier a real identity probe, and the only backend
#      whose current-path read is genuinely live rather than frozen at
#      creation time (docs/thurbox-backend.md "Current path").
#
# Target string shape: "thurbox:<session-uuid>". The uuid is a bare UUID with
# no embedded colon, so splitting on the FIRST colon is trivially correct
# (mirrors herdr's/zellij's/cmux's target-string convention). The constant
# "thurbox" prefix is not decoration: fm_backend_resolve_selector passes any
# selector CONTAINING a colon through literally, and routes a colonless one
# into the legacy bare-tmux-window search. A bare uuid would take that tmux
# path and never reach this adapter.
#
# ERROR-STREAM CONTRACT - the single most important fact about driving this
# CLI. thurbox-cli prints its failures as a JSON object ON STDOUT
# ({"error":...,"suggestion":...}) and leaves stderr EMPTY, exiting non-zero.
# Verified 2026-09-01 against 2.11.0. A pipeline like
#
#     thurbox-cli session get <id> --json | jq -r '.state // empty'
#
# therefore exits 0 with empty output when the command FAILED, because jq
# parsed the error object happily and the pipeline reports jq's status. Every
# read in this file goes through fm_backend_thurbox_json, which captures the
# CLI's own exit status BEFORE any parse and additionally rejects a payload
# carrying an `error` key. No function here pipes thurbox-cli into jq
# directly, and no new one may.
#
# OUTPUT-FORMAT CONTRACT: thurbox-cli emits TOON, not JSON, whenever stdout is
# not a terminal - which is always, under command substitution. Every call
# here passes --json explicitly. `session meta get` is the sharpest instance:
# without --json it prints a three-line `id:/key:/value:` block rather than
# the bare value its --help promises, and an UNSET key prints the literal
# string `value: null` rather than nothing.

# Version floor. 2.11.1 is the first release on which every read this adapter
# makes answers correctly. 2.11.0 introduced the verbs - `watch` (native push),
# `session create --command/--arg/--env` (launching firstmate's own harness
# without an agents.toml entry), `--on-existing` (idempotent create),
# `session meta`, `session exec`, `session stop`/`start` - but reported a parked
# session through `session get`/`session list` identically to a running one, so
# readiness and recovery could not tell them apart. 2.11.1 puts `stopped` on both
# reads and answers `state` with `stopped`, which is what this adapter needs.
FM_BACKEND_THURBOX_MIN_VERSION="2.11.1"

# Composer capture depth. 0 = the visible pane only, with no scrollback rows
# prepended. This is REQUIRED, not a tuning choice: `session capture`'s
# cursor_row is 0-based relative to the VISIBLE PANE, while --lines N prepends
# N scrollback rows to the returned text. Any N > 0 therefore desynchronizes
# the cursor row from the screen the classifier indexes into it.
FM_BACKEND_THURBOX_COMPOSER_LINES=0

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/cmux.sh's and bin/backends/zellij.sh's identical fallback.
FM_BACKEND_THURBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_THURBOX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_THURBOX_ROOT/bin/fm-backend-hometag-lib.sh"

fm_backend_thurbox_bin() {
  command -v thurbox-cli >/dev/null 2>&1 || return 1
  printf 'thurbox-cli'
}

fm_backend_thurbox_tool_check() {
  if ! command -v thurbox-cli >/dev/null 2>&1; then
    echo "error: thurbox backend requires the 'thurbox-cli' binary on PATH" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: thurbox backend requires 'jq' to parse thurbox-cli --json output" >&2
    return 1
  fi
  return 0
}

# fm_backend_thurbox_version_at_least: pure dotted-numeric comparison, no
# external tools. Non-numeric components sort as 0 rather than erroring, so a
# prerelease suffix degrades to its numeric prefix instead of refusing.
fm_backend_thurbox_version_at_least() {  # <candidate> <floor>
  local cand=$1 floor=$2 i c f
  cand=${cand%%-*}
  floor=${floor%%-*}
  for i in 1 2 3; do
    c=$(printf '%s' "$cand" | cut -d. -f"$i")
    f=$(printf '%s' "$floor" | cut -d. -f"$i")
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    case "$f" in ''|*[!0-9]*) f=0 ;; esac
    [ "$c" -gt "$f" ] && return 0
    [ "$c" -lt "$f" ] && return 1
  done
  return 0
}

fm_backend_thurbox_version() {
  local raw
  raw=$(thurbox-cli version --json 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -r '.version // empty' 2>/dev/null
}

# fm_backend_thurbox_version_check: refuse an installation below the floor
# LOUDLY rather than failing later inside an individual verb.
# FM_BACKEND_THURBOX_VERSION_OVERRIDE substitutes a version string for tests
# without touching the real binary.
fm_backend_thurbox_version_check() {
  local v
  fm_backend_thurbox_tool_check || return 1
  if [ -n "${FM_BACKEND_THURBOX_VERSION_OVERRIDE:-}" ]; then
    v=$FM_BACKEND_THURBOX_VERSION_OVERRIDE
  else
    v=$(fm_backend_thurbox_version) || v=""
  fi
  if [ -z "$v" ]; then
    echo "error: could not read thurbox-cli version ('thurbox-cli version --json' returned no version field)" >&2
    return 1
  fi
  if ! fm_backend_thurbox_version_at_least "$v" "$FM_BACKEND_THURBOX_MIN_VERSION"; then
    echo "error: thurbox-cli $v is below the $FM_BACKEND_THURBOX_MIN_VERSION floor the thurbox backend requires (needs watch, session create --command/--env, --on-existing, session meta, exec, stop)" >&2
    return 1
  fi
  return 0
}

# fm_backend_thurbox_json: THE single read point for every thurbox-cli call
# whose output this adapter parses. Runs the command with --json appended,
# captures stdout and the CLI's OWN exit status before anything parses, and
# refuses a payload that carries an `error` key. This is what keeps the
# stdout-error contract documented in the header from turning a failed read
# into a silent empty success. Prints the raw JSON on success.
fm_backend_thurbox_json() {  # <thurbox-cli-args...>
  local out rc
  out=$(thurbox-cli "$@" --json 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 1
  case "$out" in
    '{"error"'*|'{ "error"'*) return 1 ;;
  esac
  if printf '%s' "$out" | jq -e 'if type == "object" then has("error") else false end' >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$out"
}

# fm_backend_thurbox_field: one scalar field out of one thurbox-cli read.
# Empty output with return 0 means "the call succeeded and the field is unset
# or null"; return 1 means the CALL failed. Callers that must distinguish the
# two check the status, never the emptiness.
fm_backend_thurbox_field() {  # <jq-filter> <thurbox-cli-args...>
  local filter=$1 raw
  shift
  raw=$(fm_backend_thurbox_json "$@") || return 1
  printf '%s' "$raw" | jq -r "$filter // empty" 2>/dev/null
}

# fm_backend_thurbox_socket: the tmux socket path thurbox runs its own panes
# on, from `thurbox-cli version --json`'s tmux_socket field (a socket NAME,
# resolved against tmux's per-uid socket directory). Detection needs it; see
# fm_backend_thurbox_is_current_runtime.
fm_backend_thurbox_socket_name() {
  fm_backend_thurbox_field '.tmux_socket' version
}

# fm_backend_thurbox_is_current_runtime: is the firstmate process running this
# code itself inside a thurbox-managed pane?
#
# This cannot be a bare $THURBOX_SESSION test, and it cannot be ordered after
# the $TMUX test the way herdr's and cmux's detection arms are. thurbox runs
# its sessions on ITS OWN tmux server, so every process in a thurbox pane has
# BOTH THURBOX_SESSION and $TMUX set. Checking $TMUX first would classify
# every thurbox pane as plain tmux; checking THURBOX_SESSION alone would
# misclassify a NESTED plain-tmux server started inside a thurbox pane, which
# inherits THURBOX_SESSION but is genuinely a tmux runtime.
#
# The discriminator is the SOCKET: $TMUX's first comma-separated field is the
# socket path of the server this process is attached to. It matches thurbox's
# own socket name only when the innermost multiplexer IS thurbox's server. A
# nested plain tmux gets a different socket and correctly stays tmux.
fm_backend_thurbox_is_current_runtime() {
  [ -n "${THURBOX_SESSION:-}" ] || return 1
  [ -n "${TMUX:-}" ] || return 1
  command -v thurbox-cli >/dev/null 2>&1 || return 1
  local sock name
  sock=${TMUX%%,*}
  sock=${sock##*/}
  [ -n "$sock" ] || return 1
  name=$(fm_backend_thurbox_socket_name) || return 1
  [ -n "$name" ] || return 1
  [ "$sock" = "$name" ]
}

# fm_backend_thurbox_agent_launch_args: the argv thurbox would append when IT
# launches <agent>, one argument per line, or nothing.
#
# This is what makes native state reporting reachable at all. thurbox's status
# hooks are ARGUMENTS (`--settings <hooks>.json` for claude), appended from
# agents.toml only when thurbox builds the command line. Firstmate's spawn
# contract creates a shell and TYPES the harness in, so nothing appended them
# and every firstmate-spawned session reported no state and never appeared in
# `watch`. Passing these through closes that: verified 2026-09-02 that a typed
# `claude --settings <hooks>.json` reports state_source=hook and transitions
# working/done exactly as a thurbox-launched agent does.
#
# Only the `args` are taken. The `env` the verb also reports names this thurbox
# instance, and the pane already carries it - thurbox injects THURBOX_SESSION
# into every pane it creates, which is the identity `session signal` resolves.
# `--session` is deliberately NOT passed: it would additionally pin the agent's
# conversation id, making thurbox a second owner of resume alongside firstmate's
# own relaunch path.
#
# Returns 1 when the agent is not in agents.toml, which is the normal case for a
# harness thurbox does not know (grok, kimi, cursor, muse). That is not a spawn
# failure - the session simply reports no native state, exactly as before this
# wiring existed - so every caller treats a failure here as "no args".
#
# Success with NO args is a different answer and must not be read as the same
# one: thurbox delivers some agents' hooks out of band by writing their own
# config rather than through argv, and opencode and pi both report full hook
# coverage with an empty `args` (verified 2026-09-02). Those sessions report
# state normally with nothing appended.
fm_backend_thurbox_agent_launch_args() {  # <agent> -> one arg per line
  local agent=$1 raw
  [ -n "$agent" ] || return 1
  raw=$(fm_backend_thurbox_json agent launch-args "$agent") || return 1
  printf '%s' "$raw" | jq -r '.args[]? // empty' 2>/dev/null
}

# --- target handling ---------------------------------------------------------

# fm_backend_thurbox_parse_target: split "thurbox:<uuid>" and export the uuid
# as FM_BACKEND_THURBOX_SESSION. Refuses anything else rather than guessing.
# Declared up front so a caller running under `set -u` can read it after a
# failed parse without tripping an unbound-variable abort.
FM_BACKEND_THURBOX_SESSION="${FM_BACKEND_THURBOX_SESSION:-}"

fm_backend_thurbox_parse_target() {  # <target>
  local target=$1 prefix uuid
  FM_BACKEND_THURBOX_SESSION=""
  prefix=${target%%:*}
  uuid=${target#*:}
  [ "$prefix" = thurbox ] || return 1
  [ -n "$uuid" ] && [ "$uuid" != "$target" ] || return 1
  case "$uuid" in *:*) return 1 ;; esac
  FM_BACKEND_THURBOX_SESSION=$uuid
  return 0
}

fm_backend_thurbox_target() {  # <uuid>
  printf 'thurbox:%s' "$1"
}

# fm_backend_thurbox_session_row: the live session record for a session UUID,
# or failure when the session does not exist. A deleted session is not live and
# needs no marker check here: `session get` refuses a deleted row outright
# (`Session not found`, exit 1), which fm_backend_thurbox_json already turns
# into a failed read. An earlier release answered for deleted rows and this
# function filtered them on `deleted_at`; that branch became unreachable and was
# removed rather than left describing behaviour the CLI no longer has.
#
# It takes the UUID rather than the target deliberately. Callers reach it
# through a command substitution, and parsing the target here would set
# FM_BACKEND_THURBOX_SESSION inside that SUBSHELL, where it dies - leaving the
# caller to address an unset session on its very next line. Every entry point
# therefore parses the target itself, in its own scope, before reading a row.
fm_backend_thurbox_session_row() {  # <session-uuid>
  local uuid=$1 raw
  [ -n "$uuid" ] || return 1
  raw=$(fm_backend_thurbox_json session get "$uuid") || return 1
  printf '%s' "$raw"
}

# fm_backend_thurbox_target_ready: cheap liveness - the session exists, is not
# soft-deleted, and is not PARKED.
#
# A parked session (`session stop`) keeps its row, checkout and conversation but
# loses its pane, so no send, key, or capture can land on it; treating one as
# ready would make every write silently address nothing. From 2.11.1 the row
# answers that directly, which is why the floor is 2.11.1 rather than 2.11.0 -
# on 2.11.0 this read could not distinguish the two at all.
#
# It also PARSES the target in the caller's scope, so a caller that gates a
# write on this call can use FM_BACKEND_THURBOX_SESSION on the next line.
fm_backend_thurbox_target_ready() {  # <target>
  fm_backend_thurbox_parse_target "$1" || return 1
  local raw stopped
  raw=$(fm_backend_thurbox_session_row "$FM_BACKEND_THURBOX_SESSION") || return 1
  stopped=$(printf '%s' "$raw" | jq -r '.stopped // empty' 2>/dev/null)
  [ "$stopped" != true ]
}

# fm_backend_thurbox_relaunch_prepare: un-park a PARKED session before a
# replacement agent is typed into it.
#
# fm_backend_thurbox_agent_state reports a parked session as `dead` (docs
# "Parked sessions"), which is exactly what fm-spawn.sh's relaunch gate wants -
# an agent-free endpoint safe to reuse. But `dead` there does not mean "a live
# pane with a shell in it" the way it does for every other backend: a parked
# session has no pane at all, so fm_backend_thurbox_target_ready refuses every
# write into it and the replacement harness would never be typed. `session
# start` puts the pane back and is idempotent - a session that is already
# running is left alone - so this is safe to call unconditionally.
fm_backend_thurbox_relaunch_prepare() {  # <target>
  fm_backend_thurbox_target_ready "$1" && return 0
  thurbox-cli session start "$FM_BACKEND_THURBOX_SESSION" --json >/dev/null 2>&1
}

# --- container and task creation ---------------------------------------------

# fm_backend_thurbox_container_ensure: thurbox has NO session-container layer
# to multiplex the way tmux sessions, herdr workspaces, or zellij sessions do
# - `session create` addresses the one running thurbox instance directly. The
# only precondition is a usable CLI at or above the floor, so this verb is a
# dependency gate rather than a create. It exists so fm-spawn.sh's per-backend
# sequence keeps the same shape across every adapter.
fm_backend_thurbox_container_ensure() {
  fm_backend_thurbox_version_check || return 1
  fm_backend_thurbox_json session list >/dev/null || {
    echo "error: thurbox-cli is installed but 'session list' failed; is thurbox's data directory readable?" >&2
    return 1
  }
  return 0
}

# fm_backend_thurbox_shell: the interactive shell a task pane runs. firstmate's
# spawn contract is uniform across every backend - create a SHELL endpoint,
# type exports into it, then type the harness launch command
# (bin/fm-spawn.sh) - so the pane must be a shell, never an agent thurbox
# launched itself. `--command <shell> --arg -i` says exactly that with no
# agents.toml entry required, which is why this adapter needs no
# config/thurbox-agent knob. -i is required: thurbox runs the command with no
# shell interpreting it, so a non-interactive shell would read EOF and exit
# immediately.
fm_backend_thurbox_shell() {
  local sh=${SHELL:-} resolved
  case "${sh##*/}" in
    bash|zsh|sh|dash|ksh|fish)
      printf '%s' "$sh"
      return 0
      ;;
  esac
  # $SHELL is unset or names something that is not an interactive shell (a
  # restricted login shell, or an editor set by a stray export). Fall back to a
  # real shell by absolute path, since thurbox execs the command directly with
  # no PATH-resolving shell in between.
  if resolved=$(command -v bash 2>/dev/null) && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
    return 0
  fi
  printf '/bin/sh'
}

# fm_backend_thurbox_home_label / fm_backend_thurbox_scoped_name: one thurbox
# instance owns ONE session-name namespace for the whole machine, exactly like
# cmux's app-global workspace list and zellij's shared tab bar. Two firstmate
# homes whose task ids collide would otherwise fight over one name: the second
# home's --on-existing fail create would be refused by the FIRST home's live
# session, and a name-based lookup could resolve to the wrong home's endpoint.
# The shared home tag (bin/fm-backend-hometag-lib.sh) closes that the same way
# it does for those two backends.
#
# thurbox caps a session name at 64 characters and rejects slashes and a
# leading dot. The tag costs a fixed 21 characters ("fm-" + prefix + "-" +
# 8-char hash), so an over-long task label is refused LOUDLY here rather than
# silently truncated into a name that no longer identifies its task.
fm_backend_thurbox_home_label() {
  fm_backend_hometag
}

fm_backend_thurbox_scoped_name() {  # <fm-task-label>
  local label=$1 rest home name
  home=$(fm_backend_thurbox_home_label)
  case "$label" in
    */*|.*) echo "error: thurbox rejects session name '$label' (no slashes, no leading dot)" >&2; return 1 ;;
  esac
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  name="fm-$home-$rest"
  if [ "${#name}" -gt 64 ]; then
    echo "error: thurbox session name '$name' is ${#name} characters, over thurbox's 64-character limit; shorten the task id" >&2
    return 1
  fi
  printf '%s' "$name"
}

# fm_backend_thurbox_create_task: one thurbox session per firstmate task
# (mirrors tmux's one-window-per-task). Prints the task target on success.
#
# --on-existing fail, not the `allow` default: allow would create a SECOND
# session sharing the label, and thurbox then refuses to resolve that name at
# all, so a re-spawn of a task whose endpoint was never torn down would strand
# both. Failing names the session in the way and leaves the caller to
# reconcile, which is what firstmate's spawn lock expects.
fm_backend_thurbox_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 name shell raw uuid
  [ -n "$label" ] || { echo "error: thurbox create-task requires a label" >&2; return 1; }
  [ -d "$cwd" ] || { echo "error: thurbox create-task requires an existing directory, got '$cwd'" >&2; return 1; }
  name=$(fm_backend_thurbox_scoped_name "$label") || return 1
  shell=$(fm_backend_thurbox_shell)
  raw=$(fm_backend_thurbox_json session create --name "$name" --repo-path "$cwd" \
    --command "$shell" --arg -i --on-existing fail) || return 1
  uuid=$(printf '%s' "$raw" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$uuid" ] || { echo "error: thurbox session create returned no session id" >&2; return 1; }
  fm_backend_thurbox_target "$uuid"
}

# fm_backend_thurbox_current_path: where the pane's FOREGROUND process is right
# now, from `session capture --json`'s foreground_cwd.
#
# Every other session-provider backend answers this from a creation-time or
# top-level-shell-scoped field and needs a pwd-marker probe to see through a
# foreground subshell (zellij's and cmux's workaround, docs/cmux-backend.md
# finding #2). thurbox reads the foreground process's own cwd from the tty, so
# it follows into a subshell natively and needs no probe. The session row's
# own `cwd` is the creation-time launch directory and is used only as the
# fallback when no foreground process can be attributed.
fm_backend_thurbox_current_path() {  # <target>
  fm_backend_thurbox_parse_target "$1" || return 1
  local raw path
  raw=$(fm_backend_thurbox_json session capture "$FM_BACKEND_THURBOX_SESSION" --lines 0) || return 1
  path=$(printf '%s' "$raw" | jq -r '.foreground_cwd // empty' 2>/dev/null)
  # A cwd whose directory has been unlinked out from under the process comes
  # back from the kernel with a " (deleted)" suffix (Linux /proc/<pid>/cwd), so
  # what arrives is not a path at all. Observed live 2026-09-02 when a task's
  # worktree was removed while its shell was still inside it. REFUSE rather than
  # fall back to the session row's creation-time cwd: that path may well still
  # exist, and answering with it would tell the caller a live directory is the
  # pane's working directory when the real one is gone - which is exactly the
  # answer fm-spawn.sh's worktree-isolation assertion must never be given.
  case "$path" in
    *' (deleted)') return 1 ;;
  esac
  if [ -z "$path" ]; then
    path=$(fm_backend_thurbox_field '.cwd' session get "$FM_BACKEND_THURBOX_SESSION") || return 1
  fi
  [ -n "$path" ] || return 1
  printf '%s' "$path"
}

# --- input -------------------------------------------------------------------

# fm_backend_thurbox_send_literal: type <text> WITHOUT submitting. thurbox
# delivers it as one bracketed paste, so it arrives literally - no shell sees
# it and a leading '-', quote or newline survives intact. That is why this
# adapter passes the text with no escaping of its own, unlike the tmux path's
# send-keys -l.
#
# The `--` matters and its position is exact. That paste promise is about
# DELIVERY; the argument parser is a separate gate, and with the text as a
# trailing positional a leading '-' is read as a flag and the call is refused
# outright with nothing typed at all (verified against 2.18.0: `unexpected
# argument '-x' found`, exit 2). Every flag must precede the `--` and the uuid
# must too, because `session send <id> -- <text> --no-enter` instead refuses
# --no-enter. A steer beginning with a dash is the case this protects.
fm_backend_thurbox_send_literal() {  # <target> <text>
  fm_backend_thurbox_target_ready "$1" || return 1
  thurbox-cli session send --no-enter --json "$FM_BACKEND_THURBOX_SESSION" -- "$2" >/dev/null 2>&1
}

# fm_backend_thurbox_normalize_key: firstmate's key vocabulary onto thurbox's
# `session key` names. Verified against 2.11.0's own documented set: enter,
# escape, tab, backspace, space, arrows, home, end, page-up, page-down,
# delete, and ctrl-<letter>. Names are case-insensitive there and ctrl+c /
# c-c spell the same key, but this maps to the canonical spelling anyway so
# the wire form stays one shape.
fm_backend_thurbox_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl-c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl-u' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_thurbox_send_key() {  # <target> <key>
  fm_backend_thurbox_target_ready "$1" || return 1
  local key
  key=$(fm_backend_thurbox_normalize_key "$2")
  thurbox-cli session key "$FM_BACKEND_THURBOX_SESSION" "$key" --json >/dev/null 2>&1
}

# fm_backend_thurbox_send_text_line: one line of text, then submit. Mirrors
# every other adapter's literal-then-separate-Enter contract, including the
# C-c rescue that distinguishes "typed but not submitted" (1) from "left in an
# unknown state" (2).
fm_backend_thurbox_send_text_line() {  # <target> <text>
  fm_backend_thurbox_send_literal "$1" "$2" || return 1
  fm_backend_thurbox_send_key "$1" Enter && return 0
  fm_backend_thurbox_send_key "$1" C-c >/dev/null 2>&1 && return 1
  return 2
}

# --- capture -----------------------------------------------------------------

# fm_backend_thurbox_capture: bounded plain-text pane capture.
#
# NO LOCAL TRIM. `session capture --lines N` prepends up to N scrollback rows
# to the WHOLE visible screen - verified 2026-09-01: on a 63-row pane, N=50
# returned 113 rows and N=500 returned 403 (capped by the scrollback actually
# available). That is exactly tmux's `capture-pane -p -S -N` contract, so the
# response is returned whole. A `tail -n N` here would discard every requested
# scrollback row plus the top of the screen.
fm_backend_thurbox_capture() {  # <target> <lines>
  fm_backend_thurbox_parse_target "$1" || return 1
  local lines=${2:-200} raw
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  [ "$lines" -le 10000 ] || lines=10000
  raw=$(fm_backend_thurbox_json session capture "$FM_BACKEND_THURBOX_SESSION" --lines "$lines") || return 1
  printf '%s' "$raw" | jq -r '.output // empty' 2>/dev/null
}

fm_backend_thurbox_capture_ansi() {  # <target> <lines>
  fm_backend_thurbox_parse_target "$1" || return 1
  local lines=${2:-200} raw
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  [ "$lines" -le 10000 ] || lines=10000
  raw=$(fm_backend_thurbox_json session capture "$FM_BACKEND_THURBOX_SESSION" --lines "$lines" --ansi) || return 1
  printf '%s' "$raw" | jq -r '.output // empty' 2>/dev/null
}

# --- composer ----------------------------------------------------------------

# fm_backend_thurbox_composer_screen: the visible pane with ANSI styling AND
# its cursor row, as one tab-separated "<cursor_row>\t<screen>" read. They come
# from a single `session capture` call deliberately: two calls could observe
# different frames and hand the classifier a cursor row that does not index
# the screen beside it.
fm_backend_thurbox_composer_screen() {  # <target> -> "<cursor_row>\t<screen>"
  fm_backend_thurbox_parse_target "$1" || return 1
  local raw cy screen
  raw=$(fm_backend_thurbox_json session capture "$FM_BACKEND_THURBOX_SESSION" \
    --lines "$FM_BACKEND_THURBOX_COMPOSER_LINES" --ansi) || return 1
  cy=$(printf '%s' "$raw" | jq -r '.cursor_row // empty' 2>/dev/null)
  screen=$(printf '%s' "$raw" | jq -r '.output // empty' 2>/dev/null)
  case "$cy" in ''|*[!0-9]*) cy='' ;; esac
  printf '%s\t%s' "$cy" "$screen"
}

# fm_backend_thurbox_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). thurbox is the only non-tmux
# backend that can declare all three: styling comes from `capture --ansi`, the
# cursor row from the same capture's cursor_row, and identity from its
# foreground_process/foreground_command. rows=0 because the composer capture is
# the visible pane only, which is what a cursor row relative to the visible
# pane requires.
fm_backend_thurbox_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n'
}

# fm_backend_thurbox_classify_foreground: map thurbox's two foreground fields
# onto the shared agent/shell/other classifier (bin/backends/tmux.sh, the single
# owner of that vocabulary). foreground_command is a full command LINE, so its
# leading token is the executable as invoked - that is the `path` the classifier
# expects, and passing the whole line would make `${path##*/}` read
# "bash -i" and match nothing. foreground_process is the process name and fills
# the argv0 slot. A session with no command line falls back to the process name
# for both.
fm_backend_thurbox_classify_foreground() {  # <foreground_command> <foreground_process>
  local cmd=$1 proc=$2 head
  head=${cmd%% *}
  [ -n "$head" ] || head=$proc
  [ -n "$head" ] || return 1
  fm_backend_tmux_classify_process_name "$head" "$proc"
}

# fm_backend_thurbox_composer_identity: the native agent-identity probe backing
# the separated (pi) composer shape. thurbox reports the pane's live foreground
# process directly, so unlike tmux this needs no ps walk and no pgid scoping -
# foreground_process IS the foreground process. A pane whose agent exited to a
# shell reports the shell and therefore yields no agent identity, exactly as
# the tmux probe's foreground scoping intends.
fm_backend_thurbox_composer_identity() {  # <target>
  fm_backend_thurbox_parse_target "$1" || return 1
  local raw proc cmd kind
  raw=$(fm_backend_thurbox_json session capture "$FM_BACKEND_THURBOX_SESSION" --lines 0) || return 1
  proc=$(printf '%s' "$raw" | jq -r '.foreground_process // empty' 2>/dev/null)
  cmd=$(printf '%s' "$raw" | jq -r '.foreground_command // empty' 2>/dev/null)
  [ -n "$proc" ] || return 1
  kind=$(fm_backend_thurbox_classify_foreground "$cmd" "$proc") || return 1
  [ "$kind" = agent ] || return 1
  printf '%s' "$proc"
}

# fm_backend_thurbox_composer_state: thin adapter - capture plus capabilities
# in, shared verdict out. Every composer SHAPE lives in bin/fm-composer-lib.sh
# so no backend holds a private shape assumption.
fm_backend_thurbox_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local pair cy screen verdict identity
  pair=$(fm_backend_thurbox_composer_screen "$1") || { printf 'unknown'; return 0; }
  cy=${pair%%$'\t'*}
  screen=${pair#*$'\t'}
  verdict=$(fm_composer_classify_screen "$(fm_backend_thurbox_composer_caps)" "$screen" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_backend_thurbox_composer_identity "$1") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$(fm_backend_thurbox_composer_caps)" "$screen" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_thurbox_send_text_submit: type <text> once (raw, unsubmitted),
# then drive the shared verify-and-retry-Enter loop against the shared composer
# verdict. Never retypes - only the submission is retried.
fm_backend_thurbox_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_thurbox_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_thurbox_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_thurbox_send_key fm_backend_thurbox_composer_state \
    "$target" "$retries" "$sleep_s"
}

# --- state -------------------------------------------------------------------

# fm_backend_thurbox_busy_state: semantic busy/idle/unknown from thurbox's own
# agent-state row, with a HOOK-COVERAGE GATE.
#
# thurbox's `state` is authoritative only when it came from a hook the agent
# actually fired (state_source == "hook"). firstmate launches its harness by
# typing into a shell thurbox created, which means thurbox never applied the
# agents.toml wiring that installs those hooks (docs/thurbox-backend.md "Hook
# coverage"), so a firstmate-spawned session commonly reports no hook state at
# all. Trusting the row regardless would report a days-old `idle` for a pane
# that is working right now. An explicitly CONTRADICTED hook state is refused
# for the same reason: thurbox itself is saying the row disagrees with the
# pane. Both cases fall through to `unknown`, which is the cue every caller
# already understands as "use the harness-scoped pane read instead"
# (fm_backend_busy_state's contract in bin/fm-backend.sh).
fm_backend_thurbox_busy_state() {  # <target> -> busy|idle|unknown
  local raw source contradicted state
  fm_backend_thurbox_parse_target "$1" || { printf 'unknown'; return 0; }
  raw=$(fm_backend_thurbox_session_row "$FM_BACKEND_THURBOX_SESSION") || { printf 'unknown'; return 0; }
  source=$(printf '%s' "$raw" | jq -r '.state_source // empty' 2>/dev/null)
  [ "$source" = hook ] || { printf 'unknown'; return 0; }
  contradicted=$(printf '%s' "$raw" | jq -r '.hook_state_contradicted // empty' 2>/dev/null)
  [ "$contradicted" != true ] || { printf 'unknown'; return 0; }
  state=$(printf '%s' "$raw" | jq -r '.state // empty' 2>/dev/null)
  case "$state" in
    working) printf 'busy' ;;
    blocked|done|idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_thurbox_agent_state: the recovery-grade endpoint classifier
# (fm_backend_agent_state's vocabulary in bin/fm-backend.sh). Only `dead` and
# `missing` license recovery, so every uncertain read must land on ambiguous
# or unreadable instead.
#
#   missing    - the session inventory read SUCCEEDED and has no such session,
#                or the row is soft-deleted. An inventory read that FAILED is
#                unreadable, never missing: a CLI error must not be allowed to
#                license tearing down a live agent.
#   dead       - the pane exists and its live foreground process is
#                confidently a shell.
#   alive      - the pane's live foreground process classifies as an agent.
#   ambiguous  - the pane exists but no foreground process can be attributed,
#                or it is neither shell nor agent.
#   unreadable - a read failed or contradicted itself.
#
# A PARKED session is `dead`, not `missing`: the row, checkout and conversation
# are all still there, so recovery must relaunch into it rather than treat the
# task's endpoint as gone. The inventory row already in hand carries `stopped`,
# so that costs no extra read.
fm_backend_thurbox_agent_state() {  # <target>
  if ! fm_backend_thurbox_parse_target "$1"; then
    printf 'unreadable'
    return 0
  fi
  local inventory row raw proc cmd kind
  inventory=$(fm_backend_thurbox_json session list) || { printf 'unreadable'; return 0; }
  row=$(printf '%s' "$inventory" | jq -c --arg id "$FM_BACKEND_THURBOX_SESSION" \
    'map(select(.id == $id)) | first // empty' 2>/dev/null) || { printf 'unreadable'; return 0; }
  if [ -z "$row" ]; then
    # `missing` licenses recovery, and recovery starts a replacement agent. A
    # soft-deleted session is absent from this inventory while its agent keeps
    # running, so answering `missing` here would invite a second agent into the
    # same task. Only an authoritative disposition may license that.
    case "$(fm_backend_thurbox_endpoint_disposition "$FM_BACKEND_THURBOX_SESSION")" in
      gone) printf 'missing' ;;
      *) printf 'unreadable' ;;
    esac
    return 0
  fi
  if [ "$(printf '%s' "$row" | jq -r '.stopped // empty' 2>/dev/null)" = true ]; then
    printf 'dead'
    return 0
  fi
  raw=$(fm_backend_thurbox_json session capture "$FM_BACKEND_THURBOX_SESSION" --lines 0) || { printf 'unreadable'; return 0; }
  proc=$(printf '%s' "$raw" | jq -r '.foreground_process // empty' 2>/dev/null)
  cmd=$(printf '%s' "$raw" | jq -r '.foreground_command // empty' 2>/dev/null)
  if [ -z "$proc" ]; then
    printf 'ambiguous'
    return 0
  fi
  kind=$(fm_backend_thurbox_classify_foreground "$cmd" "$proc") || kind=other
  case "$kind" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

fm_backend_thurbox_agent_alive() {  # <target>
  case "$(fm_backend_thurbox_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# --- teardown and inventory --------------------------------------------------

# fm_backend_thurbox_kill: remove the task's endpoint. --force is REQUIRED, not
# a convenience: a bare `session delete` only soft-deletes the row and leaves
# the pane running until the TUI's next sync, so a headless firstmate teardown
# would report success while the agent kept running. --force kills the window
# and cancels pending scheduled commands in the same call.
#
# Worktrees: firstmate's tasks are created with --repo-path (an already-built
# treehouse worktree), never --worktree-branch, so thurbox owns no worktree for
# them and --force removes none. treehouse remains the worktree owner exactly
# as it is for tmux, herdr, zellij and cmux.
# A soft-deleted row cannot be force-deleted at all - `delete` resolves live
# rows, and a deleted one belongs to `restore`/`reap` - so a task whose session
# was deleted from outside (the interface's own delete, or a peer) would leave
# its agent running with teardown believing it had killed it. `session reap` is
# the documented way to let go of that agent, it is idempotent, and it refuses a
# live session outright, so it can never take down a running task by mistake.
fm_backend_thurbox_kill() {  # <target>
  fm_backend_thurbox_parse_target "$1" || return 1
  thurbox-cli session delete "$FM_BACKEND_THURBOX_SESSION" --force --json >/dev/null 2>&1 && return 0
  thurbox-cli session reap "$FM_BACKEND_THURBOX_SESSION" --json >/dev/null 2>&1
}

# fm_backend_thurbox_pane_alive: is <pane-id> still a pane on thurbox's own tmux
# server? Returns 0 alive, 1 gone, 2 when it cannot be told.
#
# This is the adapter's ONE reach past thurbox-cli, and it is here because
# thurbox will not answer the question. A deleted row is refused by both
# `session get` and `session capture` whether or not its pane is still up, and
# the row itself is byte-identical before and after a reap - `force_deleted`
# stays false and no reaped marker appears (verified on 2.18.0). The row's own
# `backend_id` against the socket `version` reports is the only thing left that
# distinguishes a released pane from a running one.
fm_backend_thurbox_pane_alive() {  # <pane-id>
  local pane=$1 socket
  [ -n "$pane" ] || return 2
  command -v tmux >/dev/null 2>&1 || return 2
  socket=$(fm_backend_thurbox_socket_name) || return 2
  [ -n "$socket" ] || return 2
  local panes
  panes=$(tmux -L "$socket" list-panes -a -F '#{pane_id}' 2>/dev/null) || return 2
  printf '%s\n' "$panes" | grep -qxF "$pane"
}

# fm_backend_thurbox_endpoint_disposition: the single answer both teardown-facing
# reads need about a session missing from the live inventory. Prints `gone` when
# the endpoint is provably absent, `live-pane` when an agent may still be
# running, and returns 1 when it cannot be told - which callers must treat as
# "not proven", never as either verdict.
#
# A soft `session delete` is thurbox's lossless undo window, not a leak: the row
# goes, the worktrees stay, and the pane comes down when an interface, the
# `automation tick` heartbeat, or `session reap` lets go of it. Firstmate runs
# headless with none of those guaranteed, so a soft-deleted row proves nothing on
# its own and its pane has to be checked.
fm_backend_thurbox_endpoint_disposition() {  # <session-uuid>
  local uuid=$1 deleted row forced backend_type pane
  [ -n "$uuid" ] || return 1
  deleted=$(fm_backend_thurbox_json session list --deleted) || return 1
  row=$(printf '%s' "$deleted" | jq -c --arg id "$uuid" \
    'map(select(.id == $id)) | first // empty' 2>/dev/null) || return 1
  if [ -z "$row" ]; then
    printf 'gone'
    return 0
  fi
  forced=$(printf '%s' "$row" | jq -r '.force_deleted // empty' 2>/dev/null)
  if [ "$forced" = true ]; then
    printf 'gone'
    return 0
  fi
  # Soft-deleted: only its pane can say. A session whose pane lives on another
  # host cannot be proven absent from this one, so it is never claimed.
  backend_type=$(printf '%s' "$row" | jq -r '.backend_type // empty' 2>/dev/null)
  case "$backend_type" in
    local-tmux) ;;
    *) return 1 ;;
  esac
  pane=$(printf '%s' "$row" | jq -r '.backend_id // empty' 2>/dev/null)
  # Captured explicitly: an `if` whose condition fails and has no else exits 0,
  # so `$?` after it would report the `if`, not the probe, and every reaped pane
  # would read as unprovable.
  local pane_probe
  fm_backend_thurbox_pane_alive "$pane"
  pane_probe=$?
  case "$pane_probe" in
    0) printf 'live-pane'; return 0 ;;
    1) printf 'gone'; return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_thurbox_endpoint_confirmed_gone: a POSITIVE proof of absence for
# teardown safety.
#
# Absence from the live inventory is necessary but NOT sufficient: a soft
# delete produces exactly that while the agent keeps running (see
# fm_backend_thurbox_deleted_disposition). Proof therefore needs both reads to
# answer, and a session sitting soft-deleted is reported as NOT proven rather
# than allowing teardown to record a pane it never removed as gone. A failed
# read of either inventory is not proof either.
fm_backend_thurbox_endpoint_confirmed_gone() {  # <target>
  fm_backend_thurbox_parse_target "$1" || return 1
  local inventory hit
  inventory=$(fm_backend_thurbox_json session list) || return 1
  hit=$(printf '%s' "$inventory" | jq -r --arg id "$FM_BACKEND_THURBOX_SESSION" \
    'map(select(.id == $id)) | length' 2>/dev/null)
  [ "$hit" = 0 ] || return 1
  [ "$(fm_backend_thurbox_endpoint_disposition "$FM_BACKEND_THURBOX_SESSION")" = gone ]
}

# fm_backend_thurbox_list_live: one "<target>\t<name>" line per live session.
fm_backend_thurbox_list_live() {
  local inventory
  inventory=$(fm_backend_thurbox_json session list) || return 1
  printf '%s' "$inventory" | jq -r '.[] | select(.stopped != true) | "thurbox:" + .id + "\t" + (.name // "")' 2>/dev/null
}

# fm_backend_thurbox_resolve_bare_selector: thurbox sessions are addressed by
# uuid, and a bare NAME can legitimately match several of them (thurbox refuses
# to resolve an ambiguous name rather than guessing, and this adapter must not
# guess either). Resolves only when exactly one live session carries the name.
fm_backend_thurbox_resolve_bare_selector() {  # <name>
  local name=$1 inventory ids count
  # A caller passing a firstmate task label means THIS home's session, so the
  # label is home-scoped before matching; a caller passing an already-scoped or
  # foreign name is matched verbatim.
  case "$name" in
    fm-*) name=$(fm_backend_thurbox_scoped_name "$name") || return 1 ;;
  esac
  inventory=$(fm_backend_thurbox_json session list) || return 1
  ids=$(printf '%s' "$inventory" | jq -r --arg n "$name" \
    '.[] | select(.name == $n) | .id' 2>/dev/null)
  count=$(printf '%s' "$ids" | grep -c . 2>/dev/null || true)
  case "$count" in
    1) fm_backend_thurbox_target "$(printf '%s' "$ids" | head -1)" ;;
    0) echo "error: no thurbox session named '$name'" >&2; return 1 ;;
    *) echo "error: thurbox session name '$name' matches $count sessions; address it by uuid (thurbox:<uuid>)" >&2; return 1 ;;
  esac
}

# --- native event push -------------------------------------------------------
#
# thurbox is the second push-capable backend after herdr, and by far the
# cheapest to wire: `thurbox-cli watch --json` is itself the subscriber, so
# there is no sidecar reader, no socket resolution, and no schema probe. The
# stream emits one JSON object per transition with an `event` field whose
# verified vocabulary (2.11.0, 2026-09-01) is:
#
#   present  - baseline row, emitted only under --initial
#   created  - a session appeared
#   changed  - a session's state or stopped flag changed
#   gone     - a session was removed
#
# and a `state` field carrying working|blocked|done|idle or null. Those map
# straight onto the shared policy table in bin/fm-transition-lib.sh
# (blocked = actionable, working = absorb, idle/done = defer, null =
# fallback), so nothing thurbox-specific leaks into the policy.

# fm_backend_thurbox_events_capable: the version floor is the whole gate -
# `watch` needs no separate schema probe the way herdr's protocol does.
# FM_BACKEND_THURBOX_EVENTS_FORCE overrides the verdict for tests (1 = capable,
# 0 = incapable) without touching the real binary.
fm_backend_thurbox_events_capable() {  # [<session>]
  case "${FM_BACKEND_THURBOX_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_thurbox_tool_check >/dev/null 2>&1 || return 1
  fm_backend_thurbox_version_check >/dev/null 2>&1 || return 1
  return 0
}

# fm_backend_thurbox_event_reader_cmd: the reader argv, one word per line.
# FM_BACKEND_THURBOX_EVENT_READER substitutes a fake reader replaying canned
# stream lines, mirroring herdr's own test seam.
fm_backend_thurbox_event_reader_cmd() {
  local word
  if [ -n "${FM_BACKEND_THURBOX_EVENT_READER:-}" ]; then
    for word in $FM_BACKEND_THURBOX_EVENT_READER; do
      printf '%s\n' "$word"
    done
    return 0
  fi
  printf 'thurbox-cli\n'
  printf 'watch\n'
  printf -- '--json\n'
}

# fm_backend_thurbox_normalize_event: THE single normalize point - both the
# stream reader's lines and any level-reconcile read flow through here into the
# shared normalized-transition record. The session uuid occupies the pane_id
# slot because it IS this backend's endpoint identity; there is no separate
# workspace layer, so that field stays empty.
#
# from_status is filled from the event's own `from_state`. An earlier release
# carried no previous state, which is why this used to leave the slot empty; it
# does now, and a policy that can see working->blocked separately from
# idle->blocked is strictly better informed. A baseline `present` row genuinely
# has no previous state and correctly normalizes to empty.
fm_backend_thurbox_normalize_event() {  # <session_uuid> <state> <agent> [<from_state>]
  fm_transition_record "${1:-}" "" "${4:-}" "${2:-}" "${3:-}"
}

# fm_backend_thurbox_escalation_marker: the per-session dedupe marker path for
# a <window> ("thurbox:<uuid>"), keyed identically to the watcher's own
# .stale-<key> scheme (tr ':/.' '___').
fm_backend_thurbox_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/.thurbox-escalated-%s' "$state" "$key"
}

# fm_backend_thurbox_watch_cursor_path: where this home records the last event
# sequence it consumed, so a later wait can resume from it.
fm_backend_thurbox_watch_cursor_path() {  # <state_dir>
  printf '%s/.thurbox-watch-seq' "$1"
}

# fm_backend_thurbox_watch_cursor_set: advance the cursor, ignoring anything
# that is not a sequence number. Best-effort by design: a cursor that cannot be
# written costs a replay, never a lost event, because the next wait simply
# starts from now again.
fm_backend_thurbox_watch_cursor_set() {  # <cursor-file> <seq>
  local file=$1 seq=$2
  [ -n "$file" ] || return 0
  case "$seq" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$seq" > "$file" 2>/dev/null || true
}

# fm_backend_thurbox_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-session dedupe marker. On a fresh
# actionable (blocked) edge it prints the record and returns 0; the caller
# commits the marker only after handling it. `absorb` (working) clears the
# marker. Everything else returns 1 with no output.
# <heuristic> is the event's own `hook_blocked_is_heuristic`. thurbox sets it
# because Claude's blocked signal rides its Notification hook, which also fires
# for advisories an auto-mode agent clears by itself and stays set for the whole
# of a long foreground command. Escalating on the first such edge produced
# repeated false alarms, so a heuristic blocked edge is corroborated with one
# `session get` before it is raised: if the session has already left blocked, it
# was transient and is absorbed. A confident edge pays for no extra read.
fm_backend_thurbox_apply_transition() {  # <state_dir> <record> [<heuristic>]
  local state=$1 record=$2 heuristic=${3:-} uuid to action window marker
  uuid=$(fm_transition_pane_id "$record")
  [ -n "$uuid" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  if [ "$action" = actionable ] && [ "$heuristic" = true ]; then
    local now
    now=$(fm_backend_thurbox_field '.state' session get "$uuid") || now=""
    [ "$now" = blocked ] || action=defer
  fi
  window=$(fm_backend_thurbox_target "$uuid")
  marker=$(fm_backend_thurbox_escalation_marker "$state" "$window")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

fm_backend_thurbox_commit_transition() {  # <state_dir> <record>
  local state=$1 record=$2 uuid window marker
  uuid=$(fm_transition_pane_id "$record")
  [ -n "$uuid" ] || return 1
  window=$(fm_backend_thurbox_target "$uuid")
  marker=$(fm_backend_thurbox_escalation_marker "$state" "$window")
  : > "$marker"
}

fm_backend_thurbox_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2 marker
  [ -n "$window" ] || return 0
  marker=$(fm_backend_thurbox_escalation_marker "$state" "$window")
  rm -f "$marker" 2>/dev/null || true
}

# fm_backend_thurbox_wait_transition: the bounded event wait.
#
# Blocks up to <timeout_secs> for one of <window...> ("thurbox:<uuid>") to
# reach a fresh `blocked` edge, then prints the normalized record and returns
# 0. Returns 1 on a clean timeout - the reader ran its full budget with no
# fresh actionable edge, so the caller has effectively already slept and just
# continues. Returns 2 when the event path is unusable (below the floor, or the
# reader failed to start), and the caller sleeps the budget itself; that is the
# permanent fail-closed backstop the watcher relies on.
#
# `watch --for-secs` bounds the stream inside thurbox, so the budget needs no
# external timeout wrapper. --initial is deliberately NOT passed: its baseline
# `present` rows would replay an already-handled blocked state as a fresh edge
# on every single poll.
fm_backend_thurbox_wait_transition() {  # <timeout_secs> <state_dir> <window...>
  local timeout=$1 state=$2
  shift 2
  local windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  case "$timeout" in ''|*[!0-9]*) return 2 ;; esac
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_thurbox_events_capable || return 2
  fi

  # Map each window to its session uuid, and keep the set for matching.
  local w uuid wanted=""
  for w in "${windows[@]}"; do
    fm_backend_thurbox_parse_target "$w" || continue
    wanted="$wanted $FM_BACKEND_THURBOX_SESSION"
  done
  [ -n "$wanted" ] || return 2

  local reader=()
  while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    reader+=("$uuid")
  done <<EOF
$(fm_backend_thurbox_event_reader_cmd)
EOF
  [ "${#reader[@]}" -gt 0 ] || return 2

  # Resume where the last wait stopped. The caller waits in bounded windows and
  # the stream is not running between them, so without this every transition
  # landing in that gap is simply never seen - a crewmate could go blocked and
  # nothing would notice until something else tripped over it. thurbox stamps
  # every event with a monotonic seq and `--since` replays exactly what was
  # missed; its own help names this case, "the gap a stream otherwise has across
  # a restart".
  #
  # With no cursor yet this deliberately starts from now rather than replaying
  # the machine's whole history into a first arm.
  local cursor_file since=""
  cursor_file=$(fm_backend_thurbox_watch_cursor_path "$state")
  if [ -r "$cursor_file" ]; then
    since=$(tr -dc '0-9' < "$cursor_file" 2>/dev/null)
  fi
  local reader_args=(--for-secs "$timeout")
  [ -z "$since" ] || reader_args+=(--since "$since")

  # The reader runs inside a process substitution, so its own exit status is
  # not directly available to this shell; a killed or crashed `watch` and an
  # ordinary `--for-secs` expiry both just end the stream. Recording the exit
  # status from inside that subshell is what tells them apart: expiry exits 0
  # (verified against 2.18.0), while a runtime or stream error exits nonzero.
  # Without this, a reader that keeps dying immediately looks identical to a
  # healthy empty window, and the caller would relaunch it in a tight loop
  # instead of falling back to polling.
  local reader_status_file
  reader_status_file=$(mktemp "${TMPDIR:-/tmp}/fm-thurbox-watch-status.XXXXXX" 2>/dev/null) || return 2

  local line seq session state_field agent from_field heuristic record
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    seq=$(printf '%s' "$line" | jq -r '.seq // empty' 2>/dev/null)
    session=$(printf '%s' "$line" | jq -r '.session // empty' 2>/dev/null) || continue
    if [ -z "$session" ]; then
      fm_backend_thurbox_watch_cursor_set "$cursor_file" "$seq"
      continue
    fi
    case " $wanted " in
      *" $session "*) ;;
      *) fm_backend_thurbox_watch_cursor_set "$cursor_file" "$seq"; continue ;;
    esac
    state_field=$(printf '%s' "$line" | jq -r '.state // empty' 2>/dev/null)
    agent=$(printf '%s' "$line" | jq -r '.agent // empty' 2>/dev/null)
    from_field=$(printf '%s' "$line" | jq -r '.from_state // empty' 2>/dev/null)
    heuristic=$(printf '%s' "$line" | jq -r '.hook_blocked_is_heuristic // empty' 2>/dev/null)
    record=$(fm_backend_thurbox_normalize_event "$session" "$state_field" "$agent" "$from_field")
    if record=$(fm_backend_thurbox_apply_transition "$state" "$record" "$heuristic"); then
      # Stop the cursor AT the handled edge, never past it: the events behind it
      # in this window are unread, and must replay on the next wait rather than
      # being swallowed by the early return.
      fm_backend_thurbox_watch_cursor_set "$cursor_file" "$seq"
      printf '%s' "$record"
      rm -f "$reader_status_file" 2>/dev/null || true
      return 0
    fi
    fm_backend_thurbox_watch_cursor_set "$cursor_file" "$seq"
  done < <("${reader[@]}" "${reader_args[@]}" 2>/dev/null; printf '%s\n' "$?" >"$reader_status_file")

  local reader_status
  reader_status=$(cat "$reader_status_file" 2>/dev/null)
  rm -f "$reader_status_file" 2>/dev/null || true
  [ "$reader_status" = 0 ] || return 2

  return 1
}
