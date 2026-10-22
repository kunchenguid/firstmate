#!/usr/bin/env bash
# bin/backends/rex.sh - the Rex session-provider adapter (EXPERIMENTAL).
#
# Rex (https://www.superlogical.com/rex) is a terminal multiplexer with a
# server > session > window (tab) > block (pane) hierarchy and a scriptable
# `rex` CLI. This adapter is a session provider ONLY: the worktree provider
# stays treehouse. Sourced only through bin/fm-backend.sh's fm_backend_source
# in normal operation; the unit tests source it directly.
#
# Container shape: ONE Rex window (tab) PER TASK, in a per-home session that
# fm_backend_rex_task_session_locked alone chooses and names:
#
#   - The primary home's ships and scouts open in ONE session labeled
#     `fm-local`, never in the session Firstmate itself runs in.
#   - Each secondmate home has ONE session labeled `fm-<secondmate-id>` on the
#     Rex server of the machine it runs on. Its parent opens the secondmate
#     pane as that session's FIRST tab, and the secondmate's own workers open
#     there as further tabs.
#
# A session label is display plus an identity cross-check, never routing: a
# relaunch or reclaim reuses the session its record names while that session
# is live and still carries the label; otherwise the one live session with the
# label is adopted, and one is created (its first tab is the task tab) when
# none exists. Two or more sessions with the label refuse as ambiguous, and a
# parent never adopts an unrecorded `fm-<id>` session for a new secondmate
# pane (another parent home may own it). All of this runs under a home-wide
# lock shared with the retirement of a session once it holds nothing. Tabs
# are created with `--focus=false`, so a spawn never moves the captain's view.
# The Rex server is the shared container, and Firstmate never starts, stops,
# or restarts it.
#
# Target string shape: "<session-uuid>:<block-uuid>" - the bare UUIDs of the
# typed `session:<uuid>` and `block:<uuid>` ids, so the target carries exactly
# one colon and each half passes the metadata atom check. The adapter rebuilds
# the typed ids before every call.
#
# ROUTING AUTHORITY: the recorded full block id on the recorded server. Rex
# labels are NOT unique (two sessions or blocks may share one, and a
# label-addressed command then refuses as ambiguous), so the block label
# `fm-<hometag>-<id>` is only an identity cross-check and the tab label
# `<project>·<id>` is only display. The window id is advisory: moving a block
# rewrites its tab while the block id survives.
#
# Hazards this adapter enforces (docs/verification/runtime-backends.md#rex
# owns the dated evidence):
#
#   1. Autostart. Every `rex` call defaults to `--autostart=true`, and a call
#      aimed at a missing socket silently launches a fresh, empty server.
#      fm_backend_rex_cli therefore ALWAYS passes `-S <server>` and
#      `--autostart=false`; an unreachable server exits 4.
#   2. Implicit targets. `capture`, `block call`, and others fall back to
#      REX_BLOCK or the focused block when `-b` is omitted, so every call
#      passes `-s`/`-b` with full ids, and fm_backend_rex_cli strips
#      REX_SESSION, REX_BLOCK, REX_CLIENT, and REX_SERVER from its own
#      environment.
#   3. Inherited markers. REX_* reaches every descendant, including a tmux
#      server started from a Rex pane, so a marker alone never selects Rex:
#      fm_backend_rex_launcher_identity requires REX_BLOCK to be live on the
#      server, inside REX_SESSION, with that block's child process an ancestor
#      of this process.
#   4. Exit codes. With full ids, exit 3 ("target not found") is a structural
#      GONE verdict; exit 4 (server unreachable) is UNKNOWN and never dead.
#   5. No viewport-only read. `rex capture` and the `format` block method both
#      return the screen plus scrollback, and trailing blank screen rows are
#      omitted, so the visible screen cannot be located; Rex therefore stays
#      out of FM_BACKEND_VISIBLE_CAPTURE and the composer runs cursorless.
#   6. Environment. Children get the login shell's environment, never the
#      calling CLI's, and a server started with `rex server run` exports no
#      REX_SERVER, so fm-spawn exports the recorded server into the worker
#      shell itself.
#
# Server selection (fm_backend_rex_server): FM_BACKEND_REX_SERVER (set by
# container_ensure for one spawn, or by a caller), then the task record whose
# `window=` is the target (`rex_server=`), then FM_REX_SERVER (an operator or
# lab choice), then REX_SERVER, then the default local server's own endpoint
# read with `--autostart=false`.
#
# Requires: rex (bundled with the Rex app; see fm_backend_rex_bin) and jq.
# Bootstrap detects these through fm_backend_required_tools only when rex is
# the resolved backend; container_ensure gates them again before spawning.

# FM_HOME fallback for this file's own unit tests, which source it directly;
# every real caller sets FM_HOME before sourcing bin/fm-backend.sh.
FM_BACKEND_REX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_REX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-agent-process-lib.sh"

# Verified floor: the server API revision and the methods this adapter calls.
FM_BACKEND_REX_MIN_API=4
FM_BACKEND_REX_REQUIRED_METHODS="block.close session.new_window session.set_block_label com.superlogical.terminal.process com.superlogical.terminal.format"

# fm_backend_rex_bin: the rex CLI. The app exports REX_BIN_DIR into every pane
# and the CLI there matches the server it ships with, so it wins; then PATH,
# then the app bundle's well-known location.
FM_BACKEND_REX_BUNDLE_BIN="${FM_BACKEND_REX_BUNDLE_BIN:-$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex}"
fm_backend_rex_bin() {
  if [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ]; then
    printf '%s' "$REX_BIN_DIR/rex"
    return 0
  fi
  if command -v rex >/dev/null 2>&1; then
    printf 'rex'
    return 0
  fi
  if [ -x "$FM_BACKEND_REX_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_REX_BUNDLE_BIN"
    return 0
  fi
  return 1
}

fm_backend_rex_tool_check() {
  fm_backend_rex_bin >/dev/null 2>&1 || {
    echo "error: backend=rex selected but the 'rex' CLI was not found in REX_BIN_DIR, on PATH, or at $FM_BACKEND_REX_BUNDLE_BIN (https://www.superlogical.com/rex/docs/installation)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=rex selected but 'jq' is not installed (required to parse rex's JSON output)" >&2
    return 1
  }
  return 0
}

# fm_backend_rex_raw: the rex CLI with this process's REX_* scrubbed (hazard
# 2). Only fm_backend_rex_cli and the one default-endpoint discovery read call
# it; every other call goes through fm_backend_rex_cli.
fm_backend_rex_raw() { # <rex-args...>
  local bin
  bin=$(fm_backend_rex_bin) || return 4
  env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT -u REX_SERVER "$bin" "$@"
}

# fm_backend_rex_default_server: the default local server's own endpoint, or
# failure when none is running. Never starts one.
fm_backend_rex_default_server() {
  local out endpoint
  out=$(fm_backend_rex_raw --autostart=false server status --json 2>/dev/null) || return 1
  endpoint=$(printf '%s' "$out" | jq -r '.endpoint // empty' 2>/dev/null)
  [ -n "$endpoint" ] || return 1
  printf '%s' "$endpoint"
}

# fm_backend_rex_server_of_target: the `rex_server=` recorded by the task
# whose `window=` is <target>, or failure.
fm_backend_rex_server_of_target() { # <target>
  local target=$1 meta window server
  for meta in "${STATE:-$FM_HOME/state}"/*.meta; do
    [ -f "$meta" ] || continue
    window=$(sed -n 's/^window=//p' "$meta" 2>/dev/null | tail -1)
    [ "$window" = "$target" ] || continue
    server=$(sed -n 's/^rex_server=//p' "$meta" 2>/dev/null | tail -1)
    [ -n "$server" ] || return 1
    printf '%s' "$server"
    return 0
  done
  return 1
}

# fm_backend_rex_server: the server a call for [target] must address (order in
# the header). Fails when no server can be named, which callers read as
# unreachable.
fm_backend_rex_server() { # [target]
  local target=${1:-} server
  if [ -n "${FM_BACKEND_REX_SERVER:-}" ]; then
    printf '%s' "$FM_BACKEND_REX_SERVER"
    return 0
  fi
  if [ -n "$target" ] && server=$(fm_backend_rex_server_of_target "$target"); then
    printf '%s' "$server"
    return 0
  fi
  if [ -n "${FM_REX_SERVER:-}" ]; then
    printf '%s' "$FM_REX_SERVER"
    return 0
  fi
  if [ -n "${REX_SERVER:-}" ]; then
    printf '%s' "$REX_SERVER"
    return 0
  fi
  fm_backend_rex_default_server
}

# fm_backend_rex_cli: `rex -S <server> --autostart=false <args...>` with REX_*
# scrubbed (hazards 1 and 2). FM_BACKEND_REX_TARGET_HINT, when set, names the
# task target whose recorded server applies. Returns rex's own exit status,
# and 4 when no server can be named.
fm_backend_rex_cli() { # <rex-args...>
  local server
  server=$(fm_backend_rex_server "${FM_BACKEND_REX_TARGET_HINT:-}") || {
    echo "error: no Rex server could be named (no recorded server, FM_REX_SERVER, REX_SERVER, or running default server)" >&2
    return 4
  }
  fm_backend_rex_raw -S "$server" --autostart=false "$@"
}

# fm_backend_rex_cli_json: a `--json` call whose stdout must stay parseable;
# stderr is relayed only when the call fails.
fm_backend_rex_cli_json() { # <rex-args...>
  local err status
  err=$(mktemp "${TMPDIR:-/tmp}/fm-rex-err.XXXXXX") || return 1
  fm_backend_rex_cli "$@" 2>"$err"
  status=$?
  [ "$status" -eq 0 ] || cat "$err" >&2
  rm -f "$err"
  return "$status"
}

# fm_backend_rex_version_check: refuse a missing CLI, an unreachable server,
# or a server below the verified API floor or lacking a method this adapter
# calls. `rex version`'s 0.0.<build> string is not a usable floor, so the
# server's api_revision is the gate. Never starts a server (hazard 1).
fm_backend_rex_version_check() {
  local status rc api methods method server
  fm_backend_rex_tool_check || return 1
  server=$(fm_backend_rex_server) || {
    echo "error: backend=rex selected but no Rex server is running; start the Rex app (Firstmate never starts the Rex server)" >&2
    return 1
  }
  status=$(FM_BACKEND_REX_SERVER=$server fm_backend_rex_cli server status --json 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 4 ]; then
      echo "error: the Rex server at $server is not reachable (exit 4); start the Rex app (Firstmate never starts the Rex server)" >&2
    else
      echo "error: 'rex server status' failed against $server (exit $rc)" >&2
    fi
    return 1
  fi
  api=$(printf '%s' "$status" | jq -r '.api_revision // empty' 2>/dev/null)
  case "$api" in
    '' | *[!0-9]*)
      echo "error: could not read the Rex server's api_revision at $server; refusing an unverified Rex build" >&2
      return 1
      ;;
  esac
  if [ "$api" -lt "$FM_BACKEND_REX_MIN_API" ]; then
    echo "error: the Rex server at $server speaks API revision $api, older than the verified floor $FM_BACKEND_REX_MIN_API; update Rex before using backend=rex" >&2
    return 1
  fi
  methods=$(FM_BACKEND_REX_SERVER=$server fm_backend_rex_cli api list -q 2>/dev/null) || {
    echo "error: 'rex api list' failed against $server; refusing an unverified Rex build" >&2
    return 1
  }
  for method in $FM_BACKEND_REX_REQUIRED_METHODS; do
    printf '%s\n' "$methods" | grep -Fqx "$method" || {
      echo "error: the Rex server at $server lacks the required API method '$method'; update Rex before using backend=rex" >&2
      return 1
    }
  done
  return 0
}

# fm_backend_rex_container_ensure: the spawn-time gate. Pins the server for
# this spawn in FM_BACKEND_REX_SERVER and records its instance id in
# FM_BACKEND_REX_SERVER_INSTANCE (so recovery can tell a restarted server from
# a closed pane). Must run in the spawning shell, not a subshell.
fm_backend_rex_container_ensure() {
  local server status
  fm_backend_rex_version_check || return 1
  server=$(fm_backend_rex_server) || return 1
  status=$(FM_BACKEND_REX_SERVER=$server fm_backend_rex_cli server status --json 2>/dev/null) || return 1
  FM_BACKEND_REX_SERVER=$server
  FM_BACKEND_REX_SERVER_INSTANCE=$(printf '%s' "$status" | jq -r '.instance_id // empty' 2>/dev/null)
  export FM_BACKEND_REX_SERVER FM_BACKEND_REX_SERVER_INSTANCE
  return 0
}

fm_backend_rex_home_label() {
  fm_backend_hometag
}

# fm_backend_rex_scoped_name: the block label cross-checking a task's
# identity, home-scoped so two homes on one server never cross-match.
fm_backend_rex_scoped_name() { # <fm-task-label>
  local label=$1 rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(fm_backend_rex_home_label)" "$rest"
}

# fm_backend_rex_session_label: the label of this home's worker session -
# `fm-local` for the primary home, `fm-<secondmate-id>` for a secondmate home.
fm_backend_rex_session_label() {
  local tag
  tag=$(fm_backend_rex_home_label)
  tag=${tag%-*}
  case "$tag" in
    2ndmate-?*) printf 'fm-%s' "${tag#2ndmate-}" ;;
    *) printf 'fm-local' ;;
  esac
}

fm_backend_rex_uuid_valid() { # <uuid>
  [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# fm_backend_rex_parse_target: split "<session-uuid>:<block-uuid>" and set
# FM_BACKEND_REX_SESSION_ID/FM_BACKEND_REX_BLOCK_ID to the typed full ids.
fm_backend_rex_parse_target() { # <target>
  local target=$1 sid bid
  sid=${target%%:*}
  bid=${target#*:}
  [ "$bid" != "$target" ] && fm_backend_rex_uuid_valid "$sid" && fm_backend_rex_uuid_valid "$bid" || return 1
  FM_BACKEND_REX_SESSION_ID="session:$sid"
  FM_BACKEND_REX_BLOCK_ID="block:$bid"
  return 0
}

# fm_backend_rex_block_inspect: `block inspect <block-id> --json` for the
# target, on the target's server; returns rex's exit status.
fm_backend_rex_block_inspect() { # <target>
  fm_backend_rex_parse_target "$1" || return 2
  FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli block inspect "$FM_BACKEND_REX_BLOCK_ID" --json 2>/dev/null
}

# fm_backend_rex_target_ready: the recorded block exists in the recorded
# session and, when the owning task label is known, carries its scoped label
# (a renamed block is refused, never silently targeted). Sets
# FM_BACKEND_REX_READY_RC: 0 ready, 3 gone, 4 unreachable, 1 anything else.
fm_backend_rex_target_ready() { # <target> [expected-label]
  local target=$1 expected_label=${2:-} out rc
  FM_BACKEND_REX_READY_RC=1
  fm_backend_rex_parse_target "$target" || return 1
  out=$(fm_backend_rex_block_inspect "$target")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in 3 | 4) FM_BACKEND_REX_READY_RC=$rc ;; esac
    return 1
  fi
  [ "$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)" = "$FM_BACKEND_REX_SESSION_ID" ] || return 1
  if [ -n "$expected_label" ]; then
    [ "$(printf '%s' "$out" | jq -r '.block.label // empty' 2>/dev/null)" = "$(fm_backend_rex_scoped_name "$expected_label")" ] || return 1
  fi
  FM_BACKEND_REX_READY_RC=0
  return 0
}

# fm_backend_rex_block_call: `block call -s <session> -b <block> <method>
# [json]` on the target's server; returns rex's exit status.
fm_backend_rex_block_call() { # <target> <method> [json]
  fm_backend_rex_parse_target "$1" || return 2
  FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli block call -s "$FM_BACKEND_REX_SESSION_ID" -b "$FM_BACKEND_REX_BLOCK_ID" "${@:2}" 2>/dev/null
}

# fm_backend_rex_launcher_identity: whether this process runs inside a Rex pane
# on the selected server (hazard 3). Returns 0 when REX_BLOCK is live there,
# belongs to REX_SESSION, and its child process is an ancestor of this
# process; 1 when it is not; 2 when the server could not be read. On 0, sets
# FM_BACKEND_REX_LAUNCHER_SESSION to the launcher's typed session id.
FM_BACKEND_REX_ANCESTRY_HOPS=64
fm_backend_rex_launcher_identity() {
  local block=${REX_BLOCK:-} session=${REX_SESSION:-} out rc child pid ppid hops=0
  FM_BACKEND_REX_LAUNCHER_SESSION=
  case "$block:$session" in block:*:session:*) ;; *) return 1 ;; esac
  out=$(FM_BACKEND_REX_TARGET_HINT='' fm_backend_rex_cli block inspect "$block" --json 2>/dev/null)
  rc=$?
  case "$rc" in
    0) ;;
    3) return 1 ;;
    *) return 2 ;;
  esac
  [ "$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)" = "$session" ] || return 1
  out=$(FM_BACKEND_REX_TARGET_HINT='' fm_backend_rex_cli block call -s "$session" -b "$block" process 2>/dev/null) || return 2
  child=$(printf '%s' "$out" | jq -r '.child.pid // empty' 2>/dev/null)
  case "$child" in '' | *[!0-9]*) return 2 ;; esac
  pid=$$
  while [ "$hops" -lt "$FM_BACKEND_REX_ANCESTRY_HOPS" ]; do
    if [ "$pid" = "$child" ]; then
      FM_BACKEND_REX_LAUNCHER_SESSION=$session
      return 0
    fi
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$ppid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid=$ppid
    hops=$((hops + 1))
  done
  return 1
}

# fm_backend_rex_detect: the runtime-detection probe for bin/fm-backend.sh -
# true only when REX_* markers are present AND the launcher identity is proven.
fm_backend_rex_detect() {
  [ -n "${REX_BLOCK:-}" ] && [ -n "${REX_SESSION:-}" ] || return 1
  fm_backend_rex_bin >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_backend_rex_launcher_identity
}

# fm_backend_rex_session_lock / _unlock: one home-wide lock (the shared
# stale-owner lock from bin/fm-wake-lib.sh) serializing choosing or creating
# this home's session plus opening a tab against retiring an emptied session.
# Bounded: a spawn that cannot get it refuses, cleanup skips.
FM_BACKEND_REX_LOCK_ATTEMPTS="${FM_BACKEND_REX_LOCK_ATTEMPTS:-300}"
fm_backend_rex_session_lock_path() {
  printf '%s/.rex-session.lock' "${STATE:-$FM_HOME/state}"
}
fm_backend_rex_session_lock() {
  local attempt=0 lock
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_BACKEND_REX_ROOT/bin/fm-wake-lib.sh"
  fi
  lock=$(fm_backend_rex_session_lock_path)
  mkdir -p "${lock%/*}" 2>/dev/null || return 1
  while [ "$attempt" -lt "$FM_BACKEND_REX_LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}
fm_backend_rex_session_unlock() {
  fm_lock_release "$(fm_backend_rex_session_lock_path)" || true
}

# fm_backend_rex_label_in_use: whether any live block on the server carries
# <label>; fails when an inventory cannot be read, so a caller about to create
# never mistakes an unreadable list for "none".
fm_backend_rex_label_in_use() { # <label>
  local label=$1 list sid blocks
  list=$(fm_backend_rex_cli ls --json 2>/dev/null) || return 2
  for sid in $(printf '%s' "$list" | jq -r '.sessions[]?.session_id' 2>/dev/null); do
    blocks=$(fm_backend_rex_cli block ls -s "$sid" --json 2>/dev/null) || return 2
    printf '%s' "$blocks" | jq -e --arg l "$label" 'any(.blocks[]?; .label == $l)' >/dev/null 2>&1 && return 0
  done
  return 1
}

# fm_backend_rex_session_live: whether typed session <sid> is live on the
# selected server, optionally carrying <label>. 0 live, 3 gone (or labeled
# otherwise), anything else unreadable.
fm_backend_rex_session_live() { # <typed-session-id> [label]
  local sid=$1 label=${2:-} view rc
  view=$(fm_backend_rex_cli session inspect "$sid" --json 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -z "$label" ] || [ "$(printf '%s' "$view" | jq -r '.label // empty' 2>/dev/null)" = "$label" ] || return 3
  return 0
}

# fm_backend_rex_task_session_locked: THE session placement and naming
# decision (header "Container shape"; caller holds the session lock). For a
# tab owned by <home> - a secondmate pane its parent opens when <pane> is 1 -
# sets FM_BACKEND_REX_PLACE_LABEL to that home's session label and
# FM_BACKEND_REX_PLACE_SESSION to the typed id of the live session to open the
# tab in, or to empty when a new session must be created. In order: the
# recorded <preferred> session while live and still labeled; for a secondmate
# home's own worker, the proven session the secondmate runs in; the one live
# session carrying the label. Refuses an unreadable inventory, two or more
# labeled sessions, an unrecorded labeled session for a secondmate pane, and
# the primary home's supervisor session.
fm_backend_rex_task_session_locked() { # <home> <pane:0|1> [preferred-session-uuid]
  local home=$1 pane=$2 preferred=${3:-} label rc list count
  FM_BACKEND_REX_PLACE_SESSION=
  label=$(FM_HOME=$home fm_backend_rex_session_label)
  FM_BACKEND_REX_PLACE_LABEL=$label
  if [ "$label" = fm-local ] && [ "$(tr -d '[:space:]' 2>/dev/null <"$home/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER")" = local ]; then
    echo "error: secondmate id 'local' would share the primary home's Rex session label fm-local; refusing" >&2
    return 1
  fi
  if [ -n "$preferred" ] && fm_backend_rex_uuid_valid "$preferred"; then
    fm_backend_rex_session_live "session:$preferred" "$label"
    rc=$?
    case "$rc" in
      0) FM_BACKEND_REX_PLACE_SESSION="session:$preferred" ;;
      3) ;;
      *)
        echo "error: could not read the recorded Rex session session:$preferred; refusing to choose a session" >&2
        return 1
        ;;
    esac
  fi
  if [ -z "$FM_BACKEND_REX_PLACE_SESSION" ] && [ "$pane" = 0 ] && [ "$label" != fm-local ] &&
    fm_backend_rex_launcher_identity && fm_backend_rex_session_live "$FM_BACKEND_REX_LAUNCHER_SESSION" "$label"; then
    FM_BACKEND_REX_PLACE_SESSION=$FM_BACKEND_REX_LAUNCHER_SESSION
  fi
  if [ -z "$FM_BACKEND_REX_PLACE_SESSION" ]; then
    if ! list=$(fm_backend_rex_cli ls --json 2>/dev/null) ||
      ! printf '%s' "$list" | jq -e '.sessions | type == "array"' >/dev/null 2>&1; then
      echo "error: could not read the Rex session inventory; refusing to choose a session" >&2
      return 1
    fi
    count=$(printf '%s' "$list" | jq -r --arg l "$label" '[.sessions[] | select(.label == $l)] | length')
    case "$count" in
      0) return 0 ;;
      1)
        if [ "$pane" = 1 ]; then
          echo "error: a Rex session labeled '$label' already exists but is not the one this secondmate's record names; refusing to adopt it (close or rename it)" >&2
          return 1
        fi
        FM_BACKEND_REX_PLACE_SESSION=$(printf '%s' "$list" | jq -r --arg l "$label" '.sessions[] | select(.label == $l) | .session_id')
        ;;
      *)
        echo "error: $count Rex sessions are labeled '$label'; refusing to guess which one this home owns (close or rename the extras)" >&2
        return 1
        ;;
    esac
  fi
  if [ "$label" = fm-local ] && fm_backend_rex_launcher_identity &&
    [ "$FM_BACKEND_REX_LAUNCHER_SESSION" = "$FM_BACKEND_REX_PLACE_SESSION" ]; then
    echo "error: Firstmate's own Rex session is labeled fm-local; workers never open in the supervisor's session (rename it)" >&2
    return 1
  fi
  return 0
}

# fm_backend_rex_create_task: open the task's tab (`window new --focus=false
# --keep-open`) in the home session, label its block with the scoped name,
# and echo "<session-uuid> <window-uuid> <block-uuid>". Refuses a scoped name
# already live anywhere on the server. With <home>, the tab is the secondmate
# pane of that other home (header "Secondmates"); <preferred-session-uuid> is
# the session a relaunch or reclaim record names, used while it is live.
fm_backend_rex_create_task() { # <label> <cwd> [home] [preferred-session-uuid]
  local name rc
  name=$(fm_backend_rex_scoped_name "$1")
  fm_backend_rex_session_lock || {
    echo "error: could not take the Rex session lock; refusing to create '$name'" >&2
    return 1
  }
  fm_backend_rex_create_task_locked "$@"
  rc=$?
  fm_backend_rex_session_unlock
  return "$rc"
}

fm_backend_rex_create_task_locked() { # <label> <cwd> [home] [preferred-session-uuid]
  local label=$1 cwd=$2 home=${3:-} preferred=${4:-} name tab pane=0 sid out wid bid rc
  name=$(fm_backend_rex_scoped_name "$label")
  fm_backend_rex_label_in_use "$name"
  rc=$?
  case "$rc" in
    0)
      echo "error: a Rex block labeled '$name' already exists" >&2
      return 1
      ;;
    1) ;;
    *)
      echo "error: could not read the Rex block inventory; refusing to create '$name'" >&2
      return 1
      ;;
  esac
  if [ -n "$home" ]; then
    pane=1
    tab="2ndmate·${label#fm-}"
  else
    home=$FM_HOME
    tab="${cwd##*/}·${label#fm-}"
  fi
  fm_backend_rex_task_session_locked "$home" "$pane" "$preferred" || return 1
  sid=$FM_BACKEND_REX_PLACE_SESSION
  if [ -z "$sid" ]; then
    # A new session: its own first tab becomes the task tab.
    out=$(fm_backend_rex_cli_json new "$FM_BACKEND_REX_PLACE_LABEL" -c "$cwd" --window "$tab" --keep-open --json) || {
      echo "error: rex could not create session '$FM_BACKEND_REX_PLACE_LABEL' for '$name'" >&2
      return 1
    }
    sid=$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)
    out=$(printf '%s' "$out" | jq -c '.initial_windows[0] // empty' 2>/dev/null)
  else
    out=$(fm_backend_rex_cli_json window new -s "$sid" "$tab" -c "$cwd" --focus=false --keep-open --json) || {
      echo "error: rex window new failed for '$name'" >&2
      return 1
    }
    # A secondmate pane is its session's first tab even in a reused session.
    if [ "$pane" = 1 ]; then
      fm_backend_rex_cli window move -s "$sid" "$(printf '%s' "$out" | jq -r '.window_id // empty' 2>/dev/null)" --index 1 >/dev/null 2>&1 || true
    fi
  fi
  wid=$(printf '%s' "$out" | jq -r '.window_id // empty' 2>/dev/null)
  bid=$(printf '%s' "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null)
  if [ -z "$sid" ] || [ -z "$wid" ] || [ -z "$bid" ]; then
    echo "error: could not parse session/window/block ids from rex output: $out" >&2
    return 1
  fi
  if ! fm_backend_rex_cli block rename -s "$sid" "$bid" "$name" >/dev/null 2>&1; then
    fm_backend_rex_cli block close -s "$sid" "$bid" >/dev/null 2>&1 || true
    fm_backend_rex_retire_session_locked "$sid" "$FM_BACKEND_REX_PLACE_LABEL"
    echo "error: rex could not label block $bid as '$name'; closed it" >&2
    return 1
  fi
  printf '%s %s %s' "${sid#session:}" "${wid#window:}" "${bid#block:}"
}

# fm_backend_rex_current_path: the live kernel cwd of the block's foreground
# process, from the `process` method; empty on any error.
fm_backend_rex_current_path() { # <target> [expected-label]
  local out
  fm_backend_rex_target_ready "$1" "${2:-}" || return 0
  out=$(fm_backend_rex_block_call "$1" process) || return 0
  printf '%s' "$out" | jq -r '.foreground.cwd // empty' 2>/dev/null
}

# fm_backend_rex_send_literal: TEXT as raw, unsubmitted input on stdin, which
# avoids option parsing of a payload starting with `-` and argv limits.
fm_backend_rex_send_literal() { # <target> <text> [expected-label]
  fm_backend_rex_target_ready "$1" "${3:-}" || return 1
  printf '%s' "$2" | FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli send -s "$FM_BACKEND_REX_SESSION_ID" -b "$FM_BACKEND_REX_BLOCK_ID" >/dev/null 2>&1
}

# fm_backend_rex_normalize_key: Firstmate's tmux-style key names to Rex key
# syntax. Unknown names are refused rather than guessed.
fm_backend_rex_normalize_key() { # <key>
  case "$1" in
    Enter) printf 'enter' ;;
    Escape) printf 'escape' ;;
    Tab) printf 'tab' ;;
    Space) printf 'space' ;;
    BSpace) printf 'backspace' ;;
    C-c) printf 'ctrl+c' ;;
    C-d) printf 'ctrl+d' ;;
    C-u) printf 'ctrl+u' ;;
    C-l) printf 'ctrl+l' ;;
    *) return 1 ;;
  esac
}

fm_backend_rex_send_key() { # <target> <key> [expected-label]
  local key
  key=$(fm_backend_rex_normalize_key "$2") || {
    echo "error: unsupported rex key '$2'" >&2
    return 1
  }
  fm_backend_rex_target_ready "$1" "${3:-}" || return 1
  FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli send-key -s "$FM_BACKEND_REX_SESSION_ID" -b "$FM_BACKEND_REX_BLOCK_ID" "$key" >/dev/null 2>&1
}

# fm_backend_rex_send_text_line: one line of TEXT, then Enter. 0 submitted,
# 1 nothing pending (typing failed, or Ctrl+C cleared it), 2 possibly pending.
fm_backend_rex_send_text_line() { # <target> <text> [expected-label]
  fm_backend_rex_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_rex_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_rex_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
}

# fm_backend_rex_capture: bounded plain-text tail of screen plus scrollback.
fm_backend_rex_capture() { # <target> <lines> [expected-label]
  fm_backend_rex_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} raw
  case "$lines" in '' | *[!0-9]*) lines=200 ;; esac
  raw=$(FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli capture -s "$FM_BACKEND_REX_SESSION_ID" -b "$FM_BACKEND_REX_BLOCK_ID" --trim 2>/dev/null) || return 1
  printf '%s\n' "$raw" | tr -d '\r' | tail -n "$lines"
}

# fm_backend_rex_composer_capture: the styled tail (`--format vt` keeps SGR
# styling) the shared classifier reads; carriage returns are dropped.
fm_backend_rex_composer_capture() { # <target> [expected-label]
  fm_backend_rex_target_ready "$1" "${2:-}" || return 1
  local raw
  raw=$(FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli capture -s "$FM_BACKEND_REX_SESSION_ID" -b "$FM_BACKEND_REX_BLOCK_ID" --format vt --trim 2>/dev/null) || return 1
  printf '%s\n' "$raw" | tr -d '\r' | tail -n "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_rex_composer_caps: static capability facts (bin/fm-composer-lib.sh
# owns the model). No cursor row: the screen cannot be located (hazard 5).
fm_backend_rex_composer_caps() {
  printf 'styled=1\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_rex_composer_state() { # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_rex_composer_capture "$1" "${2:-}") || {
    printf 'unknown'
    return 0
  }
  verdict=$(fm_composer_classify_screen "$(fm_backend_rex_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_rex_send_text_submit: type once, then the shared verify-and-retry
# Enter loop (bin/fm-composer-lib.sh: fm_composer_submit_retry_core).
fm_backend_rex_send_text_submit() { # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_rex_parse_target "$target" || {
    printf 'unknown'
    return 0
  }
  fm_backend_rex_send_literal "$target" "$text" "$expected_label" || {
    printf 'send-failed'
    return 0
  }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_rex_send_key fm_backend_rex_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
}

# fm_backend_rex_agent_state: the recovery-grade state (vocabulary owned by
# bin/fm-backend.sh's fm_backend_agent_state). Exit 3 on the recorded full
# block id is `missing`; any other failed read is `unreadable` (hazard 4). A
# recorded `last_exit` (the kept-open pane's program ended) is `dead`.
# Otherwise two independent sources name the foreground: Rex's own
# `process.foreground` record and the kernel's foreground process group on
# the block's tty. Either naming a verified harness is `alive`; only a group
# that is nothing but shells is `dead`; anything else is `ambiguous`.
fm_backend_rex_agent_state() { # <target>
  local target=$1 out rc fg_pid fg_path fg_argv0 tty pid pgid tpgid comm args argv0
  local fg_seen=0 fg_shell=0 fg_other=0
  fm_backend_rex_parse_target "$target" || {
    printf 'unreadable'
    return 0
  }
  out=$(fm_backend_rex_block_inspect "$target")
  rc=$?
  case "$rc" in
    0) ;;
    3)
      printf 'missing'
      return 0
      ;;
    *)
      printf 'unreadable'
      return 0
      ;;
  esac
  [ "$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)" = "$FM_BACKEND_REX_SESSION_ID" ] || {
    printf 'unreadable'
    return 0
  }
  out=$(fm_backend_rex_block_call "$target" process)
  rc=$?
  case "$rc" in
    0) ;;
    3)
      printf 'missing'
      return 0
      ;;
    *)
      printf 'unreadable'
      return 0
      ;;
  esac
  if [ "$(printf '%s' "$out" | jq -r '.last_exit != null' 2>/dev/null)" = true ]; then
    printf 'dead'
    return 0
  fi
  fg_pid=$(printf '%s' "$out" | jq -r '.foreground.pid // empty' 2>/dev/null)
  fg_path=$(printf '%s' "$out" | jq -r '.foreground.path // .foreground.name // empty' 2>/dev/null)
  fg_argv0=$(printf '%s' "$out" | jq -r '.foreground.argv0 // empty' 2>/dev/null)
  case "$fg_pid" in '' | *[!0-9]*)
    printf 'unreadable'
    return 0
    ;;
  esac
  if [ "$(fm_agent_process_classify "$fg_path" "$fg_argv0" "" "$fg_pid")" = agent ]; then
    printf 'alive'
    return 0
  fi
  tty=$(ps -o tty= -p "$fg_pid" 2>/dev/null | tr -d '[:space:]')
  case "$tty" in
    '' | '?' | '??') ;;
    *)
      while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        fg_seen=1
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        case "$(fm_agent_process_classify "$comm" "$argv0" "$args" "$pid")" in
          agent)
            printf 'alive'
            return 0
            ;;
          shell) fg_shell=1 ;;
          *) fg_other=1 ;;
        esac
      done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
      ;;
  esac
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi
  case "$(fm_agent_process_classify "$fg_path" "$fg_argv0" "")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_rex_endpoint_absence_recheck: the absence proof behind
# fm_control_endpoint_absence_verdict. Every read already addresses the
# server the record names by full id and never starts a server, so a
# `missing` here is exit 3 from that reachable server - the block is gone (a
# restarted server ended every program it ran) - and an unreachable server
# stays `unreadable`.
fm_backend_rex_endpoint_absence_recheck() { # <target>
  fm_backend_rex_agent_state "$1"
}

# fm_backend_rex_kill: close the task's block, then prove it gone (exit 3) and
# retire this home's own session if that was its last tab. 0 = closed or
# already gone; 1 = the block may still be live (unreachable server, a label
# that no longer matches, or a close that did not take).
fm_backend_rex_kill() { # <target> [unused] [expected-label]
  local target=$1 expected_label=${3:-}
  if ! fm_backend_rex_target_ready "$target" "$expected_label"; then
    case "$FM_BACKEND_REX_READY_RC" in
      3)
        fm_backend_rex_retire_home_session "$FM_BACKEND_REX_SESSION_ID" "$target" "$expected_label"
        return 0
        ;;
      4)
        echo "error: the Rex server for $target is unreachable; the task's block may still be live" >&2
        return 1
        ;;
      *)
        echo "error: the Rex block for $target does not carry the expected identity; refusing to close it" >&2
        return 1
        ;;
    esac
  fi
  FM_BACKEND_REX_TARGET_HINT=$target fm_backend_rex_cli block close -s "$FM_BACKEND_REX_SESSION_ID" "$FM_BACKEND_REX_BLOCK_ID" >/dev/null 2>&1 || true
  fm_backend_rex_block_inspect "$target" >/dev/null
  if [ "$?" -ne 3 ]; then
    echo "error: the Rex block for $target is still present after close" >&2
    return 1
  fi
  fm_backend_rex_retire_home_session "$FM_BACKEND_REX_SESSION_ID" "$target" "$expected_label"
  return 0
}

# fm_backend_rex_retire_home_session: after a task tab closes, kill the
# session it lived in once that session holds nothing. Only two labels
# qualify: this home's own `fm-local`/`fm-<id>` session, and - when the closed
# task is secondmate <id> (expected label `fm-<id>`) - the `fm-<id>` session
# its parent opened it in, which <sid> is because it came from that
# secondmate's own record. The caller's own session and any
# session with another label are never touched, and an unreadable inventory
# skips the cleanup. Runs under the session lock so a concurrent spawn cannot
# open a tab between the empty check and the kill.
fm_backend_rex_retire_home_session() { # <typed-session-id> <target> [expected-label]
  local sid=$1 target=$2 expected_label=${3:-} labels
  [ -n "$sid" ] || return 0
  [ "$sid" != "${REX_SESSION:-}" ] || return 0
  labels=$(fm_backend_rex_session_label)
  case "$expected_label" in
    fm-?*) labels="$labels $expected_label" ;;
  esac
  fm_backend_rex_session_lock || return 0
  FM_BACKEND_REX_TARGET_HINT=$target fm_backend_rex_retire_session_locked "$sid" "$labels"
  fm_backend_rex_session_unlock
  return 0
}

# fm_backend_rex_retire_session_locked: kill typed session <sid> when its label
# is one of <labels> and it holds no window and no block. `session inspect`
# omits detached blocks (a hidden away daemon lives in one), so the block
# inventory is read too. Caller holds the session lock.
fm_backend_rex_retire_session_locked() { # <typed-session-id> <labels>
  local sid=$1 labels=$2 view label blocks
  view=$(fm_backend_rex_cli session inspect "$sid" --json 2>/dev/null) || return 0
  label=$(printf '%s' "$view" | jq -r '.label // empty' 2>/dev/null)
  [ -n "$label" ] || return 0
  case " $labels " in *" $label "*) ;; *) return 0 ;; esac
  printf '%s' "$view" | jq -e '((.windows // []) | length) == 0' >/dev/null 2>&1 || return 0
  blocks=$(fm_backend_rex_cli block ls -s "$sid" --json 2>/dev/null) || return 0
  printf '%s' "$blocks" | jq -e '(.blocks | type) == "array" and (.blocks | length) == 0' >/dev/null 2>&1 || return 0
  fm_backend_rex_cli kill "$sid" >/dev/null 2>&1 || true
  return 0
}

# fm_backend_rex_list_live: every live block on the selected server whose
# label is scoped to this home, as "<session-uuid>:<block-uuid>\tfm-<id>".
# Read-only: an unreachable server lists nothing.
fm_backend_rex_list_live() {
  local list sid prefix bid label
  prefix="fm-$(fm_backend_rex_home_label)-"
  list=$(fm_backend_rex_cli ls --json 2>/dev/null) || return 0
  for sid in $(printf '%s' "$list" | jq -r '.sessions[]?.session_id' 2>/dev/null); do
    while IFS=$'\t' read -r bid label; do
      [ -n "$bid" ] || continue
      printf '%s:%s\tfm-%s\n' "${sid#session:}" "${bid#block:}" "${label#"$prefix"}"
    done < <(fm_backend_rex_cli block ls -s "$sid" --json 2>/dev/null |
      jq -r --arg p "$prefix" '.blocks[]? | select(.label | startswith($p)) | "\(.block_id)\t\(.label)"' 2>/dev/null)
  done
}

# --- away mode ----------------------------------------------------------------
# The away daemon (bin/fm-supervise-daemon.sh) injects into Firstmate's own
# pane, and bin/fm-afk-launch.sh runs that daemon in a hidden terminal. Both
# use these helpers; bin/fm-supervisor-target-lib.sh owns discovery order.

# fm_backend_rex_supervisor_target: "<session-uuid>:<block-uuid>" of the Rex
# pane this process runs in, only when fm_backend_rex_launcher_identity proves
# it (an inherited REX_BLOCK names someone else's pane). 1 when not proven.
fm_backend_rex_supervisor_target() {
  fm_backend_rex_launcher_identity || return 1
  printf '%s:%s' "${REX_SESSION#session:}" "${REX_BLOCK#block:}"
}

# fm_backend_rex_detached_create: a DETACHED block (running and addressable by
# id, but in no tab, so the captain never sees it) in typed session <sid>,
# whose login shell is handed <input> as typed input. Prints the block's
# "<session-uuid>:<block-uuid>" target.
fm_backend_rex_detached_create() { # <typed-session-id> <label> <cwd> <input>
  local sid=$1 label=$2 cwd=$3 input=$4 payload out bid
  payload=$(jq -nc --arg l "$label" --arg c "$cwd" --arg i "$input" \
    '{flavor:"com.superlogical.terminal.shell",label:$l,options:{cwd:$c,initial_input:$i}}') || return 1
  out=$(fm_backend_rex_cli_json api call -s "$sid" session.new_block "$payload") || return 1
  bid=$(printf '%s' "$out" | jq -r '.block_id // empty' 2>/dev/null)
  case "$bid" in block:*) ;; *) return 1 ;; esac
  fm_backend_rex_uuid_valid "${bid#block:}" || return 1
  printf '%s:%s' "${sid#session:}" "${bid#block:}"
}

# fm_backend_rex_block_close: close <target>'s block by full id; 0 once the
# server answers exit 3 for it (already gone included), 1 otherwise.
fm_backend_rex_block_close() { # <target>
  fm_backend_rex_parse_target "$1" || return 1
  fm_backend_rex_block_inspect "$1" >/dev/null
  [ "$?" -ne 3 ] || return 0
  FM_BACKEND_REX_TARGET_HINT=$1 fm_backend_rex_cli block close -s "$FM_BACKEND_REX_SESSION_ID" "$FM_BACKEND_REX_BLOCK_ID" >/dev/null 2>&1 || true
  fm_backend_rex_block_inspect "$1" >/dev/null
  [ "$?" -eq 3 ]
}
