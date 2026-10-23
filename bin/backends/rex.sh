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
# are created with `--focus=false`, so a spawn never moves the captain's view,
# and each new task block is resized to FM_BACKEND_REX_COLUMNS x
# FM_BACKEND_REX_ROWS, because an unviewed block starts at 80x24 (a client
# that later views it takes ownership and applies its own size).
# A worker may add side panes labeled `<block label>/<name>` to its own tab
# (bin/fm-rex-side.sh); fm_backend_rex_kill closes them with the task.
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
# `fm-<hometag>-<id>` is only an identity cross-check and the sidebar-sized
# tab label (fm_backend_rex_tab_label) is only display. The window id is
# advisory: moving a block rewrites its tab while the block id survives.
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
#   5. No viewport-only read. `rex capture` returns the screen plus scrollback,
#      so the visible viewport is DERIVED from one styled `format` read (vt
#      with extra_cursor), which ends with the full screen grid, blank rows
#      included, and then the cursor position as one trailing
#      `ESC[<row>;<col>H`: the viewport is its last size.rows rows
#      (fm_backend_rex_screen_read). An alternate-screen program's grid is the
#      screen alone, so the derivation holds on both screens; a resize landing
#      between the size read and the grid read can skew it by the size
#      difference.
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
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-transition-lib.sh"

# Verified floor: the API revision of both the CLI and the server, and the
# methods this adapter calls.
FM_BACKEND_REX_MIN_API=5
FM_BACKEND_REX_REQUIRED_METHODS="block.close session.new_window session.set_block_label com.superlogical.terminal.process com.superlogical.terminal.format"
# The size every new task block is given (header "Container shape").
FM_BACKEND_REX_COLUMNS=${FM_BACKEND_REX_COLUMNS:-200}
FM_BACKEND_REX_ROWS=${FM_BACKEND_REX_ROWS:-50}

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

# fm_backend_rex_record_field: the `<key>=` value recorded by the task whose
# `window=` is <target>, or failure.
fm_backend_rex_record_field() { # <target> <key>
  local target=$1 key=$2 meta window value
  for meta in "${STATE:-$FM_HOME/state}"/*.meta; do
    [ -f "$meta" ] || continue
    window=$(sed -n 's/^window=//p' "$meta" 2>/dev/null | tail -1)
    [ "$window" = "$target" ] || continue
    value=$(sed -n "s/^$key=//p" "$meta" 2>/dev/null | tail -1)
    [ -n "$value" ] || return 1
    printf '%s' "$value"
    return 0
  done
  return 1
}

fm_backend_rex_server_of_target() { # <target>
  fm_backend_rex_record_field "$1" rex_server
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

# fm_backend_rex_version_check: refuse a missing CLI, a CLI or server below
# the verified API floor, an unreachable server, or a server lacking a method
# this adapter calls. `rex version`'s 0.0.<build> string is not a usable
# floor, so the API revisions are the gate. Never starts a server (hazard 1).
fm_backend_rex_version_check() {
  local status rc api methods method server raw client_api
  fm_backend_rex_tool_check || return 1
  raw=$(fm_backend_rex_raw --autostart=false version 2>/dev/null) || {
    echo "error: 'rex version' failed; is Rex installed correctly?" >&2
    return 1
  }
  client_api=$(printf '%s\n' "$raw" | sed -n 's/^api: revision \([0-9][0-9]*\).*/\1/p' | head -1)
  case "$client_api" in
    '' | *[!0-9]*)
      echo "error: could not parse an API revision from 'rex version'; refusing an unverified Rex build" >&2
      return 1
      ;;
  esac
  if [ "$client_api" -lt "$FM_BACKEND_REX_MIN_API" ]; then
    echo "error: the rex CLI speaks API revision $client_api, older than the verified floor $FM_BACKEND_REX_MIN_API; update Rex before using backend=rex" >&2
    return 1
  fi
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

# fm_backend_rex_tab_label: the display-only tab label, sized for the Rex
# sidebar (at most FM_BACKEND_REX_TAB_LABEL_MAX visible characters, clipped
# with an ellipsis). An explicit display title is used as given; otherwise a
# kind marker (`Ship`, `Scout`, `Mate`) plus a condensed backlog title - the
# text after its first ": ", cut at the first ", ", " - ", or " (" - and
# otherwise the task id. jq does the slicing so multi-byte characters count
# once.
FM_BACKEND_REX_TAB_LABEL_MAX=24
fm_backend_rex_tab_label() { # <kind> <task-id> [display-title] [backlog-title]
  local marker
  case "$1" in
    scout) marker=Scout ;;
    secondmate) marker=Mate ;;
    *) marker=Ship ;;
  esac
  jq -rn --arg marker "$marker" --arg id "${2#fm-}" --arg title "${3:-}" --arg backlog "${4:-}" \
    --argjson max "$FM_BACKEND_REX_TAB_LABEL_MAX" '
    def squash: gsub("[\\s]+"; " ") | sub("^ "; "") | sub(" $"; "");
    def condense: squash
      | (if test(": .") then sub("^[^:]*: "; "") else . end)
      | (split(", ")[0] // "") | (split(" - ")[0] // "") | sub(" \\(.*$"; "") | squash;
    def clip: if length <= $max then .
      else .[0:$max - 1] as $head
        | ($head | sub(" [^ ]*$"; "")) as $word
        | (if ($word | length) >= ($max / 2) then $word else $head end)
        | sub("[ ·,:;-]+$"; "") + "…" end;
    ($title | squash) as $t
    | if $t != "" then $t | clip
      else (($backlog | condense) as $b | if $b != "" then $b else $id end) as $s
        | "\($marker) · \($s)" | clip end' 2>/dev/null
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

# fm_backend_rex_label_blocks: every live block on the server carrying
# <label>, one "<session-uuid>:<block-uuid>" target per line; fails when an
# inventory cannot be read, so a caller about to create never mistakes an
# unreadable list for "none".
fm_backend_rex_label_blocks() { # <label>
  local label=$1 list sid blocks
  list=$(fm_backend_rex_cli ls --json 2>/dev/null) || return 1
  for sid in $(printf '%s' "$list" | jq -r '.sessions[]?.session_id' 2>/dev/null); do
    blocks=$(fm_backend_rex_cli block ls -s "$sid" --json 2>/dev/null) || return 1
    printf '%s' "$blocks" | jq -r --arg l "$label" --arg s "${sid#session:}" \
      '.blocks[]? | select(.label == $l) | "\($s):\(.block_id | sub("^block:"; ""))"' 2>/dev/null
  done
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
# <tab-label> is the display label (fm_backend_rex_tab_label); without one the
# task id stands in under its kind marker. <mode> is spawn (the default) or
# reclaim: on reclaim, a block already carrying the scoped name is the husk of
# an earlier reclaim that refused before its record was republished, so a bare
# shell there is closed (and proven gone) first, while anything else refuses.
fm_backend_rex_create_task() { # <label> <cwd> [home] [preferred-session-uuid] [tab-label] [spawn|reclaim]
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

fm_backend_rex_create_task_locked() { # <label> <cwd> [home] [preferred-session-uuid] [tab-label] [spawn|reclaim]
  local label=$1 cwd=$2 home=${3:-} preferred=${4:-} tab=${5:-} mode=${6:-spawn} name pane=0 sid out wid bid husks husk state
  name=$(fm_backend_rex_scoped_name "$label")
  husks=$(fm_backend_rex_label_blocks "$name") || {
    echo "error: could not read the Rex block inventory; refusing to create '$name'" >&2
    return 1
  }
  for husk in $husks; do
    if [ "$mode" != reclaim ]; then
      echo "error: a Rex block labeled '$name' already exists" >&2
      return 1
    fi
    state=$(fm_backend_rex_agent_state "$husk")
    case "$state" in
      missing) continue ;;
      dead) ;;
      *)
        echo "error: Rex block $husk already carries '$name' and is not a bare shell ($state); refusing to open a second tab for it" >&2
        return 1
        ;;
    esac
    fm_backend_rex_block_close "$husk" || {
      echo "error: could not close the leftover Rex block $husk carrying '$name'" >&2
      return 1
    }
  done
  if [ -n "$home" ]; then
    pane=1
    [ -n "$tab" ] || tab=$(fm_backend_rex_tab_label secondmate "$label")
  else
    home=$FM_HOME
    [ -n "$tab" ] || tab=$(fm_backend_rex_tab_label ship "$label")
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
  fm_backend_rex_cli block call -s "$sid" -b "$bid" resize \
    "{\"columns\":$FM_BACKEND_REX_COLUMNS,\"rows\":$FM_BACKEND_REX_ROWS}" >/dev/null 2>&1 ||
    echo "warning: could not resize Rex block $bid to ${FM_BACKEND_REX_COLUMNS}x$FM_BACKEND_REX_ROWS; harness screens may wrap" >&2
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

# fm_backend_rex_rows: the block's current row count.
fm_backend_rex_rows() { # <target>
  local out rows
  out=$(fm_backend_rex_block_call "$1" size) || return 1
  rows=$(printf '%s' "$out" | jq -r '.rows // empty' 2>/dev/null)
  case "$rows" in '' | 0 | *[!0-9]*) return 1 ;; esac
  printf '%s' "$rows"
}

# fm_backend_rex_screen_read: one styled read of the block's screen and its
# cursor (hazard 5): the `format` block method with vt and extra_cursor
# returns the scrollback plus the full screen grid, rows joined by CRLF, then
# the cursor position as one trailing `ESC[<row>;<col>H`. An empty bottom row
# leaves the content ending in CRLF with that row implicit, so a final
# newline restores it. Sets FM_BACKEND_REX_SCREEN to the derived viewport (the
# last size.rows rows, SGR kept, carriage returns stripped) and
# FM_BACKEND_REX_CURSOR_Y to the cursor's 0-based viewport row, empty when
# the position is absent or outside the viewport. Call it directly, not in a
# command substitution, so the globals reach the caller.
fm_backend_rex_screen_read() { # <target> [expected-label]
  local rows out cup row
  FM_BACKEND_REX_SCREEN=
  FM_BACKEND_REX_CURSOR_Y=
  fm_backend_rex_target_ready "$1" "${2:-}" || return 1
  rows=$(fm_backend_rex_rows "$1") || return 1
  out=$(fm_backend_rex_block_call "$1" format '{"format":"vt","extra_cursor":true}' |
    jq -j '.content // empty' 2>/dev/null && printf x) || return 1
  out=${out%x}
  [ -n "$out" ] || return 1
  cup=$(printf '%s' "$out" | LC_ALL=C sed -n '$s/.*\(\[[0-9][0-9]*;[0-9][0-9]*H\)$/\1/p')
  if [ -n "$cup" ]; then
    out=${out%$'\033'"$cup"}
    row=${cup#[}
    row=${row%%;*}
    if [ "$row" -ge 1 ] && [ "$row" -le "$rows" ]; then
      FM_BACKEND_REX_CURSOR_Y=$((row - 1))
    fi
  fi
  FM_BACKEND_REX_SCREEN=$(printf '%s\n' "$out" | tr -d '\r' | tail -n "$rows" && printf x)
  FM_BACKEND_REX_SCREEN=${FM_BACKEND_REX_SCREEN%x}
}

# fm_backend_rex_visible_capture_vt: the derived viewport with SGR styling
# preserved, so the composer classifier can strip ghost text.
fm_backend_rex_visible_capture_vt() { # <target> [expected-label]
  fm_backend_rex_screen_read "$1" "${2:-}" || return 1
  printf '%s' "$FM_BACKEND_REX_SCREEN"
}

# fm_backend_rex_visible_capture: the same derived viewport as plain text
# (bin/fm-backend.sh's FM_BACKEND_VISIBLE_CAPTURE dispatch).
fm_backend_rex_visible_capture() { # <target> [expected-label]
  local screen
  screen=$(fm_backend_rex_visible_capture_vt "$1" "${2:-}" && printf x) || return 1
  printf '%s' "${screen%x}" | fm_composer_strip_ansi
}

# fm_backend_rex_rendered_busy_state: busy|idle|unknown from the rendered busy
# footer, the same delivery-only signal the herdr adapter reads, for harnesses
# that report no trusted program status.
fm_backend_rex_rendered_busy_state() { # <target> [harness]
  local cap visible
  cap=$(fm_backend_rex_capture "$1" 40) || {
    printf 'unknown'
    return 0
  }
  visible=$(printf '%s' "$cap" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || {
    printf 'unknown'
    return 0
  }
  if printf '%s' "$visible" | fm_busy_lines_match "${2:-}"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# fm_backend_rex_composer_identity: the identity probe behind the separated
# (pi, polytoken) composer shape and Command Code's placeholder ceiling.
# Prints "<owner>\t<status>" when the foreground process is one of those
# owners; status is the trusted native state, else the owner's own rendered
# busy footer.
fm_backend_rex_composer_identity() { # <target>
  local role pid name path argv0 owner='' base native rendered
  fm_backend_rex_process_chain "$1" || return 1
  while IFS=$'\t' read -r role pid name path argv0; do
    [ "$role" = foreground ] || continue
    for base in "${name##*/}" "${argv0##*/}" "${path##*/}"; do
      case "${base#-}" in
        pi | pi-signed | pi-launcher | Pi) owner=pi ;;
        polytoken) owner=polytoken ;;
        command-code) owner=commandcode ;;
      esac
      [ -z "$owner" ] || break
    done
  done <<EOF
$FM_BACKEND_REX_CHAIN
EOF
  [ -n "$owner" ] || return 1
  native=$(fm_backend_rex_native_state "$1")
  case "$native" in
    working | blocked | idle | done)
      printf '%s\t%s' "$owner" "$native"
      return 0
      ;;
  esac
  rendered=$(fm_backend_rex_rendered_busy_state "$1" "$owner")
  case "$rendered" in
    busy) printf '%s\tworking' "$owner" ;;
    idle) printf '%s\tidle' "$owner" ;;
    *) return 1 ;;
  esac
}

# fm_backend_rex_composer_caps: capability facts for the shared classifier
# (bin/fm-composer-lib.sh owns the model); the cursor is declared only when
# the read reported one.
fm_backend_rex_composer_caps() { # <rows> [cursor]
  printf 'styled=1\ncursor=%s\nidentity=1\nrows=%s\n' "${2:-0}" "${1:-0}"
}

# fm_backend_rex_composer_classify: one shared-classifier verdict for the
# screen and cursor row (empty for a cursorless read), fetching identity
# lazily, only when the verdict depends on it.
fm_backend_rex_composer_classify() { # <target> <screen> <cursor-row>
  local target=$1 screen=$2 cy=$3 caps verdict identity
  caps=$(fm_backend_rex_composer_caps "$(printf '%s\n' "$screen" | wc -l | tr -d '[:space:]')" "${cy:+1}")
  verdict=$(fm_composer_classify_screen "$caps" "$screen" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_backend_rex_composer_identity "$target" 2>/dev/null) || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$screen" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_rex_composer_state: the styled derived viewport and the cursor
# row in, the shared verdict out. The whole viewport is read, never a bounded
# tail, so an overlay drawn below the composer cannot push it out of view.
# The cursor-anchored read is tmux's: the shape holding the cursor is the
# composer, so furniture a harness draws below its composer cannot decide the
# verdict. Where that read is `unknown` - a harness that parks its cursor
# outside its composer, or no cursor at all - the cursorless read that picks
# the bottom-most shape decides.
fm_backend_rex_composer_state() { # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local target=$1 verdict=unknown
  fm_backend_rex_screen_read "$target" "${2:-}" 2>/dev/null || {
    printf 'unknown'
    return 0
  }
  if [ -n "$FM_BACKEND_REX_CURSOR_Y" ]; then
    verdict=$(fm_backend_rex_composer_classify "$target" "$FM_BACKEND_REX_SCREEN" "$FM_BACKEND_REX_CURSOR_Y")
  fi
  if [ "$verdict" = unknown ]; then
    verdict=$(fm_backend_rex_composer_classify "$target" "$FM_BACKEND_REX_SCREEN" '')
  fi
  printf '%s' "$verdict"
}

# fm_backend_rex_send_text_submit: type once, then the shared verify-and-retry
# Enter loop (bin/fm-composer-lib.sh: fm_composer_submit_retry_core), whose
# verdict fm_backend_rex_submit_state also confirms from a trusted root
# program status's working edge, and convert a still-pending composer whose
# agent is visibly busy into a queued delivery
# (fm_composer_queued_enter_verdict). Echoes
# empty|pending|pending-unproven|unknown|send-failed.
fm_backend_rex_send_text_submit() { # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} verdict FM_BACKEND_REX_SUBMIT_BASELINE
  fm_backend_rex_parse_target "$target" || {
    printf 'unknown'
    return 0
  }
  FM_BACKEND_REX_SUBMIT_BASELINE=$(fm_backend_rex_root_status "$target" 2>/dev/null) || FM_BACKEND_REX_SUBMIT_BASELINE=unreadable
  fm_backend_rex_send_literal "$target" "$text" "$expected_label" || {
    printf 'send-failed'
    return 0
  }
  sleep "$settle"
  verdict=$(fm_composer_submit_retry_core fm_backend_rex_send_key fm_backend_rex_submit_state \
    "$target" "$retries" "$sleep_s" "$expected_label")
  if [ "$verdict" = pending ]; then
    verdict=$(fm_composer_queued_enter_verdict "$verdict" "$(fm_backend_rex_delivery_busy "$target")")
  fi
  printf '%s' "$verdict"
}

# fm_backend_rex_process_chain: read the block's process view into
# FM_BACKEND_REX_CHAIN, one "<role>\t<pid>\t<name>\t<path>\t<argv0>" line per
# process, foreground first and then each of its ancestors; empty for a block
# with no foreground process. FM_BACKEND_REX_LAST_EXIT is `exited` once the
# kept-open block's program has ended. Fails with FM_BACKEND_REX_READ_RC set
# to rex's exit status (3 gone, 4 unreachable) when the block cannot be read.
# Call it directly, not in a command substitution, so the globals reach the
# caller.
fm_backend_rex_process_chain() { # <target>
  local out rc
  FM_BACKEND_REX_CHAIN=
  FM_BACKEND_REX_LAST_EXIT=
  FM_BACKEND_REX_READ_RC=1
  out=$(fm_backend_rex_block_call "$1" process)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FM_BACKEND_REX_READ_RC=$rc
    return 1
  fi
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  FM_BACKEND_REX_LAST_EXIT=$(printf '%s' "$out" | jq -r 'if .last_exit == null then "" else "exited" end' 2>/dev/null)
  FM_BACKEND_REX_CHAIN=$(printf '%s' "$out" | jq -r '
    def row($role): [$role, ((.pid // "") | tostring), (.name // ""), (.path // ""), (.argv0 // "")] | join("\t");
    (if .foreground then (.foreground | row("foreground")) else empty end),
    (.ancestors[]? | row("ancestor"))' 2>/dev/null) || return 1
  FM_BACKEND_REX_READ_RC=0
}

# fm_backend_rex_process_kind: agent|shell|other for one process, from its
# name, install path, argv[0], and live pid through the shared classifier.
fm_backend_rex_process_kind() { # <pid> <name> <path> <argv0>
  local pid=$1 name=$2 path=$3 argv0=$4 kind
  kind=$(fm_agent_process_classify "$name" "$argv0" '' "$pid")
  [ "$kind" != agent ] || {
    printf 'agent'
    return 0
  }
  if [ -n "$path" ] && [ "$(fm_agent_process_classify_name "$path" "$argv0")" = agent ]; then
    printf 'agent'
    return 0
  fi
  printf '%s' "$kind"
}

# fm_backend_rex_agent_state: the recovery-grade state (vocabulary owned by
# bin/fm-backend.sh's fm_backend_agent_state). Exit 3 on the recorded full
# block id is `missing`; any other failed read is `unreadable` (hazard 4). A
# recorded `last_exit` (the kept-open pane's program ended) is `dead`.
# Otherwise two independent sources are read: Rex's own process view - the
# foreground process and every ancestor - and the kernel's foreground process
# group on the block's tty. A verified harness anywhere in either is `alive`
# (a harness running a pager or an interactive shell escape is still there);
# only a foreground that is nothing but shells is `dead`; anything else is
# `ambiguous`.
fm_backend_rex_agent_state() { # <target>
  local target=$1 out rc role fpid name path argv0 kind fg_pid='' fg_kind='' tty pid pgid tpgid comm args
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
  if ! fm_backend_rex_process_chain "$target"; then
    if [ "$FM_BACKEND_REX_READ_RC" = 3 ]; then printf 'missing'; else printf 'unreadable'; fi
    return 0
  fi
  if [ "$FM_BACKEND_REX_LAST_EXIT" = exited ]; then
    printf 'dead'
    return 0
  fi
  while IFS=$'\t' read -r role fpid name path argv0; do
    [ -n "$role" ] || continue
    kind=$(fm_backend_rex_process_kind "$fpid" "$name" "$path" "$argv0")
    if [ "$kind" = agent ]; then
      printf 'alive'
      return 0
    fi
    if [ "$role" = foreground ]; then
      fg_pid=$fpid
      fg_kind=$kind
    fi
  done <<EOF
$FM_BACKEND_REX_CHAIN
EOF
  case "$fg_pid" in
    '' | *[!0-9]*)
      # No foreground process: the block is still starting.
      printf 'ambiguous'
      return 0
      ;;
  esac
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
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ] && [ "$fg_kind" = shell ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi
  case "$fg_kind" in
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

# fm_backend_rex_kill: close the task's block, then prove it gone (exit 3),
# close its side panes, and retire this home's own session if that was its
# last tab. 0 = closed or already gone; 1 = the block or a side pane may still
# be live (unreachable server, a label that no longer matches, or a close that
# did not take), so teardown keeps the record and can retry. The close's
# `gone` edge only ends an armed watcher's wait (bin/fm-transition-lib.sh), so
# a deliberate cleanup never escalates.
fm_backend_rex_kill() { # <target> [unused] [expected-label]
  local target=$1 expected_label=${3:-} sid view window recorded="" label
  if window=$(fm_backend_rex_record_field "$target" rex_window_id); then
    recorded=window:$window
  fi
  if ! fm_backend_rex_target_ready "$target" "$expected_label"; then
    case "$FM_BACKEND_REX_READY_RC" in
      3)
        sid=$FM_BACKEND_REX_SESSION_ID
        if [ -n "$expected_label" ]; then
          fm_backend_rex_close_side_panes "$target" "$(fm_backend_rex_scoped_name "$expected_label")" "$recorded" || return 1
        fi
        fm_backend_rex_retire_home_session "$sid" "$target" "$expected_label"
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
  sid=$FM_BACKEND_REX_SESSION_ID
  view=$(fm_backend_rex_block_inspect "$target")
  window=$(printf '%s' "$view" | jq -r '.block.window_id // empty' 2>/dev/null)
  label=$(printf '%s' "$view" | jq -r '.block.label // empty' 2>/dev/null)
  FM_BACKEND_REX_TARGET_HINT=$target fm_backend_rex_cli block close -s "$FM_BACKEND_REX_SESSION_ID" "$FM_BACKEND_REX_BLOCK_ID" >/dev/null 2>&1 || true
  fm_backend_rex_block_inspect "$target" >/dev/null
  if [ "$?" -ne 3 ]; then
    echo "error: the Rex block for $target is still present after close" >&2
    return 1
  fi
  fm_backend_rex_close_side_panes "$target" "$label" "$window" "$recorded" || return 1
  fm_backend_rex_retire_home_session "$sid" "$target" "$expected_label"
  return 0
}

# fm_backend_rex_close_side_panes: close the side panes bin/fm-rex-side.sh
# opened for the task - blocks labeled `<scoped-label>/<name>` - in any of the
# typed windows given (the worker's current tab and its recorded one, since a
# moved block keeps its id but not its tab) of the task's session, on the
# task's server, proving each gone. Every other pane, in those tabs or
# elsewhere, is untouched. 1 when the inventory is unreadable or a close did
# not take, so a side pane is never left behind silently.
fm_backend_rex_close_side_panes() { # <target> <scoped-label> <typed-window-id>...
  local target=$1 label=$2 server sid out bid rc=0 windows w
  shift 2
  case "$label" in fm-?*) ;; *) return 0 ;; esac
  case "$label" in */*) return 0 ;; esac
  windows=$(for w in "$@"; do
    case "$w" in (window:?*) printf '%s\n' "$w" ;; esac
  done | jq -Rsc 'split("\n") | map(select(. != "")) | unique')
  [ "$windows" != "[]" ] || return 0
  fm_backend_rex_parse_target "$target" || return 0
  sid=$FM_BACKEND_REX_SESSION_ID
  server=$(fm_backend_rex_server "$target") || {
    echo "error: the Rex server of $target is unknown; its side panes may remain" >&2
    return 1
  }
  if ! out=$(FM_BACKEND_REX_SERVER=$server fm_backend_rex_cli block ls -s "$sid" --json 2>/dev/null) ||
    ! printf '%s' "$out" | jq -e '(.blocks | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not list the Rex panes of $target; its side panes may remain" >&2
    return 1
  fi
  for bid in $(printf '%s' "$out" | jq -r --argjson w "$windows" --arg p "$label/" \
    '.blocks[] | select((.window_id as $id | any($w[]; . == $id)) and ((.label // "") | startswith($p))) | .block_id' 2>/dev/null); do
    FM_BACKEND_REX_SERVER=$server fm_backend_rex_block_close "${sid#session:}:${bid#block:}" || {
      echo "error: the Rex side pane $bid of $target is still present after close" >&2
      rc=1
    }
  done
  return "$rc"
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

# fm_backend_rex_list_live: every live task block on the selected server
# whose label is scoped to this home (side panes, `<label>/<name>`, excluded),
# as "<session-uuid>:<block-uuid>\tfm-<id>".
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
      jq -r --arg p "$prefix" '.blocks[]? | select((.label | startswith($p)) and (.label | contains("/") | not)) | "\(.block_id)\t\(.label)"' 2>/dev/null)
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

# --- program status: attention records -----------------------------------------
# Rex shows program status (OSC 7501) as tab spinners and blocked symbols,
# session-picker indicators, the Activity sidebar, the Dock badge, sounds, and
# notifications, and streams every change as `program_status_changed`. A
# record is `ESC ] 7501 ; state=<s>[:kind=<k>][:app=<a>][:id=<i>][:msg=<b64>]
# ESC \`; a record with an id is independent of the pane's root record, so
# Firstmate's own records (app=firstmate, id=fm and its validation-progress
# child id=fm/validate on a worker pane, id=fm-wedge on the supervisor pane)
# never overwrite a harness's report and a harness never overwrites them.
# Clearing id=fm also removes id=fm/validate. A worker record's title is the
# task's tab label, which Rex shows as the record's label. Rex drops a `working` or `blocked` record when its
# owning process exits or at the next OSC 133 prompt mark, while `done` and
# `error` persist, so bin/fm-rex-marks.sh re-reads and repairs rather than
# writing once. Since Rex preview.16 the app's sounds and notifications follow
# a pane's main (root) program status only, so a child record badges the tab
# and the Activity sidebar but does not notify; a new mark therefore carries
# an OSC 777 desktop notification in the same write, which Rex streams as
# `desktop_notification` and the app shows as a notification that returns to
# the pane. No API sets a record: it is written to the pane's tty as one small
# write, so it cannot split inside the program's own output.
FM_BACKEND_REX_MARK_APP=firstmate
FM_BACKEND_REX_MARK_ID=fm
FM_BACKEND_REX_PROGRESS_ID=fm/validate
FM_BACKEND_REX_ALERT_ID=fm-wedge
FM_BACKEND_REX_MSG_MAX=120
FM_BACKEND_REX_TITLE_MAX=64
FM_BACKEND_REX_DEV_DIR=${FM_BACKEND_REX_DEV_DIR:-/dev}

# fm_backend_rex_tty: the device path of <target>'s terminal, from its
# foreground process (else its child); fails when it cannot be named.
fm_backend_rex_tty() { # <target>
  local out pid tty
  out=$(fm_backend_rex_block_call "$1" process) || return 1
  pid=$(printf '%s' "$out" | jq -r '.foreground.pid // .child.pid // empty' 2>/dev/null)
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$tty" in '' | '?' | '??') return 1 ;; esac
  printf '%s/%s' "$FM_BACKEND_REX_DEV_DIR" "${tty#/dev/}"
}

# fm_backend_rex_status_text: <text> as one record line: control characters
# become spaces and the result is clipped to <max> characters.
fm_backend_rex_status_text() { # <text> <max>
  local text
  text=$(printf '%s' "$1" | tr '\000-\037\177' ' ')
  printf '%s' "${text:0:$2}"
}

# fm_backend_rex_status_sequence: one OSC 7501 report. <msg> and <title> are
# clipped to FM_BACKEND_REX_MSG_MAX and FM_BACKEND_REX_TITLE_MAX characters
# and base64-encoded on one line; <progress> (0-100) is kept only for
# working and blocked.
fm_backend_rex_status_sequence() { # <state> <id> [kind] [msg] [title] [progress]
  local fields="state=$1" msg=${4:-} title=${5:-} progress=${6:-}
  [ -z "${3:-}" ] || fields="$fields:kind=$3"
  fields="$fields:app=$FM_BACKEND_REX_MARK_APP:id=$2"
  if [ "$1" != clear ]; then
    case "$1:$progress" in
      working:[0-9] | working:[1-9][0-9] | working:100 | blocked:[0-9] | blocked:[1-9][0-9] | blocked:100)
        fields="$fields:progress=$progress"
        ;;
    esac
    if [ -n "$title" ]; then
      title=$(fm_backend_rex_status_text "$title" "$FM_BACKEND_REX_TITLE_MAX")
      fields="$fields:title=$(printf '%s' "$title" | base64 | tr -d '\n')"
    fi
    if [ -n "$msg" ]; then
      msg=$(fm_backend_rex_status_text "$msg" "$FM_BACKEND_REX_MSG_MAX")
      fields="$fields:msg=$(printf '%s' "$msg" | base64 | tr -d '\n')"
    fi
  fi
  printf '\033]7501;%s\033\134' "$fields"
}

# fm_backend_rex_notify_sequence: one OSC 777 desktop notification. The
# sequence's own separators and control characters are removed from both
# fields.
fm_backend_rex_notify_sequence() { # <title> <body>
  local title body
  title=$(printf '%s' "$1" | tr ';\a\033\r\n' ',    ')
  body=$(printf '%s' "$2" | tr ';\a\033\r\n' ',    ')
  body=${body:0:$FM_BACKEND_REX_MSG_MAX}
  printf '\033]777;notify;%s;%s\a' "$title" "$body"
}

# fm_backend_rex_tty_write: write <bytes> to <target>'s tty in one write. The
# device is opened for append, which a tty ignores, so a regular file standing
# in for it keeps every write.
fm_backend_rex_tty_write() { # <target> <bytes>
  local dev
  dev=$(fm_backend_rex_tty "$1") || return 1
  [ -w "$dev" ] || return 1
  { printf '%s' "$2" >>"$dev"; } 2>/dev/null
}

# fm_backend_rex_mark: set (or with state `clear`, remove) Firstmate's own
# attention record on a task pane. <state> is blocked|error|done|clear; <kind>
# is permission|question|auth for blocked; <title> is the record's label (the
# task's tab label). Refuses a block that does not carry the task's scoped
# label, so a mark can never land on another pane. With <notify-title>, the
# same write raises a desktop notification whose body is <msg>.
fm_backend_rex_mark() { # <target> <state> [kind] [msg] [expected-label] [notify-title] [title]
  local bytes
  fm_backend_rex_target_ready "$1" "${5:-}" || return 1
  bytes=$(fm_backend_rex_status_sequence "$2" "$FM_BACKEND_REX_MARK_ID" "${3:-}" "${4:-}" "${7:-}")
  [ -z "${6:-}" ] || bytes="$bytes$(fm_backend_rex_notify_sequence "$6" "${4:-}")"
  fm_backend_rex_tty_write "$1" "$bytes"
}

# fm_backend_rex_progress: set Firstmate's validation-progress record
# (id=fm/validate, state working) on a task pane, or with <percent> `clear`
# remove it. An empty <percent> is indeterminate. Rex shows the record's
# progress and message in the tab and pane hover cards. Same label check as
# fm_backend_rex_mark.
fm_backend_rex_progress() { # <target> <percent|clear> [msg] [expected-label] [title]
  local bytes
  fm_backend_rex_target_ready "$1" "${4:-}" || return 1
  if [ "$2" = clear ]; then
    bytes=$(fm_backend_rex_status_sequence clear "$FM_BACKEND_REX_PROGRESS_ID")
  else
    bytes=$(fm_backend_rex_status_sequence working "$FM_BACKEND_REX_PROGRESS_ID" "" "${3:-}" "${5:-}" "$2")
  fi
  fm_backend_rex_tty_write "$1" "$bytes"
}

# --- state tint -----------------------------------------------------------------
# Rex's set_theme is not applied while a client owns the pane, and the app owns
# every pane it shows, so the only tint that works is in-band: OSC 11 sets the
# pane's default background and OSC 111 restores the theme's. The tint only
# changes cells the program leaves at the default background, a harness that
# chose its theme from the background at startup keeps that theme, and it
# persists until reset. Firstmate never sends an OSC 11 query: the terminal
# answers it on the pane's input, which the harness would read as typed text.

# fm_backend_rex_tint_sequence: OSC 11 for <#rrggbb>, or OSC 111 for `reset`.
fm_backend_rex_tint_sequence() { # <#rrggbb|reset>
  case "$1" in
    reset) printf '\033]111\033\134' ;;
    \#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) printf '\033]11;%s\033\134' "$1" ;;
    *) return 1 ;;
  esac
}

# fm_backend_rex_tint: tint a task pane's background, or with `reset` restore
# it. Same label check as fm_backend_rex_mark.
fm_backend_rex_tint() { # <target> <#rrggbb|reset> [expected-label]
  local bytes
  bytes=$(fm_backend_rex_tint_sequence "$2") || return 1
  fm_backend_rex_target_ready "$1" "${3:-}" || return 1
  fm_backend_rex_tty_write "$1" "$bytes"
}

# fm_backend_rex_status_records: the pane's program-status records as one JSON
# array; fails when the pane cannot be read.
fm_backend_rex_status_records() { # <target>
  local out
  out=$(fm_backend_rex_block_call "$1" program_status) || return 1
  printf '%s' "$out" | jq -ce '.records | if type == "array" then . else error("no records") end' 2>/dev/null
}

# fm_backend_rex_mark_read: "<state>\t<kind>\t<msg>\t<title>\t<progress>" of
# Firstmate's own record <id> (default the attention mark, id=fm) on the pane
# (empty fields when it has none, which reads as `clear`); fails when the pane
# cannot be read.
fm_backend_rex_mark_read() { # <target> [id]
  local records
  records=$(fm_backend_rex_status_records "$1") || return 1
  printf '%s' "$records" | jq -r --arg app "$FM_BACKEND_REX_MARK_APP" --arg id "${2:-$FM_BACKEND_REX_MARK_ID}" '
    ([.[] | select(.id == $id and .app == $app)] | first) as $r
    | if $r == null then "clear\t\t\t\t"
      else "\($r.state // "")\t\($r.kind // "")\t\($r.msg // "")\t\($r.title // "")\t\($r.progress // "")" end' 2>/dev/null
}

# fm_backend_rex_tab_rename: set the task tab's label to <label>, renaming
# only when the live label differs.
fm_backend_rex_tab_rename() { # <target> <label> [expected-label]
  local target=$1 want=$2 out wid view live
  [ -n "$want" ] || return 1
  fm_backend_rex_target_ready "$target" "${3:-}" || return 1
  out=$(fm_backend_rex_block_inspect "$target") || return 1
  wid=$(printf '%s' "$out" | jq -r '.block.window_id // empty' 2>/dev/null)
  [ -n "$wid" ] || return 1
  view=$(FM_BACKEND_REX_TARGET_HINT=$target fm_backend_rex_cli window ls -s "$FM_BACKEND_REX_SESSION_ID" --json 2>/dev/null) || return 1
  live=$(printf '%s' "$view" | jq -r --arg w "$wid" '.windows[]? | select(.window_id == $w) | .label // empty' 2>/dev/null)
  [ "$live" != "$want" ] || return 0
  FM_BACKEND_REX_TARGET_HINT=$target fm_backend_rex_cli window rename -s "$FM_BACKEND_REX_SESSION_ID" "$wid" "$want" >/dev/null 2>&1
}

# fm_backend_rex_alert: the away daemon's wedge alarm on Firstmate's own pane:
# a blocked record (id=fm-wedge, kind permission) plus an OSC 777 desktop
# notification, in one write. fm_backend_rex_alert_clear removes the record.
fm_backend_rex_alert() { # <target> <title> <body>
  fm_backend_rex_parse_target "$1" || return 1
  fm_backend_rex_tty_write "$1" \
    "$(fm_backend_rex_status_sequence blocked "$FM_BACKEND_REX_ALERT_ID" permission "$3")$(fm_backend_rex_notify_sequence "$2" "$3")"
}
fm_backend_rex_alert_clear() { # <target>
  fm_backend_rex_parse_target "$1" || return 1
  fm_backend_rex_tty_write "$1" "$(fm_backend_rex_status_sequence clear "$FM_BACKEND_REX_ALERT_ID")"
}

# --- program status: busy state and submit confirmation ------------------------
# A harness's own OSC 7501 report is the pane's ROOT record (no id). It counts
# only while the process that reported it is the block's foreground process
# or one of its ancestors: without shell integration a `working` record
# outlives the command that reported it, so no self-report outranks the
# process view. Firstmate's own records (app=firstmate, and every child id)
# never count, so an attention mark or validation progress can never read as
# the worker's state. Native busy is positive activity evidence only
# (bin/fm-busy-lib.sh); docs/verification/runtime-backends.md#rex owns which
# harnesses report it.

# fm_backend_rex_live_pids: the block's foreground pid and its ancestors' pids
# as a JSON array; fails when the block cannot be read.
fm_backend_rex_live_pids() { # <target>
  fm_backend_rex_process_chain "$1" || return 1
  printf '%s\n' "$FM_BACKEND_REX_CHAIN" | cut -f2 |
    jq -Rsc 'split("\n") | map(select(test("^[0-9]+$")) | tonumber)' 2>/dev/null
}

# fm_backend_rex_owner_trusted: THE trust rule for a reported record's owner.
fm_backend_rex_owner_trusted() { # <target> <owner-pid>
  local live
  case "$2" in '' | *[!0-9]*) return 1 ;; esac
  live=$(fm_backend_rex_live_pids "$1") || return 1
  jq -en --argjson live "$live" --argjson pid "$2" '$live | index($pid) != null' >/dev/null 2>&1
}

# fm_backend_rex_trusted_record: the block's governing trusted root record as
# "<state>\t<kind>\t<app>\t<msg>\t<updated_at>" (working, then blocked,
# error, done, idle), or an empty line when none passes the trust rule; fails
# when the pane cannot be read.
fm_backend_rex_trusted_record() { # <target>
  local records live
  records=$(fm_backend_rex_status_records "$1") || return 1
  live=$(fm_backend_rex_live_pids "$1") || return 1
  jq -rn --argjson r "$records" --argjson live "$live" --arg mark "$FM_BACKEND_REX_MARK_APP" '
    def clean: tostring | gsub("[\t\r\n]"; " ");
    [$r[] | select((.id // "") == "" and (.app // "") != $mark
      and (.owner.pid as $p | $p != null and ($live | index($p)) != null))] as $trusted
    | (first(("working", "blocked", "error", "done", "idle") as $want
        | $trusted[] | select(.state == $want)
        | [.state, (.kind // ""), (.app // ""), (.msg // ""), (.updated_at // "")] | map(clean) | join("\t"))
      // "")' 2>/dev/null
}

# fm_backend_rex_native_state: the trusted root record's state
# (working|blocked|idle|done|error), or empty when none can be trusted.
fm_backend_rex_native_state() { # <target>
  fm_backend_rex_trusted_record "$1" 2>/dev/null | cut -f1
}

# fm_backend_rex_root_status: "<state>\t<updated_at>" of the trusted root
# record, an empty line when there is none; fails when the pane cannot be read.
fm_backend_rex_root_status() { # <target>
  local rec
  rec=$(fm_backend_rex_trusted_record "$1") || return 1
  [ -n "$rec" ] || {
    printf '\n'
    return 0
  }
  printf '%s\t%s\n' "$(printf '%s' "$rec" | cut -f1)" "$(printf '%s' "$rec" | cut -f5)"
}

# fm_backend_rex_busy_state: busy|idle|unknown from the trusted root record:
# working is busy; idle, done, blocked (waiting on the human, not grinding),
# and error are idle; no trusted record is unknown.
fm_backend_rex_busy_state() { # <target>
  fm_backend_rex_target_ready "$1" || {
    printf 'unknown'
    return 0
  }
  case "$(fm_backend_rex_native_state "$1")" in
    working) printf 'busy' ;;
    idle | done | blocked | error) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_rex_delivery_busy: busy|idle|unknown for the queued-Enter
# conversion: a trusted native working state, else the rendered busy footer.
fm_backend_rex_delivery_busy() { # <target>
  [ "$(fm_backend_rex_busy_state "$1")" != busy ] || {
    printf 'busy'
    return 0
  }
  fm_backend_rex_rendered_busy_state "$1"
}

# fm_backend_rex_submit_state: the state function behind send_text_submit's
# Enter loop. The composer verdict stands unless it is not exact `empty` and
# the trusted root record moved to `working` from the not-working baseline
# captured before typing (FM_BACKEND_REX_SUBMIT_BASELINE) - a turn started, so
# the submit landed.
fm_backend_rex_submit_state() { # <target> [expected-label]
  local verdict rec
  verdict=$(fm_backend_rex_composer_state "$1" "${2:-}")
  [ "$verdict" != empty ] || {
    printf 'empty'
    return 0
  }
  case "${FM_BACKEND_REX_SUBMIT_BASELINE:-}" in
    working* | unreadable) ;;
    *)
      rec=$(fm_backend_rex_root_status "$1" 2>/dev/null) || rec=
      if [ "${rec%%$'\t'*}" = working ]; then
        printf 'empty'
        return 0
      fi
      ;;
  esac
  printf '%s' "$verdict"
}

# --- native event push ----------------------------------------------------------
# The push half of the watcher's escalation (bin/fm-backend.sh "native event
# push"). fm_backend_rex_wait_transition replaces the watcher's blind sleep
# with a bounded `rex do` Lua reader (bin/backends/rex-eventwait.lua) on the
# session holding the watched blocks, on the server their records name. The
# reader streams program_status_changed for harness root records (never
# Firstmate's own records), child_exited, and block_closed for the watched
# blocks, and prints `@subscribed` once it is listening, so the level
# reconcile after it cannot lose an edge. Every edge is normalized through
# fm_transition_record and routed through the shared policy and per-pane
# dedupe (bin/fm-transition-lib.sh); a status edge counts only when
# fm_backend_rex_owner_trusted accepts its owner, and a `gone` edge only ends
# the wait so the watcher's poll reconciles that task at once. Polling stays
# the permanent fallback: an incapable Rex, a reader that cannot start, or one
# that ends early all return 2 and the caller sleeps the budget.

# Per-pane escalation dedupe marker prefix, under the state dir.
FM_BACKEND_REX_ESCALATED_PREFIX=".rex-escalated-"
# Longest OSC 7501 message carried into a wake reason; the rest is cut.
FM_BACKEND_REX_DETAIL_MAX=${FM_BACKEND_REX_DETAIL_MAX:-160}

# fm_backend_rex_server_of_session: the `rex_server=` of a task recorded in
# session <uuid>, or failure.
fm_backend_rex_server_of_session() { # <session-uuid>
  local meta
  for meta in "${STATE:-$FM_HOME/state}"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(sed -n 's/^rex_session_id=//p' "$meta" 2>/dev/null | tail -1)" = "$1" ] || continue
    sed -n 's/^rex_server=//p' "$meta" 2>/dev/null | tail -1
    return 0
  done
  return 1
}

# fm_backend_rex_events_capable: the gate for the event fast path - the CLI
# and jq, and a reachable server for <session> at the verified API floor with
# the program_status method, read without starting a server.
# FM_BACKEND_REX_EVENTS_FORCE=1|0 overrides it for tests.
fm_backend_rex_events_capable() { # <session-uuid>
  local server
  case "${FM_BACKEND_REX_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  server=$(fm_backend_rex_server_of_session "$1") || server=$(fm_backend_rex_server) || return 1
  FM_BACKEND_REX_SERVER=$server fm_backend_rex_version_check >/dev/null 2>&1 || return 1
  FM_BACKEND_REX_SERVER=$server fm_backend_rex_cli api list -q 2>/dev/null | grep -Fqx com.superlogical.terminal.program_status
}

# fm_backend_rex_event_reader: run the bounded Lua reader for typed
# <session-id> and the watched typed <block-id...> until <timeout> seconds
# pass, on the server FM_BACKEND_REX_TARGET_HINT's record names. Exits 0 at
# the deadline; nonzero when the reader cannot start.
# FM_BACKEND_REX_EVENT_READER substitutes a whitespace-split command taking
# the same arguments, so tests can replay canned stream lines.
fm_backend_rex_event_reader() { # <session-id> <timeout> <block-id...>
  local sid=$1 timeout=$2 word blocks
  shift 2
  if [ -n "${FM_BACKEND_REX_EVENT_READER:-}" ]; then
    local cmd=()
    for word in $FM_BACKEND_REX_EVENT_READER; do
      cmd+=("$word")
    done
    "${cmd[@]}" "$sid" "$timeout" "$@"
    return
  fi
  blocks=$(printf '%s\n' "$@" | jq -Rsc '{blocks: split("\n") | map(select(length > 0))}') || return 1
  fm_backend_rex_cli 'do' -s "$sid" --for "${timeout}s" \
    "$FM_BACKEND_REX_ROOT/bin/backends/rex-eventwait.lua" --args "$blocks"
}

# fm_backend_rex_edge_detail: the human-readable cause of a blocked edge, from
# Rex's blocked kind (permission|question|auth) and the program's message.
fm_backend_rex_edge_detail() { # <kind> <msg>
  local kind=$1 msg=$2
  if [ "${#msg}" -gt "$FM_BACKEND_REX_DETAIL_MAX" ]; then
    msg="${msg:0:$FM_BACKEND_REX_DETAIL_MAX}..."
  fi
  if [ -n "$kind" ] && [ -n "$msg" ]; then
    printf '%s: %s' "$kind" "$msg"
  else
    printf '%s' "$kind$msg"
  fi
}

fm_backend_rex_commit_transition() { # <state_dir> <session-uuid> <record>
  fm_transition_commit "$1" "$FM_BACKEND_REX_ESCALATED_PREFIX" "$2" "$3"
}

fm_backend_rex_clear_transition() { # <state_dir> <window>
  fm_transition_clear "$1" "$FM_BACKEND_REX_ESCALATED_PREFIX" "${2:-}"
}

# fm_backend_rex_wait_transition: the bounded event wait (contract in
# bin/fm-backend.sh). <session> is the recorded session uuid and each
# <window> a recorded "<session-uuid>:<block-uuid>" target. Blocks up to
# <timeout_secs> for a fresh trusted `blocked` edge on a watched block, then
# prints its normalized record (the block uuid as pane_id, the reporting app
# as agent, kind and message as detail) and returns 0. Returns 1 on a clean
# full-budget wait, and also at once when a watched block's program exits or
# the block closes, so the watcher's poll cycle reconciles that task now.
# Returns 2 when the event path is unusable or the reader ended early (the
# caller sleeps the budget itself).
fm_backend_rex_wait_transition() { # <session-uuid> <timeout_secs> <state_dir> <window...>
  local session=$1 timeout=$2 state=$3
  shift 3
  local w first='' blocks=() windows=()
  case "$timeout" in '' | *[!0-9]* | 0) return 2 ;; esac
  for w in "$@"; do
    fm_backend_rex_parse_target "$w" || continue
    [ "${w%%:*}" = "$session" ] || continue
    [ -n "$first" ] || first=$w
    blocks+=("$FM_BACKEND_REX_BLOCK_ID")
    windows+=("$w")
  done
  [ -n "$first" ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_rex_events_capable "$session" || return 2
  fi

  local fifo_dir fifo reader_pid line block to kind app owner msg record hit apply_rc level
  local rc=1 reader_rc=0 started=$SECONDS
  fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  FM_BACKEND_REX_TARGET_HINT=$first fm_backend_rex_event_reader "session:$session" "$timeout" "${blocks[@]}" >"$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9<"$fifo"; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  if ! IFS= read -r -t "$((timeout + 15))" -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  fi

  # Level reconcile once the reader is listening: a block already blocked
  # since the last wait is returned now, once, and a working one clears its
  # marker, while newer edges queue in the live stream.
  if [ "$rc" -eq 1 ]; then
    for w in "${windows[@]}"; do
      level=$(fm_backend_rex_trusted_record "$w" 2>/dev/null) || continue
      [ -n "$level" ] || continue
      to=$(printf '%s' "$level" | cut -f1)
      kind=$(printf '%s' "$level" | cut -f2)
      app=$(printf '%s' "$level" | cut -f3)
      msg=$(printf '%s' "$level" | cut -f4)
      record=$(fm_transition_record "${w#*:}" "" "" "$to" "$app" "$(fm_backend_rex_edge_detail "$kind" "$msg")")
      if hit=$(fm_transition_apply "$state" "$FM_BACKEND_REX_ESCALATED_PREFIX" "$session" "$record"); then
        printf '%s' "$hit"
        rc=0
        break
      fi
    done
  fi

  # Drain stream edges until a fresh blocked edge, an endpoint-gone edge, or
  # the deadline. Fields are split with cut, not `IFS=$'\t' read`, which would
  # collapse an empty middle field.
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    [ -n "$line" ] || continue
    block=$(printf '%s' "$line" | cut -f1)
    to=$(printf '%s' "$line" | cut -f2)
    kind=$(printf '%s' "$line" | cut -f3)
    app=$(printf '%s' "$line" | cut -f4)
    owner=$(printf '%s' "$line" | cut -f5)
    msg=$(printf '%s' "$line" | cut -f6)
    case "$block" in block:*) fm_backend_rex_uuid_valid "${block#block:}" || continue ;; *) continue ;; esac
    case "$(fm_transition_policy "$to")" in
      actionable | absorb)
        fm_backend_rex_owner_trusted "$session:${block#block:}" "$owner" || continue
        ;;
    esac
    record=$(fm_transition_record "${block#block:}" "" "" "$to" "$app" "$(fm_backend_rex_edge_detail "$kind" "$msg")")
    apply_rc=0
    hit=$(fm_transition_apply "$state" "$FM_BACKEND_REX_ESCALATED_PREFIX" "$session" "$record") || apply_rc=$?
    case "$apply_rc" in
      0)
        printf '%s' "$hit"
        rc=0
        ;;
      3) rc=3 ;;
    esac
  done
  [ "$rc" -eq 1 ] || kill "$reader_pid" 2>/dev/null || true
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$fifo_dir" 2>/dev/null || true
  case "$rc" in
    0) return 0 ;;
    2) return 2 ;;
    3) return 1 ;;
  esac
  # No edge: a reader that ran the whole budget is a clean wait; one that
  # failed or ended early (its session destroyed, or its server gone) is not,
  # so the caller sleeps rather than spinning.
  [ "$reader_rc" -eq 0 ] && [ $((SECONDS - started)) -ge $((timeout - 1)) ] && return 1
  return 2
}
